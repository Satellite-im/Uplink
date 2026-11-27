import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/signal.dart';

/// A stand-in for the Signal helper (sidecar/signal/PROTOCOL.md): answers what it is asked, and says what Signal would.
class FakeHelper implements SignalLink {
  final asked = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast();
  Object? Function(Map<String, Object?> r) answer = (_) => null;
  bool linked = false;

  void event(Map<String, Object?> e) => _out.add(e);

  @override
  Stream<Map<String, Object?>> get heard => _out.stream;

  /// What a download writes, as the helper writes the file it is asked for.
  List<int> downloaded = const [7, 7, 7];

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    if (line['op'] == 'download' && line['path'] is String) File(line['path'] as String).writeAsBytesSync(downloaded);
    final r = line['op'] == 'status' ? {'linked': linked, 'number': linked ? '+15550100199' : null} : answer(line);
    scheduleMicrotask(() => _out.add({'id': line['id'], 'ok': true, 'result': r}));
  }

  @override
  Future<void> close() async {}
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Signal through mautrix-signal (lib/inbox/signal.dart; Matt, 2026-11-15: "Lets wire it up for signal through the
/// mautrix"): linked by the QR code the helper gives, its messages kept here as they come, sent, read, deleted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });

  test('a picture sent is shown from a copy kept here after a restart, never fetched with a pointer that has no key', () async {
    // Matt, 2026-11-16: a picture sent on Signal showed "Bad state: the attachment has no key".
    final dir = Directory.systemTemp.createTempSync('signal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final picked = File('${dir.path}/picked.jpg')..writeAsBytesSync([1, 2, 3]);
    final helper = FakeHelper()..linked = true;
    var withPointer = true;
    helper.answer = (r) => switch (r['op']) {
          'send_media' => {'ts': 1763200600000 + helper.asked.length, if (withPointer) 'pointer': {'cdnKey': 'k9', 'key': 'a2V5'}},
          _ => null,
        };
    final s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await settle();
    expect(s.state, InboxState.ready);
    await s.sendFiles('aci-jo', [picked.path], caption: 'Testing images');
    withPointer = false;
    await s.sendFiles('aci-jo', [picked.path]);
    picked.deleteSync();
    s.flush();
    s.dispose();

    final again = FakeHelper()..linked = true;
    final s2 = Signal(link: () async => again, folder: dir.path);
    await s2.start(AppState());
    await settle();
    final sent = s2.messagesOf('aci-jo');
    expect(sent.map((m) => m.text), ['Testing images', '']);
    // The copy kept in Signal's folder, though the picked file is gone.
    final path = await s2.fileOf(sent[0].media.single.fileId);
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [1, 2, 3]);
    expect(again.asked.where((r) => r['op'] == 'download'), isEmpty);
    // With the copy gone too, the one sent with Signal's pointer is fetched with it; the one without asks for nothing and
    // says nothing.
    File(path).deleteSync();
    File((await s2.fileOf(sent[1].media.single.fileId))!).deleteSync();
    final s3helper = FakeHelper()..linked = true;
    s2.flush();
    s2.dispose();
    final s3 = Signal(link: () async => s3helper, folder: dir.path);
    await s3.start(AppState());
    await settle();
    final again3 = s3.messagesOf('aci-jo');
    await s3.fileOf(again3[0].media.single.fileId);
    expect(s3helper.asked.where((r) => r['op'] == 'download').single['pointer'], {'cdnKey': 'k9', 'key': 'a2V5'});
    expect(await s3.fileOf(again3[1].media.single.fileId), isNull);
    expect(s3helper.asked.where((r) => r['op'] == 'download'), hasLength(1));
    expect(s3.error, isNull);
    s3.dispose();
  });

  // Matt, 2026-11-20: "some photos and videos are not coming through". A picture asked for its file each time it was
  // drawn, and the downloads ran at once into one path.
  test('a picture asked for again and again while it comes is downloaded once; one left half done is fetched again', () async {
    final dir = Directory.systemTemp.createTempSync('signal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper()..linked = true;
    helper.downloaded = List.filled(2048, 1);
    final s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await settle();
    helper.event({
      'ev': 'message', 'chat': 'aci-jo', 'group': false, 'from': 'aci-jo', 'mine': false, 'ts': 1763200100000, 'text': '',
      'media': [{'pointer': {'cdnKey': 'k1', 'key': 'a2V5'}, 'mime': 'image/jpeg', 'name': 'beach.jpg', 'size': 2048}],
    });
    await settle();
    final id = s.messagesOf('aci-jo').single.media.single.fileId;
    final paths = await Future.wait([s.fileOf(id), s.fileOf(id), s.fileOf(id)]);
    expect(paths.toSet(), hasLength(1));
    expect(helper.asked.where((r) => r['op'] == 'download'), hasLength(1));
    expect(File(paths.first!).lengthSync(), 2048);
    s.dispose();

    // As an older build could leave it: the file at its place, cut short. Fetched again, not shown broken.
    File(paths.first!).writeAsBytesSync([1, 2, 3]);
    final again = FakeHelper()..linked = true;
    again.downloaded = List.filled(2048, 1);
    final s2 = Signal(link: () async => again, folder: dir.path);
    await s2.start(AppState());
    await settle();
    final id2 = s2.messagesOf('aci-jo').single.media.single.fileId;
    final path2 = await s2.fileOf(id2);
    expect(File(path2!).lengthSync(), 2048);
    expect(again.asked.where((r) => r['op'] == 'download'), hasLength(1));
    s2.dispose();
  });

  test('linked by the QR code; a message comes, is kept, answered, read and deleted; kept across a restart', () async {
    final dir = Directory.systemTemp.createTempSync('signal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper();
    helper.answer = (r) => switch (r['op']) {
          'contacts' => [{'aci': 'aci-jo', 'name': 'Jo Park', 'number': '+15550100'}],
          'groups' => [{'id': 'grp1', 'title': 'Weekend crew', 'members': ['aci-jo']}],
          'send' => {'ts': 1763200500000},
          _ => null,
        };
    final s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await settle();
    expect(s.state, InboxState.signedOut);

    await s.begin();
    expect(helper.asked.last, containsPair('op', 'link'));
    helper.event({'ev': 'qr', 'url': 'sgnl://linkdevice?uuid=abc&pub_key=def'});
    await settle();
    expect(s.qr, startsWith('sgnl://linkdevice'));
    helper.event({'ev': 'linked', 'aci': 'aci-me', 'number': '+15550100199'});
    await settle();
    expect(s.state, InboxState.ready);
    expect(s.account, '+15550100199');
    expect(s.qr, isNull);

    helper.event({'ev': 'message', 'chat': 'aci-jo', 'group': false, 'from': 'aci-jo', 'mine': false, 'ts': 1763200000000, 'text': 'are you coming tonight?', 'media': []});
    helper.event({
      'ev': 'message', 'chat': 'grp1', 'group': true, 'from': 'aci-jo', 'name': 'Jo Park', 'mine': false, 'ts': 1763200100000, 'text': '',
      'media': [{'pointer': {'cdnKey': 'k1'}, 'mime': 'image/jpeg', 'name': 'beach.jpg', 'size': 2048, 'width': 800, 'height': 600}],
    });
    await settle();
    final chats = {for (final c in s.chats) c.id: c};
    expect((chats['aci-jo']!.title, chats['aci-jo']!.snippet, chats['aci-jo']!.unread), ('Jo Park', 'are you coming tonight?', 1));
    expect((chats['grp1']!.title, chats['grp1']!.group, chats['grp1']!.snippet), ('Weekend crew', true, 'Photo'));
    expect(s.messagesOf('grp1').single.media.single.kind, 'photo');

    await s.send('aci-jo', 'on my way');
    final sent = helper.asked.lastWhere((r) => r['op'] == 'send');
    expect((sent['to'], sent['text']), ('aci-jo', 'on my way'));
    final mine = s.messagesOf('aci-jo').last;
    expect((mine.id, mine.mine, mine.state), ('1763200500000', true, 'sent'));

    await s.markRead('aci-jo');
    final read = helper.asked.lastWhere((r) => r['op'] == 'read');
    expect((read['to'], read['author']), ('aci-jo', 'aci-jo'));
    expect(read['ts'], [1763200000000]);
    expect(s.chats.firstWhere((c) => c.id == 'aci-jo').unread, 0);

    expect(s.canDeleteForEveryone('aci-jo', mine), isTrue);
    await s.deleteMessage('aci-jo', mine.id, forEveryone: true);
    expect(helper.asked.lastWhere((r) => r['op'] == 'delete')['ts'], 1763200500000);
    expect(s.messagesOf('aci-jo').map((m) => m.text), ['are you coming tonight?']);

    s.flush();
    s.dispose();
    final again = Signal(link: () async => FakeHelper()..linked = true, folder: dir.path);
    await again.start(AppState());
    await settle();
    expect(again.state, InboxState.ready);
    expect(again.chats.map((c) => c.title), containsAll(['Jo Park', 'Weekend crew']));
    expect(again.messagesOf('aci-jo').single.text, 'are you coming tonight?');
    again.dispose();
  });

  test('without the helper Signal is not in this build; offered from 0.7.40', () async {
    expect(Inbox.of([Signal(soon: true)]).ready, isEmpty);
    Inbox.instance = null;
    expect(Inbox.instance.named('signal')!.soon, isFalse);
    final none = Signal(link: () async => null);
    await none.start(AppState());
    expect(none.state, InboxState.unavailable);
  });

  // Matt, 2026-11-16: "Show telegram and signal contacts when linked".
  test('Signal\'s contacts once linked, without the person themself; a chat with one is named by their ACI', () async {
    final dir = Directory.systemTemp.createTempSync('signal-contacts');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper();
    helper.answer = (r) => switch (r['op']) {
          'contacts' => [
              {'aci': 'aci-me', 'name': 'Matt', 'number': '+15550100199'},
              {'aci': 'aci-riley', 'name': 'Riley Fox', 'number': '+447700900123', 'avatar': '/tmp/riley.jpg'},
              {'aci': 'aci-jo', 'name': 'Jo Park', 'number': ''},
            ],
          'groups' => const [],
          _ => null,
        };
    final s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await s.begin();
    helper.event({'ev': 'linked', 'aci': 'aci-me', 'number': '+15550100199'});
    await settle();
    expect([for (final c in s.contacts) (c.id, c.name, c.number, c.avatar)], [('aci-jo', 'Jo Park', null, null), ('aci-riley', 'Riley Fox', '+447700900123', '/tmp/riley.jpg')]);
    expect(await s.chatWith(s.contacts.last), 'aci-riley');
    // Their face by their lines in a group (lib/ui/flat_line.dart).
    expect((s.faceOf('aci-riley'), s.faceOf('aci-jo')), ('/tmp/riley.jpg', null));

    await s.signOut();
    expect(s.contacts, isEmpty);
  });

  // Matt, 2026-11-16: "Sending signal messages get stuck on sending... and the group titles are not coming through".
  test('a group is named when it is first heard from, and groups are asked for again when Signal is back', () async {
    final dir = Directory.systemTemp.createTempSync('signal-groups');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper();
    var groupsAsked = 0;
    // On linking the store has no groups yet: a group is known only from its first message.
    helper.answer = (r) => switch (r['op']) {
          'contacts' => const [],
          'groups' => (groupsAsked++ == 0) ? const [] : [{'id': 'R3JvdXAtd2Vla2VuZC1jcmV3LWlkLTAwMDAwMDAwMDA=', 'title': 'Weekend crew', 'members': const []}],
          _ => null,
        };
    final s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await s.begin();
    helper.event({'ev': 'linked', 'aci': 'aci-me', 'number': '+15550100199'});
    await settle();
    const gid = 'R3JvdXAtd2Vla2VuZC1jcmV3LWlkLTAwMDAwMDAwMDA=';
    helper.event({'ev': 'message', 'chat': gid, 'group': true, 'from': 'aci-jo', 'name': 'Jo Park', 'ts': 1763300000000, 'text': 'tent is packed'});
    await settle();
    expect(s.chats.single.title, 'Signal group', reason: 'nothing known of it yet');

    // The helper tells its name as soon as it has looked it up.
    helper.event({'ev': 'group', 'id': gid, 'title': 'Hiking crew', 'members': ['aci-jo'], 'avatar': null});
    await settle();
    expect(s.chats.single.title, 'Hiking crew');
    expect(s.chats.single.group, isTrue);

    // Reconnected: groups asked for again (and the store now has the group).
    final before = groupsAsked;
    helper.event({'ev': 'connected'});
    await settle();
    expect(groupsAsked, before, reason: 'not again within a minute of the last time');
  });

  test('the helper\'s log: its own send lines and warnings go to the Developer log, nothing else', () {
    String? keep(Map<String, Object?> m) => SignalLog.keep(jsonEncode(m));
    expect(keep({'level': 'info', 'op': 'send', 'req': 7, 'took': 61.2, 'message': 'answered'}), 'info answered op=send req=7 took=61.2');
    expect(keep({'level': 'info', 'message': 'sent to group', 'sent_to': 0, 'failed': 3, 'error': 'context deadline exceeded'}), 'info sent to group sent_to=0 failed=3 error=context deadline exceeded');
    expect(keep({'level': 'warn', 'component': 'signalmeow', 'message': 'Failed to fetch prekeys'}), 'warn Failed to fetch prekeys component=signalmeow');
    expect(keep({'level': 'info', 'component': 'signalmeow', 'message': 'Websocket connected'}), isNull);
    expect(keep({'level': 'debug', 'message': 'anything'}), isNull);
    // A send's own steps, whatever their level, with their time and the sockets' state.
    expect(keep({'level': 'info', 'trace': true, 'time': '2026-11-16T21:04:05Z', 'authed_ws': true, 'unauthed_ws': false, 'message': 'send begins'}),
        '2026-11-16T21:04:05Z info send begins authed_ws=true unauthed_ws=false');
    expect(keep({'level': 'debug', 'trace': true, 'time': '2026-11-16T21:04:41Z', 'response_status': 401, 'message': 'DEBUG: message send response data'}),
        '2026-11-16T21:04:41Z debug DEBUG: message send response data response_status=401');
  });

  // Matt, 2026-11-16: "signal messages are not being properly tied to a username or group name" (a chat showed
  // "signal:45de8397-…"): the phone's contact sync often names nobody and gives no number, so an empty name was kept
  // and the row fell back to the chat's address.
  group('names', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('signal-names'));
    tearDown(() => dir.deleteSync(recursive: true));

    Map<String, Object?> msg(String chat, String from, {bool group = false, bool mine = false, String name = '', int ts = 1763200000000}) =>
        {'ev': 'message', 'chat': chat, 'group': group, 'from': from, 'name': name, 'mine': mine, 'ts': ts, 'text': 'hi', 'media': const []};

    test('a person nothing names is asked about (their Signal profile), and called by it', () async {
      final helper = FakeHelper()..linked = true;
      helper.answer = (r) => switch (r['op']) {
            'contacts' => [
                {'aci': 'aci-jo', 'name': '', 'number': '', 'avatar': null},
              ],
            'groups' => const [],
            'who' => r['aci'] == 'aci-jo' ? {'aci': 'aci-jo', 'name': 'Jo Park', 'number': '', 'avatar': null} : {'aci': r['aci'], 'name': '', 'number': ''},
            _ => null,
          };
      final s = Signal(link: () async => helper, folder: dir.path);
      await s.start(AppState());
      await settle();
      // Only this account's own message so far: nothing in the message names Jo.
      helper.event(msg('aci-jo', 'aci-me', mine: true));
      await settle();
      await settle();
      expect(helper.asked.where((r) => r['op'] == 'who').map((r) => r['aci']), contains('aci-jo'));
      expect(s.chats.single.title, 'Jo Park');
      s.dispose();
    });

    test('an empty name is never a name: the number, else "Signal contact"', () async {
      final helper = FakeHelper()..linked = true;
      helper.answer = (r) => switch (r['op']) {
            'contacts' => [
                {'aci': 'aci-sam', 'name': '', 'number': '+15550100123', 'avatar': null},
              ],
            'groups' => const [],
            'who' => {'aci': r['aci'], 'name': '', 'number': ''},
            _ => null,
          };
      final s = Signal(link: () async => helper, folder: dir.path);
      await s.start(AppState());
      await settle();
      helper.event(msg('aci-sam', 'aci-sam', ts: 1));
      helper.event(msg('aci-nobody', 'aci-nobody', ts: 2));
      await settle();
      await settle();
      final titles = {for (final c in s.chats) c.id: c.title};
      expect(titles['aci-sam'], '+15550100123');
      expect(titles['aci-nobody'], 'Signal contact');
      expect(titles.values.any((t) => t.isEmpty || t.startsWith('aci-')), isFalse);
      s.dispose();
    });

    test('the helper\'s "name" event names a person as their profile comes; a group keeps its title', () async {
      final helper = FakeHelper()..linked = true;
      helper.answer = (r) => switch (r['op']) {
            'contacts' || 'groups' => const [],
            'who' => {'aci': r['aci'], 'name': '', 'number': ''},
            _ => null,
          };
      final s = Signal(link: () async => helper, folder: dir.path);
      await s.start(AppState());
      await settle();
      helper.event(msg('aci-riley', 'aci-riley', ts: 1));
      helper.event(msg('grp-1', 'aci-riley', group: true, ts: 2));
      helper.event({'ev': 'group', 'id': 'grp-1', 'title': 'Weekend crew', 'members': ['aci-riley'], 'avatar': null});
      await settle();
      expect({for (final c in s.chats) c.id: c.title}, {'aci-riley': 'Signal contact', 'grp-1': 'Weekend crew'});
      helper.event({'ev': 'name', 'aci': 'aci-riley', 'name': 'Riley Fox', 'number': '', 'avatar': null});
      await settle();
      expect({for (final c in s.chats) c.id: c.title}, {'aci-riley': 'Riley Fox', 'grp-1': 'Weekend crew'});
      // And the group's messages say who wrote them.
      await s.load('grp-1');
      expect(s.messagesOf('grp-1').single.sender, 'Riley Fox');
      s.dispose();
    });

    test('an empty name kept by an older build is dropped, and the person asked about again', () async {
      File('${dir.path}/chats.json').writeAsStringSync(jsonEncode({
        'chats': {'aci-jo': {'unread': 0, 'last': 5}},
        'messages': {'aci-jo': [{'ts': 5, 'from': 'aci-jo', 'mine': false, 'text': 'hey', 'media': [], 'state': 'received'}]},
        'names': {'aci-jo': ''},
        'groups': [],
      }));
      final helper = FakeHelper()..linked = true;
      helper.answer = (r) => switch (r['op']) {
            'contacts' || 'groups' => const [],
            'who' => {'aci': 'aci-jo', 'name': 'Jo Park', 'number': '', 'avatar': null},
            _ => null,
          };
      final s = Signal(link: () async => helper, folder: dir.path);
      await s.start(AppState());
      await settle();
      await settle();
      expect(s.chats.single.title, 'Jo Park');
      s.dispose();
    });
  });
}
