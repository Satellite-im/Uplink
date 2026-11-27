import 'package:flutter/painting.dart';

final Map<String, (double, double)> _faceMetrics = {};
bool _watchingFonts = false;

/// `line-height: normal` for [face], in logical pixels, as a browser works it out: the font's ascent and its descent
/// each rounded to a whole pixel, then added. Flutter rounds their sum instead, which for Inter at 11px is a line of
/// 13 where the page's is 14, and at 16px 19 where the page's is 20: a pixel on every heading and row. (An explicit
/// `line-height` the page keeps to the fraction and Flutter rounds to a pixel; that half pixel is the engine's.)
///
/// The pixel is the DEVICE's: Chromium lays a page out at the device's scale, so at [dpr] 2.625 a 16.26px title's
/// ascent and descent are rounded as 41.3 and 10.3 device pixels and its line is 51 of them, 19.43 logical, where
/// rounding the logical 15.75 and 3.92 gave 20. On a desktop's ratio of 1, where the tests' rectangles were
/// measured, the two are the same.
double normalLineHeight(TextStyle face, {double dpr = 1}) => normalLineBox(face, dpr: dpr).height;

/// The line of `line-height: normal` for [face] and where its baseline is in it, both in logical pixels.
///
/// Chromium on Android and Linux does one thing more than round the two: where the descent was rounded DOWN it gives
/// the descent a device pixel and takes it from the ascent, so the line is as tall and its words stand a device
/// pixel higher. Measured on the page for Inter from 10px to 34px at 2.625, 66 sizes: every height and every baseline
/// is this rule's (a 16.26px title: 41.3 and 10.3 round to 41 and 10, and the page has 40 and 11).
({double height, double baseline}) normalLineBox(TextStyle face, {double dpr = 1}) {
  final size = face.fontSize!;
  final key = '${face.fontFamily}|${face.fontFamilyFallback?.join(',')}|${face.fontWeight?.value}';
  final (ascent, descent) = _faceMetrics.putIfAbsent(key, () {
    if (!_watchingFonts) {
      // A font that arrives later is a different answer.
      _watchingFonts = true;
      PaintingBinding.instance.systemFonts.addListener(_faceMetrics.clear);
    }
    const probe = 1000.0;
    final painter = TextPainter(
      text: TextSpan(text: 'x', style: face.copyWith(fontSize: probe, height: kTextHeightNone, letterSpacing: 0)),
      textDirection: TextDirection.ltr,
    )..layout();
    final line = painter.computeLineMetrics().first;
    painter.dispose();
    return (line.ascent / probe, line.descent / probe);
  });
  final ratio = dpr > 0 ? dpr : 1.0;
  var up = (ascent * size * ratio).roundToDouble();
  var down = (descent * size * ratio).roundToDouble();
  // The page's ratio of 1 is a desktop's, where the tests' rectangles were measured and no pixel is moved.
  if (ratio != 1 && down < descent * size * ratio - 1e-4) {
    down += 1;
    up -= 1;
  }
  return (height: (up + down) / ratio, baseline: up / ratio);
}

/// Where the first baseline of a line [lineHeight] tall is under its top, in logical pixels, as a phone's page has
/// it: the face's content area ([normalLineBox]: its ascent and descent in whole device pixels) set in the line with
/// half the leading FLOORED to a device pixel (Blink's `FontHeight::AddLeading`), so the words of a line tighter
/// than its face start a whole number of device pixels over its top.
///
/// Read from the page in the Tauri app at 2.625, 2026-10-09: Settings' title, Inter bold at 28.29px on a line of
/// 32.54 (85.39 device pixels), has a content area of 90 that starts 3.00 over the line's top, `floor(-2.3)`; the
/// editor's own lines are held to the same rule for five sizes (test/editor/view/device_lines_test.dart).
double leadedBaseline(TextStyle face, double lineHeight, {double dpr = 1}) {
  final ratio = dpr > 0 ? dpr : 1.0;
  final box = normalLineBox(face, dpr: ratio);
  final up = box.baseline * ratio, area = box.height * ratio;
  // A length is a sixty-fourth of a device pixel on the page.
  final line = (lineHeight * ratio * 64).roundToDouble() / 64;
  return (up + ((line - area) / 2).floorToDouble()) / ratio;
}
