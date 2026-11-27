import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/mastodon.dart';

/// Mastodon's direct messages (lib/inbox/mastodon.dart; Matt, 2026-11-15: "Wire up mastadon and bluesky and have them
/// set as coming soon") against a stand-in Mastodon server on this computer: Uplink registered on it, the code
/// exchanged for a token, the conversations and one's thread read, a reply sent naming the others, read, deleted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late HttpServer server;
  late String base;
  final seen = <String>[];
  final posted = <Map>[];

  Map<String, Object?> account(String id, String acct, String name) => {'id': id, 'acct': acct, 'display_name': name, 'avatar_static': 'https://files.example/$id.png'};
  Map<String, Object?> status(String id, String from, String html, String at, {String visibility = 'direct', String? reply}) => {
        'id': id, 'content': html, 'created_at': at, 'visibility': visibility, 'in_reply_to_id': reply, 'media_attachments': const [],
        'account': from == '1' ? account('1', 'matt', 'Matt') : account('2', 'jo@social.example', 'Jo Park'),
      };

  setUp(() async {
    seen.clear();
    posted.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      seen.add('${req.method} $path');
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? const {} : jsonDecode(raw) as Map;
      Object? answer = const {};
      var code = 200;
      final authed = req.headers.value('authorization') == 'Bearer tok';
      switch ('${req.method} $path') {
        case 'POST /api/v1/apps':
          answer = body['redirect_uris'] == 'urn:ietf:wg:oauth:2.0:oob' ? {'client_id': 'cid', 'client_secret': 'secret'} : null;
        case 'POST /oauth/token':
          answer = body['code'] == 'good-code' && body['client_secret'] == 'secret' ? {'access_token': 'tok'} : null;
          if (answer == null) {
            code = 400;
            answer = {'error': 'The provided authorization grant is invalid.'};
          }
        case 'GET /api/v1/accounts/verify_credentials':
          answer = authed ? account('1', 'matt', 'Matt') : null;
        case 'GET /api/v1/conversations':
          answer = [
            {'id': '77', 'unread': true, 'accounts': [account('2', 'jo@social.example', 'Jo Park')], 'last_status': status('103', '2', '<p><span class="h-card"><a href="#">@<span>matt</span></a></span> see you at 7 &amp; bring snacks</p>', '2026-11-15T20:00:00Z')},
          ];
        case 'GET /api/v1/statuses/103/context':
          answer = {
            'ancestors': [
              status('101', '1', '<p>@jo are you coming tonight?</p>', '2026-11-15T19:00:00Z'),
              status('102', '2', '<p>public reply</p>', '2026-11-15T19:30:00Z', visibility: 'public'),
            ],
            'descendants': const [],
          };
        case 'GET /api/v1/statuses/103':
          answer = status('103', '2', '<p>@matt see you at 7 &amp; bring snacks</p>', '2026-11-15T20:00:00Z');
        case 'POST /api/v1/statuses':
          posted.add(body);
          answer = status('104', '1', '<p>${body['status']}</p>', '2026-11-15T20:05:00Z');
        case 'POST /api/v1/conversations/77/read':
        case 'DELETE /api/v1/conversations/77':
        case 'DELETE /api/v1/statuses/104':
          answer = const {};
        default:
          code = 404;
          answer = {'error': 'Record not found'};
      }
      if (answer == null) code = code == 200 ? 401 : code;
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(answer ?? {'error': 'no'}));
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a server address, its page, the code: signed in; a direct conversation read, answered, read and deleted', () async {
    final app = AppState();
    final m = Mastodon();
    await m.start(app);
    expect(m.state, InboxState.signedOut);
    expect(Mastodon.serverOf('@matt@mastodon.social'), 'https://mastodon.social');
    expect(Mastodon.serverOf('mastodon.social/'), 'https://mastodon.social');

    final page = await m.begin(base);
    expect(Uri.parse(page!).path, '/oauth/authorize');
    expect(Uri.parse(page).queryParameters, containsPair('client_id', 'cid'));
    expect(m.step, InboxStep.code);
    await m.sendCode('wrong');
    expect(m.error, contains('grant'));
    await m.sendCode(' good-code ');
    expect(m.state, InboxState.ready);
    expect(m.account, '@matt@127.0.0.1');
    expect(app.choice('mastodon_session', ''), contains('"token":"tok"'));

    await m.refresh();
    final chat = m.chats.single;
    expect((chat.title, chat.snippet, chat.unread, chat.avatar), ('Jo Park', 'see you at 7 & bring snacks', 1, 'https://files.example/2.png'));

    await m.load('77');
    expect(m.messagesOf('77').map((x) => x.text), ['are you coming tonight?', 'see you at 7 & bring snacks'], reason: 'its direct posts alone, oldest first, mentions taken off');
    expect(m.messagesOf('77').first.mine, isTrue);

    await m.send('77', 'on my way');
    expect(posted.single, {'status': '@jo@social.example on my way', 'visibility': 'direct', 'in_reply_to_id': '103'});
    final mine = m.messagesOf('77').last;
    expect((mine.id, mine.mine, mine.state), ('104', true, 'sent'));
    expect(m.canDeleteForEveryone('77', mine), isTrue);
    await m.deleteMessage('77', '104', forEveryone: true);
    expect(seen, contains('DELETE /api/v1/statuses/104'));

    await m.markRead('77');
    expect(seen, contains('POST /api/v1/conversations/77/read'));
    await m.deleteChat('77');
    expect(seen, contains('DELETE /api/v1/conversations/77'));
    expect(m.chats, isEmpty);
    m.dispose();
  });

  test('Mastodon and Bluesky are offered as Coming soon', () {
    Inbox.instance = null;
    final own = Inbox.instance;
    expect(own.named('mastodon')!.soon, isTrue);
    expect(own.named('bluesky')!.soon, isTrue);
    expect(own.ready.map((n) => n.id), isNot(contains('mastodon')));
  });
}
