import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/physics.dart' show nearEqual;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../backgrounds.dart' show lookCorner;
import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import 'chat_rows.dart' show RowHeights;
import 'dialup/bevel.dart' show DialupColors, isDialup;
import 'dialup/retro_button.dart';

// The way back to the newest message, and where each chat was left (Matt, 2026-11-17: "add a down arrow that pops up
// when we enter a chat and we're not scrolled to the bottom or after we scroll up a certain amount, remember the scroll
// position when switching between chats"). One piece for every chat: a conversation of texts or of friends
// (lib/ui/thread.dart), a Telegram or Signal chat (lib/ui/inbox_ui.dart) and a space's chat (lib/ui/hangout_screen.dart).
// Each of those lists is drawn bottom up (`reverse: true`), so an offset of 0 is the newest message and an offset
// grows as the person reads back.

/// Where a chat was left: how far up from the newest message, the newest message from someone else that had been seen
/// at the foot by then (so what came after it can be counted on the arrow), how many messages the screen held, and the
/// layout the offset was measured in ([JumpToLatest] drops a spot whose layout is not the one it opens in).
typedef ScrollSpot = ({double offset, Object? seen, int? held, String? fit});

/// Where each chat was left, for as long as the app runs: a chat opened again opens there. Held in memory alone, since
/// a spot is only worth keeping while the person is moving between chats; a chat left at its newest message keeps
/// nothing, and opens at its newest as it always did.
///
/// Keyed by the chat: `sms:<thread>`, `inbox:<network>:<chat>`, `space:<room>`.
class ScrollMemory {
  ScrollMemory._();

  static final Map<String, ScrollSpot> _spots = {};

  static ScrollSpot? of(String chat) => _spots[chat];

  /// [chat] was left [offset] up from its newest message, measured in the layout [fit] (none: taken as fitting any).
  /// At the newest (within [JumpToLatest.near]) it is forgotten.
  static void keep(String chat, double offset, {Object? seen, int? held, String? fit}) {
    if (offset <= JumpToLatest.near) {
      _spots.remove(chat);
      return;
    }
    final was = _spots[chat];
    _spots[chat] = (offset: offset, seen: seen, held: held ?? was?.held, fit: fit);
  }

  /// How many messages a screen held as it left [chat], where it pages them (a conversation of texts reads its newest
  /// 120, then 300 more at a time): opened again it reads that many at once, so the spot is there to come back to
  /// rather than past the end of the first page.
  static void hold(String chat, int held) {
    final spot = _spots[chat];
    if (spot != null) _spots[chat] = (offset: spot.offset, seen: spot.seen, held: held, fit: spot.fit);
  }

  /// [chat]'s spot forgotten, and how tall its rows were with it (lib/ui/chat_rows.dart): a spot is dropped where the
  /// chat is to be drawn in another layout, and there every row is another height.
  static void forget(String chat) {
    _spots.remove(chat);
    RowHeights.forgetChat(chat);
  }

  /// Every chat whose key starts with [prefix] forgotten: a network signed out of (`inbox:telegram:`) or a phone
  /// unpaired (`sms:`). The same ids then name other conversations, and an old spot put back on one of them would open
  /// it at some unrelated height.
  static void forgetAll(String prefix) {
    _spots.removeWhere((chat, _) => chat.startsWith(prefix));
    RowHeights.forgetAll(prefix);
  }

  /// Every chat forgotten (for tests).
  static void clear() {
    _spots.clear();
    RowHeights.clear();
  }

  /// A controller that starts where the chat [chat] names was left, so the chat's first frame is drawn there rather
  /// than at the newest and moved a frame later. [chat] is asked each time the controller is attached to a list rather
  /// than once: a space's page stays as the room changes, and the list made for the next room (after "No messages yet"
  /// stood in its place) starts at that room's spot, not the first room's.
  static ScrollController controllerFor(String Function() chat) => _ChatScrollController(chat);
}

/// A controller whose list starts at its chat's kept spot, asked for each time a list is attached.
class _ChatScrollController extends ScrollController {
  _ChatScrollController(this.chat) : super(keepScrollOffset: false);
  final String Function() chat;

  @override
  double get initialScrollOffset => ScrollMemory.of(chat())?.offset ?? 0;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _ChatScrollPosition(physics: physics, context: context, initialPixels: initialScrollOffset, keepScrollOffset: keepScrollOffset, oldPosition: oldPosition, debugLabel: debugLabel);
}

/// A chat's scroll position, which says so when its list corrects it.
///
/// A chat's list (lib/ui/chat_rows.dart) takes a row it has not measured to be about as tall as the others, and when
/// the row is laid out and is not, it corrects the scroll offset under what is on the screen, in the same layout, so
/// nothing is seen to move. A correction is silent: nothing that listens to the controller hears of it. So:
///
///  * those who listen are told once the frame is drawn, and the arrow keeps the chat's real place (it kept the
///    number from before, and a chat left then was opened again that much off);
///  * a run to somewhere (animateTo: the arrow's run to the newest message, a message brought into view, Page Up and
///    Down) goes on from the corrected offset ([_ChatRun]). The framework's run sets the offset afresh at each frame
///    from where it began, so the correction was written over a frame later and the page jumped by it, at each row
///    that came in.
class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition({required super.physics, required super.context, super.initialPixels, super.keepScrollOffset, super.oldPosition, super.debugLabel});

  /// What the list has corrected the offset by in this frame's layout, not yet told.
  double _corrected = 0;
  bool _telling = false;
  bool _gone = false;

  @override
  Future<void> animateTo(double to, {required Duration duration, required Curve curve}) {
    // As the framework's own: there already, or a run begun.
    if (nearEqual(to, pixels, physics.toleranceFor(this).distance)) {
      jumpTo(to);
      return Future<void>.value();
    }
    // The newest end is offset 0 whatever is corrected; the oldest is the list's whole length, which every
    // correction moves; a place in between moves with what is corrected under it.
    final toward = !hasContentDimensions || to <= minScrollExtent + 0.5
        ? _RunTo.newest
        : to >= maxScrollExtent - 0.5
            ? _RunTo.oldest
            : _RunTo.place;
    final run = _ChatRun(this, from: pixels, to: to, toward: toward, duration: duration, curve: curve, vsync: context.vsync);
    beginActivity(run);
    return run.done;
  }

  @override
  void correctBy(double correction) {
    final run = activity;
    // Where the run stands is read before the offset is corrected under it.
    if (run is _ChatRun) run.corrected(correction, pixels);
    super.correctBy(correction);
    _corrected += correction;
    if (_telling) return;
    _telling = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _telling = false;
      final by = _corrected;
      _corrected = 0;
      if (_gone || by == 0 || !hasPixels) return;
      notifyListeners();
      if (context.notificationContext == null) return;
      // Told as an update only of a scroll under way, which will end; with nothing scrolling, as the end of one. On
      // a computer the list has the framework's scrollbar, which an update brings up and only an end fades: told as
      // updates alone, it came up at a press on the map and stayed.
      if (activity?.isScrolling ?? false) {
        didUpdateScrollPositionBy(by);
      } else {
        didEndScroll();
      }
    });
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

/// Where a run is going: an end of the list, or a place in it.
enum _RunTo { newest, oldest, place }

/// A run to somewhere (animateTo) that goes on from the corrected offset when the list corrects it. Its own animation
/// goes from 0 to 1 by the caller's curve, and the offset is worked out at each frame from where the run last stood
/// and where it is going: nothing is begun again at a correction, so no frame is lost, and it ends when it ends.
class _ChatRun extends DrivenScrollActivity {
  _ChatRun(super.delegate, {required double from, required double to, required this.toward, required super.duration, required super.curve, required super.vsync})
      : _stood = from,
        _to = to,
        super(from: 0, to: 1);

  final _RunTo toward;

  /// Where the run stood, and how far along it was, when it began or was last corrected.
  double _stood;
  double _stoodAt = 0;

  /// Where it is going: fixed for the newest end, moved with each correction for a place, and for the oldest end the
  /// list's end as it is now.
  double _to;

  /// How far along the animation last said.
  double _along = 0;

  double get _goal => toward == _RunTo.oldest ? (delegate as ScrollPosition).maxScrollExtent : _to;

  double _at(double along) {
    final rest = 1 - _stoodAt;
    return rest.abs() < precisionErrorTolerance ? _goal : _stood + (_goal - _stood) * (along - _stoodAt) / rest;
  }

  @override
  bool applyMoveTo(double value) {
    _along = value;
    return super.applyMoveTo(_at(value));
  }

  /// The list is about to correct the offset, now [at], [by]: the run stands that much further on, as far along as it
  /// was.
  void corrected(double by, double at) {
    _stood = at + by;
    _stoodAt = _along;
    if (toward == _RunTo.place) _to += by;
  }

  @override
  double get velocity {
    final rest = 1 - _stoodAt;
    return rest.abs() < precisionErrorTolerance ? 0 : super.velocity * (_goal - _stood) / rest;
  }
}

/// A chat's list with a down arrow over its foot, at the right, that takes the person back to the newest
/// message. It comes up when the chat opens away from the newest (where it was left, [ScrollMemory]), when the person
/// has read back more than [thresholdOf] (about a screen), or when someone writes while the person is above the
/// newest; it goes once they are back at the foot. While they are up, what others write is counted on its corner.
///
/// It keeps where the chat was left in [ScrollMemory] as it goes, and puts the list back there as it is opened.
class JumpToLatest extends StatefulWidget {
  const JumpToLatest({super.key, required this.controller, required this.chat, required this.child, this.incoming = const [], this.inset});

  /// The list's own controller, on a list drawn bottom up.
  final ScrollController controller;

  /// The chat, as [ScrollMemory] keys it. A new one (a space's page moved to another room) keeps the old one's spot
  /// and goes to the new one's.
  final String chat;

  /// The messages from others, newest first, by anything that tells them apart (their ids): only how many come before
  /// the one last seen at the foot is read, so a lazy iterable is enough.
  final Iterable<Object> incoming;

  /// Room between the arrow and the list's right and bottom edges; 12 when null.
  final EdgeInsets? inset;
  final Widget child;

  /// Within this of the newest message is at the newest: a bounce at the foot, or the pixel or two a list settles by,
  /// is not reading back.
  static const double near = 48;

  /// How far up the arrow comes on its own: a whole screen of the list (and at least 400px, on a short window), the
  /// point where the newest message has gone out of sight. Under that the newest is a flick away and the arrow would
  /// only come and go while the person reads the last few messages; past it, getting back is several flicks.
  static double thresholdOf(double viewport) => math.max(viewport, 400);

  /// A press from further up than this many screens jumps to the last screen at once and runs only that to the foot,
  /// rather than scrolling every message in between past the eye.
  static const double farScreens = 3;

  /// A spot the list cannot reach is given up after this many frames that built the chat and brought nothing further
  /// back, and this long since the list last grew: a network's older messages come in a page at a time, and a chat
  /// still loading is waited on, but one that holds no more is not waited on for good.
  static const int giveUpAfter = 3;
  static const Duration giveUpAfterTime = Duration(milliseconds: 1500);

  @override
  State<JumpToLatest> createState() => _JumpToLatestState();
}

class _JumpToLatestState extends State<JumpToLatest> {
  /// How far up the list was last seen, kept as it scrolls: the list lets go of its controller before this does, so it
  /// cannot be asked on the way out.
  double _offset = 0;

  /// The chat was opened away from its newest message: the arrow is up until the person is back at the foot.
  bool _entered = false;

  /// The newest message from someone else seen at the foot; what came after it is counted on the arrow.
  Object? _seen;
  bool _seenKnown = false;

  /// Where the chat is to be put back, once its list is laid out.
  double? _restore;
  bool _shown = false;

  /// The layout the list is drawn in now ([_fitOf]), and whether a spot from [ScrollMemory] is still to be checked
  /// against it (on the first layout after a chat is opened).
  String? _fit;
  bool _checkFit = false;

  /// While a spot is put back: the furthest the list has reached, and when (by frame time) it last reached further.
  /// A spot past everything the chat will ever hold (messages deleted since) is given up once the list stops growing,
  /// rather than waited on for good.
  double _reached = double.negativeInfinity;
  Duration? _grewAt;
  int _stalls = 0;

  /// The list is being moved here to put a spot back, not by the person ([_moved]).
  bool _restoring = false;
  bool _framePending = false;

  /// The page was given another chat in this frame.
  bool _changed = false;

  /// The tallest the list has been while this chat is open: the keyboard coming up halves it, and a threshold read from
  /// the halved list would bring the arrow up on its own for someone who has not moved.
  double _tallest = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrolled);
    _begin();
  }

  /// Starts over for [JumpToLatest.chat] from what [ScrollMemory] kept of it.
  void _begin() {
    final spot = ScrollMemory.of(widget.chat);
    // Always somewhere to go, the newest where nothing was kept: a space's page moved to another room still has the
    // old room's height on its controller.
    _restore = spot?.offset ?? 0;
    _offset = spot?.offset ?? 0;
    _entered = spot != null;
    _shown = spot != null;
    _seen = spot?.seen;
    _seenKnown = spot != null;
    _checkFit = spot != null;
    _reached = double.negativeInfinity;
    _grewAt = null;
    _stalls = 0;
    _tallest = 0;
    if (!_seenKnown) _markSeen();
    _afterFrame();
  }

  @override
  void didUpdateWidget(JumpToLatest old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
    if (old.chat != widget.chat) {
      ScrollMemory.keep(old.chat, _restore ?? _offset, seen: _seen, fit: _fit);
      // The list is put at the new chat's own place at once, and silently (nothing may be told while building), so
      // this frame's layout is there: left at the old chat's offset for a frame, a list that knew nothing of the new
      // chat's rows yet laid out every one of them from the newest up to that offset, to let them go a frame later.
      final c = widget.controller;
      if (c.hasClients) {
        final spot = ScrollMemory.of(widget.chat);
        c.position.correctPixels(spot != null && (spot.fit == null || spot.fit == _fit) ? spot.offset : 0);
        _changed = true;
      }
      _begin();
      return;
    }
    // Messages came (or the first of them were read): at the foot they are seen as they come; above it, counted.
    if (_offset <= JumpToLatest.near && !_entered) _markSeen();
    _afterFrame();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrolled);
    // A spot not yet reached (the chat had not held that far back) is still the one to come back to.
    ScrollMemory.keep(widget.chat, _restore ?? _offset, seen: _seen, fit: _fit);
    super.dispose();
  }

  /// What a pixel offset is measured in: the list's width, the look, and the size of its words. A spot taken on the
  /// Fold's cover screen and opened on the inner one (every bubble wraps afresh), in a resized window, or under another
  /// look (Dial-Up's lines are far shorter than bubbles) points at some other message, or past the end.
  String _fitOf(BuildContext context, BoxConstraints box) {
    final width = box.maxWidth.isFinite ? box.maxWidth.round() : 0;
    return '$width|${context.tokens.attrs['theme-preset'] ?? 'ghost'}|${MediaQuery.textScalerOf(context).scale(100).round()}';
  }

  void _markSeen() {
    final newest = widget.incoming.firstOrNull;
    // Nothing written by anyone yet (or not read yet): what comes later is counted only once something has been seen,
    // so a chat whose messages arrive after it opens does not count them all as new.
    if (newest == null && !_seenKnown) return;
    _seen = newest;
    _seenKnown = true;
  }

  /// After the list is laid out: moves it towards the spot being put back, as far as the chat holds, then reads where
  /// it stands ([_scrolled]).
  void _afterFrame() {
    // Once a frame however often the parent builds in it.
    if (_framePending) return;
    _framePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _framePending = false;
      if (!mounted) return;
      final restore = _restore;
      final c = widget.controller;
      if (restore != null && c.hasClients) {
        final p = c.position;
        // The chat may not hold that far back yet (a network's chat whose older messages are still coming): as far as
        // it goes now, and the rest once more of it is laid out (didUpdateWidget comes back here), unless the person
        // has moved the list meanwhile (_moved), or the list has stopped growing.
        final most = p.hasContentDimensions ? p.maxScrollExtent : null;
        final goal = most == null ? restore : math.min(restore, most);
        if (goal >= restore - 1) {
          _restore = null;
        } else if (most != null) {
          final now = SchedulerBinding.instance.currentFrameTimeStamp;
          _grewAt ??= now;
          if (most > _reached + 1) {
            _reached = most;
            _grewAt = now;
            _stalls = 0;
          } else if (++_stalls >= JumpToLatest.giveUpAfter && now - _grewAt! >= JumpToLatest.giveUpAfterTime) {
            // Several builds, and a while, with nothing more to reach: the spot is past the chat's end. The list stays
            // as far back as it goes, the arrow up, and every later build leaves it be.
            _restore = null;
          }
        }
        // Already there when the controller was made for this chat (ScrollMemory.controllerFor). (Gone to all the
        // same after the page was given another chat, though the offset is there: it also ends whatever was moving
        // the old one.)
        if (_changed || (p.pixels - goal).abs() > 1) {
          _changed = false;
          _restoring = true;
          try {
            c.jumpTo(goal);
          } finally {
            _restoring = false;
          }
        }
      }
      _scrolled();
    });
  }

  /// The list moved: keeps where it is, marks what is seen at the foot, and decides whether the arrow shows.
  void _scrolled() {
    final c = widget.controller;
    if (!c.hasClients || !mounted) return;
    final p = c.position;
    _offset = p.pixels;
    final atFoot = _offset <= JumpToLatest.near;
    // At the foot only because the chat does not yet hold as far back as its spot is not the person coming back down.
    if (atFoot && _restore == null) {
      _entered = false;
      _markSeen();
    }
    // Kept as it goes, not only as the screen goes: a chat built afresh in the same frame (a space's chat moved in the
    // page as someone joins its call, Dial-Up's chat crossing 560 wide) opens before the old one is gone, and reads
    // this.
    if (_restore == null) ScrollMemory.keep(widget.chat, _offset, seen: _seen, fit: _fit);
    if (p.hasViewportDimension) _tallest = math.max(_tallest, p.viewportDimension);
    final viewport = _tallest > 0 ? _tallest : 600.0;
    // Up past a screen brings it, and once up it stays until the foot: it does not blink in and out at the line.
    final show = !atFoot && (_shown || _entered || _unread > 0 || _offset > JumpToLatest.thresholdOf(viewport));
    if (show != _shown) setState(() => _shown = show);
  }

  /// What others wrote after the newest seen at the foot, up to 100 (shown as 99+). None where that one is no longer
  /// held (deleted, or a page of the chat read afresh): better no count than a wrong one, so the walk goes on past the
  /// cap to be sure it is still there.
  int get _unread {
    if (!_seenKnown) return 0;
    var n = 0;
    for (final id in widget.incoming) {
      if (id == _seen) return math.min(n, 100);
      n++;
    }
    return _seen == null ? math.min(n, 100) : 0;
  }

  /// The list was moved by anything but the spot being put back: a drag, a mouse wheel or trackpad, the keyboard's Page
  /// Up and Down. A spot still waiting to be put back is the person's to leave now; before, a wheel did not count, and
  /// on the Mac every message that came took the list back up to the spot. The one start that is not the person's is
  /// the list settling back inside its ends (it starts past the end of a chat that does not yet hold its spot, or its
  /// estimate of its length shrinks), which only ever begins out of range.
  bool _moved(ScrollStartNotification n) {
    if (n.depth == 0 && !_restoring && (n.dragDetails != null || !n.metrics.outOfRange)) _restore = null;
    return false;
  }

  /// The arrow pressed: down to the newest message, giving up any spot still being put back.
  void _jump() {
    final c = widget.controller;
    if (!c.hasClients) return;
    final p = c.position;
    final screen = p.hasViewportDimension ? p.viewportDimension : 600.0;
    _restore = null;
    if (p.pixels > screen * JumpToLatest.farScreens) c.jumpTo(screen);
    c.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    _entered = false;
    _markSeen();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final inset = widget.inset ?? const EdgeInsets.only(right: 12, bottom: 12);
    // Laid out before the list in it is built, so a spot measured in another layout is dropped before the list's
    // controller reads it for its first frame: a dropped spot opens at the newest, better than at the wrong message.
    // Painted by itself: a chat that scrolls, or a row in it that moves, or this arrow coming up, is not the page's
    // header and composer drawn again with it (they were, at every frame). Round the LayoutBuilder and not in it: what
    // is built again under one is laid out, and painted, from the LayoutBuilder itself.
    return RepaintBoundary(
        child: LayoutBuilder(builder: (context, box) {
      _fit = _fitOf(context, box);
      if (_checkFit) {
        _checkFit = false;
        final kept = ScrollMemory.of(widget.chat)?.fit;
        if (kept != null && kept != _fit) {
          ScrollMemory.forget(widget.chat);
          _restore = 0;
          _offset = 0;
          _entered = false;
          _shown = false;
        }
      }
      final unread = _shown ? _unread : 0;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          NotificationListener<ScrollStartNotification>(onNotification: _moved, child: widget.child),
          Positioned(
            right: inset.right,
            bottom: inset.bottom,
            child: IgnorePointer(
              ignoring: !_shown,
              child: ExcludeSemantics(
                excluding: !_shown,
                child: AnimatedOpacity(
                  opacity: _shown ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  child: AnimatedScale(
                    scale: _shown ? 1 : 0.8,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutBack,
                    child: Semantics(
                      value: unread > 0 ? '$unread new' : null,
                      child: _Arrow(key: const ValueKey('jump-to-latest'), unread: unread, onPressed: _jump, tokens: t),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }));
  }
}

/// The arrow itself: a button a step up from the page's paper, with a hairline and a soft shadow, so it reads over
/// bubbles and a chat background alike; round where the look's corners are round and square where they are square
/// (Sharp), as the bubbles and the composer are; under Dial-Up one of its raised square buttons. A count of
/// new messages on its corner.
class _Arrow extends StatelessWidget {
  const _Arrow({super.key, required this.unread, required this.onPressed, required this.tokens});
  final int unread;
  final VoidCallback onPressed;
  final Tokens tokens;

  static const label = 'Jump to the newest message';

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final dialup = isDialup(context);
    final Widget button;
    if (dialup) {
      // Its face 40 square, its press target 48 (RetroButton.target), as the composer's own buttons are.
      button = RetroButton(onPressed: onPressed, icon: Lucide.arrowDown, semanticLabel: label, padding: EdgeInsets.zero);
    } else {
      // The look's corners (lib/backgrounds.dart lookCorner): a circle on a 44 box where they are round, squarer
      // where the look's are, where a circle beside square bubbles looked borrowed from another look.
      final corner = lookCorner(t, '22px', most: 1);
      button = GlacierPressable(
        onPressed: onPressed,
        semanticLabel: label,
        builder: (context, state) => GlacierFocusRing(
          visible: state.focused,
          radius: corner,
          child: AnimatedScale(
            scale: state.pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(corner),
                // A step up from the page, as the quick-reply chips are: on a black page the page's own black left only
                // the hairline to tell it from the chat behind it, and on Uplink's light page white vanished over your
                // own white, outlined bubbles.
                color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
                border: Border.all(color: t.color('app-rule')),
                boxShadow: t.shadow('glacier-shadow-2'),
              ),
              child: AppIcon(Lucide.arrowDown, size: 20, strokeWidth: 2.2, wash: false, color: t.color('app-ink')),
            ),
          ),
        ),
      );
    }
    if (unread <= 0) return button;
    final c = dialup ? DialupColors.of(t) : null;
    return Stack(clipBehavior: Clip.none, children: [
      button,
      Positioned(
        // Hung off the corner, under Dial-Up too (as its taskbar's counts are), so the button's whole bevel shows.
        right: dialup ? -6 : -4,
        top: -6,
        child: ExcludeSemantics(
          child: Container(
            // As the navigation pill's counts are (lib/ui/nav_bar.dart): red, with a line of the page round it; square
            // under Dial-Up, as its taskbar's are.
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.danger,
              borderRadius: dialup ? null : BorderRadius.circular(lookCorner(t, '11px', most: 1)),
              border: Border.all(color: c?.chrome ?? t.color('glacier-bg'), width: dialup ? 1 : 2),
            ),
            child: Text(unread > 99 ? '99+' : '$unread', style: t.textAt(12, weight: 'bold', height: 1.15, color: _onDanger(t))),
          ),
        ),
      ),
    ]);
  }

  /// The count's figures: white on the red, the same white the navigation pill's counts are drawn in (lib/ui/nav_bar.dart),
  /// since no look has a token for words on its red (Uplink's glacier-danger-contrast is its paper, black in the dark);
  /// unless a look's red is light enough that white would not read on it (Dial-Up's dark half, #FF6060, about 3:1),
  /// where they take the page's darker end instead.
  static Color _onDanger(Tokens t) {
    if (t.danger.computeLuminance() <= 0.25) return const Color(0xFFFFFFFF);
    return t.color(t.isDark ? 'app-paper' : 'app-ink');
  }
}
