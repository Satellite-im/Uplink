import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/chat_rows.dart';

// Matt, 2026-11-26, of the chat map: "when clicking something far up it doesn't go all the way to the message because
// it's still loading i assume and it's overall still kind of glitchy ... do a revamp to make it far more performant and
// smooth". lib/ui/chat_rows.dart: the list a chat is drawn in, able to go straight to any of its rows.

/// Rows of very different heights, the same each run: 28 to 320.
double _tall(int i) => 28.0 + (i * 7919 % 293);

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

/// A row that notes each time one of it is made anew.
class _Counted extends StatefulWidget {
  const _Counted({super.key, required this.made, required this.message, required this.child});
  final Set<int> made;
  final int message;
  final Widget child;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.made.add(widget.message);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Asks for its row to be kept when it is off the screen.
class _KeptAlive extends StatefulWidget {
  const _KeptAlive({required this.child});
  final Widget child;

  @override
  State<_KeptAlive> createState() => _KeptAliveState();
}

class _KeptAliveState extends State<_KeptAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// A row that asks to be kept when it is off the screen, as one playing a video does; [made] holds 1 for each made.
class _Kept extends StatefulWidget {
  const _Kept({required this.made});
  final Set<int> made;

  @override
  State<_Kept> createState() => _KeptState();
}

class _KeptState extends State<_Kept> with AutomaticKeepAliveClientMixin {
  static var _count = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.made.add(++_count);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return const SizedBox(height: 90);
  }
}

/// A chat's list, 400 by 600 at the top left of the test's screen, drawn bottom up with 8 of padding at each end. Every
/// row built is noted in [built]. [stock] is the plain list it is made from, to compare.
Widget _list(ScrollController c, int n, {List<int>? built, bool stock = false, Widget Function(int i)? row, String? chat, ScrollPhysics? physics, double height = 600, int? Function(Key key)? find}) {
  Widget build(BuildContext context, int i) {
    built?.add(i);
    return KeyedSubtree(key: ValueKey('row-$i'), child: row?.call(i) ?? SizedBox(height: _tall(i)));
  }

  const padding = EdgeInsets.symmetric(vertical: 8);
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        height: height,
        child: stock
            ? ListView.builder(controller: c, reverse: true, physics: physics, padding: padding, itemCount: n, itemBuilder: build)
            : ChatListView.builder(controller: c, reverse: true, physics: physics, padding: padding, itemCount: n, itemBuilder: build, chat: chat, findChildIndexCallback: find),
      ),
    ),
  );
}

Finder _row(int i) => find.byKey(ValueKey('row-$i'));

RenderChatRows _rows(ScrollController c) => RenderChatRows.under(c.position)!;

/// Every row built stands on the one before it, and where the heights say it is.
void _sound(WidgetTester tester, ScrollController c) {
  final list = _rows(c);
  double? end;
  int? index;
  for (var child = list.firstChild; child != null; child = list.childAfter(child)) {
    final d = child.parentData! as SliverMultiBoxAdaptorParentData;
    if (end != null) {
      expect(d.layoutOffset, closeTo(end, 1e-6), reason: 'row ${d.index} stands on row $index');
      expect(d.index, index! + 1, reason: 'no row missing');
    }
    expect(d.layoutOffset, closeTo(list.heights.before(d.index!), 0.02), reason: 'row ${d.index} is where the heights say');
    expect(list.heights.of(d.index!), child.size.height, reason: 'row ${d.index} is as tall as measured');
    end = d.layoutOffset! + child.size.height;
    index = d.index;
  }
}

void main() {
  setUp(RowHeights.clear);

  group('the heights', () {
    test('where a row starts and which row is at an offset, against plain sums, through every change', () {
      final rng = math.Random(7);
      final h = RowHeights(guess: 50);
      final plain = <double>[];
      void same() {
        expect(h.length, plain.length);
        var sum = 0.0;
        for (var i = 0; i < plain.length; i++) {
          expect(h.before(i), closeTo(sum, 1e-6), reason: 'before $i');
          expect(h.of(i), plain[i]);
          sum += plain[i];
        }
        expect(h.whole, closeTo(sum, 1e-6));
        for (var k = 0; k < 20 && plain.isNotEmpty; k++) {
          final offset = rng.nextDouble() * (sum + 40) - 20;
          // The last row that starts at or before the offset.
          var want = 0, start = 0.0;
          for (var i = 0; i < plain.length; i++) {
            if (start <= offset) want = i;
            start += plain[i];
          }
          expect(h.at(offset), want, reason: 'the row at $offset of $sum');
        }
      }

      expect(h.fresh, isTrue);
      expect(h.at(100), 0);
      // Which rows have been measured, and what the rows past a shorter end measured: they come back as they were.
      final known = <bool>[];
      final past = <int, double>{};
      for (var round = 0; round < 400; round++) {
        switch (rng.nextInt(10)) {
          case 0:
            // Older messages read in: more rows at the end, each as it measured when the list last held it, or taken
            // to be the mean of those measured.
            final more = rng.nextInt(40);
            final guess = h.guess;
            for (var k = 0; k < more; k++) {
              final was = past.remove(plain.length);
              plain.add(was ?? guess);
              known.add(was != null);
            }
            h.resize(plain.length);
          case 1:
            final fewer = math.min(plain.length, rng.nextInt(12));
            for (var i = plain.length - fewer; i < plain.length; i++) {
              if (known[i]) {
                past[i] = plain[i];
              } else {
                past.remove(i);
              }
            }
            plain.removeRange(plain.length - fewer, plain.length);
            known.removeRange(known.length - fewer, known.length);
            h.resize(plain.length);
          case 2:
            // New messages at the start, or a little way in (over one still going up): every row from there on is
            // that many further up, those past the end too.
            if (plain.isEmpty) continue;
            final at = rng.nextInt(math.min(3, plain.length)), by = 1 + rng.nextInt(3);
            final guess = h.guess;
            plain.insertAll(at, List.filled(by, guess));
            known.insertAll(at, List.filled(by, false));
            final moved = {for (final e in past.entries) e.key + by: e.value};
            past
              ..clear()
              ..addAll(moved);
            h.insert(at, by);
          default:
            if (plain.isEmpty) continue;
            final i = rng.nextInt(plain.length);
            final tall = rng.nextInt(8) == 0 ? 0.0 : rng.nextDouble() * 400;
            plain[i] = tall;
            known[i] = true;
            h.set(i, tall);
            expect(h.known(i), isTrue);
        }
        if (round % 20 == 0) same();
      }
      same();
      expect(h.fresh, isFalse);
    });

    test('a row not yet measured is taken to be the mean of those that are, and forgetting keeps the heights as guesses', () {
      final h = RowHeights(guess: 64)..resize(4);
      expect(h.whole, 4 * 64);
      h.set(0, 100);
      h.set(1, 200);
      expect(h.guess, 150);
      h.resize(6);
      expect(h.of(5), 150, reason: 'the mean of the two measured');
      expect(h.of(3), 64, reason: 'taken as it was when it was added');
      expect(h.whole, 100 + 200 + 64 + 64 + 150 + 150);
      h.forget();
      expect(h.known(0), isFalse);
      expect(h.of(0), 100, reason: 'still the best there is');
      expect(h.guess, 150);
      expect(h.fresh, isFalse);
    });

    test('kept by chat, the latest sixty-four of them', () {
      final a = RowHeights.named('sms:1');
      expect(identical(RowHeights.named('sms:1'), a), isTrue);
      for (var i = 0; i < RowHeights.most; i++) {
        RowHeights.named('inbox:x:$i');
      }
      expect(identical(RowHeights.named('sms:1'), a), isFalse, reason: 'the oldest is let go');
      final b = RowHeights.named('inbox:x:5');
      RowHeights.forgetAll('inbox:x:');
      expect(identical(RowHeights.named('inbox:x:5'), b), isFalse);
    });
  });

  group('the list', () {
    testWidgets('is the plain list where nothing is sent far: the same rows at the same places, offset for offset', (tester) async {
      final places = <bool, List<String>>{};
      for (final stock in [true, false]) {
        final c = ScrollController();
        final seen = places[stock] = [];
        await tester.pumpWidget(_list(c, 300, stock: stock));
        void note() {
          final on = [for (var i = 0; i < 300; i++) if (_row(i).evaluate().isNotEmpty) '$i@${tester.getRect(_row(i)).top.toStringAsFixed(2)}'];
          seen.add('${c.offset.toStringAsFixed(2)}: ${on.join(' ')}');
        }

        note();
        // Up by less than a screen at a time, then down again, then to the oldest end a screen at a time.
        for (final by in [120.0, 300.0, 599.0, 45.5, -200.0, -400.0, 250.0, 250.0, -900.0]) {
          c.jumpTo((c.offset + by).clamp(0.0, c.position.maxScrollExtent));
          await tester.pump();
          note();
        }
        for (var k = 0; k < 120 && c.offset < c.position.maxScrollExtent; k++) {
          c.jumpTo(math.min(c.offset + 560, c.position.maxScrollExtent));
          await tester.pump();
          note();
        }
        expect(_row(299), findsOneWidget, reason: 'the oldest');
        expect(tester.getRect(_row(299)).top, closeTo(8, 0.01));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
      expect(places[false], places[true]);
    });

    testWidgets('sent far, it builds what is near and not what is between', (tester) async {
      final counts = <bool, int>{};
      for (final stock in [true, false]) {
        final c = ScrollController();
        final built = <int>[];
        await tester.pumpWidget(_list(c, 3000, built: built, stock: stock));
        built.clear();
        c.jumpTo(c.position.maxScrollExtent * 0.8);
        await tester.pump();
        counts[stock] = built.length;
        built.clear();
        c.jumpTo(0);
        await tester.pump();
        expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01), reason: 'the newest at the foot again');
        if (!stock) expect(built.length, lessThan(30));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
      expect(counts[true], greaterThan(500), reason: 'the plain list lays out every row on the way');
      expect(counts[false], lessThan(30));
    });

    testWidgets('a row held is in the middle in the next frame, exactly, built or not, and stays as what is under it grows', (tester) async {
      final c = ScrollController();
      final built = <int>[];
      await tester.pumpWidget(_list(c, 3000, built: built, row: (i) => i % 3 == 0 ? const _Grows(from: 40, to: 240) : SizedBox(height: _tall(i))));
      await tester.pump(const Duration(milliseconds: 400));
      final rows = _rows(c);
      for (final k in [2500, 40, 1234, 1236, 7, 2990]) {
        built.clear();
        rows.hold(c.position, k);
        await tester.pump();
        expect(built.length, lessThan(30), reason: 'only what is near row $k');
        expect(tester.getRect(_row(k)).center.dy, closeTo(300, 0.01), reason: 'row $k in the middle at once');
        expect(rows.held?.index, k);
        _sound(tester, c);
        // What was built round it grows a moment later (every third row, from 40 to 240).
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        expect(tester.getRect(_row(k)).center.dy, closeTo(300, 0.01), reason: 'row $k still in the middle');
        _sound(tester, c);
        expect(tester.takeException(), isNull);
      }
      // Its foot at the screen's foot, and its top at the top.
      rows.hold(c.position, 1500, within: 0, align: 0);
      await tester.pump();
      expect(tester.getRect(_row(1500)).bottom, closeTo(600, 0.01));
      rows.hold(c.position, 1500, within: 1, align: 1);
      await tester.pump();
      expect(tester.getRect(_row(1500)).top, closeTo(0, 0.01));
      rows.hold(c.position, 1500, shift: 100);
      await tester.pump();
      expect(tester.getRect(_row(1500)).center.dy, closeTo(400, 0.01), reason: 'the list 100 further up, the row 100 lower');
    });

    testWidgets('at either end a row is held as near the middle as the list goes, with nothing springing back', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 400, physics: const BouncingScrollPhysics()));
      final rows = _rows(c);
      rows.hold(c.position, 399);
      await tester.pump();
      expect(tester.getRect(_row(399)).top, closeTo(8, 0.01), reason: 'the oldest under the padding at the top');
      expect(c.offset, closeTo(c.position.maxScrollExtent, 0.01));
      final there = c.offset;
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.offset, there, reason: 'nothing to settle');
      rows.hold(c.position, 0);
      await tester.pump();
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(c.offset, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a held row is let go when the list is moved by anything else', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 600, row: (i) => i % 2 == 0 ? const _Grows(from: 40, to: 200) : SizedBox(height: _tall(i))));
      final rows = _rows(c);
      rows.hold(c.position, 300);
      await tester.pump();
      expect(rows.held?.index, 300);
      // A finger on the list.
      await tester.drag(find.byType(ChatListView), const Offset(0, 90));
      await tester.pump();
      expect(rows.held, isNull);
      final at = tester.getRect(_row(300)).center.dy;
      expect(at, closeTo(390, 1), reason: 'gone with the finger');
      // And a wheel, and the controller.
      rows.hold(c.position, 300);
      await tester.pump();
      expect(rows.held, isNotNull);
      c.position.pointerScroll(40);
      await tester.pump();
      expect(rows.held, isNull);
      rows.hold(c.position, 300);
      await tester.pump();
      c.jumpTo(c.offset - 33);
      await tester.pump();
      expect(rows.held, isNull);
      rows.hold(c.position, 300);
      await tester.pump();
      rows.release();
      expect(rows.held, isNull);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });

    testWidgets('read down from far up, row 0 ends at the foot at offset 0, every frame whole, at any speed', (tester) async {
      for (final step in [37.0, 300.0, 590.0, 2400.0]) {
        final c = ScrollController();
        await tester.pumpWidget(_list(c, 1500));
        final rows = _rows(c);
        rows.hold(c.position, 1400);
        await tester.pump();
        var frames = 0;
        while (c.offset > 0 && frames < 20000) {
          c.jumpTo(math.max(0.0, c.offset - step));
          await tester.pump();
          _sound(tester, c);
          frames++;
        }
        expect(c.offset, 0);
        expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01), reason: 'the newest at the foot, in steps of $step');
        // And up to the oldest.
        while (c.offset < c.position.maxScrollExtent && frames < 40000) {
          c.jumpTo(math.min(c.position.maxScrollExtent, c.offset + step));
          await tester.pump();
          _sound(tester, c);
          frames++;
        }
        expect(tester.getRect(_row(1499)).top, closeTo(8, 0.01), reason: 'the oldest at the top, in steps of $step');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // Rows near the newest that have never been laid out (the chat sent far up from the start) are taken to be the mean
    // height until they come onto the screen. As each does, the list corrects the offset under what is there: read
    // down at any pace, what is on the screen must move by exactly as much as it was scrolled, in every frame.
    testWidgets('walked down from far up over rows never measured, in steps of any size, nothing on the screen slips', (tester) async {
      final rng = math.Random(11);
      var frames = 0;
      for (var walk = 0; walk < 30; walk++) {
        final seed = rng.nextInt(1 << 20);
        // Rows in runs of several kinds: short, tall, a few of them many screens tall.
        double tall(int i) {
          final r = (i * 2654435761 + seed) % 1000;
          final run = ((i ~/ (3 + seed % 17)) + seed) % 4;
          if (run == 0) return 24.0 + r % 30;
          if (run == 1) return 180.0 + r % 260;
          if (r < 30) return 900.0 + r * 20;
          return 40.0 + r % 120;
        }

        final c = ScrollController();
        await tester.pumpWidget(_list(c, 500, row: (i) => SizedBox(height: tall(i))));
        final rows = _rows(c);
        rows
          ..hold(c.position, 150 + rng.nextInt(300))
          ..release();
        await tester.pump();
        final step = [37.0, 120.0, 300.0, 590.0, 850.0, 1400.0][walk % 6] * (0.5 + rng.nextDouble());
        Map<int, double> seen() => {
              for (var child = rows.firstChild; child != null; child = rows.childAfter(child)) rows.indexOf(child): child.localToGlobal(Offset.zero).dy,
            };
        while (c.offset > 0) {
          final before = seen(), at = c.offset, to = math.max(0.0, at - step);
          c.jumpTo(to);
          await tester.pump();
          frames++;
          final after = seen();
          final shared = after.keys.where(before.containsKey);
          // Toward the newest the page goes up the screen by as much as the scroll comes down.
          if (shared.isNotEmpty) expect(after[shared.first]! - before[shared.first]!, closeTo(to - at, 0.02), reason: 'walk $walk, a step of ${step.round()} from ${at.round()}: row ${shared.first} moved with the scroll');
          _sound(tester, c);
        }
        expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.02), reason: 'walk $walk ends with the newest at the foot');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
      expect(frames, greaterThan(2000));
    });

    testWidgets('a fling down through rows never laid out glides on to the newest', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 800));
      _rows(c).hold(c.position, 700);
      await tester.pump();
      for (var k = 0; k < 40 && c.offset > 0; k++) {
        await tester.fling(find.byType(ChatListView), const Offset(0, -300), 6000);
        for (var f = 0; f < 200; f++) {
          await tester.pump(const Duration(milliseconds: 16));
          _sound(tester, c);
          if (!c.position.isScrollingNotifier.value) break;
        }
      }
      expect(c.offset, 0);
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('older messages read in at the end and a new one at the start, while far up and while a row is held', (tester) async {
      final c = ScrollController();
      final n = ValueNotifier(500);
      await tester.pumpWidget(ValueListenableBuilder<int>(valueListenable: n, builder: (context, count, _) => _list(c, count)));
      final rows = _rows(c);
      rows.hold(c.position, 480);
      await tester.pump();
      final was = tester.getRect(_row(480));
      n.value = 800;
      await tester.pump();
      expect(tester.getRect(_row(480)), was, reason: 'nothing moves as older ones come in over it');
      expect(rows.heights.length, 800);
      _sound(tester, c);
      rows.hold(c.position, 799);
      await tester.pump();
      expect(tester.getRect(_row(799)).top, closeTo(8, 0.01));
      n.value = 801;
      await tester.pump();
      _sound(tester, c);
      // Far fewer (a chat cleared but for its newest): the list is past its new end, and comes back to it as any
      // list pulled past its end does.
      n.value = 300;
      for (var f = 0; f < 90; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        _sound(tester, c);
      }
      expect(c.offset, closeTo(c.position.maxScrollExtent, 0.5));
      expect(tester.getRect(_row(299)).top, closeTo(8, 0.5), reason: 'the oldest left, at the top');
      expect(tester.takeException(), isNull);
    });

    testWidgets('its length is the heights\', and the screen can be made shorter or the list narrower under a held row', (tester) async {
      final c = ScrollController();
      final tall = ValueNotifier(600.0);
      await tester.pumpWidget(ValueListenableBuilder<double>(valueListenable: tall, builder: (context, t, _) => _list(c, 900, height: t)));
      final rows = _rows(c);
      expect(c.position.maxScrollExtent, closeTo(rows.heights.whole + 16 - 600, 0.01));
      rows.hold(c.position, 450);
      await tester.pump();
      expect(tester.getRect(_row(450)).center.dy, closeTo(300, 0.01));
      // A keyboard comes up: the row is in the middle of what is left.
      tall.value = 320;
      await tester.pump();
      expect(tester.getRect(_row(450)).center.dy, closeTo(160, 0.01));
      expect(c.position.maxScrollExtent, closeTo(rows.heights.whole + 16 - 320, 0.01));
      _sound(tester, c);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a chat opened again where it was left opens there, on the same rows, without laying out what is under them', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 2000, chat: 'sms:7'));
      _rows(c).hold(c.position, 1700);
      await tester.pump();
      final left = c.offset;
      final was = tester.getRect(_row(1700));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      // Opened again, its controller starting where it was left (ScrollMemory.controllerFor).
      final again = ScrollController(initialScrollOffset: left);
      addTearDown(again.dispose);
      final built = <int>[];
      await tester.pumpWidget(_list(again, 2000, built: built, chat: 'sms:7'));
      expect(tester.getRect(_row(1700)), was);
      expect(built.length, lessThan(30));
      expect(again.offset, left);
      // Another chat knows nothing: it opens as a plain list does.
      await tester.pumpWidget(const SizedBox());
      final other = ScrollController();
      addTearDown(other.dispose);
      await tester.pumpWidget(_list(other, 2000, chat: 'sms:8'));
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(tester.takeException(), isNull);
    });

    // A chat of messages by number, the newest first (message m is row newest - m), as a conversation is drawn: each
    // row keyed by its message and found again by that key, the list told what each row is ([named]) or not.
    // [window]: the list holds only its newest so many (a conversation's page, a space's 300). [going]: its first row
    // is one still going up, which stays first as messages come in over it.
    // [tall]: how tall a message's row is, where not the usual mix. [kept]: a message whose row asks to be kept alive
    // off the screen. [built]: every message a row is built for is noted there.
    Widget numbered(ScrollController c, ValueNotifier<int> newest, {Set<int>? made, bool named = true, bool keyed = true, bool stock = false, int? window, bool going = false, double Function(int m)? tall, int? kept, List<int>? built}) => ValueListenableBuilder<int>(
          valueListenable: newest,
          builder: (context, top, _) {
            final lead = going ? 1 : 0;
            Widget row(BuildContext context, int i) {
              if (i < lead) return const SizedBox(key: ValueKey('going'), height: 70, child: Text('going'));
              final m = top - (i - lead);
              built?.add(m);
              final box = SizedBox(height: (tall ?? _tall)(m), child: Text('m$m'));
              return _Counted(key: keyed ? ValueKey('m-$m') : null, made: made ?? {}, message: m, child: m == kept ? _KeptAlive(child: box) : box);
            }

            int? find(Key key) => key is ValueKey<String> && key.value.startsWith('m-') ? top - int.parse(key.value.substring(2)) + lead : (key == const ValueKey('going') ? 0 : null);
            final count = (window ?? top + 1) + lead;
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 600,
                  child: stock
                      ? ListView.builder(controller: c, reverse: true, itemCount: count, findChildIndexCallback: keyed ? find : null, itemBuilder: row)
                      : ChatListView.builder(controller: c, reverse: true, itemCount: count, findChildIndexCallback: keyed ? find : null, itemBuilder: row, idOf: named ? (i) => i < lead ? 'going' : top - (i - lead) : null),
                ),
              ),
            );
          },
        );
    Map<int, double> onScreen(WidgetTester tester) => {
          for (var m = 0; m < 1200; m++)
            if (find.text('m$m').evaluate().isNotEmpty) m: tester.getTopLeft(find.text('m$m')).dy,
        };

    testWidgets('a held row stays put as new messages come in at the start, and no row built is made again', (tester) async {
      final c = ScrollController();
      final newest = ValueNotifier(999);
      final states = <int>{};
      await tester.pumpWidget(numbered(c, newest, made: states));
      final rows = _rows(c);
      rows.hold(c.position, 600);
      await tester.pump();
      final message = find.byKey(const ValueKey('m-399'));
      final was = tester.getRect(message);
      expect(was.center.dy, closeTo(300, 0.01));
      // The rows built now, on the screen and just off it.
      final had = {for (var m = 300; m < 500; m++) if (find.byKey(ValueKey('m-$m')).evaluate().isNotEmpty) m};
      expect(had.length, greaterThan(2));
      states.clear();
      // Three new messages: every row is three further up.
      newest.value = 1002;
      await tester.pump();
      expect(tester.getRect(message).top, closeTo(was.top, 0.01), reason: 'the message held has not moved');
      expect(rows.held?.index, 603, reason: 'the same message, three rows up');
      expect(states.intersection(had), isEmpty, reason: 'no row that was built is made again: each is found by its key, and none is let go on the way');
      _sound(tester, c);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(message).top, closeTo(was.top, 0.01));
      expect(rows.heights.of(603), _tall(399), reason: 'its height came up the list with it');
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('reading far back with nothing held, a message that comes moves nothing on the screen; near the newest it comes in as ever', (tester) async {
      for (final keyed in [true, false]) {
        final c = ScrollController();
        final newest = ValueNotifier(999);
        await tester.pumpWidget(numbered(c, newest, keyed: keyed));
        for (var k = 0; k < 9; k++) {
          c.jumpTo(c.offset + 500);
          await tester.pump();
        }
        final was = onScreen(tester);
        expect(was.length, greaterThan(1));
        final at = c.offset;
        for (final more in [1, 2, 1]) {
          newest.value += more;
          await tester.pump();
          expect(onScreen(tester), was, reason: 'nothing on the screen moved (keyed rows: $keyed)');
          _sound(tester, c);
          await tester.pump(const Duration(milliseconds: 100));
          expect(onScreen(tester), was);
        }
        expect(c.offset, greaterThan(at + 4 * 28 - 1), reason: 'the chat is four messages further from its newest');
        // Read down to the newest: the four that came are there, each as tall as it is, the last at the foot.
        while (c.offset > 0) {
          c.jumpTo(math.max(0.0, c.offset - 250));
          await tester.pump();
          _sound(tester, c);
        }
        expect(tester.getRect(find.text('m1003')).bottom, closeTo(600, 0.01));
        // Near the newest (its row is built), one more comes in under what is there, as in a plain list: the scroll
        // stays and the page moves up to show it.
        c.jumpTo(40);
        await tester.pump();
        final near = onScreen(tester);
        newest.value++;
        await tester.pump();
        expect(c.offset, 40);
        expect(onScreen(tester)[1003], near[1003]! - _tall(1004));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // A conversation holds its newest so many and a space its newest 300: a message that comes there leaves the list
    // as long as it was (one in at the start, one out at the end). And a space's first row may be one still going up,
    // which stays first as messages come in over it.
    testWidgets('reading far back, a message that comes moves nothing where the list is no longer for it, nor where one going up stays first', (tester) async {
      for (final (window, going, keyed) in [(400, false, true), (400, false, false), (null, true, true), (300, true, false)]) {
        final c = ScrollController();
        final newest = ValueNotifier(999);
        await tester.pumpWidget(numbered(c, newest, window: window, going: going, keyed: keyed));
        for (var k = 0; k < 9; k++) {
          c.jumpTo(c.offset + 500);
          await tester.pump();
        }
        final was = onScreen(tester);
        expect(was.length, greaterThan(1));
        final count = _rows(c).heights.length;
        for (final more in [1, 3, 1]) {
          newest.value += more;
          await tester.pump();
          final now = onScreen(tester);
          for (final m in was.keys) {
            expect(now[m], closeTo(was[m]!, 0.01), reason: 'message $m where it was (the newest ${window ?? 'all'} held, one going up: $going, keyed: $keyed)');
          }
          _sound(tester, c);
        }
        if (window != null) expect(_rows(c).heights.length, count, reason: 'as long as it was');
        // And with a row held: the same message still.
        final rows = _rows(c);
        final lead = going ? 1 : 0;
        rows.hold(c.position, 150 + lead);
        await tester.pump();
        final held = newest.value - 150;
        final at = tester.getTopLeft(find.text('m$held')).dy;
        newest.value += 2;
        await tester.pump();
        expect(tester.getTopLeft(find.text('m$held')).dy, closeTo(at, 0.01), reason: 'the message held where it was');
        expect(rows.held?.index, 152 + lead);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // Back at the newest by a press on the map's foot, the list still held a row there, and as messages came it kept
    // that row where it was: the fourth was under the foot, the fifth not on the screen.
    testWidgets('a row held at the newest end is let go when a message comes: the chat follows, as a list never touched', (tester) async {
      final c = ScrollController();
      final newest = ValueNotifier(999);
      await tester.pumpWidget(numbered(c, newest));
      final rows = _rows(c);
      rows.hold(c.position, 600);
      await tester.pump();
      for (final row in [0, 2]) {
        rows.hold(c.position, row);
        await tester.pump();
        // As near the middle as the newest end lets it: at the foot, or a little over it.
        final at = c.offset;
        expect(at, lessThan(200));
        expect(rows.held, isNotNull);
        for (var k = 0; k < 6; k++) {
          newest.value++;
          await tester.pump();
          expect(c.offset, at, reason: 'the scroll stays');
          expect(tester.getRect(find.text('m${newest.value}')).bottom, closeTo(600 + at, 0.01), reason: 'and each new message comes in at the foot, the page going up for it');
        }
        expect(rows.held, isNull);
      }
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    // Pressed at the map's top the chat is at its oldest end, the row held kept from the middle by the end. Older
    // messages read in then lifted the end, and the row went to the middle by itself: everything moved half a screen.
    testWidgets('a row the list\'s end keeps from its place is held where it stands: older messages read in over it move nothing', (tester) async {
      final c = ScrollController();
      final n = ValueNotifier(300);
      await tester.pumpWidget(ValueListenableBuilder<int>(valueListenable: n, builder: (context, count, _) => _list(c, count, row: (i) => i % 4 == 0 ? const _Grows(from: 40, to: 200) : const SizedBox(height: 48))));
      final rows = _rows(c);
      rows.hold(c.position, 297);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.offset, closeTo(c.position.maxScrollExtent, 0.01), reason: 'the oldest end');
      final was = tester.getRect(_row(297));
      expect(was.center.dy, lessThan(250), reason: 'kept from the middle by the end');
      n.value = 400;
      await tester.pump();
      expect(tester.getRect(_row(297)), was, reason: 'nothing moved as older ones came in over it');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(_row(297)).top, closeTo(was.top, 0.01), reason: 'and it is still held: what grew under the new rows moved nothing either');
      expect(rows.held?.index, 297);
      _sound(tester, c);
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('a message that comes in the very frame the chat is scrolled does not take the scroll back', (tester) async {
      final c = ScrollController();
      final newest = ValueNotifier(999);
      await tester.pumpWidget(numbered(c, newest));
      for (var k = 0; k < 9; k++) {
        c.jumpTo(c.offset + 500);
        await tester.pump();
      }
      final was = onScreen(tester);
      // A turn of the wheel and a message, in one frame.
      c.position.pointerScroll(180);
      newest.value++;
      await tester.pump();
      final now = onScreen(tester);
      final shared = now.keys.where(was.containsKey).toList();
      expect(shared, isNotEmpty);
      for (final m in shared) {
        expect(now[m]! - was[m]!, closeTo(180, 0.01), reason: 'message $m went with the wheel, and no further for the message that came');
      }
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    // A chat opened again holding fewer messages than it did (a network's first page), then given the rest: the rows
    // that came back were each taken to be the mean of the few held, and the place it was left at was another message.
    testWidgets('a chat opened again shorter and then given its older messages has them as tall as they were: the place it was left at is the same message', (tester) async {
      final c = ScrollController();
      final n = ValueNotifier(240);
      // The newest eight are short ones.
      Widget chat(ScrollController c) => ValueListenableBuilder<int>(valueListenable: n, builder: (context, count, _) => _list(c, count, chat: 'inbox:x:short', row: (i) => SizedBox(height: i < 8 ? 36 : _tall(i))));
      await tester.pumpWidget(chat(c));
      for (var k = 0; k < 20; k++) {
        c.jumpTo(c.offset + 300);
        await tester.pump();
      }
      final left = c.offset;
      final was = {for (var i = 0; i < 240; i++) if (_row(i).evaluate().isNotEmpty) i: tester.getRect(_row(i)).top};
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      n.value = 8;
      final again = ScrollController(initialScrollOffset: left);
      addTearDown(again.dispose);
      await tester.pumpWidget(chat(again));
      n.value = 240;
      await tester.pump();
      // Where it was left, as the arrow puts it back once the chat holds that far (lib/ui/jump_to_latest.dart).
      again.jumpTo(left);
      await tester.pump();
      for (final i in was.keys.where((i) => was[i]! > 0 && was[i]! < 560)) {
        expect(tester.getRect(_row(i)).top, closeTo(was[i]!, 0.01), reason: 'row $i where it was left');
      }
      expect(tester.takeException(), isNull);
    });

    // Signed out of a network with one of its chats on the page: its heights were taken from under the list, which was
    // given new ones that knew nothing and laid out every row from its newest to where it stood (1562 in a frame).
    testWidgets('a chat forgotten while it is on the page keeps its rows until it goes', (tester) async {
      final c = ScrollController();
      final built = <int>[];
      final again = ValueNotifier(0);
      await tester.pumpWidget(ValueListenableBuilder<int>(valueListenable: again, builder: (context, _, _) => _list(c, 2000, built: built, chat: 'inbox:y:open')));
      final rows = _rows(c);
      rows.hold(c.position, 1500);
      await tester.pump();
      rows.release();
      final heights = rows.heights;
      final was = tester.getRect(_row(1500));
      RowHeights.forgetAll('inbox:y:');
      built.clear();
      again.value++;
      await tester.pump();
      expect(identical(rows.heights, heights), isTrue, reason: 'still its own');
      expect(tester.getRect(_row(1500)), was);
      expect(built.length, lessThan(40), reason: 'the rows on the page built again, and no others');
      // Gone from the page, it is forgotten: opened again it knows nothing.
      await tester.pumpWidget(const SizedBox());
      expect(identical(RowHeights.named('inbox:y:open'), heights), isFalse);
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    // Drawn fast along the map, a hold sends the list a dozen rows on at each frame: it walked there, building the
    // rows between and letting them go in the frame they were built.
    testWidgets('a row held a dozen rows on at each frame builds what is on the screen, not what is between', (tester) async {
      final c = ScrollController();
      final built = <int>[];
      await tester.pumpWidget(_list(c, 3000, built: built, row: (i) => SizedBox(height: 60.0 + i % 90)));
      final rows = _rows(c);
      rows.hold(c.position, 400);
      await tester.pump();
      built.clear();
      for (var f = 1; f <= 20; f++) {
        rows.hold(c.position, 400 + 13 * f);
        await tester.pump();
        expect(tester.getRect(_row(400 + 13 * f)).center.dy, closeTo(300, 0.01));
        _sound(tester, c);
      }
      // Some 9 rows fill the screen and what is kept ready round it.
      expect(built.length, lessThan(20 * 14), reason: 'about a screenful a frame, where the walk built the 13 between as well');
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    // A row under those built turned out far taller than it was taken to be, with the row held under it: what was
    // corrected for the one and for the other came to nothing between them, the rows were moved 640 up and the layout
    // left as it was made, and under half the screen had a row on it, for as long as nothing scrolled.
    testWidgets('a held row under a row far taller than it was taken to be: the screen is whole and the row in its place', (tester) async {
      for (final tallOne in [700.0, 1500.0]) {
        final c = ScrollController();
        await tester.pumpWidget(_list(c, 2000, row: (i) => SizedBox(height: i == 888 ? tallOne : 60)));
        // The newest four hundred read, so that what a row is taken to be is settled.
        for (var k = 0; k < 48; k++) {
          c.jumpTo(c.offset + 500);
          await tester.pump();
        }
        final rows = _rows(c);
        rows.hold(c.position, 900);
        await tester.pump();
        rows.release();
        expect(rows.first, greaterThan(888), reason: 'the tall one is under what is built, never laid out');
        rows.hold(c.position, 887);
        await tester.pump();
        for (final later in [Duration.zero, const Duration(milliseconds: 500)]) {
          if (later > Duration.zero) await tester.pump(later);
          expect(_row(887), findsOneWidget, reason: 'the row pressed is built (the one over it $tallOne tall)');
          expect(tester.getRect(_row(887)).center.dy, closeTo(300, 0.01));
          // Rows from the screen's top to its foot, with no gap.
          var top = 600.0, foot = 0.0;
          for (var i = rows.first; i <= rows.last; i++) {
            // (Those built off the screen, kept ready, are not found.)
            if (_row(i).evaluate().isEmpty) continue;
            final r = tester.getRect(_row(i));
            if (r.bottom <= 0 || r.top >= 600) continue;
            top = math.min(top, r.top);
            foot = math.max(foot, r.bottom);
          }
          expect(top, lessThanOrEqualTo(0.01));
          expect(foot, greaterThanOrEqualTo(599.99));
          expect(c.position.maxScrollExtent, closeTo(rows.heights.whole + 16 - 600, 0.01), reason: 'and its length is the heights\'');
          _sound(tester, c);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // The list took any move of the scroll under half a pixel in a frame for its own, and put the held row back: a
    // finger or two on a trackpad drawing the chat slowly, after a press on the map, moved nothing at all.
    testWidgets('a held row is let go by the least move of the chat by anything else, however slow', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 900));
      final rows = _rows(c);
      for (final step in [0.25, 0.4, 0.5, -0.3]) {
        rows.hold(c.position, 400);
        await tester.pump();
        final from = c.offset;
        final was = tester.getRect(_row(400)).top;
        for (var f = 0; f < 40; f++) {
          c.position.pointerScroll(step);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(rows.held, isNull, reason: 'let go at $step a frame');
        expect(c.offset - from, closeTo(40 * step, 0.01), reason: 'and the chat went with it');
        expect(tester.getRect(_row(400)).top - was, closeTo(40 * step, 0.01));
      }
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    // A chat of eight messages under two tall pictures, the eighth pressed: by what rows were taken to be it was far,
    // so everything built was let go and the list begun again there; where it really was, the pictures were still on
    // the screen, and had been made again (a picture loaded, a video playing, lost).
    testWidgets('a held row a few rows from those built is walked to: no row on the screen before and after is made again', (tester) async {
      for (final (count, row, tall) in <(int, int, double Function(int))>[
        (8, 7, (m) => m == 7 ? 700 : (m == 6 ? 300 : 40)),
        (1000, 989, (m) => m >= 996 ? 250 : 40),
      ]) {
        final c = ScrollController();
        final newest = ValueNotifier(count - 1);
        final made = <int>{};
        final built = <int>[];
        await tester.pumpWidget(numbered(c, newest, made: made, built: built, tall: tall));
        final before = onScreen(tester).keys.toSet();
        made.clear();
        built.clear();
        // By message: the row of message [row] (the newest is row 0).
        _rows(c).hold(c.position, count - 1 - row);
        await tester.pump();
        expect(tester.getRect(find.text('m$row')).height, greaterThan(0));
        final after = onScreen(tester).keys.toSet();
        expect(made.intersection(before).intersection(after), isEmpty, reason: 'what was on the screen and still is was not made again');
        expect(built.toSet().length, lessThan(after.length + 30), reason: 'and little is built that is not shown');
        _sound(tester, c);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // Reading a message taller than the screen (one row built), three messages come at once: the row built was moved
    // three places up by its key and a new one made in its old place, with a gap between, and it was not put back.
    testWidgets('more messages come at once than rows are built: what is on the screen still does not move', (tester) async {
      for (final keyed in [true, false]) {
        final c = ScrollController();
        final newest = ValueNotifier(999);
        await tester.pumpWidget(numbered(c, newest, keyed: keyed, tall: (m) => m == 900 ? 3000 : 80));
        final rows = _rows(c);
        rows.hold(c.position, 99, within: 0.5);
        await tester.pump();
        rows.release();
        expect(rows.last - rows.first, lessThan(2), reason: 'one row fills the screen and what is kept ready round it');
        final was = tester.getRect(find.text('m900'));
        newest.value = 1002;
        await tester.pump();
        expect(tester.getRect(find.text('m900')).top, closeTo(was.top, 0.01), reason: 'where it was (rows found by key: $keyed)');
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(find.text('m900')).top, closeTo(was.top, 0.01));
        expect(rows.held, isNull);
        _sound(tester, c);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    });

    // Rows found again by their keys, one near the newest kept alive off the screen (a row playing a video would be):
    // when a message comes the kept row is moved to its new place and a row made in its old one, which stands alone at
    // the head of those built. The list's own layout began from it and walked to where the chat stood, 789 rows in
    // the frame, and ended on other messages.
    testWidgets('a row kept alive far from the screen is no place to begin from: a message that comes builds what is near, and moves nothing', (tester) async {
      final c = ScrollController();
      final newest = ValueNotifier(1999);
      final built = <int>[];
      await tester.pumpWidget(numbered(c, newest, built: built, kept: 1994, tall: (m) => 60.0 + m % 7 * 20));
      final rows = _rows(c);
      rows.hold(c.position, 800);
      await tester.pump();
      rows.release();
      final was = onScreen(tester);
      built.clear();
      newest.value++;
      await tester.pump();
      expect(built.toSet().length, lessThan(40), reason: 'what is near, not every row from the kept one up');
      final now = onScreen(tester);
      for (final m in was.keys) {
        expect(now[m], closeTo(was[m]!, 0.01), reason: 'message $m where it was');
      }
      _sound(tester, c);
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('not told what its rows are, a message that comes does on the screen what it does in a plain list', (tester) async {
      final seen = <bool, List<String>>{};
      for (final stock in [true, false]) {
        final c = ScrollController();
        final newest = ValueNotifier(999);
        final log = seen[stock] = [];
        await tester.pumpWidget(numbered(c, newest, named: false, keyed: false, stock: stock));
        for (var k = 0; k < 6; k++) {
          c.jumpTo(c.offset + 400);
          await tester.pump();
        }
        for (var k = 0; k < 5; k++) {
          final at = c.offset;
          newest.value++;
          await tester.pump();
          // The scroll stays and everything is a row further up. (Its number may differ from the plain list's once
          // rows come in under those built: a height kept by a row's place is then a row out until it is laid out.)
          expect(c.offset, at);
          log.add('${onScreen(tester)}');
          c.jumpTo(c.offset - 90);
          await tester.pump();
          log.add('${onScreen(tester)}');
          if (!stock) _sound(tester, c);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
      expect(seen[false], seen[true]);
    });

    testWidgets('a row that asks to be kept alive is kept through a far send and found again', (tester) async {
      final c = ScrollController();
      final made = <int>{};
      await tester.pumpWidget(_list(c, 2000, row: (i) => i == 60 ? _Kept(made: made) : SizedBox(height: _tall(i))));
      final rows = _rows(c);
      rows.hold(c.position, 60);
      await tester.pump();
      expect(made, hasLength(1));
      rows.hold(c.position, 1800);
      await tester.pump();
      expect(_row(60), findsNothing, reason: 'off the screen');
      rows.hold(c.position, 900);
      await tester.pump();
      rows.hold(c.position, 60);
      await tester.pump();
      expect(tester.getRect(_row(60)).center.dy, closeTo(300, 0.01));
      expect(made, hasLength(1), reason: 'the same row, not one made anew');
      _sound(tester, c);
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('rows of no height, a row many screens tall, and a list shorter than the screen', (tester) async {
      final c = ScrollController();
      double tall(int i) => i % 7 == 3 ? 0 : (i == 150 ? 4000 : 30.0 + i % 40);
      await tester.pumpWidget(_list(c, 600, row: (i) => SizedBox(height: tall(i))));
      final rows = _rows(c);
      // The message just over a row many screens tall: the map's guesses stopped a screen or more short of it.
      for (final k in [151, 149, 150, 3, 4, 599, 0, 300]) {
        rows.hold(c.position, k);
        await tester.pump();
        _sound(tester, c);
        final r = tester.getRect(_row(k));
        final atAnEnd = c.offset <= 0.01 || c.offset >= c.position.maxScrollExtent - 0.01;
        if (!atAnEnd) expect(r.center.dy, closeTo(300, 0.01), reason: 'row $k');
        if (k == 151 || k == 149 || k == 300) expect(atAnEnd, isFalse);
        var filled = false;
        for (var i = 0; i < 600 && !filled; i++) {
          if (_row(i).evaluate().isEmpty) continue;
          final b = tester.getRect(_row(i));
          filled = b.height > 0 && b.bottom > 0 && b.top < 600;
        }
        expect(filled, isTrue, reason: 'something is on the screen with row $k held');
        expect(tester.takeException(), isNull);
      }
      // Through the tall one and the empty ones, a step at a time, both ways.
      rows.hold(c.position, 160);
      await tester.pump();
      while (c.offset > 0) {
        c.jumpTo(math.max(0.0, c.offset - 280));
        await tester.pump();
        _sound(tester, c);
      }
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(tester.takeException(), isNull);
      // Fewer rows than fill the screen: nowhere to go, and nothing breaks.
      await tester.pumpWidget(const SizedBox());
      final short = ScrollController();
      addTearDown(short.dispose);
      await tester.pumpWidget(_list(short, 4, row: (i) => const SizedBox(height: 50)));
      final few = _rows(short);
      few.hold(short.position, 3);
      await tester.pump();
      expect(short.offset, 0);
      expect(short.position.maxScrollExtent, 0);
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(few.view!.lo, 0);
      expect(few.view!.hi, 4);
      // None at all, then some.
      await tester.pumpWidget(const SizedBox());
      final none = ScrollController();
      addTearDown(none.dispose);
      final n = ValueNotifier(0);
      await tester.pumpWidget(ValueListenableBuilder<int>(valueListenable: n, builder: (context, count, _) => _list(none, count)));
      expect(RenderChatRows.under(none.position)!.view, isNull);
      n.value = 50;
      await tester.pump();
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('another chat given to the same page starts from that chat\'s own heights', (tester) async {
      final c = ScrollController();
      final chat = ValueNotifier('space:a');
      await tester.pumpWidget(ValueListenableBuilder<String>(
        valueListenable: chat,
        builder: (context, name, _) => _list(c, name == 'space:a' ? 900 : 700, chat: name, row: (i) => SizedBox(height: name == 'space:a' ? _tall(i) : 20.0 + i % 9)),
      ));
      final rows = _rows(c);
      final a = rows.heights;
      rows.hold(c.position, 800);
      await tester.pump();
      chat.value = 'space:b';
      await tester.pump();
      expect(identical(rows.heights, a), isFalse);
      expect(rows.held, isNull);
      expect(rows.heights.length, 700);
      _sound(tester, c);
      c.jumpTo(0);
      await tester.pump();
      expect(tester.getRect(_row(0)).bottom, closeTo(592, 0.01));
      expect(tester.getRect(_row(0)).height, 20);
      expect(a.length, 900, reason: 'the first chat\'s are kept as they were');
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('run in to a row: held with less and less of a shift each frame, it glides there without a jolt as rows come in', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 1200));
      final rows = _rows(c);
      rows.hold(c.position, 1000, shift: -300);
      await tester.pump();
      var last = tester.getRect(_row(1000)).center.dy;
      expect(last, closeTo(0, 0.01), reason: '300 short of the middle: the list 300 less far up');
      for (var f = 1; f <= 30; f++) {
        rows.hold(c.position, 1000, shift: -300 + 10.0 * f);
        await tester.pump();
        final now = tester.getRect(_row(1000)).center.dy;
        expect(now - last, closeTo(10, 0.01), reason: 'ten a frame, whatever came onto the screen in it');
        last = now;
        _sound(tester, c);
      }
      expect(last, closeTo(300, 0.01));
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets('which rows are on the screen is told as it changes, parts of a row counted', (tester) async {
      final c = ScrollController();
      await tester.pumpWidget(_list(c, 200, row: (i) => const SizedBox(height: 50)));
      final rows = _rows(c);
      var told = 0;
      rows.laid.addListener(() => told++);
      // 600 tall, 8 of padding showing at the foot: 592 of rows, 11.84 of them.
      expect(rows.view!.lo, 0);
      expect(rows.view!.hi, closeTo(11.84, 1e-9));
      c.jumpTo(8.0 + 50 * 10 + 25);
      await tester.pump();
      expect(rows.view!.lo, closeTo(10.5, 1e-9));
      expect(rows.view!.hi, closeTo(22.5, 1e-9));
      expect(rows.scrolled, 525);
      expect(told, 1);
      await tester.pump();
      expect(told, 1, reason: 'nothing changed');
      expect(rows.first, lessThanOrEqualTo(10));
      expect(rows.last, greaterThanOrEqualTo(22));
    });
  });
}
