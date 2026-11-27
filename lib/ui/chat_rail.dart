/// A chat's map, in the gutter at its right: a short line for each message, one under another, from the oldest held
/// at the top to the newest at the foot (Matt, 2026-11-25: "in the right hand of the chat gutter add this same style of
/// chat scrolling to show frequency of messages and who differently sent messages etc", with a picture of a document's
/// outline drawn as a column of ticks). A line's colour and side are who sent it (one's own in the accent from the
/// right, each other person's in their own colour from the left, as their bubbles are), its length how fast the chat
/// was going there (a long line is one of many within a few minutes, a short one stands alone), and the lines of what
/// is on the screen now are the bright ones.
///
/// The map has one size and one spacing: a line a message, [ChatRail.pitch] apart, whatever the chat's length. Where
/// the chat has more lines than the map has room for, the map shows a part of it and is itself scrolled, kept on the
/// part of the chat that is on the screen, as a frame on it (Matt, 2026-11-25: "dont change the main size of the
/// chatmap scroll it up and down as we go back through history"; 2026-11-26: "have it scroll up and down like there is a
/// frame of chat history we're viewing").
///
/// It swells where a finger is on it or a mouse is over it, as the Mac's Dock does (Matt, 2026-11-26: "Bring back the
/// magnifying effect when scrolling through the chat map"), the swell following the pointer with a little lag.
///
/// What it does, since its second making (Matt, 2026-11-26: "when clicking something far up it doesn't go all the way
/// to the message because it's still loading i assume and it's overall still kind of glitchy and i can't click and drag
/// through it, please keep the same looks but do a revamp to make it far more performant and smooth"; and of the held
/// drag: "it scrolls in reverse when touching holding and scrolling"):
///
///  * A press on a line goes to that message: the chat is put near it at once and run in the last of the way, and
///    within a quarter of a second the message is in the middle of the screen, exactly (at once, with motion
///    reduced), and stays there while pictures under it load. The chat's list does this itself now
///    (lib/ui/chat_rows.dart): the map used to guess where a row it could not see was, look again a frame later and
///    guess again, fourteen times at most, and among rows of very different heights the guesses went back and forth
///    and ended a screen or more away.
///  * A mouse's button held on it, or a finger held still for [holdFor], takes hold of the chat: drawn along the map,
///    the chat goes to the message whose line is under the pointer, a message a line. UP the map is OLDER, as the map
///    is drawn. The map stays where it is while held, so the same line is never under the pointer twice, and rolls on
///    only when the pointer has held it a moment near its top or its foot, so one hold goes through the whole chat.
///    Let go, it glides back to its frame.
///  * A wheel, two fingers on a trackpad, or a finger drawn over it at once scroll the chat as they do over the chat
///    itself.
///
/// It no longer opens into a list of the chat's stretches (Matt, 2026-11-25: "Lets remove the popover for the
/// summarized messages on the chat map for now"). The list is in this file as of commit 5cf3f3780, to be brought back
/// from there; what it was made from, [ChatRail.stretchesOf], is kept here with its tests for when it comes back.
library;

import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show Drag, GestureBinding, LongPressGestureRecognizer, PointerDeviceKind, PointerScrollEvent, PointerScrollInertiaCancelEvent, TapGestureRecognizer, VerticalDragGestureRecognizer, kPrimaryButton;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../summaries.dart';
import 'chat_rows.dart';
import 'dialup/bevel.dart' show isBevelChrome;

/// One message, as the map needs it.
@immutable
class RailMark {
  const RailMark({required this.at, required this.who, required this.mine, this.name = '', this.text = '', this.quiet = false});

  /// When it was sent, in milliseconds.
  final int at;

  /// Who sent it, by anything that tells senders apart (an address, an id); a face is asked for by it.
  final String who;
  final bool mine;

  /// Their name as the chat shows it.
  final String name;

  /// Its words, for a stretch's line.
  final String text;

  /// Something that happened, not something said (a join, a pin): a faint line, and no part of a summary.
  final bool quiet;
}

/// One line of the map: one message, or several where there are more messages than lines.
@immutable
class RailTick {
  const RailTick({required this.who, required this.mine, required this.rate, required this.quiet});

  /// Who sent most of what it stands for.
  final String who;
  final bool mine;

  /// How fast the chat was going there, 0 (one message alone) to 1 (many within minutes).
  final double rate;
  final bool quiet;
}

/// A stretch of a chat: what was said without a long pause.
@immutable
class RailStretch {
  const RailStretch({required this.newest, required this.oldest, required this.people, required this.opening, required this.lines});

  /// Where it is in the chat's messages, newest first: from [newest] to [oldest], both in it.
  final int newest, oldest;

  /// Who wrote in it, whoever wrote most first: (who, name, mine).
  final List<({String who, String name, bool mine})> people;

  /// How it began: "Maya: are we still on for Friday".
  final String opening;

  /// The stretch as a model reads a conversation, oldest first, `<name>: <words>` a line; empty where there is too
  /// little to sum up.
  final String lines;

  int get count => oldest - newest + 1;
}

class ChatRail extends StatefulWidget {
  const ChatRail({super.key, required this.controller, required this.marks, required this.child, this.chat = '', this.face, this.summarize, this.lead = 0});

  /// How many rows the list has before the first of [marks] (messages still going up, at a space's foot): a mark's
  /// row in the list is its place in [marks] and these.
  final int lead;

  /// The list's own controller, on a list drawn bottom up.
  final ScrollController controller;

  /// The chat's messages, newest first, as its list has them.
  final List<RailMark> marks;

  /// The chat, by anything that tells it from another: another chat's map starts at its foot.
  final String chat;

  /// Someone's face at a size, and what sums a stretch up ([RailStretch.lines]): for the list of stretches, which is
  /// put away for now, so neither is asked for. Kept so the chats that give them need not change when it is back.
  final Widget Function(String who, String name, bool mine, double size)? face;
  final Future<String?> Function(String lines)? summarize;

  /// The chat's list, a [ChatListView]: the map asks it which rows are on the screen and sends it to a row.
  final Widget child;

  /// Fewer messages than this have no map: there is nothing to find one's way in.
  static const fewest = 12;

  /// How wide the map's lines are drawn: twice what they were, as everything of the map's is (Matt, 2026-11-25: "make the
  /// chat map twice as big").
  static const double width = 24;

  /// The room either side of the map, so it is not flush against the window's edge or the bubbles (Matt, 2026-11-25:
  /// "add a little padding on the left and right of the chat map so it's not flush against the edge").
  static const double edge = 7;

  /// The gutter a chat's list keeps at its right for the map: its list's right padding (Matt, 2026-11-25: "add a
  /// little bit of space for a gutter on the right hand side of the chats in order to render this").
  static const double gutter = width + edge * 2;

  /// The space from one line to the next, always (Matt, 2026-11-25: "dont change the main size of the chatmap"; and
  /// 2026-11-26, after they were drawn larger for a day: "i don't want the actual chat map to be physically larger
  /// from what it was before the actual size was good").
  static const double pitch = 6;

  /// How thick a line is.
  static const double thick = 3.2;

  /// How much a line is magnified [d] away from the finger or pointer: [magnifyMost] times under it, falling away over
  /// about [magnifyReach], as the Dock's icons do.
  static const double magnifyMost = 2.4, magnifyReach = 44;
  static double magnifyAt(double d, [double amount = 1]) => 1 + (magnifyMost - 1) * amount * math.exp(-(d * d) / (2 * _sigma * _sigma));
  static const double _sigma = magnifyReach / 2;

  /// Where a line [d] from the swell's middle goes, swollen by [amount] (0 to 1): the room each line takes grows as it
  /// is magnified, worked as a whole (the sum of [magnifyAt] from the middle out), so every line moves smoothly as the
  /// swell moves, never one jumping as another comes under the pointer. The line under the middle stays where it is,
  /// and those far off are pushed out by [swellPush] at most.
  static double swollen(double d, [double amount = 1]) => d + swellPush * amount * _erf(d / (_sigma * math.sqrt2));

  /// The most a swell pushes a line: (magnifyMost - 1) * sigma * sqrt(pi / 2).
  static const double swellPush = (magnifyMost - 1) * _sigma * 1.2533141373155;

  /// How far a swollen line can be drawn past the map's own box: out of its left side toward the chat, and half its
  /// thickness past its top and foot. The map is painted in a box that much larger ([RailPainter]), so nothing of it is
  /// drawn outside what is painted by itself.
  static const double spill = 32, spillTall = 4;

  /// And past its right side: the round end of one's own line, swollen, reaches a pixel past the map's box there.
  static const double spillRight = 4;

  /// The error function, to within 1.5e-7 (Abramowitz and Stegun 7.1.26).
  static double _erf(double x) {
    final sign = x < 0 ? -1.0 : 1.0;
    final a = x.abs(), t = 1 / (1 + 0.3275911 * a);
    final y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-a * a);
    return sign * y;
  }

  /// How much of the chat's height the map may take, and its most.
  static const double share = 0.9, tallest = 680;

  /// A line's length, from one message alone to the busiest.
  static const double shortest = 8, longest = 18;

  /// Messages this near in time count toward how fast the chat was going.
  static const int near = 5 * 60 * 1000;

  /// This many near a message is as fast as the map shows.
  static const int busiest = 8;

  /// The most stretches a chat is cut into.
  static const int mostStretches = 12;

  /// How long a finger is held still on the map before it takes hold of the chat. A mouse's button takes hold at once:
  /// a mouse does not scroll by dragging, so there is nothing for it to be told apart from (Matt, 2026-11-26: "i can't
  /// click and drag through it").
  static const holdFor = Duration(milliseconds: 300);

  /// A pointer holding the map this near its top or its foot (or past it) rolls the map on, so a hold goes through
  /// the whole chat; and how fast, in lines a second: [rollLeast] at the zone's start, [rollAtEdge] at the map's edge,
  /// more past it, [rollMost] at most.
  static const double rollZone = 36;
  static const double rollLeast = 12, rollAtEdge = 90, rollMost = 240;

  /// How fast the map rolls with the pointer [into] the zone: 0 at its start, 1 at the map's edge, more past it.
  static double rollRate(double into) => into <= 0 ? 0 : math.min(rollMost, rollLeast + (rollAtEdge - rollLeast) * into * into);

  /// A press runs the chat in to its message over this long, from no further than [runway] off: a chat sent far is
  /// put near at once and only the last of the way is run, as the arrow back to the newest does.
  static const runFor = Duration(milliseconds: 240);
  static const double runway = 360;

  /// The lines for [marks] (newest first) in [rows] rows, the newest first.
  static List<RailTick> ticksOf(List<RailMark> marks, int rows) {
    final n = marks.length;
    if (n == 0 || rows <= 0) return const [];
    // How many others are within [near] of each: two pointers down a list in time's order (newest first).
    final rate = List<double>.filled(n, 0);
    var lo = 0, hi = 0;
    for (var i = 0; i < n; i++) {
      while (marks[lo].at - marks[i].at > near) {
        lo++;
      }
      if (hi < i) hi = i;
      while (hi + 1 < n && marks[i].at - marks[hi + 1].at <= near) {
        hi++;
      }
      rate[i] = ((hi - lo) / busiest).clamp(0.0, 1.0);
    }
    if (n <= rows) return [for (var i = 0; i < n; i++) RailTick(who: marks[i].who, mine: marks[i].mine, rate: rate[i], quiet: marks[i].quiet)];
    return [
      for (var r = 0; r < rows; r++)
        () {
          final from = r * n ~/ rows, to = math.max(from + 1, (r + 1) * n ~/ rows);
          final by = <String, int>{};
          var sum = 0.0, quiet = true;
          for (var i = from; i < to; i++) {
            sum += rate[i];
            if (marks[i].quiet) continue;
            quiet = false;
            by[marks[i].who] = (by[marks[i].who] ?? 0) + 1;
          }
          var who = marks[from].who;
          var best = 0;
          by.forEach((k, v) {
            if (v > best) (who, best) = (k, v);
          });
          final of = marks.sublist(from, to).firstWhere((m) => m.who == who, orElse: () => marks[from]);
          return RailTick(who: who, mine: of.mine, rate: sum / (to - from), quiet: quiet);
        }(),
    ];
  }

  /// The pauses a chat is cut into stretches at, the shortest first: the first that leaves few enough is used.
  static const _pauses = [20, 60, 3 * 60, 8 * 60, 24 * 60, 3 * 24 * 60, 7 * 24 * 60, 30 * 24 * 60];

  /// [marks] (newest first) as stretches, the newest first, [most] at most.
  static List<RailStretch> stretchesOf(List<RailMark> marks, {int most = mostStretches}) {
    final n = marks.length;
    if (n == 0) return const [];
    List<int> cuts(int minutes) => [
          for (var i = 1; i < n; i++)
            if (marks[i - 1].at - marks[i].at > minutes * 60 * 1000) i,
        ];
    var starts = <int>[];
    var found = false;
    for (final p in _pauses) {
      starts = cuts(p);
      if (starts.length < most) {
        found = true;
        break;
      }
    }
    // A chat with no pause long enough to cut at that few: even shares of it.
    if (!found) starts = [for (var k = 1; k < most; k++) k * n ~/ most];
    final edges = [0, ...starts, n];
    return [
      for (var k = 0; k + 1 < edges.length; k++)
        if (edges[k + 1] > edges[k]) _stretch(marks, edges[k], edges[k + 1] - 1),
    ];
  }

  static RailStretch _stretch(List<RailMark> marks, int newest, int oldest) {
    final by = <String, ({String who, String name, bool mine, int n})>{};
    RailMark? first;
    final said = <RailMark>[];
    for (var i = oldest; i >= newest; i--) {
      final m = marks[i];
      if (m.quiet) continue;
      final had = by[m.who];
      by[m.who] = (who: m.who, name: m.name, mine: m.mine, n: (had?.n ?? 0) + 1);
      if (m.text.trim().isEmpty) continue;
      first ??= m;
      said.add(m);
    }
    final people = by.values.toList()..sort((a, b) => b.n.compareTo(a.n));
    String words(RailMark m) => m.text.replaceAll('\n', ' ').trim();
    String name(RailMark m) => m.mine ? 'You' : (m.name.trim().isEmpty ? 'Them' : m.name.trim());
    // Worth a summary: a few things said, or one long one.
    final enough = said.length >= 3 || said.any((m) => m.text.trim().length >= Summaries.long);
    return RailStretch(
      newest: newest,
      oldest: oldest,
      people: [for (final p in people) (who: p.who, name: p.name, mine: p.mine)],
      opening: first == null ? '' : '${name(first)}: ${words(first)}',
      // The newest forty of a long stretch: what a small model can read at once.
      lines: !enough ? '' : [for (final m in said.length > 40 ? said.sublist(said.length - 40) : said) '${name(m)}: ${words(m)}'].join('\n'),
    );
  }

  @override
  State<ChatRail> createState() => _ChatRailState();
}

class _ChatRailState extends State<ChatRail> with TickerProviderStateMixin {
  bool _live = false;

  /// The chat's list, found once it is laid out and kept while it is on the page.
  RenderChatRows? _rows;

  ScrollController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _ease = createTicker(_easeOn);
    _roll = createTicker(_rollOn);
    _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    // The chat is sent at each step of the run in, in the frame of the step (and once more as it ends, to where it
    // rests): asked for a frame later, the chat stood still for the run's first frame.
    _run = AnimationController(vsync: this, duration: ChatRail.runFor)
      ..addListener(() {
        if (_run.isAnimating) _go();
      })
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _go();
      });
    _measureSoon();
  }

  @override
  void didUpdateWidget(ChatRail old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, _c)) _rows = null;
    if (old.chat != widget.chat) {
      _rows = null;
      _at = 0;
      _ticksOf = null;
      _newest = null;
      _glide.value = 1;
      _letGo();
      _to = null;
      _run.stop();
    }
    _measureSoon();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _pan?.cancel();
    _rollArm?.cancel();
    _ease.dispose();
    _roll.dispose();
    _glide.dispose();
    _run.dispose();
    _focus.dispose();
    _frame.dispose();
    super.dispose();
  }

  /// The map's lines and the people's colours, kept until the messages change: a build asks for them each time, and
  /// they are a pass over every message.
  (int, int, int)? _ticksOf;
  List<RailTick> _ticks = const [];
  List<String> _others = const [];

  /// The newest message as the lines were last made, to find it by when more have come.
  RailMark? _newest;

  /// The same message, as far as the map can tell. (Not by its time alone: a network that dates to the second gives
  /// two messages in one second the same time, and the one that came was not counted.)
  static bool _same(RailMark a, RailMark b) => a.at == b.at && a.who == b.who && a.mine == b.mine && a.quiet == b.quiet && a.text == b.text;

  void _lines() {
    final m = widget.marks;
    final now = (m.length, m.isEmpty ? 0 : m.first.at, m.isEmpty ? 0 : m.last.at);
    final was = _newest;
    if (_ticksOf == now && (was == null || m.isEmpty || _same(m.first, was))) return;
    final had = _ticksOf;
    if (had != null && had.$1 > 0 && m.isNotEmpty) {
      // New messages at the foot: every message is that many lines further up the chat. The map goes up with them, so
      // no line moves on it, and what is held (a message under the pointer, a message gone to) is still that message;
      // the chat's list keeps the row it holds on that message by itself (lib/ui/chat_rows.dart, idOf). The map used
      // to glide from where it was, which drew every line a step up and brought it down again.
      var fresh = 0;
      if (was != null) {
        final grew = now.$1 - had.$1;
        if (grew > 0 && grew <= 64 && grew < m.length && _same(m[grew], was)) {
          fresh = grew;
        } else if (!_same(m.first, was)) {
          for (var i = 1; i < m.length && i <= 64; i++) {
            if (_same(m[i], was)) {
              fresh = i;
              break;
            }
          }
        }
      }
      if (fresh > 0) {
        final by = fresh * ChatRail.pitch;
        _at += by;
        if (_gripAt != null) _gripAt = _gripAt! + by;
        final g = _grip;
        if (g != null) _grip = (at: g.at + by, y: g.y, line: g.line + fresh);
        if (_to != null) _to = _to! + fresh;
      }
      // More messages in the same chat: the map may now go where it could not, and glides there rather than jumping.
      if (had.$1 != now.$1 && !context.tokens.reducedMotion) {
        _glideFrom = _at;
        _glide.forward(from: 0);
      }
      // Held at the map's end with nothing further to roll to, and now there is (older messages read in).
      if (had.$1 != now.$1) _rollIfDue();
    }
    _ticksOf = now;
    _newest = m.isEmpty ? null : m.first;
    // A line a message, however many.
    _ticks = ChatRail.ticksOf(m, m.length);
    _others = {for (final x in m) if (!x.mine && !x.quiet) x.who}.toList()..sort();
  }

  /// Looks again, once this frame is laid out, at whether there is a map ([_measure]): once a frame however often it
  /// is asked (the list says its length has changed at every frame of some scrolls).
  bool _measures = false;

  void _measureSoon() {
    if (_measures) return;
    _measures = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measures = false;
      _measure();
    });
  }

  /// There is a map where there is a chat to find one's way in: enough messages, and more of them than a screen.
  void _measure() {
    if (!mounted) return;
    var rows = _rows;
    if (rows != null && !rows.attached) rows = null;
    if (rows == null && _c.hasClients) rows = RenderChatRows.under(_c.position);
    final live = rows != null && widget.marks.length >= ChatRail.fewest && _c.hasClients && _c.position.hasContentDimensions && _c.position.maxScrollExtent > 40;
    if (!live && _live) _drop();
    if (live != _live || !identical(rows, _rows)) {
      setState(() {
        _live = live;
        _rows = rows;
      });
    }
  }

  /// The map is off the page (too few messages for one now, its list gone, another look): whatever held it has let
  /// go, as far as it can know. Its gestures went with it, and a button let go meanwhile is never heard of: it came
  /// back still held, standing still while the chat scrolled, its swell up with nothing over it.
  void _drop() {
    _mouse = false;
    _touching.clear();
    _letGo();
    _to = null;
    _run.stop();
    _glide.value = 1;
    _target = null;
    _ease.stop();
    _focus.value = null;
  }

  /// Whether the map was drawn at the last build.
  bool _shown = false;

  /// Which of the messages are on the screen: from how many messages up from the newest to how many, parts of a
  /// message counted (2.5 is half way up the third), so the map moves with the chat and not a line at a time. As the
  /// chat's list last laid them out; by the scroll's share of its whole length until it has. Pulled past an end, as a
  /// phone's list can be, the chat is still at that end here.
  (double, double) _view() {
    final n = widget.marks.length;
    final rows = _rows;
    final seen = rows != null && rows.attached ? rows.view : null;
    if (seen != null) return ((seen.lo - widget.lead).clamp(0.0, n.toDouble()), (seen.hi - widget.lead).clamp(0.0, n.toDouble()));
    if (n == 0 || !_c.hasClients || !_c.position.hasContentDimensions) return (0, n.toDouble());
    final p = _c.position;
    final whole = p.maxScrollExtent + p.viewportDimension;
    if (whole <= 0) return (0, n.toDouble());
    final at = p.pixels.clamp(0.0, p.maxScrollExtent);
    return (at / whole * n, (at + p.viewportDimension) / whole * n);
  }

  /// How far the map itself is scrolled: how much of its lines is below its foot, nothing with the newest message's
  /// line at the foot. Counted from the newest end, as the chat's own scroll is, so older messages loaded in at the
  /// top move no line.
  double _at = 0;

  /// How tall the map is, as last built.
  double _tall = 0;

  /// The least and most the map can be scrolled, [tall] high: at rest at either end of the chat, and a chat whose
  /// lines don't fill it has them in its middle, not at its foot (Matt, 2026-11-26: "center the chat map on right
  /// side").
  (double, double) _ends(double tall) {
    final whole = widget.marks.length * ChatRail.pitch;
    final double least = whole < tall ? -(tall - whole) / 2 : 0.0;
    return (least, math.max(least, whole - tall));
  }

  /// Where the map is now, [tall] high, and what of the chat is on the screen ([_view]). The lines of what is on the
  /// screen are kept in the map's middle, so the map moves with the chat as a frame on it, as smoothly as the chat
  /// does; at either end of the chat it rests at its own end. While a pointer holds the map it stays where it was
  /// taken hold of ([_gripAt]). Asked at every paint.
  ({double lo, double hi, double at}) _place(double tall) {
    final (lo, hi) = _view();
    final (least, most) = _ends(tall);
    final held = _gripAt;
    double at;
    if (held != null) {
      at = _gripAt = held.clamp(least, most);
    } else {
      at = ((lo + hi) / 2 * ChatRail.pitch - tall / 2).clamp(least, most);
      if (_glide.isAnimating) {
        if ((at - _glideFrom).abs() < 0.01) {
          // Nowhere to glide to (a message came while far back, the map let go of where it belongs): twenty frames of
          // painting the same thing.
          _glide.stop();
        } else {
          at = _glideFrom + (at - _glideFrom) * Curves.easeOutCubic.transform(_glide.value);
        }
      }
    }
    return (lo: lo, hi: hi, at: _at = at);
  }

  /// Where the map was when more messages came in or it was let go of, and its glide from there to where it belongs.
  double _glideFrom = 0;
  late final AnimationController _glide;

  /// Painted again when this changes: the map rolled under a pointer that has not moved.
  final ValueNotifier<int> _frame = ValueNotifier(0);

  // ---- Going to a message -------------------------------------------------------------------------------------------

  /// The line being gone to (a message, parts of it counted: where a hold was let go is seldom a message's middle),
  /// until the chat is there; and whether the list has been told yet (after which, its letting go of the row means
  /// something else has moved the chat, and the going is given up).
  double? _to;
  bool _told = false;

  /// The run in to a message: how far off the chat started ([_runFrom], no more than [ChatRail.runway]), brought to
  /// nothing over [ChatRail.runFor].
  late final AnimationController _run;
  double _runFrom = 0;

  /// Sends the chat to [line] (39 is the fortieth message's middle in the screen's middle). The list puts it there
  /// itself, whether or not the row was ever built, and keeps it there while what is round it loads
  /// (lib/ui/chat_rows.dart).
  void _goTo(double line) {
    final rows = _rows;
    final n = widget.marks.length;
    if (rows == null || !rows.attached || n == 0 || !_c.hasClients) return;
    final to = _to = line.clamp(-0.499, n - 0.501);
    _told = false;
    final row = to.round();
    final still = context.tokens.reducedMotion;
    // From where it is, or from a little way off if it is far: only the last of the way is seen.
    final off = still ? 0.0 : (rows.scrolled - rows.placeOf(row + widget.lead, within: to - row + 0.5)).clamp(-ChatRail.runway, ChatRail.runway);
    if (off.abs() < 1) {
      _run.stop();
      _runFrom = 0;
    } else {
      _runFrom = off;
      _run.forward(from: 0);
    }
    // With nothing holding the map it goes to its frame on the new place as the chat does, not at a leap.
    if (_grip == null && !still) {
      _glideFrom = _at;
      _glide.forward(from: 0);
    }
    _go();
  }

  /// The chat is sent where it is wanted once a frame, however often the pointer moves in it.
  bool _goes = false;

  void _goSoon() {
    if (_goes) return;
    _goes = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _goes = false;
      // (While the run in is under way each of its steps sends the chat, this frame's too.)
      if (!_run.isAnimating) _go();
    });
  }

  void _go() {
    final rows = _rows;
    final n = widget.marks.length;
    if (!mounted || rows == null || !rows.attached || n == 0 || !_c.hasClients) return;
    final g = _grip;
    double line;
    if (g != null) {
      // Held: the message whose line is under the pointer now.
      line = _under(g);
    } else {
      final to = _to;
      if (to == null) return;
      // Sent by a press, and since moved by something else (a wheel, a finger on the chat): theirs now.
      if (_told && (rows.held == null || rows.strayed(_c.position))) {
        _to = null;
        _run.stop();
        return;
      }
      line = to;
    }
    line = line.clamp(-0.499, n - 0.501);
    final mark = line.round();
    if (g != null && mark != _ticked) {
      _ticked = mark;
      // A tick at a message under a finger, but not one for each of a hundred crossed in a second.
      final now = DateTime.now();
      if (_byTouch && now.difference(_tickedAt).inMilliseconds >= 40) {
        _tickedAt = now;
        unawaited(HapticFeedback.selectionClick());
      }
    }
    final shift = _run.isAnimating ? _runFrom * (1 - Curves.easeOutCubic.transform(_run.value)) : 0.0;
    // A line is a message from its foot to its top: the pointer half way to the next line is the row's top in the
    // screen's middle, which is the next row's foot.
    rows.hold(_c.position, mark + widget.lead, within: line - mark + 0.5, shift: shift);
    _told = true;
    if (g == null && !_run.isAnimating) {
      _to = null;
      // Brought to the newest end, the chat is the chat again: held there, it stayed on its row as messages came,
      // and they came in under the foot, unseen.
      final p = _c.position;
      if (p.hasContentDimensions && p.pixels <= p.minScrollExtent + 0.5) rows.release();
    }
  }

  /// The line under the pointer that holds the map: up the map is older; and the map rolled on under a pointer that
  /// is still has brought another line under it.
  double _under(({double at, double y, double line}) g) => g.line + (g.y - _gripY) / ChatRail.pitch + ((_gripAt ?? g.at) - g.at) / ChatRail.pitch;

  // ---- Scrolling the chat from over the map ------------------------------------------------------------------------

  /// A wheel turned over the map scrolls the chat, as it would over the chat itself: the map stands over the chat's
  /// list, which never hears the wheel there.
  void _wheel(PointerScrollEvent e) {
    if (!_c.hasClients || e.scrollDelta.dy == 0 || _grip != null) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (e) {
      // The chat's list is drawn bottom up, so a turn down the page is toward its start.
      if (_c.hasClients) _c.position.pointerScroll(-(e as PointerScrollEvent).scrollDelta.dy);
    });
  }

  /// Two fingers on a trackpad or a finger drawn over the map: the chat's own drag, with its glide after, and a
  /// finger put down stops a glide as it does on the chat (Matt, 2026-11-25: "just allow scrolling normally"). Not a
  /// mouse, which does not drag the chat either.
  Drag? _pan;
  ScrollHoldController? _hold;

  // ---- The swell ----------------------------------------------------------------------------------------------------

  /// Where down the map the swell is drawn and how far it has come up (0 to 1), if there is one: the lines round it
  /// are drawn larger and further apart, as the Dock swells under the pointer. It follows [_target] at a short lag
  /// ([_easeOn]), so a mouse's every little movement is not drawn.
  final ValueNotifier<({double y, double amount})?> _focus = ValueNotifier(null);

  /// Where a finger is on the map or a mouse over it, if one is; the swell goes when it is lifted or leaves.
  double? _target;
  bool _byTouch = false;
  late final Ticker _ease;
  Duration _eased = Duration.zero;

  /// How long the swell takes to get most of the way to the pointer (a mouse; a finger's is shorter, as the lines
  /// under it are moving with the chat), and to come up or go.
  static const _lagMouse = 0.07, _lagTouch = 0.03, _lagAmount = 0.09;

  void _aim(double? y, {bool touch = false}) {
    // (A finger still down when the page goes is still heard by what it went down on.)
    if (!mounted) return;
    _target = y;
    if (y != null) _byTouch = touch;
    if (context.tokens.reducedMotion) {
      _focus.value = y == null ? null : (y: y, amount: 1);
      return;
    }
    if (y != null && _focus.value == null) _focus.value = (y: y, amount: 0);
    if (!_ease.isActive) {
      _eased = Duration.zero;
      _ease.start();
    }
  }

  void _easeOn(Duration now) {
    final dt = (now - _eased).inMicroseconds / 1e6;
    _eased = now;
    final f = _focus.value;
    if (f == null) {
      _ease.stop();
      return;
    }
    double toward(double from, double to, double lag) => from + (to - from) * (1 - math.exp(-dt / lag));
    final t = _target;
    final y = t == null ? f.y : toward(f.y, t, _byTouch ? _lagTouch : _lagMouse);
    final amount = toward(f.amount, t == null ? 0 : 1, _lagAmount);
    if (t == null && amount < 0.01) {
      _focus.value = null;
      _ease.stop();
      return;
    }
    _focus.value = (y: y, amount: amount);
    if (t != null && (y - t).abs() < 0.2 && amount > 0.99) {
      _focus.value = (y: t, amount: 1);
      _ease.stop();
    }
  }

  /// The fingers on the map now, by pointer: the swell is under the last one put down.
  final Set<int> _touching = {};

  void _lift(int pointer) {
    if (_touching.remove(pointer) && _touching.isEmpty && !_mouse) _aim(null);
  }

  // ---- Taking hold of the chat --------------------------------------------------------------------------------------

  /// While a pointer holds the map (a mouse's button down on it, a finger held on it): how far the map was scrolled
  /// when it took hold, where the pointer was, and which message's line it took hold of. The chat is then at the
  /// message whose line is under the pointer, wherever along the map it is drawn (Matt, 2026-11-26: "i'd like to be
  /// able to tap and hold to initate the scrolling mechanic and click and hold as well"; "i can't click and drag
  /// through it"). Up the map is older, as the map is drawn: it went the other way once, the lines following the
  /// finger (Matt, the same day: "it scrolls in reverse when touching holding and scrolling").
  ({double at, double y, double line})? _grip;

  /// Where the pointer holding the map is now, down the map; whether it has been drawn along at all; and the message
  /// last under it, for a tick at each.
  double _gripY = 0;
  bool _drawn = false;
  int? _ticked;
  DateTime _tickedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// How far the map is scrolled while held: where it was taken hold of, rolled on at its ends ([_rollOn]). Null while
  /// nothing holds it, and the map follows the chat.
  double? _gripAt;

  /// A mouse's button holds the map.
  bool _mouse = false;

  /// The swell is put on the pointer, with no lag, while a pointer presses or holds the map: where the swell's middle
  /// is, the line drawn under the pointer is the line that belongs there, and a line more along the map is a message
  /// more. Left to catch up, the lines round the pointer stood out of their places, and the chat was some messages
  /// from the line under it for as long as it moved.
  void _swellAt(double y, {required bool touch}) {
    _aim(y, touch: touch);
    final f = _focus.value;
    if (f != null && f.y != y) _focus.value = (y: y, amount: f.amount);
  }

  /// A pointer takes hold of the map at [y] down it: the chat goes to the message whose line is there, and from then
  /// on to whichever is under the pointer.
  void _take(double y, {required bool touch}) {
    // One thing at a time: not while a finger is scrolling the chat from over the map, nor twice.
    if (_rows == null || widget.marks.isEmpty || _pan != null || _grip != null) return;
    // The line drawn there now, though it be past either end of the chat's lines (a chat too short to fill the map
    // has room over and under them): drawn on from there, the pointer is on a line when the chat is at its message.
    final drawn = _lineAt(y);
    final line = drawn.roundToDouble();
    // Then the swell on the pointer, and the map moved by as much as the swell had that line out of its place (a
    // mouse pressed while still moving has the swell some way behind it): the line pressed is still the one under the
    // pointer, and stays so.
    _swellAt(y, touch: touch);
    final (least, most) = _ends(_tall);
    final at = (y - _tall + (drawn + 0.5) * ChatRail.pitch).clamp(least, most);
    _grip = (at: at, y: y, line: line);
    _gripAt = at;
    _gripY = y;
    _drawn = false;
    _ticked = _markAt(y);
    if (touch) unawaited(HapticFeedback.selectionClick());
    // It rolls only once held a moment, moved or not: a press at the map's top that slipped a pixel rolled it some
    // lines on, and a button held quite still there never rolled it. (A finger has held it that long already.)
    _rollArm?.cancel();
    _rolls = touch;
    if (!touch) {
      _rollArm = Timer(ChatRail.holdFor, () {
        _rolls = true;
        _rollIfDue();
      });
    }
    _goTo(line);
    _rollIfDue();
  }

  /// The pointer holding the map is now at [y] down it.
  void _draw(double y, {required bool touch}) {
    if (_grip == null) return;
    final moved = y != _gripY;
    if (moved) _drawn = true;
    _gripY = y;
    _swellAt(y, touch: touch);
    _rollIfDue();
    // (Moved sideways only, the chat is where it was.)
    if (moved) _goSoon();
  }

  /// The pointer lets go: the map glides back to its frame on what is on the screen, and the chat goes on to where it
  /// was brought, the list still holding that message in its place until the chat is next scrolled.
  void _letGo() {
    final g = _grip;
    if (g == null) return;
    final n = widget.marks.length;
    // Drawn along: what is left of the run in goes on, to the line let go on. (It was stopped where it stood: a press
    // that slipped a pixel and was let go at once left the chat most of a screen short of its message.) Only
    // pressed: it goes on to the message pressed.
    if (_drawn && n > 0) _to = _under(g).clamp(-0.499, n - 0.501);
    _grip = null;
    _gripAt = null;
    _ticked = null;
    _rollArm?.cancel();
    _rolls = false;
    _roll.stop();
    if (mounted && !context.tokens.reducedMotion) {
      _glideFrom = _at;
      _glide.forward(from: 0);
    }
    _frame.value++;
    // Once more, where it is to rest: the list is told, and at the newest end is let go.
    _goSoon();
  }

  /// The map rolls on while the pointer holding it is near its top or its foot, or past them, so one hold goes
  /// through the whole chat: toward older messages at the top, newer at the foot, faster the further in.
  late final Ticker _roll;
  Duration _rolled = Duration.zero;

  /// Whether the hold has lasted long enough to roll, and what waits for that.
  bool _rolls = false;
  Timer? _rollArm;

  /// How fast the map is to roll now, in lines a second: over 0 toward older messages.
  double _rollBy() {
    if (_grip == null || !_rolls || _tall <= 0) return 0;
    if (_gripY < ChatRail.rollZone) return ChatRail.rollRate((ChatRail.rollZone - _gripY) / ChatRail.rollZone);
    if (_gripY > _tall - ChatRail.rollZone) return -ChatRail.rollRate((_gripY - (_tall - ChatRail.rollZone)) / ChatRail.rollZone);
    return 0;
  }

  /// Starts the roll where it is due and has somewhere to go.
  void _rollIfDue() {
    if (!mounted || _roll.isActive) return;
    final by = _rollBy(), at = _gripAt;
    if (by == 0 || at == null) return;
    final (least, most) = _ends(_tall);
    if (by > 0 ? at >= most : at <= least) return;
    _rolled = Duration.zero;
    _roll.start();
  }

  void _rollOn(Duration now) {
    final dt = (now - _rolled).inMicroseconds / 1e6;
    _rolled = now;
    final by = mounted ? _rollBy() : 0.0;
    final at = _gripAt;
    if (by == 0 || at == null) {
      _roll.stop();
      return;
    }
    if (dt <= 0) return;
    final (least, most) = _ends(_tall);
    final next = (at + by * ChatRail.pitch * dt).clamp(least, most);
    if (next == at) {
      // At an end: nothing to do until there is more (older messages read in start it again, [_lines]), and no frame
      // asked for meanwhile.
      _roll.stop();
      return;
    }
    _gripAt = next;
    _drawn = true;
    _frame.value++;
    _go();
  }

  /// Which message's line is drawn at [y] down the map, swollen as it is, parts of a line counted: 39 is the middle
  /// of the fortieth line from the newest, 39.5 half way to the next.
  double _lineAt(double y) {
    final f = _focus.value;
    var base = y;
    if (f != null) {
      // Back through the swell: where the line drawn at [y] would be without it.
      final d = y - f.y;
      var lo = d - ChatRail.swellPush - 1, hi = d + ChatRail.swellPush + 1;
      for (var k = 0; k < 40; k++) {
        final mid = (lo + hi) / 2;
        if (ChatRail.swollen(mid, f.amount) < d) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      base = (lo + hi) / 2 + f.y;
    }
    return (_at + _tall - base) / ChatRail.pitch - 0.5;
  }

  /// The message whose line is drawn nearest [y] down the map.
  int _markAt(double y) {
    final n = widget.marks.length;
    return n == 0 ? 0 : _lineAt(y).round().clamp(0, n - 1);
  }

  static const _fingers = {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus, PointerDeviceKind.unknown};

  /// The map's gestures. A mouse's button down on it takes hold at once and every move of it is followed (it is alone
  /// among the mouse's gestures here, so it has the press from the start; were anything over the map to want a
  /// mouse's drag too, the two would be told apart by the usual slop). A finger's press goes to the message, held
  /// still for [ChatRail.holdFor] it takes hold, and drawn at once it scrolls the chat; a trackpad's two fingers
  /// scroll. Each gets the device's own slop, as the chat's list does.
  Widget _gestures(BuildContext context, Widget child) {
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    final behaviour = ScrollConfiguration.of(context);
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          _wheel(e);
        } else if (e is PointerScrollInertiaCancelEvent && _c.hasClients) {
          // Fingers rested on a trackpad stop the chat's glide, as they do over the chat.
          _c.position.pointerScroll(0);
        }
      },
      onPointerHover: (e) {
        if (_touching.isEmpty && !_mouse) _aim(e.localPosition.dy);
      },
      onPointerDown: (e) {
        if (!_fingers.contains(e.kind)) return;
        _touching.add(e.pointer);
        if (_grip == null) _aim(e.localPosition.dy, touch: true);
      },
      onPointerMove: (e) {
        if (_touching.contains(e.pointer) && _grip == null) _aim(e.localPosition.dy, touch: true);
      },
      onPointerUp: (e) => _lift(e.pointer),
      onPointerCancel: (e) => _lift(e.pointer),
      child: RawGestureDetector(
        key: const ValueKey('chat-rail'),
        behavior: HitTestBehavior.opaque,
        gestures: {
          _MouseHold: GestureRecognizerFactoryWithHandlers<_MouseHold>(
            _MouseHold.new,
            (r) => r
              ..gestureSettings = settings
              ..onDown = (d) {
                _mouse = true;
                _take(d.localPosition.dy, touch: false);
              }
              ..onUpdate = ((d) => _draw(d.localPosition.dy, touch: false))
              ..onEnd = ((d) => _mouseUp(d.localPosition))
              ..onCancel = (() => _mouseUp(null)),
          ),
          // A finger's press goes to the message pressed. Not one put down to stop the chat gliding: over the chat
          // that presses nothing either.
          TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(supportedDevices: _fingers),
            (r) => r
              ..gestureSettings = settings
              ..onTapUp = (d) {
                if (!_stopped) _goTo(_markAt(d.localPosition.dy).toDouble());
              },
          ),
          // Held still, then drawn along: the chat taken hold of. Not a trackpad's two fingers, which scroll.
          LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(duration: ChatRail.holdFor, supportedDevices: _fingers),
            (r) => r
              ..gestureSettings = settings
              ..onLongPressStart = ((d) => _take(d.localPosition.dy, touch: true))
              ..onLongPressMoveUpdate = ((d) => _draw(d.localPosition.dy, touch: true))
              ..onLongPressEnd = ((_) => _letGo())
              ..onLongPressCancel = _letGo,
          ),
          VerticalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(supportedDevices: const {PointerDeviceKind.trackpad, ..._fingers}),
            (r) => r
              ..gestureSettings = settings
              // Its glide after, and its fingers counted, as the chat's own list has them.
              ..velocityTrackerBuilder = behaviour.velocityTrackerBuilder(context)
              ..multitouchDragStrategy = behaviour.getMultitouchDragStrategy(context)
              ..onDown = (d) {
                // Not under a finger that holds the map: a second finger scrolls nothing.
                if (_grip != null) return;
                _stopped = _c.hasClients && _c.position.isScrollingNotifier.value;
                _hold = _c.hasClients ? _c.position.hold(() => _hold = null) : null;
              }
              ..onStart = (d) {
                if (_grip != null) return;
                _pan?.cancel();
                // Beginning the drag ends the hold.
                _pan = _c.hasClients ? _c.position.drag(d, () => _pan = null) : null;
              }
              ..onUpdate = ((d) => _pan?.update(d))
              ..onEnd = ((d) => _pan?.end(d))
              ..onCancel = () {
                _hold?.cancel();
                _pan?.cancel();
              },
          ),
        },
        child: child,
      ),
    );
  }

  /// The finger now on the map came down while the chat was gliding, and stopped it.
  bool _stopped = false;

  /// The mouse's button is let go, at [at] if that is known.
  void _mouseUp(Offset? at) {
    if (!_mouse) return;
    _mouse = false;
    _letGo();
    // Still over the map, the swell stays under the pointer; let go somewhere else, it goes.
    final over = at != null && at.dy >= 0 && at.dy <= _tall && at.dx >= 0 && at.dx <= ChatRail.gutter;
    if (_touching.isEmpty) _aim(over ? at.dy : null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Not one that has left the page since it was found ([_measure] looks again once this frame is drawn).
    final rows = _rows != null && _rows!.attached ? _rows : null;
    // No map under Dial-Up, whose chat is a transcript: taken away under a pointer, it lets go as it goes.
    final shown = _live && !isBevelChrome(t);
    if (_shown && !shown && _live) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _drop();
      });
    }
    _shown = shown;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _measureSoon();
        return false;
      },
      child: Stack(children: [
        widget.child,
        if (shown)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: LayoutBuilder(builder: (context, box) {
              _lines();
              final ticks = _ticks, others = _others;
              // Its one size, a whole number of lines, however few the messages: once there are more lines than room
              // the map is scrolled.
              final height = _tall = (math.min(box.maxHeight * ChatRail.share, ChatRail.tallest) / ChatRail.pitch).floor() * ChatRail.pitch;
              return Center(
                widthFactor: 1,
                child: MouseRegion(
                  onExit: (_) {
                    if (_touching.isEmpty && !_mouse) _aim(null);
                  },
                  child: _gestures(context, Semantics(
                    label: 'Map of this chat',
                    container: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: ChatRail.edge),
                      child: SizedBox(
                        width: ChatRail.width,
                        height: height,
                        // Painted by itself: the map is painted at every frame of a scroll and of the pointer over it,
                        // and nothing else of the chat need be drawn again for that (the whole page was, header and
                        // composer and all). Its box is larger than the map by what a swell spills out of it, so all
                        // of it is inside what is painted.
                        child: OverflowBox(
                          // Its right edge [ChatRail.spillRight] past the map's, the rest of what it is wider by to the left.
                          alignment: const Alignment((ChatRail.spill - ChatRail.spillRight) / (ChatRail.spill + ChatRail.spillRight), 0),
                          minWidth: ChatRail.width + ChatRail.spill + ChatRail.spillRight,
                          maxWidth: ChatRail.width + ChatRail.spill + ChatRail.spillRight,
                          minHeight: height + ChatRail.spillTall * 2,
                          maxHeight: height + ChatRail.spillTall * 2,
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: RailPainter(
                                ticks: ticks,
                                tall: height,
                                place: _place,
                                focus: _focus,
                                repaint: Listenable.merge([_c, if (rows != null) rows.laid, _focus, _glide, _frame]),
                                mine: t.color('app-accent'),
                                theirs: t.color('app-ink-2'),
                                hues: others.length < 2 ? const {} : {for (var i = 0; i < others.length; i++) others[i]: t.colorOf(_hues[i % _hues.length])},
                                quiet: t.color('app-ink-3'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )),
                ),
              );
            }),
          ),
      ]),
    );
  }

  /// A few colours far apart, for telling the people of a group from one another; one's own is the accent.
  static const _hues = ['#e08a1e', '#3aa675', '#c45bd6', '#2aa7b8', '#d9534f', '#8a7be8'];
}

/// Draws the map's lines. Open to tests, which ask it where a message's line is.
@visibleForTesting
class RailPainter extends CustomPainter {
  RailPainter({required this.ticks, required this.tall, required this.place, required this.focus, required Listenable repaint, required this.mine, required this.theirs, required this.hues, required this.quiet}) : super(repaint: repaint);

  /// A line a message, the newest first.
  final List<RailTick> ticks;

  /// How tall the map is.
  final double tall;

  /// Which messages are on the screen and how far the map is scrolled, asked at each paint: the chat's scroll moves
  /// the map without a build.
  final ({double lo, double hi, double at}) Function(double tall) place;

  /// Where down the map the swell is and how far it has come up, if there is one.
  final ValueListenable<({double y, double amount})?> focus;
  final Color mine, theirs, quiet;
  final Map<String, Color> hues;

  /// How many lines past either end of the map are placed too: lines swollen near an end push lines in from past it.
  static final _spare = (ChatRail.swellPush / ChatRail.pitch).ceil() + 1;

  /// Where the line of message [mark] is drawn and how much it is magnified, with the map scrolled [at].
  ({double y, double grow}) _line(int mark, double at) {
    final base = tall - (mark + 0.5) * ChatRail.pitch + at;
    final f = focus.value;
    if (f == null) return (y: base, grow: 1);
    return (y: f.y + ChatRail.swollen(base - f.y, f.amount), grow: ChatRail.magnifyAt(base - f.y, f.amount));
  }

  /// How far down the map the line of message [mark] is now (the newest is 0), swollen or not; off the map where it
  /// is under 0 or over [tall].
  double yOf(int mark) => _line(mark, place(tall).at).y;

  /// How much the line of message [mark] is magnified now: 1 where nothing is near it.
  double growOf(int mark) => _line(mark, place(tall).at).grow;

  /// Which messages are on the screen now, as the map has them: its bright lines.
  ({double lo, double hi}) get seen {
    final (:lo, :hi, at: _) = place(tall);
    return (lo: lo, hi: hi);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = ticks.length;
    if (n == 0) return;
    final (:lo, :hi, :at) = place(tall);
    final paint = Paint()..strokeCap = StrokeCap.round;
    // The map itself is [ChatRail.width] wide and [tall] high, [ChatRail.spillRight] in from the box's right: the rest
    // is room for a swell.
    canvas.translate(size.width - ChatRail.width - ChatRail.spillRight, (size.height - tall) / 2);
    const width = ChatRail.width;
    // Only the lines in the map now, and those a swell could push into it: a long chat has many more.
    final first = math.max(0, (at / ChatRail.pitch).floor() - _spare), last = math.min(n - 1, ((at + tall) / ChatRail.pitch).ceil() + _spare);
    if (last < first) return;
    for (var i = first; i <= last; i++) {
      // The newest at the foot.
      final (:y, grow: m) = _line(i, at);
      if (y < 0 || y > tall) continue;
      paint.strokeWidth = ChatRail.thick * (1 + (m - 1) * 0.6);
      final k = ticks[i];
      final seen = i + 1 > lo && i < hi;
      final colour = k.quiet ? quiet : (k.mine ? mine : (hues[k.who] ?? theirs));
      final length = k.quiet ? ChatRail.shortest : ChatRail.shortest + (ChatRail.longest - ChatRail.shortest) * k.rate;
      paint.color = colour.withValues(alpha: seen ? 1 : (k.quiet ? 0.28 : 0.42));
      // One's own from the right edge and everyone else's from the left, as their bubbles are, so the two are told
      // apart in a look whose accent is its ink.
      // Swollen, a line grows toward the chat, out of the map's left side, as the Dock's icons grow up out of it.
      final more = length * (m - 1);
      if (k.mine && !k.quiet) {
        canvas.drawLine(Offset(width - 2 - length - more, y), Offset(width - 2, y), paint);
      } else {
        canvas.drawLine(Offset(2 - more, y), Offset(2 + length, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(RailPainter old) => !identical(old.ticks, ticks) || old.tall != tall || old.mine != mine || old.theirs != theirs || old.quiet != quiet;
}

/// A mouse's button held on the map and drawn along it: a drag of its own kind, so it can stand beside the drag that
/// scrolls the chat under a finger or a trackpad.
class _MouseHold extends VerticalDragGestureRecognizer {
  _MouseHold() : super(supportedDevices: const {PointerDeviceKind.mouse}, allowedButtonsFilter: _primary);

  static bool _primary(int buttons) => buttons == kPrimaryButton;
}
