import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:glacier/glacier.dart' show GlacierSwitch;
import 'package:ghost_messaging/keep_running.dart';
import 'package:ghost_messaging/sms.dart' show SmsStatus;
import 'package:ghost_messaging/ui/settings_panes.dart' show reachSection;

import 'support/list_harness.dart';

/// Ringing while the app is closed (GMFB-28, checked against the code on 2026-11-25: "a fully closed app is not woken
/// for a call, so it usually shows as missed"): lib/keep_running.dart, what Android is told to keep the app running
/// for, and the switch in Settings › Notifications with Android's leave to run while the phone sleeps beside it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('Android is told why the app is to be kept running, as the reasons change and only then', () {
    final told = <String>[];
    final k = KeepRunning(keep: (names, {required calls}) => told.add('${names.join('+')}${calls ? ' calls' : ''}'));
    // Nothing to keep it for, and nothing ever was: Android is not told to stop what never started.
    k.networks(const []);
    k.calls(false);
    expect(told, isEmpty);
    // Calls alone: kept, with no network signed in.
    k.calls(true);
    expect(told, [' calls']);
    k.calls(true);
    expect(told, hasLength(1), reason: 'said once');
    // A network signs in, and another: each change is said, with the calls still kept for.
    k.networks(const ['Signal']);
    k.networks(const ['Signal', 'Telegram']);
    k.networks(const ['Signal', 'Telegram']);
    expect(told.sublist(1), ['Signal calls', 'Signal+Telegram calls']);
    // Calls switched off: the networks alone keep it, as before there was such a switch.
    k.calls(false);
    expect(told.last, 'Signal+Telegram');
    // The last reason gone: told once, with nothing, which stops it.
    k.networks(const []);
    expect(told.last, '');
    k.networks(const []);
    expect(told, hasLength(5));
  });

  test('it follows the person\'s choice, which is off until switched on', () {
    final app = AppState();
    final told = <bool>[];
    final k = KeepRunning(keep: (names, {required calls}) => told.add(calls))..follow(app);
    expect([KeepRunning.wanted(app), told], [false, isEmpty]);
    app.setFlag(KeepRunning.key, true);
    expect([KeepRunning.wanted(app), told], [true, [true]]);
    // Other choices changing say nothing more.
    app.setFlag('notif_preview', false);
    expect(told, [true]);
    app.setFlag(KeepRunning.key, false);
    expect(told, [true, false]);
    k.networks(const ['Signal']);
    expect(told, [true, false, false]);
  });

  test('whether Android lets the app run while the phone sleeps comes with the status, and is unknown from a build before it', () {
    expect(SmsStatus.from(const {'battery': true}).battery, isTrue);
    expect(SmsStatus.from(const {'battery': false}).battery, isFalse);
    expect(SmsStatus.from(const {}).battery, isNull);
  });

  testWidgets('Settings › Notifications: the switch, and once it is on, Android\'s leave to run while the phone sleeps', (tester) async {
    final sheet = await loadSheet(tester);
    final app = AppState();
    var asked = 0;
    bool? battery = false;
    Widget page() => ListenableBuilder(
          listenable: app,
          builder: (context, _) => SingleChildScrollView(child: reachSection(app, battery: battery, askBattery: () => asked++)),
        );
    await pumpScreen(tester, sheet, page(), app);
    await settle(tester);
    expect(find.text('WHILE THE APP IS CLOSED'), findsOneWidget);
    expect(find.text(KeepRunning.reachLabel), findsOneWidget);
    expect(find.textContaining('After your phone restarts, open Uplink once'), findsOneWidget, reason: 'what it can\'t do is said where it is switched on');
    expect(find.byKey(const ValueKey('stay-reachable-sleep')), findsNothing, reason: 'nothing of the battery until it is on');
    expect(KeepRunning.wanted(app), isFalse);

    // Switched on where Android would hold the app back: asked at once, and the row says how it stands.
    await tester.tap(find.byType(GlacierSwitch));
    await settle(tester);
    expect([KeepRunning.wanted(app), asked], [true, 1]);
    expect(find.text(KeepRunning.sleepLabel), findsOneWidget);
    expect(find.text('Not allowed'), findsOneWidget);
    expect(find.text(KeepRunning.sleepHint), findsOneWidget);
    await tester.tap(find.text(KeepRunning.sleepLabel));
    await settle(tester);
    expect(asked, 2, reason: 'a press asks again');

    // Allowed (the status read again as the app comes back from Android's question): said, and no longer pressed.
    battery = true;
    app.setFlag('notif_preview', false);
    await settle(tester);
    expect(find.text('Allowed'), findsOneWidget);
    expect(find.text(KeepRunning.sleepAllowedHint), findsOneWidget);
    await tester.tap(find.text(KeepRunning.sleepLabel));
    await settle(tester);
    expect(asked, 2);

    // Switched off: the row goes, and switching it on again where Android already allows asks nothing.
    await tester.tap(find.byType(GlacierSwitch));
    await settle(tester);
    expect([KeepRunning.wanted(app), find.byKey(const ValueKey('stay-reachable-sleep')).evaluate().length], [false, 0]);
    await tester.tap(find.byType(GlacierSwitch));
    await settle(tester);
    expect([KeepRunning.wanted(app), asked], [true, 2]);

    // Where the phone can't say (a build of the app's Android half from before this): the switch alone.
    battery = null;
    app.setFlag('notif_preview', true);
    await settle(tester);
    expect(find.byKey(const ValueKey('stay-reachable-sleep')), findsNothing);
  });
}
