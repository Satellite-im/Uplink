/// What someone is playing, beside their name (Matt, 2026-11-20: "what about game presence sensing like discord has?",
/// then "THat sounds good, let's build").
///
/// **Yours.** While the Game activity plugin is on (lib/plugins/game_activity.dart; off until added), a Mac or a
/// Windows computer looks every half minute for a game among its running programs (lib/games/game_sense.dart). What
/// it finds is told to friends by username, sealed as everything said to them is, and to the spaces and circles this
/// device is in, each where its switch allows; and told again every five minutes, so someone who opens the app later
/// learns it. Stopping the game, switching the plugin off or closing the app says so.
///
/// **Theirs.** What a friend or someone in a space says they are playing is kept in memory only, with when they began,
/// and forgotten twelve minutes after it was last said (a computer that lost its connection never says it stopped).
///
/// On the wire it is `ga`: `{n: the game's name, s: when it began, in milliseconds}`; nothing, or no name, for not
/// playing. A build from before passes over it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../friends/buddies.dart';
import '../plugins/game_activity.dart';
import '../plugins/plugin.dart' show wordsOf;
import '../plugins/registry.dart';
import '../voice/channels.dart' show Voice;
import 'game_sense.dart';

/// One game someone is playing and since when: on the wire, `{n: name, s: ms since the epoch}`.
@immutable
class GameActivity {
  const GameActivity(this.name, this.since);

  /// The game, as its library or its app calls it.
  final String name;
  final DateTime since;

  /// The most characters of a name that are kept of what someone else says.
  static const most = 60;

  Map<String, Object> toJson() => {'n': name, 's': since.millisecondsSinceEpoch};

  /// What [j] says someone is playing; null for nothing, or anything that is not a name.
  static GameActivity? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['n'], s = j['s'];
    if (n is! String) return null;
    // One line, no control characters, no longer than a game's name is.
    final name = String.fromCharCodes(n.replaceAll(RegExp(r'[\x00-\x1f\x7f  ]'), ' ').trim().runes.take(most));
    if (name.isEmpty) return null;
    final now = DateTime.now();
    var since = s is int ? DateTime.fromMillisecondsSinceEpoch(s) : now;
    // A clock ahead of this one, or a nonsense time: began now.
    if (since.isAfter(now) || now.difference(since) > const Duration(days: 7)) since = now;
    return GameActivity(name, since);
  }

  /// "Playing Hades" and for how long, once it has been a minute: "Playing Hades · 25 min", "· 2 h 5 min".
  String words([DateTime? at]) {
    final d = (at ?? DateTime.now()).difference(since);
    if (d.inMinutes < 1) return 'Playing $name';
    final h = d.inHours, m = d.inMinutes % 60;
    return 'Playing $name · ${h > 0 ? '$h h${m > 0 ? ' $m min' : ''}' : '$m min'}';
  }

  @override
  bool operator ==(Object other) => other is GameActivity && other.name == name && other.since == since;

  @override
  int get hashCode => Object.hash(name, since);
}

/// What everyone is playing, as far as this device has been told, and what this device is.
class GameActivities extends ChangeNotifier {
  GameActivities({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static GameActivities instance = GameActivities();

  final DateTime Function() _clock;

  /// How long after it was last said someone's game is still believed.
  static const kept = Duration(minutes: 12);

  final Map<String, ({GameActivity game, DateTime heard})> _theirs = {};

  /// What this device is playing, as it would tell; null for nothing.
  GameActivity? mine;

  /// What [id] (an install's name on Uplink) is playing, where they said so lately.
  GameActivity? of(String? id) {
    if (id == null || id.isEmpty) return null;
    final t = _theirs[id];
    if (t == null) return null;
    if (_clock().difference(t.heard) > kept) {
      _theirs.remove(id);
      return null;
    }
    return t.game;
  }

  /// [id] said what they are playing ([said], the wire's `ga`), or that they are not.
  void heard(String id, Object? said) {
    if (id.isEmpty) return;
    final game = GameActivity.fromJson(said);
    final had = _theirs[id]?.game;
    if (game == null) {
      if (_theirs.remove(id) != null) notifyListeners();
      return;
    }
    _theirs[id] = (game: game, heard: _clock());
    if (had != game) notifyListeners();
  }

  /// Everyone's at once, as a phone tells its computer (`{id: ga}`): those not named are not playing.
  void heardAll(Object? said) {
    if (said is! Map) return;
    final before = {for (final e in _theirs.entries) e.key: e.value.game};
    _theirs.clear();
    for (final e in said.entries) {
      final game = GameActivity.fromJson(e.value);
      if (e.key is String && game != null) _theirs[e.key as String] = (game: game, heard: _clock());
    }
    if (!mapEquals(before, {for (final e in _theirs.entries) e.key: e.value.game})) notifyListeners();
  }

  /// Everyone believed to be playing now, as the wire's `{id: ga}`.
  Map<String, Object> all() => {
        for (final id in _theirs.keys.toList())
          if (of(id) != null) id: of(id)!.toJson(),
      };

  /// What this device is playing changed ([GamePresence.look]); listeners are told only where it did.
  void setMine(GameActivity? game) {
    if (mine == game) return;
    mine = game;
    notifyListeners();
  }
}

/// Looks for this computer's game and tells it: see the top of the file.
class GamePresence {
  GamePresence({GameSense? sense, GameActivities? activities, this.every = const Duration(seconds: 30), this.first = const Duration(seconds: 20), this.again = const Duration(minutes: 5), this.tell})
      : sense = sense ?? GameSense(),
        activities = activities ?? GameActivities.instance;

  static GamePresence instance = GamePresence();

  final GameSense sense;
  final GameActivities activities;
  final Duration every;

  /// How long after the app opens it first looks: once its friends and spaces are reached.
  final Duration first;
  Timer? _opening;

  /// How often a game still being played is said again.
  final Duration again;

  /// How it is told (to friends, to spaces): the app's own where null; a test gives one.
  final void Function(GameActivity? game, {required bool friends, required bool spaces})? tell;

  AppState? _app;

  /// The app's choices, where the plugin's switches are; a test gives them without starting the timers.
  @visibleForTesting
  set app(AppState app) => _app = app;
  Timer? _timer;
  bool _busy = false;
  DateTime? _told;

  /// What was last told to friends and to spaces, to say "stopped" only to those who were told.
  bool _toldFriends = false, _toldSpaces = false;

  /// Starts looking, on a computer; it looks only while the plugin is on, and follows its switches as they change.
  void start(AppState app) {
    if (_app != null) return;
    _app = app;
    if (!GameSense.supported) return;
    _timer = Timer.periodic(every, (_) => unawaited(look()));
    app.addListener(_changed);
    _switches = _prefsKey();
    _opening = Timer(first, () => unawaited(look()));
  }

  /// Stops looking. Nothing is told: whoever was told last stops believing it after [GameActivities.kept].
  void stop() {
    _timer?.cancel();
    _opening?.cancel();
    _timer = null;
    _app?.removeListener(_changed);
    _app = null;
  }

  String _switches = '';

  /// A switch of the plugin's moved: looked again at once, so turning it off is said at once.
  void _changed() {
    final now = _prefsKey();
    if (now == _switches) return;
    _switches = now;
    unawaited(look());
  }

  /// The Game activity plugin's switches as they stand: whether it is on, whom it tells, the programs the person
  /// calls games and the games never said. All off where the plugin isn't there or isn't on.
  ({bool on, bool friends, bool spaces, Set<String> also, Set<String> never}) _prefs() {
    final app = _app;
    final reg = PluginRegistry.instance;
    final plugin = reg.plugins.whereType<GameActivityPlugin>().firstOrNull;
    if (app == null || plugin == null || !reg.isOn(plugin, AppStore(app))) return (on: false, friends: false, spaces: false, also: const {}, never: const {});
    final prefs = reg.prefsOf(plugin, AppStore(app));
    return (on: true, friends: prefs.flag('friends'), spaces: prefs.flag('spaces'), also: wordsOf(prefs, 'also').toSet(), never: wordsOf(prefs, 'never').toSet());
  }

  /// [_prefs] as one string, to see whether any of them moved.
  String _prefsKey() {
    final p = _prefs();
    return '${p.on}|${p.friends}|${p.spaces}|${p.also.join(',')}|${p.never.join(',')}';
  }

  /// Looks once, and tells what changed.
  Future<void> look() async {
    if (_busy) return;
    _busy = true;
    try {
      final p = _prefs();
      _switches = _prefsKey();
      final name = p.on ? await sense.now(also: p.also, never: p.never) : null;
      final had = activities.mine;
      // The same game goes on from when it began.
      final game = name == null ? null : (had?.name == name ? had! : GameActivity(name, DateTime.now()));
      final friends = game != null && p.friends, spaces = game != null && p.spaces;
      final changed = game != had || friends != _toldFriends || spaces != _toldSpaces;
      final due = game != null && _told != null && DateTime.now().difference(_told!) >= again;
      activities.setMine(game);
      if (!changed && !due) return;
      // To friends where they are told or were (to say it stopped); the same of spaces.
      final toFriends = friends || _toldFriends, toSpaces = spaces || _toldSpaces;
      _toldFriends = friends;
      _toldSpaces = spaces;
      _told = DateTime.now();
      if (toFriends || toSpaces) (tell ?? _tell)(game, friends: toFriends, spaces: toSpaces);
    } finally {
      _busy = false;
    }
  }

  /// What friends are told now: the game, where the plugin shares it with them; null otherwise.
  GameActivity? get forFriends => _toldFriends ? activities.mine : null;

  /// What spaces are told now.
  GameActivity? get forSpaces => _toldSpaces ? activities.mine : null;

  /// The app's own telling: friends are sent what [forFriends] says now, and every space this device is in is told
  /// about this device again.
  static void _tell(GameActivity? game, {required bool friends, required bool spaces}) {
    if (friends) unawaited(Buddies.instance.sayActivity(GamePresence.instance.forFriends).catchError((_) {}));
    if (spaces) Voice.instance.sayMeEverywhere();
  }
}
