import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:glacier/glacier.dart';

/// The bubble colour chosen everywhere is the app's accent (Matt, 2026-11-14: "make the bubble color the accent color
/// for the app so the send button, segmented toggles, etc all get the same color as the bubbles if set globally and
/// only settings inside a chat soley change the bubble color").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a colour is the accent on both themes, with words that read on it; ink is the page\'s own', () {
    final blue = accentPair('blue');
    expect(blue.light!.$1, const Color(0xFF0A84FF));
    expect(blue.dark!.$1, const Color(0xFF0A84FF));
    expect(blue.light!.$2, const Color(0xFFFFFFFF));
    expect(accentPair('yellow').light!.$2, const Color(0xFF16181D), reason: 'dark words on yellow');
    final ink = accentPair('ink');
    expect(ink.light, isNull);
    expect(ink.dark, isNull);
    expect(accentCss('ink'), isNull);
  });

  test('a colour that would not be seen on a page leaves that page\'s accent the ink', () {
    final white = accentPair('white');
    expect(white.light, isNull, reason: 'a white Send on white paper is no button');
    expect(white.dark, isNotNull);
    expect(accentPair('silver').light, isNull);
    expect(accentPair('graphite').dark, isNotNull);
  });

  testWidgets('the sheet for a bubble colour gives the app\'s accent and the kit\'s toggles and switches that colour', (tester) async {
    final accents = await tester.runAsync(AccentSheets.load);
    // As the app does as it starts (lib/main.dart).
    installSettingsStyles(accents!.base);
    final app = AppState()..setBubble('blue');
    Tokens? light, dark, plain;
    Widget themed(TokenSheet sheet, String theme, void Function(Tokens) got) => GlacierTheme(
          sheet: sheet,
          attrs: {'platform': 'mobile', 'theme': theme},
          child: Builder(builder: (context) {
            got(context.tokens);
            return const SizedBox.shrink();
          }),
        );
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        themed(accents.of(app), 'light', (t) => light = t),
        themed(accents.of(app), 'dark', (t) => dark = t),
        themed(accents.base, 'light', (t) => plain = t),
      ]),
    ));
    int argb(Tokens t, String name) => t.color(name).toARGB32();
    for (final t in [light!, dark!]) {
      expect(argb(t, 'app-accent'), 0xFF0A84FF);
      expect(argb(t, 'app-on-accent'), 0xFFFFFFFF);
      expect(argb(t, 'glacier-segment-thumb'), 0xFF0A84FF, reason: 'a toggle\'s chosen tab');
      expect(argb(t, 'glacier-accent-solid'), 0xFF0A84FF, reason: 'a switch that is on');
    }
    expect(argb(plain!, 'app-accent'), argb(plain!, 'app-ink'), reason: 'with no accent laid over, the page\'s ink');
    // Settings' sections keep their colours on a sheet with an accent laid over, as on the plain one.
    Tokens? hued, hueBase;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        GlacierTheme(sheet: accents.of(app), attrs: const {'platform': 'mobile', 'theme': 'light'}, child: GlacierScope(attrs: const {'hue': 'coral'}, child: Builder(builder: (c) { hued = c.tokens; return const SizedBox.shrink(); }))),
        GlacierTheme(sheet: accents.base, attrs: const {'platform': 'mobile', 'theme': 'light'}, child: GlacierScope(attrs: const {'hue': 'coral'}, child: Builder(builder: (c) { hueBase = c.tokens; return const SizedBox.shrink(); }))),
      ]),
    ));
    expect(settingsHue(hued!).toARGB32(), settingsHue(hueBase!).toARGB32(), reason: 'a section\'s colour is the same with the accent laid over');
    expect(settingsHue(hued!).toARGB32(), isNot(hued!.color('app-ink').toARGB32()), reason: 'and is a colour, not the ink');
    // The same colour twice is parsed once.
    expect(identical(accents.of(app), accents.of(AppState()..setBubble('blue'))), isTrue);
  });
}
