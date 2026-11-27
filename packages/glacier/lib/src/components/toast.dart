import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../motion/motion.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'css_effects.dart';
import 'pressable.dart';

/// `tone` of a [GlacierToast]: the semantic colour family. Danger announces as an alert, every other as a status.
enum GlacierToastTone { neutral, info, success, warning, danger }

/// Per-tone auto-dismiss defaults (`TONE_DURATION` in Toast.tsx).
const _toneDuration = {
  GlacierToastTone.neutral: Duration(milliseconds: 4500),
  GlacierToastTone.info: Duration(milliseconds: 4500),
  GlacierToastTone.success: Duration(milliseconds: 3500),
  GlacierToastTone.warning: Duration(milliseconds: 4500),
  GlacierToastTone.danger: Duration(milliseconds: 7000),
};

/// How far below its place a toast starts and ends: `y: 12` in the provider's motion.
const double _rise = 12;

/// The one verb a toast may offer (`ToastProps.action`): "Undo" is the whole reason this exists. A toast is not a
/// form, so one action is the ceiling and anything needing two belongs in a dialog.
class GlacierToastAction {
  const GlacierToastAction({required this.label, required this.onPress});
  final String label;
  final VoidCallback onPress;
}

/// What `useToast()` returns: [GlacierToast.of].
class GlacierToastController {
  GlacierToastController._(this._state);
  final _GlacierToastProviderState _state;

  /// Show a toast, replacing any current one (latest wins, no queue). [duration] is the auto-dismiss delay; it
  /// defaults by tone, and [Duration.zero] disables auto-dismiss.
  void toast({
    GlacierToastTone tone = GlacierToastTone.neutral,
    required Widget message,
    Widget? icon,
    GlacierToastAction? action,
    Duration? duration,
    bool dismissible = true,
    bool glass = false,
  }) =>
      _state._show(_Entry(tone: tone, message: message, icon: icon, action: action, duration: duration, dismissible: dismissible, glass: glass));

  /// Dismiss the current toast, if any.
  void dismiss() => _state._dismiss();
}

/// Port of `@glacier/react`'s `Toast` (`molecules/Toast/Toast.tsx`, with the pill rules of `Toast.module.css`): the
/// visual toast pill. Rendered on its own it is a static notification, as wide as its row up to 28rem;
/// [GlacierToastProvider] shrinks it to its content, wraps it in motion and floats it over the app. A press anywhere
/// on the pill calls [onDismiss]; the [action] runs its handler and then dismisses too.
///
/// [GlacierToast.of] is the port of `useToast()`.
///
/// What differs from the React original:
/// - `skeleton` is not ported.
/// - The dismiss button's name is [dismissLabel], English by default; the kit's locale provider is not ported.
/// - On the web the pill carries the `status` role, or `alert` for danger, as the original does. Elsewhere those
///   roles announce nothing, so it is a live region instead, which is what `aria-live` asks for (Flutter allows one
///   or the other on a node, not both).
/// - The pill itself is pressable but is not offered to a screen reader as a button, as a `div` with a click
///   handler is not; its two controls are.
class GlacierToast extends StatelessWidget {
  const GlacierToast({
    super.key,
    this.tone = GlacierToastTone.neutral,
    required this.message,
    this.icon,
    this.action,
    this.dismissible = true,
    this.onDismiss,
    this.glass = false,
    this.dismissLabel = 'Dismiss',
  });

  final GlacierToastTone tone;

  /// The notification content.
  final Widget message;

  /// Optional leading glyph.
  final Widget? icon;

  /// One verb, offered while the pill stands. Pressing it runs the handler and dismisses.
  final GlacierToastAction? action;

  /// Whether a trailing close control is shown.
  final bool dismissible;

  /// Called when the pill or its dismiss control is pressed.
  final VoidCallback? onDismiss;

  /// Renders the frosted glass material instead of a solid surface.
  final bool glass;

  /// The dismiss control's accessible name (`kitMessages.dismiss`).
  final String dismissLabel;

  /// The imperative toast controls of the nearest [GlacierToastProvider] (`useToast()`):
  /// `GlacierToast.of(context).toast(message: ...)` replaces the current toast, `.dismiss()` clears it.
  static GlacierToastController of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ToastScope>();
    if (scope == null) throw FlutterError('GlacierToast.of must be used within a GlacierToastProvider');
    return scope.controller;
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final alert = tone == GlacierToastTone.danger;
    // `.glass` comes last in the stylesheet and outranks the tone.
    final (fillToken, borderToken, textToken) = glass
        ? ('glacier-glass-regular', 'glacier-glass-border', 'glacier-text')
        : switch (tone) {
            GlacierToastTone.neutral => ('glacier-surface-raised', 'glacier-border-subtle', 'glacier-text'),
            _ => ('glacier-${tone.name}-soft', 'glacier-${tone.name}-border', 'glacier-${tone.name}-text'),
          };
    final text = t.color(textToken);
    final hairline = t.len('glacier-hairline');
    final full = t.radius('full');
    final gap = t.space(3);
    final style = t.text('sm', weight: 'medium', color: text).copyWith(height: t.len('glacier-leading-md'));
    final shadows = cssShadowsOf(
      t,
      glass ? 'inset 0 var(--glacier-hairline) 0 var(--glacier-glass-highlight), var(--glacier-shadow-4)' : 'var(--glacier-shadow-4)',
    );

    final items = <Widget>[
      ?icon,
      // `min-width: 0; overflow-wrap: anywhere`: the message is what gives when the pill runs out of room.
      Flexible(child: message),
      if (action != null) Padding(padding: EdgeInsetsDirectional.only(start: t.space(1)), child: _action(t, style)),
      if (dismissible) Padding(padding: EdgeInsetsDirectional.only(start: t.space(2)), child: _dismiss(t, text)),
    ];

    Widget pill = DecoratedBox(
      decoration: BoxDecoration(
        color: t.color(fillToken),
        border: Border.all(color: t.color(borderToken), width: hairline),
        borderRadius: BorderRadius.circular(full),
      ),
      child: Padding(
        padding: EdgeInsets.all(hairline),
        child: GlacierInsetShadows(
          shadows: shadows,
          radius: full,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: t.space(2), horizontal: t.space(4)),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  items[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
    // The shadow is drawn round the pill and never under it: under a glass pill it would show through.
    pill = GlacierOuterShadows(shadows: shadows, radius: full, child: pill);
    pill = GlacierBackdrop(radius: full, enabled: glass, child: pill);
    pill = MouseRegion(
      cursor: SystemMouseCursors.click,
      // A `div` with a click handler: pressable, and nothing a screen reader is told about.
      child: GestureDetector(behavior: HitTestBehavior.opaque, excludeFromSemantics: true, onTap: onDismiss, child: pill),
    );

    return Semantics(
      container: true,
      role: kIsWeb ? (alert ? SemanticsRole.alert : SemanticsRole.status) : null,
      liveRegion: kIsWeb ? null : true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: t.lenOf('28rem')),
        child: DefaultTextStyle(
          style: style,
          textAlign: TextAlign.start,
          child: IconTheme.merge(data: IconThemeData(color: text), child: pill),
        ),
      ),
    );
  }

  /// `.action`: reads as a link inside the pill rather than a second button-shaped thing. Weight and the accent
  /// colour carry it, and the hit area pads out invisibly to stay pressable.
  Widget _action(Tokens t, TextStyle inherited) {
    final accent = t.color('glacier-accent-text');
    final radius = t.radius('sm');
    final hover = t.colorOf('color-mix(in oklab, currentColor 12%, transparent)', current: accent);
    return MergeSemantics(
      child: GlacierPressable(
        // The pill's own press dismisses; the action must not double as it, so it dismisses itself.
        onPressed: () {
          action!.onPress();
          onDismiss?.call();
        },
        builder: (context, state) => GlacierFocusRing(
          visible: state.focused,
          radius: radius,
          offset: -1,
          child: DecoratedBox(
            decoration: BoxDecoration(color: state.hovered ? hover : null, borderRadius: BorderRadius.circular(radius)),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(1), horizontal: t.space(2)),
              child: Text(
                action!.label,
                softWrap: false,
                style: inherited.copyWith(color: accent, fontWeight: FontWeight.w600, fontVariations: const [FontVariation('wght', 650)]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.dismiss`: a round 1.25rem hit target round the close glyph, in the pill's own colour.
  Widget _dismiss(Tokens t, Color color) {
    final side = t.lenOf('1.25rem');
    return MergeSemantics(
      child: GlacierPressable(
        onPressed: () => onDismiss?.call(),
        semanticLabel: dismissLabel,
        builder: (context, state) => CustomPaint(
          // `outline: var(--glacier-hairline) solid currentColor; outline-offset: 2px`: the kit's focus ring is
          // drawn in the focus colour, and this one is the pill's.
          foregroundPainter: state.focused ? _RingPainter(color, t.len('glacier-hairline'), 2) : null,
          child: Opacity(
            opacity: state.hovered || state.focused ? 1 : 0.6,
            child: SizedBox(
              width: side,
              height: side,
              child: Center(child: CustomPaint(size: const Size.square(12), painter: _CrossPainter(color))),
            ),
          ),
        ),
      ),
    );
  }
}

/// The close glyph: `M3 3l8 8M11 3l-8 8` on a 14 x 14 box drawn 12 across, a 1.75 stroke with round ends.
class _CrossPainter extends CustomPainter {
  _CrossPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 14);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(3, 3), const Offset(11, 11), stroke);
    canvas.drawLine(const Offset(11, 3), const Offset(3, 11), stroke);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.color != color;
}

/// A round outline outside the box, in a colour of the caller's.
class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.width, this.offset);
  final Color color;
  final double width, offset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).inflate(offset + width / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.width != width || old.offset != offset;
}

/// One toast the provider is showing, or showing out.
class _Entry {
  _Entry({required this.tone, required this.message, this.icon, this.action, this.duration, required this.dismissible, required this.glass});
  final GlacierToastTone tone;
  final Widget message;
  final Widget? icon;
  final GlacierToastAction? action;
  final Duration? duration;
  final bool dismissible;
  final bool glass;

  /// Bumped on every call, so a replacement is a new pill rather than the old one changed.
  int id = 0;

  /// False once it is dismissed or replaced, while it plays its exit.
  bool present = true;
}

/// Port of `@glacier/react`'s `ToastProvider` (`molecules/Toast/Toast.tsx`, with the `.viewport` and `.item` rules of
/// `Toast.module.css`). Holds the single current toast, floats it at the bottom centre of the window (a space-6 up,
/// a space-4 in from either side, 28rem at most), and runs the auto-dismiss timer. A new toast replaces the current
/// one immediately: this is a deliberate latest-wins, no-queue design, and the outgoing pill fades out in place
/// under the incoming one.
///
/// A toast enters from 12 below at no opacity and leaves the same way, on the `Spring.snappy` spring, keeping its
/// velocity if it is dismissed mid-entrance; under reduced motion it appears and goes at once.
///
/// What differs from the React original:
/// - There is no `document.body` to portal to. Where there is an [Overlay] above the provider, the toast is drawn
///   in the root one, over the whole of it; where there is none (the provider wraps the app itself) it is stacked
///   over [child]. Put the provider above the app's navigator for a toast that floats over every route and dialog,
///   as the original's does.
/// - `toast()` takes its options as named arguments, and `duration` is a [Duration] rather than milliseconds.
/// - A pill that is on its way out no longer takes presses. In the original a press on it in those few frames
///   dismisses whichever toast has replaced it.
/// - `toast()` and `dismiss()` called while the tree is building (from a child's `initState`, say) take effect when
///   the frame is done, where React would have them called from an effect.
class GlacierToastProvider extends StatefulWidget {
  const GlacierToastProvider({super.key, required this.child});
  final Widget child;

  /// Told of every toast as it is shown, by its tone: the app's one place to hear them all, for a sound under a
  /// failure (an addition, the app's Settings › Sounds). Null hears nothing.
  static void Function(GlacierToastTone tone)? onShown;

  @override
  State<GlacierToastProvider> createState() => _GlacierToastProviderState();
}

class _GlacierToastProviderState extends State<GlacierToastProvider> {
  late final GlacierToastController _controller = GlacierToastController._(this);
  final OverlayPortalController _portal = OverlayPortalController();

  /// The current toast, last, and before it any that are still playing their exit.
  final List<_Entry> _entries = [];
  int _nextId = 0;

  /// The auto-dismiss of the current toast.
  Timer? _timer;

  _Entry? get _current => _entries.isNotEmpty && _entries.last.present ? _entries.last : null;

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// True while the tree is being built or laid out, when this state cannot be changed: a toast asked for from a
  /// child's `initState` or `didUpdateWidget` waits for the frame to finish, as one asked for from an effect does.
  bool get _building => SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks;

  /// `toast()`: [entry] becomes the current toast, and whatever was showing starts its exit.
  void _show(_Entry entry) {
    if (!mounted) return;
    if (_building) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _show(entry));
      return;
    }
    _nextId += 1;
    entry.id = _nextId;
    GlacierToastProvider.onShown?.call(entry.tone);
    setState(() {
      for (final old in _entries) {
        old.present = false;
      }
      _entries.add(entry);
    });
    _arm();
  }

  /// `dismiss()`: the current toast starts its exit, and its timer is dropped.
  void _dismiss() {
    if (!mounted) return;
    if (_building) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _dismiss());
      return;
    }
    _timer?.cancel();
    _timer = null;
    final current = _current;
    if (current == null) return;
    setState(() => current.present = false);
  }

  /// Auto-dismiss the current toast; re-armed whenever it is replaced.
  void _arm() {
    _timer?.cancel();
    _timer = null;
    final current = _current;
    if (current == null) return;
    final after = current.duration ?? _toneDuration[current.tone]!;
    if (after <= Duration.zero) return;
    // Only clear it if this toast is still the one on screen.
    _timer = Timer(after, () {
      if (_current == current) _dismiss();
    });
  }

  /// A toast's exit has finished: it is taken out of the tree.
  void _gone(_Entry entry) {
    if (!mounted) return;
    setState(() => _entries.remove(entry));
  }

  /// `.viewport` and its `.item`s: every pill at the same spot, so an outgoing one and its replacement cross in
  /// place.
  Widget _viewport(BuildContext context) {
    final t = GlacierTheme.of(context);
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Stack(
        alignment: Alignment.topLeft,
        children: [
          for (final entry in _entries)
            Positioned(
              key: ValueKey(entry.id),
              left: t.space(4),
              right: t.space(4),
              // Over the keyboard, as the page's fixed viewport is in a window the keyboard shortens: here nothing
              // shortens the window, so the pill is lifted by what the keyboard covers.
              bottom: t.space(6) + (MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0),
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: 1,
                child: _ToastItem(
                  present: entry.present,
                  onGone: () => _gone(entry),
                  // `width: fit-content`: as wide as the pill asks, within the room there is.
                  child: IntrinsicWidth(
                    child: GlacierToast(
                      tone: entry.tone,
                      message: entry.message,
                      icon: entry.icon,
                      action: entry.action,
                      dismissible: entry.dismissible,
                      glass: entry.glass,
                      onDismiss: _dismiss,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = _ToastScope(controller: _controller, child: widget.child);
    if (Overlay.maybeOf(context, rootOverlay: true) != null) {
      return OverlayPortal(
        controller: _portal,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: _viewport,
        child: scope,
      );
    }
    return Stack(
      fit: StackFit.passthrough,
      alignment: Alignment.topLeft,
      children: [
        scope,
        if (_entries.isNotEmpty) Positioned.fill(child: _viewport(context)),
      ],
    );
  }
}

/// Carries the provider's controller down to whoever asks to show a toast.
class _ToastScope extends InheritedWidget {
  const _ToastScope({required this.controller, required super.child});
  final GlacierToastController controller;

  @override
  bool updateShouldNotify(_ToastScope old) => old.controller != controller;
}

/// The provider's `motion.div` inside `AnimatePresence`: enters on mount, and when [present] turns false plays its
/// exit and reports [onGone].
class _ToastItem extends StatefulWidget {
  const _ToastItem({required this.present, required this.onGone, required this.child});
  final bool present;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_ToastItem> createState() => _ToastItemState();
}

class _ToastItemState extends State<_ToastItem> with SingleTickerProviderStateMixin {
  /// 0 is hidden and 12 below, 1 is shown in place.
  late final AnimationController _shown = AnimationController.unbounded(vsync: this, value: 0);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _go(widget.present ? 1 : 0);
  }

  @override
  void didUpdateWidget(_ToastItem old) {
    super.didUpdateWidget(old);
    if (old.present != widget.present) _go(widget.present ? 1 : 0);
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  /// Springs to shown (1) or hidden (0) from wherever it is, at the speed it has; at once under reduced motion.
  void _go(double to) {
    if (GlacierTheme.of(context).reducedMotion) {
      _shown.value = to;
      // This runs while the provider is building, so the provider hears of it after the frame.
      if (to == 0) WidgetsBinding.instance.addPostFrameCallback((_) => _finished());
      return;
    }
    // framer-motion's rest thresholds for a value as small as an opacity: within 0.005 and under 0.01 a second.
    _shown
        .animateWith(SpringSimulation(
          springDescription(Spring.snappy),
          _shown.value,
          to,
          _shown.velocity,
          snapToEnd: true,
          tolerance: const Tolerance(distance: 0.005, velocity: 0.01),
        ))
        .whenComplete(_finished);
  }

  /// The spring has come to rest: if that was the exit, the provider is told.
  void _finished() {
    if (mounted && !widget.present) widget.onGone();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = GlacierTheme.of(context).reducedMotion;
    return IgnorePointer(
      ignoring: !widget.present,
      child: AnimatedBuilder(
        animation: _shown,
        child: widget.child,
        builder: (context, child) => Opacity(
          opacity: _shown.value.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, reduce ? 0 : _rise * (1 - _shown.value)), child: child),
        ),
      ),
    );
  }
}
