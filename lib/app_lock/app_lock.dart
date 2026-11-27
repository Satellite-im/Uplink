import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../account/account_crypto.dart';
import '../app_state.dart';
import '../desktop/platform.dart' show MacPlatform;
import '../platform_info.dart';
import '../sms.dart';
import '../standalone/standalone.dart' show StandaloneCalls;

/// The app's own lock (GMFB-46, Kevin, Android: "It could be useful to allow for users to lock their app with
/// biometrics, password, pin, or pattern"): a PIN of four to eight digits, asked for when the app is opened and when
/// it comes back after being away longer than the person chose, with the device's fingerprint or face in its place
/// where the person switched that on.
///
/// What it is and is not:
/// - The PIN is never kept. What is kept is a salted Argon2id hash of it ([PinHash]), where this device keeps its
///   secrets: Android's vault (AccountVault.kt), the Keychain on a Mac and an iPhone, the app's own folder on Windows
///   and Linux ([AppLockStore]).
/// - It is a door on the app's screens, nothing more. What the app keeps on the device is exactly as it was: nothing
///   is sealed under the PIN, so someone who can read the device's files (or delete the lock's own) is not stopped.
/// - A PIN this short can be guessed by anyone holding its hash and the time to try every one; the hash only makes
///   each guess slow. The growing wait after wrong tries ([waitAfter]) is what holds on the lock screen itself, and it
///   goes by the device's clock.
///
/// Nothing here runs until [load] is called (lib/main.dart, lib/desktop/main.dart, lib/bubble.dart), and with no PIN
/// set nothing is asked of the device and nothing is written.
class AppLock extends ChangeNotifier {
  AppLock({AppLockStore? store, AppLockPlatform? platform, DateTime Function()? now, PinHasher? hasher, this.memoryKiB = PinHash.memoryKiB, this.passes = PinHash.passes, this.timers = true, bool? desktop})
      : store = store ?? const SecretLockStore(),
        platform = platform ?? const AppLockPlatform(),
        _now = now ?? DateTime.now,
        _hasher = hasher ?? PinHash.of,
        desktop = desktop ?? (!kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux));

  /// The app's one lock. Replaced before [load] where the hash is kept in a folder (a computer, an iPhone), and by a
  /// test.
  static AppLock instance = AppLock();

  /// The choice Android's side reads how the lock stands from ([sayTo]; AppLock.kt). Not the lock itself: a hint for
  /// its notifications and its app switcher, which the app's API can read and write as any choice.
  static const statePref = 'app_lock_hide';

  /// Sets the app's lock up as the app starts, before its first page: where the record is kept ([folder] on a computer
  /// and an iPhone, with [keychain] as their other keys have it; Android's vault otherwise), then what is kept read.
  /// [tell] false for a conversation's bubble, which has a lock of its own in step with nothing: the app's says how
  /// things stand.
  static Future<void> start(AppState app, {Directory? folder, bool keychain = true, bool tell = true}) async {
    if (folder != null) instance = AppLock(store: FolderLockStore(folder, keychain: keychain));
    final lock = instance;
    if (tell && !kIsWeb && PlatformInfo.isAndroid) lock.sayTo = (state) => app.keep(statePref, state);
    await lock.load();
    // Everything this device of its own kept was deleted (signed out with everything, from the lock screen's "Forgot
    // your PIN?" or from Settings, or removed from another device: lib/account/account.dart), and the app started
    // again with nothing but the note saying so: the lock went with what it guarded.
    if (lock.isSet && Sms.standalone && app.choice(StandaloneCalls.noteKey, '').isNotEmpty) await lock.remove();
  }

  final AppLockStore store;
  final AppLockPlatform platform;
  final DateTime Function() _now;
  final PinHasher _hasher;

  /// Argon2id's settings for a PIN set from here on; one set before keeps its own (they are in its record).
  final int memoryKiB, passes;

  /// Whether the lock sets a timer for itself while the app is away. Off in a test that moves the clock by hand.
  final bool timers;

  /// A computer, where another window in front counts as away (see [away]).
  final bool desktop;

  /// The choices for "Lock after", in seconds away from the app.
  static const afterChoices = [0, 60, 300, 3600];

  /// On a computer a window that is only behind another one locks no sooner than this, whatever "Lock after" says:
  /// the app's own file chooser and the fingerprint prompt put the window behind for a moment too.
  static const behindGrace = Duration(seconds: 10);

  /// How long the lock screen waits after the [fails]th wrong PIN in a row: nothing for the first four, then half a
  /// minute, a minute, five, fifteen, and an hour from the ninth on.
  static Duration waitAfter(int fails) => switch (fails) {
        < 5 => Duration.zero,
        5 => const Duration(seconds: 30),
        6 => const Duration(minutes: 1),
        7 => const Duration(minutes: 5),
        8 => const Duration(minutes: 15),
        _ => const Duration(hours: 1),
      };

  /// [wait] in words, for the lock screen's line: "30 seconds", "1 minute", "14 minutes".
  static String waitWords(Duration wait) {
    if (wait.inSeconds < 60) {
      final s = max(1, wait.inSeconds);
      return '$s ${s == 1 ? 'second' : 'seconds'}';
    }
    final m = (wait.inSeconds / 60).ceil();
    return '$m ${m == 1 ? 'minute' : 'minutes'}';
  }

  LockRecord? _record;

  /// Whether [load] has read what is kept. Until then there is no lock as far as the app can tell.
  bool loaded = false;

  /// A PIN is set.
  bool get isSet => _record != null;

  /// The app is locked now: the lock screen is over everything ([AppLockGate]).
  bool get locked => _locked;
  bool _locked = false;

  /// "Lock after", in seconds away.
  int get after => _record?.after ?? 60;

  /// The person switched "Unlock with fingerprint or face" on.
  bool get biometric => _record?.bio ?? false;

  /// Whether this device can ask for a fingerprint or a face, as it last said ([askCanBiometric]).
  bool canBiometric = false;

  /// When the app last left the screen, while it is away and not locked yet; [_soft] where it only went behind
  /// another window on a computer.
  DateTime? _left;
  bool _soft = false;
  Timer? _timer;

  /// A fingerprint or face prompt is up: the app going behind it is not the person going away.
  bool _asking = false;

  /// Told how the lock stands, for what reads it outside Dart (Android's notifications and its app switcher,
  /// AppLock.kt): '' with no PIN, 'on' locked, 'open' in use, or the time in milliseconds at which the app, away now,
  /// counts as locked. Only ever called with something new.
  void Function(String state)? sayTo;
  String _said = '';

  /// Reads what is kept. With a PIN set the app starts locked. What can't be read is no lock: there would be nothing
  /// to check a PIN against.
  Future<void> load() async {
    String? kept;
    try {
      kept = await store.read();
    } catch (_) {}
    _record = LockRecord.tryParse(kept);
    _locked = _record != null;
    loaded = true;
    if (isSet) {
      await askCanBiometric();
      unawaited(platform.secure(true));
    }
    _say();
    notifyListeners();
  }

  /// Asks the device whether it has a fingerprint or a face to ask for.
  Future<bool> askCanBiometric() async {
    try {
      canBiometric = await platform.canBiometric();
    } catch (_) {
      canBiometric = false;
    }
    return canBiometric;
  }

  /// How long until a PIN is taken again after wrong tries; zero where one is taken now. Never longer than the wait
  /// those tries earn, so a clock set back does not shut the person out for longer.
  Duration get wait {
    final r = _record;
    if (r == null || r.until == 0) return Duration.zero;
    final left = DateTime.fromMillisecondsSinceEpoch(r.until).difference(_now());
    if (left <= Duration.zero) return Duration.zero;
    final most = waitAfter(r.fails);
    return left > most ? most : left;
  }

  /// Wrong tries in a row so far.
  int get fails => _record?.fails ?? 0;

  /// Sets the PIN (or a new one in place of the old): a new salt, its hash kept, the wrong tries forgotten. The app
  /// stays open. Throws where [pin] is not four to eight digits or the hash could not be kept.
  Future<void> setPin(String pin) async {
    if (!PinHash.valid(pin)) throw ArgumentError('A PIN is 4 to 8 digits.');
    final rnd = Random.secure();
    final salt = Uint8List.fromList([for (var i = 0; i < 16; i++) rnd.nextInt(256)]);
    final hash = await _hasher(pin, salt, memoryKiB, passes);
    final next = LockRecord(salt: _hex(salt), hash: _hex(hash), memoryKiB: memoryKiB, passes: passes, after: after, bio: biometric);
    await store.write(jsonEncode(next.toJson()));
    _record = next;
    unawaited(platform.secure(true));
    _say();
    notifyListeners();
  }

  /// Whether [pin] is the PIN. A wrong one is counted and may start a wait; none is looked at during a wait.
  Future<bool> check(String pin) async {
    final r = _record;
    if (r == null) return true;
    if (wait > Duration.zero) return false;
    var right = false;
    if (PinHash.valid(pin)) {
      try {
        right = PinHash.same(await _hasher(pin, _unhex(r.salt), r.memoryKiB, r.passes), _unhex(r.hash));
      } catch (_) {}
    }
    // Set aside or changed while the hash was worked out.
    if (!identical(_record, r)) return false;
    if (right) {
      if (r.fails != 0 || r.until != 0) await _keep(r.copyWith(fails: 0, until: 0));
    } else {
      final fails = r.fails + 1;
      final w = waitAfter(fails);
      await _keep(r.copyWith(fails: fails, until: w == Duration.zero ? 0 : _now().add(w).millisecondsSinceEpoch));
    }
    notifyListeners();
    return right;
  }

  /// [check], and the app opened where it is right.
  Future<bool> unlockWith(String pin) async {
    if (!await check(pin)) return false;
    _open();
    return true;
  }

  /// The device's fingerprint or face in the PIN's place, where the person switched it on. False where it was not
  /// given, was put away, or this device has none: the PIN is always the other way in.
  Future<bool> unlockWithBiometric() async {
    if (!_locked || !biometric || !canBiometric || _asking) return false;
    if (!await askBiometric('Unlock Uplink')) return false;
    if (!isSet) return false;
    _open();
    return true;
  }

  /// Asks for a fingerprint or a face, saying [reason]; true where the device took one.
  Future<bool> askBiometric(String reason) async {
    if (_asking) return false;
    _asking = true;
    try {
      return await platform.askBiometric(reason);
    } catch (_) {
      return false;
    } finally {
      _asking = false;
    }
  }

  void _open() {
    _locked = false;
    _left = null;
    _timer?.cancel();
    _say();
    notifyListeners();
  }

  /// Locks the app now (Settings › Lock the app › Lock now).
  void lockNow() {
    if (!isSet || _locked) return;
    _locked = true;
    _left = null;
    _timer?.cancel();
    _say();
    notifyListeners();
  }

  /// The PIN set aside: no lock from here on, and nothing of it kept.
  Future<void> remove() async {
    await store.write('');
    _record = null;
    _locked = false;
    _left = null;
    _timer?.cancel();
    unawaited(platform.secure(false));
    _say();
    notifyListeners();
  }

  Future<void> setAfter(int seconds) async {
    final r = _record;
    if (r == null || r.after == seconds || !afterChoices.contains(seconds)) return;
    await _keep(r.copyWith(after: seconds));
    notifyListeners();
  }

  Future<void> setBiometric(bool on) async {
    final r = _record;
    if (r == null || r.bio == on) return;
    await _keep(r.copyWith(bio: on));
    notifyListeners();
  }

  Future<void> _keep(LockRecord next) async {
    _record = next;
    try {
      await store.write(jsonEncode(next.toJson()));
    } catch (_) {}
  }

  /// How long away locks the app, as it left: "Lock after", and on a computer at least [behindGrace] for a window that
  /// is only behind another.
  Duration get _limit {
    final chosen = Duration(seconds: after);
    return _soft && chosen < behindGrace ? behindGrace : chosen;
  }

  /// The app left the screen. [behind] on a computer whose window is only behind another one. Locks at once where
  /// "Lock after" says so; otherwise the time is kept for [back], and a timer set where the app may still be seen (a
  /// computer's window behind another).
  void away({bool behind = false}) {
    if (!isSet || _locked || _asking) return;
    // Hidden after being behind: hidden is what counts from here.
    if (_left != null && _soft && !behind) _soft = false;
    if (_left == null) {
      _left = _now();
      _soft = behind;
    }
    _timer?.cancel();
    final rest = _limit - _now().difference(_left!);
    if (rest <= Duration.zero) return lockNow();
    if (timers) _timer = Timer(rest, checkAway);
    _say();
  }

  /// Locks where the app has been away long enough: when its timer rings, and as it comes back.
  void checkAway() {
    if (!isSet || _locked || _left == null) return;
    final gone = _now().difference(_left!);
    // A clock set back while away tells nothing of how long it was: locked.
    if (gone.isNegative || gone >= _limit) lockNow();
  }

  /// The app is on the screen again: locked where it was away long enough.
  void back() {
    if (!isSet) return;
    _timer?.cancel();
    checkAway();
    _left = null;
    _say();
  }

  /// Stops the timer (the gate is gone: a test's end).
  void stopTimer() => _timer?.cancel();

  void _say() {
    final r = _record;
    final state = r == null ? '' : _locked ? 'on' : _left == null ? 'open' : '${_left!.add(_limit).millisecondsSinceEpoch}';
    if (state == _said) return;
    _said = state;
    sayTo?.call(state);
  }

  static String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  static Uint8List _unhex(String hex) => Uint8List.fromList([for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

/// Works a PIN and its salt into the hash that is kept: [PinHash.of] in the app, something quick in a test.
typedef PinHasher = Future<Uint8List> Function(String pin, Uint8List salt, int memoryKiB, int passes);

/// The PIN's hash: Argon2id (pointycastle's, as the account's password is hashed, lib/account/account_crypto.dart)
/// under a salt of its own, off the main isolate. Lighter than a password's (19 MiB, 2 passes: a few tenths of a
/// second on a phone) since it is run at every unlock; with at most a hundred million PINs no setting would keep the
/// hash safe from someone who holds it.
class PinHash {
  static const memoryKiB = 19 * 1024, passes = 2;

  /// Four to eight digits.
  static bool valid(String pin) => RegExp(r'^[0-9]{4,8}$').hasMatch(pin);

  static Future<Uint8List> of(String pin, Uint8List salt, int memoryKiB, int passes) => AccountCrypto.passwordKeyAway(pin, salt, memoryKiB: memoryKiB, passes: passes);

  /// The same, where it is run: for a test.
  static Future<Uint8List> here(String pin, Uint8List salt, int memoryKiB, int passes) async => AccountCrypto.passwordKey(pin, salt, memoryKiB: memoryKiB, passes: passes);

  /// Whether two hashes are the same, in the same time whichever byte differs.
  static bool same(List<int> a, List<int> b) {
    if (a.length != b.length || a.isEmpty) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// What is kept of the lock: the hash and what made it, the person's two choices, and the wrong tries so far (kept so
/// that closing the app does not hand out fresh ones).
class LockRecord {
  const LockRecord({required this.salt, required this.hash, required this.memoryKiB, required this.passes, this.after = 60, this.bio = false, this.fails = 0, this.until = 0});
  final String salt, hash;
  final int memoryKiB, passes;
  final int after;
  final bool bio;
  final int fails;

  /// When a PIN is taken again, in milliseconds; 0 for now.
  final int until;

  LockRecord copyWith({int? after, bool? bio, int? fails, int? until}) =>
      LockRecord(salt: salt, hash: hash, memoryKiB: memoryKiB, passes: passes, after: after ?? this.after, bio: bio ?? this.bio, fails: fails ?? this.fails, until: until ?? this.until);

  Map<String, Object> toJson() => {'v': 1, 'kdf': 'argon2id', 'salt': salt, 'hash': hash, 'm': memoryKiB, 't': passes, 'after': after, 'bio': bio, 'fails': fails, 'until': until};

  /// The record in [text]; null where there is none or it is not one this build can check a PIN against.
  static LockRecord? tryParse(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['kdf'] != 'argon2id') return null;
      final salt = j['salt'], hash = j['hash'], m = j['m'], t = j['t'];
      if (salt is! String || hash is! String || m is! int || t is! int) return null;
      final hex = RegExp(r'^([0-9a-f]{2})+$');
      if (!hex.hasMatch(salt) || !hex.hasMatch(hash) || m < 8 || t < 1) return null;
      final after = j['after'];
      return LockRecord(
        salt: salt,
        hash: hash,
        memoryKiB: m,
        passes: t,
        after: after is int && AppLock.afterChoices.contains(after) ? after : 60,
        bio: j['bio'] == true,
        fails: j['fails'] is int ? max(0, j['fails'] as int) : 0,
        until: j['until'] is int ? max(0, j['until'] as int) : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Where the lock's record is kept. [write] with nothing forgets it.
abstract class AppLockStore {
  Future<String?> read();
  Future<void> write(String value);

  /// The folder to delete to start again where the app has no way of its own to (a computer paired with a phone);
  /// null where there is none to name.
  String? get folder => null;
}

/// With the device's other secrets (Sms.secretKeep): Android's vault, sealed under a Keystore key.
class SecretLockStore implements AppLockStore {
  const SecretLockStore();
  static const name = 'app_lock';

  @override
  Future<String?> read() => Sms.instance.secretRead(name);
  @override
  Future<void> write(String value) => Sms.instance.secretKeep(name, value);
  @override
  String? get folder => null;
}

/// On a computer and an iPhone: the Keychain where it takes the record ([keychain]; a Mac's release build, an
/// iPhone), with a file in the app's folder that says a lock is set, and the record in that file itself everywhere
/// else (Windows, Linux, a build signed for this Mac alone), as the app's other keys are kept (lib/desktop/store.dart).
///
/// The file is what makes the lock stand: with the app's folder deleted (the app removed from an iPhone; the way to
/// start again on a paired computer) a record left behind in the Keychain locks nothing.
class FolderLockStore implements AppLockStore {
  FolderLockStore(this.dir, {this.keychain = true});
  final Directory dir;
  final bool keychain;

  static const _account = 'app-lock';
  static const _inKeychain = 'keychain';

  File get _file => File('${dir.path}${PlatformInfo.pathSeparator}app-lock.json');

  @override
  String? get folder => dir.path;

  @override
  Future<String?> read() async {
    if (!_file.existsSync()) return null;
    final text = _file.readAsStringSync();
    if (text.trim() != _inKeychain) return text;
    return keychain ? MacPlatform.keyRead(_account) : null;
  }

  @override
  Future<void> write(String value) async {
    if (value.isEmpty) {
      if (keychain) await MacPlatform.keyDelete(_account);
      if (_file.existsSync()) _file.deleteSync();
      return;
    }
    dir.createSync(recursive: true);
    final kept = keychain && await MacPlatform.keyWrite(_account, value);
    _file.writeAsStringSync(kept ? _inKeychain : value, flush: true);
  }
}

/// What the lock asks of the device itself: a fingerprint or a face (Android's BiometricPrompt, AppLock.kt; Touch ID
/// and Face ID through LocalAuthentication, DeskChannels.swift), and on Android that the app switcher and screenshots
/// show nothing of the app while a PIN is set. Windows and Linux have neither: the PIN alone.
class AppLockPlatform {
  const AppLockPlatform();

  static const _phone = MethodChannel('ghost_messaging/sms');
  static const _system = MethodChannel('ghost_desktop/system');

  MethodChannel? get _channel => kIsWeb ? null : PlatformInfo.isAndroid ? _phone : (PlatformInfo.isMacOS || PlatformInfo.isIOS) ? _system : null;

  Future<bool> canBiometric() async {
    try {
      return await _channel?.invokeMethod<bool>('lockBioCan') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> askBiometric(String reason) async {
    try {
      return await _channel?.invokeMethod<bool>('lockBioAsk', {'reason': reason}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android's FLAG_SECURE on the app's window, [on] while a PIN is set.
  Future<void> secure(bool on) async {
    if (kIsWeb || !PlatformInfo.isAndroid) return;
    try {
      await _phone.invokeMethod<void>('lockSecure', {'on': on});
    } catch (_) {}
  }
}
