import 'dart:math' as math;
import 'dart:ui' show Color;

/// A colour as the token sheets write it: OKLCH with an alpha. Kept in this space until the last moment so that
/// `color-mix(in oklch, ...)` mixes where CSS mixes, and only then turned into the sRGB a screen draws.
class Oklch {
  const Oklch(this.l, this.c, this.h, [this.alpha = 1]);

  /// Lightness, 0 to 1.
  final double l;

  /// Chroma, 0 to about 0.4.
  final double c;

  /// Hue in degrees; meaningless where [c] is 0.
  final double h;
  final double alpha;

  static const Oklch transparent = Oklch(0, 0, 0, 0);

  /// A grey: no chroma to speak of, so its hue says nothing ([mix] takes the other colour's).
  bool get achromatic => c < 1e-5;

  Oklch withAlpha(double a) => Oklch(l, c, h, a);

  /// From sRGB channels, each 0 to 1.
  factory Oklch.fromSrgb(double r, double g, double b, [double alpha = 1]) {
    final lr = _toLinear(r), lg = _toLinear(g), lb = _toLinear(b);
    final l_ = _cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
    final m_ = _cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
    final s_ = _cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
    final ll = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    final a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    final bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    final c = math.sqrt(a * a + bb * bb);
    var h = math.atan2(bb, a) * 180 / math.pi;
    if (h < 0) h += 360;
    return Oklch(ll, c < 1e-7 ? 0 : c, h, alpha);
  }

  factory Oklch.fromColor(Color color) => Oklch.fromSrgb(color.r, color.g, color.b, color.a);

  /// Linear sRGB, not yet clamped: a channel outside 0 to 1 is a colour the screen cannot show.
  List<double> _linear(double chroma) {
    final hr = h * math.pi / 180;
    final a = chroma * math.cos(hr), b = chroma * math.sin(hr);
    final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
    final l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_;
    return [
      4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
      -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
      -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
    ];
  }

  /// The sRGB colour a screen draws. A colour outside sRGB is clipped channel by channel, which is what Chromium (the
  /// engine the Android app's page runs in) does with it; test/tokens_test.dart holds this to the page's own pixels.
  Color toColor() {
    final rgb = _linear(c);
    return Color.from(
      alpha: alpha.clamp(0.0, 1.0),
      red: _toGamma(rgb[0]).clamp(0.0, 1.0),
      green: _toGamma(rgb[1]).clamp(0.0, 1.0),
      blue: _toGamma(rgb[2]).clamp(0.0, 1.0),
    );
  }

  /// `color-mix(in oklch, a wa, b wb)`: weights already as fractions that sum to 1. Premultiplied, hue by the shorter
  /// arc, and a colour with no hue of its own (a grey, or `transparent`) takes the other's.
  static Oklch mix(Oklch a, double wa, Oklch b, double wb) {
    final alpha = a.alpha * wa + b.alpha * wb;
    if (alpha <= 0) return transparent;
    final aMissing = a.alpha == 0, bMissing = b.alpha == 0;
    double pre(double x, Oklch o, double w) => x * o.alpha * w;
    final l = aMissing
        ? b.l
        : bMissing
            ? a.l
            : (pre(a.l, a, wa) + pre(b.l, b, wb)) / alpha;
    final c = aMissing
        ? b.c
        : bMissing
            ? a.c
            : (pre(a.c, a, wa) + pre(b.c, b, wb)) / alpha;
    double h;
    final aNoHue = aMissing || a.achromatic, bNoHue = bMissing || b.achromatic;
    if (aNoHue && bNoHue) {
      h = 0;
    } else if (aNoHue) {
      h = b.h;
    } else if (bNoHue) {
      h = a.h;
    } else {
      var d = b.h - a.h;
      if (d > 180) d -= 360;
      if (d < -180) d += 360;
      h = (a.h + d * wb) % 360;
      if (h < 0) h += 360;
    }
    return Oklch(l, c, h, alpha);
  }

  /// The sRGB transfer curve, from a stored channel to linear light and back.
  static double _toLinear(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  static double _toGamma(double v) {
    if (v <= 0) return 0;
    return v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  }

  /// A cube root that keeps the sign: `pow` of a negative number to a third is not a number.
  static double _cbrt(double v) => v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

  @override
  String toString() => 'oklch($l $c $h / $alpha)';
}
