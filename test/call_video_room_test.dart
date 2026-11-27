import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show CallPanel;

import 'support/space_call_harness.dart';

/// Video in a call on a computer gets the room (GMFB-58, @kevin, Windows 0.12.17: "The video call window is far too
/// vertically slim for regular use"): one person's video in a space's call was a strip 200 high across the panel
/// whatever the window's size, and a friend call's two videos stood three across. A phone's layout is as it was.
void main() {
  for (final size in const [Size(1280, 720), Size(1920, 1080)]) {
    testWidgets('a space\'s call at ${size.width.round()}x${size.height.round()}: one other\'s video is at least half the window high', (tester) async {
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      // The chat docked open (as a computer starts), then closed.
      await h.shoot(tester, TelegramCall(call: h.call(people: 1, video: const {'a'})), 'space-telegram-video-room-${size.height.round()}', size: size);
      for (final chat in [true, false]) {
        if (!chat) {
          await tester.tap(find.bySemanticsLabel('Close chat'));
          await tester.pump(const Duration(milliseconds: 300));
        }
        final tile = tester.getSize(find.byType(SpaceVideo));
        expect(tile.height, greaterThanOrEqualTo(size.height / 2), reason: 'chat open: $chat');
        // Shaped like a picture, not a strip: no wider than 16:9, and inside its panel.
        expect(tile.width / tile.height, lessThanOrEqualTo(1.8), reason: 'chat open: $chat');
        expect(tile.width, lessThanOrEqualTo(tester.getSize(find.byKey(const ValueKey('tg-voice-panel'))).width));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a space\'s call on a computer: several videos among many people, none under 200 high', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    for (final video in const [{'a', 'b'}, {'a', 'b', 'c'}, {'a', 'b', 'c', 'd'}]) {
      await h.shoot(tester, TelegramCall(call: h.call(people: 7, video: video)), 'space-telegram-video-room-many', size: const Size(1280, 720));
      for (final e in find.byType(SpaceVideo).evaluate()) {
        expect(e.size!.height, greaterThanOrEqualTo(200), reason: '$video');
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a space\'s call on a phone: the video is as it was, and gives way to the list', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await h.shoot(tester, TelegramCall(call: h.call(people: 1, video: const {'a'})), 'space-telegram-video-room-phone');
    final tile = tester.getSize(find.byType(SpaceVideo));
    expect(tile.height, closeTo(198, 3)); // 200 less the tile's border
    expect(tile.width, greaterThan(350));
    await tester.pumpWidget(const SizedBox());
  });

  test('a friend call\'s videos: never more across than there are, one alone no taller than the window allows', () {
    // Two videos in a computer's pane stood three across with a gap where the third would be.
    final two = CallPanel.videoTile(width: 900, count: 2, gap: 8, screenHeight: 720);
    expect(two.width, closeTo(446, 0.5));
    expect(two.height, closeTo(334.5, 0.5));
    // One alone was 4:3 of the pane's width, taller than the window; now at most 70% of the window's height, and still
    // 4:3 (Matt, 2026-11-23), narrower than the pane.
    final one = CallPanel.videoTile(width: 900, count: 1, gap: 8, screenHeight: 720);
    expect(one.width, closeTo(672, 0.5));
    expect(one.height, closeTo(504, 0.5));
    expect(one.height, greaterThanOrEqualTo(720 / 2));
    // Many: up to four across on a wide pane, as before.
    expect(CallPanel.videoTile(width: 1000, count: 6, gap: 8, screenHeight: 1080).width, closeTo(244, 0.5));
    // A phone: as it was (one across the width at 4:3, more two across).
    final phone = CallPanel.videoTile(width: 380, count: 1, gap: 8, screenHeight: 892);
    expect((phone.width, phone.height), (380.0, 285.0));
    final pair = CallPanel.videoTile(width: 380, count: 3, gap: 8, screenHeight: 892);
    expect((pair.width, pair.height), (186.0, 139.5));
  });
}
