/// Where something is still being read: the shapes of what will stand there, in grey, with a light passing over them
/// (Matt, 2026-11-24: "show better loading states with skeletal loaders and a connecting banner so it doesn't just
/// seem like the app is frozen"). A small arc turning in the middle of an empty page said nothing of what was coming
/// and was easy to miss; the page drawn in grey says what is loading and, moving, that the app is alive.
///
/// [Skeleton] is the clock and what is read aloud; [Bone] is one shape; the rest are the app's own pages in bones:
/// [SkeletonCards] a list of conversations, [SkeletonChat] a chat's messages, [SkeletonPeople] rows of people,
/// [SkeletonFiles] a folder.
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../backgrounds.dart' show lookCorner, lookRim;
import 'dialup/bevel.dart' show isBevelChrome;
import 'flat_line.dart' show FlatLine;

/// The shapes under it share one light, which crosses the whole window at once and not each shape by itself. What is
/// being waited for ([label]) is read aloud in their place. Still under "Remove animations".
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child, this.label = 'Loading'});
  final Widget child;

  /// What is being waited for.
  final String label;

  /// How long the light takes to cross, and to come again.
  static const every = Duration(milliseconds: 1500);

  /// The light's place for the shapes under [context], 0 to 1 again and again; null outside a [Skeleton], where a
  /// shape rests.
  static Animation<double>? clockOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SkeletonClock>()?.clock;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: Skeleton.every);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || context.tokens.reducedMotion) {
      _sweep
        ..stop()
        ..value = 0;
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: widget.label,
        liveRegion: true,
        container: true,
        // Painted by itself: the light moving does not have the page round it painted again at every frame.
        child: ExcludeSemantics(child: RepaintBoundary(child: _SkeletonClock(clock: _sweep, child: widget.child))),
      );
}

class _SkeletonClock extends InheritedWidget {
  const _SkeletonClock({required this.clock, required super.child});
  final Animation<double> clock;

  @override
  bool updateShouldNotify(_SkeletonClock old) => old.clock != clock;
}

/// One grey shape: a line of words ([height] high, as wide as it is given or as [width] says), a face ([circle]), a
/// picture. Its corners are the look's own, square where the look is.
class Bone extends LeafRenderObjectWidget {
  const Bone({super.key, this.width, this.height = 12, this.radius, this.circle = false});

  /// A face [size] across.
  const Bone.face(double size, {super.key})
      : width = size,
        height = size,
        radius = null,
        circle = true;

  /// As wide as this; null takes all the width there is.
  final double? width;
  final double height;

  /// Its corners; null rounds a line fully and leaves a tall shape at the look's own corner.
  final double? radius;
  final bool circle;

  /// The grey a shape rests in, and the grey of the light: ink over whatever it stands on, so a shape reads on the
  /// page, on a card and on a chat's own background alike. The light is brighter than the shape on a dark page and
  /// paler on a light one, so it is light passing on both.
  static (Color, Color) colours(Tokens t) {
    // The page's ink, or the grey a look names where its ink is a colour (`--app-skeleton`: Runestone's yellow made
    // every shape olive).
    final ink = t.colorOf('var(--app-skeleton, var(--app-ink))');
    final dark = t.color('app-paper').computeLuminance() < 0.4;
    return (ink.withValues(alpha: dark ? 0.10 : 0.09), ink.withValues(alpha: dark ? 0.19 : 0.035));
  }

  double _corner(Tokens t) {
    if (isBevelChrome(t)) return 0;
    if (circle) return height / 2;
    final asked = radius;
    if (asked != null) return lookCorner(t, '${asked / 16}rem');
    return height <= 20 ? height / 2 : lookCorner(t, '0.75rem');
  }

  @override
  RenderObject createRenderObject(BuildContext context) {
    final t = context.tokens;
    final (rest, light) = colours(t);
    return _RenderBone(width: width, height: height, corner: _corner(t), rest: rest, light: light, clock: Skeleton.clockOf(context), window: MediaQuery.sizeOf(context));
  }

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    final t = context.tokens;
    final (rest, light) = colours(t);
    (renderObject as _RenderBone)
      ..width = width
      ..height = height
      ..corner = _corner(t)
      ..rest = rest
      ..light = light
      ..clock = Skeleton.clockOf(context)
      ..window = MediaQuery.sizeOf(context);
  }
}

class _RenderBone extends RenderBox {
  _RenderBone({required double? width, required double height, required double corner, required Color rest, required Color light, required Animation<double>? clock, required Size window})
      : _width = width,
        _height = height,
        _corner = corner,
        _rest = rest,
        _light = light,
        _clock = clock,
        _window = window;

  double? _width;
  set width(double? v) {
    if (v == _width) return;
    _width = v;
    markNeedsLayout();
  }

  double _height;
  set height(double v) {
    if (v == _height) return;
    _height = v;
    markNeedsLayout();
  }

  double _corner;
  set corner(double v) {
    if (v == _corner) return;
    _corner = v;
    markNeedsPaint();
  }

  Color _rest, _light;
  set rest(Color v) {
    if (v == _rest) return;
    _rest = v;
    markNeedsPaint();
  }

  set light(Color v) {
    if (v == _light) return;
    _light = v;
    markNeedsPaint();
  }

  /// The window: what the light crosses.
  Size _window;
  set window(Size v) {
    if (v == _window) return;
    _window = v;
    markNeedsPaint();
  }

  Animation<double>? _clock;
  set clock(Animation<double>? v) {
    if (identical(v, _clock)) return;
    if (attached) _clock?.removeListener(markNeedsPaint);
    _clock = v;
    if (attached) _clock?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _clock?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _clock?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => false;

  Size _sizeFor(BoxConstraints c) => c.constrain(Size(_width ?? (c.hasBoundedWidth ? c.maxWidth : 120), _height));

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);

  @override
  void performLayout() => size = _sizeFor(constraints);

  @override
  double computeMinIntrinsicWidth(double height) => _width ?? 0;
  @override
  double computeMaxIntrinsicWidth(double height) => _width ?? 0;
  @override
  double computeMinIntrinsicHeight(double width) => _height;
  @override
  double computeMaxIntrinsicHeight(double width) => _height;

  @override
  void paint(PaintingContext context, Offset offset) {
    final shape = RRect.fromRectAndRadius(offset & size, Radius.circular(_corner));
    final at = _clock?.value ?? 0;
    final paint = Paint()..color = _rest;
    // The light is one band across the whole window, leaning like a slash, so every shape is lit as it passes: where
    // this shape is in the window decides when. At rest (no clock, or "Remove animations") there is no band.
    if (at > 0 && !_window.isEmpty) {
      final band = (_window.width * 0.45).clamp(160.0, 460.0);
      // Where the band's middle crosses the window's top edge: from clear of the left to clear of the right at the
      // window's foot, where the lean has it arrive last.
      final x = -band + at * (_window.width + band * 2 + _window.height * _lean);
      final from = Offset(x - band / 2, 0);
      final to = from + const Offset(1, _lean) * (band / (1 + _lean * _lean));
      // In this layer's own measure: the shape's corner is at [offset] here and at [where] in the window.
      final shift = offset - localToGlobal(Offset.zero);
      // Opaque under the shader: a paint's own alpha is multiplied into what its shader draws, and the greys are
      // already as faint as they should be.
      paint
        ..color = const Color(0xFF000000)
        ..shader = ui.Gradient.linear(from + shift, to + shift, [_rest, _light, _rest], const [0, 0.5, 1]);
    }
    context.canvas.drawRRect(shape, paint);
  }

  /// How far the band leans: this much to the left for each point down the window.
  static const _lean = 0.35;
}

/// How wide the lines of row [i] are, as shares of the room there is: a few lengths in turn, so a list in bones is not
/// a ladder of identical lines.
double _share(int i, {int salt = 0}) => const [0.52, 0.36, 0.64, 0.44, 0.58, 0.32, 0.48, 0.7][(i + salt) % 8];

/// One line of words in bones: [share] of the room there is, [height] high, and of no more than [most], so a line in
/// a wide window is still the length of a name or a sentence and not a bar across it.
class _Line extends StatelessWidget {
  const _Line(this.share, {this.height = 12, this.most = 420});
  final double share, height, most;

  @override
  Widget build(BuildContext context) => Align(
        alignment: AlignmentDirectional.centerStart,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: most),
          child: FractionallySizedBox(alignment: AlignmentDirectional.centerStart, widthFactor: share.clamp(0.0, 1.0), child: Bone(height: height)),
        ),
      );
}

/// A list of conversations in bones (lib/ui/conversations.dart's cards: a face, a name, the last words and a time).
/// More than fill the room there is, cut off at its foot; nothing to scroll.
class SkeletonCards extends StatelessWidget {
  const SkeletonCards({super.key, this.label = 'Loading', this.most = 14, this.shrink = false});
  final String label;
  final int most;

  /// As tall as its cards, as rows of a list that holds real ones (more being read at its foot); otherwise it
  /// fills the room there is.
  final bool shrink;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final dialup = isBevelChrome(t);
    final face = dialup ? 24.0 : t.lenOf('3rem');
    Widget card(int i) {
      final lines = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: _Line(_share(i), height: dialup ? 10 : 13, most: 300)),
          SizedBox(width: t.space(3)),
          const Bone(width: 34, height: 10),
        ]),
        if (!dialup) ...[SizedBox(height: t.space(2)), _Line(_share(i, salt: 3) + 0.22, height: 11, most: 520)],
      ]);
      // Dial-Up's list is close rows in a sunken well, with no cards.
      if (dialup) {
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 5),
          child: Row(children: [Bone(width: face, height: face), SizedBox(width: t.space(2)), Expanded(child: lines)]),
        );
      }
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
        child: Container(
          decoration: BoxDecoration(
            color: t.color('app-paper-2'),
            borderRadius: BorderRadius.circular(lookCorner(t, '1rem')),
            border: Border.all(color: lookRim(t) == null ? const Color(0x00000000) : t.color('glacier-border-subtle'), width: 2),
          ),
          padding: EdgeInsets.symmetric(horizontal: t.space(3) - 2, vertical: t.space(3) - 2),
          child: Row(children: [Bone.face(face), SizedBox(width: t.space(3)), Expanded(child: lines)]),
        ),
      );
    }

    final cards = [for (var i = 0; i < most; i++) card(i)];
    return Skeleton(
      label: label,
      child: shrink
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: cards)
          : ListView(key: const ValueKey('skeleton-cards'), physics: const NeverScrollableScrollPhysics(), padding: EdgeInsets.zero, children: cards),
    );
  }
}

/// A chat's messages in bones: bubbles from both sides (or a channel's lines, [flat]), the newest at the foot as a chat has
/// them. [bottom] is the
/// room kept clear under them (the composer's).
class SkeletonChat extends StatelessWidget {
  const SkeletonChat({super.key, this.label = 'Loading messages', this.bottom = 0, this.faces = false, this.flat = false, this.most = 16, this.shrink = false});
  final String label;
  final double bottom;

  /// A channel's lines rather than bubbles (lib/ui/flat_line.dart): everyone on the left, a face, a name and a time over
  /// each run.
  final bool flat;

  /// As tall as its bubbles, over the oldest message of a chat while earlier ones are read; otherwise it fills the
  /// room there is.
  final bool shrink;

  /// A face beside what others wrote, as a group's and a space's chat have.
  final bool faces;
  final int most;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Whose each is, the newest first: mostly theirs, some of one's own, never a regular beat.
    const mine = [false, true, true, false, false, true, false, false, true, false, true, false];
    const tall = [1, 1, 2, 1, 3, 1, 1, 2, 1, 1, 2, 1];
    Widget bubble(int i) {
      final own = mine[i % mine.length];
      final rows = tall[i % tall.length];
      final shape = FractionallySizedBox(
        widthFactor: (_share(i, salt: 2) + (rows > 1 ? 0.12 : 0)).clamp(0.2, 0.78),
        alignment: own ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        child: Bone(height: 20.0 + rows * 18, radius: 18),
      );
      return Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 3, t.space(3), i > 0 && mine[(i - 1) % mine.length] == own ? 3 : t.space(3)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (faces && !own) ...[const Bone.face(28), SizedBox(width: t.space(2))],
          Expanded(child: shape),
        ]),
      );
    }

    // A run's lines of words under its face, name and time, where they stand in a channel ([FlatLine]).
    Widget run(int i) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Bone.face(FlatLine.faceSize(t)),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                SizedBox(height: t.space(1)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(child: Bone(width: 70 + 80 * _share(i, salt: 1), height: 13)),
                  SizedBox(width: t.space(2)),
                  const Bone(width: 40, height: 10),
                ]),
                for (var row = 0; row < tall[i % tall.length]; row++)
                  Padding(padding: EdgeInsets.only(top: t.space(2)), child: _Line(_share(i + row, salt: 2) + 0.15, height: 12, most: 540)),
              ]),
            ),
          ]),
        );

    final bubbles = [for (var i = 0; i < most; i++) flat ? run(i) : bubble(i)];
    return Skeleton(
      label: label,
      child: shrink
          // The newest at the foot here too: the list above is drawn the other way up.
          ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: bubbles.reversed.toList())
          : ListView(
              key: const ValueKey('skeleton-chat'),
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: bottom + t.space(2), top: t.space(2)),
              children: bubbles,
            ),
    );
  }
}

/// Rows of people in bones: a face and a name, and a line under it where the rows have one ([second]).
class SkeletonPeople extends StatelessWidget {
  const SkeletonPeople({super.key, this.label = 'Loading', this.most = 12, this.face = 40, this.second = true, this.padding, this.shrink = false});
  final String label;
  final int most;
  final double face;
  final bool second;
  final EdgeInsets? padding;

  /// As tall as its rows, inside a list of other things; otherwise it fills the room there is.
  final bool shrink;

  /// One person's row, for a list that holds bones among real rows (a call's people still to come).
  static Widget row(Tokens t, int i, {double face = 40, bool second = true}) => Padding(
        padding: EdgeInsets.symmetric(vertical: t.space(2)),
        child: Row(children: [
          Bone.face(face),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              _Line(_share(i, salt: 1) * 0.8, height: 13, most: 300),
              if (second) ...[SizedBox(height: t.space(2)), _Line(_share(i, salt: 4) * 0.6, height: 10, most: 300)],
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rows = [for (var i = 0; i < most; i++) row(t, i, face: face, second: second)];
    final pad = padding ?? EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2));
    return Skeleton(
      label: label,
      child: shrink
          ? Padding(padding: pad, child: Column(mainAxisSize: MainAxisSize.min, children: rows))
          : ListView(key: const ValueKey('skeleton-people'), physics: const NeverScrollableScrollPhysics(), padding: pad, children: rows),
    );
  }
}

/// A folder in bones: a file's mark, its name, and its size and date under it.
class SkeletonFiles extends StatelessWidget {
  const SkeletonFiles({super.key, this.label = 'Loading files', this.most = 10, this.padding});
  final String label;
  final int most;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Skeleton(
      label: label,
      child: ListView(
        key: const ValueKey('skeleton-files'),
        physics: const NeverScrollableScrollPhysics(),
        padding: padding ?? EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        children: [
          for (var i = 0; i < most; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(2)),
              child: Row(children: [
                const Bone(width: 40, height: 40, radius: 10),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    _Line(_share(i, salt: 5), height: 13),
                    SizedBox(height: t.space(2)),
                    _Line(_share(i, salt: 2) * 0.5, height: 10, most: 300),
                  ]),
                ),
                SizedBox(width: t.space(3)),
                const Bone(width: 22, height: 22, radius: 6),
              ]),
            ),
        ],
      ),
    );
  }
}

/// A picture's place while the picture is fetched: all of the room it is given, in bone.
class SkeletonPicture extends StatelessWidget {
  const SkeletonPicture({super.key, this.label = 'Loading the picture', this.radius = 0});
  final String label;
  final double radius;

  @override
  Widget build(BuildContext context) => Skeleton(label: label, child: Bone(height: double.infinity, radius: radius));
}

/// The lines of something written, while it is read: a file's words, a page of a list with one line a row.
class SkeletonLines extends StatelessWidget {
  const SkeletonLines({super.key, this.label = 'Loading', this.most = 14, this.padding, this.shrink = false});
  final String label;
  final int most;
  final EdgeInsets? padding;
  final bool shrink;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = padding ?? EdgeInsets.all(t.space(4));
    final lines = [for (var i = 0; i < most; i++) Padding(padding: EdgeInsets.symmetric(vertical: t.space(2)), child: _Line(_share(i, salt: 6) + 0.25, height: 11, most: 720))];
    return Skeleton(
      label: label,
      child: shrink
          ? Padding(padding: pad, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: lines))
          : ListView(key: const ValueKey('skeleton-lines'), physics: const NeverScrollableScrollPhysics(), padding: pad, children: lines),
    );
  }
}
