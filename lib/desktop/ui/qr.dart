import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// A QR code of [data]: black on white whatever the theme, with the quiet border a camera wants round it.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 260, this.radius = 14, this.label = 'The pairing code, as a QR code'});
  final String label;
  final String data;
  final double size;

  /// Its corners' rounding: none in Dial-Up's square chrome.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return Semantics(
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(size: Size.square(size), painter: _QrPainter(image)),
      ),
    );
  }
}

/// Draws the code's dark squares on white, with the clear border round them.
class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;

  /// The clear border, in modules: the standard asks for four.
  static const quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final n = image.moduleCount;
    final cell = size.width / (n + quiet * 2);
    final dark = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    for (var row = 0; row < n; row++) {
      for (var col = 0; col < n; col++) {
        if (!image.isDark(row, col)) continue;
        // A hair wider than a cell, so no line of white shows between two dark ones.
        canvas.drawRect(Rect.fromLTWH((col + quiet) * cell, (row + quiet) * cell, cell + 0.3, cell + 0.3), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
