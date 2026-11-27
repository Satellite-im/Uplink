import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/common.dart';

/// The New messages wave is measured from the tag (Matt, 2026-11-19: "the squiggle always ends in the middle of the
/// "new" tag i suggest starting the squiggle from that end so it's always lined up"): whatever its width, it meets
/// its right end on the middle line, and nowhere else at that end.
void main() {
  const red = Color(0xFFDD3A30);
  const height = 16;

  Future<ByteData> drawn(double width) async {
    final recorder = ui.PictureRecorder();
    const GhostHem(color: red, stroke: 2, tail: 8).paint(Canvas(recorder), Size(width, height.toDouble()));
    final image = await recorder.endRecording().toImage(width.ceil() + 8, height);
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  int alpha(ByteData d, int w, int x, int y) => d.getUint8((y * w + x) * 4 + 3);

  test('the wave meets its right end on the middle line at any width', () async {
    for (final width in [57.0, 100.0, 133.0, 250.5, 301.0, 412.0]) {
      final w = width.ceil() + 8;
      final d = await drawn(width);
      // The last whole column of the wave, and one in the level run past it, under the tag.
      for (final x in [width.floor() - 1, width.floor() + 4]) {
        expect(alpha(d, w, x, height ~/ 2 - 1) + alpha(d, w, x, height ~/ 2), greaterThan(300), reason: 'width $width, column $x: ink on the middle line');
        expect(alpha(d, w, x, 1), 0, reason: 'width $width, column $x: none at the top');
        expect(alpha(d, w, x, height - 2), 0, reason: 'width $width, column $x: none at the foot');
      }
      // A quarter wave back from the end it is at its crest, at every width: the wave's place is the tag's.
      final crest = (width - GhostHem.halfWave(height.toDouble(), 2) / 2).round();
      expect(alpha(d, w, crest, 1) + alpha(d, w, crest, 2), greaterThan(200), reason: 'width $width: a crest half a half-wave from the end');
    }
  });
}
