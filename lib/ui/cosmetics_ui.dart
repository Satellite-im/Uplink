import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import '../kit/picture_decode.dart';
import '../me/cosmetics.dart';

/// How a profile's cosmetics are drawn (lib/me/cosmetics.dart; GMFB-34). Each piece is its art where the build has it
/// (assets/cosmetics/…), else a stand-in drawn here from its colours, so a profile dressed in a piece whose file is not
/// in yet still looks dressed, never broken. Moving ones stand still under reduced motion.

/// A face dressed: [face] (a picture of [size]) with a border on its edge and a decoration around it. The
/// decoration spills past [size] (Lovart's art keeps a clear circle 360 of 512 across for the face, the border's 440),
/// so what holds this should leave it room ([DressedFace.spill]).
class DressedFace extends StatelessWidget {
  const DressedFace({super.key, required this.face, required this.size, this.cosmetics = Cosmetics.none});
  final Widget face;
  final double size;
  final Cosmetics cosmetics;

  /// How far past the face, on each side, a decoration may reach.
  static double spill(double size) => size * (512 / 360 - 1) / 2;

  @override
  Widget build(BuildContext context) {
    final border = CosmeticCatalog.find(CosmeticKind.border, cosmetics.border);
    final decoration = CosmeticCatalog.find(CosmeticKind.decoration, cosmetics.decoration);
    if (border == null && decoration == null) return face;
    return ListenableBuilder(
      listenable: CosmeticArt.instance,
      builder: (context, _) {
        final art = CosmeticArt.instance;
        final b = border, d = decoration;
        // The art is 512 square: the face's circle is 440 across in a border's, 360 in a decoration's.
        Widget? ring, around;
        if (b != null) {
          final side = size * 512 / 440;
          ring = art.has(b)
              ? Image.asset(b.asset, width: side, height: side, key: ValueKey('border-${b.id}'))
              : CustomPaint(key: ValueKey('border-${b.id}'), size: Size.square(size), painter: _RingStandIn(b));
        }
        if (d != null) {
          final side = size * 512 / 360;
          final file = art.artOf(d, moving: !MediaQuery.disableAnimationsOf(context));
          around = file != null
              ? Image.asset(file, width: side, height: side, gaplessPlayback: true, key: ValueKey('decoration-${d.id}'))
              : _DecorationStandIn(key: ValueKey('decoration-${d.id}'), piece: d, size: size);
        }
        return SizedBox.square(
          dimension: size,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            face,
            if (ring != null) Positioned.fill(child: OverflowBox(maxWidth: double.infinity, maxHeight: double.infinity, child: IgnorePointer(child: ring))),
            if (around != null) Positioned.fill(child: OverflowBox(maxWidth: double.infinity, maxHeight: double.infinity, child: IgnorePointer(child: around))),
          ]),
        );
      },
    );
  }
}

/// A border's stand-in: a ring in its colours on the face's edge.
class _RingStandIn extends CustomPainter {
  _RingStandIn(this.piece);
  final Cosmetic piece;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final w = math.max(2.0, size.width * 0.07);
    final rect = Rect.fromCircle(center: Offset(r, r), radius: r);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..shader = SweepGradient(colors: [piece.accent, piece.second ?? piece.accent.withValues(alpha: 0.55), piece.accent]).createShader(rect);
    canvas.drawCircle(Offset(r, r), r - w / 2, paint);
  }

  @override
  bool shouldRepaint(_RingStandIn old) => old.piece != piece;
}

/// A decoration's stand-in: a soft glow round the face and a few sparks of its colour turning slowly about it.
class _DecorationStandIn extends StatefulWidget {
  const _DecorationStandIn({super.key, required this.piece, required this.size});
  final Cosmetic piece;
  final double size;

  @override
  State<_DecorationStandIn> createState() => _DecorationStandInState();
}

class _DecorationStandInState extends State<_DecorationStandIn> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(seconds: 9));

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
    final side = widget.size * 512 / 360;
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) => CustomPaint(size: Size.square(side), painter: _SparksPainter(widget.piece, widget.size, _turn.value)),
    );
  }
}

/// Paints the decoration's stand-in: the glow, and six sparks at [turn] (0 to 1) of the way round a face [face] wide.
class _SparksPainter extends CustomPainter {
  _SparksPainter(this.piece, this.face, this.turn);
  final Cosmetic piece;
  final double face;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = face / 2;
    canvas.drawCircle(
      c,
      r + face * 0.05,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = face * 0.08
        ..color = piece.accent.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, face * 0.06),
    );
    final dot = Paint()..color = piece.accent;
    const n = 6;
    for (var i = 0; i < n; i++) {
      final a = (i / n + turn) * 2 * math.pi;
      final lift = r + face * (0.13 + 0.04 * math.sin(a * 3));
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * lift, face * (i.isEven ? 0.035 : 0.022), dot);
    }
  }

  @override
  bool shouldRepaint(_SparksPainter old) => old.turn != turn || old.piece != piece || old.face != face;
}

/// A banner: the piece [id]'s art, else its colours as a gradient; with no piece, [fallback] (the card's own band).
class CosmeticBanner extends StatelessWidget {
  const CosmeticBanner({super.key, required this.id, required this.fallback, this.picture = ''});
  final String id;
  final Widget fallback;

  /// The person's own picture as their banner (GMFB-34; base64, lib/me/picture_make.dart's bannerPictureOf): drawn in
  /// place of the piece [id] names where there is one and it can be read; '' for none.
  final String picture;

  @override
  Widget build(BuildContext context) {
    final piece = CosmeticCatalog.find(CosmeticKind.banner, id);
    final made = piece == null
        ? fallback
        : ListenableBuilder(
            listenable: CosmeticArt.instance,
            builder: (context, _) {
              if (CosmeticArt.instance.has(piece)) return Image.asset(piece.asset, fit: BoxFit.cover, key: ValueKey('banner-${piece.id}'));
              return DecoratedBox(
                key: ValueKey('banner-${piece.id}'),
                decoration: BoxDecoration(gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [piece.accent, piece.second ?? piece.accent])),
              );
            },
          );
    final bytes = picture.isEmpty ? null : pictureBytes(picture);
    if (bytes == null) return made;
    // A picture that can't be drawn after all (not a picture): the banner chosen, as a build from before draws.
    return Image.memory(bytes, key: const ValueKey('banner-own'), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true, cacheWidth: fillDecodeWidth(context, 480), errorBuilder: (context, _, _) => made);
  }
}

/// [text] in [style] with the name effect [id]: the art's texture inside the letters, or the app's own gradient,
/// shimmer, glow or turning rainbow. With no effect, the text as it is.
class NameEffectText extends StatefulWidget {
  const NameEffectText(this.text, {super.key, required this.id, required this.style, this.maxLines = 1});
  final String text;
  final String id;
  final TextStyle style;
  final int maxLines;

  @override
  State<NameEffectText> createState() => _NameEffectTextState();
}

class _NameEffectTextState extends State<NameEffectText> with SingleTickerProviderStateMixin {
  late final AnimationController _move = AnimationController(vsync: this, duration: const Duration(seconds: 4));
  ui.Image? _texture;
  String _textureFor = '';

  Cosmetic? get _piece => CosmeticCatalog.find(CosmeticKind.name, widget.id);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate();
  }

  @override
  void didUpdateWidget(NameEffectText old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _animate();
  }

  /// Runs the animation for an effect that moves (shimmer, rainbow, texture) unless reduced motion is asked for, and
  /// loads a texture's art once for each piece.
  void _animate() {
    final p = _piece;
    final moves = p != null && (p.style == NameStyle.shimmer || p.style == NameStyle.rainbow || p.style == NameStyle.texture);
    if (moves && !MediaQuery.disableAnimationsOf(context)) {
      _move.repeat();
    } else {
      _move.stop();
    }
    if (p != null && p.style == NameStyle.texture && _textureFor != p.id) unawaited(_load(p));
  }

  /// The texture's art, where the build has it: decoded once.
  Future<void> _load(Cosmetic p) async {
    _textureFor = p.id;
    try {
      final data = await rootBundle.load(p.asset);
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      if (!mounted || _textureFor != p.id) return;
      setState(() => _texture = frame.image);
    } catch (_) {
      // Not in this build yet: its colours stand in.
    }
  }

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _piece;
    final plain = Text(widget.text, maxLines: widget.maxLines, overflow: TextOverflow.ellipsis, style: widget.style);
    if (p == null) return plain;
    final a = p.accent, b = p.second ?? p.accent;
    if (p.style == NameStyle.glow) {
      return Text(
        widget.text,
        key: ValueKey('name-${p.id}'),
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
        style: widget.style.copyWith(color: a, shadows: [Shadow(color: b, blurRadius: 10), Shadow(color: b.withValues(alpha: 0.6), blurRadius: 22)]),
      );
    }
    return AnimatedBuilder(
      key: ValueKey('name-${p.id}'),
      animation: _move,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) {
          final v = _move.value;
          final tex = _texture;
          if (p.style == NameStyle.texture && tex != null) {
            // The texture slides slowly along the name, scaled to its height.
            final scale = rect.height / tex.height;
            final m = Matrix4.identity()
              ..translateByDouble(-v * tex.width * scale, 0, 0, 1)
              ..scaleByDouble(scale, scale, 1, 1);
            return ImageShader(tex, TileMode.repeated, TileMode.repeated, m.storage);
          }
          return switch (p.style) {
            NameStyle.shimmer => LinearGradient(
                colors: [a, b, a],
                stops: const [0.35, 0.5, 0.65],
                begin: Alignment(-1 - 2 + 4 * v, 0),
                end: Alignment(1 - 2 + 4 * v, 0),
              ).createShader(rect),
            NameStyle.rainbow => LinearGradient(
                colors: [for (var i = 0; i <= 6; i++) HSVColor.fromAHSV(1, ((i / 6) * 360 + v * 360) % 360, 0.65, 1).toColor()],
              ).createShader(rect),
            _ => LinearGradient(colors: [a, b]).createShader(rect),
          };
        },
        child: child,
      ),
      child: Text(widget.text, maxLines: widget.maxLines, overflow: TextOverflow.ellipsis, style: widget.style.copyWith(color: const Color(0xFFFFFFFF))),
    );
  }
}

/// A profile effect over a whole card: the art, else a few motes of its colours drifting in from the card's edges.
/// Never takes a touch.
class ProfileEffectLayer extends StatefulWidget {
  const ProfileEffectLayer({super.key, required this.id});
  final String id;

  @override
  State<ProfileEffectLayer> createState() => _ProfileEffectLayerState();
}

class _ProfileEffectLayerState extends State<ProfileEffectLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 12));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    MediaQuery.disableAnimationsOf(context) ? _drift.stop() : _drift.repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final piece = CosmeticCatalog.find(CosmeticKind.effect, widget.id);
    if (piece == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: CosmeticArt.instance,
        builder: (context, _) {
          final file = CosmeticArt.instance.artOf(piece, moving: !MediaQuery.disableAnimationsOf(context));
          if (file != null) return Image.asset(file, fit: BoxFit.cover, gaplessPlayback: true, key: ValueKey('effect-${piece.id}'));
          return AnimatedBuilder(
            key: ValueKey('effect-${piece.id}'),
            animation: _drift,
            builder: (context, _) => CustomPaint(painter: _MotesPainter(piece, _drift.value), size: Size.infinite),
          );
        },
      ),
    );
  }
}

/// Paints a profile effect's stand-in: 18 motes falling (rising, for embers) at [v] (0 to 1) of one drift. Seeded from
/// the piece's id, so each mote keeps its place and speed from frame to frame.
class _MotesPainter extends CustomPainter {
  _MotesPainter(this.piece, this.v);
  final Cosmetic piece;
  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    final rising = piece.id == 'embers';
    final rnd = math.Random(piece.id.hashCode);
    for (var i = 0; i < 18; i++) {
      // Along the card's two sides, where the words are not.
      final left = i.isEven;
      final x = left ? rnd.nextDouble() * size.width * 0.18 : size.width * (0.82 + rnd.nextDouble() * 0.18);
      final speed = 0.6 + rnd.nextDouble() * 0.8;
      var y = (rnd.nextDouble() + v * speed) % 1.0;
      if (rising) y = 1 - y;
      final colour = (i % 3 == 0 ? (piece.second ?? piece.accent) : piece.accent).withValues(alpha: 0.35 + 0.4 * rnd.nextDouble());
      canvas.drawCircle(Offset(x, y * size.height), 1.5 + rnd.nextDouble() * 2.5, Paint()..color = colour);
    }
  }

  @override
  bool shouldRepaint(_MotesPainter old) => old.v != v || old.piece != piece;
}
