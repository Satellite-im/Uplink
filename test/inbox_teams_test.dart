import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/teams.dart';

/// Microsoft Teams chats (lib/inbox/teams.dart; Matt, 2026-11-17: "Let's add support for matrix, microsoft teams and
/// google chat") against a stand-in for Microsoft's sign-in and Graph on this computer: the device code asked for,
/// waited on (pending, slow down) and turned into a token; a run-out token renewed with the refresh token; the chats
/// listed newest first, a one-on-one and a group; a chat's messages read with their HTML made plain; a message sent,
/// a reply quoting another, a reaction; the chat marked read; a 429 waited out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every request with a 400 of its own: these go to the stand-in on this computer.
  HttpOverrides.global = null;
  late HttpServer server;
  late String base;
  final seen = <String>[];
  final posted = <String, List<Map>>{};
  final grants = <String>[];
  late List<String> devicePolls;
  var valid = <String>{};
  var throttle = false;

  Map<String, Object?> member(String id, String name) => {'@odata.type': '#microsoft.graph.aadUserConversationMember', 'userId': id, 'displayName': name, 'tenantId': 'tenant-1'};

  setUp(() async {
    seen.clear();
    posted.clear();
    grants.clear();
    devicePolls = ['authorization_pending', 'slow_down', 'ok'];
    valid = {};
    throttle = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      seen.add('${req.method} $path');
      final raw = await utf8.decoder.bind(req).join();
      Object? answer = const {};
      var code = 200;
      void reply() {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(answer));
      }

      if (path.startsWith('/login/')) {
        final form = Uri.splitQueryString(raw);
        expect(form['client_id'], 'app-1');
        if (path == '/login/oauth2/v2.0/devicecode') {
          expect(form['scope'], 'offline_access User.Read Chat.ReadWrite ChatMessage.Send');
          answer = {'device_code': 'dev-1', 'user_code': 'GHOST123', 'verification_uri': 'https://microsoft.com/devicelogin', 'expires_in': 900, 'interval': 0};
        } else if (form['grant_type'] == 'urn:ietf:params:oauth:grant-type:device_code') {
          grants.add('device');
          final next = devicePolls.removeAt(0);
          if (next == 'ok') {
            valid.add('a1');
            // Run out already: the first call to Graph renews it with the refresh token.
            answer = {'access_token': 'a1', 'refresh_token': 'r1', 'expires_in': 30, 'token_type': 'Bearer'};
          } else if (next == 'admin') {
            code = 400;
            answer = {'error': 'invalid_grant', 'error_description': 'AADSTS65001: The user or administrator has not consented to use the application.', 'error_codes': [65001]};
          } else {
            code = 400;
            answer = {'error': next};
          }
        } else if (form['grant_type'] == 'refresh_token') {
          grants.add('refresh ${form['refresh_token']}');
          final n = grants.where((g) => g.startsWith('refresh')).length + 1;
          valid.add('a$n');
          answer = {'access_token': 'a$n', 'refresh_token': 'r$n', 'expires_in': 3600};
        }
        reply();
        await req.response.close();
        return;
      }

      final bearer = (req.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
      if (!valid.contains(bearer)) {
        code = 401;
        answer = {'error': {'code': 'InvalidAuthenticationToken', 'message': 'Access token has expired.'}};
      } else if (throttle) {
        code = 429;
        req.response.headers.set('retry-after', '120');
        answer = {'error': {'code': 'TooManyRequests', 'message': 'Too many requests'}};
      } else {
        final body = raw.isEmpty ? const {} : jsonDecode(raw) as Map;
        switch ('${req.method} $path') {
          case 'GET /graph/me':
            answer = {'id': 'me-1', 'displayName': 'Matt', 'userPrincipalName': 'matt@contoso.example'};
          case 'GET /graph/me/chats':
            expect(req.uri.queryParameters[r'$expand'], 'members,lastMessagePreview');
            expect(req.uri.queryParameters[r'$orderby'], 'lastMessagePreview/createdDateTime desc');
            if (req.uri.queryParameters['page'] == '2') {
              answer = {
                'value': [
                  {
                    'id': '19:group@thread.v2',
                    'chatType': 'group',
                    'topic': 'Launch crew',
                    'members': [member('me-1', 'Matt'), member('u-2', 'Jo Park'), member('u-3', 'Sam Lee')],
                    'viewpoint': {'lastMessageReadDateTime': '2026-11-17T10:00:00Z'},
                    'lastMessagePreview': {'createdDateTime': '2026-11-17T09:00:00Z', 'body': {'contentType': 'text', 'content': 'shipped'}, 'from': {'user': {'id': 'u-3', 'displayName': 'Sam Lee'}}},
                  },
                ],
              };
            } else {
              answer = {
                'value': [
                  {
                    'id': '19:me-1_u-2@unq.gbl.spaces',
                    'chatType': 'oneOnOne',
                    'topic': null,
                    'members': [member('me-1', 'Matt'), member('u-2', 'Jo Park')],
                    'viewpoint': {'lastMessageReadDateTime': '2026-11-17T08:00:00Z'},
                    'lastMessagePreview': {'createdDateTime': '2026-11-17T12:00:00Z', 'body': {'contentType': 'html', 'content': '<p>See you at <b>7</b> &amp; bring snacks</p>'}, 'from': {'user': {'id': 'u-2', 'displayName': 'Jo Park'}}},
                  },
                ],
                '@odata.nextLink': '$base/graph/me/chats?\$expand=members,lastMessagePreview&\$orderby=lastMessagePreview/createdDateTime%20desc&page=2',
              };
            }
          case 'GET /graph/chats/19:me-1_u-2@unq.gbl.spaces/messages':
            expect(req.uri.queryParameters[r'$top'], '50');
            answer = {
              'value': [
                {
                  'id': 'm3', 'messageType': 'message', 'createdDateTime': '2026-11-17T12:00:00Z',
                  'from': {'user': {'id': 'u-2', 'displayName': 'Jo Park'}},
                  'body': {'contentType': 'html', 'content': '<p>See you at <b>7</b> &amp; bring snacks</p><ul><li>chips</li><li>dip</li></ul><img src="$base/graph/chats/x/messages/m3/hostedContents/h1/\$value">'},
                  'reactions': [{'reactionType': 'like', 'user': {'user': {'id': 'me-1'}}}],
                },
                {'id': 'm2', 'messageType': 'systemEventMessage', 'createdDateTime': '2026-11-17T11:00:00Z', 'eventDetail': {'@odata.type': '#microsoft.graph.membersAddedEventMessageDetail', 'members': [{'id': 'u-2', 'displayName': 'Jo Park'}]}},
                {'id': 'm1', 'messageType': 'message', 'createdDateTime': '2026-11-17T10:00:00Z', 'from': {'user': {'id': 'me-1', 'displayName': 'Matt'}}, 'body': {'contentType': 'html', 'content': 'are you coming<br>tonight?'}},
                {'id': 'm0', 'messageType': 'message', 'createdDateTime': '2026-11-17T09:00:00Z', 'deletedDateTime': '2026-11-17T09:01:00Z', 'body': {'contentType': 'html', 'content': ''}},
              ],
            };
          case 'POST /graph/chats/19:me-1_u-2@unq.gbl.spaces/messages':
            (posted['send'] ??= []).add(body);
            final n = posted['send']!.length;
            answer = {
              'id': 'm${3 + n}', 'messageType': 'message', 'createdDateTime': '2026-11-17T12:0$n:00Z',
              'from': {'user': {'id': 'me-1', 'displayName': 'Matt'}}, 'body': body['body'], 'attachments': body['attachments'] ?? const [],
            };
          case 'POST /graph/chats/19:me-1_u-2@unq.gbl.spaces/markChatReadForUser':
            (posted['read'] ??= []).add(body);
            code = 204;
            answer = '';
          case 'POST /graph/chats/19:me-1_u-2@unq.gbl.spaces/messages/m3/setReaction':
            (posted['react'] ??= []).add(body);
            code = 204;
            answer = '';
          case 'POST /graph/users/me-1/chats/19:me-1_u-2@unq.gbl.spaces/messages/m4/softDelete':
            code = 204;
            answer = '';
          case 'GET /graph/chats/x/messages/m3/hostedContents/h1/\$value':
            req.response.headers.contentType = ContentType('image', 'png');
            req.response.add([137, 80, 78, 71]);
            await req.response.close();
            return;
          default:
            code = 404;
            answer = {'error': {'code': 'NotFound', 'message': 'no'}};
        }
      }
      if (code == 204) {
        req.response.statusCode = 204;
      } else {
        reply();
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  Teams make({String clientId = 'app-1'}) =>
      Teams(clientId: clientId, login: '$base/login', graph: '$base/graph', slowDown: Duration.zero, folder: '${Directory.systemTemp.path}/ghost-teams-test-${server.port}');

  test('the device code, waited on, then a token; chats newest first; messages made plain; send, reply, react, read, delete', () async {
    final app = AppState();
    final t = make();
    await t.start(app);
    expect(t.state, InboxState.signedOut);

    final code = await t.begin();
    expect((code!.user, code.page), ('GHOST123', 'https://microsoft.com/devicelogin'));
    expect(t.step, InboxStep.elsewhere);
    await until(() => t.state == InboxState.ready);
    expect(grants.take(3), ['device', 'device', 'device'], reason: 'pending, slow down, then the token');
    expect(grants, contains('refresh r1'), reason: 'the first token had run out: renewed before Graph was called');
    expect(t.account, 'matt@contoso.example');
    final kept = jsonDecode(app.choice('teams_session', '')) as Map;
    expect(kept['refresh'], 'r2');
    expect(kept.containsKey('access'), isFalse, reason: 'only the refresh token is kept');

    await t.refresh();
    expect(t.chats.map((c) => c.title), ['Jo Park', 'Launch crew'], reason: 'both pages, newest first, a one-on-one named for the other');
    final jo = t.chats.first, crew = t.chats.last;
    expect((jo.group, jo.unread, jo.snippet), (false, 1, 'See you at 7 & bring snacks'));
    expect((crew.group, crew.unread, crew.snippet), (true, 0, 'Sam: shipped'), reason: 'read after its last message');

    await t.load(jo.id);
    final ms = t.messagesOf(jo.id);
    expect(ms.map((m) => m.text), ['are you coming\ntonight?', 'Jo Park joined', 'See you at 7 & bring snacks\n• chips\n• dip'], reason: 'oldest first, the deleted one gone, the event a plain line');
    expect(ms.map((m) => m.event), [false, true, false], reason: 'something that happened, not something said');
    expect(ms.first.mine, isTrue);
    expect(ms.last.sender, 'Jo Park');
    expect(ms.last.senderId, isNotEmpty);
    expect(ms.last.reactions.single.emoji, '👍');
    expect(ms.last.reactions.single.mine, isTrue);
    final pic = ms.last.media.single;
    expect(pic.kind, 'photo');
    final file = await t.fileOf(pic.fileId);
    expect(File(file!).readAsBytesSync(), [137, 80, 78, 71]);

    await t.send(jo.id, 'on my way');
    expect(posted['send']!.first, {'body': {'contentType': 'text', 'content': 'on my way'}});
    final mine = t.messagesOf(jo.id).last;
    expect((mine.id, mine.text, mine.mine, mine.state), ('m4', 'on my way', true, 'sent'));
    expect(t.chats.first.snippet, 'on my way');

    await t.reply(jo.id, 'm3', 'yes <chips>');
    final r = posted['send']!.last;
    expect((r['body'] as Map)['content'], '<attachment id="m3"></attachment>yes &lt;chips&gt;');
    final att = (r['attachments'] as List).single as Map;
    expect((att['contentType'], att['id']), ('messageReference', 'm3'));
    final replied = t.messagesOf(jo.id).last;
    expect((replied.text, replied.replyTo), ('yes <chips>', 'm3'));

    await t.react(jo.id, 'm3', '🔥');
    expect(posted['react'], [{'reactionType': '🔥'}]);
    expect(t.messagesOf(jo.id).firstWhere((m) => m.id == 'm3').reactions.map((x) => x.emoji), ['👍', '🔥']);

    await t.markRead(jo.id);
    expect(posted['read'], [{'user': {'id': 'me-1', 'tenantId': 'tenant-1'}}]);
    expect(t.chats.first.unread, 0);

    expect(t.canDeleteForEveryone(jo.id, mine), isTrue);
    await t.deleteMessage(jo.id, 'm4', forEveryone: true);
    expect(seen, contains('POST /graph/users/me-1/chats/19:me-1_u-2@unq.gbl.spaces/messages/m4/softDelete'));
    expect(t.messagesOf(jo.id).any((m) => m.id == 'm4'), isFalse);

    // Started again later from what was kept: the refresh token alone brings it back.
    t.dispose();
    final again = make();
    await again.start(app);
    expect(again.state, InboxState.ready);
    await again.refresh();
    expect(again.chats.length, 2);
    expect(grants.last, 'refresh r2');
    again.dispose();
  });

  test('a token refused by Graph is renewed once with the refresh token', () async {
    final app = AppState();
    final t = make();
    await t.begin();
    await until(() => t.state == InboxState.ready);
    await t.refresh();
    final before = grants.where((g) => g.startsWith('refresh')).length;
    valid.clear(); // Graph says the access token has expired.
    await t.refresh();
    expect(grants.where((g) => g.startsWith('refresh')).length, before + 1);
    expect(t.error, isNull);
    expect(t.chats.length, 2);
    t.dispose();
    expect(app, isNotNull);
  });

  test('a 429 waits as long as Retry-After says', () async {
    final t = make();
    await t.begin();
    await until(() => t.state == InboxState.ready);
    await t.refresh();
    throttle = true;
    await t.refresh();
    expect(t.error, contains('slow down'));
    expect(t.waitingUntil.isAfter(DateTime.now().add(const Duration(seconds: 100))), isTrue);
    final calls = seen.length;
    throttle = false;
    await t.refresh();
    await t.load(t.chats.first.id);
    expect(seen.length, calls, reason: 'nothing asked of Graph until the wait is over');
    t.dispose();
  });

  test('an organisation that needs its admin to approve the app says so', () async {
    devicePolls = ['authorization_pending', 'admin'];
    final t = make();
    await t.begin();
    await until(() => t.state == InboxState.signedOut);
    expect(t.error, Teams.adminNeeded);
    expect(t.code, isNull);
    t.dispose();
  });

  test('a code that runs out is said, and Teams is unavailable in a build with no app id', () async {
    devicePolls = ['expired_token'];
    final t = make();
    await t.begin();
    await until(() => t.state == InboxState.signedOut);
    expect(t.error, contains('ran out'));
    t.dispose();

    final none = make(clientId: '');
    await none.start(AppState());
    expect(none.state, InboxState.unavailable);
    expect(none.error, contains('no Microsoft app id'));
    expect(await none.begin(), isNull);
    expect(seen.where((x) => x == 'POST /login/oauth2/v2.0/devicecode').length, 1, reason: 'only the first Teams asked');
    none.dispose();
  });
}
