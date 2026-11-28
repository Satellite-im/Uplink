import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Waits until a picture that moves has its first frame on the page: [shown] finds it. Its frames are read in real
/// time and each is put on the page at a frame of the app's, so neither a wait nor a pump alone brings one, and
/// `precacheImage` waited on inside `runAsync` never comes back (no frame of the app's is drawn in there).
Future<void> filmShown(WidgetTester tester, Finder shown) async {
  for (var i = 0; i < 300 && shown.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(shown, findsOneWidget, reason: 'the film\'s first frame was read and shown');
}

/// What was drawn, as a test looks at it: the picture of everything under the nearest boundary above [element]
/// (the whole screen, for anything not under a boundary of its own), with each of its dots' colour to hand. It is in
/// the screen's own dots: [scale] of them to one of the page's.
class Drawn {
  Drawn._(this.width, this.height, this.scale, this._rgba, this._png);
  final int width, height;
  final double scale;
  final ByteData _rgba;
  final Uint8List _png;

  static Future<Drawn> of(WidgetTester tester, Element element) async {
    late Drawn drawn;
    final wide = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      drawn = Drawn._(image.width, image.height, image.width / wide, rgba!, png!.buffer.asUint8List());
      image.dispose();
    });
    return drawn;
  }

  /// Kept as a picture, to be looked at.
  void keep(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_png);
  }

  /// The colour at a place on the page.
  Color at(Offset place) {
    final x = (place.dx * scale).floor().clamp(0, width - 1), y = (place.dy * scale).floor().clamp(0, height - 1);
    final i = (y * width + x) * 4;
    return Color.fromARGB(_rgba.getUint8(i + 3), _rgba.getUint8(i), _rgba.getUint8(i + 1), _rgba.getUint8(i + 2));
  }

  /// How many of the dots in [box] (a place on the page) are anything but [colour], to the last part in 255.
  int not(Rect box, Color colour) {
    final want = [(colour.r * 255).round(), (colour.g * 255).round(), (colour.b * 255).round()];
    var n = 0;
    for (var y = (box.top * scale).ceil(); y < (box.bottom * scale).floor(); y++) {
      for (var x = (box.left * scale).ceil(); x < (box.right * scale).floor(); x++) {
        final i = (y * width + x) * 4;
        if (_rgba.getUint8(i) != want[0] || _rgba.getUint8(i + 1) != want[1] || _rgba.getUint8(i + 2) != want[2]) n++;
      }
    }
    return n;
  }

  /// Of the dots in [box] (a place on the page), the share that are [ink], the share that are [page], and the share
  /// that are neither one nor on the way between them: a colour that has no business there. A dot counts as a colour
  /// within [slack] of it in each of red, green and blue.
  ({double ink, double page, double other}) shares(Rect box, {required Color ink, required Color page, int slack = 10}) {
    List<int> of(Color c) => [(c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round()];
    final i = of(ink), p = of(page);
    var inked = 0, paged = 0, others = 0, all = 0;
    for (var y = (box.top * scale).ceil(); y < (box.bottom * scale).floor(); y++) {
      for (var x = (box.left * scale).ceil(); x < (box.right * scale).floor(); x++) {
        final n = (y * width + x) * 4;
        final c = [_rgba.getUint8(n), _rgba.getUint8(n + 1), _rgba.getUint8(n + 2)];
        bool near(List<int> to) => (c[0] - to[0]).abs() <= slack && (c[1] - to[1]).abs() <= slack && (c[2] - to[2]).abs() <= slack;
        // Between the two: each of red, green and blue no further out than the page and the ink are.
        bool between() {
          for (var k = 0; k < 3; k++) {
            final low = (i[k] < p[k] ? i[k] : p[k]) - slack, high = (i[k] > p[k] ? i[k] : p[k]) + slack;
            if (c[k] < low || c[k] > high) return false;
          }
          return true;
        }

        all++;
        if (near(i)) {
          inked++;
        } else if (near(p)) {
          paged++;
        } else if (!between()) {
          others++;
        }
      }
    }
    return (ink: inked / all, page: paged / all, other: others / all);
  }
}
