import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/matrix.dart';
import 'package:ghost_messaging/ui/inbox_signin_matrix.dart';

import 'support/list_harness.dart' show loadSheet, pumpScreen;

/// A stand-in for the Matrix helper (sidecar/matrix/PROTOCOL.md): answers what it is asked, and says what a homeserver
/// would.
class FakeHelper implements MatrixLink {
  final asked = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast();
  Object? Function(Map<String, Object?> r) answer = (_) => null;
  Map<String, Object?> status = const {'logged_in': false};

  void event(Map<String, Object?> e) => _out.add(e);

  @override
  Stream<Map<String, Object?>> get heard => _out.stream;

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    Object? r;
    String? error;
    try {
      r = line['op'] == 'status' ? status : answer(line);
    } catch (e) {
      error = '$e';
    }
    scheduleMicrotask(() => _out.add(error == null ? {'id': line['id'], 'ok': true, 'result': r} : {'id': line['id'], 'ok': false, 'error': error}));
  }

  Map<String, Object?> last(String op) => asked.lastWhere((r) => r['op'] == op);
  Iterable<Map<String, Object?>> all(String op) => asked.where((r) => r['op'] == op);

  @override
  Future<void> close() async {}
}

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const me = '@matt:matrix.org';
const signedIn = {'logged_in': true, 'user_id': me, 'device_id': 'GHOST1', 'homeserver': 'https://matrix-client.matrix.org', 'name': 'Matt', 'verified': false};

Map<String, Object?> dm({int ts = 1763300000000, int unread = 1, bool invite = false}) => {
      'id': '!dm:matrix.org', 'title': 'Jo Park', 'avatar': null, 'members': ['@jo:matrix.org'], 'is_direct': true, 'with': '@jo:matrix.org',
      'invite': invite, 'encrypted': true, 'unread': unread, 'ts': ts,
      'last': {'id': r'$m1', 'from': '@jo:matrix.org', 'text': 'are you coming tonight?', 'ts': ts, 'mine': false, 'media': false, 'undecryptable': false},
    };

Map<String, Object?> group({int ts = 1763200000000}) => {
      'id': '!crew:matrix.org', 'title': 'Weekend crew', 'avatar': '/tmp/crew.img', 'members': ['@jo:matrix.org', '@sam:matrix.org'], 'is_direct': false,
      'invite': false, 'encrypted': false, 'unread': 0, 'ts': ts,
      'last': {'id': r'$g1', 'from': '@sam:matrix.org', 'text': '', 'ts': ts, 'mine': false, 'media': true, 'undecryptable': false},
    };

Map<String, Object?> msg(String room, String id, {String from = '@jo:matrix.org', String name = 'Jo Park', String text = 'hi', int ts = 1763300000000, String? replyTo, bool undecryptable = false, List media = const []}) => {
      'ev': 'message', 'room': room, 'id': id, 'from': from, 'name': name, 'mine': from == me, 'ts': ts, 'text': text, 'kind': 'm.text', 'media': media,
      'reply_to': ?replyTo, if (undecryptable) 'undecryptable': true,
    };

/// Matrix through mautrix-go (lib/inbox/matrix.dart; Matt, 2026-11-17: "Let's add support for matrix, microsoft teams
/// and google chat"): signed in, its direct chats and group rooms listed, messages in and out, replies, read, reactions,
/// deletes, signed out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('matrix');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('signed in with a password; a direct chat and a group, newest first; a message in and out, a reply, read, a reaction, a deletion; signed out', () async {
    final helper = FakeHelper();
    helper.answer = (r) => switch (r['op']) {
          'login_password' => signedIn,
          'rooms' => [group(), dm()],
          'send' => {'id': r['reply_to'] == null ? r'$out1' : r'$out2'},
          'react' => {'id': r'$react1'},
          _ => null,
        };
    final m = Matrix(link: () async => helper, folder: dir.path);
    await m.start(AppState());
    await settle();
    expect(m.state, InboxState.signedOut);
    expect(m.step, InboxStep.credentials);

    await m.signInWithPassword('', '@matt:matrix.org', 'hunter2');
    await settle();
    final login = helper.last('login_password');
    expect((login['homeserver'], login['user'], login['password']), ('', '@matt:matrix.org', 'hunter2'));
    expect(m.state, InboxState.ready);
    expect(m.userId, me);
    expect(m.account, 'Matt (@matt:matrix.org)');

    // The rooms, newest first: the direct chat is a person, the group a group chat.
    expect([for (final c in m.chats) (c.id, c.title, c.group, c.unread, c.snippet)], [
      ('!dm:matrix.org', 'Jo Park', false, 1, 'are you coming tonight?'),
      ('!crew:matrix.org', 'Weekend crew', true, 0, 'Attachment'),
    ]);
    expect(m.chats.last.avatar, '/tmp/crew.img');

    // A message in.
    helper.event(msg('!dm:matrix.org', r'$m1', text: 'are you coming tonight?'));
    helper.event(msg('!crew:matrix.org', r'$g2', from: '@sam:matrix.org', name: 'Sam', text: 'tent is packed', ts: 1763300100000));
    await settle();
    expect(m.messagesOf('!dm:matrix.org').single.text, 'are you coming tonight?');
    final g = m.messagesOf('!crew:matrix.org').single;
    expect((g.sender, g.mine), ('Sam', false));
    expect(m.chats.first.id, '!crew:matrix.org', reason: 'the group\'s message is newer now');

    // A message out: sending at once, sent with the event id the server gave; the sync's echo of it is not a second one.
    final sending = m.send('!dm:matrix.org', 'on my way');
    expect(m.messagesOf('!dm:matrix.org').last.state, 'sending');
    await sending;
    expect(helper.last('send')['text'], 'on my way');
    helper.event(msg('!dm:matrix.org', r'$out1', from: me, name: 'Matt', text: 'on my way', ts: 1763300200000));
    await settle();
    final out = m.messagesOf('!dm:matrix.org');
    expect([for (final x in out) (x.id, x.text, x.mine, x.state)], [(r'$m1', 'are you coming tonight?', false, 'sent'), (r'$out1', 'on my way', true, 'sent')]);

    // A reply, quoting what it answers.
    await m.reply('!dm:matrix.org', r'$m1', 'yes, at eight');
    expect((helper.last('send')['reply_to'], helper.last('send')['text']), (r'$m1', 'yes, at eight'));
    final reply = m.messagesOf('!dm:matrix.org').last;
    expect((reply.id, reply.replyTo, reply.replyText, reply.replySender), (r'$out2', r'$m1', 'are you coming tonight?', 'Jo Park'));
    expect(m.canReply, isTrue);

    // Read: the read marker up to the last message from them, and the unread count cleared.
    await m.markRead('!dm:matrix.org');
    expect((helper.last('read')['room'], helper.last('read')['event']), ('!dm:matrix.org', r'$m1'));
    expect(m.chats.firstWhere((c) => c.id == '!dm:matrix.org').unread, 0);

    // A reaction from them, and one of ours; ours taken off again by deleting it.
    helper.event({'ev': 'reaction', 'room': '!dm:matrix.org', 'id': r'$rj', 'target': r'$out1', 'from': '@jo:matrix.org', 'emoji': '👍', 'ts': 1});
    await settle();
    await m.react('!dm:matrix.org', r'$out1', '👍');
    expect((helper.last('react')['event'], helper.last('react')['emoji']), (r'$out1', '👍'));
    var reactions = m.messagesOf('!dm:matrix.org').firstWhere((x) => x.id == r'$out1').reactions;
    expect([for (final r in reactions) (r.emoji, r.count, r.mine)], [('👍', 2, true)]);
    await m.react('!dm:matrix.org', r'$out1', '👍', remove: true);
    expect(helper.last('redact')['event'], r'$react1');
    reactions = m.messagesOf('!dm:matrix.org').firstWhere((x) => x.id == r'$out1').reactions;
    expect([for (final r in reactions) (r.emoji, r.count, r.mine)], [('👍', 1, false)]);

    // A message deleted by its sender (a redaction), and one of ours deleted for everyone.
    helper.event({'ev': 'redacted', 'room': '!dm:matrix.org', 'target': r'$m1', 'from': '@jo:matrix.org'});
    await settle();
    expect(m.messagesOf('!dm:matrix.org').map((x) => x.id), [r'$out1', r'$out2']);
    final mine = m.messagesOf('!dm:matrix.org').last;
    expect(m.canDeleteForEveryone('!dm:matrix.org', mine), isTrue);
    expect(m.canDeleteForEveryone('!dm:matrix.org', m.messagesOf('!crew:matrix.org').single), isFalse);
    await m.deleteMessage('!dm:matrix.org', mine.id, forEveryone: true);
    expect(helper.last('redact')['event'], r'$out2');
    expect(m.messagesOf('!dm:matrix.org').map((x) => x.id), [r'$out1']);

    await m.signOut();
    expect(helper.all('logout'), hasLength(1));
    expect(m.state, InboxState.signedOut);
    expect(m.chats, isEmpty);
    m.dispose();
  });

  test('signed in with the browser: the homeserver\'s page opened, the login token taken from the redirect to 127.0.0.1', () async {
    // flutter_test answers every HTTP request with a 400; this one goes to the listener on this device.
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    final helper = FakeHelper();
    helper.answer = (r) => switch (r['op']) {
          'sso_url' => {'url': 'https://matrix-client.matrix.org/_matrix/client/v3/login/sso/redirect?redirectUrl=${Uri.encodeQueryComponent('${r['redirect']}')}', 'homeserver': 'https://matrix-client.matrix.org'},
          'login_token' => signedIn,
          _ => null,
        };
    final m = Matrix(link: () async => helper, folder: dir.path);
    await m.start(AppState());
    await settle();
    String? opened;
    await m.signInWithBrowser('@matt:matrix.org', open: (url) async {
      opened = url;
      // The browser, once the person has signed in: back to the redirect with the token.
      final back = Uri.parse(Uri.parse(url).queryParameters['redirectUrl']!).replace(queryParameters: {'loginToken': 'tok-123'});
      expect(back.host, '127.0.0.1');
      final req = await HttpClient().getUrl(back);
      final res = await req.close();
      expect(await res.transform(utf8.decoder).join(), contains('Signed in to Matrix'));
      return true;
    });
    expect(opened, startsWith('https://matrix-client.matrix.org/_matrix/client/v3/login/sso/redirect?redirectUrl=http'));
    expect(helper.last('sso_url')['homeserver'], '@matt:matrix.org');
    expect(helper.last('login_token')['token'], 'tok-123');
    expect(m.state, InboxState.ready);
    m.dispose();
  });

  test('a password the server refuses says why and stays signed out', () async {
    final helper = FakeHelper();
    helper.answer = (r) => r['op'] == 'login_password' ? throw 'this server doesn\'t take passwords here: sign in with your browser instead' : null;
    final m = Matrix(link: () async => helper, folder: dir.path);
    await m.start(AppState());
    await settle();
    await m.signInWithPassword('matrix.org', 'matt', 'x');
    expect(m.state, InboxState.signedOut);
    expect(m.error, contains('sign in with your browser'));
    m.dispose();
  });

  test('an encrypted message without its key, unlocked by the recovery key; an edit; older messages; kept across a restart', () async {
    final helper = FakeHelper()..status = signedIn;
    var unlocked = false;
    helper.answer = (r) => switch (r['op']) {
          'rooms' => [dm()],
          'verify_recovery_key' => {'verified': true, 'backup_version': '3'},
          'messages' when r['from'] == null => {
              'messages': [
                if (unlocked) {...msg('!dm:matrix.org', r'$m2', text: 'the door code is 4412', ts: 1763300050000)}..remove('ev')
                else {...msg('!dm:matrix.org', r'$m2', text: '', ts: 1763300050000, undecryptable: true)}..remove('ev'),
                {...msg('!dm:matrix.org', r'$m1', text: 'are you coming tonight?')}..remove('ev'),
              ],
              'reactions': [{'room': '!dm:matrix.org', 'id': r'$rx', 'target': r'$m1', 'from': me, 'emoji': '❤️', 'ts': 2}],
              'end': 't-older',
            },
          'messages' => {
              'messages': [{...msg('!dm:matrix.org', r'$m0', text: 'hey, long time', ts: 1763000000000)}..remove('ev')],
              'reactions': const [],
              'end': '',
            },
          _ => null,
        };
    final m = Matrix(link: () async => helper, folder: dir.path);
    await m.start(AppState());
    await settle();
    expect(m.state, InboxState.ready);
    expect(m.verified, isFalse);

    await m.load('!dm:matrix.org');
    var held = m.messagesOf('!dm:matrix.org');
    expect([for (final x in held) x.text], ['are you coming tonight?', Matrix.lockedText]);
    expect(held.first.reactions.single.mine, isTrue);

    unlocked = true;
    await m.unlock('  EsTc 1234 abcd  ');
    await settle();
    expect(helper.last('verify_recovery_key')['key'], 'EsTc 1234 abcd');
    expect(m.verified, isTrue);
    held = m.messagesOf('!dm:matrix.org');
    expect([for (final x in held) x.text], ['are you coming tonight?', 'the door code is 4412'], reason: 'asked for again, and decrypted now');

    // An edit changes the words of the message it replaces.
    helper.event({...msg('!dm:matrix.org', r'$e1', text: 'the door code is 4413'), 'replaces': r'$m2'});
    await settle();
    expect(m.messagesOf('!dm:matrix.org').last.text, 'the door code is 4413');
    expect(m.messagesOf('!dm:matrix.org'), hasLength(2));

    // Older ones from where the last answer ended; none after that.
    await m.load('!dm:matrix.org', older: true);
    expect(helper.last('messages')['from'], 't-older');
    expect(m.messagesOf('!dm:matrix.org').first.text, 'hey, long time');
    final asked = helper.all('messages').length;
    await m.load('!dm:matrix.org', older: true);
    expect(helper.all('messages').length, asked);

    m.flush();
    m.dispose();
    // The chats show from what was kept, before and after the helper gives its rooms (from its own rooms.json).
    final helper2 = FakeHelper()..status = signedIn;
    helper2.answer = (r) => r['op'] == 'rooms' ? [dm()] : null;
    final again = Matrix(link: () async => helper2, folder: dir.path);
    await again.start(AppState());
    await settle();
    expect(again.chats.single.title, 'Jo Park');
    expect(again.messagesOf('!dm:matrix.org').map((x) => x.text), ['hey, long time', 'are you coming tonight?', 'the door code is 4413']);
    again.dispose();
  });

  test('an invite to a direct chat shows, and answering it accepts it', () async {
    final helper = FakeHelper()..status = signedIn;
    helper.answer = (r) => switch (r['op']) {
          'rooms' => [dm(invite: true, unread: 0)],
          'send' => {'id': r'$hi'},
          'messages' => {'messages': const [], 'reactions': const [], 'end': ''},
          _ => null,
        };
    final m = Matrix(link: () async => helper, folder: dir.path);
    await m.start(AppState());
    await settle();
    final chat = m.chats.single;
    expect((chat.snippet, chat.stranger, chat.group), ('Wants to chat with you', true, false));
    expect(m.isInvite(chat.id), isTrue);
    await m.send(chat.id, 'hi Jo');
    expect(helper.all('join').single['room'], '!dm:matrix.org');
    expect(helper.last('send')['text'], 'hi Jo');
    expect(m.isInvite(chat.id), isFalse);

    // A room that changed is told whole; one left is gone.
    helper.event({'ev': 'room', ...group(ts: 1763400000000)});
    await settle();
    expect(m.chats.first.title, 'Weekend crew');
    helper.event({'ev': 'room_gone', 'room': '!crew:matrix.org'});
    await settle();
    expect(m.chats.map((c) => c.id), ['!dm:matrix.org']);

    // Signed out by the server.
    helper.event({'ev': 'logged_out', 'error': 'Your Matrix server signed this device out. Sign in again to carry on.'});
    await settle();
    expect(m.state, InboxState.signedOut);
    expect(m.error, contains('signed this device out'));
    expect(m.chats, isEmpty);
    m.dispose();
  });

  test('without the helper Matrix is not in this build', () async {
    final none = Matrix(link: () async => null, folder: dir.path);
    await none.start(AppState());
    expect(none.state, InboxState.unavailable);
    expect(none.error, contains('helper'));
    expect(Inbox.of([Matrix(soon: true)]).ready, isEmpty);
  });

  test('the helper\'s log: its own request lines and warnings go to the Developer log, nothing else', () {
    String? keep(Map<String, Object?> m) => MatrixLog.keep(jsonEncode(m));
    expect(keep({'level': 'info', 'op': 'send', 'req': 7, 'took': 61.2, 'message': 'answered'}), 'info answered op=send req=7 took=61.2');
    expect(keep({'level': 'warn', 'component': 'crypto', 'event_id': r'$x', 'message': 'Failed to decrypt event'}), r'warn Failed to decrypt event component=crypto event_id=$x');
    expect(keep({'level': 'info', 'component': 'mautrix', 'message': 'Stored credentials after login'}), isNull);
    expect(matrixReactions({'a': {'from': me, 'emoji': '👍'}, 'b': {'from': '@jo:s', 'emoji': '👍'}, 'c': {'from': '@jo:s', 'emoji': '🎉'}}, me: me).map((r) => (r.emoji, r.count, r.mine)), [('👍', 2, true), ('🎉', 1, false)]);
  });

  testWidgets('the sign-in screen: the server, the browser or a password; once in, the recovery key', (tester) async {
    final sheet = await loadSheet(tester);
    final helper = FakeHelper();
    helper.answer = (r) => switch (r['op']) {
          'login_password' => signedIn,
          'rooms' => [dm()],
          'verify_recovery_key' => {'verified': true, 'backup_version': '3'},
          _ => null,
        };
    final m = Matrix(link: () async => helper, folder: dir.path);
    await tester.runAsync(() async {
      await m.start(AppState());
      await settle();
    });
    await pumpScreen(tester, sheet, MatrixSignInScreen(network: m, openLink: (_) async => true), AppState());
    expect(find.text('Sign in to Matrix'), findsOneWidget);
    expect(find.text('Sign in with your browser'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Or with a password$', caseSensitive: false)), findsOneWidget);
    expect(find.textContaining('Uplink\'s servers never see them'), findsOneWidget);

    await tester.runAsync(() async {
      await m.signInWithPassword('matrix.org', 'matt', 'hunter2');
      await settle();
    });
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Unlock older messages$', caseSensitive: false)), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    await tester.runAsync(() async {
      await m.unlock('EsTc 1234');
      await settle();
    });
    await tester.pump();
    expect(find.text('This device is verified'), findsOneWidget);
    expect(helper.last('verify_recovery_key')['key'], 'EsTc 1234');
    await tester.pumpWidget(const SizedBox());
    m.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
