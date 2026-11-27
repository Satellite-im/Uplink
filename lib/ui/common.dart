import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../inbox/inbox.dart' show InboxPresence;
import '../presence.dart';
import '../sms.dart';
import '../kit/semantic_colors.dart';
import 'dialup/dialup.dart';
import 'window_chrome.dart';
import '../kit/picture_decode.dart';
import '../l10n/words.dart';

/// The page under every screen: the ground, a bar with the way back (or a big title), its actions, and the body.
class GhostPage extends StatelessWidget {
  const GhostPage({super.key, required this.title, required this.body, this.back = true, this.actions = const [], this.titleWidget, this.footer, this.top, this.subtitle, this.onTitle, this.titleLeading, this.onBack, this.bigTitle, this.headerBackground, this.headerExtra = 0, this.headerInk, this.noBar = false});

  final String title;
  final Widget? titleWidget;

  /// Under Dial-Up, where [titleWidget] is not drawn (its words were styled for the page's ground, and would be black
  /// on the title bar's navy): the line under the name on the bar ("Telegram · People Here: 4"), a press on the
  /// name ([onTitle]: a conversation's settings), and a small picture before it ([titleLeading], 16 to 20 across).
  /// Every other look draws [titleWidget] and ignores these.
  final String? subtitle;
  final VoidCallback? onTitle;
  final Widget? titleLeading;
  final Widget body;
  final bool back;

  /// Where the back arrow goes, where that is not the page under this one: a page that took another's place in the
  /// pane (Contacts › Blocked goes back to Contacts). Given, the arrow is there beside the list too.
  final VoidCallback? onBack;

  /// The big title with a back arrow too, level with a page beside it (Settings' list beside a section's page); by
  /// default a page with the way back has the bar's smaller title.
  final bool? bigTitle;
  final List<Widget> actions;

  /// Kept above the keyboard: a conversation's composer.
  final Widget? footer;

  /// Above the title, under the status bar: the list's update card (lib/ui/update_banner.dart).
  final Widget? top;

  /// Drawn behind the top of the page under the status bar, the header row in it, and [headerExtra] further down (Matt,
  /// 2026-11-19, of a circle's banner: "needs to be taller and the back arrow and other header content should render
  /// inside the background image not above it"). Not under Dial-Up, whose title bar is its own.
  final Widget? headerBackground;
  final double headerExtra;

  /// The back arrow's colour over [headerBackground]; the page's ink where null.
  final Color? headerInk;

  /// No top bar at all, only a step under the status bar: for a page whose bar would be empty (the conversations with
  /// nothing to mark read and no plugin's button; Matt, 2026-11-19: "if there is no mark as read or cleaner icons
  /// rendered at the top remove the extra space above the searchbar too").
  final bool noBar;

  @override
  Widget build(BuildContext context) {
    // The page's name in the language drawn (lib/l10n/words.dart).
    final title = this.title.t;
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    // Beside the list (lib/ui/shell.dart) there is nowhere to go back to: the list is there to be seen.
    final back = this.back && (onBack != null || !PaneRoot.beside(context));
    final bar = t.lenOf('3.5rem');
    final lights = TopBarLights.roomOf(context);
    if (pad.top == 0) MacChrome.say(height: isBevelChrome(t) ? TitleBar.heightOf(t) : bar, dark: t.color('glacier-bg').computeLuminance() < 0.4);
    if (isBevelChrome(t)) return _dialup(context, t, pad, inset, back);
    // The top bar: on the Mac the window's own strip is gone and this is where it was, dragged to move the window, with
    // the three buttons centred in it at the window's left (lib/ui/window_chrome.dart).
    final row = WindowDragArea(
      child: SizedBox(
        height: bar,
        child: Row(
          children: [
            // Over a background (a circle's banner) the back arrow's round hover and press mark stays inside the picture's
            // rounded edge, as far in as the rest of the header (Matt, 2026-11-19: "when hovering the back arrow the
            // hover state goes over the left edge of the banner").
            // Over a background, almost flush with its left edge: two points in from the picture's left when hovered
            // (Matt, 2026-11-19: "remove the extra padding on the left of the back arrow ... so it sits almost flush when
            // hovered with the border of the background image").
            SizedBox(width: lights + (back ? (headerBackground == null ? t.space(1) : 2) : t.space(4))),
            // Centred on the row it starts, level with the circle's face and name beside it (Matt, 2026-11-20: "the back
            // arrow should be horizontally centered with the header text on the sidebar"); it was at the top corner.
            if (back && headerBackground != null)
              IconTap(key: const ValueKey('page-back'), icon: Lucide.arrowLeft, label: 'Back', size: 22, color: headerInk, onPressed: onBack ?? () => Navigator.of(context).maybePop())
            else if (back)
              IconTap(icon: Lucide.arrowLeft, label: 'Back', size: 22, onPressed: onBack ?? () => Navigator.of(context).maybePop()),
            Expanded(
              child: titleWidget ??
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: pageText(t, (bigTitle ?? !back) ? t.fontSize('2xl') : t.fontSize('lg'), weight: (bigTitle ?? !back) ? 'bold' : 'semibold', color: t.color('app-ink')),
                  ),
            ),
            ...actions,
            SizedBox(width: t.space(2)),
          ],
        ),
      ),
    );
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (headerBackground == null) ...[SizedBox(height: pad.top), ?top, if (noBar) SizedBox(height: t.space(3)) else row] else ...[
            // The header inside its background, the background under the phone's status bar (its clock and battery)
            // rather than behind it (Matt, 2026-11-19: "add a safe area above in the app to give room for the top bar
            // on the phone like the settings batteries and clock"); the row where it always is.
            // The row a step down, inside a background set in from its edges (CircleBanner's margin).
            // Inside it with a margin of its own on every side, as the picture's rounded edge has (Matt, 2026-11-19: "the
            // header doesn't line up with the header background image correctly"): the row stood on the picture's top
            // edge and out to the page's sides, so the circle's face touched or crossed the rounded top.
            SizedBox(height: pad.top),
            // Two points into the picture rather than a whole step: the row is taller than the face in it, which leaves
            // room enough above (Matt, 2026-11-20: "remove some of the extra space above the header text and profile
            // picture").
            SizedBox(
              height: t.space(2) + 2 + bar + headerExtra,
              child: Stack(fit: StackFit.expand, children: [
                headerBackground!,
                PositionedDirectional(top: t.space(2) + 2, start: t.space(2), end: t.space(2), height: bar, child: row),
              ]),
            ),
            ?top,
          ],
          const HeaderEnd(),
          Expanded(child: body),
          if (footer != null) Padding(padding: EdgeInsets.only(bottom: inset > 0 ? inset : pad.bottom), child: footer!),
        ],
      ),
    );
  }

  /// Dial-Up's page (Matt, 2026-11-16: "base one of them heavily on the old AOL chatrooms"): a window opened full
  /// screen, as the era's maximised windows were, edge to edge with no frame of its own. Its title bar has the
  /// page's name, its own header where it has one, its buttons, and one X as the way back (the system's back gesture
  /// still works: the X is only another way to it). The status bar's strip is the window's silver, and the foot that
  /// holds the composer is a silver panel to the screen's bottom edge.
  Widget _dialup(BuildContext context, Tokens t, EdgeInsets pad, double inset, bool back) {
    final c = DialupColors.of(t);
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(color: c.chrome, child: SizedBox(height: pad.top)),
          ?top,
          // The page's own header ([titleWidget]) is made with the page's tokens before it reaches here, so it cannot
          // be told it is on navy: the bar draws [title] and [subtitle] itself.
          WindowDragArea(
            child: Padding(
            padding: EdgeInsetsDirectional.only(start: TopBarLights.roomOf(context)),
            child: TitleBar(
            title: title,
            subtitle: subtitle,
            leading: titleLeading,
            titleChild: onTitle == null ? null : _PressTitle(title: title, subtitle: subtitle, onPressed: onTitle!),
            actions: actions,
            onClose: back ? (onBack ?? () => Navigator.of(context).maybePop()) : null,
          ),
          ),
          ),
          const HeaderEnd(),
          Expanded(child: body),
          if (footer != null)
            DialupPanel(
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.chrome, border: Border(top: BorderSide(color: c.hi, width: Bevel.ringOf(context)))),
                child: Padding(padding: EdgeInsets.only(bottom: inset > 0 ? inset : pad.bottom), child: footer!),
              ),
            ),
        ],
      ),
    );
  }
}

/// Dial-Up's title words where a press on them does something (a conversation's settings): the bar's name and its
/// line under it, read aloud as a button.
class _PressTitle extends StatelessWidget {
  const _PressTitle({required this.title, required this.subtitle, required this.onPressed});
  final String title;
  final String? subtitle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final desk = t.attrs['platform'] == 'desktop';
    final ink = DialupColors.of(t).titlebarInk;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: subtitle == null ? title : '$title, $subtitle',
      builder: (context, state) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, desk ? 14 : 16, weight: 'bold', color: ink)),
          if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, desk ? 12 : 14, color: ink)),
        ],
      ),
    );
  }
}

/// Something is being fetched: an arc going round, in the page's ink. Still under Android's "Remove animations".
class GhostSpinner extends StatefulWidget {
  const GhostSpinner({super.key, this.size = 22, this.label});
  final double size;

  /// What is being waited for, said under it.
  final String? label;

  @override
  State<GhostSpinner> createState() => _GhostSpinnerState();
}

class _GhostSpinnerState extends State<GhostSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    MediaQuery.disableAnimationsOf(context) ? _turn.stop() : _turn.repeat();
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Painted by itself: its turning does not have what stands round it painted again at every frame.
    final arc = RepaintBoundary(
      child: RotationTransition(
        turns: _turn,
        child: CustomPaint(size: Size.square(widget.size), painter: _ArcPainter(t.color('app-ink-2'), t.color('app-rule'))),
      ),
    );
    return Semantics(
      label: widget.label ?? 'Loading',
      liveRegion: true,
      child: ExcludeSemantics(
        child: widget.label == null
            ? arc
            : Column(mainAxisSize: MainAxisSize.min, children: [
                arc,
                SizedBox(height: t.space(3)),
                Text(widget.label!, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
      ),
    );
  }
}

/// The spinner's picture: a whole ring in [track], and over it an arc of about a third of the way round in [ink],
/// starting at the top. The spinner turns it.
class _ArcPainter extends CustomPainter {
  const _ArcPainter(this.ink, this.track);
  final Color ink;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.12;
    final rect = Offset.zero & size;
    final box = rect.deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(box, 0, 6.2832, false, paint..color = track);
    canvas.drawArc(box, -1.5708, 1.9, false, paint..color = ink);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.ink != ink || old.track != track;
}

/// Round the page a wide window shows beside the list of conversations (lib/ui/shell.dart): a conversation, a new
/// message, Settings. [beside] is whether the list is there to be seen, in which case the page draws no way back
/// (GhostPage). A page opened from that one is not under this, and keeps its way back.
class PaneRoot extends InheritedWidget {
  const PaneRoot({super.key, required this.isBeside, required super.child});
  final bool isBeside;

  static bool beside(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaneRoot>()?.isBeside ?? false;

  @override
  bool updateShouldNotify(PaneRoot old) => old.isBeside != isBeside;
}

/// Round a page that another has been laid over without leaving its place: the list of conversations under the
/// one opened on a narrow screen (lib/ui/shell.dart). Its header no longer says where the update banner hangs.
class HeaderCover extends InheritedWidget {
  const HeaderCover({super.key, required this.covered, required super.child});
  final bool covered;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HeaderCover>()?.covered ?? false;

  @override
  bool updateShouldNotify(HeaderCover old) => old.covered != covered;
}

/// Round a page that stands in a column of the window, not the whole of it: the list of conversations beside a
/// pane (lib/ui/shell.dart). What hangs under that page's header (the update banner) is as wide as the column.
class HeaderColumn extends InheritedWidget {
  const HeaderColumn({super.key, required this.left, required this.width, required super.child});
  final double left;
  final double width;

  @override
  bool updateShouldNotify(HeaderColumn old) => old.left != left || old.width != width;
}

/// Where a page's header ends: a mark of no size that a page puts under its header (GhostPage puts one under its
/// title; the list of conversations puts another under its search field). The update banner hangs just below the
/// lowest one on the page in front, so it is over the page's content and never over its header.
class HeaderEnd extends StatefulWidget {
  const HeaderEnd({super.key});

  static final _marks = <_HeaderEndState>{};

  /// Told whenever a mark comes, goes, or its page comes to the front or leaves it.
  static final changed = ValueNotifier<int>(0);

  /// Where the header of the page in front ends: the lowest such mark, as a line across the screen at its height.
  /// It runs the window's width (a width without end), unless its page stands in a column of the window
  /// ([HeaderColumn]: the list beside a pane), and then it is that column's. Beside a pane the list's mark is the
  /// lowest, its search field being under its title. Null where no page has said.
  static Rect? lowestRect() {
    Rect? found;
    for (final mark in _marks) {
      if (!mark.mounted || mark._covered || !(mark._route?.isCurrent ?? true)) continue;
      final box = mark.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (found == null || y > found.top) found = Rect.fromLTWH(mark._column?.left ?? 0, y, mark._column?.width ?? double.infinity, 0);
    }
    return found;
  }

  /// How far down the screen the header of the page in front ends, or null where no page has said.
  static double? lowest() => lowestRect()?.top;

  @override
  State<HeaderEnd> createState() => _HeaderEndState();
}

class _HeaderEndState extends State<HeaderEnd> {
  ModalRoute<dynamic>? _route;
  bool _covered = false;
  HeaderColumn? _column;

  // After the frame: this is called while building and painting, when listeners may not be told to rebuild.
  void _say() => WidgetsBinding.instance.addPostFrameCallback((_) => HeaderEnd.changed.value++);

  @override
  void initState() {
    super.initState();
    HeaderEnd._marks.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The page coming to the front or leaving it is a change of this, and so is its arriving.
    _route = ModalRoute.of(context);
    _covered = HeaderCover.of(context);
    _column = context.dependOnInheritedWidgetOfExactType<HeaderColumn>();
    _say();
  }

  @override
  void dispose() {
    HeaderEnd._marks.remove(this);
    _say();
    super.dispose();
  }

  // Told when it has moved up or down the screen (a row of chips came in over it, a line of words went): what
  // hangs under it follows.
  @override
  Widget build(BuildContext context) => _HeaderMark(onMoved: _say);
}

/// A line of no height that says when it has been drawn somewhere else down the screen than last time.
class _HeaderMark extends LeafRenderObjectWidget {
  const _HeaderMark({required this.onMoved});
  final VoidCallback onMoved;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeaderMark(onMoved);

  @override
  void updateRenderObject(BuildContext context, _RenderHeaderMark mark) => mark.onMoved = onMoved;
}

/// The mark's render box: as wide as it is given and of no height, and it calls [onMoved] from paint when its place
/// down the screen is not what it was at the last paint.
class _RenderHeaderMark extends RenderBox {
  _RenderHeaderMark(this.onMoved);
  VoidCallback onMoved;
  double? _y;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => Size(constraints.hasBoundedWidth ? constraints.maxWidth : 0, 0);

  @override
  void paint(PaintingContext context, Offset offset) {
    // How far down the screen, which a page sliding in from the side does not change.
    final y = localToGlobal(Offset.zero).dy;
    if (y != _y) {
      _y = y;
      onMoved();
    }
  }
}

/// Where the messages not yet read begin, in a group chat (Matt, 2026-11-16: "Add a "new messages" divider like
/// discord has for all group chats across telegram signal and RCS"): a thin red line across, and a small red "New"
/// at its end. It marks where they began as the chat was opened, and stays there while it is open.
class NewMessagesDivider extends StatelessWidget {
  const NewMessagesDivider({super.key});

  static const red = Color(0xFFDD3A30);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: 'New messages',
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space(2)),
        // Wavy like a ghost's hem, running on behind the tag (Matt, 2026-11-18: "Make the new chat marker wavy like a
        // ghost"; "make the new message more wavy and make the wave dissaper behind the tag that says new"). The wave is
        // measured from the tag, not from the far edge: it comes to the line's middle exactly at the tag's edge and
        // runs level under it, whatever the width (Matt, 2026-11-19: "the squiggle always ends in the middle of the
        // "new" tag i suggest starting the squiggle from that end so it's always lined up").
        child: Row(children: [
          Expanded(child: SizedBox(height: t.lenOf('1rem'), child: CustomPaint(painter: GhostHem(color: red, stroke: 2, tail: t.space(2))))),
          Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 1),
            decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(t.radius('sm'))),
            child: ExcludeSemantics(child: Text('New', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: const Color(0xFFFFFFFF), height: 1.3))),
          ),
        ]),
      ),
    );
  }
}

/// How many are unread, in a pill large enough to read at a glance (Matt, 2026-11-18: "The notification badges are too
/// small"): at least 1.375rem round, the count in 13-point bold, 99+ past ninety-nine; where no count is known, a dot
/// half as large. In [color], its words in whichever of black and white reads on it, or [ink].
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, this.count, required this.color, this.ink, this.square = false, this.mentioned = false});
  final int? count;
  final Color color;
  final Color? ink;

  /// Square corners, for Dial-Up's rows.
  final bool square;

  /// Something unread mentions the person: an "@" before the count, as other chat apps mark it (Matt, 2026-11-19:
  /// "Add mentions support to spaces and circles with the @user prefix").
  final bool mentioned;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = count;
    if ((n == null || n <= 0) && !mentioned) {
      final dot = t.lenOf('0.75rem');
      return Container(width: dot, height: dot, decoration: BoxDecoration(color: color, shape: square ? BoxShape.rectangle : BoxShape.circle));
    }
    final side = t.lenOf('1.375rem');
    final words = ink ?? (color.computeLuminance() > 0.5 ? const Color(0xFF000000) : const Color(0xFFFFFFFF));
    return Container(
      constraints: BoxConstraints(minWidth: side, minHeight: side),
      padding: EdgeInsets.symmetric(horizontal: t.space(2) - 1),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: square ? null : BorderRadius.circular(side / 2)),
      child: Text('${mentioned ? '@' : ''}${n == null || n <= 0 ? '' : (n > 99 ? '99+' : '$n')}', semanticsLabel: mentioned ? 'Mentions you${n == null || n <= 0 ? '' : ', $n unread'}' : null, style: t.textAt(13, weight: 'bold', height: 1.15, color: words)),
    );
  }
}

/// A ghost's hem as a line: a wave rising and falling as deep as it is drawn tall, drawn in [color]. It is measured
/// from its right end, so it always meets that end on its middle line, at the start of a wave, however wide it is;
/// whatever is cut short is at the left. [tail] carries it on level past the right edge, under what stands there (the
/// New tag), so the two join with no gap.
class GhostHem extends CustomPainter {
  const GhostHem({required this.color, this.stroke = 1.5, this.tail = 0});
  final Color color;
  final double stroke;
  final double tail;

  /// Half a wave's length for a line drawn [height] tall: as long as the wave is deep, and a little more, which is
  /// round and not a zigzag.
  static double halfWave(double height, double stroke) => math.max(1.5, height / 2 - stroke / 2) * 2.2;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final depth = math.max(1.5, mid - stroke / 2);
    final half = halfWave(size.height, stroke);
    final path = Path()
      ..moveTo(size.width + tail, mid)
      ..lineTo(size.width, mid);
    var x = size.width;
    var up = true;
    while (x > -half) {
      final peak = up ? mid - depth : mid + depth;
      // A cubic whose handles sit level with the peak gives a sine's soft crest.
      path.cubicTo(x - half * 0.36, peak, x - half * 0.64, peak, x - half, mid);
      x -= half;
      up = !up;
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, size.width + tail, size.height));
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = stroke..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(GhostHem old) => old.color != color || old.stroke != stroke || old.tail != tail;
}

/// The app's logo: the white speech bubble with UP LINK cut out of it, on black, as the icon on the home screen has
/// it (assets/art/ghost-mark.png, cut from the icon by tool/app_icon.py, and named for the ghost the mark was until
/// 2026-11-27). Black in either theme, since the mark is white. The mark is wider than it is tall and fills four
/// fifths of the tile, as it does of the icon.
class GhostLogo extends StatelessWidget {
  const GhostLogo({super.key, this.size});

  /// Its side; 2.75rem where not said, which fills the box an empty screen gives its picture.
  final double? size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final side = size ?? t.lenOf('2.75rem');
    // In a look of its own (Sharp, and Uplink's packs Mist and Lamplight) the mark is the look's ink on its paper, in
    // its corners: the black tile was the one pure black on Mist's aqua page.
    // Uplink's, and Dial-Up's on its desktop, are the app's own black tile.
    final own = t.attrs['theme-preset'] != null && t.attrs['theme-preset'] != 'dialup';
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: own ? t.color('app-paper-3') : const Color(0xFF000000),
        borderRadius: BorderRadius.circular(side * 0.27 * (own ? t.number('glacier-radius-scale').clamp(0.0, 1.0) : 1)),
        border: Border.all(color: t.color('app-rule')),
      ),
      alignment: Alignment.center,
      child: Image.asset('assets/art/ghost-mark.png', width: side * 0.8, height: side * 0.8, filterQuality: FilterQuality.medium, color: own ? t.color('app-ink') : null, colorBlendMode: own ? BlendMode.srcIn : null),
    );
  }
}

/// A round icon button with the kit's press and focus ring; [label] is what a screen reader says. Under Dial-Up it
/// is that look's own button instead.
class IconTap extends StatelessWidget {
  const IconTap({super.key, required this.icon, required this.label, required this.onPressed, this.size = 20, this.color, this.filled = false, this.box});

  final LucideIcon icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  /// Ink-filled disc with the icon in paper: the one main action on a screen (Send).
  final bool filled;

  /// The button's side; 2.75rem (a full touch target) by default.
  final double? box;

  @override
  Widget build(BuildContext context) {
    final label = this.label.t;
    final t = context.tokens;
    final box = this.box ?? t.lenOf('2.75rem');
    // Dial-Up: the one main action (Send) is a raised button with its word on it; the composer's own buttons stand
    // up as raised squares (RetroIcons); every other is a flat tool button that sinks while held.
    if (isBevelChrome(t)) {
      if (filled) return DialupSendButton(onPressed: onPressed, label: DialupSendButton.wordFor(label), semanticLabel: label);
      if (RetroIcons.of(context)) return RetroButton(onPressed: onPressed, icon: icon, semanticLabel: label, padding: EdgeInsets.zero);
      return DialupTool(icon: icon, label: label, onPressed: onPressed, size: size, color: color, box: t.lenOf('2.75rem'));
    }
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) {
        final off = onPressed == null;
        // A filled disc (Send) wears the app's accent: the bubble colour chosen everywhere (lib/accent.dart).
        // Off, it is grey with a grey icon, no colour at all until there is something to send (Matt, 2026-11-15: "on the
        // send button it should be gray with no colored icon until the message has text").
        final ink = filled ? (off ? t.color('app-ink-3') : t.color('app-on-accent')) : (color ?? t.color(state.pressed ? 'app-ink-3' : 'app-ink'));
        return GlacierFocusRing(
          visible: state.focused,
          radius: box,
          child: AnimatedScale(
            scale: state.pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: box,
              height: box,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled
                    ? (off ? t.color('app-paper-3') : t.color('app-accent'))
                    : (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)),
              ),
              alignment: Alignment.center,
              child: Opacity(opacity: off && !filled ? 0.4 : 1, child: AppIcon(icon, size: size, color: ink)),
            ),
          ),
        );
      },
    );
  }
}

/// The section colours of settings.css, one per person by their number, so a face keeps its colour everywhere.
const _hues = ['blue', 'purple', 'coral', 'green', 'amber', 'indigo', 'orange', 'cyan', 'rose', 'mint', 'magenta', 'slate'];

/// The colour's name for [address]: hashed from its last ten letters and digits, so a number written with or without
/// its spaces or country code's punctuation gets the same one.
String hueFor(String address) {
  final digits = address.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
  final key = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _hues[h % _hues.length];
}

/// Up to two capitals for a face: the first letters of the first and last words that start with a letter. Empty for
/// a bare number, which gets the person icon.
String initials(String label) {
  final words = label.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(w[0])).toList();
  if (words.isEmpty) return '';
  if (words.length == 1) return words[0][0].toUpperCase();
  return (words.first[0] + words.last[0]).toUpperCase();
}

/// A person's face: their contact photo, else their initials on their colour; a group is two faces overlapped.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.people, this.size = 44, this.presence = true});
  final List<Person> people;
  final double size;

  /// A dot on its corner while the one person it shows is online on a network that says so (Telegram's), wherever
  /// the face is drawn (Matt, 2026-11-17: "to be able to tell if a friend is online on a given plaform anywhere the
  /// users avatar is shown"). Off for a face that is not someone's (a group's picture).
  final bool presence;

  @override
  Widget build(BuildContext context) {
    final face = _face(context);
    if (!presence || people.length != 1 || people.first.address.isEmpty) return face;
    final address = people.first.address;
    return ListenableBuilder(
      listenable: Presence.changes,
      builder: (context, _) {
        final p = Presence.of(address);
        if (p == null || !(p.online || p.busy || p.away)) return face;
        final dot = (size * 0.3).clamp(8.0, 16.0);
        return Stack(clipBehavior: Clip.none, children: [
          face,
          PositionedDirectional(top: size * 0.02, end: size * 0.02, child: PresenceDot(presence: p, size: dot)),
        ]);
      },
    );
  }

  Widget _face(BuildContext context) {
    // Dial-Up: square, set into the page in a ring of the sunken bevel; a group is a picture of people in the first
    // person's colour, since overlapped squares read as a mistake and two halves of initials as one word.
    if (isBevelChrome(context.tokens)) {
      if (people.length > 1) {
        return DialupFace(
          size: size,
          child: GlacierScope(
            attrs: {'hue': hueFor(people.first.address)},
            child: Builder(builder: (context) {
              final t = context.tokens;
              return ColoredBox(color: settingsHueWash(t), child: Center(child: AppIcon(Lucide.users, size: size * 0.55, color: settingsHue(t))));
            }),
          ),
        );
      }
      return DialupFace(size: size, child: _Face(person: people.isEmpty ? const Person(address: '') : people.first, size: size, square: true));
    }
    if (people.length > 1) {
      final small = size * 0.68;
      return SizedBox.square(
        dimension: size,
        child: Stack(children: [
          PositionedDirectional(start: 0, top: 0, child: _Face(person: people[0], size: small)),
          PositionedDirectional(end: 0, bottom: 0, child: _Ringed(size: small, child: _Face(person: people[1], size: small))),
        ]),
      );
    }
    return _Face(person: people.isEmpty ? const Person(address: '') : people.first, size: size);
  }
}

/// A face in a ring of the page's colour, so the second face of a group stands clear of the one it overlaps.
class _Ringed extends StatelessWidget {
  const _Ringed({required this.size, required this.child});
  final double size;
  final Widget child;
  // The page's colour fills the ring too, so a face whose colour is see-through (initials on a hue wash) hides the face it overlaps.
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: context.tokens.color('glacier-bg'), border: Border.all(color: context.tokens.color('glacier-bg'), width: 2)),
        child: child,
      );
}

/// One person's face: their photo (a file, a web address, or a contact photo asked of the phone), and until it is
/// there or where there is none, their initials or the person icon on their colour.
class _Face extends StatelessWidget {
  const _Face({required this.person, required this.size, this.square = false});
  final Person person;
  final double size;

  /// Dial-Up's: square, to fill its frame (DialupFace).
  final bool square;

  @override
  Widget build(BuildContext context) {
    return GlacierScope(
      attrs: {'hue': hueFor(person.address)},
      child: Builder(builder: (context) {
        final t = context.tokens;
        final letters = initials(person.name ?? '');
        final fallback = Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: square ? BoxShape.rectangle : BoxShape.circle, color: settingsHueWash(t)),
          alignment: Alignment.center,
          child: letters.isEmpty
              ? AppIcon(Lucide.userRound, size: size * 0.5, color: settingsHue(t))
              : Text(letters, style: pageText(t, size * 0.38, weight: 'semibold', color: settingsHue(t))),
        );
        if (person.photo == null) return fallback;
        // A picture of a chat on another network (lib/inbox): a file Telegram brought down, or Bluesky's address.
        final photo = person.photo!;
        Widget clip(Widget child) => square ? ClipRect(child: child) : ClipOval(child: child);
        if (photo.startsWith('/')) {
          return clip(Image.file(File(photo), width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size), errorBuilder: (_, _, _) => fallback));
        }
        if (photo.startsWith('https://')) {
          return clip(Image.network(photo, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size), errorBuilder: (_, _, _) => fallback));
        }
        return FutureBuilder<Uint8List?>(
          future: Sms.instance.photo(person.photo!),
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) return fallback;
            return clip(Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size)));
          },
        );
      }),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// The time of day on a twelve-hour clock: 9:05 AM.
String clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// A conversation's time in the list: the time today, the weekday this week, else the date.
String listWhen(DateTime d, [DateTime? now]) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final ago = today.difference(day).inDays;
  if (ago <= 0) return clock(d);
  if (ago == 1) return 'Yesterday';
  if (ago < 7) return _days[d.weekday - 1];
  if (d.year == now.year) return '${_months[d.month - 1]} ${d.day}';
  return '${d.month}/${d.day}/${d.year % 100}';
}

/// The heading over a day's messages in a conversation.
String dayHeading(DateTime d, [DateTime? now]) {
  now ??= DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final ago = today.difference(day).inDays;
  if (ago <= 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  if (ago < 7) return _weekdays[d.weekday - 1];
  if (d.year == now.year) return '${_days[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Opens a page from the right, as Ghost Keyboard's settings pages do. Under Dial-Up it simply appears, as the era's
/// windows did.
Future<T?> push<T>(BuildContext context, WidgetBuilder builder) => pushOn<T>(Navigator.of(context), context, builder);

/// [push], on [navigator]: for what is drawn over the app's pages and so has no navigator above it (the recording's
/// pill, lib/ui/recording_float.dart). [context] is only asked for the look.
Future<T?> pushOn<T>(NavigatorState navigator, BuildContext context, WidgetBuilder builder) {
  final still = isBevelChrome(context.tokens);
  return navigator.push<T>(
      PageRouteBuilder<T>(
        transitionDuration: still ? Duration.zero : const Duration(milliseconds: 260),
        reverseTransitionDuration: still ? Duration.zero : const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
          child: child,
        ),
      ),
    );
}

/// Says [message] in a toast, on the toasts nearest above [context].
void toast(BuildContext context, String message, {GlacierToastTone tone = GlacierToastTone.neutral, GlacierToastAction? action}) {
  GlacierToast.of(context).toast(message: Text(message), tone: tone, action: action);
}

/// A sheet rising from the foot of the screen with a list of choices: a long press's menu.
Future<void> showChoices(BuildContext context, {String? title, Widget? header, required List<Choice> choices}) {
  // On the app's outermost navigator, over everything: asked for from the list, whose own navigator stands under the
  // navigation pill, the sheet's last choices were behind the pill and could not be pressed (Matt, 2026-11-14: "the
  // context menu ... opens behind the navbar so you can't click delete").
  final still = isBevelChrome(context.tokens);
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: still ? Duration.zero : const Duration(milliseconds: 220),
    reverseTransitionDuration: still ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => _ChoiceSheet(title: title, header: header, choices: choices),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// One row of [showChoices]: its words, its icon, and what pressing it does; [danger] draws it as something that
/// removes or can't be undone.
class Choice {
  const Choice(this.label, this.icon, this.onPress, {this.danger = false, this.mark, this.hint});
  final String label;
  final LucideIcon icon;
  final VoidCallback onPress;
  final bool danger;

  /// Drawn in the icon's place: a network's own mark (lib/ui/contacts.dart's "Message … with").
  final Widget? mark;

  /// A second line under the label.
  final String? hint;
}

/// The sheet [showChoices] raises: a title or a header of its own, then the choices; a window of its own under
/// Dial-Up.
class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({this.title, this.header, required this.choices});
  final String? title;
  final Widget? header;
  final List<Choice> choices;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    if (isBevelChrome(t)) return _dialup(context, t, pad);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
        // A sheet's width, where the window is wider than a phone: not a band across the whole of it.
        // And no taller than the screen: a long list of choices scrolls inside the sheet.
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: MediaQuery.sizeOf(context).height - pad.top - pad.bottom - t.space(8)), child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radius('xl')),
          child: ColoredBox(
            color: t.color('app-paper-2'),
            child: SingleChildScrollView(child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(4), t.space(4), t.space(2)),
                    // A message's own words are cut short by whoever asks; what a sheet explains is said whole.
                    child: Text(title!.t, maxLines: 14, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
                  ),
                ?header,
                for (final c in choices)
                  GlacierPressable(
                    onPressed: () {
                      Navigator.of(context).pop();
                      c.onPress();
                    },
                    builder: (context, state) {
                      final ink = c.danger ? t.danger : t.color('app-ink');
                      return ColoredBox(
                        color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(3)),
                          child: Row(children: [
                            c.mark ?? AppIcon(c.icon, size: 20, color: ink),
                            SizedBox(width: t.space(3)),
                            // A long line wraps rather than running off the sheet.
                            Flexible(
                              child: c.hint == null
                                  ? Text(c.label.t, style: pageText(t, t.fontSize('md'), weight: 'medium', color: ink))
                                  : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                      Text(c.label.t, style: pageText(t, t.fontSize('md'), weight: 'medium', color: ink)),
                                      Text(c.hint!.t, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                                    ]),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                SizedBox(height: t.space(2)),
              ],
            )),
          ),
        )),
      ),
    );
  }

  /// Dial-Up's: the era's pop-up menu, a silver panel in a raised frame, each choice a row the height of a finger
  /// that turns navy with white words while pressed. The words are the window's black, a dangerous one red.
  Widget _dialup(BuildContext context, Tokens t, EdgeInsets pad) {
    final c = DialupColors.of(t);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: MediaQuery.sizeOf(context).height - pad.top - pad.bottom - t.space(8)),
          child: Bevel(
            padding: const EdgeInsets.all(2),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 10, 6),
                    child: Text(title!.t, maxLines: 14, overflow: TextOverflow.ellipsis, style: pageText(t, 14, color: c.onChrome, height: 1.35)),
                  ),
                if (title != null) _etch(c),
                ?header,
                for (final choice in choices)
                  GlacierPressable(
                    onPressed: () {
                      Navigator.of(context).pop();
                      choice.onPress();
                    },
                    builder: (context, state) {
                      final ink = state.pressed ? c.onHighlight : (choice.danger ? t.danger : c.onChrome);
                      return ColoredBox(
                        color: state.pressed ? c.highlight : const Color(0x00000000),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Row(children: [
                              choice.mark ?? AppIcon(choice.icon, size: 18, color: ink, wash: false),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                  Text(choice.label.t, style: pageText(t, 16, color: ink)),
                                  if (choice.hint != null) Text(choice.hint!.t, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, 13, color: state.pressed ? c.onHighlight : c.inkSoft)),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// The era's etched line between a menu's parts: grey over white.
  static Widget _etch(DialupColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Column(children: [SizedBox(height: 1, child: ColoredBox(color: c.shadow)), SizedBox(height: 1, child: ColoredBox(color: c.hi))]),
      );
}


/// Opens gogho.st's docs at [page] ("pairing", "discord"; the docs' home where empty) in the browser (Matt, 2026-11-19:
/// "Spend time creating a /docs/ page on ghost messaging", linked "In the app": Settings › About and a "?" on screens
/// that need it).
void openDocs([String page = '']) => Sms.instance.openLink('https://gogho.st/docs/${page.isEmpty ? '' : '$page/'}');

/// The "?" in a screen's header that opens its page in the docs ([openDocs]).
Widget docsButton(String page, {String label = 'Help with this'}) => IconTap(icon: Lucide.info, label: label, onPressed: () => openDocs(page));


/// The mark on a face for how someone is (GMFB-34): green online, a red disc with a bar for Busy, an amber moon for
/// Away, each ringed in the page's colour.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.presence, required this.size});
  final InboxPresence presence;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = presence;
    final ring = t.color('glacier-bg');
    final edge = (size * 0.18).clamp(1.5, 2.5);
    final (colour, label) = p.busy
        ? (const Color(0xFFED4245), 'Busy')
        : p.online
            ? (const Color(0xFF34C759), 'Online on ${p.network}')
            : (const Color(0xFFF0B232), 'Away');
    return Semantics(
      label: label,
      child: Container(
        key: ValueKey('presence-${p.busy ? 'busy' : p.online ? 'online' : 'away'}'),
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(shape: BoxShape.circle, color: colour, border: Border.all(color: ring, width: edge)),
        child: p.busy
            ? Center(child: Container(width: size * 0.42, height: (size * 0.14).clamp(1.5, 3.0), decoration: BoxDecoration(color: ring, borderRadius: BorderRadius.circular(2))))
            : (!p.online
                // A crescent: the disc with a bite of the page's colour out of its top right.
                ? Align(alignment: const Alignment(0.7, -0.7), child: Container(width: size * 0.5, height: size * 0.5, decoration: BoxDecoration(shape: BoxShape.circle, color: ring)))
                : null),
      ),
    );
  }
}
