import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'linux_voice.dart' show findProgram;

/// The Mac app's own updates, so a copy that is installed is never installed again by hand (Matt, 2026-11-13:
/// "install the app on my mac and make sure it has OTA updates so we don't need to reinstall again").
///
/// - **What it reads** is `https://gogho.st/mac.json`, which tool/release-mac.mjs puts beside the phone app's
///   `apk.json`: `{ version, versionCode, sha256, bytes, url }`, the url being the zip of the app beside it. A newer
///   one is one whose `versionCode` (the app's `CFBundleVersion`) is above this app's.
/// - **What it does** is download that zip into the app's own cache and hand it to the Mac's half
///   (macos/Runner/UpdatesChannel.swift), which holds it to the size and SHA-256 the description gives, unpacks it
///   beside the running app, and checks what came out is this app, newer, and signed by this app's own team. That
///   last check is what makes an update believed: nothing the server or the network says can stand in for Matt's
///   Developer ID.
/// - **When it is in place** the app says so ([MacUpdatePhase.ready]): Restart to update swaps it in and opens it,
///   and so does quitting the app, so the next launch is the new version either way.
/// - **Looked for** as the app opens and every six hours after, and from Settings when asked.
///
/// `GHOST_DESK_UPDATES` names another address to read (a local server, to walk an update through: the Mac's half
/// believes only what this app's team signed, wherever it came from), and `off` looks nowhere. With
/// `GHOST_DESK_UPDATE_RESTART=now` the app restarts into an update as soon as one is in place, so the whole of it
/// can be walked through with no hand on the app (docs/desktop.md, "Updating itself").

/// Where an installed Mac app reads of a newer one.
const macFeed = 'https://gogho.st/mac.json';

/// Where an installed Windows app reads of a newer one: tool/release-windows.mjs's description of the installer
/// beside it (Matt, 2026-11-15: "also we need an auto updated for windows").
const windowsFeed = 'https://gogho.st/windows.json';

/// The build number a Windows build was made with (`--dart-define=GHOST_BUILD=…` in
/// .github/workflows/messaging-windows.yml); 0 for a build made any other way, which never updates itself.
const windowsBuild = int.fromEnvironment('GHOST_BUILD');

/// Where an installed Linux app reads of a newer one: tool/release-linux.mjs's linux.json (GMFB-32, from the Uplink gap
/// review: "Linux auto-update"). It describes the .deb at its top and the folder's .tar.gz under `tar`; which one this
/// copy takes is [LinuxUpdateHost.part]'s to say. The workflow builds with the same `GHOST_BUILD` as Windows'.
const linuxFeed = 'https://gogho.st/linux.json';

/// A release, as its description gives it.
class MacRelease {
  const MacRelease({required this.version, required this.build, required this.sha256, required this.bytes, required this.url});
  final String version;

  /// The app's `CFBundleVersion`: what newer is asked of.
  final int build;

  /// What the download must be to be taken: its SHA-256, in lower-case hex, and its size.
  final String sha256;
  final int bytes;
  final Uri url;

  /// The least and the most a zip of this app could be: a description outside them is not one.
  static const smallest = 1 << 20;
  static const largest = 500 << 20;

  /// Reads a description read from [feed]; null where it is not one: a field missing or of the wrong kind, a size
  /// no app is, or a zip somewhere other than beside the description. With [part] the file is the one described under
  /// that key (linux.json's `tar`: `{url, bytes, sha256}`), the version still the description's own.
  static MacRelease? parse(String text, Uri feed, {String? part}) {
    final Object? said;
    try {
      said = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (said is! Map) return null;
    final file = part == null ? said : said[part];
    if (file is! Map) return null;
    final version = said['version'], build = said['versionCode'], sha256 = file['sha256'], bytes = file['bytes'], url = file['url'];
    if (version is! String || !RegExp(r'^\d+(\.\d+){1,3}$').hasMatch(version)) return null;
    if (build is! int || build <= 0) return null;
    if (sha256 is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) return null;
    if (bytes is! int || bytes < smallest || bytes > largest) return null;
    if (url is! String || url.isEmpty) return null;
    final Uri at;
    try {
      at = feed.resolve(url);
    } catch (_) {
      return null;
    }
    // The zip is beside its description: the same server, spoken to the same way.
    if (at.scheme != feed.scheme || at.host != feed.host || at.port != feed.port) return null;
    return MacRelease(version: version, build: build, sha256: sha256.toLowerCase(), bytes: bytes, url: at);
  }
}

/// The app as it is installed (UpdatesChannel.swift `installed`).
class InstalledMac {
  const InstalledMac({required this.version, required this.build, required this.dir, this.updated = false});
  final String version;
  final int build;

  /// Where a download is kept for the Mac's half to unpack.
  final String dir;

  /// This launch is the first of a version the app put in place itself.
  final bool updated;
}

/// The Mac's half (macos/Runner/UpdatesChannel.swift), or a test's own.
abstract class UpdateHost {
  /// The installed app, or null where there is no Mac half: then nothing is looked for.
  Future<InstalledMac?> installed();

  /// Hands over the downloaded zip: `ready` once it is unpacked and checked beside the app, `manual: <why>` where
  /// this copy cannot replace itself, or a reason it was refused.
  Future<String> install(String path, {required String sha256, required int bytes});

  /// Swaps the version in place for the running one and opens it: `restarting`, or why not.
  Future<String> restart();
}

/// The Mac's half, asked over its method channel. Where there is none (a test, another platform) nothing is
/// installed, so nothing is looked for.
class ChannelUpdateHost implements UpdateHost {
  const ChannelUpdateHost();
  static const _channel = MethodChannel('ghost_desktop/updates');

  @override
  Future<InstalledMac?> installed() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('installed');
      if (m == null) return null;
      return InstalledMac(
        version: (m['version'] as String?) ?? '',
        build: (m['versionCode'] as num?)?.toInt() ?? 0,
        dir: (m['dir'] as String?) ?? '',
        updated: m['updated'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String> install(String path, {required String sha256, required int bytes}) async {
    try {
      return await _channel.invokeMethod<String>('install', {'path': path, 'sha256': sha256, 'bytes': bytes}) ?? 'no answer';
    } on MissingPluginException {
      return 'no installer';
    }
  }

  @override
  Future<String> restart() async {
    try {
      return await _channel.invokeMethod<String>('restart') ?? 'no answer';
    } on MissingPluginException {
      return 'no installer';
    }
  }
}

/// Where the app's own update stands.
enum MacUpdatePhase {
  /// Nothing newer, as far as is known.
  idle,
  checking,
  downloading,

  /// The new version is in place beside this one: a restart, or a quit, swaps it in.
  ready,
  restarting,

  /// There is a newer one and this copy cannot replace itself ([MacUpdates.problem] says why).
  manual,

  /// Looking, downloading or putting it in place did not work ([MacUpdates.problem]); it is tried again later.
  failed,
}

/// Looks for a newer Mac app, brings it down and has it put in place (the header).
class MacUpdates extends ChangeNotifier {
  MacUpdates({Uri? feed, UpdateHost? host, HttpClient Function()? client, this.every = const Duration(hours: 6), this.restartWhenReady = false, this.part})
      : feed = feed ?? Uri.parse(macFeed),
        _host = host ?? const ChannelUpdateHost(),
        _client = client ?? HttpClient.new;

  /// As it would stand with [installed] and a newer [release] at [phase]: for a picture of what the app says of it.
  @visibleForTesting
  MacUpdates.standing({required InstalledMac installed, required MacUpdatePhase phase, MacRelease? release, String? problem, UpdateHost? host})
      : feed = Uri.parse(macFeed),
        every = const Duration(hours: 6),
        restartWhenReady = false,
        part = null,
        _host = host ?? const ChannelUpdateHost(),
        _client = HttpClient.new {
    _installed = installed;
    _phase = phase;
    _release = release;
    _problem = problem;
    _checked = DateTime.now();
    _standing = true;
  }

  /// Made to stand as it is, for a picture: it looks nowhere.
  bool _standing = false;

  /// The updater for this run of the app: where `GHOST_DESK_UPDATES` says to look, or nowhere for `off`.
  /// On Windows it reads [windowsFeed] and runs the installer it brings ([WindowsUpdateHost]); on Linux [linuxFeed],
  /// the folder swapped in or the .deb's command given ([LinuxUpdateHost]). [linuxHost] stands in for a test.
  static MacUpdates? fromEnvironment(Map<String, String> env, {bool windows = false, bool linux = false, LinuxUpdateHost? linuxHost}) {
    final said = (env['GHOST_DESK_UPDATES'] ?? '').trim();
    if (said == 'off') return null;
    final given = said.isEmpty ? null : Uri.tryParse(said);
    final feed = given != null && given.hasScheme && given.host.isNotEmpty
        ? given
        : windows
            ? Uri.parse(windowsFeed)
            : linux
                ? Uri.parse(linuxFeed)
                : null;
    final lin = linux ? (linuxHost ?? LinuxUpdateHost(env: env)) : null;
    return MacUpdates(
      feed: feed,
      host: windows ? WindowsUpdateHost(env: env) : lin,
      restartWhenReady: env['GHOST_DESK_UPDATE_RESTART'] == 'now',
      part: lin?.part,
    );
  }

  /// Where the newest release's description is read from, and how often it is read again.
  final Uri feed;

  /// Which file of the description this copy takes, where it describes more than one (linux.json's `tar`); null for
  /// the one at its top.
  final String? part;

  /// The command that installs the update this copy brought down and can't put in place itself (a .deb, which
  /// needs root), for Settings to offer to copy; null otherwise.
  String? get installCommand => _phase == MacUpdatePhase.manual && _host is LinuxUpdateHost ? _host.command : null;

  /// Whether putting the update in place will have the computer ask for an administrator's password (Linux from the
  /// .deb, installed through polkit: [LinuxUpdateHost.asksPassword]), for Settings to say so on the button.
  bool get asksPassword => _phase == MacUpdatePhase.ready && _host is LinuxUpdateHost && _host.asksPassword;
  final Duration every;

  /// Restart into an update as soon as it is in place, with nobody asked (`GHOST_DESK_UPDATE_RESTART=now`).
  final bool restartWhenReady;
  final UpdateHost _host;
  final HttpClient Function() _client;
  Timer? _timer;

  /// A look is under way: another asked for meanwhile does nothing.
  bool _busy = false;

  InstalledMac? get installed => _installed;
  InstalledMac? _installed;
  MacUpdatePhase get phase => _phase;
  MacUpdatePhase _phase = MacUpdatePhase.idle;

  /// The newer version found, once one is.
  MacRelease? get release => _release;
  MacRelease? _release;

  /// How much of the download is here, 0 to 1.
  double get progress => _progress;
  double _progress = 0;

  /// Why it did not work, or why this copy cannot replace itself.
  String? get problem => _problem;
  String? _problem;

  /// When the release's description was last read.
  DateTime? get checked => _checked;
  DateTime? _checked;

  /// Asks the Mac what is installed, looks once, and goes on looking.
  Future<void> start() async {
    _installed = await _host.installed();
    if (_installed == null) return;
    notifyListeners();
    unawaited(check());
    _timer = Timer.periodic(every, (_) => check());
  }

  /// As [start], with the first look waited for: the launch splash waits on it (lib/desktop/ui/launch_splash.dart),
  /// and on the download where it finds one.
  Future<void> startChecking() async {
    _installed = await _host.installed();
    if (_installed == null) return;
    notifyListeners();
    _timer = Timer.periodic(every, (_) => check());
    await check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Moves to [phase] and tells the listeners; the last problem is forgotten unless a new one is given.
  void _set(MacUpdatePhase phase, {String? problem}) {
    _phase = phase;
    _problem = problem;
    notifyListeners();
  }

  /// Looks for a newer version and, where there is one, brings it down and has it put in place.
  Future<void> check() async {
    final here = _installed;
    if (here == null || _busy || _standing) return;
    // One in place is not looked past, and one this copy cannot take is not fetched again each time.
    if (_phase == MacUpdatePhase.ready || _phase == MacUpdatePhase.restarting || _phase == MacUpdatePhase.manual) return;
    _busy = true;
    _set(MacUpdatePhase.checking);
    try {
      final found = await _read();
      _checked = DateTime.now();
      if (found == null || found.build <= here.build) {
        _release = null;
        _set(MacUpdatePhase.idle);
        return;
      }
      _release = found;
      _progress = 0;
      _set(MacUpdatePhase.downloading);
      final zip = await _fetch(found, here);
      final answer = await _host.install(zip.path, sha256: found.sha256, bytes: found.bytes);
      if (answer == 'ready') {
        _set(MacUpdatePhase.ready);
        // Never where that asks for a password, which only a press may bring up.
        if (restartWhenReady && !asksPassword) unawaited(restart());
      } else if (answer.startsWith('manual: ')) {
        _set(MacUpdatePhase.manual, problem: answer.substring('manual: '.length));
      } else {
        _set(MacUpdatePhase.failed, problem: answer);
      }
    } catch (e) {
      _set(MacUpdatePhase.failed, problem: e is UpdateProblem ? e.words : 'The update could not be reached ($e)');
    } finally {
      _busy = false;
    }
  }

  /// Restart to update: the version in place is swapped in and opened.
  Future<void> restart() async {
    if (_phase != MacUpdatePhase.ready) return;
    _set(MacUpdatePhase.restarting);
    final answer = await _host.restart();
    if (answer == 'restarting') return;
    // Linux from the .deb, where the password wasn't given or there was nothing to ask for it: the command instead.
    if (answer.startsWith('manual: ')) {
      _set(MacUpdatePhase.manual, problem: answer.substring('manual: '.length));
    } else {
      _set(MacUpdatePhase.failed, problem: answer);
    }
  }

  /// The release's description; null where nothing has been published there (the server has no such file).
  Future<MacRelease?> _read() async {
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    try {
      // Read afresh each time: a description an hour old would hide a release.
      final request = await client.getUrl(feed.replace(queryParameters: {...feed.queryParameters, 't': '${DateTime.now().millisecondsSinceEpoch}'})).timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode == 404) {
        await response.drain<void>();
        return null;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw UpdateProblem('${feed.host} answered ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 64 * 1024) throw const UpdateProblem('The release\'s description is too long to be one');
      }
      final found = MacRelease.parse(utf8.decode(bytes, allowMalformed: true), feed, part: part);
      if (found == null) throw const UpdateProblem('The release\'s description could not be read');
      return found;
    } finally {
      client.close(force: true);
    }
  }

  /// Brings the zip down into the app's own folder for it, which holds nothing else: what was there goes first.
  Future<File> _fetch(MacRelease release, InstalledMac here) async {
    final dir = Directory(here.dir);
    if (dir.existsSync()) {
      for (final old in dir.listSync()) {
        try {
          old.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    dir.createSync(recursive: true);
    // Named as published, with the build before the extension: ghost-messaging-mac-500.zip, …-setup-36.exe.
    final name = release.url.pathSegments.isEmpty || release.url.pathSegments.last.isEmpty ? 'update' : release.url.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final file = File('${dir.path}${PlatformInfo.pathSeparator}${dot > 0 ? '${name.substring(0, dot)}-${release.build}${name.substring(dot)}' : '$name-${release.build}'}');
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    IOSink? out;
    try {
      final request = await client.getUrl(release.url).timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw UpdateProblem('${release.url.host} answered ${response.statusCode} for the download');
      }
      out = file.openWrite();
      var got = 0, said = 0.0;
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        got += chunk.length;
        if (got > release.bytes) throw const UpdateProblem('The download is larger than the release says');
        out.add(chunk);
        _progress = got / release.bytes;
        if (_progress - said >= 0.01) {
          said = _progress;
          notifyListeners();
        }
      }
      await out.flush();
      await out.close();
      out = null;
      if (got != release.bytes) throw const UpdateProblem('The download stopped before it was whole');
      _progress = 1;
      notifyListeners();
      return file;
    } catch (_) {
      try {
        await out?.close();
      } catch (_) {}
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

/// Windows' half, in Dart alone: the installer is held to the size and SHA-256 its description gives, and Restart to
/// update runs it silently with /RELAUNCH (windows/installer.iss reopens the app then) and quits this copy.
///
/// The installer is not signed yet, so what makes it believed is weaker than the Mac's Developer ID check: it came
/// over HTTPS from gogho.st, beside a description from the same server, and matches that description.
///
/// Only a copy the installer put in place updates itself: one in the person's Programs folder, built with a build
/// number ([windowsBuild]). Any other (a build run from its folder) is never looked for.
class WindowsUpdateHost implements UpdateHost {
  WindowsUpdateHost({Map<String, String>? env, String? exe, int? build, String? version, this.launch = _launch, this.quit = _quit})
      : _env = env ?? PlatformInfo.environment,
        _exe = exe ?? PlatformInfo.resolvedExecutable,
        _build = build ?? windowsBuild,
        _version = version ?? const String.fromEnvironment('GHOST_VERSION');

  /// The environment, this app's own path, and the build and version it was made with: given by a test, else real.
  final Map<String, String> _env;
  final String _exe;
  final int _build;
  final String _version;

  /// Starts the installer at the path, detached; and ends this app.
  final Future<void> Function(String path) launch;
  final void Function() quit;

  /// The installer downloaded and checked, waiting for [restart] to run it.
  String? _installer;

  static Future<void> _launch(String path) async {
    await Process.start(path, const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/RELAUNCH'], mode: ProcessStartMode.detached);
  }

  static void _quit() => exit(0);

  /// Where the installer puts the app: `%LOCALAPPDATA%\Programs\Ghost Messaging` (the folder keeps the name the app
  /// had until 2026-11-27: an install is found there, windows/installer.iss).
  bool get _installedByInstaller {
    final local = _env['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return false;
    final home = '$local\\Programs\\Ghost Messaging\\'.toLowerCase();
    return _exe.toLowerCase().startsWith(home);
  }

  @override
  Future<InstalledMac?> installed() async {
    if (_build <= 0 || !_installedByInstaller) return null;
    final base = _env['LOCALAPPDATA']!;
    return InstalledMac(version: _version, build: _build, dir: '$base\\Ghost Messaging\\updates');
  }

  @override
  Future<String> install(String path, {required String sha256, required int bytes}) async {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() != bytes) return 'The installer is not the size the release says';
    if (await fileSha256(file) != sha256.toLowerCase()) {
      try {
        file.deleteSync();
      } catch (_) {}
      return 'The installer is not the one the release describes';
    }
    _installer = path;
    return 'ready';
  }

  @override
  Future<String> restart() async {
    final path = _installer;
    if (path == null || !File(path).existsSync()) return 'The installer is gone; it is fetched again later';
    try {
      await launch(path);
    } catch (e) {
      return 'The installer would not start ($e)';
    }
    quit();
    return 'restarting';
  }
}

/// A file's SHA-256, in lower-case hex, read a piece at a time.
Future<String> fileSha256(File file) async {
  final digest = SHA256Digest();
  final out = Uint8List(digest.digestSize);
  await for (final chunk in file.openRead()) {
    final b = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    digest.update(b, 0, b.length);
  }
  digest.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// How this Linux copy was put on the computer, which decides how it updates (GMFB-32).
enum LinuxInstall {
  /// From the .deb: the app's folder is /opt/ghost-messaging, root's. The new .deb is brought down and checked, and
  /// installed with the desktop's own password prompt (polkit's pkexec); where there is none, or the password isn't
  /// given, the person is given the one command that installs it.
  deb,

  /// From the .tar.gz, unpacked where the person chose: the folder is theirs, so the new one is unpacked beside it
  /// and swapped in on Restart to update.
  folder,

  /// The .tar.gz unpacked somewhere this person can't write: the new one is pointed to, not put in place.
  readOnly,
}

/// Linux's half, in Dart alone (GMFB-32, from the Uplink gap review: "Linux auto-update"). The packages are not
/// signed, so what makes one believed is as on Windows: it came over HTTPS from gogho.st, beside a description from the
/// same server, and matches that description's size and SHA-256.
///
/// - **A folder** ([LinuxInstall.folder], the .tar.gz): the archive is unpacked beside the app's folder
///   (`.ghost-messaging-update`), checked to hold the app, and on Restart to update the running folder is moved aside
///   (`<folder>.old`, removed at the next start), the new one moved into its place and started, and this copy quits.
/// - **The .deb** ([LinuxInstall.deb]): brought down into `~/.cache/ghost-messaging/updates` and checked. Installing a
///   package is root's, so on Restart to update the desktop is asked to: `pkexec apt-get install -y <path>`
///   ([installAsRoot]), polkit's own window asking for the password, never this app; then the new copy is started and
///   this one quits, as on the Mac and Windows. Where there is no pkexec, the password isn't given or apt refuses, the
///   person is given `sudo apt install <path>` ([command]) to run in a terminal, as before there was this.
///
/// Only a copy made with a build number ([windowsBuild], the same `GHOST_BUILD` define) looks for updates: one run from
/// a build folder never does.
class LinuxUpdateHost implements UpdateHost {
  LinuxUpdateHost({Map<String, String>? env, String? exe, int? build, String? version, LinuxInstall? install, this.launch = _launch, this.quit = _quit, this.unpack = _unpack, String? Function()? pkexec, this.asRoot = _asRoot})
      : _findPkexec = pkexec,
        _env = env ?? PlatformInfo.environment,
        _exe = exe ?? PlatformInfo.resolvedExecutable,
        _build = build ?? windowsBuild,
        _version = version ?? const String.fromEnvironment('GHOST_VERSION') {
    kind = install ?? _kindOf(_exe);
  }

  // The environment, where the program runs from, and this copy's build number and version: a test gives its own.
  final Map<String, String> _env;
  final String _exe;
  final int _build;
  final String _version;

  /// How this copy was installed (from where it runs, unless a test says).
  late final LinuxInstall kind;

  /// Starts the app at the path, detached.
  final Future<void> Function(String exe) launch;

  /// Ends this copy, once the new one has been started.
  final void Function() quit;

  /// Unpacks the .tar.gz at [archive] into [into]: null, or why it couldn't.
  final Future<String?> Function(String archive, String into) unpack;

  /// Where the .deb installs the app.
  static const debFolder = '/opt/ghost-messaging';

  /// The folder the archive holds the app in (the workflow's `--transform 's,^bundle,ghost-messaging,'`), and its
  /// program.
  static const archiveFolder = 'ghost-messaging';
  static const program = 'ghost-messaging';

  /// The file of linux.json this copy takes: the folder's archive, or the .deb at the top.
  String? get part => kind == LinuxInstall.deb ? null : 'tar';

  /// For the .deb, once it is here and checked: the command that installs it.
  String? command;

  /// Runs [command] (pkexec and what it is to run as root) and answers how it ended: 0 for done, 126 where the
  /// password window was put away, 127 where nobody could be asked.
  final Future<int> Function(List<String> command) asRoot;

  /// Where polkit's pkexec is, which asks for an administrator's password in a window of the desktop's own; null
  /// where it isn't installed. Looked for along PATH once (a test says).
  late final String? pkexec = _findPkexec != null ? _findPkexec() : findProgram('pkexec', env: _env);
  final String? Function()? _findPkexec;

  /// The .deb waiting to be installed with a password, and the SHA-256 it was checked to have.
  String? _deb, _debSha;

  /// Whether Restart to update will have the desktop ask for a password: a .deb is here and pkexec is.
  bool get asksPassword => kind == LinuxInstall.deb && _deb != null;

  /// What installs the .deb at [deb] as root through [pkexec]: apt, by its whole path (pkexec gives what it runs a
  /// bare PATH), told yes to its one question.
  static List<String> installAsRoot(String pkexec, String deb) => [pkexec, '/usr/bin/apt-get', 'install', '-y', deb];

  static Future<int> _asRoot(List<String> command) async => (await Process.run(command.first, command.sublist(1))).exitCode;

  /// The new app's folder, unpacked and checked, waiting for Restart to update.
  String? _staged;

  /// The folder this copy runs from.
  String get _folder => File(_exe).parent.path;

  /// How the copy at [exe] was installed: the .deb's where it runs from [debFolder]; else a folder, the person's own
  /// where a file can be made beside it.
  static LinuxInstall _kindOf(String exe) {
    if (exe.startsWith('$debFolder/')) return LinuxInstall.deb;
    final folder = File(exe).parent;
    try {
      // Writable here and beside it: a file made and removed in the folder that holds the app's.
      final probe = File('${folder.parent.path}/.ghost-messaging-write-test-$pid');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return LinuxInstall.folder;
    } catch (_) {
      return LinuxInstall.readOnly;
    }
  }

  static Future<void> _launch(String exe) async {
    // Said to be the app opening itself again (GHOST_DESK_AGAIN, desk.dart startedAgain): this copy is still open as
    // the new one starts, which would otherwise only show this one's window and go (GMFB-47, linux/runner/main.cc).
    await Process.start(exe, const [], environment: const {'GHOST_DESK_AGAIN': '1'}, mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
  }

  static void _quit() => exit(0);

  static Future<String?> _unpack(String archive, String into) async {
    final r = await Process.run('tar', ['-xzf', archive, '-C', into]);
    return r.exitCode == 0 ? null : 'The update could not be unpacked (${'${r.stderr}'.trim()})';
  }

  /// `sudo apt install` for a .deb at [path], quoted for a shell.
  static String aptCommand(String path) => 'sudo apt install ${_quoted(path)}';

  /// [s] as one word of a shell command: as it is where plain, else in single quotes.
  static String _quoted(String s) => RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", "'\\''")}'";

  /// Where updates are brought down to: under the person's cache folder (XDG_CACHE_HOME, else ~/.cache).
  String get _cache {
    final xdg = _env['XDG_CACHE_HOME'];
    final base = xdg != null && xdg.isNotEmpty ? xdg : '${_env['HOME'] ?? Directory.systemTemp.path}/.cache';
    return '$base/ghost-messaging/updates';
  }

  @override
  Future<InstalledMac?> installed() async {
    if (_build <= 0) return null;
    // What the last swap moved aside: this copy runs from the new folder now.
    if (kind == LinuxInstall.folder) {
      try {
        final old = Directory('$_folder.old');
        if (old.existsSync()) old.deleteSync(recursive: true);
      } catch (_) {}
    }
    return InstalledMac(version: _version, build: _build, dir: _cache);
  }

  @override
  Future<String> install(String path, {required String sha256, required int bytes}) async {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() != bytes) return 'The download is not the size the release says';
    if (await fileSha256(file) != sha256.toLowerCase()) {
      try {
        file.deleteSync();
      } catch (_) {}
      return 'The download is not the one the release describes';
    }
    switch (kind) {
      case LinuxInstall.deb:
        command = aptCommand(path);
        // With pkexec it is ready as any other: Restart to update asks for the password and installs it ([restart]).
        if (pkexec != null) {
          _deb = path;
          _debSha = sha256.toLowerCase();
          return 'ready';
        }
        return 'manual: It came from the .deb, which only an administrator can replace. To install it, run $command in a terminal, then open Uplink again.';
      case LinuxInstall.readOnly:
        return 'manual: Its folder ($_folder) isn\'t yours to change. Download the new one from gogho.st and unpack it where you can write.';
      case LinuxInstall.folder:
        final stage = Directory('${File(_folder).parent.path}/.ghost-messaging-update');
        try {
          if (stage.existsSync()) stage.deleteSync(recursive: true);
          stage.createSync(recursive: true);
        } catch (e) {
          return 'There is no room beside the app to unpack the update ($e)';
        }
        final why = await unpack(path, stage.path);
        if (why != null) return why;
        final app = '${stage.path}/$archiveFolder';
        if (!File('$app/$program').existsSync()) {
          try {
            stage.deleteSync(recursive: true);
          } catch (_) {}
          return 'The update does not hold Uplink';
        }
        try {
          file.deleteSync();
        } catch (_) {}
        _staged = app;
        return 'ready';
    }
  }

  @override
  Future<String> restart() async {
    if (kind == LinuxInstall.deb) return _installDeb();
    final staged = _staged;
    if (staged == null || !Directory(staged).existsSync()) return 'The update is gone; it is fetched again later';
    final here = _folder;
    final aside = '$here.old';
    try {
      if (Directory(aside).existsSync()) Directory(aside).deleteSync(recursive: true);
      Directory(here).renameSync(aside);
    } catch (e) {
      return 'The app\'s folder could not be moved aside ($e)';
    }
    try {
      Directory(staged).renameSync(here);
    } catch (e) {
      // Put back as it was: the copy running now goes on from its own folder.
      try {
        Directory(aside).renameSync(here);
      } catch (_) {}
      return 'The new version could not be put in place ($e)';
    }
    try {
      Directory(File(staged).parent.path).deleteSync(recursive: true);
    } catch (_) {}
    _staged = null;
    try {
      await launch('$here/$program');
    } catch (e) {
      return 'The new version is in place but would not start ($e). Open Uplink again.';
    }
    quit();
    return 'restarting';
  }

  /// The .deb's Restart to update: installed as root through pkexec, whose window asks for the password, then the new
  /// copy started and this one ended. `manual: …` with the command to run in a terminal where that didn't happen.
  Future<String> _installDeb() async {
    final deb = _deb, tool = pkexec;
    if (deb == null || tool == null || !File(deb).existsSync()) return 'The update is gone; it is fetched again later';
    // Checked again: it has lain in a folder of the person's since it was, and is about to be installed as root.
    if (await fileSha256(File(deb)) != _debSha) {
      _deb = null;
      return 'The download is not the one the release describes';
    }
    int code;
    try {
      code = await asRoot(installAsRoot(tool, deb));
    } catch (_) {
      code = -1;
    }
    if (code != 0) {
      _deb = null;
      // 126 is pkexec's for a password window put away.
      final why = code == 126 ? 'The password wasn\'t given, so it isn\'t installed yet.' : 'It couldn\'t be installed from here.';
      return 'manual: $why To install it, run $command in a terminal, then open Uplink again.';
    }
    _deb = null;
    try {
      await launch('$debFolder/$program');
    } catch (e) {
      return 'The new version is installed but would not start ($e). Open Uplink again.';
    }
    quit();
    return 'restarting';
  }
}

/// Why an update did not come, in words for the person.
class UpdateProblem implements Exception {
  const UpdateProblem(this.words);
  final String words;

  @override
  String toString() => words;
}
