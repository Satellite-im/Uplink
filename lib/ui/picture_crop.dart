/// Choosing which part of a picture is your profile picture (Matt, 2026-11-25: "show a profile picture cropping
/// feature"): the picture under a round window, dragged and made larger or smaller until the window holds what is
/// wanted. What it gives back is that square as shares of the picture, which lib/me/picture_make.dart cuts out.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import 'common.dart';

/// The square of a picture a window shows: the window is [side] across over a picture drawn [drawn] large and moved
/// and scaled by [transform]. As shares of the picture, each 0 to 1, kept inside it. A window that is not square (a
/// banner's, GMFB-34) is [side] across and [height] high.
Rect cropShares(Matrix4 transform, double side, Size drawn, {double? height}) {
  final inverse = Matrix4.inverted(transform);
  final a = MatrixUtils.transformPoint(inverse, Offset.zero), b = MatrixUtils.transformPoint(inverse, Offset(side, height ?? side));
  final w = ((b.dx - a.dx) / drawn.width).clamp(0.0, 1.0), h = ((b.dy - a.dy) / drawn.height).clamp(0.0, 1.0);
  return Rect.fromLTWH((a.dx / drawn.width).clamp(0.0, 1.0 - w), (a.dy / drawn.height).clamp(0.0, 1.0 - h), w, h);
}

/// Asks which square of [bytes] to keep; null where the person thought better of it or it can't be read. With
/// [shape] (the window's width over its height) other than 1 the window is a band of that shape, with square corners:
/// a profile's banner (GMFB-34).
Future<Rect?> showPictureCrop(BuildContext context, Uint8List bytes, {double shape = 1}) async {
  Size? size;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    size = Size(desc.width.toDouble(), desc.height.toDouble());
    desc.dispose();
    buffer.dispose();
  } catch (_) {
    return null;
  }
  if (!context.mounted || size.isEmpty) return null;
  return Navigator.of(context, rootNavigator: true).push<Rect>(PageRouteBuilder<Rect>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 160),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) => PictureCrop(image: MemoryImage(bytes), size: size!, shape: shape),
    transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

/// The card [showPictureCrop] shows: [image], which is [size] in its own pixels, under the window. Pops with the square
/// chosen.
class PictureCrop extends StatefulWidget {
  const PictureCrop({super.key, required this.image, required this.size, this.shape = 1});
  final ImageProvider image;
  final Size size;

  /// The window's width over its height: 1 for a profile picture's round one, 3 for a banner's band.
  final double shape;

  @override
  State<PictureCrop> createState() => _PictureCropState();
}

class _PictureCropState extends State<PictureCrop> {
  final _move = TransformationController();
  double? _side;

  static const _most = 6.0;

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  /// The window's height, [side] across.
  double _high(double side) => side / widget.shape;

  /// The picture as drawn before any zoom: just covering the window (its short side the window's, for a square one).
  Size _drawn(double side) {
    final s = math.max(side / widget.size.width, _high(side) / widget.size.height);
    return Size(widget.size.width * s, widget.size.height * s);
  }

  /// The middle of the picture in the window, as it opens.
  void _centre(double side) {
    if (_side == side) return;
    _side = side;
    final d = _drawn(side);
    _move.value = Matrix4.translationValues(-(d.width - side) / 2, -(d.height - _high(side)) / 2, 0);
  }

  /// Larger or smaller about the window's middle, kept over the picture.
  void _zoom(double by) {
    final side = _side;
    if (side == null) return;
    final d = _drawn(side);
    final now = _move.value.getMaxScaleOnAxis();
    final next = (now * by).clamp(1.0, _most);
    final high = _high(side);
    final middle = _move.toScene(Offset(side / 2, high / 2));
    final left = (side / 2 - middle.dx * next).clamp(side - d.width * next, 0.0), top = (high / 2 - middle.dy * next).clamp(high - d.height * next, 0.0);
    _move.value = Matrix4.translationValues(left, top, 0)..scaleByDouble(next, next, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final screen = MediaQuery.sizeOf(context);
    final side = math.max(160.0, math.min(340.0, math.min(screen.width - t.space(4) * 4, screen.height - 300))).floorToDouble();
    _centre(side);
    final drawn = _drawn(side);
    final high = _high(side), round = widget.shape == 1;
    return Center(
      child: Container(
        key: const ValueKey('picture-crop'),
        width: side + t.space(4) * 2,
        padding: EdgeInsets.all(t.space(4)),
        decoration: BoxDecoration(
          color: t.color('app-paper'),
          borderRadius: BorderRadius.circular(t.radius('xl')),
          border: Border.all(color: t.color('app-rule')),
          boxShadow: t.shadowOf('0 16px 48px rgba(0,0,0,0.3)'),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(round ? 'Position your picture' : 'Position your banner', style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
          SizedBox(height: t.space(1)),
          Text('Drag it, and pinch or scroll to make it larger.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          SizedBox(height: t.space(3)),
          ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('lg')),
            child: SizedBox(
              width: side,
              height: high,
              child: Stack(children: [
                InteractiveViewer(
                  key: const ValueKey('picture-crop-view'),
                  transformationController: _move,
                  constrained: false,
                  minScale: 1,
                  maxScale: _most,
                  child: SizedBox(width: drawn.width, height: drawn.height, child: Image(image: widget.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true)),
                ),
                // What is outside the round picture, dimmed; never in the way of a touch.
                if (round) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _Window(t.color('app-paper').withValues(alpha: 0.62), t.color('app-ink').withValues(alpha: 0.5))))),
              ]),
            ),
          ),
          SizedBox(height: t.space(3)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconTap(key: const ValueKey('picture-crop-smaller'), icon: Lucide.zoomOut, label: 'Smaller', size: 18, box: t.lenOf('2.25rem'), onPressed: () => _zoom(1 / 1.25)),
            IconTap(key: const ValueKey('picture-crop-larger'), icon: Lucide.zoomIn, label: 'Larger', size: 18, box: t.lenOf('2.25rem'), onPressed: () => _zoom(1.25)),
          ]),
          SizedBox(height: t.space(2)),
          Row(children: [
            Expanded(child: _Button(key: const ValueKey('picture-crop-cancel'), label: 'Cancel', onPressed: () => Navigator.of(context).pop())),
            SizedBox(width: t.space(2)),
            Expanded(child: _Button(key: const ValueKey('picture-crop-use'), label: 'Use picture', filled: true, onPressed: () => Navigator.of(context).pop(cropShares(_move.value, side, drawn, height: high)))),
          ]),
        ]),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({super.key, required this.label, required this.onPressed, this.filled = false});
  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        child: Container(
          height: t.lenOf('2.25rem'),
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? t.color('app-ink').withValues(alpha: state.hovered || state.pressed ? 0.88 : 1) : (state.hovered || state.pressed ? t.color('app-paper-2') : null),
            borderRadius: BorderRadius.circular(t.radius('lg')),
            border: filled ? null : Border.all(color: t.color('app-rule')),
          ),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color(filled ? 'app-paper' : 'app-ink'))),
        ),
      ),
    );
  }
}

/// The window: everything outside the round picture dimmed, and a line round it.
class _Window extends CustomPainter {
  _Window(this.dim, this.line);
  final Color dim, line;

  @override
  void paint(Canvas canvas, Size size) {
    final all = Offset.zero & size;
    final round = Path()..addOval(all.deflate(1));
    canvas.drawPath(Path.combine(PathOperation.difference, Path()..addRect(all), round), Paint()..color = dim);
    canvas.drawPath(
        round,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = line);
  }

  @override
  bool shouldRepaint(_Window old) => old.dim != dim || old.line != line;
}
