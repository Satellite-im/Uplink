import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart' show SpaceVideo;
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/tile_grid.dart';

import 'support/space_call_harness.dart';

/// Every person's video tile is 4:3 on a computer, in a space's call (Matt, 2026-11-23: "please make the video chats
/// more square right now they're too wide and narrow make them like 4:3"). With --update-goldens the call is drawn on
/// a computer and a phone with 1, 2, 4 and 9 people, every camera on, into build/video-43/ (not kept in the repo) to
/// be looked at.

/// Everyone in the made-up call with their camera on.
const _all = {'me', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'};

/// The tile each picture is drawn in: of the boxes round it no more than a border or a little padding bigger (8 a
/// side), the one nearest 4:3 (a tile's border inside it makes the picture itself a pixel or two off).
List<Size> _tiles(WidgetTester tester) => [
      for (final e in find.byType(SpaceVideo).evaluate())
        () {
          final inner = e.renderObject! as RenderBox;
          double miss(Size s) => (s.height - s.width * 3 / 4).abs();
          var tile = inner.size;
          RenderObject? up = inner.parent;
          while (up is RenderBox && up.hasSize && up.size.width - inner.size.width <= 16 && up.size.height - inner.size.height <= 16) {
            if (miss(up.size) < miss(tile)) tile = up.size;
            up = up.parent;
          }
          return tile;
        }(),
    ];

void main() {
  testWidgets('every video tile of a space\'s call is 4:3 on a computer', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    for (final others in [0, 1, 3, 8]) {
      await h.shoot(tester, TelegramCall(call: h.call(people: others, video: _all, myVideo: true)), 'vt-measure', size: SpaceHarness.computer, dir: '../build/video-43');
      expect(tester.takeException(), isNull);
      final tiles = _tiles(tester);
      expect(tiles, isNotEmpty, reason: 'with ${others + 1}: no tiles found');
      for (final s in tiles) {
        expect((s.height - s.width * 3 / 4).abs(), lessThanOrEqualTo(1), reason: 'with ${others + 1}: a tile of ${s.width.toStringAsFixed(1)} by ${s.height.toStringAsFixed(1)} is not 4:3');
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  // The pictures of a call that is not a space's, and of an open space's (CallVideos, lib/ui/voice_screen.dart), are
  // a TileGrid.
  testWidgets('a TileGrid draws 4:3 tiles as big as fit, touching two sides of its room', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final room in [const Size(900, 420), const Size(600, 700), const Size(1200, 360)]) {
      for (var n = 1; n <= 9; n++) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox.fromSize(size: room, child: TileGrid(count: n, gap: 8, tile: (i) => ColoredBox(key: ValueKey('t$i'), color: const Color(0xFF000000))))),
        ));
        final grid = tester.getRect(find.byType(TileGrid));
        final drawn = [for (var i = 0; i < n; i++) tester.getRect(find.byKey(ValueKey('t$i')))];
        for (final r in drawn) {
          expect((r.height - r.width * 3 / 4).abs(), lessThanOrEqualTo(1), reason: '$n in $room: ${r.size}');
          expect(grid.contains(r.topLeft) && grid.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue, reason: '$n in $room: $r outside');
        }
        final all = drawn.reduce((a, b) => a.expandToInclude(b));
        // No band both ways: the grid reaches the room's edges across or down (centred along the other).
        expect((all.width - room.width).abs() < 1 || (all.height - room.height).abs() < 1, isTrue, reason: '$n in $room: grid $all');
      }
    }
  });

  testWidgets('pictures of a space\'s call with 1, 2, 4 and 9 people (--update-goldens)', (tester) async {
    if (!autoUpdateGoldenFiles) return;
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    for (final (size, where) in [(SpaceHarness.computer, 'computer'), (SpaceHarness.phone, 'phone')]) {
      for (final others in [0, 1, 3, 8]) {
        await h.shoot(tester, TelegramCall(call: h.call(people: others, video: _all, myVideo: true)), 'call-$where-${others + 1}', size: size, dark: true, dir: '../build/video-43');
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
