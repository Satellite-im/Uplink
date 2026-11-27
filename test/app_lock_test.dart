import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_lock/app_lock.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/ui/app_lock_ui.dart';
import 'package:glacier/glacier.dart';

/// The app's lock (GMFB-46; lib/app_lock/app_lock.dart, lib/ui/app_lock_ui.dart): the PIN kept only as a salted hash
/// and checked against it, the growing wait after wrong tries, "Lock after" by a clock the test moves, the lock screen
/// (number pad, wrong PIN, unlock) over the app, Settings › Lock the app, and that with no PIN set nothing is asked,
/// written or drawn.

/// The record kept in memory, with how often it was read and written.
class MemoryStore extends AppLockStore {
  String? value;
  int reads = 0, writes = 0;

  @override
  Future<String?> read() async {
    reads++;
    return value;
  }

  @override
  Future<void> write(String v) async {
    writes++;
    value = v.isEmpty ? null : v;
  }
}

/// A device with a fingerprint ([can]) that takes it or not ([gives]); what was asked of it is counted.
class FakeDevice extends AppLockPlatform {
  FakeDevice({this.can = false, this.gives = false});
  bool can, gives;
  int asked = 0, canAsked = 0;
  final secured = <bool>[];

  @override
  Future<bool> canBiometric() async {
    canAsked++;
    return can;
  }

  @override
  Future<bool> askBiometric(String reason) async {
    asked++;
    return gives;
  }

  @override
  Future<void> secure(bool on) async => secured.add(on);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var now = DateTime(2026, 11, 23, 12);
  setUp(() => now = DateTime(2026, 11, 23, 12));

  /// A lock on [store] with a quick hash, a clock the test moves and no timers of its own.
  AppLock lockOn(MemoryStore store, {FakeDevice? device, bool desktop = false}) =>
      AppLock(store: store, platform: device ?? FakeDevice(), now: () => now, hasher: PinHash.here, memoryKiB: 16, passes: 1, timers: false, desktop: desktop);

  group('the PIN', () {
    test('is kept only as a salted hash, and checked against it', () async {
      final store = MemoryStore();
      final lock = lockOn(store);
      await lock.load();
      await lock.setPin('482915');
      expect(lock.isSet, isTrue);
      expect(lock.locked, isFalse, reason: 'setting a PIN leaves the app open');
      final kept = jsonDecode(store.value!) as Map;
      expect(store.value, isNot(contains('482915')));
      expect(kept['kdf'], 'argon2id');
      expect((kept['salt'] as String).length, 32);
      expect((kept['hash'] as String).length, 64);
      expect(await lock.check('482915'), isTrue);
      expect(await lock.check('482916'), isFalse);
      // The same PIN set again is a new salt and so a new hash.
      await lock.setPin('482915');
      final again = jsonDecode(store.value!) as Map;
      expect(again['salt'], isNot(kept['salt']));
      expect(again['hash'], isNot(kept['hash']));
    });

    test('is four to eight digits', () async {
      final lock = lockOn(MemoryStore());
      await lock.load();
      for (final bad in ['', '123', '123456789', '12a4', '12 34']) {
        await expectLater(lock.setPin(bad), throwsArgumentError, reason: bad);
      }
      expect(lock.isSet, isFalse);
      await lock.setPin('1234');
      await lock.setPin('12345678');
      expect(await lock.check('12345678'), isTrue);
    });

    test('with the app\'s own Argon2id settings, off the main isolate', () async {
      final store = MemoryStore();
      final lock = AppLock(store: store, platform: FakeDevice(), timers: false);
      await lock.load();
      await lock.setPin('2580');
      final kept = jsonDecode(store.value!) as Map;
      expect(kept['m'], PinHash.memoryKiB);
      expect(kept['t'], PinHash.passes);
      expect(await lock.check('2580'), isTrue);
      expect(await lock.check('2581'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('opens the app it locked, and a record that can\'t be read is no lock', () async {
      final store = MemoryStore();
      final first = lockOn(store);
      await first.load();
      await first.setPin('7410');
      // The app opened again: locked from the start.
      final lock = lockOn(store);
      await lock.load();
      expect(lock.locked, isTrue);
      expect(await lock.unlockWith('7411'), isFalse);
      expect(lock.locked, isTrue);
      expect(await lock.unlockWith('7410'), isTrue);
      expect(lock.locked, isFalse);
      await lock.remove();
      expect(store.value, isNull);
      expect(lock.isSet, isFalse);

      final junk = lockOn(MemoryStore()..value = 'not a record');
      await junk.load();
      expect(junk.isSet, isFalse);
      expect(junk.locked, isFalse);
    });
  });

  group('wrong tries', () {
    test('wait longer each time from the fifth', () {
      expect([for (var n = 0; n <= 10; n++) AppLock.waitAfter(n).inSeconds], [0, 0, 0, 0, 0, 30, 60, 300, 900, 3600, 3600]);
      expect(AppLock.waitWords(const Duration(seconds: 30)), '30 seconds');
      expect(AppLock.waitWords(const Duration(seconds: 1)), '1 second');
      expect(AppLock.waitWords(const Duration(seconds: 61)), '2 minutes');
      expect(AppLock.waitWords(const Duration(minutes: 60)), '60 minutes');
    });

    test('the fifth starts a wait in which no PIN is taken, kept across the app closing', () async {
      final store = MemoryStore();
      var lock = lockOn(store);
      await lock.load();
      await lock.setPin('1357');
      lock.lockNow();
      for (var i = 0; i < 4; i++) {
        expect(await lock.unlockWith('0000'), isFalse);
        expect(lock.wait, Duration.zero, reason: 'try ${i + 1}');
      }
      expect(await lock.unlockWith('0000'), isFalse);
      expect(lock.fails, 5);
      expect(lock.wait, const Duration(seconds: 30));
      // The right PIN is not looked at while the wait runs, and is not counted as a wrong one.
      expect(await lock.unlockWith('1357'), isFalse);
      expect(lock.fails, 5);
      expect(lock.locked, isTrue);
      // Closing the app hands out no fresh tries.
      now = now.add(const Duration(seconds: 10));
      lock = lockOn(store);
      await lock.load();
      expect(lock.fails, 5);
      expect(lock.wait, const Duration(seconds: 20));
      now = now.add(const Duration(seconds: 20));
      expect(lock.wait, Duration.zero);
      // The sixth wrong one waits a minute.
      expect(await lock.unlockWith('0000'), isFalse);
      expect(lock.wait, const Duration(minutes: 1));
      now = now.add(const Duration(minutes: 1));
      expect(await lock.unlockWith('1357'), isTrue);
      expect(lock.fails, 0);
      expect(lock.wait, Duration.zero);
    });

    test('a clock set back does not make the wait longer than it was', () async {
      final lock = lockOn(MemoryStore());
      await lock.load();
      await lock.setPin('1357');
      for (var i = 0; i < 5; i++) {
        await lock.check('0000');
      }
      now = now.subtract(const Duration(days: 3));
      expect(lock.wait, const Duration(seconds: 30));
    });
  });

  group('Lock after', () {
    Future<AppLock> open(MemoryStore store, {int after = 60, bool desktop = false, List<String>? said}) async {
      final lock = lockOn(store, desktop: desktop);
      if (said != null) lock.sayTo = said.add;
      await lock.load();
      await lock.setPin('2468');
      await lock.setAfter(after);
      return lock;
    }

    test('locks once the app has been away that long, not before', () async {
      final lock = await open(MemoryStore());
      lock.away();
      now = now.add(const Duration(seconds: 59));
      lock.back();
      expect(lock.locked, isFalse);
      lock.away();
      now = now.add(const Duration(seconds: 60));
      // Its timer rings while the app is still away (a computer's window behind another).
      lock.checkAway();
      expect(lock.locked, isTrue);
      await lock.unlockWith('2468');
      // Away and back twice within the minute: each time away is counted on its own.
      lock.away();
      now = now.add(const Duration(seconds: 40));
      lock.back();
      lock.away();
      now = now.add(const Duration(seconds: 40));
      lock.back();
      expect(lock.locked, isFalse);
      for (final (after, away) in [(300, const Duration(minutes: 5)), (3600, const Duration(hours: 1))]) {
        await lock.setAfter(after);
        lock.away();
        now = now.add(away - const Duration(seconds: 1));
        lock.back();
        expect(lock.locked, isFalse, reason: '$after');
        lock.away();
        now = now.add(away);
        lock.back();
        expect(lock.locked, isTrue, reason: '$after');
        await lock.unlockWith('2468');
      }
    });

    test('"At once" locks as the app leaves; a computer\'s window behind another takes ten seconds', () async {
      final lock = await open(MemoryStore(), after: 0);
      lock.away();
      expect(lock.locked, isTrue);

      final desk = await open(MemoryStore(), after: 0, desktop: true);
      desk.away(behind: true);
      expect(desk.locked, isFalse);
      now = now.add(const Duration(seconds: 9));
      desk.back();
      expect(desk.locked, isFalse);
      desk.away(behind: true);
      now = now.add(const Duration(seconds: 10));
      desk.back();
      expect(desk.locked, isTrue);
      await desk.unlockWith('2468');
      // Behind, then hidden: hidden locks at once.
      desk.away(behind: true);
      desk.away();
      expect(desk.locked, isTrue);
    });

    test('says how it stands, for Android\'s notifications and app switcher', () async {
      final said = <String>[];
      final lock = await open(MemoryStore(), said: said);
      expect(said, ['open']);
      final left = now;
      lock.away();
      expect(said.last, '${left.add(const Duration(seconds: 60)).millisecondsSinceEpoch}');
      lock.back();
      expect(said.last, 'open');
      lock.lockNow();
      expect(said.last, 'on');
      await lock.unlockWith('2468');
      expect(said.last, 'open');
      await lock.remove();
      expect(said.last, '');
    });

    test('a fingerprint prompt over the app is not the person going away', () async {
      final device = FakeDevice(can: true, gives: true);
      final store = MemoryStore();
      final lock = AppLock(store: store, platform: _Prompting(device, () => AppLock.instance.away(behind: true)), now: () => now, hasher: PinHash.here, memoryKiB: 16, passes: 1, timers: false, desktop: true);
      AppLock.instance = lock;
      addTearDown(() => AppLock.instance = AppLock());
      await lock.load();
      await lock.setPin('2468');
      await lock.setAfter(0);
      await lock.setBiometric(true);
      // Switching it on asks once; the window goes behind the prompt meanwhile, and "At once" must not lock for it.
      expect(await lock.askBiometric('test'), isTrue);
      now = now.add(const Duration(seconds: 30));
      lock.back();
      expect(lock.locked, isFalse);
    });
  });

  group('fingerprint or face', () {
    test('unlocks where it is on and given; the PIN works either way', () async {
      final device = FakeDevice(can: true, gives: false);
      final store = MemoryStore();
      final lock = lockOn(store, device: device);
      await lock.load();
      await lock.setPin('9753');
      lock.lockNow();
      // Off: the device is not asked.
      expect(await lock.unlockWithBiometric(), isFalse);
      expect(device.asked, 0);
      await lock.setBiometric(true);
      await lock.askCanBiometric();
      // Put away: still locked.
      expect(await lock.unlockWithBiometric(), isFalse);
      expect(device.asked, 1);
      expect(lock.locked, isTrue);
      expect(await lock.unlockWith('9753'), isTrue);
      lock.lockNow();
      device.gives = true;
      expect(await lock.unlockWithBiometric(), isTrue);
      expect(lock.locked, isFalse);
      // A device with none: never asked, whatever is kept.
      final none = FakeDevice();
      final other = lockOn(store, device: none);
      await other.load();
      expect(other.biometric, isTrue);
      expect(await other.unlockWithBiometric(), isFalse);
      expect(none.asked, 0);
      expect(other.locked, isTrue);
    });
  });

  group('with no PIN set', () {
    test('nothing is asked of the device, written or said', () async {
      final store = MemoryStore();
      final device = FakeDevice(can: true, gives: true);
      final said = <String>[];
      final lock = lockOn(store, device: device)..sayTo = said.add;
      await lock.load();
      expect(lock.isSet, isFalse);
      expect(lock.locked, isFalse);
      lock.away();
      now = now.add(const Duration(days: 1));
      lock.back();
      lock.lockNow();
      lock.checkAway();
      expect(lock.locked, isFalse);
      expect(await lock.unlockWithBiometric(), isFalse);
      expect(store.writes, 0);
      expect(device.asked, 0);
      expect(device.canAsked, 0);
      expect(device.secured, isEmpty);
      expect(said, isEmpty);
    });
  });

  group('kept in the app\'s folder', () {
    test('the record is read back, and gone with its file', () async {
      final dir = Directory.systemTemp.createTempSync('ghost-app-lock-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = FolderLockStore(dir, keychain: false);
      expect(await store.read(), isNull);
      await store.write('{"a":1}');
      expect(await store.read(), '{"a":1}');
      expect(store.folder, dir.path);
      // The folder deleted (the way to start again on a paired computer): no lock.
      File('${dir.path}/app-lock.json').deleteSync();
      expect(await store.read(), isNull);
      await store.write('{"a":2}');
      await store.write('');
      expect(File('${dir.path}/app-lock.json').existsSync(), isFalse);
    });
  });

  // --- the screens ----------------------------------------------------------------------------------------------------

  /// The gate over a page with one button, which counts its presses.
  Future<void> pumpGate(WidgetTester tester, AppLock lock, ValueNotifier<int> presses) async {
    tester.view.physicalSize = const Size(412, 1000) * 2.0;
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
        builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: AppLockGate(lock: lock, child: GlacierToastProvider(child: child!)))),
        home: Center(
          child: GestureDetector(
            key: const ValueKey('behind'),
            onTap: () => presses.value++,
            child: const SizedBox(width: 200, height: 200, child: Text('A secret conversation')),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String pin, {bool submit = true}) async {
    for (final d in pin.split('')) {
      await tester.tap(find.byKey(ValueKey('pin-key-$d')));
      await tester.pump();
    }
    if (!submit) return;
    await tester.tap(find.byKey(const ValueKey('pin-submit')));
    await tester.pump();
    await tester.pump();
  }

  /// Takes the screens down, so nothing of theirs (the wait's ticking line) outlives the test.
  Future<void> close(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  String line(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('lock-line'))).data!;

  testWidgets('with no PIN set the gate is the app and nothing else', (tester) async {
    final store = MemoryStore();
    final lock = lockOn(store);
    await lock.load();
    final presses = ValueNotifier(0);
    await pumpGate(tester, lock, presses);
    expect(find.byType(AppLockScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('behind')));
    expect(presses.value, 1);
    // Away for a day and back: still nothing.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(days: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(AppLockScreen), findsNothing);
    expect(store.writes, 0);
    // A lock never read (a test of another screen, which starts no lock) is the same.
    final unread = lockOn(MemoryStore()..value = '{}');
    await pumpGate(tester, unread, presses);
    expect(find.byType(AppLockScreen), findsNothing);
    await close(tester);
  });

  testWidgets('locked: the lock screen covers the app, a wrong PIN says so, the right one opens it', (tester) async {
    final store = MemoryStore();
    final first = lockOn(store);
    await first.load();
    await first.setPin('4821');
    final lock = lockOn(store);
    await lock.load();
    final presses = ValueNotifier(0);
    await pumpGate(tester, lock, presses);
    expect(find.byType(AppLockScreen), findsOneWidget);
    expect(find.text('Uplink is locked'), findsOneWidget);
    expect(line(tester), 'Enter your PIN');
    // What is behind takes no touch, and the lock screen is drawn over all of it, opaque.
    // (The touch lands on the pad's 5, which is where the button behind is: taken back below.)
    await tester.tap(find.byKey(const ValueKey('behind')), warnIfMissed: false);
    expect(presses.value, 0);
    await tester.tap(find.byKey(const ValueKey('pin-key-back')));
    await tester.pump();
    final cover = tester.widget<ColoredBox>(find.descendant(of: find.byType(AppLockScreen), matching: find.byType(ColoredBox)).first);
    expect(cover.color.a, 1.0);
    expect(tester.getSize(find.byType(AppLockScreen)), const Size(412, 1000));
    // Fewer than four digits can't be sent.
    await type(tester, '482');
    expect(lock.fails, 0);
    await tester.tap(find.byKey(const ValueKey('pin-key-back')));
    await tester.tap(find.byKey(const ValueKey('pin-key-back')));
    await tester.tap(find.byKey(const ValueKey('pin-key-back')));
    await tester.pump();
    await type(tester, '4822');
    expect(line(tester), 'Wrong PIN. Try again.');
    expect(lock.locked, isTrue);
    expect(find.byType(AppLockScreen), findsOneWidget);
    await type(tester, '4821');
    expect(lock.locked, isFalse);
    expect(find.byType(AppLockScreen), findsNothing);
    await tester.tap(find.byKey(const ValueKey('behind')));
    expect(presses.value, 1);
    await close(tester);
  });

  testWidgets('the keyboard\'s digits, Backspace and Enter work the pad', (tester) async {
    final store = MemoryStore();
    final lock = lockOn(store);
    await lock.load();
    await lock.setPin('4821');
    lock.lockNow();
    await pumpGate(tester, lock, ValueNotifier(0));
    for (final (key, c) in [(LogicalKeyboardKey.digit4, '4'), (LogicalKeyboardKey.digit8, '8'), (LogicalKeyboardKey.digit2, '2'), (LogicalKeyboardKey.digit9, '9')]) {
      await tester.sendKeyDownEvent(key, character: c);
      await tester.sendKeyUpEvent(key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1, character: '1');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(lock.locked, isFalse);
    await close(tester);
  });

  testWidgets('after five wrong PINs the lock screen says how long to wait and takes none', (tester) async {
    final store = MemoryStore();
    final lock = lockOn(store);
    await lock.load();
    await lock.setPin('4821');
    lock.lockNow();
    await pumpGate(tester, lock, ValueNotifier(0));
    for (var i = 0; i < 5; i++) {
      await type(tester, '0000');
    }
    expect(line(tester), 'Too many wrong tries. Try again in 30 seconds.');
    // The right PIN typed during the wait goes nowhere.
    await type(tester, '4821');
    expect(lock.locked, isTrue);
    // The line counts down, and the pad takes the PIN once the wait is over.
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
    expect(line(tester), 'Too many wrong tries. Try again in 18 seconds.');
    now = now.add(const Duration(seconds: 18));
    await tester.pump(const Duration(seconds: 1));
    expect(line(tester), isNot(contains('Too many')));
    await type(tester, '4821');
    expect(lock.locked, isFalse);
    await close(tester);
  });

  testWidgets('leaving the app locks it as "Lock after" says, and the fingerprint opens it where it is on', (tester) async {
    final store = MemoryStore();
    final device = FakeDevice(can: true, gives: true);
    final lock = lockOn(store, device: device);
    await lock.load();
    await lock.setPin('4821');
    await lock.askCanBiometric();
    final presses = ValueNotifier(0);
    await pumpGate(tester, lock, presses);
    expect(find.byType(AppLockScreen), findsNothing);
    // A minute by default: half a minute away is not enough.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(AppLockScreen), findsNothing);
    // The notification shade over a phone (inactive) is not away.
    await lock.setAfter(0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(AppLockScreen), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(AppLockScreen), findsOneWidget);
    // No fingerprint key while that is off, and the device is not asked.
    expect(find.byKey(const ValueKey('lock-biometric')), findsNothing);
    expect(device.asked, 0);
    await type(tester, '4821');
    await lock.setBiometric(true);
    lock.lockNow();
    await tester.pump();
    // Asked for as the lock comes up, and given: open.
    await tester.pump();
    await tester.pump();
    expect(device.asked, 1);
    expect(find.byType(AppLockScreen), findsNothing);
    // Put away: the lock stays, its key on the pad asks again, and the PIN still works.
    device.gives = false;
    lock.lockNow();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(device.asked, 2);
    expect(find.byType(AppLockScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lock-biometric')));
    await tester.pump();
    expect(device.asked, 3);
    expect(lock.locked, isTrue);
    await type(tester, '4821');
    expect(lock.locked, isFalse);
    await close(tester);
  });

  testWidgets('"Forgot your PIN?" says the way back in and leaves the lock on', (tester) async {
    final store = MemoryStore();
    final lock = lockOn(store);
    await lock.load();
    await lock.setPin('4821');
    lock.lockNow();
    await pumpGate(tester, lock, ValueNotifier(0));
    await tester.tap(find.byKey(const ValueKey('lock-forgot')));
    await tester.pump();
    expect(find.byKey(const ValueKey('lock-forgot-page')), findsOneWidget);
    expect(find.textContaining('nobody can read it back or reset it'), findsOneWidget);
    expect(find.textContaining('The way back in is'), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-submit')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lock-forgot-back')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pin-submit')), findsOneWidget);
    expect(lock.locked, isTrue);
    expect(store.value, isNotNull);
    await close(tester);
  });

  testWidgets('Settings › Lock the app: a PIN set and confirmed, then changed and turned off only after the PIN', (tester) async {
    final store = MemoryStore();
    final lock = lockOn(store);
    await lock.load();
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
        home: SingleChildScrollView(child: AppLockPane(lock: lock)),
      ),
    ));
    await tester.pump();
    String setLine() => tester.widget<Text>(find.byKey(const ValueKey('pin-set-line'))).data!;
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    expect(find.text('Set a PIN'), findsOneWidget);
    expect(find.text('Lock after'), findsNothing);
    await tester.tap(find.text('Set a PIN'));
    await settle();
    expect(setLine(), 'Choose a PIN of 4 to 8 digits');
    await type(tester, '13579');
    expect(setLine(), 'Type it again');
    // Typed differently the second time: nothing is set.
    await type(tester, '13570');
    expect(setLine(), 'Those two weren\'t the same. Start again.');
    expect(lock.isSet, isFalse);
    await type(tester, '13579');
    await type(tester, '13579');
    await settle();
    expect(lock.isSet, isTrue);
    expect(lock.locked, isFalse);
    expect(await lock.check('13579'), isTrue);
    expect(find.text('Lock after'), findsOneWidget);
    expect(find.text('Change PIN'), findsOneWidget);
    // No fingerprint on this device: its switch is not offered.
    expect(find.text('Unlock with fingerprint or face'), findsNothing);
    await tester.tap(find.text('5 minutes'));
    await settle();
    expect(lock.after, 300);

    // Changing it asks for the PIN now first.
    await tester.tap(find.text('Change PIN'));
    await settle();
    expect(setLine(), 'Enter your PIN now');
    await type(tester, '0000');
    expect(setLine(), 'Wrong PIN. Try again.');
    await type(tester, '13579');
    expect(setLine(), 'Choose a PIN of 4 to 8 digits');
    await type(tester, '2468');
    await type(tester, '2468');
    await settle();
    expect(await lock.check('13579'), isFalse);
    expect(await lock.check('2468'), isTrue);
    expect(lock.after, 300, reason: 'a new PIN keeps the choices');

    // Lock now locks.
    await tester.tap(find.text('Lock now'));
    await tester.pump();
    expect(lock.locked, isTrue);
    await lock.unlockWith('2468');

    // Turning it off asks for the PIN too.
    await tester.tap(find.byType(GlacierSwitch).first);
    await settle();
    expect(setLine(), 'Enter your PIN now');
    await type(tester, '2468');
    await settle();
    expect(lock.isSet, isFalse);
    expect(store.value, isNull);
    expect(find.text('Set a PIN'), findsOneWidget);
    await close(tester);
  });
}

/// A device whose fingerprint prompt puts the app's window behind it while it is up.
class _Prompting extends AppLockPlatform {
  _Prompting(this.device, this.whileUp);
  final FakeDevice device;
  final void Function() whileUp;

  @override
  Future<bool> canBiometric() => device.canBiometric();
  @override
  Future<bool> askBiometric(String reason) async {
    whileUp();
    return device.askBiometric(reason);
  }

  @override
  Future<void> secure(bool on) => device.secure(on);
}
