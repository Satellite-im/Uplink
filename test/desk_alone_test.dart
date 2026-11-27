import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/link/crypto.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/main.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/desktop/ui/link_offer.dart';
import 'package:ghost_messaging/desktop/ui/shell.dart';
import 'package:ghost_messaging/desktop/ui/wizard.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/standalone.dart';
import 'package:ghost_messaging/standalone/welcome.dart';
import 'package:ghost_messaging/ui/account_screens.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:glacier/glacier.dart';

/// A computer with no phone linked (Matt, 2026-11-18: "a user can use the app without linking the phone since some
/// people may be joining just to enter circles or use telegram and signal but not SMS. make setting up SMS and such and
/// linking to a phone an optional step"): a username, then linking offered and passed by, then the app; linking from
/// Settings opens the app again on the phone.
class _Store implements LinkStore {
  PairedPhone? kept;
  @override
  Future<PairedPhone?> load() async => kept;
  @override
  Future<void> save(PairedPhone phone) async => kept = phone;
  @override
  Future<void> clear() async => kept = null;
}

class _Link extends PhoneLink {
  _Link() : super(store: _Store(), name: 'Test Mac', app: '0.9.3');
  void linked(PairedPhone p) {
    phone = p;
    notifyListeners();
  }
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ghost-desk-alone');
  });
  tearDown(() {
    Sms.standalone = false;
    dir.deleteSync(recursive: true);
  });

  Future<({_Link link, DeskStore store, int Function() restarts})> open(WidgetTester tester, {String? username, Size size = const Size(1100, 740)}) async {
    tester.view.physicalSize = size * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final own = StandaloneCalls(Directory('${dir.path}/standalone'), keychain: false);
    await tester.runAsync(own.load);
    Sms.calls = own;
    Sms.standalone = true;
    final meStore = MemoryMeStore();
    if (username != null) meStore.set('me_username', username);
    await tester.runAsync(() => Me.instance.start(meStore, ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    final store = DeskStore(dir, keychain: false);
    final link = _Link();
    var restarts = 0;
    await tester.pumpWidget(DesktopApp(sheet: sheet, state: AppState(), link: link, calls: LinkCalls(link, store), store: store, relaunch: () async => restarts++));
    await settle(tester);
    return (link: link, store: store, restarts: () => restarts);
  }

  // The window is small for signing up or in (lib/desktop/window_size.dart; Matt, 2026-11-20: "make the sign up / sign
  // in window smaller"): the welcome fits it, 480 by 720, with nothing cut off.
  testWidgets('the welcome fits the small window it is shown in', (tester) async {
    await open(tester, size: const Size(480, 720));
    expect(find.byType(StandaloneWelcome), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing overflows');
  });

  testWidgets('first a username, said in a computer\'s words', (tester) async {
    await open(tester);
    expect(find.byType(StandaloneWelcome), findsOneWidget);
    // Only a username and a password (Matt, 2026-11-20: "very simple and just ask for a username and password").
    expect(find.byKey(const ValueKey('welcome-username')), findsOneWidget);
    expect(find.byKey(const ValueKey('welcome-password')), findsOneWidget);
    expect(find.byType(GlacierInput), findsNWidgets(2));
    expect(find.byType(PairWizard), findsNothing, reason: 'no phone is asked for before anything else');
    // Signing in is a section on this same page, not a page first (Matt, 2026-11-20: "it should have an 'already have
    // an account' section on the first page").
    expect(find.text('Already have an account?'), findsOneWidget);
    expect(find.byKey(const ValueKey('welcome-sign-in')), findsOneWidget);
    expect(find.byType(SignInScreen), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('welcome-sign-in')));
    await tester.tap(find.byKey(const ValueKey('welcome-sign-in')));
    await settle(tester);
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('then linking a phone, offered once and passed by; the app opens without one', (tester) async {
    final o = await open(tester, username: 'matt');
    expect(find.byType(LinkOffer), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-offer-skip')));
    await settle(tester);
    expect(find.byType(DeskShell), findsOneWidget);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.textContaining('phone isn'), findsNothing, reason: 'nothing says a phone is missing');

    // Settings › Your phone offers it again; once linked, the app opens again on it.
    tester.state<AppShellState>(find.byType(AppShell)).settings('phone');
    await settle(tester);
    expect(find.text('Link an Android phone'), findsWidgets);
    o.link.linked(PairedPhone(id: 'd387c0690aec58b7', name: 'Galaxy Z Fold8', key: DeskCrypto.randomBytes(32), mode: 'both', relay: 'wss://gogho.st/relay', since: DateTime.now()));
    await settle(tester);
    expect(find.byType(LinkRestarting), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1000)));
    await tester.pump(const Duration(seconds: 1));
    expect(o.restarts(), 1);
  });

  testWidgets('"Link my Android phone" shows the wizard, with Not now to go back', (tester) async {
    await open(tester, username: 'matt');
    await tester.tap(find.byKey(const ValueKey('link-offer-link')));
    await settle(tester);
    expect(find.byType(PairWizard), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await settle(tester);
    expect(find.byType(DeskShell), findsOneWidget);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  // What is written to the folder (the choice to pass linking by) takes real time.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}
