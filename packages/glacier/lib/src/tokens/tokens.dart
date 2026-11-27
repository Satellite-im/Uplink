import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

import 'css_value.dart';
import 'oklch.dart';
import 'sheet.dart';
import 'line_height.dart';

/// Font families the stylesheets name that are not fonts of the app's: the system's stand-ins, which Flutter has its
/// own answer for.
const _genericFamilies = {
  'ui-sans-serif',
  'ui-monospace',
  'ui-serif',
  'system-ui',
  '-apple-system',
  'segoe ui',
  'sf mono',
  'sfmono-regular',
  'menlo',
  'sans-serif',
  'serif',
  'monospace',
};

/// What the page sets on `html` for all its text that no token carries: the font features, and for each family the
/// further families its glyphs fall back to (the subsets a web font reaches by `unicode-range`).
class GlacierTypography {
  const GlacierTypography({this.features = const [], this.fallbacks = const {}});
  final List<FontFeature> features;
  final Map<String, List<String>> fallbacks;
}

/// The design tokens as they stand in one place of the app: every custom property of the token sheets, resolved for a
/// theme, a density and a window, and read as the type the caller wants.
///
/// A name is a custom property's, with or without its two dashes: `glacier-space-3`, `--app-ink`. The root holds what
/// `:root` holds on the page; [child] is an element inside it with classes or attributes of its own (`.app-inverse`,
/// `data-hue`), which inherits the root's computed values and lays its own rules over them, as CSS does.
class Tokens {
  Tokens.root(
    TokenSheet sheet, {
    Map<String, String> attrs = const {},
    Map<String, String> env = const {},
    bool reducedMotion = false,
    CssContext css = const CssContext(),
    GlacierTypography typography = const GlacierTypography(),
  }) : this._(sheet, null, Map.unmodifiable(attrs), const {}, env, reducedMotion, css, typography, attrs.keys.toSet(), const {}, root: true);

  Tokens._(this._sheet, this.parent, this.attrs, this.classes, this._env, this.reducedMotion, this.css, this.typography, Set<String> ownAttrs, Set<String> ownClasses, {required bool root}) {
    // The rules that declare something here, later ones over earlier (the sheet is in cascade order). A scope takes
    // only rules about its own classes and attributes, and inherits the rest; the root takes none that ask a class.
    for (final rule in _sheet.rules) {
      if (rule.reducedMotion && !reducedMotion) continue;
      if (!rule.matches(attrs, classes)) continue;
      if (!root && !rule.asksFor(ownAttrs, ownClasses)) continue;
      if (!root && !rule.aboutScope(ownAttrs, ownClasses)) continue;
      if (root && rule.conditions.any((c) => c.isClass)) continue;
      _declared.addAll(rule.declarations);
    }
  }

  final TokenSheet _sheet;

  /// The sheet these were resolved from: for a subtree that lays the page's attributes again over the same rules.
  TokenSheet get sheet => _sheet;
  final Tokens? parent;

  /// The `data-` attributes in force here, without the prefix: `theme`, `density`, `accent`, ...
  final Map<String, String> attrs;
  final Set<String> classes;
  final Map<String, String> _env;
  final bool reducedMotion;
  final CssContext css;
  final GlacierTypography typography;

  /// The tokens of the page itself, from anywhere inside it: what a panel drawn over the page (a menu, a toast)
  /// takes, as a portal to `body` does.
  Tokens get rootTokens {
    var at = this;
    while (at.parent != null) {
      at = at.parent!;
    }
    return at;
  }

  /// What the rules matching here declare, as written; each property's resolved value once asked for (null where
  /// it has none); and those values read as a type, by kind and name.
  final Map<String, String> _declared = {};
  final Map<String, String?> _computed = {};
  final Map<String, Object?> _typed = {};

  /// An element inside this one with [classes] or [attrs] of its own.
  Tokens child({Map<String, String> attrs = const {}, Set<String> classes = const {}}) {
    return Tokens._(
      _sheet,
      this,
      Map.unmodifiable({...this.attrs, ...attrs}),
      Set.unmodifiable({...this.classes, ...classes}),
      _env,
      reducedMotion,
      css,
      typography,
      attrs.keys.toSet(),
      classes,
      root: false,
    );
  }

  bool get isDark => attrs['theme'] == 'dark';

  /// A property's name as the sheet writes it: callers may leave the `--` off.
  static String _name(String name) => name.startsWith('--') ? name : '--$name';

  /// The property's computed value, every `var()` and `env()` in it resolved, or null where nothing declares it.
  String? raw(String name) => _rawOf(_name(name), const {});

  /// [raw] for a full name, remembered: this scope's own declaration, or else what the parent computes. [seen] is
  /// the properties being resolved on the way here, so a ring of `var()`s ends.
  String? _rawOf(String name, Set<String> seen) {
    if (_computed.containsKey(name)) return _computed[name];
    final declared = _declared[name];
    final value = declared != null ? _resolved(declared, {...seen, name}, whole: true) : parent?._rawOf(name, const {});
    return _computed[name] = value;
  }

  /// [value] with each `var(--x, fallback)` and `env(x, fallback)` replaced by what it stands for here.
  String resolve(String value, {Set<String> seen = const {}}) => _resolved(value, seen, whole: false)!;

  /// [resolve]; and for a property's own declaration ([whole]) null where a `var()` in it stands for nothing and
  /// brings no fallback. Such a property is invalid at computed-value time and has no value at all, so a
  /// `var(--it, fallback)` elsewhere takes its fallback, as on the page: settings.css gives every `[data-hue]`
  /// `--hue: var(--hue-dark)` on the dark side, and a hue it does not name (an organization's Report asks for
  /// `amber`) must leave `var(--hue, var(--app-ink))` the ink, not an empty word.
  String? _resolved(String value, Set<String> seen, {required bool whole}) {
    if (!value.contains('var(') && !value.contains('env(')) return value;
    final out = StringBuffer();
    var i = 0;
    while (i < value.length) {
      final isVar = value.startsWith('var(', i), isEnv = value.startsWith('env(', i);
      final wordBefore = i > 0 && RegExp(r'[\w-]').hasMatch(value[i - 1]);
      if ((!isVar && !isEnv) || wordBefore) {
        out.write(value[i]);
        i++;
        continue;
      }
      var depth = 1, end = i + 4;
      while (end < value.length && depth > 0) {
        if (value[end] == '(') depth++;
        if (value[end] == ')') depth--;
        end++;
      }
      final inner = value.substring(i + 4, end - 1);
      final comma = _topComma(inner);
      final name = (comma < 0 ? inner : inner.substring(0, comma)).trim();
      final fallback = comma < 0 ? null : inner.substring(comma + 1).trim();
      String? found;
      if (isEnv) {
        found = _env[name];
      } else if (!seen.contains(name)) {
        // A property that names itself, straight or round a ring, has no value: its fallback stands.
        found = _rawOf(name, seen);
      }
      found ??= fallback == null ? null : _resolved(fallback, seen, whole: whole);
      if (found == null && whole) return null;
      out.write(found ?? '');
      i = end;
    }
    return out.toString();
  }

  /// Where the first comma outside any brackets is, or -1: what parts a `var()`'s name from its fallback.
  static int _topComma(String s) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '(') depth++;
      if (s[i] == ')') depth--;
      if (s[i] == ',' && depth == 0) return i;
    }
    return -1;
  }

  /// [raw], or a [CssFormatException] naming the token where it is missing or empty.
  String _need(String name) {
    final value = raw(name);
    if (value == null || value.isEmpty) throw CssFormatException('no token "${_name(name)}"');
    return value;
  }

  /// A token's typed value, made once and kept for as long as these tokens stand.
  T _cached<T>(String kind, String key, T Function() make) => (_typed['$kind $key'] ??= make()) as T;

  // --- by name ---------------------------------------------------------------------------------------------------

  /// A length in logical pixels, a time in milliseconds, or a plain number. [em] is the font size an `em` in it
  /// measures, where the property is one.
  double len(String name, {double? em}) {
    final value = em == null ? _cached('len', name, () => evalNumber(_need(name), css)) : evalNumber(_need(name), css.withEm(em));
    return _rules.contains(name) ? css.border(value) : value;
  }

  /// The tokens that are the width of a rule or a border wherever they are used, and so are whole device pixels on
  /// the page ([CssContext.border]).
  static const _rules = {'glacier-hairline', 'app-line'};

  double number(String name) => len(name);

  Color color(String name) => _cached('color', name, () => evalColor(_need(name), ctx: css).toColor());

  /// The colour in the space the sheets write it in, for mixing.
  Oklch oklch(String name) => _cached('oklch', name, () => evalColor(_need(name), ctx: css));

  Duration duration(String name) => _cached('duration', name, () => evalDuration(_need(name)));

  Curve curve(String name) => _cached('curve', name, () => evalCurve(_need(name)));

  /// A property written as a time and an easing together, as the app's `--app-pop` is.
  ({Duration duration, Curve curve}) transition(String name) => _cached('transition', name, () => evalTransition(_need(name)));

  /// Every layer of a `box-shadow` token, inset ones included, for a widget that draws them itself.
  List<CssShadow> cssShadows(String name) => _cached('shadows', name, () => evalShadows(_need(name), ctx: css));

  /// The outer layers of a `box-shadow` token, as Flutter draws them.
  List<BoxShadow> shadow(String name) => _cached('shadow', name, () => cssShadows(name).where((s) => !s.inset).map((s) => s.toBoxShadow()).toList());

  /// The shadow every word here stands on (`--glacier-text-shadow`, written as CSS writes a `text-shadow`: `1px 1px 0
  /// #000`), or null where no sheet sets one, as the kit's own never do: [textAt] draws its text over it. A local
  /// addition (VENDORED.md), for a look whose letters each have a hard shadow under them.
  List<Shadow>? get textShadows {
    final layers = _cached<List<Shadow>>('text-shadow', '', () {
      final value = raw('glacier-text-shadow')?.trim() ?? '';
      if (value.isEmpty || value.toLowerCase() == 'none') return const [];
      // A blur as Flutter counts one (CssShadow.toBoxShadow): none at all for a hard shadow.
      return [for (final s in evalShadows(value, ctx: css)) Shadow(offset: s.offset, blurRadius: s.sigma <= 0.5 ? 0 : (s.sigma - 0.5) / 0.57735, color: s.color)];
    });
    return layers.isEmpty ? null : layers;
  }

  /// A gradient token made for [size], or null where the token is `none`.
  Gradient? gradient(String name, [Size size = const Size(1, 1)]) => evalGradient(_need(name), ctx: css)?.toGradient(size);

  /// The fonts a `font-family` token names that the app ships, first choice first.
  List<String> families(String name) => _cached(
        'families',
        name,
        () => splitTop(_need(name), ',').map((f) => f.replaceAll(RegExp('''^['"]|['"]\$'''), '')).where((f) => !_genericFamilies.contains(f.toLowerCase())).toList(),
      );

  // --- by value --------------------------------------------------------------------------------------------------

  /// What [lenOf] and [colorOf] have worked out so far, by the expression as it was written. An expression is
  /// resolved (every `var()` in it) and read (a `calc()`, a `color-mix()`) to be answered, and a widget asks for
  /// its own at every build and a painter at every paint: the same few strings, with the same answer for as long
  /// as these tokens stand (a theme or a sheet that changes is other tokens, with nothing kept). Some callers write
  /// the expression themselves (a share that moves, a hex someone chose), so no more than [_mostKept] are held.
  final Map<String, double> _lengths = <String, double>{};
  final Map<String, Color> _colors = <String, Color>{};
  static const int _mostKept = 2048;

  /// Told each time an expression is read rather than remembered, with `len` or `color`: for a build that measures
  /// itself to count. Null otherwise.
  static void Function(String kind)? debugOnRead;

  /// A CSS expression worked out here, for a rule that computes its own: `calc(var(--glacier-space-10) * 0.74)`.
  double lenOf(String expression, {double? em}) {
    if (em != null) return evalNumber(resolve(expression), css.withEm(em));
    final had = _lengths[expression];
    if (had != null) return had;
    debugOnRead?.call('len');
    if (_lengths.length >= _mostKept) _lengths.clear();
    return _lengths[expression] = evalNumber(resolve(expression), css);
  }

  /// A CSS colour expression worked out here. With [current] (what `currentColor` means) it is read afresh each
  /// time; without, remembered as [lenOf]'s are.
  Color colorOf(String expression, {Color? current}) {
    if (current != null) return evalColor(resolve(expression), ctx: css, current: Oklch.fromColor(current)).toColor();
    final had = _colors[expression];
    if (had != null) return had;
    debugOnRead?.call('color');
    if (_colors.length >= _mostKept) _colors.clear();
    return _colors[expression] = evalColor(resolve(expression), ctx: css).toColor();
  }

  /// The outer layers of a `box-shadow` expression, as Flutter draws them. Not remembered.
  List<BoxShadow> shadowOf(String expression, {Color? current}) =>
      evalShadows(resolve(expression), ctx: css, current: current == null ? null : Oklch.fromColor(current)).where((s) => !s.inset).map((s) => s.toBoxShadow()).toList();

  Gradient? gradientOf(String expression, [Size size = const Size(1, 1)]) => evalGradient(resolve(expression), ctx: css)?.toGradient(size);

  // --- the kit's own scales, by their short names ---------------------------------------------------------------------

  /// `--glacier-space-N`: 0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24.
  double space(int step) => len('glacier-space-$step');

  /// `--glacier-radius-NAME`: none, xs, sm, md, lg, xl, 2xl, full.
  double radius(String name) => len('glacier-radius-$name');

  /// `--glacier-font-size-NAME`: xs, sm, md, lg, xl, 2xl, 3xl, 4xl, 5xl.
  double fontSize(String name) => len('glacier-font-size-$name');

  FontWeight weight(String name) => _weight(len('glacier-font-weight-$name'));

  /// A CSS weight (100 to 900) as Flutter's, to the nearest hundred.
  static FontWeight _weight(double value) => FontWeight.values[((value / 100).round() - 1).clamp(0, 8)];

  /// The kit's text at a step of its scale: size, leading and tracking together, in the sans face unless [mono].
  TextStyle text(String size, {String weight = 'regular', bool mono = false, Color? color}) {
    final px = fontSize(size);
    return textAt(px, weight: weight, mono: mono, color: color, height: len('glacier-leading-$size'), tracking: len('glacier-tracking-$size', em: px), inherit: true);
  }

  /// Text at a size of the caller's own, as a page sets it outside the kit's components: `line-height: normal` unless
  /// [height] is given (a multiple, as a unitless line-height is), no tracking unless [tracking] (in px), the sans
  /// face unless [mono]. `normal` is a browser's: the face's ascent and descent each rounded to a whole pixel
  /// ([normalLineHeight]). Not inherited unless asked, so the leading of whatever default style stands above
  /// cannot arrive in it.
  TextStyle textAt(double px, {String weight = 'regular', bool mono = false, Color? color, double? height, double tracking = 0, bool inherit = false}) {
    final fonts = families(mono ? 'glacier-font-mono' : 'glacier-font-sans');
    final fallback = [...fonts.skip(1), for (final family in fonts) ...?typography.fallbacks[family]];
    final face = TextStyle(
      inherit: inherit,
      fontFamily: fonts.isEmpty ? null : fonts.first,
      fontFamilyFallback: fallback.isEmpty ? null : fallback,
      fontFeatures: mono || typography.features.isEmpty ? null : typography.features,
      fontSize: px,
      height: height,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: tracking,
      fontWeight: this.weight(weight),
      // `font-optical-sizing: auto`, a page's default: a face with an optical size axis (Inter's runs 14 to 32) is
      // drawn at the cut for its size, which is narrower as it grows. A face without the axis ignores this.
      fontVariations: [FontVariation('wght', len('glacier-font-weight-$weight')), if (!mono) FontVariation('opsz', px)],
      color: color ?? this.color('glacier-text'),
      decoration: TextDecoration.none,
      // Under light words only: a dark word over a dark shadow is the same word, smudged.
      shadows: textShadows == null || (color ?? this.color('glacier-text')).computeLuminance() < 0.18 ? null : textShadows,
    );
    // `line-height: normal` as a browser works it out (line_height.dart), which is not the face's own sum.
    return height != null || px <= 0 ? face : face.copyWith(height: normalLineHeight(face, dpr: css.lineDpr) / px);
  }

  /// [style] at another size, with the optical size that goes with it: `copyWith(fontSize:)` alone would keep the cut
  /// of the size it was made at.
  static TextStyle resized(TextStyle style, double px) => style.copyWith(
        fontSize: px,
        fontVariations: [
          for (final variation in style.fontVariations ?? const <FontVariation>[])
            variation.axis == 'opsz' ? FontVariation('opsz', px) : variation,
        ],
      );
}
