import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/overlay.dart';

/// The phone's own channel, as a test holds it: a texts conversation (id 7) and a contact, and every call it is asked.
class _Phone implements SmsCalls {
  final asked = <String>[];
  String buddies = jsonEncode([
    {'u': 'bee', 'i': 'b' * 32, 'k': 'x', 'n': 'Bee', 'b': '', 's': 'yes', 'a': 0},
  ]);

  /// The phone's encryption records (android E2e.list).
  List<Object?> records = [
    {'address': '+15551234567', 'state': 'on', 'friend': 'yes'},
  ];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    asked.add(method);
    final Object? answer = switch (method) {
      'buddiesKept' => buddies,
      'conversationsPage' => {
          'items': [
            {'id': 7, 'date': 5000, 'people': [{'address': '+15551234567', 'name': 'Sam'}], 'snippet': 'a text', 'unread': false, 'error': false, 'archived': false},
          ],
          'next': null,
        },
      'messages' => [
          {'id': 1, 'kind': 'sms', 'address': '+15551234567', 'body': 'a text', 'date': 5000, 'outgoing': false, 'state': 'received'},
        ],
      'e2eList' => records,
      'searchContacts' => [
          {'name': 'Sam', 'address': '+15551234567'},
        ],
      'archivedCount' => 2,
      _ => null,
    };
    return answer as T?;
  }
}

/// On the Android phone, friends by username kept in Dart beside its texts (lib/standalone/overlay.dart; Matt,
/// 2026-11-15: "Yes, Android next").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Phone phone;
  late OverlayCalls calls;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('overlay');
    phone = _Phone();
    calls = OverlayCalls(phone, File('${root.path}/chats.json'));
    await calls.load();
  });
  tearDown(() async {
    await calls.flushed();
    root.deleteSync(recursive: true);
  });

  test('it stands on the phone: the phone\'s screens stay the phone\'s', () {
    final before = Sms.calls;
    Sms.calls = calls;
    addTearDown(() => Sms.calls = before);
    expect(Sms.remote, isFalse);
    expect(Sms.paired, isFalse);
    // Everything the phone can do is still offered: pictures, stickers, voice, deleting (Matt, 2026-11-15: "Im missing
    // the button to send picture and videos to people").
    for (final what in ['sendPictures', 'sendSticker', 'sendVoice', 'deleteThreads', 'deleteMessage', 'editMessage', 'e2eOffer']) {
      expect(Sms.can(what), isTrue, reason: what);
    }
  });

  test('a friend by username\'s words are kept here, and the list is the phone\'s with them', () async {
    await calls.invokeMethod('netTextIn', {'address': '@bee', 'body': 'hi from an iPhone', 'at': 9000});
    expect(phone.asked, isNot(contains('netTextIn')), reason: 'Android has no room for someone with no number');
    final page = (await calls.invokeMethod<Map>('conversationsPage', {'limit': 30, 'offset': 0, 'pinned': true}))!;
    final items = [for (final c in page['items'] as List) Conversation.from(c as Map)];
    expect(items.map((c) => c.people.single.address), containsAll(['+15551234567', '@bee']));
    final bee = items.firstWhere((c) => c.people.single.address == '@bee');
    expect(bee.id, greaterThanOrEqualTo(OverlayCalls.base));
    expect(bee.title, 'Bee');
    expect(bee.unread, isTrue);
    // Its messages are kept here; the phone's conversation is the phone's.
    final mine = [for (final m in (await calls.invokeMethod<List>('messages', {'thread': bee.id, 'limit': 50}))!) Message.from(m as Map)];
    expect(mine.single.body, 'hi from an iPhone');
    phone.asked.clear();
    final theirs = (await calls.invokeMethod<List>('messages', {'thread': 7, 'limit': 50}))!;
    expect((theirs.single as Map)['body'], 'a text');
    expect(phone.asked, ['messages']);
    // A later lot is the phone's alone: these come once.
    final later = (await calls.invokeMethod<Map>('conversationsPage', {'limit': 30, 'offset': 30}))!;
    expect([for (final c in later['items'] as List) (c as Map)['id']], isNot(contains(bee.id)));
  });

  // Matt, 2026-11-20: "rework the onboarding on mobile so that SMS is not required and you can 'skip this step'".
  test('with texts off, Android is asked for no conversations; friends\' chats go on; a number says why it can\'t', () async {
    Sms.textsOff = true;
    addTearDown(() => Sms.textsOff = false);
    await calls.invokeMethod('netTextIn', {'address': '@bee', 'body': 'hi', 'at': 9000});
    phone.asked.clear();
    final page = (await calls.invokeMethod<Map>('conversationsPage', {'limit': 30, 'offset': 0, 'pinned': true}))!;
    expect([for (final c in page['items'] as List) Conversation.from(c as Map).people.single.address], ['@bee']);
    expect(await calls.invokeMethod('archivedCount', const {}), 0);
    expect(phone.asked, isNot(anyOf(contains('conversationsPage'), contains('archivedCount'))));
    expect(() => calls.invokeMethod('threadFor', {'addresses': ['+15551234567']}), throwsA(isA<StateError>().having((e) => e.message, 'says', textsOffWords)));
    expect(() => calls.invokeMethod('send', {'addresses': ['+15551234567'], 'body': 'x'}), throwsA(isA<StateError>()));
  });

  test('sending, where things stand, contacts: friends by username added to the phone\'s', () async {
    final row = (await calls.invokeMethod<int>('netTextOut', {'address': '@bee', 'body': 'going'}))!;
    await calls.invokeMethod('netTextState', {'id': row, 'state': 'delivered'});
    expect(phone.asked, isNot(contains('netTextState')));
    // A phone row's state is the phone's.
    await calls.invokeMethod('netTextState', {'id': 3, 'state': 'sent'});
    expect(phone.asked, contains('netTextState'));

    final states = [for (final s in (await calls.invokeMethod<List>('e2eList'))!) E2eState.from(s as Map)];
    expect(states.map((s) => s.address), ['+15551234567', '@bee']);
    expect(states.last.isFriend, isTrue);
    final found = (await calls.invokeMethod<List>('searchContacts', {'query': 'be'}))!;
    expect(found.map((c) => (c as Map)['address']), containsAll(['+15551234567', '@bee']));
    expect((await calls.invokeMethod<Map>('contact', {'address': '@bee'}))!['name'], 'Bee');
    expect(await calls.invokeMethod<int>('threadFor', {'addresses': ['@bee']}), greaterThanOrEqualTo(OverlayCalls.base));
    phone.asked.clear();
    await calls.invokeMethod('threadFor', {'addresses': ['+15551234567']});
    expect(phone.asked, ['threadFor']);
  });

  test('a new friend by username is read as the phone keeps the list', () async {
    expect(await calls.invokeMethod('contact', {'address': '@cee'}), {'address': '@cee', 'name': null});
    phone.buddies = jsonEncode([
      {'u': 'cee', 'i': 'c' * 32, 'k': 'x', 'n': 'Cee', 'b': '', 's': 'yes', 'a': 0},
    ]);
    await calls.invokeMethod('buddiesKeep', {'json': phone.buddies});
    expect(phone.asked, contains('buddiesKeep'), reason: 'the phone works out the sealing keys from it');
    expect((await calls.invokeMethod<Map>('contact', {'address': '@cee'}))!['name'], 'Cee');
  });

  // Found in review, 2026-11-23: who sent a friend's words, and where they go, is decided by the ids the records name
  // (lib/friends/friends.dart), so a friend by username's record names them, and nothing else can be one.
  test('friends by username are one record each, naming the install their username stands for and their others; a phone record under a username is no one\'s', () async {
    phone.buddies = jsonEncode([
      {'u': 'bee', 'i': 'b' * 32, 'k': 'x', 'n': 'Bee', 's': 'yes', 'a': 1},
      // The same username again, an install of theirs that came with a new key: the newest stands for them.
      {'u': 'bee', 'i': 'd' * 32, 'k': 'x', 'n': 'Bee', 's': 'yes', 'a': 2},
      {'u': 'cee', 'i': 'c' * 32, 'k': 'x', 'n': 'Cee', 's': 'invited', 'a': 3},
    ]);
    await calls.invokeMethod('buddiesKeep', {'json': phone.buddies});
    phone.records = [
      {'address': '+15551234567', 'state': 'on', 'friend': 'yes', 'id': 'a' * 32},
      // A text from a sender that named itself "@bee" (some networks let it): an encryption record under a username.
      {'address': '@bee', 'state': 'on', 'friend': 'yes', 'id': 'e' * 32},
    ];
    final states = [for (final s in (await calls.invokeMethod<List>('e2eList'))!) E2eState.from(s as Map)];
    expect(states.map((s) => s.address), ['+15551234567', '@bee']);
    expect(states.map((s) => s.id), ['a' * 32, 'd' * 32]);
    expect(states.last.otherIds, ['b' * 32]);
    expect(states.last.isFriend, isTrue);
    // The conversation's own word on where things stand is that one record too.
    expect(E2eState.from((await calls.invokeMethod<Map>('e2e', {'address': '@bee'}))!).id, 'd' * 32);
  });

  test('deleting several: each kept where it is', () async {
    await calls.invokeMethod('netTextIn', {'address': '@bee', 'body': 'x', 'at': 1});
    final bee = (await calls.invokeMethod<int>('threadFor', {'addresses': ['@bee']}))!;
    phone.asked.clear();
    await calls.invokeMethod('deleteThreads', {'threads': [7, bee]});
    expect(calls.chats.threads, isEmpty);
    expect(phone.asked, ['deleteThreads']);
    expect(await calls.invokeMethod('archivedCount'), 2);
  });

  test('kept across a restart', () async {
    await calls.invokeMethod('netTextIn', {'address': '@bee', 'body': 'stays', 'at': 1});
    await calls.flushed();
    final again = OverlayCalls(phone, File('${root.path}/chats.json'));
    await again.load();
    expect(again.chats.threads.values.single.rows.single.body, 'stays');
  });
}
