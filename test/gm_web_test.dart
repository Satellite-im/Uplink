import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/gm_web.dart';

/// Google Messages on the computer (lib/desktop/gm_web.dart; Matt, 2026-11-15: "Yes, mautrix sidecar"): its
/// conversations folded into the desktop's, and what is asked of one answered by it. The sidecar itself is stood in
/// for here; it is run for real by hand (sidecar/gmessages/README.md).
void main() {
  final gm = GmWeb.instance;
  final asked = <String>[];

  Map<String, dynamic> conv(String id, List<Map<String, Object?>> others, {int time = 1000, bool unread = false, bool rcs = true, bool group = false, String name = ''}) => {
        'id': id, 'name': name, 'group': group, 'unread': unread, 'time': time, 'snippet': 'last of $id', 'rcs': rcs, 'pinned': false,
        'archived': false, 'outgoing': 'me1',
        'people': [
          {'id': 'me1', 'name': 'Me', 'number': '+15550000000', 'me': true},
          for (final o in others) {'me': false, ...o},
        ],
      };

  setUp(() {
    asked.clear();
    gm.paired = true;
    gm.conversations
      ..clear()
      ..['c1'] = conv('c1', [{'id': 'p1', 'name': 'Maya Chen', 'number': '+15551230001'}], time: 5000, unread: true)
      ..['c2'] = conv('c2', [{'id': 'p2', 'name': '', 'number': '+15559998888'}, {'id': 'p3', 'name': 'Sam', 'number': '+15557776666'}], time: 3000, group: true, name: 'Trip');
    gm.standIn = (op, args) async {
      asked.add('$op ${args['conv'] ?? args['media'] ?? ''}'.trim());
      switch (op) {
        case 'messages':
          return {
            'items': [
              {'id': 'm2', 'conv': args['conv'], 'from': 'me1', 'me': true, 'text': 'On my way', 'time': 4000, 'status': 'outgoing_delivered', 'media': [], 'reactions': [{'emoji': '👍', 'from': ['p1']}]},
              {'id': 'm1', 'conv': args['conv'], 'from': 'p1', 'me': false, 'text': 'Dinner?', 'time': 3500, 'status': 'incoming_complete',
               'media': [{'id': 'med1', 'key': 'a2V5', 'mime': 'image/jpeg', 'name': 'photo.jpg'}], 'reactions': []},
            ],
          };
        case 'media':
          await File(args['path'] as String).writeAsBytes([1, 2, 3]);
          return {'path': args['path']};
        default:
          return {};
      }
    };
  });

  tearDown(() {
    gm.standIn = null;
    gm.paired = false;
    gm.conversations.clear();
  });

  test('its conversations join the list, newest first; the phone\'s copy of one with the same people is left out', () {
    final phone = [
      {'id': 7, 'date': 4500, 'people': [{'address': '(555) 123-0001'}], 'snippet': 'texts with Maya', 'group': null},
      {'id': 8, 'date': 9000, 'people': [{'address': '+15554443333'}], 'snippet': 'only on the phone', 'group': null},
    ];
    final list = gm.fold(phone);
    expect([for (final c in list) (c as Map)['snippet']], ['only on the phone', 'last of c1', 'last of c2']);
    final maya = list[1] as Map;
    expect(maya['id'], lessThanOrEqualTo(GmWeb.threadBase), reason: 'a thread number of its own');
    expect(maya['unread'], isTrue);
    expect(maya['people'], [{'address': '+15551230001', 'name': 'Maya Chen'}], reason: 'not counting the person');
    expect((list[2] as Map)['name'], 'Trip', reason: 'a group keeps its name');
    expect(gm.owns(maya['id'] as int), isTrue);
    expect(gm.owns(7), isFalse);
  });

  test('you are not counted among a conversation\'s people when not marked as you, but are the one it sends from', () {
    // Matt, 2026-11-15: "i see two chats for message DMs ... then one that is the person and me in a group".
    gm.conversations['c3'] = {
      ...conv('c3', [{'id': 'p9', 'name': 'Riley', 'number': '+15551112222'}], time: 9000),
      'people': [
        {'id': 'me1', 'name': 'Matt', 'number': '+15550000000', 'me': false},
        {'id': 'p9', 'name': 'Riley', 'number': '+15551112222', 'me': false},
      ],
    };
    final row = gm.row(gm.conversations['c3']!);
    expect(row['people'], [{'address': '+15551112222', 'name': 'Riley'}], reason: 'one to one, not a group with yourself');
    expect(gm.convFor(['+15551112222']), 'c3');
    final folded = gm.fold([{'id': 5, 'date': 1, 'people': [{'address': '(555) 111-2222'}], 'snippet': 'texts with Riley', 'group': null}]);
    expect(folded.where((c) => (c as Map)['snippet'] == 'texts with Riley'), isEmpty, reason: 'the phone\'s copy is the same conversation');
  });

  test('not paired, the phone\'s list stands as it is', () {
    gm.paired = false;
    final phone = [{'id': 7, 'date': 1, 'people': const [], 'snippet': 'x'}];
    expect(gm.fold(phone), same(phone));
  });

  test('a thread number is the same every time for the same conversation', () {
    expect(gm.threadOf('c1'), gm.threadOf('c1'));
    expect(gm.threadOf('c1'), isNot(gm.threadOf('c2')));
  });

  test('messages come as the conversation draws them: who, words, reactions apart, state, and pictures to bring down', () async {
    final t = gm.threadOf('c1');
    final ms = await gm.messages(t);
    expect(ms.map((m) => m['body']), ['On my way', 'Dinner?'], reason: 'newest first');
    // Reactions apart from the words, drawn once (Matt, 2026-11-17: "we see double reactions").
    expect(ms[0]['reactions'], ['👍']);
    expect(ms[0]['outgoing'], isTrue);
    expect(ms[0]['state'], 'delivered');
    expect(ms[1]['address'], '+15551230001');
    expect(ms[1]['state'], 'received');
    final part = (ms[1]['parts'] as List).single as Map;
    expect(part['type'], 'image/jpeg');
    final dir = Directory.systemTemp.createTempSync('gmweb');
    addTearDown(() => dir.deleteSync(recursive: true));
    gm.folder = dir;
    expect(gm.ownsPart(part['id'] as int), isTrue);
    expect(await gm.part(part['id'] as int), Uint8List.fromList([1, 2, 3]));
    asked.clear();
    expect(await gm.part(part['id'] as int), Uint8List.fromList([1, 2, 3]));
    expect(asked, isEmpty, reason: 'brought down once, kept');
  });

  test('sending to the people of one of its conversations goes to that conversation', () async {
    expect(gm.convFor(['(555) 123-0001']), 'c1');
    expect(gm.convFor(['+15557776666', '+1 555 999 8888']), 'c2');
    expect(gm.convFor(['+15554443333']), isNull);
    expect(await gm.send('c1', 'hi'), gm.threadOf('c1'));
    expect(asked, ['send c1']);
  });

  test('marking read reads as far as the newest message', () async {
    await gm.markRead(gm.threadOf('c1'));
    expect(asked, ['messages c1', 'read c1']);
    expect(gm.conversations['c1']!['unread'], isFalse);
  });

  // The real sidecar (tool/build-gmsidecar.sh), asked how it stands and for a QR code: only where
  // GHOST_GMSIDECAR_LIVE names the built binary, since it speaks to Google.
  test('the real sidecar starts, says it is not paired, and gives a QR code to scan', () async {
    final binary = Platform.environment['GHOST_GMSIDECAR_LIVE'];
    final dir = Directory.systemTemp.createTempSync('gmlive');
    addTearDown(() => dir.deleteSync(recursive: true));
    gm.standIn = null;
    gm.paired = false;
    await gm.start(dir, env: {'GHOST_GMSIDECAR': binary!});
    expect(gm.available, isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    await gm.refresh();
    expect(gm.paired, isFalse);
    await gm.pair();
    for (var i = 0; i < 50 && gm.qr == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(gm.qr, startsWith('https://support.google.com/messages/'));
    await gm.stop();
  }, skip: Platform.environment['GHOST_GMSIDECAR_LIVE'] == null ? 'GHOST_GMSIDECAR_LIVE names no sidecar' : null, timeout: const Timeout(Duration(seconds: 60)));
}
