import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../net/crypto.dart';
import 'channels.dart';
import 'voice.dart';

/// An open space: a call you walk around in (Matt, 2026-11-23: "a new kind of space called a "open space" which has a
/// top down view and lets you move around in the space so we can hear people louder or quieter depending on where in
/// the space we are, allow creating groups in the space that display as a targeted circle that expands as more people
/// enter it so you could have different spaces for games like valorant group casual chat group movie watching").
///
/// It is an ordinary call ([VoiceSession]) with three things on top, all held here and none of them the relay's:
/// - **Places.** Everyone stands somewhere on one floor ([OpenWorld]) and says where as they move (`os`: x, y, which way
///   they face, whether they are walking). Someone who says nothing (a build from before, a guest in a browser, the
///   Discord bridge) stands in the middle, so they are still found and heard.
/// - **Hearing.** How loud each person is played on this device goes by how far they stand from it ([OpenWorld.gain]):
///   whole when near, fading to nothing far off. It is one more gain on their sound ([PlacedMedia]), under each person's
///   own volume, so nothing about the call itself changes and nobody is cut off: walking back brings them back.
/// - **Groups.** Named circles on the floor ([SpaceGroup]: a game, a chat, a film). Whoever stands in one hears the
///   others in it whole, wherever in it they stand, and those outside it faintly; from outside, a group is a murmur. A
///   group's circle grows with how many are in it ([OpenWorld.radiusFor]). Anyone in the space may make, name, move or
///   take away a group; the newest word about each wins, and what is known of a space's groups is kept on the device and
///   said again on coming in, so they are there for whoever comes back to an empty room.
///
/// **The figure.** Today each person is drawn as their profile picture with the call's ripple round it
/// (lib/ui/open_space_view.dart). What is said about a place already carries which way they face and whether they are
/// walking, and the view draws people through one builder ([OpenFigure] is what it is handed), so a character in the
/// picture's place (Matt: "plan for a actual character to be used in the near future like a ghost we can customize with
/// cosmetics") is a new builder and, for its cosmetics, one more field (`f`) beside these: nothing here changes.
class OpenWorld {
  OpenWorld._();

  /// The floor, in its own units (a face is about 56 across).
  static const double width = 2400, height = 1600;

  /// Where someone stands who has said nothing of their place.
  static const Offset2 middle = Offset2(width / 2, height / 2);

  /// Heard whole within [near] of this device; not at all beyond [far].
  static const double near = 170, far = 760;

  /// How much of someone's sound gets through a group's edge (one of the two in a group the other is not in).
  static const double throughEdge = 0.3;

  /// A group's circle with nobody in it, and how much it grows for each person in it (by the square root, as the floor
  /// each takes), up to [radiusMost].
  static const double radiusEmpty = 130, radiusEach = 38, radiusMost = 420;

  /// How fast someone walks, in units a second.
  static const double speed = 300;

  /// The most groups one space holds, and the longest name one has.
  static const int mostGroups = 24, longestName = 32;

  /// A group's radius with [people] in it.
  static double radiusFor(int people) => math.min(radiusMost, radiusEmpty + radiusEach * math.sqrt(people.toDouble()));

  /// How much of someone's sound is played, 0 to 1, [distance] away: whole in one's own group ([together]) wherever in
  /// it they stand; otherwise whole when near and falling away smoothly to nothing, and fainter still through a group's
  /// edge ([edge]).
  static double gain(double distance, {bool together = false, bool edge = false}) {
    if (together) return 1;
    final double open;
    if (distance <= near) {
      open = 1;
    } else if (distance >= far) {
      open = 0;
    } else {
      final t = (far - distance) / (far - near);
      // Squared: loudness falls away quickly at first, as it does across a room.
      open = t * t;
    }
    return edge ? open * throughEdge : open;
  }

  static double clampX(double x) => x.clamp(0.0, width);
  static double clampY(double y) => y.clamp(0.0, height);
}

/// A point on the floor (dart:ui's Offset, without the UI: this file is used with no screen).
@immutable
class Offset2 {
  const Offset2(this.x, this.y);
  final double x, y;
  double to(Offset2 o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
  @override
  bool operator ==(Object other) => other is Offset2 && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => '(${x.round()}, ${y.round()})';
}

/// Where someone stands, as they last said.
@immutable
class Place {
  const Place(this.at, {this.facing = 0, this.walking = false, this.said = true});
  final Offset2 at;

  /// Which way they face, in radians (0 to the right, a quarter turn down the screen): for a character, later.
  final double facing;
  final bool walking;

  /// False for the middle, given to someone who has said nothing.
  final bool said;

  static const Place unsaid = Place(OpenWorld.middle, said: false);
}

/// A group on the floor: its name, its middle, its colour (one of the app's hues), and when it was last changed. One
/// taken away is kept for a while as [gone], so a device that was away doesn't bring it back.
@immutable
class SpaceGroup {
  const SpaceGroup({required this.id, required this.name, required this.at, this.hue = 'purple', required this.changed, this.gone = false});
  final String id;
  final String name;
  final Offset2 at;
  final String hue;
  final int changed;
  final bool gone;

  static const hues = ['purple', 'green', 'blue', 'amber', 'rose', 'cyan', 'orange', 'mint'];

  SpaceGroup copyWith({String? name, Offset2? at, int? changed, bool? gone}) => SpaceGroup(id: id, name: name ?? this.name, at: at ?? this.at, hue: hue, changed: changed ?? this.changed, gone: gone ?? this.gone);

  Map<String, Object?> toJson() => {'i': id, 'n': name, 'x': at.x.round(), 'y': at.y.round(), 'h': hue, 'at': changed, if (gone) 'gone': 1};

  /// From what another device said, or what was kept; null for anything that is not a group.
  static SpaceGroup? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['i'], name = j['n'], x = j['x'], y = j['y'], at = j['at'];
    if (id is! String || id.isEmpty || id.length > 32 || name is! String || x is! num || y is! num || at is! int) return null;
    if (!x.isFinite || !y.isFinite) return null;
    final hue = j['h'];
    final words = name.trim();
    return SpaceGroup(
      id: id,
      name: words.length > OpenWorld.longestName ? words.substring(0, OpenWorld.longestName) : words,
      at: Offset2(OpenWorld.clampX(x.toDouble()), OpenWorld.clampY(y.toDouble())),
      hue: hue is String && hues.contains(hue) ? hue : hues.first,
      changed: at,
      gone: j['gone'] == 1,
    );
  }
}

/// Where a space's groups are kept between calls: the app's choices in the app, a map in a test.
abstract class OpenStore {
  String? read(String key);
  void write(String key, String value);
}

/// [OpenStore] over the app's choices.
class AppOpenStore implements OpenStore {
  AppOpenStore(this.app);
  final AppState app;
  @override
  String? read(String key) {
    final v = app.choice(key, '');
    return v.isEmpty ? null : v;
  }

  @override
  void write(String key, String value) => app.keep(key, value);
}

/// One open space's floor while this device is in its call: everyone's place, the groups, and how loud each is played.
/// Told of changes as any ChangeNotifier is; the view draws from it every frame.
class OpenSpace extends ChangeNotifier {
  OpenSpace(this.session, {this.store, PlacedMedia? media, DateTime Function()? now, math.Random? random})
      : _media = media ?? (session.media is PlacedMedia ? session.media as PlacedMedia : null),
        _now = now ?? DateTime.now {
    final r = random ?? math.Random();
    // In near the middle, a little apart from whoever else comes in.
    final a = r.nextDouble() * math.pi * 2, d = 40 + r.nextDouble() * 110;
    _me = Place(Offset2(OpenWorld.middle.x + math.cos(a) * d, OpenWorld.middle.y + math.sin(a) * d));
    _readKept();
    session.onPlace = _heard;
    session.addListener(_sessionChanged);
    _known = session.members.keys.toSet();
    _beat = Timer.periodic(beatEvery, (_) => _sayPlace());
    _settle();
    // Said once in: where this device stands and the groups it knows of.
    scheduleMicrotask(() {
      if (_disposed) return;
      _sayPlace();
      _sayGroups();
    });
  }

  final VoiceSession session;
  final OpenStore? store;
  final PlacedMedia? _media;
  final DateTime Function() _now;

  /// A place is said again this often while standing still, for whoever missed it, and at most this often while
  /// walking.
  static const beatEvery = Duration(seconds: 3), whileWalking = Duration(milliseconds: 100);

  /// A group taken away is remembered this long, so a device that was away doesn't bring it back.
  static const goneKept = Duration(days: 14);

  late Place _me;
  final Map<String, Place> _places = {};
  final Map<String, SpaceGroup> _groups = {};
  Set<String> _known = {};
  Timer? _beat, _walk;
  bool _disposed = false;

  /// Let go of (the call was left): what still draws it for a frame draws nothing.
  bool get gone => _disposed;

  /// This device's id on the floor, as the view names it.
  static const meId = 'me';

  /// Where this device stands.
  Place get me => _me;

  /// Where [id] stands ([meId] for this device): the middle for someone who has said nothing.
  Place placeOf(String id) => id == meId ? _me : (_places[id] ?? Place.unsaid);

  /// Everyone on the floor: this device, then the call's members.
  List<String> get people => [meId, ...session.members.keys];

  /// The groups there are, oldest first.
  List<SpaceGroup> get groups => [for (final g in _groups.values) if (!g.gone) g]..sort((a, b) => a.id.compareTo(b.id));

  // --- who is in which group, worked out whenever anything moves ([_settle]) ---------------------------------------------

  final Map<String, String> _in = {};
  final Map<String, double> _radius = {};

  /// The group [id] stands in, if any ([meId] for this device).
  String? groupOf(String id) => _in[id];

  /// How many stand in [group], and its circle's radius now.
  int countIn(String group) => _in.values.where((g) => g == group).length;
  double radiusOf(String group) => _radius[group] ?? OpenWorld.radiusEmpty;

  /// Works out who stands in which group and how big each circle is, then how loud everyone is played. A circle grows
  /// with those in it, and growing can take in someone standing just outside, so it is counted until it settles;
  /// someone inside two circles is in the one whose middle is nearer.
  void _settle() {
    final live = groups;
    final ids = people;
    final radius = {for (final g in live) g.id: OpenWorld.radiusEmpty};
    final inside = <String, String>{};
    for (var round = 0; round < 6; round++) {
      inside.clear();
      for (final id in ids) {
        final at = placeOf(id).at;
        SpaceGroup? best;
        var bestD = double.infinity;
        for (final g in live) {
          final d = at.to(g.at);
          if (d <= radius[g.id]! && d < bestD) {
            best = g;
            bestD = d;
          }
        }
        if (best != null) inside[id] = best.id;
      }
      var grew = false;
      for (final g in live) {
        final want = OpenWorld.radiusFor(inside.values.where((x) => x == g.id).length);
        if (want > radius[g.id]!) {
          radius[g.id] = want;
          grew = true;
        }
      }
      if (!grew) break;
    }
    _in
      ..clear()
      ..addAll(inside);
    _radius
      ..clear()
      ..addAll(radius);
    _applyGains();
  }

  // --- hearing -----------------------------------------------------------------------------------------------------------

  final Map<String, double> _gains = {};

  /// How much of [id]'s sound is played here, 0 to 1.
  double gainOf(String id) {
    final mine = _in[meId], theirs = _in[id];
    return OpenWorld.gain(_me.at.to(placeOf(id).at), together: mine != null && mine == theirs, edge: mine != theirs);
  }

  void _applyGains() {
    final m = _media;
    final ids = session.members.keys.toSet();
    for (final id in ids) {
      final g = gainOf(id);
      final had = _gains[id];
      // A hair's difference is not worth setting, but silence and whole always are: never left a hair short of either.
      if (had == g || (had != null && g != 0 && g != 1 && (had - g).abs() < 0.01)) continue;
      _gains[id] = g;
      m?.setPlaceGain(id, g);
    }
    // Whoever left is played as anyone is the next time they are met.
    for (final id in _gains.keys.where((id) => !ids.contains(id)).toList()) {
      _gains.remove(id);
      m?.setPlaceGain(id, 1);
    }
  }

  // --- walking -----------------------------------------------------------------------------------------------------------

  double _dx = 0, _dy = 0;
  Offset2? _target;
  DateTime? _stepped, _saidAt;

  /// Whether this device is walking.
  bool get walking => _dx != 0 || _dy != 0 || _target != null;

  /// Walks the way ([dx], [dy]) points (keys held: -1, 0 or 1 each way) until told otherwise; 0, 0 stops.
  void head(double dx, double dy) {
    final len = math.sqrt(dx * dx + dy * dy);
    _dx = len == 0 ? 0 : dx / len;
    _dy = len == 0 ? 0 : dy / len;
    if (len != 0) _target = null;
    _walking();
  }

  /// Walks to [to] and stops there (a press on the floor).
  void walkTo(Offset2 to) {
    _dx = _dy = 0;
    _target = Offset2(OpenWorld.clampX(to.x), OpenWorld.clampY(to.y));
    _walking();
  }

  /// Starts or stops the clock that moves this device.
  void _walking() {
    if (!walking) {
      _walk?.cancel();
      _walk = null;
      _stepped = null;
      if (_me.walking) {
        _me = Place(_me.at, facing: _me.facing);
        _sayPlace();
        notifyListeners();
      }
      return;
    }
    _walk ??= Timer.periodic(const Duration(milliseconds: 16), (_) => step());
  }

  /// One step, as long as the time since the last ([seconds] in a test): moved, hearing worked out again, and the new
  /// place said if it is time.
  @visibleForTesting
  void step([double? seconds]) {
    if (_disposed || !walking) return;
    final now = _now();
    final dt = seconds ?? math.min(0.1, (now.difference(_stepped ?? now).inMicroseconds / 1e6));
    _stepped = now;
    if (dt <= 0) return;
    var x = _me.at.x, y = _me.at.y, facing = _me.facing;
    final reach = OpenWorld.speed * dt;
    final t = _target;
    if (t != null) {
      final d = _me.at.to(t);
      if (d <= reach) {
        x = t.x;
        y = t.y;
        _target = null;
      } else {
        facing = math.atan2(t.y - y, t.x - x);
        x += (t.x - x) / d * reach;
        y += (t.y - y) / d * reach;
      }
    } else {
      facing = math.atan2(_dy, _dx);
      x += _dx * reach;
      y += _dy * reach;
    }
    _me = Place(Offset2(OpenWorld.clampX(x), OpenWorld.clampY(y)), facing: facing, walking: walking);
    _settle();
    if (_saidAt == null || now.difference(_saidAt!) >= whileWalking) _sayPlace();
    notifyListeners();
    if (!walking) _walking();
  }

  // --- what is said, and heard -------------------------------------------------------------------------------------------

  void _sayPlace() {
    if (_disposed || !session.joined) return;
    _saidAt = _now();
    session.sayPlace({'t': 'os', 'x': _me.at.x.round(), 'y': _me.at.y.round(), 'd': (_me.facing * 180 / math.pi).round(), if (_me.walking) 'w': 1});
  }

  void _sayGroups() {
    if (_disposed || !session.joined || _groups.isEmpty) return;
    session.sayPlace({'t': 'osg', 'g': [for (final g in _groups.values) g.toJson()]});
  }

  void _heard(String from, Map<String, dynamic> m) {
    if (_disposed) return;
    switch (m['t']) {
      case 'os':
        final x = m['x'], y = m['y'], d = m['d'];
        if (x is! num || y is! num || !x.isFinite || !y.isFinite) return;
        _places[from] = Place(Offset2(OpenWorld.clampX(x.toDouble()), OpenWorld.clampY(y.toDouble())), facing: d is num && d.isFinite ? d * math.pi / 180 : 0, walking: m['w'] == 1);
        _settle();
        notifyListeners();
      case 'osg':
        final list = m['g'];
        if (list is! List) return;
        var changed = false;
        for (final j in list.take(OpenWorld.mostGroups * 4)) {
          final g = SpaceGroup.fromJson(j);
          if (g != null && _take(g)) changed = true;
        }
        if (!changed) return;
        _keep();
        _settle();
        notifyListeners();
    }
  }

  /// Takes [g] where it is news: a group not known, or a newer word about one that is (the same moment: the one taken
  /// away wins, then the greater name, so every device ends the same). False where it is not, or the space is full.
  bool _take(SpaceGroup g) {
    final had = _groups[g.id];
    if (had != null) {
      if (g.changed < had.changed) return false;
      if (g.changed == had.changed && (g.gone == had.gone ? g.name.compareTo(had.name) <= 0 : !g.gone)) return false;
    } else if (!g.gone && groups.length >= OpenWorld.mostGroups) {
      return false;
    }
    _groups[g.id] = g;
    return true;
  }

  /// Someone came or went: places said again for a newcomer, and hearing worked out for who is here now. A floor made
  /// before its call is in (Voice.join) says nothing until then: those already there are newcomers to it as it joins.
  void _sessionChanged() {
    if (_disposed) return;
    final now = session.members.keys.toSet();
    final came = now.difference(_known).isNotEmpty;
    final went = _known.difference(now);
    _known = now;
    for (final id in went) {
      _places.remove(id);
    }
    if (came) {
      _sayPlace();
      _sayGroups();
    }
    if (came || went.isNotEmpty) {
      _settle();
      notifyListeners();
    }
  }

  // --- groups ------------------------------------------------------------------------------------------------------------

  /// A moment for a change of this device's: never earlier than what it changes, whatever the clocks say.
  int _stamp([SpaceGroup? over]) => math.max(_now().millisecondsSinceEpoch, (over?.changed ?? 0) + 1);

  static String _clean(String name) {
    final words = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    return words.length > OpenWorld.longestName ? words.substring(0, OpenWorld.longestName) : words;
  }

  /// Makes a group called [name] round where this device stands. Null where the name is empty or the space is full.
  SpaceGroup? addGroup(String name) {
    final words = _clean(name);
    if (words.isEmpty || groups.length >= OpenWorld.mostGroups) return null;
    final id = NetCrypto.hex(NetCrypto.randomBytes(6));
    // A colour from its id, not from how many there are: two made at once on two devices are then told apart.
    final g = SpaceGroup(id: id, name: words, at: _me.at, hue: SpaceGroup.hues[int.parse(id.substring(0, 4), radix: 16) % SpaceGroup.hues.length], changed: _stamp());
    _change(g);
    return g;
  }

  void renameGroup(String id, String name) {
    final g = _groups[id];
    final words = _clean(name);
    if (g == null || g.gone || words.isEmpty) return;
    _change(g.copyWith(name: words, changed: _stamp(g)));
  }

  /// Moves [id] to where this device stands.
  void moveGroupHere(String id) {
    final g = _groups[id];
    if (g == null || g.gone) return;
    _change(g.copyWith(at: _me.at, changed: _stamp(g)));
  }

  void removeGroup(String id) {
    final g = _groups[id];
    if (g == null || g.gone) return;
    _change(g.copyWith(gone: true, changed: _stamp(g)));
  }

  void _change(SpaceGroup g) {
    _groups[g.id] = g;
    _keep();
    _settle();
    if (session.joined) session.sayPlace({'t': 'osg', 'g': [g.toJson()]});
    notifyListeners();
  }

  String get _key => 'open_${session.channel.room}_groups';

  void _readKept() {
    final kept = store?.read(_key);
    if (kept == null) return;
    try {
      final old = _now().subtract(goneKept).millisecondsSinceEpoch;
      for (final j in jsonDecode(kept) as List) {
        final g = SpaceGroup.fromJson(j);
        if (g != null && !(g.gone && g.changed < old)) _groups[g.id] = g;
      }
    } catch (_) {
      // What was kept can't be read: the floor starts bare, and the others say what they know.
    }
  }

  void _keep() => store?.write(_key, jsonEncode([for (final g in _groups.values) g.toJson()]));

  @override
  void dispose() {
    _disposed = true;
    _beat?.cancel();
    _walk?.cancel();
    session.removeListener(_sessionChanged);
    if (identical(session.onPlace, _heard)) session.onPlace = null;
    // Everyone is played as anyone is again, in whatever call comes next.
    for (final id in _gains.keys) {
      _media?.setPlaceGain(id, 1);
    }
    _gains.clear();
    super.dispose();
  }
}

/// The open space this device is in the call of, if it is in one: made as the call is begun, before the relay has
/// answered, and let go of as it is left (Voice.join and leave call [follow]), so the floor is on the screen from the
/// first moment rather than once the call is in.
class OpenSpaces extends ChangeNotifier {
  OpenSpaces._();
  static final OpenSpaces instance = OpenSpaces._();

  /// The app's choices, where a space's groups are kept (set as the app starts: Voice.start).
  AppState? app;

  OpenSpace? _current;

  /// The floor of the call this device is in, where that call is an open space's.
  OpenSpace? get current => _current;

  /// Whether [s] is an open space's call. Every surface that draws a call asks this, not whether a floor is followed
  /// yet ([of]): the floor is drawn in place of the call's people, and neither the call's page (lib/ui/space_designs) nor a list of
  /// people is drawn in its place (Matt, 2026-11-23: "the open space is just showing up as a normal call for me").
  static bool isCall(VoiceSession? s) => s != null && s.channel.kind == SpaceKind.open;

  /// The floor of [session], where it is the one followed.
  OpenSpace? of(VoiceSession? session) => session != null && identical(_current?.session, session) ? _current : null;

  /// Follows the call [Voice] is in.
  void follow() => followSession(Voice.instance.session);

  /// Follows [s] (null: no call): a floor for it where its space is an open one, and the one before let go of.
  void followSession(VoiceSession? s) {
    if (identical(s, _current?.session)) return;
    _current?.dispose();
    final a = app;
    _current = s != null && s.channel.kind == SpaceKind.open ? OpenSpace(s, store: a == null ? null : AppOpenStore(a)) : null;
    notifyListeners();
  }
}

/// What the view hands whatever draws a person ([OpenSpace]'s own words say why): enough for a picture today and a
/// character tomorrow.
@immutable
class OpenFigure {
  const OpenFigure({required this.id, required this.name, required this.me, required this.size, required this.level, required this.muted, required this.facing, required this.walking, required this.heard});
  final String id;
  final String name;
  final bool me;

  /// How big to draw them, in the screen's units.
  final double size;

  /// How loud they are right now, 0 to 1 (the ripple), and whether their microphone is off.
  final double level;
  final bool muted;

  /// Which way they face, in radians, and whether they are walking.
  final double facing;
  final bool walking;

  /// How much of them this device hears, 0 to 1.
  final double heard;
}
