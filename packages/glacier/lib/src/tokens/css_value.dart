import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import 'oklch.dart';
import 'split.dart';

export 'split.dart' show splitTop;

/// What a CSS length is measured against: the root font size, the font size of the element asking, and the window.
/// Flutter's logical pixels are CSS pixels, so a `rem` is 16 of them here as it is on the page.
class CssContext {
  const CssContext({this.rem = 16, this.em = 16, this.vw = 390, this.vh = 844, this.dpr = 1, double? lineDpr}) : lineDpr = lineDpr ?? dpr;

  final double rem;
  final double em;

  /// The window's width and height in logical pixels.
  final double vw;
  final double vh;

  /// Device pixels to a logical one, for [border].
  final double dpr;

  /// Device pixels to a logical one where a line of `line-height: normal` is rounded (line_height.dart): the
  /// window's own, [dpr], unless a test's fixture was measured on a page of another ratio.
  final double lineDpr;

  /// A border's width as a browser uses it: a whole number of device pixels, rounded down, and never less than one
  /// (Chromium snaps the computed width, so on a phone at 2.625 a `1px` rule is two device pixels, 0.762px, and a
  /// column of forty rows is that much shorter than forty unsnapped rules would make it).
  double border(double px) {
    if (px <= 0 || dpr <= 0) return px;
    final device = px * dpr;
    return device < 1 ? 1 / dpr : (device + 1e-6).floorToDouble() / dpr;
  }

  /// The same context for an element whose own font size is [em] pixels.
  CssContext withEm(double em) => CssContext(rem: rem, em: em, vw: vw, vh: vh, dpr: dpr, lineDpr: lineDpr);

  @override
  bool operator ==(Object other) => other is CssContext && other.rem == rem && other.em == em && other.vw == vw && other.vh == vh && other.dpr == dpr && other.lineDpr == lineDpr;

  @override
  int get hashCode => Object.hash(rem, em, vw, vh, dpr, lineDpr);
}

/// Thrown by every reader in this file for a value it cannot read; [message] quotes the value.
class CssFormatException implements Exception {
  CssFormatException(this.message);
  final String message;
  @override
  String toString() => 'CssFormatException: $message';
}

/// `name(inner)` taken apart, or null where [s] is not one function call from end to end.
({String name, String inner})? _call(String s) {
  final open = s.indexOf('(');
  if (open <= 0 || !s.endsWith(')')) return null;
  final name = s.substring(0, open);
  if (!RegExp(r'^[a-zA-Z-]+$').hasMatch(name)) return null;
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')') {
      depth--;
      if (depth == 0 && i != s.length - 1) return null;
    }
  }
  return (name: name.toLowerCase(), inner: s.substring(open + 1, s.length - 1));
}

// --- numbers and lengths ---------------------------------------------------------------------------------------

/// A CSS number, length, time or angle as one figure: lengths in logical pixels, times in milliseconds, angles in
/// degrees, a percentage as its number. `calc()`, `clamp()`, `min()` and `max()` are worked out.
double evalNumber(String expression, [CssContext ctx = const CssContext()]) {
  final parser = _Expr(expression.trim(), ctx);
  final value = parser.sum();
  parser.ws();
  if (parser.i != parser.s.length) throw CssFormatException('unexpected "${parser.s.substring(parser.i)}" in "$expression"');
  return value;
}

/// A recursive-descent reader of one arithmetic expression: [sum] over [product] over [unary] over [primary],
/// with [i] the place reached in [s].
class _Expr {
  _Expr(this.s, this.ctx);
  final String s;
  final CssContext ctx;
  int i = 0;

  static final _number = RegExp(r'(\d+\.?\d*|\.\d+)(e[+-]?\d+)?', caseSensitive: false);
  static final _ident = RegExp(r'[a-zA-Z%][a-zA-Z-]*');

  void ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t')) {
      i++;
    }
  }

  double sum() {
    var value = product();
    while (true) {
      ws();
      if (i >= s.length) return value;
      final ch = s[i];
      if (ch == '+') {
        i++;
        value += product();
      } else if (ch == '-') {
        i++;
        value -= product();
      } else {
        return value;
      }
    }
  }

  double product() {
    var value = unary();
    while (true) {
      ws();
      if (i >= s.length) return value;
      final ch = s[i];
      if (ch == '*') {
        i++;
        value *= unary();
      } else if (ch == '/') {
        i++;
        value /= unary();
      } else {
        return value;
      }
    }
  }

  double unary() {
    ws();
    if (i < s.length && s[i] == '-') {
      i++;
      return -unary();
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return unary();
    }
    return primary();
  }

  /// A bracketed sum, a number with its unit, or one of the functions `calc`, `clamp`, `min` and `max`.
  double primary() {
    ws();
    if (i >= s.length) throw CssFormatException('"$s" ends early');
    if (s[i] == '(') {
      i++;
      final value = sum();
      _expect(')');
      return value;
    }
    final number = _number.matchAsPrefix(s, i);
    if (number != null) {
      i = number.end;
      final value = double.parse(number.group(0)!);
      final unit = _ident.matchAsPrefix(s, i);
      if (unit == null) return value;
      i = unit.end;
      return value * _unit(unit.group(0)!.toLowerCase());
    }
    final name = _ident.matchAsPrefix(s, i);
    if (name == null) throw CssFormatException('unexpected "${s.substring(i)}" in "$s"');
    i = name.end;
    final word = name.group(0)!.toLowerCase();
    if (i >= s.length || s[i] != '(') throw CssFormatException('"$word" is not a number in "$s"');
    i++;
    final args = <double>[sum()];
    while (true) {
      ws();
      if (i < s.length && s[i] == ',') {
        i++;
        args.add(sum());
      } else {
        break;
      }
    }
    _expect(')');
    switch (word) {
      case 'calc':
        return args.first;
      case 'clamp':
        if (args.length != 3) throw CssFormatException('clamp() takes three in "$s"');
        return math.max(args[0], math.min(args[1], args[2]));
      case 'min':
        return args.reduce(math.min);
      case 'max':
        return args.reduce(math.max);
      default:
        throw CssFormatException('"$word()" is not a number in "$s"');
    }
  }

  void _expect(String ch) {
    ws();
    if (i >= s.length || s[i] != ch) throw CssFormatException('expected "$ch" in "$s"');
    i++;
  }

  /// What one of [unit] is worth in the figure [evalNumber] answers in. A `ch` is taken as half an `em`.
  double _unit(String unit) {
    switch (unit) {
      case 'px':
      case 'ms':
      case 'deg':
      case '%':
        return 1;
      case 'rem':
        return ctx.rem;
      case 'em':
        return ctx.em;
      case 'ch':
        return ctx.em * 0.5;
      case 'vw':
        return ctx.vw / 100;
      case 'vh':
        return ctx.vh / 100;
      case 's':
        return 1000;
      case 'turn':
        return 360;
      default:
        throw CssFormatException('unit "$unit" in "$s"');
    }
  }
}

// --- colours ---------------------------------------------------------------------------------------------------

/// A CSS colour, kept in OKLCH. [current] is what `currentColor` means where the value is read.
Oklch evalColor(String value, {CssContext ctx = const CssContext(), Oklch? current}) {
  final s = value.trim();
  final lower = s.toLowerCase();
  switch (lower) {
    case 'transparent':
      return Oklch.transparent;
    case 'white':
      return const Oklch(1, 0, 0);
    case 'black':
      return const Oklch(0, 0, 0);
    case 'currentcolor':
      return current ?? const Oklch(0, 0, 0);
  }
  if (s.startsWith('#')) return _hex(s);
  final call = _call(s);
  if (call == null) throw CssFormatException('not a colour: "$value"');
  switch (call.name) {
    case 'oklch':
      return _oklch(call.inner, ctx, current);
    case 'rgb':
    case 'rgba':
      return _rgb(call.inner, ctx);
    case 'color-mix':
      return _mix(call.inner, ctx, current);
    default:
      throw CssFormatException('not a colour: "$value"');
  }
}

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
Oklch _hex(String s) {
  var hex = s.substring(1);
  if (hex.length == 3 || hex.length == 4) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length != 6 && hex.length != 8) throw CssFormatException('not a colour: "$s"');
  double at(int i) => int.parse(hex.substring(i, i + 2), radix: 16) / 255;
  return Oklch.fromSrgb(at(0), at(2), at(4), hex.length == 8 ? at(6) : 1);
}

/// An alpha written as a share of one or as a percentage.
double _alpha(String s, CssContext ctx) => s.trim().endsWith('%') ? evalNumber(s, ctx) / 100 : evalNumber(s, ctx);

/// The inside of `oklch()`: three channels and an optional `/ alpha`, each a number, a percentage (100% of chroma
/// is 0.4) or a `calc()`, with the relative `from` form.
Oklch _oklch(String inner, CssContext ctx, Oklch? current) {
  final halves = splitTop(inner, '/');
  var parts = splitTop(halves[0], ' ');
  var alpha = halves.length > 1 ? null : 1.0;
  // `oklch(from <colour> l c h / alpha)`: the base colour's own channels, named, for the rest to work from.
  var named = const <String, double>{};
  if (parts.isNotEmpty && parts.first == 'from') {
    final base = evalColor(parts[1], ctx: ctx, current: current);
    named = {'l': base.l, 'c': base.c, 'h': base.h, 'alpha': base.alpha};
    parts = parts.sublist(2);
  }
  if (parts.length != 3) throw CssFormatException('oklch() takes three channels: "$inner"');
  String fill(String s) => named.isEmpty ? s : s.replaceAllMapped(RegExp(r'(?<![\w.-])(alpha|l|c|h)(?![\w(-])'), (m) => '${named[m.group(1)]}');
  final lRaw = fill(parts[0]), cRaw = fill(parts[1]), hRaw = fill(parts[2]);
  final l = lRaw.endsWith('%') ? evalNumber(lRaw, ctx) / 100 : evalNumber(lRaw, ctx);
  final c = cRaw.endsWith('%') ? evalNumber(cRaw, ctx) / 100 * 0.4 : evalNumber(cRaw, ctx);
  final h = hRaw == 'none' ? 0.0 : evalNumber(hRaw, ctx);
  alpha ??= _alpha(fill(halves[1]), ctx);
  return Oklch(l, c, h % 360, alpha);
}

/// The inside of `rgb()` or `rgba()`, with commas or spaces, the alpha fourth or after a slash.
Oklch _rgb(String inner, CssContext ctx) {
  final halves = splitTop(inner, '/');
  var parts = halves[0].contains(',') ? splitTop(halves[0], ',') : splitTop(halves[0], ' ');
  double? alpha;
  if (halves.length > 1) alpha = _alpha(halves[1], ctx);
  if (parts.length == 4) {
    alpha = _alpha(parts[3], ctx);
    parts = parts.sublist(0, 3);
  }
  if (parts.length != 3) throw CssFormatException('rgb() takes three channels: "$inner"');
  double channel(String s) => s.endsWith('%') ? evalNumber(s, ctx) / 100 : evalNumber(s, ctx) / 255;
  return Oklch.fromSrgb(channel(parts[0]), channel(parts[1]), channel(parts[2]), alpha ?? 1);
}

/// The inside of `color-mix(in <space>, a [share], b [share])`. Mixed in sRGB where the space says so, in OKLCH
/// otherwise; a share left out is what the other leaves, or half.
Oklch _mix(String inner, CssContext ctx, Oklch? current) {
  final args = splitTop(inner, ',');
  if (args.length != 3) throw CssFormatException('color-mix() takes a space and two colours: "$inner"');
  final space = args[0].toLowerCase();
  ({Oklch colour, double? share}) arg(String s) {
    final words = splitTop(s, ' ');
    if (words.length > 1 && words.last.endsWith('%')) {
      return (colour: evalColor(words.sublist(0, words.length - 1).join(' '), ctx: ctx, current: current), share: evalNumber(words.last, ctx) / 100);
    }
    if (words.length > 1 && words.first.endsWith('%')) {
      return (colour: evalColor(words.sublist(1).join(' '), ctx: ctx, current: current), share: evalNumber(words.first, ctx) / 100);
    }
    return (colour: evalColor(s, ctx: ctx, current: current), share: null);
  }

  final a = arg(args[1]), b = arg(args[2]);
  var wa = a.share ?? (b.share == null ? 0.5 : 1 - b.share!);
  var wb = b.share ?? 1 - wa;
  final total = wa + wb;
  if (total <= 0) return Oklch.transparent;
  // Shares that do not come to the whole are scaled to it, and short of it the result is that much see-through.
  final fade = total < 1 ? total : 1.0;
  wa /= total;
  wb /= total;
  Oklch mixed;
  if (space.contains('srgb')) {
    final ca = a.colour.toColor(), cb = b.colour.toColor();
    final alpha = ca.a * wa + cb.a * wb;
    if (alpha <= 0) return Oklch.transparent;
    double ch(double x, double y) => (x * ca.a * wa + y * cb.a * wb) / alpha;
    mixed = Oklch.fromSrgb(ch(ca.r, cb.r), ch(ca.g, cb.g), ch(ca.b, cb.b), alpha);
  } else {
    mixed = Oklch.mix(a.colour, wa, b.colour, wb);
  }
  return fade == 1 ? mixed : mixed.withAlpha(mixed.alpha * fade);
}

// --- shadows ---------------------------------------------------------------------------------------------------

/// One layer of a `box-shadow`. An inset layer is kept apart: Flutter's [BoxShadow] has no inset, so a widget that
/// needs one draws it itself.
class CssShadow {
  const CssShadow({required this.offset, required this.blur, required this.spread, required this.color, this.inset = false});
  final Offset offset;
  final double blur;
  final double spread;
  final Color color;
  final bool inset;

  /// The sigma CSS blurs this layer by: half its blur radius.
  double get sigma => blur / 2;

  /// As a Flutter shadow that blurs by the same sigma. Flutter turns a blur radius into a sigma its own way
  /// (`radius * 0.57735 + 0.5`), so the radius given here is the one that comes out at CSS's `blur / 2`.
  BoxShadow toBoxShadow() =>
      BoxShadow(offset: offset, blurRadius: sigma <= 0.5 ? 0 : (sigma - 0.5) / 0.57735, spreadRadius: spread, color: color);
}

/// The layers of a `box-shadow` value in the order written, none for `none`. A layer with no colour takes
/// [current], as CSS gives it `currentColor`.
List<CssShadow> evalShadows(String value, {CssContext ctx = const CssContext(), Oklch? current}) {
  final s = value.trim();
  if (s.isEmpty || s.toLowerCase() == 'none') return const [];
  return splitTop(s, ',').map((layer) {
    final lengths = <double>[];
    final rest = <String>[];
    var inset = false;
    for (final word in splitTop(layer, ' ')) {
      if (word.toLowerCase() == 'inset') {
        inset = true;
      } else if (rest.isEmpty && RegExp(r'^([-+.\d]|calc\(|clamp\(|min\(|max\()').hasMatch(word)) {
        lengths.add(evalNumber(word, ctx));
      } else {
        rest.add(word);
      }
    }
    if (lengths.length < 2) throw CssFormatException('not a shadow: "$layer"');
    final colour = rest.isEmpty ? (current ?? const Oklch(0, 0, 0)) : evalColor(rest.join(' '), ctx: ctx, current: current);
    return CssShadow(
      offset: Offset(lengths[0], lengths[1]),
      blur: lengths.length > 2 ? lengths[2] : 0,
      spread: lengths.length > 3 ? lengths[3] : 0,
      color: colour.toColor(),
      inset: inset,
    );
  }).toList();
}

// --- gradients -------------------------------------------------------------------------------------------------

/// A `linear-gradient()`: its angle as CSS counts it (0 is up, 90 is to the right) and its stops. The line a CSS
/// gradient runs along depends on the box, so the Flutter gradient is made for a size.
class CssLinearGradient {
  const CssLinearGradient({required this.degrees, required this.colors, required this.stops});
  final double degrees;
  final List<Color> colors;
  final List<double> stops;

  /// The Flutter gradient for a box of [size]: its ends sit where CSS puts them, far enough out along the angle
  /// that the first and last stops reach the box's corners.
  LinearGradient toGradient([Size size = const Size(1, 1)]) {
    final r = degrees * math.pi / 180;
    final sin = math.sin(r), cos = math.cos(r);
    final half = (size.width * sin.abs() + size.height * cos.abs()) / 2;
    final x = size.width == 0 ? 0.0 : sin * half / (size.width / 2);
    final y = size.height == 0 ? 0.0 : -cos * half / (size.height / 2);
    return LinearGradient(begin: Alignment(-x, -y), end: Alignment(x, y), colors: colors, stops: stops);
  }
}

/// A `linear-gradient()` value read, or null for `none`. Takes an angle or `to <side>` (down where neither is
/// given), an `in oklch` mix, and stops placed in percentages only.
CssLinearGradient? evalGradient(String value, {CssContext ctx = const CssContext(), Oklch? current}) {
  final s = value.trim();
  if (s.isEmpty || s.toLowerCase() == 'none') return null;
  final call = _call(s);
  if (call == null || call.name != 'linear-gradient') throw CssFormatException('not a linear gradient: "$value"');
  var args = splitTop(call.inner, ',');
  var degrees = 180.0;
  var inOklch = false;
  final first = args.first.toLowerCase();
  final firstWords = splitTop(first, ' ');
  final directed = first.startsWith('to ') || RegExp(r'^[-+.\d]').hasMatch(first) && RegExp(r'(deg|turn)$').hasMatch(firstWords.first) || firstWords.first == 'in';
  if (directed) {
    if (first.startsWith('to ')) {
      const sides = {'top': 0.0, 'right': 90.0, 'bottom': 180.0, 'left': 270.0};
      final named = firstWords.skip(1).takeWhile((w) => sides.containsKey(w)).toList();
      if (named.length == 1) {
        degrees = sides[named[0]]!;
      } else if (named.length == 2) {
        // A corner: halfway between its two sides, the short way round.
        final a = sides[named[0]]!, b = sides[named[1]]!;
        degrees = ((a - b).abs() == 270) ? 315 : (a + b) / 2;
      }
    } else if (firstWords.first != 'in') {
      degrees = evalNumber(firstWords.first, ctx);
    }
    inOklch = first.contains('in oklch') || first.contains('in oklab');
    args = args.sublist(1);
  }
  final colours = <Oklch>[];
  final places = <double?>[];
  for (final stop in args) {
    final words = splitTop(stop, ' ');
    var end = words.length;
    final at = <double>[];
    while (end > 1 && words[end - 1].endsWith('%')) {
      at.insert(0, evalNumber(words[end - 1], ctx) / 100);
      end--;
    }
    final colour = evalColor(words.sublist(0, end).join(' '), ctx: ctx, current: current);
    if (at.isEmpty) {
      colours.add(colour);
      places.add(null);
    } else {
      for (final p in at) {
        colours.add(colour);
        places.add(p);
      }
    }
  }
  if (colours.length < 2) throw CssFormatException('a gradient needs two stops: "$value"');
  // Stops with no place share the room between their placed neighbours evenly, as CSS has it.
  places[0] ??= 0;
  places[places.length - 1] ??= 1;
  for (var i = 1; i < places.length - 1; i++) {
    if (places[i] != null) continue;
    var j = i;
    while (places[j] == null) {
      j++;
    }
    final from = places[i - 1]!, to = places[j]!;
    for (var k = i; k < j; k++) {
      places[k] = from + (to - from) * (k - i + 1) / (j - i + 1);
    }
  }
  final outColours = <Color>[];
  final outStops = <double>[];
  for (var i = 0; i < colours.length; i++) {
    outColours.add(colours[i].toColor());
    outStops.add(places[i]!);
    if (i == colours.length - 1) break;
    // A transparent end fades the other colour out rather than passing through black, in either space; a mix asked
    // for in OKLCH is stepped through it, since Flutter only blends in sRGB.
    final a = colours[i], b = colours[i + 1];
    final steps = inOklch || a.alpha == 0 || b.alpha == 0 ? 6 : 0;
    for (var k = 1; k <= steps; k++) {
      final w = k / (steps + 1);
      outColours.add(Oklch.mix(a, 1 - w, b, w).toColor());
      outStops.add(places[i]! + (places[i + 1]! - places[i]!) * w);
    }
  }
  return CssLinearGradient(degrees: degrees, colors: outColours, stops: outStops);
}

// --- motion ----------------------------------------------------------------------------------------------------

/// A CSS easing: one of the named keywords or a `cubic-bezier()`.
Curve evalCurve(String value) {
  final s = value.trim().toLowerCase();
  switch (s) {
    case 'linear':
      return Curves.linear;
    case 'ease':
      return const Cubic(0.25, 0.1, 0.25, 1);
    case 'ease-in':
      return const Cubic(0.42, 0, 1, 1);
    case 'ease-out':
      return const Cubic(0, 0, 0.58, 1);
    case 'ease-in-out':
      return const Cubic(0.42, 0, 0.58, 1);
  }
  final call = _call(s);
  if (call == null || call.name != 'cubic-bezier') throw CssFormatException('not an easing: "$value"');
  final p = splitTop(call.inner, ',').map(double.parse).toList();
  if (p.length != 4) throw CssFormatException('cubic-bezier() takes four: "$value"');
  return Cubic(p[0], p[1], p[2], p[3]);
}

/// A CSS time (`120ms`, `0.2s`) as a [Duration].
Duration evalDuration(String value) {
  final ms = evalNumber(value);
  return Duration(microseconds: (ms * 1000).round());
}

/// `420ms cubic-bezier(0.3, 1.4, 0.5, 1)`: a time and the easing after it, as the app's own motion tokens are written.
({Duration duration, Curve curve}) evalTransition(String value) {
  final words = splitTop(value.trim(), ' ');
  if (words.isEmpty) throw CssFormatException('not a transition: "$value"');
  return (duration: evalDuration(words.first), curve: words.length > 1 ? evalCurve(words.sublist(1).join(' ')) : Curves.linear);
}
