import '../desktop/linux_dialogs.dart';
import 'dart:async';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../desktop/platform.dart' show MacPlatform;
import 'browser_files.dart';
import '../sms.dart';

/// A file picked to go up: where it is on this device, and whether it is a copy the app made (a phone's), which goes
/// once it is up.
typedef PickedFile = ({String path, bool owned});

/// What a Files space asks of the device itself (Matt, 2026-11-17: "add full functionality for filesharing in a space"):
/// choosing files, saving one where the person says, sharing one to another app, opening one, files dropped on the
/// window, and files shared in from other apps.
///
/// - Android (android/.../MainActivity.kt): Android's own picker for any file, each copied into the app's folder
///   (`keepFile`) since the picker's permission ends with the app; "Save to" (`saveFile`); the share sheet
///   (`shareFile`); and files shared from other apps (`sharedFiles` and the `sharedFiles` event).
/// - Mac (macos/Runner/DeskChannels.swift, MainFlutterWindow.swift): the Open and Save panels for any file, the share
///   menu, and files dragged onto the window while a Files space is showing.
/// - Windows (windows/runner/clipboard.cpp): its Open dialog for any file or pictures, and a save into Downloads.
class FilePlatform {
  FilePlatform._();

  static const _system = MethodChannel('ghost_desktop/system');
  static const _drop = MethodChannel('ghost_desktop/drop');

  /// Whether this is a computer's app, or the Android phone's: never a browser, which has neither's channels.
  static bool get _desktop => !kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);
  static bool get _phone => !kIsWeb && PlatformInfo.isAndroid;

  /// A page in a browser whose build has Files spaces (Sms.browserFiles): it picks, takes drops and saves through
  /// lib/files/browser_files.dart, with files that are no paths.
  static bool get _browser => kIsWeb && Sms.browserFiles;

  /// Whether this device can choose files at all.
  static bool get canPick => _phone || _desktop || _browser;

  /// Whether files can be dragged onto the window here.
  static bool get canDrop => (!kIsWeb && PlatformInfo.isMacOS) || _browser;

  /// Whether a file can be opened in another app from here: not in a browser, where it would be opened in a tab of
  /// the app's own address (docs/OPEN_NETWORK.md, part 6).
  static bool get canOpen => !kIsWeb;

  /// Files chosen with the device's own picker; none where it was put away.
  static Future<List<PickedFile>> pick() async {
    if (_phone) {
      final out = <PickedFile>[];
      for (final uri in await Sms.instance.pickFiles()) {
        out.add((path: (await Sms.instance.keepFile(uri)).path, owned: true));
      }
      return out;
    }
    return [for (final p in await pickPaths()) (path: p, owned: false)];
  }

  /// A computer's own panel for any file: the paths chosen. Also what a Telegram chat's + uses on a computer
  /// (lib/desktop/remote.dart).
  static Future<List<String>> pickPaths({int most = 50}) async {
    // Linux: the desktop's own chooser (lib/desktop/linux_dialogs.dart).
    if (!kIsWeb && PlatformInfo.isLinux) return linuxPick(most: most);
    try {
      return [for (final p in (await _system.invokeMethod<List>('pickFiles', {'most': most})) ?? const []) '$p'];
    } on MissingPluginException {
      // A desktop build without the any-file panel: its picture panel.
      return MacPlatform.pickPictures(most: most);
    } catch (_) {
      return const [];
    }
  }

  /// Copies a content address another app shared in to a file of the app's own: its path.
  static Future<String?> keep(String uri) async {
    try {
      return (await Sms.instance.keepFile(uri)).path;
    } catch (_) {
      return null;
    }
  }

  /// Whether a file can be saved out of the app here (an iPhone's Files export is not built yet).
  static bool get canSave => _phone || _desktop || _browser;

  /// Saves the file at [path] where the person says, under [name]: where it went in words, or null where it was not
  /// saved.
  static Future<String?> save(String path, String name, String mime) async {
    if (!canSave) return null;
    // A browser: what came down is held in the tab under [path], and saved to the browser's downloads from there.
    if (_browser) {
      BrowserFiles.save(path, name);
      return 'Saved to your downloads';
    }
    if (_phone) return await Sms.instance.saveFile(path, name, mime) ? 'Saved' : null;
    if (!kIsWeb && PlatformInfo.isMacOS) {
      final to = await _system.invokeMethod<String>('saveFile', {'name': name});
      if (to == null) return null;
      await File(path).copy(to);
      return 'Saved to ${to.split('/').reversed.skip(1).firstOrNull ?? 'your Mac'}';
    }
    // Elsewhere: into Downloads, under a name not already taken.
    final home = PlatformInfo.environment['USERPROFILE'] ?? PlatformInfo.environment['HOME'] ?? Directory.systemTemp.path;
    final dir = Directory('$home${PlatformInfo.pathSeparator}Downloads')..createSync(recursive: true);
    var target = File('${dir.path}${PlatformInfo.pathSeparator}$name');
    final dot = name.lastIndexOf('.');
    for (var n = 2; target.existsSync(); n++) {
      target = File('${dir.path}${PlatformInfo.pathSeparator}${dot > 0 ? '${name.substring(0, dot)} ($n)${name.substring(dot)}' : '$name ($n)'}');
    }
    await File(path).copy(target.path);
    return 'Saved to Downloads';
  }

  /// Whether this device can share a file to another app.
  static bool get canShare => _phone || (!kIsWeb && PlatformInfo.isMacOS);

  /// Hands the file at [path] to the system to share with another app: on Android and a Mac, nothing elsewhere.
  static Future<void> share(String path, String name, String mime) async {
    if (_phone) return Sms.instance.shareFile(path, name, mime);
    if (!kIsWeb && PlatformInfo.isMacOS) await _system.invokeMethod('shareFile', {'path': path});
  }

  /// Endings that run something when opened, rather than show something: a file another member added with one of these
  /// is never opened from here (it was written by this app, so neither Gatekeeper nor SmartScreen would stop it). It
  /// can be shown in its folder, with a warning, and saved.
  static const _runs = {
    // macOS
    'app', 'command', 'terminal', 'tool', 'webloc', 'fileloc', 'inetloc', 'jar', 'pkg', 'mpkg', 'workflow', 'scpt', 'scptd', 'applescript', 'action', 'dmg', 'kext', 'prefpane', 'mobileconfig',
    // Windows
    'exe', 'com', 'bat', 'cmd', 'lnk', 'url', 'hta', 'js', 'jse', 'vbs', 'vbe', 'wsf', 'wsh', 'ps1', 'psm1', 'scr', 'cpl', 'msi', 'msp', 'msc', 'reg', 'pif', 'appref-ms', 'gadget', 'chm', 'iso', 'img', 'vhd', 'vhdx',
    // Linux, and anything with a script's ending
    'sh', 'bash', 'zsh', 'csh', 'ksh', 'desktop', 'run', 'bin', 'appimage', 'deb', 'rpm', 'py', 'pl', 'rb',
    // Android
    'apk', 'xapk', 'apks', 'apkm',
  };

  /// Whether a file named [name] runs something when opened ([_runs]): offered as Show in its folder, never Open.
  static bool runsCode(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 && _runs.contains(name.substring(dot + 1).toLowerCase());
  }

  /// Opens the file at [path] in whichever app reads its kind; never one that runs something ([runsCode]).
  static Future<void> open(String path, String name) async {
    if (runsCode(name) || !canOpen) return;
    if (_phone) return Sms.instance.openFile(path, name: name);
    if (!kIsWeb && PlatformInfo.isWindows) {
      await Process.run('explorer', [path]);
    } else if (!kIsWeb && PlatformInfo.isLinux) {
      await Process.run('xdg-open', [path]);
    } else {
      await Process.run('open', [path]);
    }
  }

  /// Shows the file at [path] in the Finder (a computer only).
  static Future<void> reveal(String path) async {
    if (!kIsWeb && PlatformInfo.isMacOS) await Process.run('open', ['-R', path]);
  }

  // --- files dropped on the window -----------------------------------------------------------------------------------

  /// True while files are dragged over the window, with a Files space showing.
  static final ValueNotifier<bool> over = ValueNotifier(false);
  static final _dropped = StreamController<List<String>>.broadcast();
  static int _targets = 0;
  static bool _listening = false;

  /// The paths of files dropped on the window while a Files space is showing.
  static Stream<List<String>> get dropped => _dropped.stream;

  /// A Files space on the screen says it takes drops ([on]), and stops when it goes.
  static void dropTarget(bool on) {
    if (!canDrop) return;
    if (!_listening) {
      _listening = true;
      _drop.setMethodCallHandler((call) async {
        final args = (call.arguments as Map?) ?? const {};
        if (call.method == 'over') over.value = args['on'] == true;
        if (call.method == 'dropped') _dropped.add([for (final p in (args['paths'] as List? ?? const [])) '$p']);
        return null;
      });
    }
    _targets = (_targets + (on ? 1 : -1)).clamp(0, 1 << 20);
    unawaited(_drop.invokeMethod('target', {'on': _targets > 0}).catchError((_) => null));
  }

  // --- files shared in from other apps (Android) ---------------------------------------------------------------------

  /// Files another app shared in: their content addresses, as they come and (once, at start) any that came before.
  static Stream<List<String>> sharedIn() async* {
    if (!_phone) return;
    try {
      final before = await Sms.instance.sharedFiles();
      if (before.isNotEmpty) yield before;
    } catch (_) {}
    yield* Sms.instance.sharedIn.stream;
  }
}
