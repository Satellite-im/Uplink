import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import 'dialup/dialup.dart';

/// A message's bubble going in a puff (Matt, 2026-11-15: "show a poof animation when one is deleted"): once [gone],
/// it shrinks and fades while a ring of small puffs bursts out of where it was and fades, then its room closes up
/// and [onDone] is called, which takes the message away for good.
class Poof extends StatefulWidget {
  const Poof({super.key, required this.gone, required this.child, this.onDone, this.color = const Color(0xFFE4E7EC), this.side});
  final bool gone;

  /// Where in a row the size of the screen the bubble stands: your own at the right, theirs at the left. The puffs
  /// burst from about its middle there. Null: from the middle of the row.
  final AxisDirection? side;
  final Widget child;
  final VoidCallback? onDone;

  /// The puffs' colour.
  final Color color;

  static const duration = Duration(milliseconds: 420);

  @override
  State<Poof> createState() => _PoofState();
}

class _PoofState extends State<Poof> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: Poof.duration);
  bool _done = false;

  /// Dial-Up has no puff (Matt, 2026-11-16, of the chat-room look; the design: "the delete 'poof' becomes the line
  /// vanishing"): the line goes at once, and [Poof.onDone] is told in the next frame, as it would be at the puff's end.
  bool _vanish = false;

  /// Starts the puff, from its beginning with [restart]; under Dial-Up the line just goes.
  void _go({bool restart = false}) {
    if (isBevelChrome(context.tokens)) {
      if (_vanish) return;
      _vanish = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _done) return;
        _done = true;
        widget.onDone?.call();
      });
      return;
    }
    restart ? _c.forward(from: 0) : _c.forward();
  }

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && !_done) {
        _done = true;
        widget.onDone?.call();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than in initState: the tokens that say Dial-Up are an inherited widget's.
    if (widget.gone && _c.value == 0 && !_vanish) _go();
  }

  @override
  void didUpdateWidget(Poof old) {
    super.didUpdateWidget(old);
    if (widget.gone && !old.gone) _go(restart: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_vanish) return const SizedBox.shrink();
    if (!widget.gone && _c.value == 0) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value;
        // The bubble: smaller and fainter over the first half.
        final fade = Curves.easeIn.transform((v / 0.5).clamp(0.0, 1.0));
        // Its room: closing over the last part, once the puff has gone off.
        final close = Curves.easeInOut.transform(((v - 0.55) / 0.45).clamp(0.0, 1.0));
        // Not clipped: the puffs burst past the bubble's edges.
        return Align(
            alignment: Alignment.center,
            heightFactor: 1 - close,
            child: CustomPaint(
              foregroundPainter: _Puffs(v, widget.color, widget.side),
              // Shrinking toward its own side, so the bubble stays where it stood.
              child: Opacity(
                opacity: 1 - fade,
                child: Transform.scale(
                  scale: 1 - 0.35 * fade,
                  alignment: switch (widget.side) { AxisDirection.right => const Alignment(0.75, 0), AxisDirection.left => const Alignment(-0.75, 0), _ => Alignment.center },
                  child: child,
                ),
              ),
            ),
        );
      },
      child: widget.child,
    );
  }
}

/// A ring of puffs bursting out from the middle and fading.
class _Puffs extends CustomPainter {
  _Puffs(this.v, this.color, this.side);
  final double v;
  final Color color;
  final AxisDirection? side;

  static const _count = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final burst = Curves.easeOut.transform((v / 0.75).clamp(0.0, 1.0));
    if (burst <= 0 || burst >= 1) return;
    // About a bubble's middle on its side of the row (a bubble is some 200 points wide), else the row's middle.
    final half = min(size.width * 0.5, 110.0);
    final centre = switch (side) {
      AxisDirection.right => Offset(size.width - half - 12, size.height / 2),
      AxisDirection.left => Offset(half + 12, size.height / 2),
      _ => size.center(Offset.zero),
    };
    final across = side == null ? size.width : half * 2;
    // Out from where the bubble was, wider than it is tall, as far as a little past its ends.
    final reachX = across * 0.5 + 24, reachY = size.height * 0.5 + 22;
    final paint = Paint()..color = color.withValues(alpha: (1 - burst * burst) * 0.95);
    for (var i = 0; i < _count; i++) {
      final a = i / _count * 2 * pi + (i.isEven ? 0.18 : -0.12);
      final d = burst * (0.55 + 0.45 * ((i * 37) % 10) / 10);
      final r = (6 + (i % 4) * 2.5) * (1 - burst * 0.6);
      canvas.drawCircle(centre + Offset(cos(a) * reachX * d, sin(a) * reachY * d), r, paint);
    }
    // A soft cloud where it stood, fading first.
    final cloud = (1 - burst * 1.6).clamp(0.0, 1.0);
    if (cloud > 0) canvas.drawOval(Rect.fromCenter(center: centre, width: across * 0.5 * burst + 20, height: size.height * 0.6 * burst + 14), Paint()..color = color.withValues(alpha: cloud * 0.35));
  }

  @override
  bool shouldRepaint(_Puffs old) => old.v != v || old.color != color || old.side != side;
}
