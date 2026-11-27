import 'art/app_icon.dart' show LucideIcon;
import 'art/lucide.g.dart';
import 'art/lucide_more.dart';
import 'app_state.dart';
import 'custom_theme.dart';

/// Looks for the whole app, chosen in Settings › Appearance (Matt, 2026-11-16: "spend some time making a few themes
/// for ghost, base one of them heavily on the old AOL chatrooms").
///
/// A look is a block of rules at the end of assets/css/app.css, keyed on `data-theme-preset`: its own twelve greys
/// (which ink.css copies onto the page's paper and ink), its accent and the colour of your own bubbles. The page is
/// told which with [ghostAttrs], so the app, the computer's app and every test that draws a screen stamp the same
/// attributes from the same choice. Uplink is the app's own and stamps no preset at all, so it is drawn exactly as it
/// was before there were looks.
///
/// **Four looks are offered, and each has its packs** (Matt, 2026-11-27: "I think we should add texture packs to all
/// themes, but remove the phosphor entirely and remove the dark dial uptheme, also remove lamplight and mist and make
/// them texture packs for the Ghost theme"). A pack is what a look is drawn with in place of its own, chosen under it
/// in Settings › Appearance › Textures (lib/ui/resource_packs_ui.dart), and it is one of two kinds:
/// - a set of rules that is part of the app, which is a value here like any look ([isPack], [family]): Mist and
///   Lamplight, Uplink's. Each was a look of its own until then and is still drawn exactly as it was, by its own
///   preset, so nothing that goes by the look in use had to learn of packs. It is only chosen somewhere else;
/// - a resource pack's pictures, fetched to the device ([pictures]; lib/packs/resource_pack.dart): Runestone's.
/// Sharp and Dial-Up have none yet. Phosphor is gone ([retired]), and Dial-Up is its daytime half alone.
///
/// [after] is a note for whoever works on it, never shown: the visible names stay the app's own (no other company's
/// name or marks, as the store listings ask).
enum Look {
  ghost('Uplink', '', 'The app\'s own: white paper and black ink, or the reverse, and your bubbles in the colour you choose.', Lucide.ghost, light: true, dark: true, keyboard: 'white'),
  // Uplink's packs, each its own preset in app.css and its own brightness.
  mist('Mist', 'morning fog on pale water', 'A pale aqua page with deep teal ink, and deep teal bubbles of your own.', LucideMore.cloud, light: true, dark: false, keyboard: 'ghost'),
  lamplight('Lamplight', 'a reading lamp late at night: warm, low on blue', 'Warm parchment words on a brown-black page, and amber bubbles. For reading late.', Lucide.lightbulb, light: false, dark: true, keyboard: 'orange'),
  sharp('Sharp', 'high contrast, every grey above WCAG AA; its dark half is the true-black OLED choice', 'Black on white or white on black, lines you can see, and teal bubbles.', Lucide.square, light: true, dark: true, keyboard: 'ghost'),
  // Modelled on AOL's late-90s chat rooms; the name stays here in a comment, out of the binary's strings. Light
  // only: its dark half (After Hours, the era's high-contrast black scheme) was taken out with Phosphor.
  dialup(
    'Dial-Up',
    'a late-90s online service\'s chat room; nothing of theirs is copied',
    'Silver windows, navy title bars and a white page where each line is a name and what they said.',
    Lucide.globe,
    light: true,
    dark: false,
    keyboard: 'blue',
    rounding: 'square',
    // Arimo, bundled (assets/fonts/ArimoVariable.ttf): Arial's measures without Arial, which may not be shipped.
    font: 'arimo',
  ),
  // Modelled on Old School RuneScape's interface as its players' resource packs draw it (melkypie/resource-packs;
  // Matt, 2026-11-27: "make a theme in Ghost that fits this with the runescape font and everything", of Nichy's Dark
  // Vanilla, then "let's try the duckscape theme instead and bring in the pixelated looks"). None of a pack's pictures
  // are here: the look is drawn from the one on the device (lib/packs/), Duckscape unless another is chosen, and in
  // flat stone by Dial-Up's chrome (lib/ui/dialup/) until it is there. The names stay in this comment, out of what
  // is shown.
  runestone(
    'Runestone',
    'an old adventure game\'s interface in its players\' dark stone pack; the letters are the game\'s own, traced and given to the public domain by others (assets/fonts/CC0-Runestone.txt), and nothing else of theirs is copied',
    'Dark stone windows with chiselled edges, yellow and orange words in an old adventure game\'s letters, and chats written on grey parchment.',
    Lucide.scrollText,
    light: false,
    dark: true,
    keyboard: 'orange',
    rounding: 'square',
    // Runestone, bundled (assets/fonts/Runestone-*.ttf, made by tool/runestone_font.py).
    font: 'runestone',
  );

  const Look(
    this.label,
    this.after,
    this.description,
    this.icon, {
    required this.light,
    required this.dark,
    required this.keyboard,
    this.rounding,
    this.font,
  });

  /// Its name, what it is modelled on (in code only), and a line on what it looks like.
  final String label;
  final String after;
  final String description;
  final LucideIcon icon;

  /// Which brightness it has: both, or only one, which it is then always drawn in whatever Theme says.
  final bool light, dark;

  /// The id among Ghost Keyboard's colours (lib/backgrounds.dart's `bubbleColors`) nearest this look's own bubbles,
  /// told to the keyboard while your bubbles are the look's ('theme'): the keyboard knows only those ids.
  final String keyboard;

  /// `data-rounding` (ink.css: square, soft, rounder), where the look stamps one.
  final String? rounding;

  /// `data-font`, where the look draws in a face of its own: one bundled in pubspec, hung with the emoji set in
  /// ghostTypography's fallbacks, and loaded by every test that draws a screen.
  final String? font;

  /// Offered in Settings › Appearance: every look is now; a look still being built can say false here.
  bool get ready => true;

  /// The look this is chosen under: itself, unless it is one of another's packs (Mist and Lamplight are Uplink's).
  Look get family => switch (this) { mist || lamplight => ghost, _ => this };

  /// Whether this is a pack: chosen under its [family] in Settings › Appearance › Textures, not among the looks.
  bool get isPack => family != this;

  /// The looks offered in Settings › Appearance.
  static List<Look> get offered => [for (final l in values) if (!l.isPack) l];

  /// This look's packs that are part of the app, each a set of rules of its own.
  List<Look> get packs => [for (final l in values) if (l.isPack && l.family == this) l];

  /// Whether it is drawn with a resource pack's pictures, fetched to the device (lib/packs/resource_pack.dart).
  bool get pictures => this == runestone;

  /// The choice the look is kept under, as its enum name.
  static const pref = 'look';

  /// The choice a look's pack is kept under while another look is in use: the pack's name, empty for the look's own.
  static String packPref(Look family) => 'look_pack_${family.name}';

  /// Looks that were in the app and are not: Phosphor (Matt, 2026-11-27: "remove the phosphor entirely").
  static const retired = {'phosphor'};

  /// The look chosen in [app]: Uplink where none was, or one no longer known.
  static Look of(AppState app) => named(app.choice(pref, 'ghost'));

  static Look named(String name) {
    for (final l in values) {
      if (l.name == name) return l;
    }
    return ghost;
  }

  /// What [family] is drawn as when it is chosen: the pack [app] last had it in, where it had one, else the look.
  static Look last(AppState app, Look family) {
    final kept = named(app.choice(packPref(family), ''));
    return kept.isPack && kept.family == family ? kept : family;
  }

  /// Where the look kept in [app] is one of the [retired], Uplink is chosen in its place as if it had been pressed:
  /// your bubbles go back to the colour they had before the look, unless a colour was chosen under it or a look of
  /// your own is in use (whose accent they wear). Asked once the choices are read (AppState.load).
  static void settle(AppState app) {
    if (!retired.contains(app.choice(pref, 'ghost'))) return;
    app.set('theme_bubble', ghost.keyboard);
    app.set(pref, ghost.name);
    if (app.bubble == 'theme' && CustomTheme.used(app) == null) app.setBubble(app.choice('bubble_before_look', 'white'));
  }

  /// The brightness it is always drawn in, or null where it follows Theme.
  String? get forced => light && dark ? null : (light ? 'light' : 'dark');

  /// The page's `data-` attributes for this look on [platform], with [theme] ('light', 'dark', or null to follow the
  /// phone) where the look has both halves.
  Map<String, String> attrs({required String platform, String? theme}) {
    final shown = forced ?? theme;
    return {
      'platform': platform,
      'theme': ?shown,
      if (this != ghost) 'theme-preset': name,
      'rounding': ?rounding,
      'font': ?font,
    };
  }
}

/// The page's `data-` attributes for [s]'s choices on [platform] ('mobile' or 'desktop'): the look, and the theme
/// where it is not the phone's own ('system'). The app (lib/main.dart, lib/desktop/main.dart) and every test that
/// draws a screen take them from here, so a choice in AppState is all a look needs.
///
/// A look of the person's own in use (lib/custom_theme.dart) stamps its own preset and brightness in place of the
/// look's; the Readable font (GMFB-41) stamps `data-font` over any look's own face.
Map<String, String> ghostAttrs(AppState s, String platform) {
  final custom = CustomTheme.used(s);
  final attrs = custom != null ? custom.attrs(platform: platform) : Look.of(s).attrs(platform: platform, theme: s.theme == 'system' ? null : s.theme);
  if (s.font == 'readable') attrs['font'] = 'readable';
  return attrs;
}
