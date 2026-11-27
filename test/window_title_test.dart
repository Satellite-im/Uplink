import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/desktop/ui/desk_title_bar.dart';
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/window_title.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-24: "also show the active circle or conversation name in the titlebar where the "ghost messaging"
// title is". A page names the window by standing under a WindowTitle (lib/ui/window_title.dart); the Mac's title strip
// (lib/desktop/ui/desk_title_bar.dart) draws what is named. Run with --update-goldens, the pictures are
// build/window-title/*.png.

Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '9' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'OnlyGhosts', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '9a' * 32, name: 'General', kind: SpaceKind.text),
  ]),
);

void main() {
  group('what names the window', () {
    Widget page(String name, {bool circle = false, Key? key}) => WindowTitle(key: key, name: name, circle: circle, child: const SizedBox());
    Future<void> show(WidgetTester tester, List<Widget> pages) async {
      await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: Stack(children: pages)));
      await tester.pump();
    }

    testWidgets('a conversation while it is open; nothing once it has gone', (tester) async {
      expect(WindowTitle.now.value, isNull);
      await show(tester, [page('Maya Chen')]);
      expect(WindowTitle.now.value, 'Maya Chen');
      await show(tester, const []);
      expect(WindowTitle.now.value, isNull);
    });

    testWidgets('the circle before a conversation open beside it, and the conversation again when the circle closes', (tester) async {
      await show(tester, [page('General', key: const ValueKey('space')), page('OnlyGhosts', circle: true, key: const ValueKey('circle'))]);
      expect(WindowTitle.now.value, 'OnlyGhosts');
      // Whichever came first: the circle's list is made before the space it opens, and after one opened earlier.
      await show(tester, [page('OnlyGhosts', circle: true, key: const ValueKey('circle')), page('General', key: const ValueKey('space'))]);
      expect(WindowTitle.now.value, 'OnlyGhosts');
      await show(tester, [page('General', key: const ValueKey('space'))]);
      expect(WindowTitle.now.value, 'General');
      await show(tester, const []);
    });

    testWidgets('a name that changes, and one that is blank', (tester) async {
      await show(tester, [page('Maya', key: const ValueKey('chat'))]);
      expect(WindowTitle.now.value, 'Maya');
      await show(tester, [page('Maya Chen', key: const ValueKey('chat'))]);
      expect(WindowTitle.now.value, 'Maya Chen', reason: 'renamed while open');
      await show(tester, [page('  ', key: const ValueKey('chat'))]);
      expect(WindowTitle.now.value, isNull, reason: 'a page with no name yet names nothing');
      await show(tester, const []);
    });

    testWidgets('the newest of two conversations', (tester) async {
      await show(tester, [page('Dad', key: const ValueKey('a'))]);
      await show(tester, [page('Dad', key: const ValueKey('a')), page('Maya Chen', key: const ValueKey('b'))]);
      expect(WindowTitle.now.value, 'Maya Chen');
      await show(tester, [page('Dad', key: const ValueKey('a'))]);
      expect(WindowTitle.now.value, 'Dad');
      await show(tester, const []);
    });
  });

  group('in the app', () {
    setUpAll(_fonts);
    tearDown(() async {
      await Circles.instance.clear();
    });

    Future<AppShellState> open(WidgetTester tester) async {
      ListPhone([
        ListPhone.conversation(1, '+15550100', 'Call me when you land', name: 'Dad'),
        ListPhone.conversation(2, '+15550101', 'Sounds good, see you at 7!', name: 'Maya Chen', minutes: 4),
      ]).install();
      Circles.instance.join(_circle);
      final sheet = await loadSheet(tester);
      final nav = GlobalKey<NavigatorState>();
      // The window as a Mac draws it: the title strip above the app.
      await pumpScreen(
        tester,
        sheet,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [DeskTitleBar(navigator: nav), const Expanded(child: AppShell())]),
        AppState(),
        size: const Size(1100, 760),
        platform: 'desktop',
      );
      return AppShellState.live!;
    }

    String said(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('desk-title'))).data!;

    testWidgets('the title strip names the conversation that is open, then the circle, then the app again', (tester) async {
      final shell = await open(tester);
      expect(said(tester), 'Uplink', reason: 'nothing open');

      shell.openThread(2, const [Person(address: '+15550101', name: 'Maya Chen')]);
      await settle(tester);
      expect(said(tester), 'Maya Chen');
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/window-title/conversation.png'));

      shell.openThread(1, const [Person(address: '+15550100', name: 'Dad')]);
      await settle(tester);
      expect(said(tester), 'Dad', reason: 'another conversation in its place');

      // A circle: its own name, whichever of its spaces is open in the pane.
      shell.openCircle(_circle);
      await settle(tester);
      expect(said(tester), 'OnlyGhosts');
      expect(find.text('General'), findsWidgets, reason: 'its space is open beside its list');
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/window-title/circle.png'));

      // Back to the conversations with nothing open.
      shell.home();
      await settle(tester);
      shell.close();
      await settle(tester);
      expect(said(tester), 'Uplink');
      expect(WindowTitle.now.value, isNull);
    });
  });
}
