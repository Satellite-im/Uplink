import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../voice/hangout.dart';
import '../voice/open_space.dart';

/// One message of an open space's chat while it hangs over the floor ([FloorBubbles]).
@immutable
class FloorBubble {
  const FloorBubble({required this.id, required this.from, required this.name, required this.text, required this.shown, this.group});
  final String id;

  /// Who said it, as the floor names them: [OpenSpace.meId] for this device, else their id in the call.
  final String from;
  final String name;
  final String text;

  /// When it came up over the floor, by this device's clock.
  final DateTime shown;

  /// The group its writer stood in as they said it: it hangs over that group's circle. Null: at the side of the view.
  final String? group;
}

/// An open space's chat as bubbles over its floor (Matt, 2026-11-23: "make the chat show up in bubbles hovering over the
/// side that stack and fade away after a few messages if they're said within a circle make them stack above the circle
/// and make them fade away the further you are away from them").
///
/// Each message written after the floor was opened comes up as a bubble: over the group its writer stands in, or at the
/// side of the view for someone in no group. A stack holds the newest [most]; a bubble stays [life] and fades over the
/// last [fade] of it; and each is fainter the less of its writer (or its group) is heard from where this device stands,
/// as the people are. The chat itself is the space's own ([HangoutRoom]): nothing here is kept or sent, and the whole of
/// it is still on the space's Chat tab.
class FloorBubbles extends ChangeNotifier {
  FloorBubbles(this.floor, {DateTime Function()? now}) : _now = now ?? DateTime.now;
  final OpenSpace floor;
  final DateTime Function() _now;

  /// How long a bubble stays, how long its fading out takes, and how many one stack holds.
  static const life = Duration(seconds: 10), fade = Duration(milliseconds: 1800);
  static const most = 4;

  /// How faint a bubble is at its faintest for distance: still there to be noticed, never gone.
  static const faintest = 0.08;

  HangoutRoom? _room;
  final Set<String> _seen = {};
  final List<FloorBubble> _all = [];
  Timer? _tick;

  /// Follows [room]'s chat (null: none yet). What is in it already is not shown: only what is said from now.
  void follow(HangoutRoom? room) {
    if (identical(room, _room)) return;
    _room?.removeListener(_heard);
    _room = room;
    // Another chat's bubbles go with it.
    _all.clear();
    _seen
      ..clear()
      ..addAll([for (final m in room?.messages ?? const <HangoutMessage>[]) m.id]);
    room?.addListener(_heard);
  }

  /// What a message with no words says in a bubble.
  static String wordsOf(HangoutMessage m) {
    final words = m.text.trim();
    if (words.isNotEmpty) return words;
    if (m.sticker != null) return 'Sticker';
    if (m.voice) return 'Voice message';
    return m.files.isEmpty ? '' : (m.files.length == 1 ? 'Sent a file' : 'Sent ${m.files.length} files');
  }

  void _heard() {
    final room = _room;
    if (room == null) return;
    var added = false;
    for (final m in room.messages) {
      if (!_seen.add(m.id)) continue;
      final words = wordsOf(m);
      if (words.isEmpty) continue;
      final from = m.from == room.me ? OpenSpace.meId : m.from;
      _all.add(FloorBubble(id: m.id, from: from, name: m.name, text: words, shown: _now(), group: floor.groupOf(from)));
      added = true;
    }
    if (!added) return;
    _trim();
    _tick ??= Timer.periodic(const Duration(milliseconds: 200), (_) => _age());
    notifyListeners();
  }

  /// Each stack keeps its newest [most]; a bubble whose group has gone moves to the side.
  void _trim() {
    final live = {for (final g in floor.groups) g.id};
    final counts = <String?, int>{};
    for (var i = _all.length - 1; i >= 0; i--) {
      final b = _all[i];
      final stack = b.group != null && live.contains(b.group) ? b.group : null;
      final n = counts[stack] = (counts[stack] ?? 0) + 1;
      if (n > most) _all.removeAt(i);
    }
  }

  void _age() {
    final now = _now();
    _all.removeWhere((b) => now.difference(b.shown) >= life);
    if (_all.isEmpty) {
      _tick?.cancel();
      _tick = null;
    }
    notifyListeners();
  }

  /// The bubbles at the side of the view, oldest first: from people in no group (or whose group has gone).
  List<FloorBubble> get side {
    final live = {for (final g in floor.groups) g.id};
    return [for (final b in _all) if (b.group == null || !live.contains(b.group)) b];
  }

  /// The bubbles over the group [id], oldest first.
  List<FloorBubble> over(String id) => floor.groups.any((g) => g.id == id) ? [for (final b in _all) if (b.group == id) b] : const [];

  /// How strongly [b] is drawn, 0 to 1: whole while fresh, fading out at the end of its [life], and fainter the less
  /// of its writer or its group is heard from here.
  double opacityOf(FloorBubble b) {
    final age = _now().difference(b.shown);
    final left = life - age;
    final time = left <= Duration.zero ? 0.0 : (left >= fade ? 1.0 : left.inMilliseconds / fade.inMilliseconds);
    return time * (faintest + (1 - faintest) * _heardOf(b));
  }

  double _heardOf(FloorBubble b) {
    if (b.from == OpenSpace.meId) return 1;
    final g = b.group == null ? null : floor.groups.where((x) => x.id == b.group).firstOrNull;
    if (g != null) {
      // In the group: all of it. Outside: by how far off its edge is.
      if (floor.groupOf(OpenSpace.meId) == g.id) return 1;
      return OpenWorld.gain(math.max(0, floor.me.at.to(g.at) - floor.radiusOf(g.id)));
    }
    // Someone in no group: as much as they are heard. Someone who has left since: faint.
    return floor.people.contains(b.from) ? floor.gainOf(b.from) : 0.4;
  }

  @override
  void dispose() {
    _room?.removeListener(_heard);
    _tick?.cancel();
    super.dispose();
  }
}
