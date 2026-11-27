import 'dart:io';

import 'package:flutter/foundation.dart' show kProfileMode, kReleaseMode;
import 'package:flutter/services.dart' show MethodChannel;

import '../platform_info.dart';
import 'forward_secrecy.dart' show FsStore;
import 'kept_paths.dart';

/// Where there are files (kept_files.dart): the folder [name] is kept in on this device, out of any backup and this
/// build's own ([keptPathFor]); null where none can be named. Android and the Apple platforms are asked for theirs:
/// the app's no-backup folder (MainActivity.kt, Context.getNoBackupFilesDir), and its Caches folder
/// (ios/Runner/DeskChannels.swift; on a Mac, under its bundle id: macos/Runner/DeskChannels.swift).
Future<Directory?> keptDir(String name) async {
  try {
    final os = PlatformInfo.isAndroid
        ? 'android'
        : PlatformInfo.isIOS
            ? 'ios'
            : PlatformInfo.isMacOS
                ? 'macos'
                : PlatformInfo.isWindows
                    ? 'windows'
                    : PlatformInfo.isLinux
                        ? 'linux'
                        : '';
    final base = switch (os) {
      'android' => await const MethodChannel('ghost_messaging/sms').invokeMethod<String>('keptDir'),
      'ios' || 'macos' => await const MethodChannel('ghost_desktop/system').invokeMethod<String>('keptDir'),
      _ => null,
    };
    final path = keptPathFor(name, os: os, base: base, env: PlatformInfo.environment, mode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'));
    return path == null ? null : Directory(path);
  } catch (_) {
    return null;
  }
}

/// The ledger's store on this device: a file for each name in [keptDir], the folder asked for as the store is made and
/// waited for by each read and write. Where none can be named, nothing is read or kept.
FsStore? ledgerFiles() => FilesFsStore.later(keptDir('ledger'));

/// Where which route each person was last on is kept (routes_kept.dart): a folder of its own beside the ledger's, out
/// of any backup as it is.
FsStore? routesFiles() => FilesFsStore.later(keptDir('routes'));

/// What is kept, a file for each name in a folder: written whole each time (to a file beside it, then moved over it, so a
/// write cut short leaves the one before), and gone when written empty. Writes go one after another, and a read waits
/// for those asked before it, so two at once never write the same file together (the second review, N5).
class FilesFsStore implements FsStore {
  FilesFsStore(Directory dir) : _dir = Future.value(dir);

  /// A folder found later ([keptDir]): null for none, and then nothing is read or kept.
  FilesFsStore.later(Future<Directory?> dir) : _dir = dir;

  final Future<Directory?> _dir;

  /// The folder, once found.
  Future<Directory?> get dir => _dir;

  /// The end of the line the writes wait in; and a number for each write's file beside its own, never the same twice in
  /// this process, whichever store writes it.
  Future<void> _last = Future.value();
  static int _writes = 0;

  /// The file [name] is kept in: only letters, digits, dots, dashes and underscores, and never a name of dots alone, so a
  /// name is never a path out of [dir].
  static File _file(Directory dir, String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return File('${dir.path}${PlatformInfo.pathSeparator}${RegExp(r'^\.*$').hasMatch(safe) ? '_$safe' : safe}');
  }

  @override
  Future<String?> read(String name) async {
    await _last;
    final d = await _dir;
    if (d == null) return null;
    final f = _file(d, name);
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> write(String name, String value) {
    final run = _last.then((_) => _write(name, value));
    // One that fails stops none after it.
    _last = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// One write, in its turn: an empty [value] deletes the file.
  Future<void> _write(String name, String value) async {
    final d = await _dir;
    if (d == null) return;
    final f = _file(d, name);
    if (value.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await d.create(recursive: true);
    final next = File('${f.path}.${_writes++}.next');
    await next.writeAsString(value, flush: true);
    await next.rename(f.path);
  }
}
