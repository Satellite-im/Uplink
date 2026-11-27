import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/window_chrome.dart' show MacChrome;
import 'package:ghost_messaging/desktop/ui/desk_title_bar.dart';
import 'package:ghost_messaging/ui/feedback_screen.dart';

import 'support/space_call_harness.dart';

/// The Mac window's own title strip (Matt, 2026-11-19: "I want the top bar where we drag like the window titlebar to
/// house these buttons we can roll a custom titlebar if we need to that's a bit thicker to fit the content"): across
/// the top, a little taller than the Mac's, Share feedback at its right opening the form on the app's navigator under it.
void main() {
  testWidgets('the strip is across the top with room for the window buttons, and Share feedback opens the form below it', (tester) async {
    final h = await SpaceHarness.load(tester);
    final nav = GlobalKey<NavigatorState>();
    final extra = DeskTitleBar.extras.length;
    DeskTitleBar.extras.add((context, navigator) => const SizedBox(key: ValueKey('strip-extra'), width: 20, height: 20));
    addTearDown(() => DeskTitleBar.extras.removeRange(extra, DeskTitleBar.extras.length));
    await h.shoot(
      tester,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DeskTitleBar(navigator: nav),
        Expanded(child: Navigator(key: nav, onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => const Center(child: Text('The app')))))
      ]),
      'desk-title-bar',
      size: const Size(1100, 700),
    );
    final bar = tester.getRect(find.byKey(const ValueKey('desk-title-bar')));
    expect(bar.top, 0);
    expect(bar.width, 1100, reason: 'across the whole window');
    expect(bar.height, DeskTitleBar.height);
    final button = tester.getRect(find.byKey(const ValueKey('share-feedback')));
    expect(button.right, greaterThan(1100 - 40), reason: 'at its right end');
    expect(tester.getRect(find.byKey(const ValueKey('strip-extra'))).right, lessThan(button.left), reason: 'more buttons before it');
    expect(find.text('Uplink'), findsOneWidget);

    // Under a video at full screen there is none of it (Matt, 2026-11-25: "fullscreen videos still incorrectly show
    // the titlebar of the app"), and the page under it has the whole window; after, it is back.
    MacChrome.covered.value = true;
    addTearDown(() => MacChrome.covered.value = false);
    await tester.pump();
    expect(find.byKey(const ValueKey('desk-title-bar')), findsNothing);
    expect(tester.getRect(find.byKey(nav)).top, 0);
    MacChrome.covered.value = false;
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('desk-title-bar'))).height, DeskTitleBar.height);

    if (Platform.environment['KEEP_SHOT'] == '1') {
      await tester.runAsync(() async {
        final image = await captureImage(find.byType(Column).first.evaluate().single);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/desk-title-bar.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await tester.tap(find.byKey(const ValueKey('share-feedback')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(FeedbackScreen), findsOneWidget, reason: 'opened on the app\'s navigator, under the strip');
    expect(tester.getRect(find.byType(FeedbackScreen)).top, greaterThanOrEqualTo(DeskTitleBar.height));
    await tester.pump(const Duration(seconds: 1));
  });
}
