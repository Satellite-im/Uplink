import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'link/link.dart';
import 'platform.dart';

/// Where the Mac keeps what it must between runs: the pairing (who the phone is, how the two connect, and the
/// pairing's key) and the person's choices (the theme, the relay's address). What was read from the phone is kept
/// apart, sealed with a key made from the pairing's (cache.dart; docs/desktop.md, "What the Mac keeps").
///
/// The key is kept in the Keychain. Where the Keychain will not take it (a build signed to run on this Mac alone
/// loses its Keychain items' trust with every rebuild, and macOS would ask for the password each time), it is kept
/// in the app's own folder, in a file only the person's account can read: [keychain] false.
class DeskStore implements LinkStore {
  DeskStore(this.dir, {this.keychain = true});

  final Directory dir;
  final bool keychain;

  /// The name the pairing's key is kept under in the Keychain.
  static const _account = 'pairing-key';

  /// The app's own folder: inside its sandbox container on a Mac, the person's AppData on Windows.
  static Directory defaultDir() {
    final appData = PlatformInfo.environment['APPDATA'];
    if (PlatformInfo.isWindows && appData != null) return Directory('$appData\\Ghost Messaging');
    // iOS gives a Flutter app no HOME: the container is the parent of its tmp folder.
    final home = PlatformInfo.environment['HOME'] ?? (PlatformInfo.isIOS ? Directory.systemTemp.parent.path : Directory.systemTemp.path);
    return Directory('$home/Library/Application Support/Ghost Messaging');
  }

  /// The two files: the paired phone, and this computer's choices.
  File get _pairing => File('${dir.path}/pairing.json');
  File get _prefs => File('${dir.path}/prefs.json');

  /// The write before the next one, and how many there have been: each temporary file has a name of its own.
  Future<void> _last = Future.value();
  int _writes = 0;

  /// Written whole to a file beside it and moved into place, one write after another: two choices changed at once
  /// are two writes, and the later is what is kept.
  Future<void> _write(File file, Object value, {bool private = false}) {
    final text = jsonEncode(value);
    return _last = _last.catchError((_) {}).then((_) async {
      await dir.create(recursive: true);
      final tmp = File('${file.path}.${_writes++}.tmp');
      await tmp.writeAsString(text, flush: true);
      // The person's account alone: the pairing's key may be in it. The folder is closed to everyone else once
      // ([_private]); the pairing's own file is closed too. The choices' file, written often, starts no program.
      await _private();
      if (private) {
        try {
          await Process.run('/bin/chmod', ['600', tmp.path]);
        } catch (_) {}
      }
      await tmp.rename(file.path);
    });
  }

  /// The app's folder is the person's alone (`chmod 700`), asked once a run: nothing in it can be read by another
  /// account whatever each file's own mode. Windows has no chmod; its AppData is the person's already.
  Future<void>? _closed;
  Future<void> _private() => _closed ??= () async {
        if (PlatformInfo.isWindows) return;
        try {
          await Process.run('/bin/chmod', ['700', dir.path]);
        } catch (_) {}
      }();

  /// The choices are written at most once in [_prefsEvery]: several changed together (a screen's worth, a store's
  /// bookkeeping) are one write of the newest, where each was the whole file written and a program started
  /// (docs/performance-audit.md). Every caller's future ends when a write holding its choices has.
  static const _prefsEvery = Duration(milliseconds: 200);
  Map<String, String>? _prefsNext;
  Future<void>? _prefsGoing;

  @override
  Future<PairedPhone?> load() async {
    try {
      if (!await _pairing.exists()) return null;
      final o = jsonDecode(await _pairing.readAsString()) as Map<String, dynamic>;
      final key = (o['key'] as String?) ?? (keychain ? await MacPlatform.keyRead(_account) : null);
      if (key == null) return null;
      return PairedPhone(
        id: o['id'] as String,
        name: (o['name'] as String?) ?? 'Your phone',
        key: base64.decode(key),
        mode: (o['mode'] as String?) ?? 'both',
        relay: (o['relay'] as String?) ?? '',
        since: DateTime.fromMillisecondsSinceEpoch((o['since'] as num?)?.toInt() ?? 0),
        host: o['host'] as String?,
        port: (o['port'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(PairedPhone p) async {
    final key = base64.encode(p.key);
    final kept = keychain && await MacPlatform.keyWrite(_account, key);
    await _write(_pairing, {
      'id': p.id, 'name': p.name, 'mode': p.mode, 'relay': p.relay, 'since': p.since.millisecondsSinceEpoch, 'host': p.host, 'port': p.port,
      // In the file only where the Keychain did not take it.
      if (!kept) 'key': key,
    }, private: true);
  }

  @override
  Future<void> clear() async {
    if (keychain) await MacPlatform.keyDelete(_account);
    try {
      if (await _pairing.exists()) await _pairing.delete();
    } catch (_) {}
  }

  /// The person's choices on this Mac, by name.
  Future<Map<String, String>> prefs() async {
    // The choices waiting to be written are the choices: read before their write, they are not the file's older ones.
    final waiting = _prefsNext;
    if (waiting != null) return Map.of(waiting);
    try {
      if (!await _prefs.exists()) return {};
      return {for (final e in (jsonDecode(await _prefs.readAsString()) as Map).entries) '${e.key}': '${e.value}'};
    } catch (_) {
      return {};
    }
  }

  /// Keeps the choices, all of them: the newest map given is what the next write holds.
  Future<void> savePrefs(Map<String, String> prefs) {
    _prefsNext = Map.of(prefs);
    return _prefsGoing ??= Future<void>.delayed(_prefsEvery).then((_) {
      final next = _prefsNext!;
      _prefsNext = null;
      _prefsGoing = null;
      return _write(_prefs, next);
    });
  }
}
