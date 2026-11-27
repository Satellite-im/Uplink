import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/ui/launch_splash.dart';

import 'support/list_harness.dart';

/// The launch splash (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20): the logo, what it is doing, and a bar
/// while an update comes down, in a window 300 by 340. Pictures in build/themes/launch-splash.
void main() {
  for (final dark in [false, true]) {
    testWidgets('it says what it is doing, with a bar for a download (${dark ? 'dark' : 'light'})', (tester) async {
      final sheet = await loadSheet(tester);
      final step = ValueNotifier<SplashStep>((words: 'Checking for updates', progress: null));
      await pumpScreen(tester, sheet, LaunchSplash(step: step), AppState()..set('theme', dark ? 'dark' : 'light'), size: const Size(300, 340));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Checking for updates'), findsOneWidget);
      await _keep(tester, 'checking-${dark ? 'dark' : 'light'}');
      step.value = (words: 'Downloading 0.9.38', progress: 0.42);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Downloading 0.9.38'), findsOneWidget);
      await _keep(tester, 'downloading-${dark ? 'dark' : 'light'}');
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _keep(WidgetTester tester, String name) async {
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('build/themes/launch-splash/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}
