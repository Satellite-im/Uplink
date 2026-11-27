import 'package:glacier/glacier.dart';

/// The custom properties of the web app's src/app/settings/settings.css, rule for rule: the page's own ground and
/// the search pill's height, the split view's column, the segmented control's track on a card, and each section's
/// colour with its deeper shade for the light page.
///
/// The token engine reads the stylesheets the app ships as assets (the kit's tokens.css, then ink.css, app.css and
/// typefaces.css); settings.css is not one of them, and the kit has no way to give a subtree a custom property of
/// its own. So the rules are kept here as the stylesheet writes them and laid over the app's sheet once
/// ([installSettingsStyles]); after that `GlacierScope(classes: {'setk__card'})` and
/// `GlacierScope(attrs: {'hue': 'purple'})` resolve `--glacier-segment-track` and `--hue` exactly as the page's
/// cascade does. Only the declarations of custom properties are here; every other rule of settings.css is a
/// widget's to draw (settings_screen.dart, kit/settings_kit.dart).
const String settingsCss = '''
.settingsScreen {
  /* What a pane draws against, the cheat sheet among them (guide/CheatSheet.module.css). */
  --sheet-ground: var(--glacier-bg);
  /* The search field's pill, named for the split view's column to start its sections under the field by. */
  --settings-find-pill: 2.4rem;
}

.settingsScreen[data-layout='split'] {
  --settings-side: 20rem;
}

.settingsScreen__group,
.setk__card {
  /*
   * A segmented control's track is paper-2 on the page (ink.css), which is this card's own ground: on a card its
   * choices sat on nothing. On a card the track is a step further from the page, paper-3.
   */
  --glacier-segment-track: var(--app-paper-3);
}

/*
 * The colours: a shade deeper on the light page, so the glyph holds its contrast on paper; brighter on the dark one.
 */
[data-hue='blue']     { --hue: #0a6fe0; --hue-dark: #4ea1ff; }
[data-hue='purple']   { --hue: #9a45c9; --hue-dark: #c77dff; }
[data-hue='red']      { --hue: #dd3a30; --hue-dark: #ff6b61; }
[data-hue='graphite'] { --hue: #5f6368; --hue-dark: #aeb2b8; }
[data-hue='coral']    { --hue: #c8643f; --hue-dark: #f0906b; }
[data-hue='green']    { --hue: #2a9d4b; --hue-dark: #4cd571; }
[data-hue='yellow']   { --hue: #b58400; --hue-dark: #ffd43b; }
[data-hue='grey']     { --hue: #7c7c82; --hue-dark: #a1a1a8; }
[data-hue='brown']    { --hue: #93724e; --hue-dark: #c7a57f; }
[data-hue='mint']     { --hue: #1f9e8f; --hue-dark: #5fe0cf; }
[data-hue='amber']    { --hue: #c27c00; --hue-dark: #ffb84d; }
[data-hue='indigo']   { --hue: #4f5bd5; --hue-dark: #8c95ff; }
[data-hue='orange']   { --hue: #d9600d; --hue-dark: #ff9a4d; }
[data-hue='cyan']     { --hue: #0a86a8; --hue-dark: #4cc9f0; }
[data-hue='lime']     { --hue: #5a8a00; --hue-dark: #a3d93f; }
[data-hue='rose']     { --hue: #d6336c; --hue-dark: #ff7aa8; }
[data-hue='magenta']  { --hue: #b5279f; --hue-dark: #f07ae0; }
[data-hue='slate']    { --hue: #4a5a70; --hue-dark: #8fa3bf; }

:root[data-theme='dark'] [data-hue] {
  --hue: var(--hue-dark);
}
''';

/// The sheets the rules have been laid over already.
final Expando<bool> _installed = Expando<bool>('settings.css');

/// Lays [settingsCss] over [sheet], after every rule it already has, as the page loads settings.css after the app's
/// own stylesheets. Once for a sheet; asked again, it does nothing. Call it before the theme that reads the sheet is
/// first built (lib/app/ghost_app.dart does).
///
/// A workaround, and the only place the settings reach into the kit's own state: it appends to [TokenSheet.rules].
/// It goes the day `GlacierTheme` or `GlacierScope` can take a stylesheet or inline properties of an app's own.
void installSettingsStyles(TokenSheet sheet) {
  if (_installed[sheet] ?? false) return;
  _installed[sheet] = true;
  appendTokenRules(sheet, TokenSheet.parse(settingsCss).rules);
}

/// Adds [rules] to [sheet] after the ones it has, each keeping its specificity, and puts the cascade back in order.
void appendTokenRules(TokenSheet sheet, Iterable<TokenRule> rules) {
  final base = sheet.rules.length;
  var n = 0;
  sheet.rules.addAll([
    for (final rule in rules)
      TokenRule(conditions: rule.conditions, declarations: rule.declarations, specificity: rule.specificity, order: base + n++, reducedMotion: rule.reducedMotion),
  ]);
  sheet.rules.sort((a, b) => a.specificity != b.specificity ? a.specificity.compareTo(b.specificity) : a.order.compareTo(b.order));
}
