import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'app_state.dart';
import 'looks.dart';

/// A look of the person's own (GMFB-41, from the Uplink gap review: "Customization: custom CSS-style themes"): four
/// colours, a name and whether it is dark, made in Settings › Appearance › Make your own look
/// (lib/ui/custom_theme_editor.dart). Not a stylesheet anyone writes: the four colours are made into the same block of
/// rules the app's own looks are (assets/css/app.css), so what it can change is only what a look can.
///
/// It is shared as a short code ([code]): `GT1` and the colours, the flag and the name as base64url bytes, or `GT2`
/// where it has a face of its own ([font]), said in the flag's other bits. A code pasted in is taken only as those
/// bytes ([CustomTheme.decode]): colours, a face among the app's own and a name, nothing that runs, and nothing
/// unreadable (words that can't be read against the page are refused). It is also kept in a file, with any custom CSS
/// (lib/look_file.dart).
class CustomTheme {
  const CustomTheme({required this.name, required this.dark, required this.paper, required this.surface, required this.ink, required this.accent, this.font});

  /// What it is called in the picker: at most [nameMost] bytes of UTF-8.
  final String name;

  /// Whether it is drawn in the dark theme's way (the system's light or dark setting is then not asked).
  final bool dark;

  /// The page; the cards, fields and someone else's bubbles on it; the words; and the accent, which your own bubbles,
  /// Send and what is chosen wear.
  final Color paper, surface, ink, accent;

  /// The face it draws in (GMFB-41, "Custom themes as a file you can import/share (colours and fonts)"): one of
  /// [fonts], all bundled with the app, so a look never asks for a download; null for the app's own (Inter). Stamped
  /// as `data-font` (assets/css/app.css), which the Readable font chosen in Appearance still draws over.
  final String? font;

  /// The faces a look can have, by id, with what Appearance calls each, in the order of their number in a code (one
  /// after the app's own, which is 0). An id is never taken out or moved: a code made with it would mean another face.
  static const fonts = {'arimo': 'Classic', 'readable': 'Readable', 'mono': 'Mono'};

  /// Each face's family in pubspec.yaml, for drawing a look small before it is used.
  static const fontFamilies = {'arimo': 'Arimo', 'readable': 'Atkinson Hyperlegible Next Variable', 'mono': 'JetBrains Mono Variable'};

  static const nameMost = 40;

  /// The ink's contrast with the page must be at least this to be saved or taken in: AA's for large text.
  static const leastContrast = 3.0;

  /// The code's mark and version: GT1 for a look in the app's own face, as every code was before looks had faces (so
  /// those codes, and a build from before, are as they were), GT2 for one with a face of its own.
  static const _mark = 'GT1', _markFont = 'GT2';

  /// Where codes are kept ('custom_themes', a JSON list) and which is in use ('custom_theme', its code, or empty).
  static const savedPref = 'custom_themes', usedPref = 'custom_theme';

  /// The page attribute that names it to the stylesheet, as a look's name does.
  static const preset = 'custom';

  /// [font]: a face's id, or null for the app's own; left out, the face it has.
  CustomTheme copyWith({String? name, bool? dark, Color? paper, Color? surface, Color? ink, Color? accent, Object? font = _same}) => CustomTheme(
        name: name ?? this.name,
        dark: dark ?? this.dark,
        paper: paper ?? this.paper,
        surface: surface ?? this.surface,
        ink: ink ?? this.ink,
        accent: accent ?? this.accent,
        font: identical(font, _same) ? this.font : font as String?,
      );

  static const _same = Object();

  /// [font]'s number in a code: 0 for the app's own face, or one not known.
  int get _fontNumber => font == null ? 0 : CustomTheme.fonts.keys.toList().indexOf(font!) + 1;

  /// The words drawn on the accent: near black or white, whichever is read better.
  Color get onAccent => contrast(accent, const Color(0xFFFFFFFF)) >= contrast(accent, const Color(0xFF16181D)) ? const Color(0xFFFFFFFF) : const Color(0xFF16181D);

  /// Why it can't be used, in a few words, or null where it can: a name, and words that can be read on the page.
  String? get problem {
    if (name.trim().isEmpty) return 'Give it a name';
    if (font != null && !fonts.containsKey(font)) return 'That font isn\'t one of the app\'s';
    if (utf8.encode(name.trim()).length > nameMost) return 'The name is too long';
    if (contrast(ink, paper) < leastContrast) return 'The words can\'t be read on the background';
    if (contrast(ink, surface) < leastContrast) return 'The words can\'t be read on the surface';
    return null;
  }

  // --- the code -----------------------------------------------------------------------------------------------------

  /// The short code it is shared as.
  String get code {
    final words = utf8.encode(name.trim());
    final face = _fontNumber;
    final bytes = BytesBuilder()
      ..addByte((dark ? 1 : 0) | face << 1)
      ..add(_rgb(paper))
      ..add(_rgb(surface))
      ..add(_rgb(ink))
      ..add(_rgb(accent))
      ..add(words.length > nameMost ? words.sublist(0, nameMost) : words);
    return '${face == 0 ? _mark : _markFont}${base64Url.encode(bytes.toBytes()).replaceAll('=', '')}';
  }

  /// [c]'s red, green and blue, a byte each; how see-through it is is left out.
  static List<int> _rgb(Color c) {
    final v = c.toARGB32();
    return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  }

  static final _codeIn = RegExp('GT[12][A-Za-z0-9_-]{18,80}');

  /// The look in [text]: a code alone, or a message or link with one in it. Null where there is none, or what is
  /// there is not a look: the wrong length, a flag that means nothing, a name that is not text, or words that can't
  /// be read. A GT2 says a face of the app's own in the flag's bits above the first; one not known is no look.
  static CustomTheme? decode(String text) {
    final found = _codeIn.firstMatch(text.trim());
    if (found == null) return null;
    final faced = found.group(0)!.startsWith(_markFont);
    final body = found.group(0)!.substring(_mark.length);
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(body));
    } catch (_) {
      return null;
    }
    if (bytes.length < 14 || bytes.length > 13 + nameMost) return null;
    final face = bytes[0] >> 1;
    if (faced ? face < 1 || face > fonts.length : bytes[0] > 1) return null;
    Color at(int i) => Color(0xFF000000 | bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2]);
    final String name;
    try {
      name = utf8.decode(bytes.sublist(13), allowMalformed: false);
    } catch (_) {
      return null;
    }
    // Words only: no line breaks or other control characters in a name shown in the picker.
    if (name.trim().isEmpty || name.runes.any((r) => r < 0x20 || r == 0x7F)) return null;
    final theme = CustomTheme(name: name.trim(), dark: bytes[0] & 1 == 1, paper: at(1), surface: at(4), ink: at(7), accent: at(10), font: faced ? fonts.keys.elementAt(face - 1) : null);
    return theme.problem == null ? theme : null;
  }

  @override
  bool operator ==(Object other) => other is CustomTheme && other.code == code;

  @override
  int get hashCode => code.hashCode;

  // --- the rules ----------------------------------------------------------------------------------------------------

  /// The page's `data-` attributes while it is the look in use: its brightness always, as a look with one half has,
  /// and its face where it has one of its own.
  Map<String, String> attrs({required String platform}) => {'platform': platform, 'theme': dark ? 'dark' : 'light', 'theme-preset': preset, 'font': ?font};

  /// Its block of rules, written as the app's looks are written (assets/css/app.css explains the two specificities):
  /// twelve greys from the page through the surface to the ink, and the rest at specificity 5 so it is above ink.css
  /// and below a bubble colour chosen in Appearance.
  String get css {
    // Where each grey stands between the surface (0) and the ink (1), after the page (1) and halfway (2).
    const steps = [0.08, 0.15, 0.24, 0.34, 0.46, 0.62, 0.72, 0.84];
    final greys = [paper, mix(paper, surface, 0.5), surface, for (final s in steps) mix(surface, ink, s), ink];
    final b = StringBuffer(":root[data-theme-preset='$preset'] {\n");
    for (var i = 0; i < greys.length; i++) {
      b.writeln('  --glacier-gray-${i + 1}: ${hex(greys[i])};');
    }
    b.writeln('}');
    String a(Color c, double alpha) => 'rgba(${(c.toARGB32() >> 16) & 0xFF}, ${(c.toARGB32() >> 8) & 0xFF}, ${c.toARGB32() & 0xFF}, $alpha)';
    final scrim = dark ? 'rgba(0, 0, 0, 0.62)' : a(ink, 0.40);
    b
      ..writeln(":root:root:root:root[data-theme-preset='$preset'] {")
      ..writeln('  --glacier-glass-thin: ${a(paper, 0.48)};')
      ..writeln('  --glacier-glass-regular: ${a(paper, 0.68)};')
      ..writeln('  --glacier-glass-thick: ${a(paper, 0.86)};')
      ..writeln('  --glacier-glass-border: ${a(ink, 0.12)};')
      ..writeln('  --glacier-glass-highlight: ${dark ? 'rgba(255, 255, 255, 0.10)' : 'rgba(255, 255, 255, 0.82)'};')
      ..writeln('  --glacier-surface-raised: ${hex(dark ? surface : paper)};')
      ..writeln('  --glacier-overlay: $scrim;')
      ..writeln('  --glacier-segment-track: ${a(surface, 0.72)};')
      ..writeln('  --glacier-slider-thumb: ${hex(dark ? ink : paper)};')
      ..writeln('  --app-ink-level: ${inkLevel.toStringAsFixed(3)};')
      ..writeln('  --app-raised: var(--app-gray-${dark ? 3 : 1});')
      ..writeln('  --app-scrim: $scrim;')
      ..writeln('  --app-mark: ${a(accent, 0.34)};')
      ..writeln('  --app-accent: ${hex(accent)};')
      ..writeln('  --app-on-accent: ${hex(onAccent)};')
      ..writeln('  --app-bubble-mine: ${hex(accent)};')
      ..writeln('  --app-on-bubble-mine: ${hex(onAccent)};')
      ..writeln('  --glacier-selection: ${a(accent, 0.24)};')
      ..writeln('  --glacier-focus-ring: ${hex(accent)};')
      ..writeln('  --app-unread: ${hex(accent)};')
      ..writeln('  --app-chosen: ${hex(accent)};')
      ..writeln('  --app-info: ${hex(accent)};')
      ..writeln('}');
    return b.toString();
  }

  /// The ink as a grey in sRGB, 0 to 1 (ink.css's `--app-ink-level`): the grey of the same luminance.
  double get inkLevel {
    final y = ink.computeLuminance();
    return y <= 0.0031308 ? y * 12.92 : 1.055 * math.pow(y, 1 / 2.4) - 0.055;
  }

  // --- in the app's choices -----------------------------------------------------------------------------------------

  /// The looks [app] has kept, in the order they were made.
  static List<CustomTheme> saved(AppState app) {
    try {
      final list = jsonDecode(app.choice(savedPref, '[]'));
      if (list is! List) return const [];
      return [for (final c in list) if (c is String) ?decode(c)];
    } catch (_) {
      return const [];
    }
  }

  /// The look of [app]'s own in use, or null where it is one of the app's looks.
  static CustomTheme? used(AppState app) {
    final c = app.choice(usedPref, '');
    return c.isEmpty ? null : decode(c);
  }

  /// Keeps [theme] among [app]'s looks, in place of [replacing] where given (one being edited), and uses it.
  static void save(AppState app, CustomTheme theme, {CustomTheme? replacing}) {
    final list = [...saved(app)];
    final at = replacing == null ? -1 : list.indexOf(replacing);
    if (at >= 0) {
      list[at] = theme;
    } else if (!list.contains(theme)) {
      list.add(theme);
    }
    app.set(savedPref, jsonEncode([for (final t in list) t.code]));
    use(app, theme);
  }

  /// Takes [theme] out of [app]'s looks; in use, the app's own look comes back.
  static void remove(AppState app, CustomTheme theme) {
    if (used(app) == theme) use(app, null);
    app.set(savedPref, jsonEncode([for (final t in saved(app)) if (t != theme) t.code]));
  }

  /// Makes [theme] the look in use (null: back to the app's look chosen under it). Your bubbles wear its accent
  /// ('theme', as under any look), and the colour they had comes back after, as Look's own choosing does.
  static void use(AppState app, CustomTheme? theme) {
    final was = used(app);
    if (theme == null) {
      if (was == null) return;
      app.set(usedPref, '');
      if (app.look == Look.ghost && app.bubble == 'theme') app.setBubble(app.choice('bubble_before_look', 'white'));
      return;
    }
    if (was == null && app.look == Look.ghost && app.bubble != 'theme') app.set('bubble_before_look', app.bubble);
    app.set(usedPref, theme.code);
    if (app.bubble != 'theme') app.setBubble('theme');
  }

  /// One of the app's looks chosen: any look of one's own goes first.
  static void chooseLook(AppState app, Look look) {
    use(app, null);
    app.setLook(look);
  }
}

/// [a] to [b] by [t], each channel in sRGB.
Color mix(Color a, Color b, double t) {
  final x = a.toARGB32(), y = b.toARGB32();
  int ch(int shift) => ((((x >> shift) & 0xFF) * (1 - t)) + (((y >> shift) & 0xFF) * t)).round().clamp(0, 255);
  return Color(0xFF000000 | ch(16) << 16 | ch(8) << 8 | ch(0));
}

/// [c] as it is written: `#RRGGBB`, in capitals.
String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// WCAG's contrast between two colours, 1 to 21.
double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
}
