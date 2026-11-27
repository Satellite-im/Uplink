import 'package:flutter/painting.dart' show Color;
import 'package:glacier/glacier.dart';

import 'app_state.dart';
import 'custom_theme.dart' show contrast;

/// CSS of the person's own, laid over the look in use (GMFB-41; Matt, 2026-11-25: "it doesn't seem like the custom css
/// i there", "where can I find the css custom styles"). Written in Settings › Appearance › Custom CSS
/// (lib/ui/custom_css_editor.dart) and kept on this device ('custom_css', with 'custom_css_on').
///
/// What it can be is what the app's own stylesheets are to the app: the app is drawn by widgets that read named
/// values (CSS custom properties, `--app-accent`, `--glacier-radius-md`) from rules about the page, so the CSS that
/// does anything here is rules that set those properties:
///
///     :root { --app-accent: #ff5c8a; --glacier-radius-md: 2px; }
///     :root[data-theme='dark'] { --app-paper: #101418; }
///
/// A property that is not a variable (`color: red`), a selector about an element (`button`, `div > p`) and an
/// at-rule are read by nothing and are said so, not applied. Every rule that is read is put above the app's own and
/// the bubble colour's ([_boost]), as a person's own stylesheet is expected to win.
///
/// Nothing written here can leave the app unusable ([check]): a value that can't be read as what the app reads it
/// as (a colour where a colour is read, a length where a length is) would throw as a screen is built, so each
/// declaration is tried against every value the stylesheets name, on the light and the dark page, and one that
/// breaks any of them is left out and named. Words that can no longer be read on the page are left out the same
/// way, so the switch that turns this off can always be seen.
class CustomCss {
  static const textPref = 'custom_css', onPref = 'custom_css_on';

  /// The most that is kept and read, in characters, and the most declarations.
  static const mostText = 20000, mostDeclarations = 400;

  /// What [app] has written, whether or not it is in use.
  static String text(AppState app) => app.choice(textPref, '');

  static bool on(AppState app) => app.flag(onPref, fallback: false);

  /// What is laid over the look: [text] while it is switched on, else nothing.
  static String used(AppState app) => on(app) ? text(app) : '';

  static void save(AppState app, String css, {required bool on}) {
    app.set(textPref, css.length > mostText ? css.substring(0, mostText) : css);
    app.setFlag(onPref, on);
  }

  /// Every property the app's stylesheets name, in order, for the editor's list (set as the stylesheets are read,
  /// lib/accent.dart).
  static List<String> known = const [];

  /// What became of the CSS in use the last time the app's sheet was made with it (lib/accent.dart): the editor
  /// shows its [CustomCssResult.problems]. Null while none is in use.
  static CustomCssResult? last;

  /// `:root` this many times before each selector: more specific than any rule of the app's stylesheets (five at
  /// most) and than the bubble colour's (six).
  static final _boost = ':root' * 8;

  /// A selector the token sheet reads: `:root`, `[data-x='y']`, `:not([data-x])`, `.class`, and spaces between.
  static final _selector = RegExp(r'''^(?:\s+|:root|:not\(\[data-[\w-]+(?:=['"]?[^'"\]]*['"]?)?\]\)|\[data-[\w-]+(?:=['"]?[^'"\]]*['"]?)?\]|\.[A-Za-z_][\w-]*)+$''');
  static final _name = RegExp(r'^--[A-Za-z0-9_-]+$');

  /// [css] read into the declarations the app can use, each tried against [under] (the stylesheets with the look
  /// and bubble colour in use) on every page in [pages] (the page's `data-` attributes, light and dark).
  static CustomCssResult check(String css, TokenSheet under, List<Map<String, String>> pages) {
    final problems = <String>[];
    if (css.length > mostText) {
      problems.add('Only the first $mostText characters are read.');
      css = css.substring(0, mostText);
    }
    final entries = _read(css, problems);
    if (entries.length > mostDeclarations) {
      problems.add('Only the first $mostDeclarations declarations are read.');
      entries.removeRange(mostDeclarations, entries.length);
    }
    if (entries.isEmpty) return CustomCssResult('', problems, 0);
    final probe = _Probe(under, pages);
    var kept = entries;
    if (probe.broken(kept) != null) {
      // Something breaks: find which, one declaration at a time, keeping every one that reads.
      kept = [];
      for (final e in entries) {
        final why = probe.broken([...kept, e]);
        if (why == null) {
          kept.add(e);
        } else {
          problems.add('${e.name}: ${e.value} is left out: $why');
        }
      }
    }
    return CustomCssResult(_write(kept), problems, kept.length);
  }

  /// The declarations in [css], top-level rules only, with what is passed over said in [problems].
  static List<_Entry> _read(String css, List<String> problems) {
    final out = <_Entry>[];
    final clean = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
    var i = 0;
    while (i < clean.length) {
      final open = clean.indexOf('{', i);
      if (open < 0) {
        if (clean.substring(i).trim().isNotEmpty) problems.add('"${_short(clean.substring(i))}" is not a rule: a rule is a selector and { }.');
        break;
      }
      var depth = 1, close = open + 1;
      while (close < clean.length && depth > 0) {
        if (clean[close] == '{') depth++;
        if (clean[close] == '}') depth--;
        close++;
      }
      final prelude = clean.substring(i, open).trim();
      final body = depth == 0 ? clean.substring(open + 1, close - 1) : clean.substring(open + 1);
      i = close;
      if (depth != 0) problems.add('A { is never closed.');
      if (prelude.startsWith('@')) {
        problems.add('${_short(prelude)} is passed over: @ rules are not read here.');
        continue;
      }
      if (body.contains('{')) {
        problems.add('${_short(prelude)} is passed over: rules inside rules are not read here.');
        continue;
      }
      final selectors = <String>[];
      for (final s in splitTop(prelude, ',')) {
        if (s.isEmpty) continue;
        if (_selector.hasMatch(s)) {
          selectors.add(s);
        } else {
          problems.add('"${_short(s)}" is passed over: the app has no elements to match. Use :root, [data-theme=\'dark\'] or one of the app\'s classes.');
        }
      }
      if (selectors.isEmpty) continue;
      for (final part in splitTop(body, ';')) {
        if (part.isEmpty) continue;
        final colon = part.indexOf(':');
        final name = colon < 0 ? part : part.substring(0, colon).trim();
        final value = colon < 0 ? '' : part.substring(colon + 1).trim().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'\s*!important$'), '');
        if (!_name.hasMatch(name)) {
          problems.add('"${_short(part)}" does nothing here: only variables (--name: value) are read.');
        } else if (value.isEmpty || value.contains('}') || value.contains('{')) {
          problems.add('$name has no value.');
        } else {
          for (final s in selectors) {
            out.add(_Entry(s, name, value));
          }
        }
      }
    }
    return out;
  }

  /// [entries] as rules above everything else: the same selectors, each more specific than the app's own.
  static String _write(List<_Entry> entries) {
    final b = StringBuffer();
    for (final e in entries) {
      b.writeln('${e.selector.startsWith('.') ? '$_boost ' : _boost}${e.selector} { ${e.name}: ${e.value}; }');
    }
    return b.toString();
  }

  static String _short(String s) {
    final one = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return one.length > 60 ? '${one.substring(0, 57)}...' : one;
  }
}

/// What [CustomCss.check] made of a person's CSS: the rules to lay over the app's ([css], empty where none can be
/// used), what was passed over or left out and why, and how many declarations are in use.
class CustomCssResult {
  const CustomCssResult(this.css, this.problems, this.kept);
  final String css;
  final List<String> problems;
  final int kept;
}

class _Entry {
  const _Entry(this.selector, this.name, this.value);
  final String selector, name, value;
}

/// Tries declarations against the stylesheets: every value they name must still be read as what it was read as
/// before, and the words must still be read on the page.
class _Probe {
  _Probe(this.under, this.pages) {
    final names = <String>{};
    for (final rule in under.rules) {
      names.addAll(rule.declarations.keys);
    }
    for (final attrs in pages) {
      final t = Tokens.root(under, attrs: attrs);
      final kinds = <String, int>{};
      for (final name in names) {
        for (var k = 0; k < _readers.length; k++) {
          if (_reads(t, name, k)) {
            kinds[name] = k;
            break;
          }
        }
      }
      _kinds.add(kinds);
      _readable.add(_contrast(t) >= _least);
    }
  }

  final TokenSheet under;
  final List<Map<String, String>> pages;

  /// For each page, how each property is read there before the person's CSS: an index into [_readers]. A property
  /// read as none of them (a font's name, a word) is not in it, and nothing written to it can break.
  final List<Map<String, int>> _kinds = [];

  /// For each page, whether its words could be read on it before.
  final List<bool> _readable = [];

  /// The least contrast between the words and the page, as a look of one's own must have (lib/custom_theme.dart).
  static const _least = 3.0;

  static final List<void Function(Tokens, String)> _readers = [
    (t, n) => t.color(n),
    (t, n) => t.len(n),
    (t, n) => t.transition(n),
    (t, n) => t.curve(n),
    (t, n) => t.cssShadows(n),
    (t, n) => t.gradient(n),
  ];

  static bool _reads(Tokens t, String name, int kind) {
    try {
      _readers[kind](t, name);
      return true;
    } catch (_) {
      // Anything at all: a value that is not of this kind, a missing one, a var() that goes round in a circle.
      return false;
    }
  }

  static double _contrast(Tokens t) {
    try {
      final Color ink = t.color('app-ink'), paper = t.color('app-paper');
      return contrast(ink, paper);
    } catch (_) {
      return 0;
    }
  }

  /// Why the app could not be drawn with [entries] laid over it, or null where it can.
  String? broken(List<_Entry> entries) {
    final TokenSheet sheet;
    try {
      sheet = TokenSheet.kept([...under.rules, ...TokenSheet.parse(CustomCss._write(entries)).rules]);
    } catch (_) {
      return 'it can\'t be read as CSS';
    }
    for (var p = 0; p < pages.length; p++) {
      final t = Tokens.root(sheet, attrs: pages[p]);
      for (final kind in _kinds[p].entries) {
        if (!_reads(t, kind.key, kind.value)) return 'with it, --${kind.key.replaceFirst('--', '')} can\'t be read';
      }
      if (_readable[p] && _contrast(t) < _least) return 'with it, the words can\'t be read on the ${pages[p]['theme'] ?? ''} page'.replaceAll('  ', ' ');
    }
    return null;
  }
}
