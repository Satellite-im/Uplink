import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/chat_rail.dart';
import 'package:ghost_messaging/ui/chat_rows.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-25: "in the right hand of the chat gutter add this same style of chat scrolling to show frequency of
// messages and who differently sent messages etc". Then, the same day: "Lets remove the popover for the summarized
// messages on the chat map for now and remove the tap and hold just allow scrolling normally it's a bit glitchy though
// when getting to the top or bottom dont change the main size of the chatmap scroll it up and down as we go back
// through history". Then, 2026-11-26: "when clicking something far up it doesn't go all the way to the message because
// it's still loading i assume and it's overall still kind of glitchy and i can't click and drag through it, please keep
// the same looks but do a revamp to make it far more performant and smooth", and of the held drag: "it scrolls in
// reverse when touching holding and scrolling". lib/ui/chat_rail.dart, over lib/ui/chat_rows.dart. Run with
// --update-goldens, the pictures are build/chat-rail/*.png.

const _minute = 60 * 1000;
final _now = DateTime(2026, 11, 25, 15).millisecondsSinceEpoch;

/// A chat, newest first: three bursts, a day apart, between Maya and oneself.
List<RailMark> _chat({int each = 20}) => [
      for (var day = 0; day < 3; day++)
        for (var i = 0; i < each; i++)
          RailMark(
            at: _now - day * 24 * 60 * _minute - i * _minute ~/ 2,
            who: i.isEven ? 'maya' : 'me',
            mine: i.isOdd,
            name: i.isEven ? 'Maya Chen' : 'You',
            text: 'day $day line ${each - i}',
          ),
    ];

Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

/// A group's chat over a week, for a picture: busy evenings, a quiet day, three people and oneself.
List<RailMark> _week() {
  const people = [('maya', 'Maya Chen'), ('sam', 'Sam Okafor'), ('me', 'You'), ('lee', 'Lee Park')];
  const said = [
    'are we still on for Friday?', 'yes! 7 at the usual place', 'I can bring the projector', 'who has the cable though',
    'me, it is in the car', 'perfect', 'running ten late', 'no rush, the table is ours till 9', 'ok ordering for everyone',
    'get the dumplings', 'photos from last night are up', 'that one of Sam is going on the wall',
  ];
  final out = <RailMark>[];
  var at = _now;
  var k = 0;
  for (var burst = 0; burst < 7; burst++) {
    final n = [34, 6, 22, 3, 41, 12, 18][burst];
    for (var i = 0; i < n; i++, k++) {
      final p = people[(k * 7 + burst + (i ~/ 3)) % people.length];
      out.add(RailMark(at: at, who: p.$1, mine: p.$1 == 'me', name: p.$2, text: said[(said.length - 1 - (k % said.length))]));
      at -= (i % 5 == 4 ? 9 : 1) * _minute ~/ (burst.isEven ? 2 : 1);
    }
    at -= [5, 19, 3, 26, 14, 40, 8][burst] * 60 * _minute;
  }
  return out;
}

void main() {
  group('the lines', () {
    test('one for each message while they fit, a long line in a burst and a short one alone', () {
      final marks = [
        for (var i = 0; i < 9; i++) RailMark(at: _now - i * 20 * 1000, who: 'maya', mine: false),
        RailMark(at: _now - 3 * 60 * _minute, who: 'me', mine: true),
      ];
      final ticks = ChatRail.ticksOf(marks, 40);
      expect(ticks, hasLength(10));
      expect(ticks.first.rate, 1, reason: 'nine within minutes');
      expect(ticks.last.rate, 0, reason: 'alone, hours before');
      expect(ticks.last.mine, isTrue);
      expect(ticks.first.who, 'maya');
    });

    test('more messages than lines: each line is several, and whoever wrote most of them', () {
      final marks = [
        for (var i = 0; i < 300; i++) RailMark(at: _now - i * _minute, who: i < 150 ? (i % 3 == 0 ? 'me' : 'maya') : 'me', mine: i < 150 ? i % 3 == 0 : true),
      ];
      final ticks = ChatRail.ticksOf(marks, 50);
      expect(ticks, hasLength(50));
      expect(ticks.first.who, 'maya');
      expect(ticks.first.mine, isFalse);
      expect(ticks.last.who, 'me');
      expect(ticks.last.mine, isTrue);
    });

    test('nothing for nothing', () {
      expect(ChatRail.ticksOf(const [], 10), isEmpty);
      expect(ChatRail.stretchesOf(const []), isEmpty);
    });
  });

  group('the stretches', () {
    test('cut where the chat paused, the newest first, each with who wrote in it and how it began', () {
      final s = ChatRail.stretchesOf(_chat());
      expect(s, hasLength(3));
      expect(s.first.newest, 0);
      expect(s.first.oldest, 19);
      expect(s.last.oldest, 59);
      expect(s.first.count, 20);
      expect(s.first.people.map((p) => p.who).toSet(), {'maya', 'me'});
      expect(s.first.opening, 'You: day 0 line 1', reason: 'its oldest words');
      expect(s.first.lines.split('\n').first, 'You: day 0 line 1');
      expect(s.first.lines.split('\n'), hasLength(20));
    });

    test('never more than a dozen, however often a chat paused', () {
      final marks = [for (var i = 0; i < 400; i++) RailMark(at: _now - i * 40 * 24 * 60 * _minute, who: 'maya', mine: false, text: 'hello $i')];
      final s = ChatRail.stretchesOf(marks);
      expect(s.length, lessThanOrEqualTo(ChatRail.mostStretches));
      expect(s.fold<int>(0, (n, x) => n + x.count), 400, reason: 'every message in one');
    });

    test('too little to sum up has no lines for a model, and something that happened is no part of one', () {
      final s = ChatRail.stretchesOf([
        RailMark(at: _now, who: 'maya', mine: false, name: 'Maya', text: 'ok'),
        RailMark(at: _now - 1000, who: '', mine: false, text: 'Maya joined', quiet: true),
      ]);
      expect(s.single.lines, isEmpty);
      expect(s.single.opening, 'Maya: ok');
      expect(s.single.people.map((p) => p.who), ['maya']);
    });
  });

  group('in a chat', () {
    /// A chat's list with its map, 700 by 600 with rows 48 tall unless [tall] says, or [row] makes them. [marks] can
    /// be given again, as when older messages are loaded or a new one comes. Every row built is noted in [built]. A
    /// row is keyed by its message's place from the oldest (`row-1` the oldest), which no newer message changes.
    Future<ScrollController> openOn(WidgetTester tester, ValueNotifier<List<RailMark>> marks, {double Function(int i)? tall, Widget Function(int fromOldest)? row, ScrollPhysics? physics, List<int>? built}) async {
      final sheet = await loadSheet(tester);
      final c = ScrollController();
      addTearDown(c.dispose);
      await pumpScreen(
        tester,
        sheet,
        ValueListenableBuilder<List<RailMark>>(
          valueListenable: marks,
          builder: (context, m, _) => ChatRail(
            controller: c,
            marks: m,
            chat: 'test',
            child: ChatListView.builder(
              controller: c,
              reverse: true,
              physics: physics,
              itemCount: m.length,
              // A message by its place from the oldest, as its row is keyed.
              idOf: (i) => m.length - i,
              itemBuilder: (context, i) {
                built?.add(i);
                final made = row?.call(m.length - i);
                return made != null ? KeyedSubtree(key: ValueKey('row-${m.length - i}'), child: made) : SizedBox(key: ValueKey('row-${m.length - i}'), height: tall?.call(i) ?? 48, child: Text(m[i].text));
              },
            ),
          ),
        ),
        AppState(),
        size: const Size(700, 600),
        platform: 'desktop',
      );
      await tester.pump();
      await tester.pump();
      return c;
    }

    Future<ScrollController> open(WidgetTester tester, List<RailMark> marks, {double Function(int i)? tall, List<int>? built}) => openOn(tester, ValueNotifier(marks), tall: tall, built: built);

    final rail = find.byKey(const ValueKey('chat-rail'));
    RailPainter painter(WidgetTester tester) => tester.widget<CustomPaint>(find.descendant(of: rail, matching: find.byType(CustomPaint))).painter! as RailPainter;

    /// [n] messages a minute apart, newest first.
    List<RailMark> long(int n) => [for (var i = 0; i < n; i++) RailMark(at: _now - i * _minute, who: i.isEven ? 'maya' : 'me', mine: i.isOdd, name: i.isEven ? 'Maya Chen' : 'You', text: 'line ${n - i}')];

    setUpAll(_fonts);

    testWidgets('a picture of a week of a group', (tester) async {
      await open(tester, _week());
      expect(rail, findsOneWidget);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/chat-rail/week.png'));
    });

    testWidgets('a short chat has no map', (tester) async {
      await open(tester, _chat(each: 2));
      expect(rail, findsNothing);
    });

    testWidgets('the map is at the right, and a press on it goes there', (tester) async {
      final c = await open(tester, _chat());
      expect(rail, findsOneWidget);
      expect(tester.getRect(rail).right, 700);
      expect(c.offset, 0);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/chat-rail/rail.png'));
      // Its top is the oldest end.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getRect(rail).topCenter + const Offset(0, 2));
      addTearDown(mouse.removePointer);
      await mouse.down(tester.getRect(rail).topCenter + const Offset(0, 2));
      await mouse.up();
      await settle(tester);
      expect(c.offset, greaterThan(c.position.maxScrollExtent - 60), reason: 'at the oldest');
      // And a finger's press does the same: its foot is newer, and once the map is back there, the newest.
      for (var k = 0; k < 2; k++) {
        await tester.tapAt(tester.getRect(rail).bottomCenter - const Offset(0, 2));
        await settle(tester);
      }
      expect(c.offset, 0, reason: 'the newest');
    });

    testWidgets('a press goes to the message pressed, exactly, however tall the rows between', (tester) async {
      // Rows of very different heights, so a guess by the scroll's share of its length lands somewhere else.
      final marks = _chat();
      await open(tester, marks, tall: (i) => i < 20 ? 30 : (i < 40 ? 140 : 60));
      final box = tester.getRect(rail);
      // The 40th message from the newest (39, counted from 0), by where its line is.
      await tester.tapAt(Offset(box.center.dx, box.top + painter(tester).yOf(39)));
      await settle(tester);
      final row = find.byKey(ValueKey('row-${marks.length - 39}'));
      expect(row, findsOneWidget);
      expect(tester.getRect(row).center.dy, closeTo(300, 1), reason: 'in the middle of the screen');
    });

    // Matt, 2026-11-25: "Lets remove the popover for the summarized messages on the chat map for now and remove the tap
    // and hold".
    testWidgets('no list of stretches opens from it, under a mouse or a press, and a finger held on it moves nothing', (tester) async {
      final c = await open(tester, _chat());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(rail));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(rail) + const Offset(0, 1));
      await settle(tester);
      expect(find.byKey(const ValueKey('chat-rail-list')), findsNothing);
      expect(find.textContaining('20 messages'), findsNothing);
      await mouse.moveTo(const Offset(100, 300));
      await tester.pump();
      // Held at its foot, where the chat is already: nothing moves, nothing opens.
      final size = tester.getSize(rail);
      final touch = await tester.startGesture(tester.getRect(rail).bottomCenter - const Offset(0, 2));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await settle(tester);
      expect(find.byKey(const ValueKey('chat-rail-list')), findsNothing);
      expect(c.offset, 0);
      expect(tester.getSize(rail), size);
      await touch.up();
      await settle(tester);
      expect(find.byKey(const ValueKey('chat-rail-list')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-26: "Bring back the magnifying effect when scrolling through the chat map".
    testWidgets('the map swells under a mouse over it and under a finger scrolling over it, and settles once they go', (tester) async {
      final c = await open(tester, long(300));
      final box = tester.getRect(rail);
      final rest = [for (var i = 0; i < 80; i++) painter(tester).yOf(i)];
      expect([for (var i = 0; i < 80; i++) painter(tester).growOf(i)], everyElement(1.0));
      // A mouse over the middle: the line under it is the largest, those far off are as they were.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 300));
      addTearDown(mouse.removePointer);
      const under = 30;
      await mouse.moveTo(Offset(box.center.dx, box.top + rest[under]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final p = painter(tester);
      expect(p.growOf(under), closeTo(ChatRail.magnifyMost, 0.05));
      expect(p.yOf(under), closeTo(rest[under], 0.01), reason: 'the line under the pointer stays where it is');
      expect(p.growOf(under + 20), lessThan(p.growOf(under + 4)));
      expect(p.growOf(under + 40), closeTo(1, 0.01));
      expect(p.yOf(under) - p.yOf(under + 1), greaterThan(ChatRail.pitch * 1.8), reason: 'further apart under it');
      expect(p.yOf(under + 1) - p.yOf(under + 2), greaterThan(p.yOf(under + 15) - p.yOf(under + 16)));
      expect(c.offset, 0, reason: 'a mouse over it scrolls nothing');
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/chat-rail/swell.png'));
      await mouse.moveTo(const Offset(100, 300));
      await settle(tester);
      expect(painter(tester).growOf(under), 1);
      // A finger drawn over it scrolls the chat, and the swell goes with the finger.
      final touch = await tester.startGesture(Offset(box.center.dx, box.top + 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter(tester).growOf(_nearest(painter(tester), 200)), greaterThan(2));
      for (var k = 0; k < 6; k++) {
        await touch.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.offset, greaterThan(60), reason: 'still scrolls the chat');
      await tester.pump(const Duration(milliseconds: 300));
      final q = painter(tester), at = _nearest(q, 320);
      expect(q.yOf(at), closeTo(320, ChatRail.pitch * ChatRail.magnifyMost), reason: 'under the finger where it is now');
      expect(q.growOf(at), greaterThan(2));
      await touch.up();
      await settle(tester);
      expect([for (var i = 0; i < 300; i += 9) painter(tester).growOf(i)], everyElement(1.0));
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-26: "i'd like to be able to tap and hold to initate the scrolling mechanic and click and hold as well";
    // then: "i can't click and drag through it", and "in the current chat map it scrolls in reverse when touching
    // holding and scrolling".
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets('taken hold of with a ${kind.name} and drawn along: the chat is at the message under the pointer, UP the map OLDER, the map itself still', (tester) async {
        final c = await open(tester, long(300));
        c.jumpTo(48.0 * 100);
        await settle(tester);
        final box = tester.getRect(rail);
        final p0 = painter(tester);
        final at0 = p0.place(p0.tall).at;
        final y0 = p0.tall / 2;
        final under = _nearest(p0, y0);
        Finder row(int mark) => find.byKey(ValueKey('row-${300 - mark}'));
        final g = await tester.createGesture(kind: kind);
        if (kind == PointerDeviceKind.mouse) await g.addPointer(location: Offset(box.center.dx, box.top + y0));
        await g.down(Offset(box.center.dx, box.top + y0));
        if (kind == PointerDeviceKind.touch) {
          await tester.pump(const Duration(milliseconds: 200));
          expect(c.offset, closeTo(48.0 * 100, 0.01), reason: 'a finger not yet held long enough moves nothing');
          await tester.pump(ChatRail.holdFor);
        }
        await settle(tester);
        expect(tester.getRect(row(under)).center.dy, closeTo(300, 1), reason: 'held: the message whose line is under the pointer is in the middle');
        final held = c.offset;
        // Up the map by ten lines: ten messages OLDER, and further up the chat.
        for (var k = 0; k < 10; k++) {
          await g.moveBy(const Offset(0, -ChatRail.pitch));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await settle(tester);
        expect(tester.getRect(row(under + 10)).center.dy, closeTo(300, 1), reason: 'ten lines up the map is ten messages older');
        expect(c.offset, closeTo(held + 480, 1));
        expect(painter(tester).place(p0.tall).at, closeTo(at0, 0.01), reason: 'the map itself has not moved under the pointer');
        // (Taken hold of at its middle, so no further from the pointer than half a line, swollen as lines there are.)
        expect(painter(tester).yOf(under + 10), closeTo(y0 - 10 * ChatRail.pitch, ChatRail.pitch / 2 * ChatRail.magnifyMost + 0.5), reason: 'that message\'s line is the one under the pointer');
        expect(painter(tester).seen.lo, lessThan(under + 10));
        expect(painter(tester).seen.hi, greaterThan(under + 10), reason: 'and it is one of the bright ones');
        // Half a line more is half a message more: the chat goes with the pointer, not a message at a time.
        await g.moveBy(const Offset(0, -ChatRail.pitch / 2));
        await settle(tester);
        expect(c.offset, closeTo(held + 480 + 24, 1));
        await g.moveBy(const Offset(0, ChatRail.pitch / 2));
        // Down the map past where it began: newer.
        for (var k = 0; k < 25; k++) {
          await g.moveBy(const Offset(0, ChatRail.pitch));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await settle(tester);
        expect(tester.getRect(row(under - 15)).center.dy, closeTo(300, 1), reason: 'fifteen lines under where it began is fifteen messages newer');
        expect(painter(tester).place(p0.tall).at, closeTo(at0, 0.01));
        // Let go: the chat stays, and the map glides back to its frame on what is on the screen.
        final left = c.offset;
        await g.up();
        if (kind == PointerDeviceKind.mouse) await g.removePointer();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 100));
        final gliding = painter(tester).place(p0.tall).at;
        expect(gliding, lessThan(at0));
        await settle(tester);
        expect(c.offset, left);
        final p1 = painter(tester);
        expect(p1.place(p1.tall).at, lessThan(gliding), reason: 'it glided, it did not jump');
        expect(p1.yOf(under - 15), closeTo(p1.tall / 2, ChatRail.pitch), reason: 'what is on the screen is in the map\'s middle again');
        expect(tester.takeException(), isNull);
      });
    }

    // Matt, 2026-11-26: "i can't click and drag through it". A mouse's button had to be held still for 300 ms first,
    // within 18 px: pressed and drawn at once, as anyone does, nothing happened at all.
    testWidgets('a mouse pressed and drawn along at once, with no wait, takes the chat with it', (tester) async {
      final c = await open(tester, long(300));
      c.jumpTo(48.0 * 100);
      await settle(tester);
      final box = tester.getRect(rail);
      final y0 = painter(tester).tall / 2;
      final under = _nearest(painter(tester), y0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset(box.center.dx, box.top + y0));
      addTearDown(mouse.removePointer);
      await mouse.down(Offset(box.center.dx, box.top + y0));
      await tester.pump(const Duration(milliseconds: 8));
      await mouse.moveBy(const Offset(0, -40), timeStamp: const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 16));
      await mouse.moveBy(const Offset(3, -80), timeStamp: const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
      expect(c.offset, greaterThan(48.0 * 100 + 600), reason: 'already well on the way, 60 ms after the press');
      await settle(tester);
      expect(tester.getRect(find.byKey(ValueKey('row-${300 - (under + 20)}'))).center.dy, closeTo(300, 1), reason: '120 up the map is twenty messages older');
      await mouse.up();
      await settle(tester);
      expect(c.offset, closeTo(48.0 * (under + 20) + 24 - 300, 1), reason: 'and it stays there');
      expect(tester.takeException(), isNull);
    });

    testWidgets('held near the map\'s top or foot, or past it, the map rolls on: one hold goes through the whole chat', (tester) async {
      final c = await open(tester, long(900));
      c.jumpTo(48.0 * 300);
      await settle(tester);
      final box = tester.getRect(rail);
      final p0 = painter(tester);
      final at0 = p0.place(p0.tall).at;
      final topLine = _nearest(p0, 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: box.center);
      addTearDown(mouse.removePointer);
      await mouse.down(box.center);
      await settle(tester);
      // To just under the map's top: inside the zone that rolls it.
      await mouse.moveTo(Offset(box.center.dx, box.top + 6));
      for (var f = 0; f < 60; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final rolled = painter(tester).place(p0.tall).at;
      expect(rolled, greaterThan(at0 + 20 * ChatRail.pitch), reason: 'the map has rolled toward older messages under a pointer that is still');
      expect(painter(tester).seen.lo, greaterThan(topLine), reason: 'and the chat with it, past what the map showed when it was taken hold of');
      // Past the top it rolls faster.
      await mouse.moveTo(Offset(box.center.dx, box.top - 40));
      final before = painter(tester).place(p0.tall).at;
      for (var f = 0; f < 60; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(painter(tester).place(p0.tall).at - before, greaterThan(rolled - at0));
      // Held there, it comes to the oldest message and rests.
      for (var f = 0; f < 600 && c.offset < c.position.maxScrollExtent; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await settle(tester);
      expect(c.offset, closeTo(c.position.maxScrollExtent, 1), reason: 'the oldest end');
      expect(find.byKey(const ValueKey('row-1')), findsOneWidget);
      // Back in the middle it rolls no more; at the foot it rolls back toward the newest.
      await mouse.moveTo(box.center);
      await settle(tester);
      final rested = painter(tester).place(p0.tall).at;
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter(tester).place(p0.tall).at, rested);
      await mouse.moveTo(Offset(box.center.dx, box.bottom - 4));
      for (var f = 0; f < 60; f++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(painter(tester).place(p0.tall).at, lessThan(rested - 20 * ChatRail.pitch));
      await mouse.up();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-26: "when clicking something far up it doesn't go all the way to the message because it's still
    // loading i assume". Among rows of very different heights (a few lines of talk among pictures) the map's guesses at
    // where an unbuilt row was went back and forth, fourteen times, and ended hundreds of pixels from the message with
    // hundreds of rows built on the way.
    testWidgets('a press among rows of very different heights ends on the message, with only what is near it built', (tester) async {
      for (final tall in <double Function(int)>[
        (i) => i % 9 == 8 ? 28.0 : 320.0,
        (i) => (i ~/ 40).isEven ? 28.0 : 320.0,
        (i) => (i ~/ 25).isEven ? 320.0 : 28.0,
        (i) => i < 26 ? 28.0 : 240.0 + (i * 37 % 80),
      ]) {
        final built = <int>[];
        final c = await open(tester, long(420), tall: tall, built: built);
        for (final to in [0.02, 0.3, 0.97, 0.5, 0.0]) {
          final box = tester.getRect(rail);
          final p = painter(tester);
          final y = (p.tall * to).clamp(1.0, p.tall - 1);
          final mark = _nearest(p, y);
          built.clear();
          await tester.tapAt(Offset(box.center.dx, box.top + p.yOf(mark)));
          await settle(tester);
          final row = find.byKey(ValueKey('row-${420 - mark}'));
          expect(row, findsOneWidget, reason: 'message $mark is built');
          final r = tester.getRect(row);
          final atEnd = c.offset <= 0.5 || c.offset >= c.position.maxScrollExtent - 0.5;
          if (!atEnd) expect(r.center.dy, closeTo(300, 1), reason: 'message $mark in the middle of the screen');
          expect(r.bottom > 0 && r.top < 600, isTrue, reason: 'message $mark on the screen');
          expect(built.length, lessThan(90), reason: 'only what is near it and on the short run in to it');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a press ends on the message though what is under it grows after, as a picture that loads does', (tester) async {
      final marks = ValueNotifier(long(420));
      // Every third message is 40 tall when first built and 240 a moment later.
      final c = await openOn(tester, marks, row: (k) => k % 3 == 0 ? const _Grows(from: 40, to: 240) : SizedBox(height: 30.0 + k % 50));
      await tester.pump(const Duration(milliseconds: 300));
      final box = tester.getRect(rail);
      final p = painter(tester);
      final mark = _nearest(p, 12);
      await tester.tapAt(Offset(box.center.dx, box.top + p.yOf(mark)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // On its way; then everything round it loads.
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      final r = tester.getRect(find.byKey(ValueKey('row-${420 - mark}')));
      expect(r.center.dy, closeTo(300, 1), reason: 'still in the middle after what is under it grew');
      // And it is let go once the chat is scrolled by hand.
      await tester.drag(find.byType(ChatListView), const Offset(0, 60));
      await settle(tester);
      expect(tester.getRect(find.byKey(ValueKey('row-${420 - mark}'))).center.dy, greaterThan(340));
      expect(c.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a press runs the chat in to the message: near at once, then the last of the way', (tester) async {
      final c = await open(tester, long(300));
      final box = tester.getRect(rail);
      final p = painter(tester);
      final mark = _nearest(p, 20);
      expect(mark, greaterThan(70), reason: 'far: some eighty messages up');
      final to = 48.0 * mark + 24 - 300;
      await tester.tapAt(Offset(box.center.dx, box.top + p.yOf(mark)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(c.offset, greaterThan(to - ChatRail.runway - 1), reason: 'put near at once: no further off than the runway');
      expect(c.offset, lessThan(to - 100), reason: 'and not yet there');
      final seen = <double>[c.offset];
      for (var f = 0; f < 20; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.add(c.offset);
      }
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'only ever toward it');
      }
      expect(c.offset, closeTo(to, 0.5), reason: 'there, in a quarter of a second');
      // Scrolled by a wheel on the way, the run is given up: the chat is the person's.
      await tester.tapAt(Offset(box.center.dx, tester.getRect(rail).bottom - 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final mid = c.offset;
      c.position.pointerScroll(120);
      await settle(tester);
      expect(c.offset, closeTo(mid + 120, 40), reason: 'left where the wheel put it, not run on to the foot');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new message while one is held: the map does not move, and the chat stays on the message held', (tester) async {
      final marks = ValueNotifier(long(300));
      await openOn(tester, marks);
      final box = tester.getRect(rail);
      final p = painter(tester);
      final mark = _nearest(p, p.tall * 0.3);
      await tester.tapAt(Offset(box.center.dx, box.top + p.yOf(mark)));
      await settle(tester);
      final key = ValueKey('row-${300 - mark}');
      final was = tester.getRect(find.byKey(key));
      expect(was.center.dy, closeTo(300, 1));
      final lines = [for (final i in [mark - 20, mark, mark + 20]) painter(tester).yOf(i)];
      // Two more at the foot: every message is two further up the list.
      marks.value = [
        RailMark(at: _now + 2 * _minute, who: 'maya', mine: false, name: 'Maya Chen', text: 'line 302'),
        RailMark(at: _now + _minute, who: 'me', mine: true, name: 'You', text: 'line 301'),
        ...marks.value,
      ];
      await tester.pump();
      expect(tester.getRect(find.byKey(ValueKey('row-${300 - mark}'))), was, reason: 'the message held has not moved on the screen');
      expect([for (final i in [mark - 20, mark, mark + 20]) painter(tester).yOf(i + 2)], lines, reason: 'nor has any line of the map');
      await settle(tester);
      expect(tester.getRect(find.byKey(ValueKey('row-${300 - mark}'))), was);
      expect([for (final i in [mark - 20, mark, mark + 20]) painter(tester).yOf(i + 2)], lines);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-25: "just allow scrolling normally".
    testWidgets('a wheel turned over the map scrolls the chat', (tester) async {
      final c = await open(tester, _week());
      expect(c.offset, 0);
      // Up the page, toward what is older: the chat is drawn bottom up, so its scroll grows.
      await tester.sendEventToBinding(PointerScrollEvent(position: tester.getCenter(rail), kind: PointerDeviceKind.mouse, scrollDelta: const Offset(0, -300)));
      await settle(tester);
      expect(c.offset, closeTo(300, 1));
      await tester.sendEventToBinding(PointerScrollEvent(position: tester.getCenter(rail), kind: PointerDeviceKind.mouse, scrollDelta: const Offset(0, 500)));
      await settle(tester);
      expect(c.offset, closeTo(0, 1));
    });

    testWidgets('two fingers on a trackpad over the map scroll the chat too', (tester) async {
      final c = await open(tester, _week());
      final at = tester.getCenter(rail);
      final pad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pad.panZoomStart(at);
      await pad.panZoomUpdate(at, pan: const Offset(0, 60));
      await pad.panZoomUpdate(at, pan: const Offset(0, 260));
      await pad.panZoomEnd();
      await settle(tester);
      expect(c.offset, greaterThan(150));
    });

    testWidgets('a finger drawn over the map scrolls the chat as it does over the chat, with its glide after, and a finger put down stops the glide', (tester) async {
      final c = await open(tester, long(300));
      // Down the screen: toward what is older.
      await tester.drag(rail, const Offset(0, 200));
      await tester.pump();
      expect(c.offset, inInclusiveRange(170, 200), reason: 'the chat goes with the finger');
      await settle(tester);
      final rested = c.offset;
      await tester.fling(rail, const Offset(0, 200), 2500);
      final let = c.offset;
      expect(let, greaterThan(rested + 150));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.offset, greaterThan(let + 50), reason: 'it glides on once let go');
      final touch = await tester.startGesture(tester.getCenter(rail));
      await tester.pump(const Duration(milliseconds: 16));
      final stopped = c.offset;
      await tester.pump(const Duration(milliseconds: 100));
      expect(c.offset, stopped, reason: 'held where the finger came down');
      await touch.moveBy(const Offset(0, -80));
      await touch.up();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-25: "it's a bit glitchy though when getting to the top or bottom dont change the main size of the
    // chatmap scroll it up and down as we go back through history". The map fitted every message into its height: 60
    // messages were 9 apart, 200 were 6 apart and several to a line, so a page of older ones drew it all again.
    testWidgets('older messages loaded in at the top leave the map its size and its lines as far apart, and it glides to them', (tester) async {
      final marks = ValueNotifier(long(50));
      final c = await openOn(tester, marks);
      expect(painter(tester).ticks, hasLength(50), reason: 'a line a message');
      expect(painter(tester).yOf(0) - painter(tester).yOf(1), ChatRail.pitch);
      c.jumpTo(c.position.maxScrollExtent);
      await settle(tester);
      final box = tester.getRect(rail);
      // All of it fits: in the map's middle, not at its foot (Matt, 2026-11-26: "center the chat map on right side").
      final tall = painter(tester).tall;
      expect(painter(tester).yOf(0), tall / 2 + 50 * ChatRail.pitch / 2 - ChatRail.pitch / 2);
      expect(painter(tester).yOf(49), tall / 2 - 50 * ChatRail.pitch / 2 + ChatRail.pitch / 2);
      for (final n in [200, 500]) {
        final was = [for (final i in [0, 30, 49]) painter(tester).yOf(i)];
        marks.value = long(n);
        await tester.pump();
        expect([for (final i in [0, 30, 49]) painter(tester).yOf(i)], was, reason: 'no line jumps');
        await settle(tester);
        expect(tester.getRect(rail), box, reason: 'the map is where it was and as big, with $n');
        expect(painter(tester).ticks, hasLength(n), reason: 'still a line a message');
        expect(painter(tester).yOf(0) - painter(tester).yOf(1), ChatRail.pitch, reason: 'as far apart as they were');
        // Glided on to its frame: what is on the screen (the oldest dozen or so of the fifty) in its middle.
        expect(painter(tester).yOf(44), closeTo(painter(tester).tall / 2, ChatRail.pitch * 1.5));
      }
    });

    // Matt, 2026-11-26: "have it scroll up and down like there is a frame of chat history we're viewing".
    testWidgets('a chat longer than the map: the map is a frame on what is on the screen, moved with the chat, smoothly, and rests at each end', (tester) async {
      final marks = ValueNotifier(long(300));
      final c = await openOn(tester, marks);
      final size = tester.getSize(rail);
      final tall = painter(tester).tall;
      expect(tall, 540, reason: 'nine tenths of the chat\'s height, in whole lines');
      expect(painter(tester).yOf(0), tall - ChatRail.pitch / 2, reason: 'the newest at its foot');
      // Near the newest end the map rests at its foot.
      c.jumpTo(48.0 * 20);
      await settle(tester);
      expect(painter(tester).yOf(0), tall - ChatRail.pitch / 2);
      // Further back: what is on the screen (12.5 rows, from 120 up) is in the map's middle.
      c.jumpTo(48.0 * 120);
      await settle(tester);
      expect(painter(tester).yOf(126), closeTo(tall / 2, ChatRail.pitch));
      final was = painter(tester).yOf(100);
      c.jumpTo(48.0 * 120 + 20);
      await tester.pump();
      expect(painter(tester).yOf(100), closeTo(was + ChatRail.pitch * 20 / 48, 0.01), reason: 'by exactly as much as the chat was scrolled');
      final held = painter(tester).yOf(100);
      c.jumpTo(48.0 * 110);
      await settle(tester);
      expect(painter(tester).yOf(100), closeTo(held - ChatRail.pitch * (10 + 20 / 48), 0.01), reason: 'back down, and the map with it');
      // The oldest end: its line at the map's top, and no further.
      c.jumpTo(c.position.maxScrollExtent);
      await settle(tester);
      expect(painter(tester).yOf(299), ChatRail.pitch / 2);
      expect(tester.getSize(rail), size);
      // Older ones loaded there: nothing jumps, the map glides on to put what is on the screen in its middle, and
      // scrolling on up takes it up with it.
      marks.value = long(450);
      await tester.pump();
      expect(painter(tester).yOf(299), ChatRail.pitch / 2);
      await settle(tester);
      expect(painter(tester).yOf(294), closeTo(tall / 2, ChatRail.pitch));
      expect(tester.getSize(rail), size);
      final up = painter(tester).yOf(299);
      c.jumpTo(c.offset + 48);
      await settle(tester);
      expect(painter(tester).yOf(299), closeTo(up + ChatRail.pitch, 0.01));
      // And the newest end again.
      c.jumpTo(0);
      await settle(tester);
      expect(painter(tester).yOf(0), tall - ChatRail.pitch / 2);
      expect(tester.getSize(rail), size);
    });

    testWidgets('pulled past an end, as a phone\'s list can be, the map does not move or change its size', (tester) async {
      final c = await openOn(tester, ValueNotifier(long(300)), physics: const BouncingScrollPhysics());
      final size = tester.getSize(rail);
      c.jumpTo(c.position.maxScrollExtent);
      await settle(tester);
      final top = painter(tester).yOf(299);
      // A finger pulling the oldest end down past where it stops.
      final touch = await tester.startGesture(const Offset(200, 200));
      await touch.moveBy(const Offset(0, 30));
      await touch.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(c.offset, greaterThan(c.position.maxScrollExtent + 20), reason: 'pulled past the end');
      expect(painter(tester).yOf(299), top);
      expect(tester.getSize(rail), size);
      await touch.up();
      await settle(tester);
      // And the newest end.
      c.jumpTo(0);
      await settle(tester);
      final foot = painter(tester).yOf(0);
      final pull = await tester.startGesture(const Offset(200, 400));
      await pull.moveBy(const Offset(0, -30));
      await pull.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(c.offset, lessThan(-20));
      expect(painter(tester).yOf(0), foot);
      expect(tester.getSize(rail), size);
      await pull.up();
      await settle(tester);
    });
  });
}

/// A row that is [from] tall when first built and [to] tall 150 ms later, as one whose picture loads.
class _Grows extends StatefulWidget {
  const _Grows({required this.from, required this.to});
  final double from, to;

  @override
  State<_Grows> createState() => _GrowsState();
}

class _GrowsState extends State<_Grows> {
  late double _tall = widget.from;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 150), () => setState(() => _tall = widget.to));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(height: _tall);
}

/// The message whose line is drawn nearest [y] down the map.
int _nearest(RailPainter p, double y) {
  var best = 0;
  for (var i = 1; i < p.ticks.length; i++) {
    if ((p.yOf(i) - y).abs() < (p.yOf(best) - y).abs()) best = i;
  }
  return best;
}
