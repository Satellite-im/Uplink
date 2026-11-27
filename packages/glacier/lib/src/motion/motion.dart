import 'dart:async';

import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import '../tokens/tokens.dart';

/// `@glacier/motion`: the kit's micro-animation vocabulary. The times and easings are the motion tokens, read from the
/// theme, so reduced motion collapses them here as it does on the page.
enum Motion { fadeIn, fadeOut, scaleIn, scaleOut, slideUp, slideDown, slideLeft, slideRight, riseIn, collapse, expand, shake, pulse, bounce, shimmer }

/// The steps of the duration scale: `--glacier-duration-NAME`.
enum Speed { instant, fast, normal, slow, slower }

/// The easings: `--glacier-ease-NAME`, by way of [_easeToken].
enum Ease { out, inOut, spring, exit }

/// The spring presets [springDescription] gives.
enum Spring { snappy, smooth, bouncy }

const _easeToken = {Ease.out: 'out', Ease.inOut: 'in-out', Ease.spring: 'spring', Ease.exit: 'exit'};

/// The spring presets, as framer-motion was given them.
SpringDescription springDescription([Spring preset = Spring.snappy]) {
  switch (preset) {
    case Spring.snappy:
      return const SpringDescription(mass: 0.9, stiffness: 520, damping: 38);
    case Spring.smooth:
      return const SpringDescription(mass: 1, stiffness: 300, damping: 34);
    case Spring.bouncy:
      return const SpringDescription(mass: 1, stiffness: 460, damping: 26);
  }
}

/// A time and an easing: `transition(speed, ease)`.
class MotionTiming {
  const MotionTiming(this.duration, this.curve, [this.delay = Duration.zero]);
  final Duration duration;
  final Curve curve;
  final Duration delay;

  MotionTiming delayed(Duration by) => MotionTiming(duration, curve, by);
}

/// The timing for a speed and an easing, from the motion tokens in force.
MotionTiming transition(Tokens tokens, [Speed speed = Speed.normal, Ease ease = Ease.out]) =>
    MotionTiming(tokens.duration('glacier-duration-${speed.name}'), tokens.curve('glacier-ease-${_easeToken[ease]}'));

/// The timing for item [index] of a staggered entrance: the base timing, later by the stagger step for each one before.
MotionTiming staggerDelay(Tokens tokens, int index, [MotionTiming? base]) {
  final from = base ?? transition(tokens, Speed.normal, Ease.out);
  return from.delayed(tokens.duration('glacier-stagger-step') * index);
}

/// Named press-in depths, by a control's weight: a card barely moves, an icon button presses noticeably.
enum PressScale {
  surface(0.99),
  control(0.97),
  chip(0.96),
  compact(0.94);

  const PressScale(this.scale);
  final double scale;
}

/// How far a [Motion] has come: what it does to the child at [t], 0 at the start and 1 at rest.
class _Pose {
  const _Pose({this.opacity = 1, this.scale = 1, this.dx = 0, this.dy = 0, this.height = 1});
  final double opacity, scale, dx, dy, height;

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
        opacity: a.opacity + (b.opacity - a.opacity) * t,
        scale: a.scale + (b.scale - a.scale) * t,
        dx: a.dx + (b.dx - a.dx) * t,
        dy: a.dy + (b.dy - a.dy) * t,
        height: a.height + (b.height - a.height) * t,
      );
}

/// One [Motion] written out: where it starts, where it rests, where it leaves to (null where it has no exit and
/// is simply taken away), and its default speed and easing. Offsets are in logical pixels.
class _Spec {
  const _Spec(this.initial, this.rest, this.exit, this.speed, this.ease);
  final _Pose initial, rest;
  final _Pose? exit;
  final Speed speed;
  final Ease ease;
}

/// The poses of each [Motion]. The attention effects have none: they are drawn from the clock in the build.
_Spec _spec(Motion kind) {
  const hidden = _Pose(opacity: 0), shown = _Pose();
  switch (kind) {
    case Motion.fadeIn:
      return const _Spec(hidden, shown, hidden, Speed.normal, Ease.out);
    case Motion.fadeOut:
      return const _Spec(shown, hidden, null, Speed.fast, Ease.exit);
    case Motion.scaleIn:
      return const _Spec(_Pose(opacity: 0, scale: 0.96), shown, _Pose(opacity: 0, scale: 0.98), Speed.fast, Ease.out);
    case Motion.scaleOut:
      return const _Spec(shown, _Pose(opacity: 0, scale: 0.96), null, Speed.fast, Ease.exit);
    case Motion.slideUp:
      return const _Spec(_Pose(opacity: 0, dy: 8), shown, _Pose(opacity: 0, dy: 8), Speed.normal, Ease.out);
    case Motion.slideDown:
      return const _Spec(_Pose(opacity: 0, dy: -8), shown, _Pose(opacity: 0, dy: -8), Speed.normal, Ease.out);
    case Motion.slideLeft:
      return const _Spec(_Pose(opacity: 0, dx: 8), shown, _Pose(opacity: 0, dx: 8), Speed.normal, Ease.out);
    case Motion.slideRight:
      return const _Spec(_Pose(opacity: 0, dx: -8), shown, _Pose(opacity: 0, dx: -8), Speed.normal, Ease.out);
    case Motion.riseIn:
      return const _Spec(_Pose(opacity: 0, dy: 14), shown, _Pose(opacity: 0, dy: 14), Speed.normal, Ease.out);
    case Motion.collapse:
      return const _Spec(shown, _Pose(opacity: 0, height: 0), null, Speed.normal, Ease.inOut);
    case Motion.expand:
      return const _Spec(_Pose(opacity: 0, height: 0), shown, _Pose(opacity: 0, height: 0), Speed.normal, Ease.inOut);
    case Motion.shake:
    case Motion.pulse:
    case Motion.bounce:
    case Motion.shimmer:
      return const _Spec(shown, shown, null, Speed.normal, Ease.out);
  }
}

/// A child that enters by a [Motion] and, when [present] turns false, leaves by its exit before it is taken out of
/// the tree: `motionProps(kind)` on a `motion.div` inside `AnimatePresence`. The attention effects (shake once; pulse,
/// bounce and shimmer for as long as they are shown) animate in place; change the key to replay a shake.
class GlacierMotion extends StatefulWidget {
  const GlacierMotion({
    super.key,
    required this.kind,
    this.speed,
    this.ease,
    this.delay = Duration.zero,
    this.present = true,
    this.alignment = Alignment.center,
    this.onGone,
    required this.child,
  });

  final Motion kind;
  final Speed? speed;
  final Ease? ease;
  final Duration delay;

  /// False plays the exit; the child stays mounted until it has finished.
  final bool present;

  /// What a scale grows from (`transform-origin`).
  final Alignment alignment;
  final VoidCallback? onGone;
  final Widget child;

  @override
  State<GlacierMotion> createState() => _GlacierMotionState();
}

class _GlacierMotionState extends State<GlacierMotion> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  /// Whether the first entrance has been set off, the exit is playing, and the exit has finished (nothing is
  /// built from then on).
  bool _started = false;
  bool _leaving = false;
  bool _gone = false;

  /// The wait before a delayed entrance begins: a staggered row's turn.
  Timer? _wait;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _enter();
  }

  @override
  void didUpdateWidget(GlacierMotion old) {
    super.didUpdateWidget(old);
    if (old.present && !widget.present) _leave();
    if (!old.present && widget.present) {
      _leaving = false;
      _gone = false;
      _enter();
    }
  }

  /// Puts the child at its first pose and plays the entrance, after [GlacierMotion.delay] where there is one.
  void _enter() {
    _controller.value = 0;
    _wait?.cancel();
    if (widget.delay > Duration.zero) {
      _wait = Timer(widget.delay, _begin);
    } else {
      _begin();
    }
  }

  /// Starts the clock: once through for an entrance or a shake, round and round for pulse, bounce and shimmer.
  void _begin() {
    if (!mounted) return;
    final tokens = GlacierTheme.of(context);
    final spec = _spec(widget.kind);
    final timing = transition(tokens, widget.speed ?? spec.speed, widget.ease ?? spec.ease);
    switch (widget.kind) {
      case Motion.shake:
        _controller.duration = tokens.duration('glacier-duration-slow');
        _controller.forward();
      case Motion.pulse:
        _controller.duration = _reduced(tokens, const Duration(milliseconds: 1200));
        _controller.repeat();
      case Motion.bounce:
        _controller.duration = _reduced(tokens, const Duration(milliseconds: 1000));
        _controller.repeat();
      case Motion.shimmer:
        _controller.duration = _reduced(tokens, const Duration(milliseconds: 1400));
        _controller.repeat();
      default:
        _controller.duration = timing.duration;
        _controller.forward();
    }
  }

  /// A looping effect's period, or no time at all under reduced motion.
  Duration _reduced(Tokens tokens, Duration looped) => tokens.reducedMotion ? Duration.zero : looped;

  /// Plays the exit and then stops building the child and calls [GlacierMotion.onGone]; at once where the kind
  /// has no exit. A child shown again before the exit ends is left alone.
  void _leave() {
    _wait?.cancel();
    final spec = _spec(widget.kind);
    if (spec.exit == null) {
      setState(() => _gone = true);
      widget.onGone?.call();
      return;
    }
    final tokens = GlacierTheme.of(context);
    _leaving = true;
    _controller.duration = transition(tokens, widget.speed ?? spec.speed, widget.ease ?? spec.ease).duration;
    _controller.forward(from: 0).whenComplete(() {
      if (!mounted || widget.present) return;
      setState(() => _gone = true);
      widget.onGone?.call();
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    final tokens = GlacierTheme.of(context);
    final spec = _spec(widget.kind);
    final curve = transition(tokens, widget.speed ?? spec.speed, widget.ease ?? spec.ease).curve;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = _controller.value;
        _Pose pose;
        switch (widget.kind) {
          case Motion.shake:
            // x: [0, -6, 6, -4, 4, 0], evenly, each leg eased in and out.
            const keys = [0.0, -6.0, 6.0, -4.0, 4.0, 0.0];
            final at = (t * (keys.length - 1)).clamp(0.0, keys.length - 1.0);
            final i = at.floor().clamp(0, keys.length - 2);
            final local = Curves.easeInOut.transform(at - i);
            pose = _Pose(dx: keys[i] + (keys[i + 1] - keys[i]) * local);
          case Motion.pulse:
            pose = _Pose(scale: 1 + 0.04 * _there(t));
          case Motion.bounce:
            // 0.6s up and back, then 0.4s of rest, as `repeatDelay` had it.
            final moving = (t / 0.6).clamp(0.0, 1.0);
            pose = _Pose(dy: -6 * (moving < 0.5 ? Curves.easeOut.transform(moving * 2) : 1 - Curves.easeOut.transform((moving - 0.5) * 2)));
          case Motion.shimmer:
            pose = _Pose(opacity: 0.45 + 0.55 * _there(t));
          default:
            final eased = curve.transform(t);
            pose = _leaving ? _Pose.lerp(spec.rest, spec.exit!, eased) : _Pose.lerp(spec.initial, spec.rest, eased);
        }
        // The same wrappers at every moment, so the child keeps its state from its first frame to its last.
        Widget out = child!;
        if (spec.initial.height != 1 || spec.rest.height != 1 || (spec.exit?.height ?? 1) != 1) {
          out = ClipRect(child: Align(alignment: Alignment.topCenter, heightFactor: pose.height.clamp(0.0, 1.0), child: out));
        }
        out = Transform.translate(offset: Offset(pose.dx, pose.dy), child: out);
        out = Transform.scale(scale: pose.scale, alignment: widget.alignment, child: out);
        out = Opacity(opacity: pose.opacity.clamp(0.0, 1.0), child: out);
        return out;
      },
    );
  }

  /// There and back over one turn, eased both ways.
  static double _there(double t) => t < 0.5 ? Curves.easeInOut.transform(t * 2) : 1 - Curves.easeInOut.transform((t - 0.5) * 2);
}
