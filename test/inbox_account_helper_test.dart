import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/account_helper.dart';
import 'package:ghost_messaging/inbox/cookie_paste.dart';
import 'package:ghost_messaging/inbox/inbox.dart';

/// A stand-in for an account helper (sidecar/ACCOUNT_HELPERS.md): answers what it is asked, and says what the service
/// would.
class FakeHelper implements HelperLink {
  final asked = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast();

  /// What each op answers; throw a [StateError] for the helper's own refusal.
  Object? Function(Map<String, Object?> r) answer = (_) => null;
  bool linked = false;

  void event(Map<String, Object?> e) => _out.add(e);

  @override
  Stream<Map<String, Object?>> get heard => _out.stream;

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    Map<String, Object?> reply;
    try {
      final r = line['op'] == 'status' ? {'linked': linked, 'connected': linked, 'me': 'me-1', 'name': 'Matt', 'handle': linked ? 'matt' : ''} : answer(line);
      reply = {'id': line['id'], 'ok': true, 'result': r};
    } on StateError catch (e) {
      reply = {'id': line['id'], 'ok': false, 'error': e.message};
    }
    scheduleMicrotask(() => _out.add(reply));
  }

  @override
  Future<void> close() async {}

  Iterable<String> get ops => asked.map((r) => '${r['op']}');
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> msg(String chat, String id, String text, {String from = 'jo-1', bool mine = false, int ts = 1763200000000, String name = '', List<Object?> media = const []}) =>
    {'ev': 'message', 'chat': chat, 'group': false, 'id': id, 'from': from, 'name': name, 'mine': mine, 'ts': ts, 'text': text, 'media': media};

/// Messenger, Instagram and LinkedIn (lib/inbox/account_helper.dart; Matt, 2026-11-20: "Let's do the feasible ones but
/// skip X and google voice"): one class for the three, tried against a stand-in for their helpers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    dir = Directory.systemTemp.createTempSync('ghost-helper');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const igCurl = "curl 'https://www.instagram.com/api/v1/direct_v2/inbox/' -H 'accept: */*' -H 'cookie: mid=AAA; csrftoken=tok123; ds_user_id=42; sessionid=42%3Aabc%3A7; other=x' --compressed";

  group('cookies pasted', () {
    test('from a copied request, a header, pairs, or JSON; only those asked for', () {
      const names = {'sessionid', 'csrftoken', 'ds_user_id', 'mid'};
      expect(cookiesIn(igCurl, names: names), {'mid': 'AAA', 'csrftoken': 'tok123', 'ds_user_id': '42', 'sessionid': '42%3Aabc%3A7'});
      expect(cookiesIn('Cookie: sessionid=s; csrftoken=c', names: names), {'sessionid': 's', 'csrftoken': 'c'});
      expect(cookiesIn('sessionid=s; ds_user_id=9', names: names), {'sessionid': 's', 'ds_user_id': '9'});
      expect(cookiesIn('{"sessionid": "s", "junk": "j"}', names: names), {'sessionid': 's'});
      // Chrome's -b form, and Windows cmd's escapes.
      expect(cookiesIn("curl 'https://x' -b 'sessionid=s; csrftoken=c'", names: names), {'sessionid': 's', 'csrftoken': 'c'});
      expect(cookiesIn('curl ^"https://x^" -H ^"cookie: sessionid=s; csrftoken=c^"', names: names), {'sessionid': 's', 'csrftoken': 'c'});
      expect(cookiesMissing({'sessionid': 's'}, const ['sessionid', 'csrftoken']), ['csrftoken']);
    });

    // Matt, 2026-11-21: "linked in keeps automatically signing our sessions out remove the plugin": what it kept goes.
    test('a service no longer offered is forgotten: its folder, with the sign-in in it, is deleted', () async {
      final dir = Directory.systemTemp.createTempSync('gone');
      File('${dir.path}/session.json').writeAsStringSync('{}');
      await AccountHelper.forget(linkedInService, folder: dir.path);
      expect(dir.existsSync(), isFalse);
      await AccountHelper.forget(linkedInService, folder: dir.path); // and nothing there is no trouble
    });

    test('LinkedIn: every cookie of the site, and JSESSIONID without its quotes', () {
      final got = cookiesIn("curl 'https://www.linkedin.com/voyager/api/x' -H 'cookie: bcookie=\"v=2&abc\"; li_at=AQED; JSESSIONID=\"ajax:123\"; lang=v=2'");
      expect(got['li_at'], 'AQED');
      expect(got['JSESSIONID'], 'ajax:123');
      expect(got['bcookie'], 'v=2&abc');
      expect(got['lang'], 'v=2');
    });
  });

  group('a token pasted (Discord, Slack)', () {
    test('Discord: the authorization header of a copied request, bash or cmd, or the token alone', () {
      const t = 'not_a_real_token_just_a_test_value_of_more_than_fifty_letters';
      expect(tokenIn("curl 'https://discord.com/api/v9/users/@me' -H 'accept: */*' -H 'authorization: $t' -H 'cookie: locale=en'"), t);
      expect(tokenIn('curl ^"https://discord.com/api/v9/x^" -H ^"Authorization: $t^"'), t);
      expect(tokenIn(t), t);
      expect(tokenIn("curl 'https://discord.com/api/v9/x' -H 'cookie: locale=en'"), isNull);
    });
    test('Slack: the xoxc- token wherever the request carries it, with the d cookie beside it', () {
      final curl = "curl 'https://acme.slack.com/api/conversations.history' -H 'cookie: d=xoxd-abc%2F1; d-s=17' --data-raw \$'------x\\r\\nContent-Disposition: form-data; name=\"token\"\\r\\n\\r\\nxoxc-111-222-333-abcdef\\r\\n'";
      expect(tokenIn(curl), 'xoxc-111-222-333-abcdef');
      expect(tokenIn('token=xoxc-9-8-7-ff&channel=C1'), 'xoxc-9-8-7-ff');
      final slack = AccountHelper(slackService, link: () async => null);
      expect(slack.cookiesOf(curl), {'d': 'xoxd-abc%2F1', 'd-s': '17', 'token': 'xoxc-111-222-333-abcdef'});
    });
    test('a synced entry already holds the token', () {
      final discord = AccountHelper(discordService, link: () async => null);
      expect(discord.cookiesOf('{"token": "abc"}'), {'token': 'abc'});
    });
  });

  group('a network through its helper', () {
    Future<(AccountHelper, FakeHelper)> started({bool linked = false, HelperService service = instagramService}) async {
      final helper = FakeHelper()..linked = linked;
      final n = AccountHelper(service, link: () async => helper, folder: dir.path);
      await n.start(AppState());
      await settle();
      return (n, helper);
    }

    test('what a helper is signed in with is read back from its session.json, for the account\'s other devices', () async {
      File('${dir.path}/session.json').writeAsStringSync('{"me":"1","name":"Matt","token":"tok-abc","heartbeat":{"x":1}}');
      final (discord, _) = await started(linked: true, service: discordService);
      expect(await discord.heldSignIn(), {'token': 'tok-abc'}, reason: 'Discord keeps its token alone');
      File('${dir.path}/session.json').writeAsStringSync('{"cookies":{"sessionid":"s","csrftoken":"c","ds_user_id":"9","rur":""},"me":"9"}');
      final (ig, _) = await started(linked: true);
      expect(await ig.heldSignIn(), {'sessionid': 's', 'csrftoken': 'c', 'ds_user_id': '9'}, reason: 'cookies, none blank');
      File('${dir.path}/session.json').writeAsStringSync('{"cookies":{"csrftoken":"c"}}');
      expect(await ig.heldSignIn(), isNull, reason: 'missing a cookie the service needs');
      final (out, _) = await started();
      expect(await out.heldSignIn(), isNull, reason: 'not signed in here');
    });

    test('asked to start again while it is starting, it waits for the first: one helper, never two on one folder', () async {
      var made = 0;
      final helper = FakeHelper();
      final gate = Completer<void>();
      final n = AccountHelper(discordService, link: () async {
        made++;
        await gate.future;
        return helper;
      }, folder: dir.path);
      final first = n.start(AppState()), second = n.start(AppState());
      gate.complete();
      await Future.wait([first, second]);
      expect(made, 1);
      expect(n.state, InboxState.signedOut);
    });

    test('a sign-in pasted here is shared for the account\'s other devices; one that came synced is not shared again', () async {
      final shared = <String, Map<String, String>>{};
      AccountHelper.onShare = (id, cookies) => shared[id] = cookies;
      addTearDown(() => AccountHelper.onShare = null);
      final (n, helper) = await started();
      expect(await n.signIn('{"sessionid": "s", "csrftoken": "c", "ds_user_id": "9"}', share: false), isTrue);
      expect(shared, isEmpty);
      expect(await n.signIn("curl 'https://www.instagram.com/' -H 'cookie: sessionid=s2; csrftoken=c2; ds_user_id=9'"), isTrue);
      expect(shared['instagram'], {'sessionid': 's2', 'csrftoken': 'c2', 'ds_user_id': '9'});
    });

    test('X: no sign-in without its 4-digit X Chat passcode; with it, the passcode goes to the helper beside the cookies', () async {
      final (n, helper) = await started(service: xService);
      const curl = "curl 'https://x.com/i/api/1.1/dm/inbox_initial_state.json' -H 'cookie: auth_token=abc; ct0=def; twid=u%3D1'";
      expect(await n.signIn(curl), isFalse);
      expect(n.error, contains('passcode'));
      expect(await n.signIn(curl, passcode: '12a4'), isFalse);
      expect(helper.ops, isNot(contains('sign_in')), reason: 'nothing asked of X without a passcode');
      await n.signIn(curl, passcode: '1234');
      await settle();
      final asked = helper.asked.lastWhere((r) => r['op'] == 'sign_in');
      expect(asked['passcode'], '1234');
      expect((asked['cookies'] as Map)['auth_token'], 'abc');
    });

    test('without its helper it is not in this build', () async {
      final n = AccountHelper(messengerService, link: () async => null, folder: dir.path);
      await n.start(AppState());
      expect(n.state, InboxState.unavailable);
      expect(n.error, contains('Messenger helper'));
    });

    test('signing in: what is missing is said before the helper is asked; then the cookies go to it and nowhere kept', () async {
      final (n, helper) = await started();
      expect(n.state, InboxState.signedOut);

      expect(await n.signIn('hello'), isFalse);
      expect(n.error, contains('No Instagram cookies'));
      expect(await n.signIn('sessionid=s'), isFalse);
      expect(n.error, contains('csrftoken'));
      expect(helper.ops, isNot(contains('sign_in')));

      helper.answer = (r) => switch (r['op']) {
            'sign_in' => {'me': 'me-1', 'name': 'Matt', 'handle': 'matt'},
            'chats' => [
                {'id': 't1', 'title': 'Jo Park', 'group': false, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}], 'avatar': null, 'unread': 2, 'last': 1763200000000, 'snippet': 'see you there', 'snippet_mine': false},
                {'id': 't2', 'title': '', 'group': true, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}, {'id': 'sam-1', 'name': 'Sam'}], 'unread': 0, 'last': 1763100000000},
              ],
            _ => null,
          };
      expect(await n.signIn(igCurl), isTrue);
      await settle();
      expect(n.state, InboxState.ready);
      expect(n.account, '@matt');
      final sent = helper.asked.firstWhere((r) => r['op'] == 'sign_in')['cookies'] as Map;
      expect(sent.keys, containsAll(['sessionid', 'csrftoken', 'ds_user_id', 'mid']));
      expect(sent.containsKey('other'), isFalse);

      // The service's chats, named by it: a group with no title is its people, never an id.
      expect(n.chats.map((c) => (c.title, c.unread, c.snippet, c.group)), [('Jo Park', 2, 'see you there', false), ('Jo Park, Sam', 0, '', true)]);
      // The cookies are the helper's to keep (its session.json): nothing of them in what this class keeps.
      n.flush();
      final kept = File('${dir.path}/chats.json');
      expect(kept.existsSync() ? kept.readAsStringSync() : '', isNot(contains('42%3Aabc')));
      n.dispose();
    });

    test('the helper refusing a sign-in is said in its words', () async {
      final (n, helper) = await started();
      helper.answer = (r) => r['op'] == 'sign_in' ? throw StateError('Instagram asked to confirm it\'s you: finish that in the browser, then sign in here again') : null;
      expect(await n.signIn(igCurl), isFalse);
      expect(n.state, InboxState.signedOut);
      expect(n.error, contains('confirm it\'s you'));
      n.dispose();
    });

    test('messages arrive, are counted unread, sent ones are confirmed once, and reading tells the service', () async {
      final (n, helper) = await started(linked: true);
      expect(n.state, InboxState.ready);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}], 'unread': 0, 'last': 1});
      helper.event(msg('t1', 'm1', 'coming tonight?', ts: 1000));
      helper.event(msg('t1', 'm1', 'coming tonight?', ts: 1000));
      await settle();
      expect(n.messagesOf('t1').map((m) => m.text), ['coming tonight?']);
      expect(n.chats.single.unread, 1);
      expect(n.unreadChats, 1);
      // Their face by their lines in a group (lib/ui/flat_line.dart), as the helper names them.
      expect(n.faceOf('jo-1'), isNull);
      helper.event({'ev': 'name', 'id': 'jo-1', 'name': 'Jo Park', 'avatar': '/tmp/jo.png'});
      await settle();
      expect(n.faceOf('jo-1'), '/tmp/jo.png');

      // Sent from here: shown at once, then said back by the service with its own id. One bubble, not two.
      helper.answer = (r) => r['op'] == 'send' ? {'id': 'm2', 'ts': 2000} : null;
      final sending = n.send('t1', ' on my way ');
      expect(n.messagesOf('t1').last.state, 'sending');
      helper.event(msg('t1', 'm2', 'on my way', from: 'me-1', mine: true, ts: 2000));
      await sending;
      await settle();
      expect(n.messagesOf('t1').map((m) => (m.text, m.mine, m.state)), [('coming tonight?', false, 'sent'), ('on my way', true, 'sent')]);
      expect(helper.asked.firstWhere((r) => r['op'] == 'send')['text'], 'on my way');
      expect(n.chats.single.lastFromMe, isTrue);

      await n.markRead('t1');
      expect(n.chats.single.unread, 0);
      final read = helper.asked.lastWhere((r) => r['op'] == 'read');
      expect((read['to'], read['upto']), ('t1', 'm1'));
      expect(read['id'], isA<int>(), reason: 'the request\'s own id is never a message\'s');

      // Read by them, a reaction, an edit, an unsend.
      helper.event({'ev': 'receipt', 'chat': 't1', 'from': 'jo-1', 'id': 'm2', 'kind': 'read'});
      helper.event({'ev': 'reaction', 'chat': 't1', 'from': 'jo-1', 'target': 'm2', 'emoji': '❤️', 'remove': false});
      helper.event({'ev': 'edited', 'chat': 't1', 'target': 'm1', 'text': 'coming tonight??'});
      await settle();
      final all = n.messagesOf('t1');
      expect(all.first.text, 'coming tonight??');
      expect(all.first.edited, isTrue);
      expect(all.last.reactions.single.emoji, '❤️');
      // Read in the service's own app (a receipt from this account), and a receipt by time alone.
      helper.event(msg('t1', 'm9', 'one more', ts: 9000));
      await settle();
      expect(n.chats.single.unread, 1);
      helper.event({'ev': 'receipt', 'chat': 't1', 'from': 'me-1', 'id': '', 'ts': 9000, 'kind': 'read'});
      await settle();
      expect(n.chats.single.unread, 0);
      helper.event({'ev': 'deleted', 'chat': 't1', 'target': 'm9'});
      await settle();
      helper.event({'ev': 'deleted', 'chat': 't1', 'target': 'm1'});
      await settle();
      expect(n.messagesOf('t1').map((m) => m.id), ['m2']);
      n.dispose();
    });

    test('a message that could not be sent says so, in the helper\'s words', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo', 'group': false, 'unread': 0, 'last': 1});
      await settle();
      helper.answer = (r) => r['op'] == 'send' ? throw StateError('Messenger isn\'t connected') : null;
      await n.send('t1', 'hello');
      expect(n.messagesOf('t1').single.state, 'failed');
      expect(n.error, 'Messenger isn\'t connected');
      n.dispose();
    });

    test('opening a chat brings its history; scrolling back asks for older, until there is none', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo', 'group': false, 'unread': 0, 'last': 5000});
      helper.event(msg('t1', 'm5', 'five', ts: 5000));
      await settle();
      var asks = 0;
      helper.answer = (r) {
        if (r['op'] != 'history') return null;
        asks++;
        return r['before'] == null
            ? {'messages': [{'id': 'm4', 'from': 'jo-1', 'mine': false, 'ts': 4000, 'text': 'four', 'media': []}, {'id': 'm5', 'from': 'jo-1', 'mine': false, 'ts': 5000, 'text': 'five', 'media': []}], 'more': true}
            : r['before'] == 'm4'
                ? {'messages': [{'id': 'm3', 'from': 'me-1', 'mine': true, 'ts': 3000, 'text': 'three', 'media': [], 'reactions': [{'from': 'jo-1', 'emoji': '👍'}]}], 'more': false}
                : {'messages': [], 'more': false};
      };
      await n.load('t1');
      expect(n.messagesOf('t1').map((m) => m.text), ['four', 'five']);
      expect(n.hasOlder('t1'), isTrue);
      await n.load('t1', older: true);
      expect(n.messagesOf('t1').map((m) => m.text), ['three', 'four', 'five']);
      expect(n.messagesOf('t1').first.reactions.single.emoji, '👍', reason: 'history\'s reactions come with it');
      expect(n.hasOlder('t1'), isFalse);
      await n.load('t1', older: true);
      expect(asks, 2, reason: 'nothing older is asked for again');
      n.dispose();
    });

    test('a picture is brought down by its pointer when wanted', () async {
      final (n, helper) = await started(linked: true);
      helper.event(msg('t1', 'm1', '', media: [{'pointer': {'url': 'https://cdn.example/p.jpg'}, 'mime': 'image/jpeg', 'name': 'p.jpg', 'size': 3, 'width': 10, 'height': 10}]));
      await settle();
      final media = n.messagesOf('t1').single.media.single;
      expect(media.kind, 'photo');
      expect(n.chats.single.snippet, 'Photo');
      helper.answer = (r) {
        if (r['op'] == 'download') File('${r['path']}').writeAsBytesSync([1, 2, 3]);
        return null;
      };
      final path = await n.fileOf(media.fileId);
      expect(File(path!).readAsBytesSync(), [1, 2, 3]);
      expect((helper.asked.lastWhere((r) => r['op'] == 'download')['pointer'] as Map)['url'], 'https://cdn.example/p.jpg');
      n.dispose();
    });

    // A picture asks for its file each time it is drawn (lib/ui/inbox_ui.dart), so it was asked for again while the first
    // download was still coming: two ran at once into one path, sharing the helper's ".part" file, and the second failed
    // with "rename …/discord/files/330240540.png.part …: no such file or directory".
    test('a picture asked for again and again while it comes is downloaded once', () async {
      final (n, helper) = await started(linked: true, service: discordService);
      helper.event(msg('t1', 'm1', '', media: [{'pointer': {'url': 'https://cdn.example/p.png'}, 'mime': 'image/png', 'name': 'p.png', 'size': 3, 'width': 10, 'height': 10}]));
      await settle();
      final id = n.messagesOf('t1').single.media.single.fileId;
      helper.answer = (r) {
        if (r['op'] == 'download') File('${r['path']}').writeAsBytesSync([1, 2, 3]);
        return null;
      };
      n.wantFile(id);
      n.wantFile(id);
      final paths = await Future.wait([n.fileOf(id), n.fileOf(id), n.fileOf(id)]);
      expect(paths.toSet(), hasLength(1));
      expect(File(paths.first!).readAsBytesSync(), [1, 2, 3]);
      expect(helper.asked.where((r) => r['op'] == 'download'), hasLength(1));
      // Once it is here it is not asked for again, and a later ask starts no second download.
      expect(await n.fileOf(id), paths.first);
      expect(helper.asked.where((r) => r['op'] == 'download'), hasLength(1));
      n.dispose();
    });

    test('a reply says who and what it answers: from the message kept here, else from what the helper sent (GMFB-44)', () async {
      final (n, helper) = await started(linked: true, service: discordService);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}], 'unread': 0, 'last': 1});
      helper.event(msg('t1', 'm1', '', ts: 1000, media: [{'pointer': {'url': 'https://cdn.example/p.jpg'}, 'mime': 'image/jpeg', 'name': 'p.jpg', 'size': 3, 'width': 10, 'height': 10}]));
      helper.event(msg('t1', 'm2', 'mine', from: 'me-1', mine: true, ts: 2000));
      InboxMessage reply(String id) => n.messagesOf('t1').firstWhere((m) => m.id == id);
      // To a picture kept here, of which the helper sent the id alone.
      helper.event({...msg('t1', 'm3', 'nice', from: 'me-1', mine: true, ts: 3000), 'quote': {'id': 'm1'}});
      // To one of this account's own.
      helper.event({...msg('t1', 'm4', 'what?', ts: 4000), 'quote': {'id': 'm2', 'text': 'mine', 'from': 'me-1', 'name': 'Matt'}});
      // To ones older than what is loaded: the helper's words and name, or the kind of thing it was.
      helper.event({...msg('t1', 'm5', 'yes', ts: 5000), 'quote': {'id': 'old-1', 'text': 'lunch on friday?', 'from': 'ann-1', 'name': 'Ann Lee'}});
      helper.event({...msg('t1', 'm6', 'ha', ts: 6000), 'quote': {'id': 'old-2', 'from': 'jo-1', 'mime': 'video/mp4'}});
      // Nothing known of it at all.
      helper.event({...msg('t1', 'm7', 'ok', ts: 7000), 'quote': {'id': 'old-3'}});
      await settle();
      expect((reply('m3').replyTo, reply('m3').replySender, reply('m3').replyText), ('m1', 'Jo Park', 'Photo'));
      expect((reply('m4').replySender, reply('m4').replyText), ('You', 'mine'));
      expect((reply('m5').replySender, reply('m5').replyText), ('Ann Lee', 'lunch on friday?'));
      expect((reply('m6').replySender, reply('m6').replyText), ('Jo Park', 'Video'));
      expect((reply('m7').replyTo, reply('m7').replySender, reply('m7').replyText), ('old-3', null, null));
      n.dispose();
    });

    test('the service ending the session signs out here, keeping what was read, and says why', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo', 'group': false, 'unread': 0, 'last': 1});
      helper.event(msg('t1', 'm1', 'hi'));
      await settle();
      helper.event({'ev': 'unlinked', 'error': 'Instagram signed this session out.'});
      await settle();
      expect(n.state, InboxState.signedOut);
      expect(n.error, 'Instagram signed this session out.');
      expect(n.messagesOf('t1'), hasLength(1));
      n.dispose();
    });

    test('what has come is there again after a restart; signing out forgets it and tells the helper', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 1, 'last': 1000});
      helper.event(msg('t1', 'm1', 'hi', ts: 1000));
      await settle();
      n.flush();
      n.dispose();

      final again = FakeHelper()..linked = true;
      final n2 = AccountHelper(instagramService, link: () async => again, folder: dir.path);
      await n2.start(AppState());
      await settle();
      expect(n2.chats.single.title, 'Jo Park');
      expect(n2.messagesOf('t1').single.text, 'hi');

      await n2.signOut();
      expect(again.ops, contains('unlink'));
      expect(n2.state, InboxState.signedOut);
      expect(n2.chats, isEmpty);
      n2.flush();
      expect(jsonDecode(File('${dir.path}/chats.json').readAsStringSync())['messages'], isEmpty);
      n2.dispose();
    });

    // GMFB-62 (Matt, Android 0.12.26): "Every time i tab back into the app Facebook messenger messages are getting
    // marked as unread". Back in front the helper connects again and the service's list is asked for; its count was
    // taken over what was read here, though nothing newer had come.
    test('a chat read here stays read when the service lists it unread again with nothing newer (GMFB-62)', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 0, 'last': 1000});
      helper.event(msg('t1', 'm1', 'hi', ts: 2000));
      await settle();
      expect(n.chats.single.unread, 1);
      await n.markRead('t1');
      expect(helper.asked.where((r) => r['op'] == 'read').length, 1);

      // The app comes back to the front: connected again, and the service's own list still says one waits.
      helper.answer = (r) => r['op'] == 'chats' ? [{'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 1, 'last': 2000}] : null;
      helper.event({'ev': 'connected'});
      await settle();
      expect(n.chats.single.unread, 0, reason: 'read here, and nothing newer than what was read');
      expect(helper.asked.where((r) => r['op'] == 'read').map((r) => (r['to'], r['upto'])), [('t1', 'm1'), ('t1', 'm1')], reason: 'the service is told again');
      // Listed so again: not told a third time.
      helper.event({'ev': 'connected'});
      await settle();
      expect(n.chats.single.unread, 0);
      expect(helper.asked.where((r) => r['op'] == 'read').length, 2);
      // The same message said again by the service is not counted again.
      helper.event({'ev': 'deleted', 'chat': 't1', 'target': 'm1'});
      helper.event(msg('t1', 'm1', 'hi', ts: 2000));
      await settle();
      expect(n.chats.single.unread, 0, reason: 'older than what was read');

      // Something newer than what was read is unread, as before.
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 1, 'last': 3000});
      await settle();
      expect(n.chats.single.unread, 1);
      n.dispose();
    });

    test('a message that arrives while its chat is open is told to the service as read (GMFB-62)', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 0, 'last': 1000});
      await settle();
      n.watching = 't1';
      helper.event(msg('t1', 'm1', 'are you there?', ts: 2000));
      await settle();
      expect(n.chats.single.unread, 0, reason: 'it is on screen');
      // The open chat marks itself read as each message arrives (lib/ui/inbox_ui.dart).
      await n.markRead('t1');
      expect(helper.asked.where((r) => r['op'] == 'read').map((r) => (r['to'], r['upto'])), [('t1', 'm1')]);
      // And only once for it.
      await n.markRead('t1');
      expect(helper.asked.where((r) => r['op'] == 'read').length, 1);
      // Closed, and listed by the service as unread with nothing newer: still read.
      n.watching = null;
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 1, 'last': 2000});
      await settle();
      expect(n.chats.single.unread, 0);
      n.dispose();
    });

    // GMFB-61 (Matt, Android 0.12.25): "I'd like to be able to lookup contacts from connected platforms to start new
    // chats for example slack or telegram".
    test('people to start a chat with: those there is a chat with already, found by name (GMFB-61)', () async {
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}], 'unread': 0, 'last': 2});
      helper.event({'ev': 'chat', 'id': 't2', 'title': 'Trip', 'group': true, 'members': [{'id': 'jo-1', 'name': 'Jo Park'}, {'id': 'sam-1', 'name': 'Sam Joyce'}], 'unread': 0, 'last': 1});
      await settle();
      expect(await n.findPeople(''), isEmpty, reason: 'nobody for nothing typed');
      final found = await n.findPeople('jo');
      expect(found.map((c) => (c.network, c.id, c.name)), [('instagram', 'jo-1', 'Jo Park')], reason: 'Sam is only met in a group: no chat to open');
      expect(helper.ops, isNot(contains('people')), reason: 'Instagram\'s helper lists no people');
      expect(await n.chatWith(found.single), 't1');
      expect(await n.chatWith(const InboxContact(network: 'instagram', id: 'sam-1', name: 'Sam Joyce')), isNull);
      expect(helper.ops, isNot(contains('open')));
      expect(n.contacts, isEmpty, reason: 'who is a contact says who is a stranger (the Human check plugin): unchanged');
      n.dispose();
    });

    test('Slack: the workspace is asked for people, and a chat is opened with one there is none with (GMFB-61)', () async {
      final helper = FakeHelper()..linked = true;
      final n = AccountHelper(slackService, link: () async => helper, folder: dir.path);
      await n.start(AppState());
      await settle();
      helper.event({'ev': 'chat', 'id': 'T1-D1', 'title': 'Ann Lee', 'group': false, 'members': [{'id': 'UANN', 'name': 'Ann Lee'}], 'unread': 0, 'last': 2});
      await settle();
      helper.answer = (r) => switch (r['op']) {
            'people' => [
                {'id': 'UANN', 'name': 'Ann Lee', 'handle': 'ann', 'avatar': null},
                {'id': 'UBEN', 'name': 'Ben Okoro', 'handle': 'benno', 'avatar': null},
              ],
            'open' => {'id': 'T1-D2'},
            _ => null,
          };
      final found = await n.findPeople('benno');
      expect(helper.asked.lastWhere((r) => r['op'] == 'people')['query'], 'benno');
      expect(found.map((c) => (c.id, c.name, c.handle)), [('UBEN', 'Ben Okoro', '@benno')]);
      expect(await n.chatWith(found.single), 'T1-D2');
      expect(helper.asked.lastWhere((r) => r['op'] == 'open')['who'], 'UBEN');
      // Someone there is a chat with already: that chat, and Slack is not asked to open one.
      final ann = (await n.findPeople('ann')).single;
      expect(await n.chatWith(ann), 'T1-D1');
      expect(helper.asked.where((r) => r['op'] == 'open').length, 1);
      // A helper from before `people` (it answers that it does not know the op): what is known here still answers.
      helper.answer = (r) => r['op'] == 'people' ? throw StateError('the Slack helper does not know "people"') : null;
      expect((await n.findPeople('ann')).map((c) => c.name), ['Ann Lee']);
      n.dispose();
    });

    // Matt, 2026-11-23: "messages are being un marked from read when relaunching the app". The file was written two
    // seconds after the last change, however long changes kept coming: with a busy account (names, messages elsewhere,
    // reactions, each a change) a chat read was never written, and the app opened again with it unread.
    test('a chat read is on the disk soon, however many changes keep coming after it', () async {
      final after = AccountHelper.saveAfter, within = AccountHelper.saveWithin;
      AccountHelper.saveAfter = const Duration(milliseconds: 150);
      AccountHelper.saveWithin = const Duration(milliseconds: 500);
      addTearDown(() {
        AccountHelper.saveAfter = after;
        AccountHelper.saveWithin = within;
      });
      final (n, helper) = await started(linked: true);
      helper.event({'ev': 'chat', 'id': 't1', 'title': 'Jo Park', 'group': false, 'unread': 0, 'last': 1000});
      helper.event(msg('t1', 'm1', 'hi', ts: 1000));
      await settle();
      expect(n.chats.single.unread, 1);
      await n.markRead('t1');
      // Something else changes every 50 ms for two seconds: never 150 ms of quiet.
      for (var i = 0; i < 40; i++) {
        helper.event(msg('t2', 'x$i', 'elsewhere', mine: true, ts: 2000 + i));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // The app is closed without a word (no flush, as a quit gives none) and opened again.
      final again = FakeHelper()..linked = true;
      final n2 = AccountHelper(instagramService, link: () async => again, folder: dir.path);
      await n2.start(AppState());
      await settle();
      expect(n2.chats.where((c) => c.id == 't1').map((c) => c.unread), [0], reason: 'read before the app closed');
      n2.dispose();
      n.dispose();
    });

    test('only the newest messages of a chat are kept on disk', () async {
      final (n, helper) = await started(linked: true);
      for (var i = 0; i < 450; i++) {
        helper.event(msg('t1', 'm$i', 'n$i', ts: 1000 + i));
      }
      await settle();
      expect(n.messagesOf('t1'), hasLength(450));
      n.flush();
      final kept = (jsonDecode(File('${dir.path}/chats.json').readAsStringSync())['messages'] as Map)['t1'] as List;
      expect(kept, hasLength(400));
      expect((kept.last as Map)['id'], 'm449');
      n.dispose();
    });

    test('each service says what it is and warns in its own name', () {
      for (final s in [messengerService, instagramService, linkedInService]) {
        expect(s.warning, contains('${s.name} doesn\'t support or allow other apps'));
        expect(s.needed, isNotEmpty);
      }
      expect(Inbox.instance.networks.map((n) => n.id), containsAll(['messenger', 'instagram']));
      Inbox.instance = null;
    });
  });

  test('a helper\'s log: warnings and its own request lines are kept, the rest is not', () {
    expect(helperLogLine('{"level":"info","message":"asked","op":"send","req":4}'), 'info asked op=send req=4');
    expect(helperLogLine('{"level":"debug","message":"socket frame"}'), isNull);
    expect(helperLogLine('{"level":"warn","message":"reconnecting","error":"eof"}'), 'warn reconnecting error=eof');
  });
}
