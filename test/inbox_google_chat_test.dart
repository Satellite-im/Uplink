import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/google_chat.dart';
import 'package:ghost_messaging/inbox/inbox.dart';

/// Google Chat (lib/inbox/google_chat.dart; Matt, 2026-11-17: "Let's add support for matrix, microsoft teams and google
/// chat") against a stand-in for Google's token endpoint, the Chat API and the People API on this computer: the
/// browser's return to the loopback address played by the test, the code exchanged with its PKCE verifier, spaces
/// listed, a thread read, sent to, replied into and marked read, a 429 waited out, the refresh token used and revoked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late HttpServer server;
  late String base;
  final seen = <String>[];
  final posted = <({String path, Map query, Map body})>[];
  late String challenge;
  var refreshes = 0;
  var tooMany = false;
  var revoked = false;

  String idToken(Map claims) => 'h.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.s';

  Map msg(String name, String user, String text, String at, String thread, {bool reply = false}) => {
        'name': name, 'text': text, 'createTime': at, 'sender': {'name': user, 'type': 'HUMAN'},
        'thread': {'name': thread}, if (reply) 'threadReply': true,
      };

  GoogleChat chat() => GoogleChat(clientId: 'cid.apps.googleusercontent.com', clientSecret: 'shh', authUrl: '$base/auth', tokenUrl: '$base/token', revokeUrl: '$base/revoke', chatBase: '$base/v1', peopleBase: '$base/people');

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 500 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ok(), isTrue);
  }

  setUp(() async {
    seen.clear();
    posted.clear();
    refreshes = 0;
    tooMany = false;
    revoked = false;
    challenge = '';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      final q = req.uri.queryParameters;
      seen.add('${req.method} $path');
      final raw = await utf8.decoder.bind(req).join();
      final form = req.headers.contentType?.mimeType == 'application/x-www-form-urlencoded' ? Uri.splitQueryString(raw) : const <String, String>{};
      final body = req.headers.contentType?.mimeType == 'application/json' && raw.isNotEmpty ? jsonDecode(raw) as Map : const {};
      final authed = req.headers.value('authorization') == 'Bearer at1' || req.headers.value('authorization') == 'Bearer at2';
      Object? answer = const {};
      var code = 200;
      void no(int c, String words) {
        code = c;
        answer = {'error': {'code': c, 'message': words}};
      }

      if (path == '/token') {
        if (form['grant_type'] == 'authorization_code') {
          final ok = form['code'] == 'good' && form['client_secret'] == 'shh' && form['redirect_uri']!.startsWith('http://127.0.0.1:') &&
              GoogleChat.challengeOf(form['code_verifier'] ?? '') == challenge;
          answer = ok
              ? {'access_token': 'at1', 'expires_in': 3599, 'refresh_token': 'rt', 'scope': GoogleChat.scopes.where((s) => s.startsWith('https')).join(' '), 'id_token': idToken({'sub': '1', 'email': 'matt@work.example'})}
              : {'error': 'invalid_grant', 'error_description': 'Bad verifier'};
          if (!ok) code = 400;
        } else if (form['grant_type'] == 'refresh_token') {
          refreshes++;
          if (revoked || form['refresh_token'] != 'rt') {
            code = 400;
            answer = {'error': 'invalid_grant', 'error_description': 'Token has been expired or revoked.'};
          } else {
            answer = {'access_token': 'at2', 'expires_in': 3599};
          }
        }
      } else if (path == '/revoke') {
        answer = const {};
      } else if (!authed) {
        no(401, 'Request had invalid authentication credentials.');
      } else if (tooMany) {
        no(429, 'Resource has been exhausted');
      } else {
        switch ('${req.method} $path') {
          case 'GET /v1/spaces':
            answer = {
              'spaces': [
                {'name': 'spaces/G', 'spaceType': 'GROUP_CHAT', 'displayName': '', 'lastActiveTime': '2026-11-17T09:00:00Z'},
                {'name': 'spaces/S', 'spaceType': 'SPACE', 'displayName': 'Launch team', 'lastActiveTime': '2026-11-17T08:00:00Z'},
                {'name': 'spaces/D', 'spaceType': 'DIRECT_MESSAGE', 'lastActiveTime': '2026-11-17T10:00:00Z'},
              ],
            };
          case 'GET /v1/spaces/D/members':
            answer = {'memberships': [{'member': {'name': 'users/1', 'type': 'HUMAN'}}, {'member': {'name': 'users/2', 'type': 'HUMAN'}}]};
          case 'GET /v1/spaces/G/members':
            answer = {'memberships': [{'member': {'name': 'users/1', 'type': 'HUMAN'}}, {'member': {'name': 'users/2', 'type': 'HUMAN'}}, {'member': {'name': 'users/3', 'type': 'HUMAN', 'displayName': 'Sam Lee'}}]};
          case 'GET /people/people:batchGet':
            final asked = req.uri.queryParametersAll['resourceNames'] ?? const [];
            answer = {
              'responses': [
                for (final r in asked)
                  if (r == 'people/2') {'requestedResourceName': r, 'person': {'names': [{'displayName': 'Jo Park'}], 'photos': [{'url': 'https://photos.example/jo.png'}]}},
              ],
            };
          case 'GET /v1/users/me/spaces/D/spaceReadState':
            answer = {'name': 'users/me/spaces/D/spaceReadState', 'lastReadTime': '2026-11-17T09:30:00Z'};
          case 'GET /v1/users/me/spaces/G/spaceReadState':
          case 'GET /v1/users/me/spaces/S/spaceReadState':
            answer = {'lastReadTime': '2026-11-17T11:00:00Z'};
          case 'GET /v1/spaces/D/messages':
            answer = {'messages': [msg('spaces/D/messages/d1', 'users/2', 'lunch?', '2026-11-17T10:00:00Z', 'spaces/D/threads/t0')]};
          case 'GET /v1/spaces/S/messages':
            answer = {'messages': [msg('spaces/S/messages/s1', 'users/1', 'shipped', '2026-11-17T08:00:00Z', 'spaces/S/threads/ts')]};
          case 'GET /v1/spaces/G/messages':
            final all = [
              msg('spaces/G/messages/g3', 'users/3', 'second thing', '2026-11-17T09:00:00Z', 'spaces/G/threads/t2'),
              msg('spaces/G/messages/g2', 'users/2', 'yes, at 3', '2026-11-17T08:30:00Z', 'spaces/G/threads/t1', reply: true),
              msg('spaces/G/messages/g1', 'users/1', 'meeting today?', '2026-11-17T08:00:00Z', 'spaces/G/threads/t1'),
            ];
            answer = q['pageSize'] == '1' ? {'messages': all.take(1).toList()} : {'messages': all};
          case 'POST /v1/spaces/G/messages':
            posted.add((path: path, query: q, body: body));
            answer = {...msg('spaces/G/messages/g${4 + posted.length}', 'users/1', body['text'] as String, '2026-11-17T09:1${posted.length}:00Z', (body['thread'] as Map?)?['name'] as String? ?? 'spaces/G/threads/new')};
          case 'PATCH /v1/users/me/spaces/D/spaceReadState':
            posted.add((path: path, query: q, body: body));
            answer = {'lastReadTime': body['lastReadTime']};
          default:
            no(404, 'Not found');
        }
      }
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(answer));
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('without a client id it is unavailable and says why', () async {
    final g = GoogleChat(clientId: '', clientSecret: '');
    await g.start(AppState());
    expect(g.state, InboxState.unavailable);
    expect(g.error, contains('no Google app id'));
    expect(await g.begin(), isNull);
  });

  test('signed in through the loopback with PKCE; spaces, a thread, a send, a reply into the thread, read', () async {
    final app = AppState();
    final g = chat();
    await g.start(app);
    expect(g.state, InboxState.signedOut);

    final page = Uri.parse((await g.begin())!);
    expect(page.path, '/auth');
    final p = page.queryParameters;
    expect(p['code_challenge_method'], 'S256');
    expect(p['access_type'], 'offline');
    expect(p['scope']!.split(' '), containsAll(['openid', 'email', 'https://www.googleapis.com/auth/chat.messages', 'https://www.googleapis.com/auth/chat.users.readstate']));
    final redirect = Uri.parse(p['redirect_uri']!);
    expect(redirect.host, '127.0.0.1');
    expect(g.state, InboxState.signingIn);
    challenge = p['code_challenge']!;

    // The browser, sent back by Google: one with the wrong state is turned away, the right one signs in.
    final browser = HttpClient();
    final wrong = await (await browser.getUrl(redirect.replace(queryParameters: {'code': 'good', 'state': 'nope'}))).close();
    expect(wrong.statusCode, 400);
    await wrong.drain<void>();
    final back = await (await browser.getUrl(redirect.replace(queryParameters: {'code': 'good', 'state': p['state']!}))).close();
    expect(back.statusCode, 200);
    expect(await back.transform(utf8.decoder).join(), contains('Signed in'));
    await g.pending;
    browser.close(force: true);
    expect(g.error, isNull);
    expect(g.state, InboxState.ready);
    expect(g.account, 'matt@work.example');
    final kept = jsonDecode(app.choice('googlechat_session', '')) as Map;
    expect((kept['refresh'], kept['me']), ('rt', '1'));
    expect(kept.containsKey('access'), isFalse, reason: 'only the refresh token and the account are kept');
    // The listener is closed once the browser has come back.
    await expectLater(HttpClient().getUrl(redirect).then((r) => r.close()), throwsA(isA<SocketException>()));

    await g.refresh();
    expect(g.chats.map((c) => (c.id, c.title, c.group)), [('spaces/D', 'Jo Park', false), ('spaces/G', 'Jo Park, Sam Lee', true), ('spaces/S', 'Launch team', true)], reason: 'newest first');
    final dm = g.chats.first;
    expect((dm.snippet, dm.unread, dm.avatar), ('lunch?', 1, 'https://photos.example/jo.png'));
    expect(g.chats[1].unread, 0, reason: 'read after it was last active');
    expect(g.chats[2].lastFromMe, isTrue);

    await g.load('spaces/G');
    final ms = g.messagesOf('spaces/G');
    expect(ms.map((m) => (m.text, m.sender, m.mine)), [('meeting today?', '', true), ('yes, at 3', 'Jo Park', false), ('second thing', 'Sam Lee', false)], reason: 'oldest first');
    expect(g.faceOf(ms[1].senderId), 'https://photos.example/jo.png', reason: 'their face by their lines in a group (lib/ui/flat_line.dart)');
    expect((ms[1].replyTo, ms[1].replyText, ms[1].replySender), ('spaces/G/messages/g1', 'meeting today?', 'You'), reason: 'a reply in a thread shows inline');
    expect(ms[2].replyTo, isNull);
    expect(g.canReply, isTrue);

    await g.send('spaces/G', 'new topic');
    expect(posted.last.body, {'text': 'new topic'});
    expect(posted.last.query, isEmpty);
    await g.reply('spaces/G', 'spaces/G/messages/g2', 'see you then');
    expect(posted.last.body, {'text': 'see you then', 'thread': {'name': 'spaces/G/threads/t1'}});
    expect(posted.last.query, {'messageReplyOption': 'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD'});
    final sentReply = g.messagesOf('spaces/G').last;
    expect((sentReply.text, sentReply.state, sentReply.mine, sentReply.replyTo), ('see you then', 'sent', true, 'spaces/G/messages/g1'));

    await g.markRead('spaces/D');
    expect(posted.last.path, '/v1/users/me/spaces/D/spaceReadState');
    expect(posted.last.query, {'updateMask': 'lastReadTime'});
    expect(DateTime.parse(posted.last.body['lastReadTime'] as String).isUtc, isTrue);
    expect(g.chats.first.unread, 0);
    g.dispose();
  });

  test('a refused consent is said, and the listener closes', () async {
    final g = chat();
    await g.start(AppState());
    final p = Uri.parse((await g.begin())!).queryParameters;
    final redirect = Uri.parse(p['redirect_uri']!);
    final c = HttpClient();
    await (await (await c.getUrl(redirect.replace(queryParameters: {'error': 'access_denied', 'state': p['state']!}))).close()).drain<void>();
    await g.pending;
    c.close(force: true);
    expect(g.state, InboxState.signedOut);
    expect(g.error, contains('not allowed'));
    expect(seen, isNot(contains('POST /token')));
    g.dispose();
  });

  test('a kept sign-in uses the refresh token; a 429 waits; a revoked token signs out', () async {
    final app = AppState();
    app.set('googlechat_session', jsonEncode({'refresh': 'rt', 'me': '1', 'email': 'matt@work.example', 'scopes': const []}));
    tooMany = true;
    final g = chat();
    await g.start(app);
    expect(g.state, InboxState.ready);
    await until(() => g.pausedUntil != null);
    expect(refreshes, 1, reason: 'an access token from the refresh token');
    expect(g.error, contains('slow down'));
    final asked = seen.where((s) => s == 'GET /v1/spaces').length;
    await g.refresh();
    expect(seen.where((s) => s == 'GET /v1/spaces').length, asked, reason: 'nothing asked while waiting');
    expect(g.pausedUntil!.difference(DateTime.now()).inSeconds, greaterThan(20));

    // Revoked at Google's end, and the access token has run out: signed out, kept sign-in forgotten.
    final h = chat();
    final app2 = AppState();
    app2.set('googlechat_session', jsonEncode({'refresh': 'rt', 'me': '1', 'email': 'matt@work.example'}));
    revoked = true;
    tooMany = false;
    await h.start(app2);
    await until(() => h.state == InboxState.signedOut);
    expect(h.error, contains('Sign in again'));
    expect(app2.choice('googlechat_session', ''), '');
    g.dispose();
    h.dispose();
  });
}
