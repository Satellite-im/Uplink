/// A look of one's own as a file (GMFB-41, from the Uplink gap review: "Custom themes as a file you can import/share
/// (colours and fonts)"): a `.ghostlook`, JSON, made in Settings › Appearance and taken in there
/// (lib/ui/custom_theme_editor.dart). It holds what a look's code holds (lib/custom_theme.dart) said in words anyone
/// can read and change, and the custom CSS that was in use beside it, if any (lib/custom_css.dart):
///
///     {
///       "ghostlook": 1,
///       "name": "Harbour",
///       "dark": true,
///       "colours": {"background": "#0B0B0C", "surface": "#1E1F24", "text": "#F4F1EA", "accent": "#0C7F7A"},
///       "font": "readable",
///       "css": ":root { --glacier-radius-md: 2px; }"
///     }
///
/// Read back strictly ([LookFile.read]): the colours as #RRGGBB, a name a look may have, a face among the app's own
/// (one a newer build knows and this one doesn't is passed over, and said), and CSS only as text. The CSS is never run
/// here: as written in the editor, it is checked declaration by declaration when it is used.
library;

import 'dart:convert';
import 'dart:ui' show Color;

import 'custom_css.dart';
import 'custom_theme.dart';

class LookFile {
  const LookFile({required this.theme, this.css, this.passedOver = const []});

  final CustomTheme theme;

  /// The custom CSS that came with it; null where none did.
  final String? css;

  /// What was in the file and is not taken, in a few words each (a face this build hasn't got).
  final List<String> passedOver;

  /// The file's ending, and its version, under "ghostlook".
  static const ending = 'ghostlook', version = 1;

  /// The most a look's file is read to: a look and the most custom CSS kept, with room to spare.
  static const mostBytes = CustomCss.mostText * 4 + 4096;

  /// [theme] as a file's text, with [css] where it is given and not blank.
  static String write(CustomTheme theme, {String? css}) => const JsonEncoder.withIndent('  ').convert({
        'ghostlook': version,
        'name': theme.name.trim(),
        'dark': theme.dark,
        'colours': {'background': hex(theme.paper), 'surface': hex(theme.surface), 'text': hex(theme.ink), 'accent': hex(theme.accent)},
        'font': ?theme.font,
        if (css != null && css.trim().isNotEmpty) 'css': css.length > CustomCss.mostText ? css.substring(0, CustomCss.mostText) : css,
      });

  /// A name for the file, from the look's: letters, numbers, spaces and dashes, and the ending.
  static String fileName(CustomTheme theme) {
    final plain = theme.name.trim().replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${plain.isEmpty ? 'My look' : plain}.$ending';
  }

  static final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');

  /// The look in [text], a file's, or why it is none, in words to show.
  static ({LookFile? file, String? problem}) read(String text) {
    Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      return (file: null, problem: 'That file isn\'t a look');
    }
    if (j is! Map || j['ghostlook'] is! int) return (file: null, problem: 'That file isn\'t a look');
    if ((j['ghostlook'] as int) > version) return (file: null, problem: 'That look was made by a newer version of the app. Update to take it in.');
    final colours = j['colours'];
    final name = j['name'];
    final dark = j['dark'];
    if (colours is! Map || name is! String || dark is! bool) return (file: null, problem: 'That look is missing its name or colours');
    Color? colour(String part) {
      final v = colours[part];
      return v is String && _hex.hasMatch(v) ? Color(0xFF000000 | int.parse(v.substring(1), radix: 16)) : null;
    }

    final paper = colour('background'), surface = colour('surface'), ink = colour('text'), accent = colour('accent');
    if (paper == null || surface == null || ink == null || accent == null) return (file: null, problem: 'A colour in that look isn\'t written as #RRGGBB');
    final passed = <String>[];
    String? font;
    final f = j['font'];
    if (f is String && f.isNotEmpty) {
      if (CustomTheme.fonts.containsKey(f)) {
        font = f;
      } else {
        passed.add('Its font isn\'t one this version has, so it is drawn in the app\'s own.');
      }
    }
    // Words only in a name shown in the picker, as a code's ([CustomTheme.decode]).
    final words = name.trim();
    if (words.runes.any((r) => r < 0x20 || r == 0x7F)) return (file: null, problem: 'That look\'s name can\'t be shown');
    final theme = CustomTheme(name: words, dark: dark, paper: paper, surface: surface, ink: ink, accent: accent, font: font);
    final problem = theme.problem;
    if (problem != null) return (file: null, problem: problem == 'Give it a name' ? 'That look has no name' : problem);
    final c = j['css'];
    String? css;
    if (c is String && c.trim().isNotEmpty) {
      css = c.length > CustomCss.mostText ? c.substring(0, CustomCss.mostText) : c;
      if (c.length > CustomCss.mostText) passed.add('Only the first ${CustomCss.mostText} characters of its CSS are kept.');
    }
    return (file: LookFile(theme: theme, css: css, passedOver: passed), problem: null);
  }
}
