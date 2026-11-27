import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import 'css_value.dart';
import 'sheet.dart';
import 'tokens.dart';

/// The kit's own token sheet, as `@glacier/tokens` ships it.
const String glacierTokensAsset = 'packages/glacier/assets/css/tokens.css';

/// Reads the kit's tokens and then [more] stylesheets of the app's, in the order a page would load them.
Future<TokenSheet> loadTokenSheet({List<String> more = const [], AssetBundle? bundle}) async {
  final from = bundle ?? rootBundle;
  final sheets = <String>[];
  for (final asset in [glacierTokensAsset, ...more]) {
    sheets.add(await from.loadString(asset));
  }
  return TokenSheet.parseAll(sheets);
}

/// The device pixel ratio a test's lines of text are rounded at, in place of its window's. A page's engine rounds a
/// line of `line-height: normal` in device pixels (line_height.dart), so a rectangle measured on a desktop's page
/// (ratio 1) is only met by lines rounded at 1, whatever density the test draws its picture at. A test says the ratio
/// its fixture was measured at here (the app's `pumpApp(measuredAt:)`) and puts null back after; the app never sets
/// it. A border keeps the window's ratio ([CssContext.border]): at 1 and at 2 a 1px rule is the same.
double? debugFixturePixelRatio;

/// Puts the design tokens over a subtree, as `<html data-theme=... data-density=...>` does on the page.
///
/// [attrs] are the page's `data-` attributes without the prefix. `theme` may be left out to follow the system's
/// light or dark. The tokens are worked out again when the window's width changes (the type and space scales are
/// fluid) or its safe areas do.
class GlacierTheme extends StatefulWidget {
  const GlacierTheme({super.key, required this.sheet, this.attrs = const {}, this.typography = const GlacierTypography(), this.resizeSettle, required this.child});

  /// How long the window's size must stand still before the tokens are worked out for it. Null (the kit's own way):
  /// at once, at every size. A desktop app whose window is dragged larger or smaller gives a moment here: the tokens
  /// (and so everything drawn from them) were otherwise made anew at every frame of the drag. A change of anything
  /// else (the theme, the density, the sheet, the safe areas) is always taken at once.
  final Duration? resizeSettle;

  final TokenSheet sheet;
  final Map<String, String> attrs;

  /// The page's own type settings (`html { font-feature-settings }`, a web font's subsets).
  final GlacierTypography typography;
  final Widget child;

  /// The tokens in force at [context].
  static Tokens of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_TokensScope>();
    assert(scope != null, 'No GlacierTheme above this widget.');
    return scope!.tokens;
  }

  static Tokens? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_TokensScope>()?.tokens;

  @override
  State<GlacierTheme> createState() => _GlacierThemeState();
}

class _GlacierThemeState extends State<GlacierTheme> {
  /// The tokens last made, and a hash of everything they were made from: made again only when that changes.
  Tokens? _tokens;
  Object? _key;

  /// [_key] without the window's size, and the wait for a size being dragged to settle ([GlacierTheme.resizeSettle]).
  Object? _keyButSize;
  Timer? _settling;
  Object? _waitingFor;

  @override
  void dispose() {
    _settling?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = widget.attrs['theme'] ?? (media.platformBrightness == Brightness.dark ? 'dark' : 'light');
    final attrs = {...widget.attrs, 'theme': theme};
    final pad = media.viewPadding;
    // A page is given its insets in whole CSS pixels, each rounded UP (Chromium's `adjustInsetForScale`, on Android
    // `ceil(pixels / density)`): a status bar of 159 device pixels at 2.625 is `61px` to the page, where the
    // phone's own 60.57 stood everything under the bar a device pixel higher than the page's.
    String whole(double inset) => '${inset <= 0 ? 0 : (inset - 1e-6).ceil()}px';
    final env = {
      'safe-area-inset-top': whole(pad.top),
      'safe-area-inset-bottom': whole(pad.bottom),
      'safe-area-inset-left': whole(pad.left),
      'safe-area-inset-right': whole(pad.right),
    };
    final css = CssContext(vw: media.size.width, vh: media.size.height, dpr: media.devicePixelRatio, lineDpr: debugFixturePixelRatio ?? media.devicePixelRatio);
    final key = Object.hash(widget.sheet, Object.hashAll(attrs.entries.map((e) => Object.hash(e.key, e.value))), Object.hashAll(env.values), css, media.disableAnimations, widget.typography);
    final keyButSize = Object.hash(widget.sheet, Object.hashAll(attrs.entries.map((e) => Object.hash(e.key, e.value))), Object.hashAll(env.values), media.devicePixelRatio, debugFixturePixelRatio, media.disableAnimations, widget.typography);
    final settle = widget.resizeSettle;
    if (_tokens != null && key != _key && settle != null && keyButSize == _keyButSize) {
      // Only the window's size changed: the tokens stand until it has been still for a moment, then are made once.
      // A build for another reason while it waits (the same size still) does not start the wait again.
      if (key != _waitingFor) {
        _waitingFor = key;
        _settling?.cancel();
        _settling = Timer(settle, () {
          _waitingFor = null;
          if (mounted) setState(() => _keyButSize = null);
        });
      }
    } else if (_tokens == null || key != _key) {
      _settling?.cancel();
      _settling = null;
      _waitingFor = null;
      _key = key;
      _keyButSize = keyButSize;
      _tokens = Tokens.root(widget.sheet, attrs: attrs, env: env, reducedMotion: media.disableAnimations, css: css, typography: widget.typography);
    }
    return _TokensScope(tokens: _tokens!, child: widget.child);
  }
}

/// An element with classes or attributes of its own inside the theme: `.app-inverse`, `data-hue`.
class GlacierScope extends StatefulWidget {
  const GlacierScope({super.key, this.classes = const {}, this.attrs = const {}, required this.child});

  final Set<String> classes;
  final Map<String, String> attrs;
  final Widget child;

  @override
  State<GlacierScope> createState() => _GlacierScopeState();
}

class _GlacierScopeState extends State<GlacierScope> {
  Tokens? _from;
  Tokens? _tokens;
  Object? _key;

  @override
  Widget build(BuildContext context) {
    final parent = GlacierTheme.of(context);
    final key = Object.hash(Object.hashAllUnordered(widget.classes), Object.hashAllUnordered(widget.attrs.entries.map((e) => Object.hash(e.key, e.value))));
    if (!identical(parent, _from) || key != _key) {
      _from = parent;
      _key = key;
      _tokens = parent.child(attrs: widget.attrs, classes: widget.classes);
    }
    return _TokensScope(tokens: _tokens!, child: widget.child);
  }
}

/// The page's own tokens for what is drawn over the page: a popover's panel, a menu's, the command palette. The web
/// kit portals each to `document.body`, so whatever scope its trigger stands in (`.app-inverse`, a `data-hue`) the
/// panel is the body's child and wears the body's tokens ([Tokens.rootTokens]). An overlay here keeps the inherited
/// widgets of where it was declared, so it is told.
class GlacierRootScope extends StatelessWidget {
  const GlacierRootScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _TokensScope(tokens: GlacierTheme.of(context).rootTokens, child: child);
}

/// Carries the tokens down the tree; dependents rebuild only when the [Tokens] object itself is another.
class _TokensScope extends InheritedWidget {
  const _TokensScope({required this.tokens, required super.child});
  final Tokens tokens;

  @override
  bool updateShouldNotify(_TokensScope old) => !identical(old.tokens, tokens);
}

extension GlacierContext on BuildContext {
  /// The design tokens in force here.
  Tokens get tokens => GlacierTheme.of(this);
}
