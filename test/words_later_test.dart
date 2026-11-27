import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/account_screens.dart' show wordsLater;
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/shell.dart';

import 'support/list_harness.dart';

/// GMFB-3 (@kevin, Windows 0.11.3: "We need to find a way to reduce friction when onboarding new users. I find the
/// seed phrase to be a frustrating hurdle personally"): the recovery words can wait after sign-up, and the
/// conversations list reminds of them until they are seen or the reminder is put away.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  testWidgets('words put off: the list reminds, with the way to them; dismissed, it is gone', (tester) async {
    ListPhone([ListPhone.conversation(1, '+15550001', 'hey', name: 'Maya')]).install();
    final sheet = await loadSheet(tester);
    final app = AppState()
      ..set(NavStyle.pref, NavStyle.dock.name)
      ..setFlag(wordsLater, true);
    await pumpScreen(tester, sheet, const AppShell(), app);
    await settle(tester);
    expect(find.byKey(const ValueKey('words-notice')), findsOneWidget);
    expect(find.text('Write down your recovery words'), findsOneWidget);
    expect(find.text('Show them'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('words-notice')), matching: find.byType(IconTap)));
    await settle(tester);
    expect(find.byKey(const ValueKey('words-notice')), findsNothing);
    expect(app.flag(wordsLater, fallback: false), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no reminder for someone who never put them off', (tester) async {
    ListPhone([ListPhone.conversation(1, '+15550001', 'hey', name: 'Maya')]).install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.dock.name));
    await settle(tester);
    expect(find.byKey(const ValueKey('words-notice')), findsNothing);
  });
}
