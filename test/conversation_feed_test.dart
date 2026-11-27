import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/conversation_feed.dart';
import 'package:ghost_messaging/sms.dart';

/// The list's conversations as they are read (lib/conversation_feed.dart; Matt, 2026-11-26: "Please go through and
/// rework how we load chats into the sidebar and sort them to clean things up right now they don't always show the last
/// message"): a conversation's row is the newest reading of it, and no reading puts an older copy over a newer one.

Map<String, Object?> _c(int id, int date, {String snippet = '', bool unread = false, bool pinned = false, bool archived = false}) =>
    {'id': id, 'date': date, 'people': const [], 'snippet': snippet, 'unread': unread, 'pinned': pinned, 'archived': archived};

/// A phone made up for these: [rows] is Android's list (given a lot at a time, newest first), [first] what its first
/// lot also carries (the pinned, the unread, a conversation the bridge has newer words for), and [asked] everything
/// the feed asked of it.
class _Phone implements SmsCalls {
  _Phone(this.rows);
  List<Map<String, Object?>> rows;
  List<Map<String, Object?>> first = [];
  final asked = <String>[];

  /// Says where each lot ends, as a phone of this build does; off, a phone of an older build.
  bool saysFloor = false;

  /// Held shut, the lot that starts at this row waits for [open].
  int? gate;
  Completer<void>? open;
  Object? fail;

  List<Map<String, Object?>> get _sorted => [...rows]..sort((a, b) => (b['date'] as int).compareTo(a['date'] as int));

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final a = (arguments as Map?) ?? const {};
    switch (method) {
      case 'conversationsPage':
        if (a['archived'] == true) {
          asked.add('archived');
          return {'items': [for (final c in _sorted) if (c['archived'] == true) c], 'next': null} as T;
        }
        final offset = (a['offset'] as num?)?.toInt() ?? 0, limit = (a['limit'] as num?)?.toInt() ?? 0;
        asked.add('lot $offset');
        if (gate == offset) await (open ??= Completer<void>()).future;
        if (fail != null) throw fail!;
        final all = _sorted;
        final to = limit <= 0 ? all.length : (offset + limit).clamp(0, all.length);
        final lot = all.sublist(offset.clamp(0, all.length), to);
        final next = to < all.length ? to : null;
        return {
          'items': [...lot, if (offset == 0) ...first],
          'next': next,
          if (saysFloor && next != null && lot.isNotEmpty) 'floor': lot.last['date'],
        } as T;
      case 'conversation':
        final id = (a['thread'] as num).toInt();
        asked.add('one $id');
        return [...first, ...rows].where((c) => c['id'] == id).firstOrNull as T?;
    }
    return null;
  }
}

/// Sixty conversations, the newest first: conversation n was written at 10000 - n.
List<Map<String, Object?>> _sixty() => [for (var n = 1; n <= 60; n++) _c(n, 10000 - n, snippet: 'text $n')];

void main() {
  late SmsCalls was;
  late _Phone phone;
  late ConversationFeed feed;
  setUp(() {
    was = Sms.calls;
    Sms.calls = phone = _Phone(_sixty());
    feed = ConversationFeed();
  });
  tearDown(() {
    feed.dispose();
    Sms.calls = was;
  });

  Conversation of(int id) => feed.items!.firstWhere((c) => c.id == id);
  List<int> ids() => [for (final c in feed.items ?? const <Conversation>[]) c.id];

  /// Lets a run of changes settle and what they ask for come back.
  Future<void> settled(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('everything is read the newest first: the first lot, then the rest behind it', (tester) async {
    final seen = <int>[];
    feed.addListener(() => seen.add(feed.items?.length ?? -1));
    expect(feed.items, isNull);
    await feed.load();
    expect(phone.asked, ['lot 0', 'lot 40']);
    expect(seen, [40, 60], reason: 'drawn as each lot arrives');
    expect(ids(), [for (var n = 1; n <= 60; n++) n]);
    expect([feed.more, feed.error, feed.whole, feed.floor], [false, null, 1, null]);
  });

  testWidgets('a later lot\'s older copy of a conversation never goes over the newer one the first lot had', (tester) async {
    // Conversation 55's last SMS is old, so Android lists it in the second lot; its newest message is an RCS one the
    // bridge has, which the first lot carries. A phone before this build gave the second lot's copy as Android has it.
    phone.first = [_c(55, 20000, snippet: 'the RCS message, just now')];
    await feed.load();
    expect(ids().first, 55);
    expect(of(55).snippet, 'the RCS message, just now');
    expect(ids().where((id) => id == 55), hasLength(1));
    // And again at every whole reading, which is where it used to go stale.
    await feed.load();
    expect([ids().first, of(55).snippet], [55, 'the RCS message, just now']);
  });

  testWidgets('a pinned one comes with the first lot and again in its place: held once, as it stands in the later copy when that is as new', (tester) async {
    phone.rows[57] = _c(58, 10000 - 58, snippet: 'text 58', pinned: true);
    phone.first = [_c(58, 10000 - 58, snippet: 'text 58', pinned: true)];
    await feed.load();
    expect(ids().where((id) => id == 58), hasLength(1));
    expect(of(58).pinned, isTrue);
  });

  testWidgets('what a whole reading did not find has gone, and what was shown before stays until it is read again', (tester) async {
    await feed.load();
    phone.rows.removeWhere((c) => c['id'] == 50);
    phone.gate = 40;
    final reading = feed.load();
    await tester.pump();
    expect(ids(), contains(50), reason: 'the second lot has not said yet');
    expect(feed.more, isTrue);
    phone.open!.complete();
    await reading;
    expect(ids(), isNot(contains(50)));
    expect(ids(), hasLength(59));
    expect(feed.whole, 2);
  });

  testWidgets('while older ones are still being read: the date everything newer than which is held', (tester) async {
    phone.gate = 40;
    phone.first = [_c(58, 10000 - 58, snippet: 'text 58', pinned: true), _c(59, 10000 - 59, unread: true)];
    // An older build says nothing: the oldest of the lot that is not pinned (an unread one from further down drags it
    // down, which a newer build does not let it).
    var reading = feed.load();
    await tester.pump();
    expect(feed.floor, DateTime.fromMillisecondsSinceEpoch(10000 - 59));
    phone.open!.complete();
    await reading;
    expect(feed.floor, isNull);
    // This build says where the lot ends.
    phone
      ..saysFloor = true
      ..open = null;
    reading = feed.load();
    await tester.pump();
    expect(feed.floor, DateTime.fromMillisecondsSinceEpoch(10000 - 40));
    phone.open!.complete();
    await reading;
  });

  testWidgets('a text that came: the newest lot is read again, once for a run of changes', (tester) async {
    await feed.load();
    phone.asked.clear();
    phone.rows[29] = _c(30, 30000, snippet: 'hello again', unread: true);
    feed
      ..changed(30)
      ..changed(-1)
      ..changed(30);
    await settled(tester);
    expect(phone.asked, ['lot 0']);
    expect([ids().first, of(30).snippet, of(30).unread], [30, 'hello again', true]);
    expect(ids(), hasLength(60));
  });

  testWidgets('a conversation far down the list that changed is read by itself, and one that is gone is taken out', (tester) async {
    phone.rows[54] = _c(55, 10000 - 55, snippet: 'text 55', unread: true);
    await feed.load();
    expect(of(55).unread, isTrue);
    phone.asked.clear();
    // Read on another device: its row changes where it stands, far below the newest lot.
    phone.rows[54] = _c(55, 10000 - 55, snippet: 'text 55');
    feed.changed(55);
    await settled(tester);
    expect(phone.asked, ['lot 0', 'one 55']);
    expect(of(55).unread, isFalse);
    expect(ids().indexOf(55), 54, reason: 'where it was');
    // Its messages deleted: the phone has no such conversation.
    phone.asked.clear();
    phone.rows.removeWhere((c) => c['id'] == 55);
    feed.changed(55);
    await settled(tester);
    expect(phone.asked, ['lot 0', 'one 55']);
    expect(ids(), isNot(contains(55)));
  });

  testWidgets('a row read again alone: marked read here, nothing else is asked for', (tester) async {
    phone.rows[54] = _c(55, 10000 - 55, snippet: 'text 55', unread: true);
    await feed.load();
    phone.asked.clear();
    phone.rows[54] = _c(55, 10000 - 55, snippet: 'text 55');
    feed.refresh(55);
    await settled(tester);
    expect(phone.asked, ['one 55']);
    expect(of(55).unread, isFalse);
  });

  testWidgets('a list short enough to come in one lot comes whole: what it has not is gone', (tester) async {
    phone.rows = [for (var n = 1; n <= 5; n++) _c(n, 100 - n)];
    await feed.load();
    expect(phone.asked, ['lot 0']);
    phone.asked.clear();
    phone.rows.removeWhere((c) => c['id'] == 4);
    feed.changed(4);
    await settled(tester);
    expect(phone.asked, ['lot 0'], reason: 'not asked for by itself: the lot was the whole list');
    expect(ids(), [1, 2, 3, 5]);
    expect(feed.whole, 2);
  });

  testWidgets('a text that comes while everything is being read is read once that has ended', (tester) async {
    await feed.load();
    phone
      ..asked.clear()
      ..gate = 40;
    final reading = feed.load();
    await tester.pump();
    phone.rows[2] = _c(3, 40000, snippet: 'came meanwhile');
    feed.changed(3);
    await settled(tester);
    expect(phone.asked, ['lot 0', 'lot 40'], reason: 'the whole reading is left to finish');
    phone.open!.complete();
    await reading;
    await settled(tester);
    expect(phone.asked, ['lot 0', 'lot 40', 'lot 0']);
    expect([ids().first, of(3).snippet], [3, 'came meanwhile']);
  });

  testWidgets('more changed at once than is worth reading one by one: everything is read again, once', (tester) async {
    await feed.load();
    phone.asked.clear();
    for (var n = 41; n <= 41 + ConversationFeed.mostAlone; n++) {
      feed.changed(n);
    }
    await settled(tester);
    expect(phone.asked, ['lot 0', 'lot 40']);
  });

  testWidgets('changes that keep coming do not put the reading off for ever', (tester) async {
    await feed.load();
    phone.asked.clear();
    // One every 200 ms, each inside the wait the one before began.
    for (var i = 0; i < 12; i++) {
      feed.changed(1);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(phone.asked.where((a) => a == 'lot 0').length, greaterThanOrEqualTo(2));
    await settled(tester);
  });

  testWidgets('a reading that fails says why and keeps what was held; the next one clears it', (tester) async {
    await feed.load();
    phone.fail = StateError('the store did not answer');
    await feed.load();
    expect(feed.error, contains('the store did not answer'));
    expect(ids(), hasLength(60));
    expect([feed.more, feed.slow], [false, false]);
    phone.fail = null;
    await feed.load();
    expect(feed.error, isNull);
    // Nothing read yet, and it fails: an empty list with the reason, not bones for ever.
    final cold = ConversationFeed();
    addTearDown(cold.dispose);
    phone.fail = StateError('no');
    await cold.load();
    expect([cold.items, cold.error != null], [isEmpty, true]);
    phone.fail = null;
  });

  testWidgets('a reading that takes a moment says so, and stops saying so when the screen has its conversations', (tester) async {
    phone.gate = 0;
    final reading = feed.load();
    await tester.pump(const Duration(milliseconds: 400));
    expect(feed.slow, isTrue);
    phone.open!.complete();
    await reading;
    expect(feed.slow, isFalse);
  });

  testWidgets('changed at once, before the phone answers: a row read, a conversation gone', (tester) async {
    phone.rows[4] = _c(5, 10000 - 5, snippet: 'text 5', unread: true);
    await feed.load();
    var told = 0;
    feed.addListener(() => told++);
    feed.patch(5, (c) => c.copyWith(unread: false));
    expect([of(5).unread, told], [false, 1]);
    feed.patchAll({1, 2}, (c) => c.copyWith(pinned: true));
    expect([of(1).pinned, of(2).pinned, of(3).pinned], [true, true, false]);
    feed.remove([5, 6]);
    expect(ids(), isNot(anyOf(contains(5), contains(6))));
    expect(feed.has(7), isTrue);
    expect(feed.has(5), isFalse);
  });

  testWidgets('the archive is asked for by name, all at once, and read again whole at any change', (tester) async {
    phone.rows[9] = _c(10, 10000 - 10, archived: true);
    final archive = ConversationFeed(archived: true);
    addTearDown(archive.dispose);
    await archive.load();
    expect(phone.asked, ['archived']);
    expect([for (final c in archive.items!) c.id], [10]);
    phone.rows[10] = _c(11, 10000 - 11, archived: true);
    archive.changed(11);
    await settled(tester);
    expect(phone.asked, ['archived', 'archived']);
    expect([for (final c in archive.items!) c.id], [10, 11]);
    expect(archive.whole, 2);
  });

  testWidgets('nothing is said or asked after it is disposed of', (tester) async {
    final gone = ConversationFeed();
    await gone.load();
    var told = 0;
    gone.addListener(() => told++);
    phone.asked.clear();
    gone
      ..changed(3)
      ..removeListener(() {});
    gone.dispose();
    await settled(tester);
    expect([told, phone.asked], [0, isEmpty]);
  });
}
