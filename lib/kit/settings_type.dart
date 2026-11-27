import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

/// The page's text as a rule of settings.css sets it: the kit's `Tokens.textAt` at [px], with the line the page's
/// engine gives `line-height: normal` ([normalLineHeight]) unless the rule names one ([height], CSS's unitless
/// multiple). [tracking] is `letter-spacing` in logical pixels.
TextStyle pageText(Tokens t, double px, {String weight = 'regular', Color? color, double? height, double tracking = 0, bool mono = false}) {
  return t.textAt(px, weight: weight, color: color, height: height, tracking: tracking, mono: mono);
}
