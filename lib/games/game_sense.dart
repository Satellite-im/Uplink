/// Which game is running on this computer (Matt, 2026-11-20: "what about game presence sensing like discord has?").
///
/// A Mac and Windows only: the list of running programs is read (`ps` on a Mac, PowerShell's process list on
/// Windows), and a program is a game where:
///
/// - it runs from a game library's folder, whose folder name is the game's: Steam (`steamapps/common/<Game>`), Epic,
///   GOG, Xbox, Riot, Ubisoft, EA;
/// - on a Mac, its app says it is one (`LSApplicationCategoryType` a games category in its Info.plist);
/// - it is one of a short list known by its program's name ([knownGames]), for games outside those folders;
/// - the person added it (Game activity's "Also games", a program's name a line).
///
/// Never a helper, a crash reporter or a launcher. Where several run, the one that started last. Nothing is sent
/// anywhere from here: what is found is the Game activity plugin's to share or not (lib/games/game_activity.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

/// Games known by their program's name (lower case, no `.exe` or `.app`), for those outside a library's folder.
const Map<String, String> knownGames = {
  'runelite': 'Old School RuneScape',
  'osclient': 'Old School RuneScape',
  'old school runescape': 'Old School RuneScape',
  'rs2client': 'RuneScape',
  'minecraft': 'Minecraft',
  'minecraft.windows': 'Minecraft',
  'minecraftlauncher': 'Minecraft',
  'leagueclient': 'League of Legends',
  'league of legends': 'League of Legends',
  'valorant-win64-shipping': 'VALORANT',
  'fortniteclient-win64-shipping': 'Fortnite',
  'robloxplayerbeta': 'Roblox',
  'roblox': 'Roblox',
  'overwatch': 'Overwatch 2',
  'wow': 'World of Warcraft',
  'world of warcraft': 'World of Warcraft',
  'diablo iv': 'Diablo IV',
  'hearthstone': 'Hearthstone',
  'genshinimpact': 'Genshin Impact',
  'starrail': 'Honkai: Star Rail',
  'ffxiv_dx11': 'Final Fantasy XIV',
  'gta5': 'Grand Theft Auto V',
  'rocketleague': 'Rocket League',
  'eldenring': 'Elden Ring',
  'pathofexile': 'Path of Exile',
  'pathofexile_x64': 'Path of Exile',
  'osu!': 'osu!',
  'factorio': 'Factorio',
  'dwarf fortress': 'Dwarf Fortress',
};

/// Folders whose next folder is a game's name, lower case with forward slashes.
const List<String> _libraries = [
  '/steamapps/common/',
  '/epic games/',
  '/gog games/',
  '/gog galaxy/games/',
  '/xboxgames/',
  '/riot games/',
  '/ubisoft game launcher/games/',
  '/ea games/',
  '/origin games/',
];

/// Folders in a library that are not games, and programs in a game's folder that are not the game.
const Set<String> _notGames = {'steamworks shared', 'steamvr', 'steam controller configs', 'launcher', 'epic online services', 'directxredist', 'riot client', 'proton', 'steamlinuxruntime'};
final RegExp _helper = RegExp(r'(crash|report|helper|updater|unins|install|setup|redist|easyanticheat|anticheat|battleye|launcher|webhelper|cefprocess|overlay|service)', caseSensitive: false);

/// A program that is running: its whole path.
typedef Running = String;

/// What a Mac app says of itself: whether its category is a game's, and its name.
typedef AppFacts = ({bool game, String name});

/// Finds the game running on this Mac or Windows computer from the list of running programs: by a library's folder,
/// a known program's name, the person's own list, or a Mac app's category. Nothing is read of what a program does.
class GameSense {
  GameSense({this.runner = _run, this.windows, this.home});

  /// Runs a program and gives what it wrote; a test gives its own.
  final Future<String> Function(String program, List<String> args) runner;

  /// Windows rather than a Mac; this computer's where null.
  final bool? windows;
  final String? home;

  bool get _windows => windows ?? PlatformInfo.isWindows;

  /// Whether this device can look at all.
  static bool get supported => !kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows);

  /// The app's own runner: what the program wrote, '' where it failed; 12 seconds at most.
  static Future<String> _run(String program, List<String> args) async {
    final r = await Process.run(program, args, stdoutEncoding: utf8, stderrEncoding: utf8).timeout(const Duration(seconds: 12));
    return r.exitCode == 0 ? '${r.stdout}' : '';
  }

  /// What each Mac app said of itself, kept while the app runs: an app is asked once.
  final Map<String, AppFacts> _apps = {};

  /// When each game was first seen running, to know the newest.
  final Map<String, DateTime> _seen = {};

  /// The paths of the programs running now.
  Future<List<Running>> running() async {
    final out = _windows
        ? await runner('powershell', const ['-NoProfile', '-NonInteractive', '-Command', r'Get-CimInstance Win32_Process | ForEach-Object { $_.ExecutablePath }'])
        : await runner('/bin/ps', const ['-axo', 'comm=']);
    return [for (final l in const LineSplitter().convert(out)) if (l.trim().isNotEmpty) l.trim()];
  }

  /// The game running now, or null: [also] are program names the person calls games, [never] game names never said.
  Future<String?> now({Set<String> also = const {}, Set<String> never = const {}}) async {
    final List<Running> paths;
    try {
      paths = await running();
    } catch (_) {
      return null;
    }
    final found = <String>{};
    final bundles = <String>{};
    for (final p in paths) {
      final g = gameOf(p, also: also);
      if (g != null) {
        found.add(g);
      } else if (!_windows) {
        final b = bundleOf(p);
        if (b != null) bundles.add(b);
      }
    }
    // A Mac app that says it is a game.
    for (final b in bundles) {
      final facts = _apps[b] ??= await _factsOf(b);
      if (facts.game && facts.name.isNotEmpty) found.add(facts.name);
    }
    final hidden = {for (final n in never) n.toLowerCase()};
    found.removeWhere((g) => hidden.contains(g.toLowerCase()));
    _seen.removeWhere((g, _) => !found.contains(g));
    final at = DateTime.now();
    for (final g in found) {
      _seen.putIfAbsent(g, () => at);
    }
    if (found.isEmpty) return null;
    // The one that started last; by name where two were first seen together.
    final sorted = found.toList()..sort((a, b) => _seen[b]!.compareTo(_seen[a]!) != 0 ? _seen[b]!.compareTo(_seen[a]!) : a.compareTo(b));
    return sorted.first;
  }

  /// The game [path] is a program of, by where it runs from or what it is called; null for anything else.
  static String? gameOf(String path, {Set<String> also = const {}}) {
    final slashed = path.replaceAll('\\', '/');
    final lower = slashed.toLowerCase();
    final file = slashed.split('/').last;
    final stem = file.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
    // The app a Mac program is in, by its name ("RuneLite" of /Applications/RuneLite.app/Contents/MacOS/RuneLite).
    final bundle = bundleOf(slashed);
    final app = bundle == null || bundle.contains('.app/') ? null : bundle.split('/').last.replaceFirst(RegExp(r'\.app$', caseSensitive: false), '');
    for (final name in {...also}) {
      final n = name.toLowerCase().replaceFirst(RegExp(r'\.(exe|app)$'), '');
      if (n.isNotEmpty && (n == stem || n == app?.toLowerCase())) return app ?? _titled(file);
    }
    for (final lib in _libraries) {
      final at = lower.indexOf(lib);
      if (at < 0) continue;
      final rest = slashed.substring(at + lib.length);
      final cut = rest.indexOf('/');
      if (cut <= 0) continue;
      final folder = rest.substring(0, cut);
      if (_notGames.contains(folder.toLowerCase()) || folder.toLowerCase().startsWith('proton ') || folder.toLowerCase().startsWith('steamlinuxruntime')) return null;
      if (_helper.hasMatch(file)) return null;
      return folder;
    }
    // Minecraft's own Java, wherever the launcher keeps it.
    if ((lower.contains('/minecraft/runtime/') || lower.contains('/.minecraft/runtime/')) && stem.startsWith('java')) return 'Minecraft';
    final known = knownGames[stem] ?? (app == null ? null : knownGames[app.toLowerCase()]);
    return known;
  }

  /// The outermost `.app` a Mac program runs from, or null: a helper inside an app is that app.
  static String? bundleOf(String path) {
    final at = path.indexOf('.app/');
    if (at < 0) return null;
    final bundle = path.substring(0, at + 4);
    if (bundle.startsWith('/System/') || bundle.startsWith('/usr/') || bundle.startsWith('/Library/Apple/')) return null;
    return bundle;
  }

  /// What the app at [bundle] says of itself in its Info.plist.
  Future<AppFacts> _factsOf(String bundle) async {
    final fallback = bundle.split('/').last.replaceFirst(RegExp(r'\.app$', caseSensitive: false), '');
    try {
      final plist = '$bundle/Contents/Info.plist';
      // The whole of it as JSON where it can be; else the two things wanted, one at a time.
      final json = await runner('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist]);
      if (json.trim().startsWith('{')) return factsOf(jsonDecode(json) as Map, fallback);
      final category = (await runner('/usr/bin/plutil', ['-extract', 'LSApplicationCategoryType', 'raw', '-o', '-', plist])).trim();
      if (!category.contains('games')) return (game: false, name: fallback);
      final name = (await runner('/usr/bin/plutil', ['-extract', 'CFBundleName', 'raw', '-o', '-', plist])).trim();
      return (game: true, name: name.isEmpty ? fallback : name);
    } catch (_) {
      return (game: false, name: fallback);
    }
  }

  /// An Info.plist's say: a game where its category is one of the games' (`public.app-category.games`, `…action-games`…).
  @visibleForTesting
  static AppFacts factsOf(Map plist, String fallback) {
    final category = '${plist['LSApplicationCategoryType'] ?? ''}';
    final shown = plist['CFBundleDisplayName'], named = plist['CFBundleName'];
    final name = shown is String && shown.trim().isNotEmpty ? shown.trim() : (named is String && named.trim().isNotEmpty ? named.trim() : fallback);
    return (game: category.contains('games'), name: name);
  }

  /// A program's file as a name: "my-game.exe" is "my-game".
  static String _titled(String file) => file.replaceFirst(RegExp(r'\.(exe|app)$', caseSensitive: false), '');
}
