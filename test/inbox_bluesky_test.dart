import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/bluesky.dart';
import 'package:ghost_messaging/inbox/inbox.dart';

/// Bluesky's direct messages (lib/inbox/bluesky.dart) against a stand-in for Bluesky on this computer: the handle
/// resolved, the account's server found in the directory, a session made with an app password, the chats and a
/// chat's messages read through the chat service's proxy header, a reply sent, a run-out session renewed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every request with a 400 of its own: these go to the stand-in on this computer.
  HttpOverrides.global = null;
  late HttpServer server;
  late String base;
  final seen = <String>[];
  var access = 'access-1';
  var scoped = true;
  final sent = <Map>[];

  setUp(() async {
    seen.clear();
    sent.clear();
    access = 'access-1';
    scoped = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      seen.add('${req.method} $path ${req.headers.value('atproto-proxy') ?? ''}'.trim());
      final raw = await utf8.decoder.bind(req).join();
      final body = raw.isEmpty ? const {} : jsonDecode(raw) as Map;
      Object? answer;
      var status = 200;
      final bearer = req.headers.value('authorization');
      final chat = path.startsWith('/xrpc/chat.');
      if (chat && req.headers.value('atproto-proxy') != 'did:web:api.bsky.chat#bsky_chat') {
        status = 400;
        answer = {'error': 'InvalidRequest', 'message': 'no proxy'};
      } else if (chat && !scoped) {
        status = 401;
        answer = {'error': 'InvalidToken', 'message': 'Bad token scope'};
      } else if (chat && bearer != 'Bearer $access') {
        status = 400;
        answer = {'error': 'ExpiredToken', 'message': 'Token has expired'};
      } else {
        switch (path) {
          case '/xrpc/com.atproto.identity.resolveHandle':
            answer = req.uri.queryParameters['handle'] == 'matt.bsky.social' ? {'did': 'did:plc:matt'} : null;
            if (answer == null) status = 400;
          case '/did:plc:matt':
            answer = {
              'id': 'did:plc:matt',
              'service': [
                {'id': '#atproto_pds', 'type': 'AtprotoPersonalDataServer', 'serviceEndpoint': base},
              ],
            };
          case '/xrpc/com.atproto.server.createSession':
            if (body['password'] == 'abcd-efgh-ijkl-mnop') {
              answer = {'accessJwt': access, 'refreshJwt': 'refresh-1', 'did': 'did:plc:matt', 'handle': 'matt.bsky.social'};
            } else {
              status = 401;
              answer = {'error': 'AuthenticationRequired', 'message': 'Invalid identifier or password'};
            }
          case '/xrpc/com.atproto.server.refreshSession':
            access = 'access-2';
            answer = {'accessJwt': access, 'refreshJwt': 'refresh-2', 'did': 'did:plc:matt', 'handle': 'matt.bsky.social'};
          case '/xrpc/chat.bsky.convo.listConvos':
            answer = {
              'convos': [
                {
                  'id': 'c1',
                  'members': [
                    {'did': 'did:plc:matt', 'handle': 'matt.bsky.social'},
                    {'did': 'did:plc:jo', 'handle': 'jo.bsky.social', 'displayName': 'Jo'},
                  ],
                  'lastMessage': {'id': 'm2', 'text': 'see you there', 'sender': {'did': 'did:plc:jo'}, 'sentAt': '2026-11-15T10:05:00Z'},
                  'unreadCount': 1,
                },
              ],
            };
          case '/xrpc/chat.bsky.convo.getMessages':
            answer = {
              'messages': [
                {'id': 'm2', 'text': 'see you there', 'sender': {'did': 'did:plc:jo'}, 'sentAt': '2026-11-15T10:05:00Z'},
                {'id': 'm1', 'text': 'coming tonight?', 'sender': {'did': 'did:plc:matt'}, 'sentAt': '2026-11-15T10:00:00Z'},
              ],
            };
          case '/xrpc/chat.bsky.convo.sendMessage':
            sent.add(body);
            answer = {'id': 'm3', 'text': (body['message'] as Map)['text'], 'sender': {'did': 'did:plc:matt'}, 'sentAt': '2026-11-15T10:06:00Z'};
          case '/xrpc/chat.bsky.convo.updateRead':
            answer = {'convo': {}};
          case '/xrpc/chat.bsky.convo.deleteMessageForSelf':
            sent.add(body);
            answer = {'id': body['messageId']};
          case '/xrpc/chat.bsky.convo.leaveConvo':
            sent.add(body);
            answer = {'convoId': body['convoId'], 'rev': '1'};
          default:
            status = 404;
            answer = {'error': 'NotFound'};
        }
      }
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(answer));
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('signs in, reads the chats and a chat, and replies', () async {
    final app = AppState();
    final b = Bluesky(entryway: base, plc: base);
    await b.start(app);
    expect(b.state, InboxState.signedOut);

    await b.signIn('@matt', 'abcd-efgh-ijkl-mnop');
    expect(b.error, isNull);
    expect(b.state, InboxState.ready);
    expect(b.account, 'matt.bsky.social');
    // Only the session is kept, never the password.
    expect(app.choice('bsky_session', ''), contains('refresh-1'));
    expect(app.choice('bsky_session', ''), isNot(contains('abcd')));

    await b.refresh();
    expect(b.chats.single.title, 'Jo');
    expect(b.chats.single.unread, 1);
    expect(b.chats.single.snippet, 'see you there');

    await b.load('c1');
    expect(b.messagesOf('c1').map((m) => (m.text, m.mine)), [('coming tonight?', true), ('see you there', false)]);

    await b.send('c1', ' on my way ');
    expect(sent.single, {'convoId': 'c1', 'message': {'text': 'on my way'}});
    expect(b.messagesOf('c1').last.text, 'on my way');
    expect(b.messagesOf('c1').last.state, 'sent');
    expect(b.chats.single.lastFromMe, isTrue);

    await b.markRead('c1');
    expect(b.chats.single.unread, 0);
    expect(seen, contains('POST /xrpc/chat.bsky.convo.updateRead did:web:api.bsky.chat#bsky_chat'));

    // Deleted for this account, and left, on Bluesky itself (Matt, 2026-11-15: "if possible proxy the archive and
    // delete messages too").
    await b.deleteMessage('c1', 'm3');
    expect(sent.last, {'convoId': 'c1', 'messageId': 'm3'});
    expect(b.messagesOf('c1').map((m) => m.id), isNot(contains('m3')));
    await b.deleteChat('c1');
    expect(sent.last, {'convoId': 'c1'});
    expect(b.chats, isEmpty);
    b.dispose();
  });

  test('a run-out session is renewed and the call made again', () async {
    final b = Bluesky(entryway: base, plc: base);
    await b.start(AppState());
    await b.signIn('matt.bsky.social', 'abcd-efgh-ijkl-mnop');
    access = 'access-9';
    await b.refresh();
    expect(b.error, isNull);
    expect(seen, contains('POST /xrpc/com.atproto.server.refreshSession'));
    expect(b.chats, hasLength(1));
    b.dispose();
  });

  test('says plainly what went wrong', () async {
    final b = Bluesky(entryway: base, plc: base);
    await b.start(AppState());
    await b.signIn('matt.bsky.social', 'wrong');
    expect(b.state, InboxState.signedOut);
    expect(b.error, 'That handle and app password don\'t match.');

    // An app password without direct messages allowed: refused at sign-in, not found out later as an empty tab.
    scoped = false;
    await b.signIn('matt.bsky.social', 'abcd-efgh-ijkl-mnop');
    expect(b.state, InboxState.signedOut);
    expect(b.error, contains('Allow access to your direct messages'));

    await b.signIn('nobody.example', 'x');
    expect(b.error, isNotNull);
    b.dispose();
  });

  test('signing in again after a restart, and signing out forgets it', () async {
    final app = AppState();
    final first = Bluesky(entryway: base, plc: base);
    await first.start(app);
    await first.signIn('matt.bsky.social', 'abcd-efgh-ijkl-mnop');
    first.dispose();

    final again = Bluesky(entryway: base, plc: base);
    await again.start(app);
    expect(again.state, InboxState.ready);
    expect(again.account, 'matt.bsky.social');

    await again.signOut();
    expect(again.state, InboxState.signedOut);
    expect(app.choice('bsky_session', 'x'), '');
    again.dispose();
  });
}
