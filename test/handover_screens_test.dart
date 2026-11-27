import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/account/handover.dart';
import 'package:ghost_messaging/app_lock/app_lock.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/ui/qr.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/me/me.dart' show MemoryMeStore;
import 'package:ghost_messaging/ui/app_lock_ui.dart' show PinPad;
import 'package:ghost_messaging/ui/computers.dart' show PairingCode;
import 'package:ghost_messaging/ui/handover_screens.dart';
import 'package:glacier/glacier.dart';

import 'app_lock_test.dart' show FakeDevice, MemoryStore;
import 'handover_test.dart' show End, Rooms, relay;

/// The two screens of signing in on a new device by scanning its code with a phone (GMFB-45;
/// lib/ui/handover_screens.dart), each against the other end in memory: the new device's code and digits, and the
/// phone's question, with the phone's lock answered by the test.

/// An account that keeps [kept] words (or none) and opens them with [password].
class FakeAccount extends Account {
  FakeAccount({this.kept, this.password = 'correct horse battery'}) : super(relay: HubAccountRelay(), port: SmsAccountPort(), store: MemoryMeStore(), profiles: AppAccountProfiles(home: '/nowhere'));
  final List<String>? kept;
  final String password;
  int keptAsked = 0, passwordAsked = 0;

  @override
  bool get signedIn => kept != null;

  @override
  Future<List<String>?> wordsForNewDevice() async {
    keptAsked++;
    return kept;
  }

  @override
  Future<List<String>> revealWords(String typed) async {
    passwordAsked++;
    if (typed != password) throw AccountError('That password isn\'t right.');
    return kept ?? words;
  }

  /// What the password opens where nothing is kept.
  static final words = AccountCrypto.newWords();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Rooms rooms;
  late DateTime clock;
  late List<List<String>> got;
  DateTime now() => clock;

  setUp(() {
    rooms = Rooms();
    clock = DateTime(2026, 11, 23, 12);
    got = [];
  });

  AppLock lockOn(MemoryStore store, FakeDevice device) => AppLock(store: store, platform: device, now: now, hasher: PinHash.here, memoryKiB: 16, passes: 1, timers: false, desktop: false);

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(412, 1400) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final state = AppState();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    await tester.pumpWidget(AppScope(
      state: state,
      child: WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
        home: page,
      ),
    ));
    await settle(tester);
  }

  // --- the new device -------------------------------------------------------------------------------------------------

  Future<void> showPanel(WidgetTester tester) => show(tester, SingleChildScrollView(child: HandoverCodePanel(onWords: got.add, room: () => End(rooms), relay: relay, now: now)));
  String shownCode(WidgetTester tester) => tester.widget<QrView>(find.byKey(const ValueKey('handover-qr'))).data;
  HandoverPhone phoneFor(String code) => HandoverPhone(room: End(rooms), code: HandoverCode.parse(code)!, relay: relay, now: now);

  testWidgets('the new device shows a code with nothing of an account, then the phone\'s digits, then takes the words once', (tester) async {
    final words = AccountCrypto.newWords();
    await showPanel(tester);
    expect(find.text('Scan this with your phone'), findsOneWidget);
    final code = shownCode(tester);
    expect(HandoverCode.parse(code), isNotNull);
    expect(code, startsWith('GHOSTSIGNIN1:'));
    expect(code, endsWith(':$relay'));

    final phone = phoneFor(code);
    await phone.start();
    await settle(tester);
    expect(find.text('Does your phone show the same six digits?'), findsOneWidget);
    expect(find.byKey(const ValueKey('handover-qr')), findsNothing, reason: 'the code is not shown once a phone has answered');
    expect(tester.widget<PairingCode>(find.byType(PairingCode)).code, phone.digits);

    expect(phone.approve(words), isTrue);
    await settle(tester);
    expect(got, [words]);
    expect(find.text('Opening your account'), findsOneWidget);
    expect(phone.phase, HandoverPhase.done);
    expect(rooms.empty, isTrue);
    await close(tester);
  });

  testWidgets('leaving the new device\'s screen takes its code with it and tells the phone', (tester) async {
    await showPanel(tester);
    final phone = phoneFor(shownCode(tester));
    await phone.start();
    await settle(tester);
    expect(phone.ready, isTrue);
    await close(tester);
    await settle(tester);
    expect(phone.phase, HandoverPhase.refused);
    expect(phone.approve(AccountCrypto.newWords()), isFalse);
    expect(rooms.empty, isTrue);
    expect(got, isEmpty);
  });

  testWidgets('a code nobody scanned in two minutes is replaced by a new one; one a phone answered runs out', (tester) async {
    await showPanel(tester);
    final first = shownCode(tester);
    clock = clock.add(Handover.lifetime);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    final second = shownCode(tester);
    expect(second, isNot(first));
    // The old code's room has nobody in it.
    expect(rooms.membersOf(HandoverCode.parse(first)!.room), 0);

    final phone = phoneFor(second);
    await phone.start();
    await settle(tester);
    clock = clock.add(Handover.lifetime);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('That code ran out'), findsOneWidget);
    expect(find.byKey(const ValueKey('handover-qr')), findsNothing);
    await tester.tap(find.text('Show a new code'));
    await settle(tester);
    expect(shownCode(tester), isNot(second));
    phone.close();
    await close(tester);
  });

  testWidgets('the new device says so where the relay can\'t be reached', (tester) async {
    await show(tester, SingleChildScrollView(child: HandoverCodePanel(onWords: got.add, room: () => End(rooms, down: true), relay: relay, now: now)));
    expect(find.text('The relay server can\'t be reached'), findsOneWidget);
    expect(find.byKey(const ValueKey('handover-qr')), findsNothing);
    await close(tester);
  });

  // --- the phone ------------------------------------------------------------------------------------------------------

  Future<HandoverNewDevice> newDevice() async {
    final d = HandoverNewDevice(room: End(rooms), relay: relay, onWords: got.add, now: now);
    await d.start();
    addTearDown(d.close);
    return d;
  }

  Future<void> showPhone(WidgetTester tester, HandoverNewDevice device, {required AppLock lock, required FakeAccount account, String? code}) =>
      show(tester, HandoverApproveScreen(code: code ?? device.codeText, room: () => End(rooms), lock: lock, account: account, relay: relay, now: now));

  testWidgets('the phone shows the digits and the warning, asks its fingerprint on yes, and only then hands the words over', (tester) async {
    final words = AccountCrypto.newWords();
    final device = await newDevice();
    final finger = FakeDevice(can: true, gives: true);
    final lock = lockOn(MemoryStore(), finger);
    await lock.load();
    final account = FakeAccount(kept: words);
    await showPhone(tester, device, lock: lock, account: account);
    expect(find.text('Does the new device show the same six digits?'), findsOneWidget);
    expect(tester.widget<PairingCode>(find.byType(PairingCode)).code, device.digits);
    expect(find.textContaining('Never for a code someone else shows you or sends you'), findsOneWidget);
    // Nothing was asked of the account or the lock, and nothing sent, before the yes.
    expect(finger.asked, 0);
    expect(account.keptAsked, 0);
    expect(got, isEmpty);

    await tester.tap(find.byKey(const ValueKey('handover-yes')));
    await settle(tester);
    expect(finger.asked, 1);
    expect(account.keptAsked, 1);
    expect(got, [words]);
    expect(find.text('Handed over'), findsOneWidget);
    expect(device.phase, HandoverPhase.done);
    await close(tester);
    expect(rooms.empty, isTrue);
  });

  testWidgets('a fingerprint put away sends nothing: with no app lock, the account\'s password is asked instead', (tester) async {
    final words = AccountCrypto.newWords();
    final device = await newDevice();
    final finger = FakeDevice(can: true, gives: false);
    final lock = lockOn(MemoryStore(), finger);
    await lock.load();
    final account = FakeAccount(kept: words);
    await showPhone(tester, device, lock: lock, account: account);
    await tester.tap(find.byKey(const ValueKey('handover-yes')));
    await settle(tester);
    expect(finger.asked, 1);
    expect(account.keptAsked, 0);
    expect(got, isEmpty);
    expect(find.text('Your password first'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'not the password');
    await tester.tap(find.text('Sign it in'));
    await settle(tester);
    expect(find.text('That password isn\'t right.'), findsOneWidget);
    expect(got, isEmpty);

    await tester.enterText(find.byType(EditableText), account.password);
    await tester.tap(find.text('Sign it in'));
    await settle(tester);
    expect(got, [words]);
    expect(find.text('Handed over'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a phone with no lock of any kind asks the account\'s password, never the fingerprint', (tester) async {
    final device = await newDevice();
    final finger = FakeDevice(can: false);
    final lock = lockOn(MemoryStore(), finger);
    await lock.load();
    final account = FakeAccount(kept: AccountCrypto.newWords());
    await showPhone(tester, device, lock: lock, account: account);
    await tester.tap(find.byKey(const ValueKey('handover-yes')));
    await settle(tester);
    expect(finger.asked, 0);
    expect(find.text('Your password first'), findsOneWidget);
    expect(account.keptAsked, 0);
    expect(got, isEmpty);
    await close(tester);
    await settle(tester);
    expect(device.phase, HandoverPhase.refused, reason: 'left before anything was sent: a no');
  });

  testWidgets('with the app\'s lock set and no fingerprint switched on, its PIN is asked: a wrong one sends nothing', (tester) async {
    final words = AccountCrypto.newWords();
    final device = await newDevice();
    final finger = FakeDevice(can: true, gives: true);
    final store = MemoryStore();
    final first = lockOn(store, finger);
    await first.load();
    await first.setPin('4821');
    final lock = lockOn(store, finger);
    await lock.load();
    final account = FakeAccount(kept: words);
    await showPhone(tester, device, lock: lock, account: account);
    await tester.tap(find.byKey(const ValueKey('handover-yes')));
    await settle(tester);
    // The fingerprint is not the app lock's way in unless the person switched it on there.
    expect(finger.asked, 0);
    expect(find.byType(PinPad), findsOneWidget);

    Future<void> type(String pin) async {
      for (final d in pin.split('')) {
        await tester.tap(find.byKey(ValueKey('pin-key-$d')));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('pin-submit')));
      await settle(tester);
    }

    await type('4822');
    expect(find.text('That PIN isn\'t right.'), findsOneWidget);
    expect(got, isEmpty);
    expect(account.keptAsked, 0);
    await type('4821');
    expect(got, [words]);
    expect(find.text('Handed over'), findsOneWidget);
    await close(tester);
  });

  testWidgets('"They don\'t match" sends nothing and tells the new device no', (tester) async {
    final device = await newDevice();
    final finger = FakeDevice(can: true, gives: true);
    final lock = lockOn(MemoryStore(), finger);
    await lock.load();
    final account = FakeAccount(kept: AccountCrypto.newWords());
    await showPhone(tester, device, lock: lock, account: account);
    await tester.tap(find.byKey(const ValueKey('handover-no')));
    await settle(tester);
    expect(find.text('Nothing was sent'), findsOneWidget);
    expect(device.phase, HandoverPhase.refused);
    expect(finger.asked, 0);
    expect(account.keptAsked, 0);
    expect(got, isEmpty);
    await close(tester);
  });

  testWidgets('a code that is not a sign-in code, and a new device on another relay, are said plainly', (tester) async {
    final device = await newDevice();
    final lock = lockOn(MemoryStore(), FakeDevice());
    await lock.load();
    final account = FakeAccount(kept: AccountCrypto.newWords());
    await showPhone(tester, device, lock: lock, account: account, code: 'GHOSTPAIR1:abcdef');
    expect(find.textContaining('Scan it from Settings › Computers instead'), findsOneWidget);
    await close(tester);

    // A phone signed in to nothing has nothing to hand over, and joins no room.
    await showPhone(tester, device, lock: lock, account: FakeAccount(), code: device.codeText);
    expect(find.textContaining('isn\'t signed in to an Uplink account'), findsOneWidget);
    expect(device.phase, HandoverPhase.waiting);
    await close(tester);

    final elsewhere = HandoverCode(key: HandoverCode.parse(device.codeText!)!.key, secret: HandoverCode.parse(device.codeText!)!.secret, relay: 'wss://other.test/hub');
    await showPhone(tester, device, lock: lock, account: account, code: elsewhere.text);
    expect(find.text('That device is on another relay'), findsOneWidget);
    expect(find.textContaining('other.test'), findsOneWidget);
    await close(tester);
    device.close();
  });
}

/// Lets what the two ends said arrive and be drawn.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

/// Takes the screen down, as leaving it does.
Future<void> close(WidgetTester tester) => tester.pumpWidget(const SizedBox());
