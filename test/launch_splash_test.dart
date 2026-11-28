import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/loading_logo.dart';
import 'package:ghost_messaging/desktop/ui/launch_splash.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostLogo;
import 'package:glacier/glacier.dart';

import 'support/drawn_ink.dart';
import 'support/list_harness.dart';

/// The launch splash (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20): the logo, what it is doing, and a bar
/// while an update comes down, in a window 300 by 340. Pictures in build/themes/launch-splash.
///
/// The logo is the one that turns (lib/art/loading_logo.dart, test/loading_logo_test.dart), by itself and in the
/// page's ink, most of the window across (Matt, 2026-11-27: "update the update screen to use the loading_logo.mp4 and
/// make it larger so it is visible"; and of the tile it once stood in, the same day: "remove the uplink logo from the
/// squircle on the loading page").
/// The app's own letters, so the pictures say what the splash says.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  for (final dark in [false, true]) {
    testWidgets('it says what it is doing, with a bar for a download (${dark ? 'dark' : 'light'})', (tester) async {
      final sheet = await loadSheet(tester);
      final step = ValueNotifier<SplashStep>((words: 'Checking for updates', progress: null));
      await pumpScreen(tester, sheet, LaunchSplash(step: step), AppState()..set('theme', dark ? 'dark' : 'light'), size: const Size(300, 340));
      await filmShown(tester, find.byType(RawImage));
      expect(find.text('Checking for updates'), findsOneWidget);
      expect(find.byType(GhostLogo), findsNothing, reason: 'no tile behind the logo');
      final t = tester.element(find.byType(LaunchSplash)).tokens;
      final logo = tester.widget<LoadingLogo>(find.byKey(const ValueKey('splash-logo')));
      expect(logo.color, t.color('app-ink'), reason: 'the page\'s ink: the film is white, and the light page is too');
      // Larger: 248 across where the still mark was 128, and the logo in it about 217 where it was 115.
      final box = tester.getRect(find.byType(LoadingLogo));
      expect(box.size, Size(248, 248 / LoadingLogo.shape));
      expect(box.width, greaterThan(300 * 0.8), reason: 'most of the window across');
      // And it all still stands in the window, with room round it: the logo, the words, the bar's place.
      final words = tester.getRect(find.byKey(const ValueKey('splash-words')));
      expect(box.left, greaterThanOrEqualTo(24));
      expect(box.top, greaterThanOrEqualTo(24));
      expect(words.top, greaterThan(box.bottom));
      expect(words.bottom, lessThanOrEqualTo(340 - 40), reason: 'the bar goes under the words');
      var drawn = await Drawn.of(tester, find.byType(WidgetsApp).evaluate().single);
      drawn.keep('build/themes/launch-splash/checking-${dark ? 'dark' : 'light'}.png');
      // Drawn in the ink on the page, and nothing of the film's black round it.
      final page = t.color('glacier-bg');
      final shares = drawn.shares(box, ink: logo.color, page: page);
      expect(shares.ink, inInclusiveRange(0.15, 0.4), reason: '$shares');
      expect(shares.page, inInclusiveRange(0.5, 0.85), reason: '$shares');
      expect(shares.other, 0, reason: '$shares');
      expect(drawn.not(Rect.fromLTWH(box.left, box.top, 40, 30), page), 0);
      step.value = (words: 'Downloading 0.9.38', progress: 0.42);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Downloading 0.9.38'), findsOneWidget);
      final bar = tester.getRect(find.byType(GlacierProgressBar));
      expect(bar.top, greaterThan(words.bottom));
      expect(bar.bottom, lessThanOrEqualTo(340 - 24));
      drawn = await Drawn.of(tester, find.byType(WidgetsApp).evaluate().single);
      drawn.keep('build/themes/launch-splash/downloading-${dark ? 'dark' : 'light'}.png');
      expect(tester.takeException(), isNull);
    });
  }
}
