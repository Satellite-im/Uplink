import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/main.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:integration_test/integration_test.dart';

/// How many frames a second the Mac app draws while its loading arc turns (Matt, 2026-11-13: "the desktop app also
/// seems laggy the loading indicator is at a few fps instead of smooth"). The real app, with no phone: the wizard
/// is taken to the code it shows, where the arc turns for as long as the phone is waited for, and the frames of
/// five seconds are counted. `DESK_POLICY=test` draws as a test does by default, only when it asks for a frame, and
/// asks every 150 ms: what the app looked like while desk_live_test.dart first drove it. `test16` asks every 16
/// ms, as that test does now. The default here draws every frame, as when a person runs the app.
///
///     flutter drive --driver=test_driver/integration_test.dart --target=integration_test/desk_frames_test.dart -d macos --profile
const _policy = String.fromEnvironment('DESK_POLICY', defaultValue: 'live');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_policy == 'live') binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('frames while the arc turns ($_policy)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ghost-desk-frames');
    await desktopMain(peers: const [], folder: dir.path, bonjour: false, updates: false);
    for (var i = 0; i < 20 && find.text('Your texts, on your Mac').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    // Local network only, so nothing is dialed while frames are counted.
    await tester.tap(find.byWidgetPredicate((w) => w is Pick && w.label == 'Use local network only'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Show the pairing code'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Scan this with your phone'), findsOneWidget);

    final timings = <FrameTiming>[];
    void take(List<FrameTiming> t) => timings.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(take);
    const seconds = 5;
    if (_policy == 'live') {
      await tester.pump(const Duration(seconds: seconds));
    } else {
      // As desk_live_test.dart waits: a frame asked for every 150 ms at first (`test`), every 16 ms now (`test16`).
      final every = _policy == 'test16' ? 16 : 150;
      final end = DateTime.now().add(const Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(Duration(milliseconds: every));
      }
    }
    await tester.pump(const Duration(milliseconds: 200));
    SchedulerBinding.instance.removeTimingsCallback(take);

    double ms(Duration d) => d.inMicroseconds / 1000;
    final build = [for (final t in timings) ms(t.buildDuration)]..sort();
    final raster = [for (final t in timings) ms(t.rasterDuration)]..sort();
    String mid(List<double> l) => l.isEmpty ? '-' : l[l.length ~/ 2].toStringAsFixed(1);
    String worst(List<double> l) => l.isEmpty ? '-' : l.last.toStringAsFixed(1);
    final refresh = PlatformDispatcher.instance.views.first.display.refreshRate;
    // ignore: avoid_print
    print('DESK-FRAMES policy=$_policy frames=${timings.length} in ${seconds}s = ${(timings.length / seconds).toStringAsFixed(1)} a second (the display: ${refresh.toStringAsFixed(0)} Hz); '
        'build mid ${mid(build)} ms worst ${worst(build)} ms; raster mid ${mid(raster)} ms worst ${worst(raster)} ms');
  });
}
