import 'split.dart';

/// One thing a rule's selector asks of where it applies: an attribute (`[data-theme='dark']`, `[data-split]`,
/// `:not([data-accent])`) or a class (`.app-inverse`).
class TokenCondition {
  const TokenCondition.attr(this.key, this.value, {this.negated = false}) : isClass = false;
  const TokenCondition.cls(this.key)
      : value = null,
        negated = false,
        isClass = true;

  /// The attribute's name without `data-`, or the class's name.
  final String key;

  /// The value asked for, or null where being present is enough.
  final String? value;
  final bool negated;
  final bool isClass;

  /// Whether an element with these attributes and classes, its own and inherited, meets the condition.
  bool holds(Map<String, String> attrs, Set<String> classes) {
    if (isClass) return classes.contains(key);
    final has = value == null ? attrs.containsKey(key) : attrs[key] == value;
    return negated ? !has : has;
  }
}

/// A rule of a token sheet that declares custom properties: where it applies, what it declares, and where it stands
/// in the cascade.
class TokenRule {
  const TokenRule({required this.conditions, required this.declarations, required this.specificity, required this.order, this.reducedMotion = false, this.subject});

  final List<TokenCondition> conditions;

  /// What the selector's last compound asks without a `:not`: the element the rule is about must have these itself.
  /// `[data-theme='dark'][data-accent='red']` is about one element with both, so a swatch that only says its accent
  /// inside a dark page is not it and keeps `[data-accent='red']`'s light ramp, as on the page; `[data-theme='dark']
  /// [data-hue]` is about any element with a hue under a dark one. Null where the selector was not read in parts.
  final List<TokenCondition>? subject;

  /// Custom properties by their whole name, `--glacier-space-2`.
  final Map<String, String> declarations;

  /// How many simple selectors the selector has, and where the rule came in the sheets: a sheet's rules are
  /// sorted by the first and then the second.
  final int specificity;
  final int order;

  /// Inside `@media (prefers-reduced-motion: reduce)`.
  final bool reducedMotion;

  bool matches(Map<String, String> attrs, Set<String> classes) => conditions.every((c) => c.holds(attrs, classes));

  /// Whether the rule answers to something a scope brings of its own: one of its classes or attributes.
  bool asksFor(Set<String> attrKeys, Set<String> classes) =>
      conditions.any((c) => !c.negated && (c.isClass ? classes.contains(c.key) : attrKeys.contains(c.key)));

  /// Whether everything the selector's last compound asks is the scope's own: its attributes and classes, not what
  /// it inherits from the page round it.
  bool aboutScope(Set<String> attrKeys, Set<String> classes) =>
      subject == null || subject!.every((c) => c.isClass ? classes.contains(c.key) : attrKeys.contains(c.key));
}

/// The custom properties of one or more stylesheets, as rules in cascade order.
///
/// This reads the very CSS the web app ships (`@glacier/tokens`' tokens.css, then the app's own ink.css, app.css and
/// typefaces.css) and keeps every rule whose selector is made only of `:root`, `data-` attributes and classes.
/// Rules for particular elements are a widget's to port; rules inside `prefers-color-scheme` are left out, because
/// the theme is always named here (`data-theme` is set from the system's when the person chose "system") and each of
/// those rules has a `[data-theme='dark']` twin.
class TokenSheet {
  TokenSheet._(this.rules);

  /// A sheet from rules already in cascade order: what [TokenSheet.parseAll] made of the same stylesheets some
  /// other time. The app's own is made as it is built (tool/token_sheet.dart writes lib/app/token_sheet.g.dart), so
  /// its start reads and parses no CSS; a test holds the two to be the same, rule for rule.
  TokenSheet.kept(Iterable<TokenRule> rules) : rules = List.of(rules);

  final List<TokenRule> rules;

  factory TokenSheet.parse(String css) => TokenSheet.parseAll([css]);

  /// Several stylesheets, in the order the page loads them.
  factory TokenSheet.parseAll(Iterable<String> sheets) {
    final rules = <TokenRule>[];
    for (final css in sheets) {
      final clean = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').replaceAll(RegExp(r'@(import|charset)[^;]*;'), '');
      _block(clean, rules, reducedMotion: false);
    }
    rules.sort((a, b) => a.specificity != b.specificity ? a.specificity.compareTo(b.specificity) : a.order.compareTo(b.order));
    return TokenSheet._(rules);
  }

  /// Reads the rules of one block of CSS into [out]. Of the at-rules only a reduced-motion `@media` is gone into;
  /// a rule with rules nested in it is passed over.
  static void _block(String css, List<TokenRule> out, {required bool reducedMotion}) {
    var i = 0;
    while (i < css.length) {
      final open = css.indexOf('{', i);
      if (open < 0) return;
      var depth = 1, close = open + 1;
      while (close < css.length && depth > 0) {
        final ch = css[close];
        if (ch == '{') depth++;
        if (ch == '}') depth--;
        close++;
      }
      final prelude = css.substring(i, open).trim();
      final body = css.substring(open + 1, close - 1);
      i = close;
      if (prelude.startsWith('@')) {
        if (prelude.startsWith('@media') && prelude.contains('prefers-reduced-motion')) _block(body, out, reducedMotion: true);
        continue;
      }
      if (body.contains('{')) continue;
      final declarations = _declarations(body);
      if (declarations.isEmpty) continue;
      for (final selector in splitTop(prelude, ',')) {
        final parsed = _selector(selector);
        if (parsed == null) continue;
        out.add(TokenRule(conditions: parsed.conditions, declarations: declarations, specificity: parsed.specificity, order: out.length, reducedMotion: reducedMotion, subject: parsed.subject));
      }
    }
  }

  /// The custom properties a rule's body declares, each value on one line with single spaces.
  static Map<String, String> _declarations(String body) {
    final out = <String, String>{};
    for (final part in splitTop(body, ';')) {
      if (!part.startsWith('--')) continue;
      final colon = part.indexOf(':');
      if (colon < 0) continue;
      out[part.substring(0, colon).trim()] = part.substring(colon + 1).trim().replaceAll(RegExp(r'\s+'), ' ');
    }
    return out;
  }

  /// One piece of a selector this sheet can read: a space, `:root`, a negated `data-` attribute (groups 1 and 2),
  /// a `data-` attribute (3 and 4) or a class (5).
  static final _piece = RegExp(
    r'''\s+|:root|:not\(\[data-([\w-]+)(?:=['"]?([^'"\]]*)['"]?)?\]\)|\[data-([\w-]+)(?:=['"]?([^'"\]]*)['"]?)?\]|\.([A-Za-z_][\w-]*)''',
  );

  /// A selector as its conditions, or null where any part of it is something else (an element, a pseudo-class).
  static ({List<TokenCondition> conditions, int specificity, List<TokenCondition> subject})? _selector(String selector) {
    final conditions = <TokenCondition>[];
    // The last compound's own conditions: begun again at each space between compounds.
    var subject = <TokenCondition>[];
    var specificity = 0;
    var i = 0;
    while (i < selector.length) {
      final m = _piece.matchAsPrefix(selector, i);
      if (m == null) return null;
      i = m.end;
      final text = m.group(0)!;
      if (text.trim().isEmpty) {
        if (i < selector.length) subject = <TokenCondition>[];
        continue;
      }
      specificity++;
      if (text == ':root') continue;
      if (m.group(1) != null) {
        conditions.add(TokenCondition.attr(m.group(1)!, m.group(2), negated: true));
      } else if (m.group(3) != null) {
        final condition = TokenCondition.attr(m.group(3)!, m.group(4));
        conditions.add(condition);
        subject.add(condition);
      } else {
        final condition = TokenCondition.cls(m.group(5)!);
        conditions.add(condition);
        subject.add(condition);
      }
    }
    return (conditions: conditions, specificity: specificity, subject: subject);
  }
}
