import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/open_space.dart';
import '../voice/voice.dart';
import 'common.dart';
import 'connecting_banner.dart';
import 'composer_box.dart';
import 'hangout_screen.dart' show SpaceFace;
import 'open_space_chat.dart';
import 'ripple_avatar.dart';
import 'voice_screen.dart' show LinkBadge, showPerson;
import '../l10n/words.dart';

/// Draws one person on an open space's floor. Today's is [avatarFigure]; a character (a ghost dressed in cosmetics)
/// is another of these, handed the same [OpenFigure]: which way they face and whether they walk are already in it.
typedef OpenFigureBuilder = Widget Function(BuildContext context, OpenFigure who, Widget face);

/// A person as their profile picture with the call's ripple round it while they talk.
Widget avatarFigure(BuildContext context, OpenFigure who, Widget face) => RippleAvatar(name: who.name, level: who.level, muted: who.muted, size: who.size, child: face);

/// An open space's call wherever a call is drawn (lib/ui/hangout_screen.dart, a phone's and a computer's): its floor,
/// from the first moment, and never the normal call in its place. The floor is made as the call is begun
/// (OpenSpaces.follow in Voice.join); should a frame come before it, the room's ground is drawn with a word that it
/// is coming in, rather than anything that looks like another kind of call.
class OpenSpaceFloor extends StatelessWidget {
  const OpenSpaceFloor({super.key, required this.session, this.bottomInset = 0, this.sayBeside});
  final VoiceSession session;
  final double bottomInset;

  /// See [OpenSpaceView.sayBeside].
  final double? sayBeside;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: OpenSpaces.instance,
        builder: (context, _) {
          final floor = OpenSpaces.instance.of(session);
          if (floor != null) return OpenSpaceView(key: ValueKey('open-floor-${session.channel.room}'), session: session, floor: floor, bottomInset: bottomInset, sayBeside: sayBeside);
          final t = context.tokens;
          return ColoredBox(
            key: const ValueKey('open-floor-coming'),
            color: t.color('app-paper'),
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Center(child: _Pill(child: Text('Coming into ${session.channel.name}…', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))))),
            ),
          );
        },
      );
}

/// An open space's floor seen from above (lib/voice/open_space.dart; Matt, 2026-11-23: "a top down view and lets you
/// move around in the space ... allow walking around with wasd or arrow keys"). This device stays in the middle of the
/// view and the floor moves under it, until the view reaches a wall: it stops there, and this device walks on ([cameraFor]). Walk with W A S D or the arrow keys while the floor has the keyboard, or press
/// (or drag) where to go. Groups are drawn as circles that grow with who is in them; press a group's name for
/// what can be done with it. Everyone else is drawn where they said they stand, eased between their words, and fainter
/// the less of them is heard from here.
class OpenSpaceView extends StatefulWidget {
  const OpenSpaceView({super.key, required this.session, required this.floor, this.figure = avatarFigure, this.bottomInset = 0, this.sayBeside});
  final VoiceSession session;
  final OpenSpace floor;
  final OpenFigureBuilder figure;

  /// Room left at the foot for what is drawn over it (the call's dock).
  final double bottomInset;

  /// Where the call's dock stands at the floor's left foot and leaves the right free (a wide window): how far above
  /// the foot the chat's box stands, on the dock's own line. Null where the dock is across the foot (a phone): the box
  /// stands above it, [bottomInset] up.
  final double? sayBeside;

  /// How many of the screen's units one of the floor's is, for a view [size] big: a little smaller on a phone, so
  /// about as much floor is seen.
  static double scaleFor(Size size) => (size.shortestSide / 760).clamp(0.6, 1.1);

  /// The point of the floor at the view's [centre] for someone standing at [me]: [me], held back so that a view
  /// [size] big at [scale] never shows past the walls' outer edge. Where the room is narrower than the view, the room
  /// is centred.
  static Offset cameraFor(Offset me, Size size, Offset centre, double scale) {
    double held(double at, double low, double high, double before, double after) {
      // The furthest the view's middle may go each way with its edges still inside the room.
      final least = low + before / scale, most = high - after / scale;
      return least > most ? (low + high) / 2 + (before - after) / (2 * scale) : at.clamp(least, most);
    }

    const t = _FloorPainter.wallThick, up = _FloorPainter.wallHigh;
    return Offset(
      held(me.dx, -t, OpenWorld.width + t, centre.dx, size.width - centre.dx),
      held(me.dy, -up - t, OpenWorld.height + t + up, centre.dy, size.height - centre.dy),
    );
  }

  @override
  State<OpenSpaceView> createState() => _OpenSpaceViewState();
}

class _OpenSpaceViewState extends State<OpenSpaceView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_frame);
  final FocusNode _focus = FocusNode(debugLabel: 'open space floor');

  /// Where each person is drawn (eased towards where they said they stand), and each group's circle as drawn.
  final Map<String, Offset> _shown = {};
  final Map<String, double> _radius = {};
  Duration _last = Duration.zero;

  /// The floor and the call as one thing to listen to: made once for each floor, never anew at each drawing, so a
  /// floor let go of while this is still on the screen for a frame is not listened to again.
  late FloorBubbles _bubbles = FloorBubbles(widget.floor);
  late Listenable _both = Listenable.merge([widget.floor, widget.session, _bubbles]);

  /// What is being written to the space's chat from the floor.
  final TextEditingController _saying = TextEditingController();
  final FocusNode _sayFocus = FocusNode(debugLabel: 'open space chat box');

  /// This device has walked since the floor opened: the words saying how are no longer needed and fade away (Matt,
  /// 2026-11-23: "when we move with wasd or click fade away the tooltip").
  bool _walked = false;

  /// The keys held that walk: which ways are wanted.
  final Set<LogicalKeyboardKey> _held = {};

  static final _left = {LogicalKeyboardKey.keyA, LogicalKeyboardKey.arrowLeft};
  static final _right = {LogicalKeyboardKey.keyD, LogicalKeyboardKey.arrowRight};
  static final _up = {LogicalKeyboardKey.keyW, LogicalKeyboardKey.arrowUp};
  static final _down = {LogicalKeyboardKey.keyS, LogicalKeyboardKey.arrowDown};

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    widget.floor.addListener(_wake);
    _wake();
  }

  @override
  void didUpdateWidget(OpenSpaceView old) {
    super.didUpdateWidget(old);
    if (identical(old.floor, widget.floor)) return;
    old.floor.removeListener(_wake);
    widget.floor.addListener(_wake);
    _bubbles.dispose();
    _bubbles = FloorBubbles(widget.floor);
    _both = Listenable.merge([widget.floor, widget.session, _bubbles]);
    _shown.clear();
    _radius.clear();
    _wake();
  }

  /// Something on the floor changed: frames are drawn until everyone has reached where they stand ([_frame] stops them
  /// again), so a floor nobody is walking on costs nothing.
  void _wake() {
    if (_ticker.isActive || widget.floor.gone) return;
    _last = Duration.zero;
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _bubbles.dispose();
    _saying.dispose();
    _sayFocus.dispose();
    widget.floor.removeListener(_wake);
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    // Not left walking into a wall by a key that was down as the view went.
    if (_held.isNotEmpty) widget.floor.head(0, 0);
    super.dispose();
  }

  /// Each frame: everyone eased towards where they stand, and the circles towards their size. Drawn again only while
  /// something is still on its way; once all have arrived the frames stop until the floor next changes ([_wake]).
  void _frame(Duration now) {
    if (widget.floor.gone) {
      _ticker.stop();
      return;
    }
    // A ticker's time starts at nothing each time it is started.
    final dt = _last == Duration.zero ? 1 / 60 : ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = now;
    final floor = widget.floor;
    // Closes most of the gap in a tenth of a second: smooth between words said ten times a second, never lagging far.
    final ease = 1 - math.exp(-dt * 14);
    var moved = false;
    final ids = floor.people;
    _shown.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      final at = floor.placeOf(id).at;
      final want = Offset(at.x, at.y);
      final had = _shown[id];
      // This device is drawn where it is: it is what the view is centred on.
      final next = had == null || id == OpenSpace.meId ? want : Offset.lerp(had, want, ease)!;
      if (had == null || (next - had).distanceSquared > 0.01) moved = true;
      _shown[id] = (next - want).distanceSquared < 0.25 ? want : next;
    }
    final groups = {for (final g in floor.groups) g.id};
    _radius.removeWhere((id, _) => !groups.contains(id));
    for (final id in groups) {
      final want = floor.radiusOf(id);
      final had = _radius[id];
      final next = had == null ? want : had + (want - had) * (1 - math.exp(-dt * 8));
      if (had == null || (next - had).abs() > 0.05) moved = true;
      _radius[id] = (next - want).abs() < 0.3 ? want : next;
    }
    if (!mounted) return;
    if (moved) {
      setState(() {});
    } else {
      _ticker.stop();
    }
  }

  void _focusChanged() {
    if (!_focus.hasFocus && _held.isNotEmpty) {
      _held.clear();
      widget.floor.head(0, 0);
    }
    if (mounted) setState(() {});
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    // While the chat's box has the keyboard its letters are words, not steps.
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (!_left.contains(k) && !_right.contains(k) && !_up.contains(k) && !_down.contains(k)) return KeyEventResult.ignored;
    // With Ctrl, Alt or Cmd it is a command of the app's, not a step.
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return KeyEventResult.ignored;
    if (e is KeyUpEvent) {
      _held.remove(k);
    } else {
      _held.add(k);
    }
    double way(Set<LogicalKeyboardKey> plus, Set<LogicalKeyboardKey> minus) => (_held.any(plus.contains) ? 1.0 : 0.0) - (_held.any(minus.contains) ? 1.0 : 0.0);
    widget.floor.head(way(_right, _left), way(_down, _up));
    if (!_walked && _held.isNotEmpty) setState(() => _walked = true);
    return KeyEventResult.handled;
  }

  /// A group's name pressed: what can be done with it.
  void _groupMenu(SpaceGroup g) {
    final floor = widget.floor;
    showChoices(context, title: g.name, choices: [
      Choice('Walk there', Lucide.compass, () => floor.walkTo(g.at)),
      Choice('Rename', Lucide.pencil, () async {
        final name = await push<String>(context, (_) => _NameGroupPage(title: 'Rename group', start: g.name));
        if (name != null) floor.renameGroup(g.id, name);
      }),
      Choice('Move it here', LucideMore.move, () => floor.moveGroupHere(g.id), hint: 'Round where you stand now'),
      Choice('Remove', Lucide.trash2, () => floor.removeGroup(g.id), danger: true, hint: 'For everyone in the space'),
    ]);
  }

  /// New group pressed: a few ready names, or one of your own; made round where this device stands.
  void _newGroup() {
    final floor = widget.floor;
    if (floor.groups.length >= OpenWorld.mostGroups) {
      toast(context, 'This space has all the groups it can hold.');
      return;
    }
    void make(String name) {
      if (floor.addGroup(name) == null && mounted) toast(context, 'Couldn\'t make that group.');
    }

    showChoices(context, title: 'New group here', choices: [
      Choice('Game', LucideMore.gamepad, () => make('Game'), hint: 'A circle for whoever is playing'),
      Choice('Casual chat', LucideMore.messageCircle, () => make('Casual chat')),
      Choice('Movie night', Lucide.film, () => make('Movie night')),
      Choice('Name it yourself', Lucide.pencil, () async {
        final name = await push<String>(context, (_) => const _NameGroupPage(title: 'New group'));
        if (name != null) make(name);
      }),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final floor = widget.floor, session = widget.session;
    // The call was left a moment ago and the page has not gone yet.
    if (floor.gone) return const SizedBox.expand();
    final voice = Voice.instance;
    final room = voice.hangoutFor(session.channel);
    _bubbles.follow(room);
    final levels = voice.media?.levels ?? session.media.levels;
    return ListenableBuilder(
      listenable: _both,
      builder: (context, _) => LayoutBuilder(builder: (context, box) {
        final size = box.biggest;
        final scale = OpenSpaceView.scaleFor(size);
        final me = _shown[OpenSpace.meId] ?? Offset(floor.me.at.x, floor.me.at.y);
        // This device in the middle of what is seen above the dock.
        final centre = Offset(size.width / 2, (size.height - widget.bottomInset) / 2);
        // What the view is centred on: this device, until that would show past a wall; then the view stays put and
        // this device walks on towards its edge (Matt, 2026-11-23: "when we get to the wall stop moving the camera so
        // we don't see past the wall").
        final cam = OpenSpaceView.cameraFor(me, size, centre, scale);
        Offset onScreen(Offset world) => centre + (world - cam) * scale;
        final face = (56 * scale).clamp(40.0, 60.0);
        final groups = floor.groups;
        final people = floor.people;
        final beside = widget.sayBeside;
        // The walls: the colour chosen for the app (its accent, lib/accent.dart). Nothing chosen leaves the accent the
        // page's own ink, white on a dark page, which is no colour for a wall (Matt, 2026-11-23: "the walls should be
        // the primary color selected for the users theme but it's solid white"): the open space's own purple then.
        final accent = t.color('app-accent');
        final wall = _plain(accent) ? t.hueSwatch('purple') : accent;
        return Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _key,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // A press, or a finger dragged: walk to there. Also takes the keyboard back from the chat's box.
            onTapUp: (d) {
              _focus.requestFocus();
              if (!_walked) setState(() => _walked = true);
              final w = cam + (d.localPosition - centre) / scale;
              floor.walkTo(Offset2(w.dx, w.dy));
            },
            onPanUpdate: (d) {
              final w = cam + (d.localPosition - centre) / scale;
              floor.walkTo(Offset2(w.dx, w.dy));
            },
            child: ClipRect(
              child: Stack(clipBehavior: Clip.hardEdge, children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _FloorPainter(
                      me: cam,
                      self: me,
                      centre: centre,
                      scale: scale,
                      ground: t.color('app-paper'),
                      floor: t.color('app-paper-2'),
                      rule: t.color('app-rule'),
                      ink: t.color('app-ink-3'),
                      // One colour, the app's own (Matt, 2026-11-23: "make the walls a solid color like the primary
                      // color (still keep different opaqueness and lines)").
                      // Two shades of it across the room, so the walls have some depth to them ("make the primary color
                      // have some gradients to it so that there is some detail to the walls").
                      wallA: Color.lerp(wall, const Color(0xFFFFFFFF), 0.22)!,
                      wallB: Color.lerp(wall, const Color(0xFF000000), 0.28)!,
                      groups: [for (final g in groups) (at: Offset(g.at.x, g.at.y), radius: _radius[g.id] ?? floor.radiusOf(g.id), color: t.hueSwatch(g.hue), mine: floor.groupOf(OpenSpace.meId) == g.id)],
                    ),
                  ),
                ),
                // Each group's name over its circle, with how many are in it.
                for (final g in groups)
                  () {
                    final at = onScreen(Offset(g.at.x, g.at.y - (_radius[g.id] ?? floor.radiusOf(g.id))));
                    final n = floor.countIn(g.id);
                    return PositionedDirectional(
                      key: ValueKey('open-group-${g.id}'),
                      start: at.dx - 110,
                      top: at.dy - 34,
                      width: 220,
                      child: Center(child: _GroupName(name: g.name, count: n, color: t.hueSwatch(g.hue), onPress: () => _groupMenu(g))),
                    );
                  }(),
                // Everyone, this device last so it is on top.
                for (final id in [...people.where((id) => id != OpenSpace.meId), OpenSpace.meId])
                  () {
                    final mine = id == OpenSpace.meId;
                    final place = floor.placeOf(id);
                    final at = onScreen(_shown[id] ?? Offset(place.at.x, place.at.y));
                    final member = mine ? null : session.members[id];
                    // As they said they are called in this call; else as the app knows them.
                    final name = mine ? (session.name.isEmpty ? 'You' : session.name) : ((member?.name ?? '').isNotEmpty ? member!.name : voice.nameOf(id));
                    final heard = mine ? 1.0 : floor.gainOf(id);
                    final muted = mine ? (session.muted || session.deafened) : (member?.muted ?? false);
                    final picture = room == null ? Avatar(people: [Person(address: 'space:$id', name: name)], size: face, presence: false) : SpaceFace(room: room, id: mine ? room.me : id, name: name, size: face);
                    Widget figure = ValueListenableBuilder<Map<String, double>>(
                      valueListenable: levels,
                      builder: (context, loud, _) => widget.figure(context, OpenFigure(id: id, name: name, me: mine, size: face, level: loud[id] ?? 0, muted: muted, facing: place.facing, walking: place.walking, heard: heard), picture),
                    );
                    if (!mine) figure = LinkBadge(id: id, size: face, child: figure);
                    return PositionedDirectional(
                      key: ValueKey('open-person-$id'),
                      start: at.dx - 70,
                      top: at.dy - face / 2,
                      width: 140,
                      child: IgnorePointer(
                        ignoring: mine,
                        child: GestureDetector(
                          behavior: HitTestBehavior.deferToChild,
                          // Press and hold (or the other button) for what can be done about them, as in any call.
                          onLongPress: mine ? null : () => showPerson(context, session, id, name),
                          onSecondaryTap: mine ? null : () => showPerson(context, session, id, name),
                          child: Opacity(
                            // Fainter the less of them is heard from here; never gone, so they can be walked to.
                            opacity: 0.4 + 0.6 * heard,
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              figure,
                              SizedBox(height: t.space(1)),
                              _NameTag(name: mine ? 'You' : name, muted: muted),
                            ]),
                          ),
                        ),
                      ),
                    );
                  }(),
                PositionedDirectional(
                  start: t.space(3),
                  top: t.space(3),
                  end: t.space(3) + 150,
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    // Gone once this device has walked; the word that the call is coming stays until it has.
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        key: const ValueKey('open-hint'),
                        opacity: _walked && session.joined ? 0 : 1,
                        duration: const Duration(milliseconds: 500),
                        child: _Pill(
                      child: Text(
                        // Before the relay has answered the floor is already here, and says the call is coming.
                        // And what it is waiting for, where it is known (lib/voice/call_wait.dart).
                        !session.joined ? (CallWaitBuilder.now()?.line ?? 'Connecting…') : Sms.computer ? (_focus.hasFocus ? 'Walk with W A S D or the arrow keys, or press where to go' : 'Press the floor, then walk with W A S D or the arrow keys') : 'Press where to go. The nearer someone is, the louder they are.',
                        style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')),
                      ),
                        ),
                      ),
                    ),
                  ),
                ),
                // The chat over the floor ([FloorBubbles]): over each group its own, the rest at the side.
                for (final g in groups)
                  if (_bubbles.over(g.id).isNotEmpty)
                    () {
                      final top = onScreen(Offset(g.at.x, g.at.y - (_radius[g.id] ?? floor.radiusOf(g.id))));
                      return PositionedDirectional(
                        key: ValueKey('open-bubbles-${g.id}'),
                        start: top.dx - 150,
                        width: 300,
                        // Stacked upwards from just above the group's name.
                        bottom: size.height - (top.dy - 40),
                        child: IgnorePointer(child: _BubbleStack(bubbles: _bubbles.over(g.id), opacityOf: _bubbles.opacityOf, align: CrossAxisAlignment.center)),
                      );
                    }(),
                if (_bubbles.side.isNotEmpty)
                  PositionedDirectional(
                    key: const ValueKey('open-bubbles-side'),
                    // Over the chat's box, on whichever side it stands.
                    start: beside == null ? t.space(3) : null,
                    end: beside == null ? null : t.space(3),
                    width: math.min(320, size.width * 0.62),
                    bottom: (beside ?? t.space(3) + widget.bottomInset) + 60,
                    child: IgnorePointer(child: _BubbleStack(bubbles: _bubbles.side, opacityOf: _bubbles.opacityOf, align: beside == null ? CrossAxisAlignment.start : CrossAxisAlignment.end)),
                  ),
                // A box to write to the space's chat from the floor; what is written comes up as a bubble like any other.
                // The app's own composer (lib/ui/composer_box.dart), as every conversation's (Matt, 2026-11-23: "make the
                // compose input look like the one on the rest of the app"); at the right foot beside the dock in a wide
                // window ("right justify the compose input").
                if (room != null && room.mayWrite)
                  PositionedDirectional(
                    start: beside == null ? t.space(3) : null,
                    end: beside == null ? null : t.space(3),
                    bottom: beside ?? t.space(3) + widget.bottomInset,
                    width: beside == null ? math.min(300, size.width * 0.62) : math.min(380, size.width * 0.42),
                    child: ListenableBuilder(
                      listenable: _saying,
                      builder: (context, _) {
                        void say() {
                          final words = _saying.text.trim();
                          if (words.isEmpty) return;
                          if (room.sendWith(text: words)) _saying.clear();
                        }

                        final has = _saying.text.trim().isNotEmpty;
                        final buttons = composerButtons(t, hasSomething: has, onAttach: null, onSticker: null, onRecord: null, onSend: has ? say : null);
                        return ComposerBox(
                          key: const ValueKey('open-say'),
                          flush: true,
                          typing: has,
                          ends: has ? buttons.ends : const [],
                          field: ComposerField(controller: _saying, focusNode: _sayFocus, hint: 'Say something', onSubmitted: say, enterSends: true),
                        );
                      },
                    ),
                  ),
                // At the top right, clear of the dock and the chat's box (Matt, 2026-11-23: "move the new group to the top right").
                PositionedDirectional(
                  end: t.space(3),
                  top: t.space(3),
                  child: GestureDetector(
                    key: const ValueKey('open-new-group'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _newGroup,
                    child: _Pill(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        AppIcon(LucideMore.target, size: 16, color: t.color('app-ink')),
                        SizedBox(width: t.space(2)),
                        Text('New group', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    );
  }
}

/// Whether [c] is all but a grey: white, black or between, with no colour of its own to speak of.
bool _plain(Color c) {
  final hi = math.max(c.r, math.max(c.g, c.b)), lo = math.min(c.r, math.min(c.g, c.b));
  return hi - lo < 0.08;
}

/// A stack of the chat's bubbles, oldest at the top: each its writer's name and words, as strongly drawn as
/// [opacityOf] says.
class _BubbleStack extends StatelessWidget {
  const _BubbleStack({required this.bubbles, required this.opacityOf, required this.align});
  final List<FloorBubble> bubbles;
  final double Function(FloorBubble) opacityOf;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: align, children: [
      for (final b in bubbles)
        Padding(
          padding: EdgeInsets.only(top: t.space(1)),
          child: Opacity(
            key: ValueKey('open-bubble-${b.id}'),
            opacity: opacityOf(b).clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: b.from == OpenSpace.meId ? 'You' : b.name, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink'))),
                    TextSpan(text: '  ${b.text}'),
                  ]),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: pageText(t, t.fontSize('sm'), color: t.color('app-ink')),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// A small raised capsule over the floor: the hint, the New group button.
class _Pill extends StatelessWidget {
  const _Pill({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(999), border: Border.all(color: t.color('app-rule'))),
      child: Padding(padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)), child: child),
    );
  }
}

/// A person's name under them, with a crossed microphone while theirs is off.
class _NameTag extends StatelessWidget {
  const _NameTag({required this.name, required this.muted});
  final String name;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return DecoratedBox(
      decoration: BoxDecoration(color: t.color('app-paper-3').withValues(alpha: 0.9), borderRadius: BorderRadius.circular(999)),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink')))),
          if (muted) Padding(padding: const EdgeInsetsDirectional.only(start: 4), child: AppIcon(LucideMore.micOff, size: 11, wash: false, color: t.danger)),
        ]),
      ),
    );
  }
}

/// A group's name over its circle, in its colour, with how many are in it. Pressed for its menu.
class _GroupName extends StatelessWidget {
  const _GroupName({required this.name, required this.count, required this.color, required this.onPress});
  final String name;
  final int count;
  final Color color;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPress,
      child: DecoratedBox(
        decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(999), border: Border.all(color: color, width: 1.5)),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink')))),
            SizedBox(width: t.space(2)),
            Text('$count', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: color)),
          ]),
        ),
      ),
    );
  }
}

/// The floor under everyone: the walls round it ([_walls]), a grid of dots to walk against, how far this device hears, and each group as a
/// circle, an outline in its colour over a see-through wash of it (Matt, 2026-11-23: "remove the extra decorations like
/// a crosshair on the circles just make a circle outline with the semiopaque infill").
class _FloorPainter extends CustomPainter {
  _FloorPainter({required this.me, required this.self, required this.centre, required this.scale, required this.ground, required this.floor, required this.rule, required this.ink, required this.wallA, required this.wallB, required this.groups});
  /// [me]: the point of the floor at the view's [centre] (OpenSpaceView.cameraFor). [self]: where this device stands.
  final Offset me, self, centre;
  final double scale;
  final Color ground, floor, rule, ink;

  /// The walls' two colours, left and right.
  final Color wallA, wallB;
  final List<({Offset at, double radius, Color color, bool mine})> groups;

  Offset _at(Offset world) => centre + (world - me) * scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = ground);
    canvas.drawRect(Rect.fromPoints(_at(Offset.zero), _at(const Offset(OpenWorld.width, OpenWorld.height))), Paint()..color = floor);
    // Dots every 80 of the floor's units, only those in sight.
    const step = 80.0;
    final dot = Paint()..color = ink.withValues(alpha: 0.22);
    final x0 = math.max(0.0, me.dx - centre.dx / scale), x1 = math.min(OpenWorld.width, me.dx + (size.width - centre.dx) / scale);
    final y0 = math.max(0.0, me.dy - centre.dy / scale), y1 = math.min(OpenWorld.height, me.dy + (size.height - centre.dy) / scale);
    for (var x = (x0 / step).ceil() * step; x <= x1; x += step) {
      for (var y = (y0 / step).ceil() * step; y <= y1; y += step) {
        canvas.drawCircle(_at(Offset(x, y)), 1.4, dot);
      }
    }
    for (final g in groups) {
      final c = _at(g.at), r = g.radius * scale;
      canvas.drawCircle(c, r, Paint()..color = g.color.withValues(alpha: g.mine ? 0.2 : 0.11));
      final line = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.mine ? 2.5 : 1.8
        ..color = g.color.withValues(alpha: g.mine ? 0.95 : 0.7);
      canvas.drawCircle(c, r, line);
    }
    _walls(canvas);
    // How far this device hears: nobody past this ring is heard. (The ring inside which everyone is whole is not
    // drawn: it sat just inside a small group's edge and read as part of the group.)
    canvas.drawCircle(
        _at(self),
        OpenWorld.far * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = ink.withValues(alpha: 0.18));
  }

  /// How thick the walls are and how high they stand, in the floor's units, and how far apart the far and near walls'
  /// panel lines are.
  static const double wallThick = 30, wallHigh = 104, wallPanel = 300;

  /// The walls round the floor, drawn as a room seen from above and a little in front (Matt, 2026-11-23: "add 3d walls
  /// to the edges so it shows a 2.5d wall around the edges", then "use colors and a mixture of hard lines and semi
  /// opaque walls", then "make the walls a solid color like the primary color (still keep different opaqueness and
  /// lines)": both ends are the app's own colour now). They are glass, [wallA] at the left running to [wallB] at the right: every face a
  /// see-through wash of its colour, every edge a hard line of it at full strength, as the groups' circles are drawn.
  /// The far wall shows its face, standing [wallHigh] above the floor's far edge under its top; the side walls show
  /// their tops, running down the sides; the near wall shows its top and, below it, its outer face, fainter. The far
  /// and near faces are ruled into panels, and the far wall's colour falls on the floor at its foot. Drawn after the
  /// floor's dots and groups, which all lie inside it.
  void _walls(Canvas canvas) {
    const w = OpenWorld.width, h = OpenWorld.height, t = wallThick, up = wallHigh;
    Rect box(double x0, double y0, double x1, double y1) => Rect.fromPoints(_at(Offset(x0, y0)), _at(Offset(x1, y1)));
    // Across the whole room, so every piece takes its colour from where it stands between the two.
    final room = box(-t, 0, w + t, 0);
    Shader across(double alpha) => LinearGradient(colors: [wallA.withValues(alpha: alpha), wallB.withValues(alpha: alpha)]).createShader(Rect.fromLTRB(room.left, 0, room.right, 1));
    Paint wash(double alpha) => Paint()..shader = across(alpha);
    Paint line(double width, [double alpha = 1]) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = across(alpha);
    // The far wall's colour on the floor at its foot, fading out.
    // Faint and short (Matt, 2026-11-23: "make the glow from the walls more subtle").
    final glow = box(0, 0, w, 44);
    canvas.drawRect(glow, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(wallA, wallB, 0.5)!.withValues(alpha: 0.07), Color.lerp(wallA, wallB, 0.5)!.withValues(alpha: 0)]).createShader(glow));
    // The faces, see-through: the far wall's, and the near wall's outer one, fainter.
    final far = box(0, -up, w, 0), near = box(-t, h + t, w + t, h + t + up);
    canvas.drawRect(far, wash(0.26));
    canvas.drawRect(near, wash(0.16));
    // Shaded as standing things are, so they don't read as flat bands ("so that it dosn't look too 2d"): the far
    // face darker under its top and lit towards the floor, the near face falling into shade towards its foot.
    Paint shade(Rect r, double top, double foot, Color c) => Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.withValues(alpha: top), c.withValues(alpha: foot)]).createShader(r);
    const dark = Color(0xFF000000), light = Color(0xFFFFFFFF);
    canvas.drawRect(far, shade(far, 0.30, 0, dark));
    canvas.drawRect(far, shade(far, 0, 0.10, light));
    canvas.drawRect(near, shade(near, 0, 0.34, dark));
    // Their panels: a thin hard line every [wallPanel], and one along the far wall a little above the floor.
    for (var x = wallPanel; x < w; x += wallPanel) {
      canvas.drawLine(_at(Offset(x, -up)), _at(Offset(x, 0)), line(1, 0.55));
      canvas.drawLine(_at(Offset(x, h + t)), _at(Offset(x, h + t + up)), line(1, 0.4));
    }
    canvas.drawLine(_at(const Offset(0, -14)), _at(const Offset(w, -14)), line(1, 0.55));
    // The tops, a stronger wash: the far one from corner to corner, the sides down from it, the near one between.
    final tops = [box(-t, -up - t, w + t, -up), box(-t, -up, 0, h + t), box(w, -up, w + t, h + t), box(0, h, w, h + t)];
    for (final r in tops) {
      canvas.drawRect(r, wash(0.42));
    }
    // Light along the tops' inner edges, where it would catch them.
    final shine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = light.withValues(alpha: 0.28);
    canvas.drawLine(_at(const Offset(0, -up)), _at(const Offset(w, -up)), shine);
    canvas.drawLine(_at(const Offset(0, h)), _at(const Offset(w, h)), shine);
    // The hard lines: round the outside of the tops, round the floor and up the far wall's face, and round the near face.
    canvas.drawRect(box(-t, -up - t, w + t, h + t), line(2));
    canvas.drawRect(box(0, -up, w, h), line(2));
    canvas.drawLine(_at(const Offset(0, 0)), _at(const Offset(w, 0)), line(2));
    canvas.drawRect(near, line(1.5, 0.7));
  }

  @override
  bool shouldRepaint(_FloorPainter old) => old.me != me || old.self != self || old.centre != centre || old.scale != scale || old.ground != ground || old.floor != floor || old.wallA != wallA || old.wallB != wallB || !_same(old.groups, groups);

  static bool _same(List<({Offset at, double radius, Color color, bool mine})> a, List<({Offset at, double radius, Color color, bool mine})> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A page for a group's name: New group's "Name it yourself", and Rename. Pops with the name, or with nothing.
class _NameGroupPage extends StatefulWidget {
  const _NameGroupPage({required this.title, this.start = ''});
  final String title;
  final String start;

  @override
  State<_NameGroupPage> createState() => _NameGroupPageState();
}

class _NameGroupPageState extends State<_NameGroupPage> {
  late final _name = TextEditingController(text: widget.start);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final words = _name.text.trim();
    Navigator.of(context).pop(words.isEmpty ? null : words);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: widget.title,
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          children: [
            PaneSection(title: 'Name', description: const Tr('What the group is for: a game, a film, a quiet corner.'), children: [
              SettingRowBox(child: GlacierInput(controller: _name, placeholder: 'Group name'.t, ariaLabel: 'Group name', autoFocus: true, autoCapitalize: TextCapitalization.sentences, size: GlacierFieldSize.md, onSubmitted: (_) => _done())),
            ]),
            SizedBox(height: t.space(6)),
            PaneSection(children: [
              SettingRow(key: const ValueKey('open-group-name-done'), icon: AppIcon(Lucide.check, size: 18), label: 'Done', onPress: _done),
            ]),
          ],
        ),
      ),
    );
  }
}
