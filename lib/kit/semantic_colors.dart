import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

/// The few colours that mean something whatever the look (lib/looks.dart): danger, unread, chosen, online and the
/// rest. Each was a hex written where it was drawn, so no look could reach it; now each is a token of the app's
/// (assets/css/app.css, `--app-danger` and so on) with that same hex as its value and as the fallback here, so Uplink's
/// own look draws them exactly as before and a look may name its own.
extension AppColors on Tokens {
  /// Something failed or will be lost: a message that did not go, Delete, a muted microphone.
  Color get danger => colorOf('var(--app-danger, #dd3a30)');

  /// The dot of a conversation with something unread.
  Color get unread => colorOf('var(--app-unread, #4f5bd5)');

  /// What is picked: a ticked row, a reaction of your own, a message found again.
  Color get chosen => colorOf('var(--app-chosen, #4f5bd5)');

  /// The wash under a reaction or a choice of your own.
  Color get chosenWash => colorOf('color-mix(in srgb, var(--app-chosen, #4f5bd5) 22%, transparent)');

  /// Archive, as a row slid aside shows it.
  Color get info => colorOf('var(--app-info, #4f5bd5)');

  /// Someone in a call, talking, or a step done.
  Color get online => colorOf('var(--app-online, #2fb35a)');

  /// A warning that is not yet a failure.
  Color get warn => colorOf('var(--app-warn, #c27c00)');

  /// Pin, as a row slid aside shows it.
  Color get pinned => colorOf('var(--app-pinned, #d38b00)');

  /// Selected words in a message or a field.
  Color get textSelection => colorOf('var(--app-text-selection, color-mix(in srgb, #4f5bd5 30%, transparent))');

  /// The dimmed page behind a sheet.
  Color get sheetScrim => colorOf('var(--app-sheet-scrim, #00000066)');

  /// The dimmed page behind a held message's menu.
  Color get menuScrim => colorOf('var(--app-menu-scrim, #00000073)');

  /// A failed message of your own: a wash of danger on the paper.
  Color get failedGround => colorOf('color-mix(in srgb, var(--app-danger, #dd3a30) 18%, var(--app-paper-2))');

  /// [hue]'s own colour (one of lib/kit/settings_css.dart's `data-hue` names), whatever the look: for a colour picker,
  /// whose swatches must show the colour picked even where a look settles hues into its own (Runestone draws every hue
  /// in its orange, Dial-Up in black, Mist folds blue, purple and indigo into its teal). A name it doesn't know draws
  /// in the page's ink.
  Color hueSwatch(String hue) {
    final pair = _hueSwatches[hue];
    return pair == null ? color('app-ink') : Color(isDark ? pair.$2 : pair.$1);
  }
}

/// lib/kit/settings_css.dart's `--hue` and `--hue-dark` for each name, as raw values ([AppColors.hueSwatch]).
const _hueSwatches = <String, (int, int)>{
  'blue': (0xFF0A6FE0, 0xFF4EA1FF),
  'purple': (0xFF9A45C9, 0xFFC77DFF),
  'red': (0xFFDD3A30, 0xFFFF6B61),
  'graphite': (0xFF5F6368, 0xFFAEB2B8),
  'coral': (0xFFC8643F, 0xFFF0906B),
  'green': (0xFF2A9D4B, 0xFF4CD571),
  'yellow': (0xFFB58400, 0xFFFFD43B),
  'grey': (0xFF7C7C82, 0xFFA1A1A8),
  'brown': (0xFF93724E, 0xFFC7A57F),
  'mint': (0xFF1F9E8F, 0xFF5FE0CF),
  'amber': (0xFFC27C00, 0xFFFFB84D),
  'indigo': (0xFF4F5BD5, 0xFF8C95FF),
  'orange': (0xFFD9600D, 0xFFFF9A4D),
  'cyan': (0xFF0A86A8, 0xFF4CC9F0),
  'lime': (0xFF5A8A00, 0xFFA3D93F),
  'rose': (0xFFD6336C, 0xFFFF7AA8),
  'magenta': (0xFFB5279F, 0xFFF07AE0),
  'slate': (0xFF4A5A70, 0xFF8FA3BF),
};
