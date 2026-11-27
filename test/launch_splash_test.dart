import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/ui/launch_splash.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostLogo;

import 'support/list_harness.dart';

/// The launch splash (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20): the logo, what it is doing, and a bar
/// while an update comes down, in a window 300 by 340. Pictures in build/themes/launch-splash.
///
/// The logo stands by itself, in the page's ink, 8rem across: out of the black tile it was in, and twice the size it
/// had there (Matt, 2026-11-27: "remove the uplink logo from the squircle on the loading page. and make it twice as
/// large").
void main() {
  for (final dark in [false, true]) {
    testWidgets('it says what it is doing, with a bar for a download (${dark ? 'dark' : 'light'})', (tester) async {
      final sheet = await loadSheet(tester);
      final step = ValueNotifier<SplashStep>((words: 'Checking for updates', progress: null));
      await pumpScreen(tester, sheet, LaunchSplash(step: step), AppState()..set('theme', dark ? 'dark' : 'light'), size: const Size(300, 340));
      // The logo's picture is read before anything is looked at: the first page drawn in a run has not got it yet.
      await tester.runAsync(() => precacheImage(const AssetImage('assets/art/ghost-mark.png'), tester.element(find.byType(LaunchSplash))));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Checking for updates'), findsOneWidget);
      expect(find.byType(GhostLogo), findsNothing, reason: 'no tile behind the logo');
      final logo = tester.widget<Image>(find.byType(Image));
      expect(tester.getSize(find.byType(Image)), const Size(128, 128), reason: 'twice the 4rem it was in its tile');
      expect(logo.color, isNotNull, reason: 'the page\'s ink: the mark itself is white, and the light page is too');
      expect(logo.colorBlendMode, BlendMode.srcIn);
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
