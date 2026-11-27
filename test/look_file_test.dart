import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/custom_css.dart';
import 'package:ghost_messaging/custom_theme.dart';
import 'package:ghost_messaging/look_file.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/ui/custom_theme_editor.dart';
import 'package:glacier/glacier.dart';

/// GMFB-41, box 2 ("Custom themes as a file you can import/share (colours and fonts)"): a look of one's own with a
/// face of the app's own, in its code (GT2) and in a .ghostlook file with the custom CSS beside it (lib/look_file.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  const dusk = CustomTheme(name: 'Dusk', dark: true, paper: Color(0xFF101418), surface: Color(0xFF1C222B), ink: Color(0xFFE6EAF0), accent: Color(0xFF7AA2F7));
  const css = ":root { --glacier-radius-md: 2px; }\n:root[data-theme='dark'] { --app-accent: #ff5c8a; }";

  group('a face in a look', () {
    test('without one the code is GT1 as ever; with one it is GT2, and comes back with its face', () {
      expect(dusk.code, startsWith('GT1'));
      for (final f in CustomTheme.fonts.keys) {
        final faced = dusk.copyWith(font: f);
        expect(faced.code, startsWith('GT2'), reason: f);
        final back = CustomTheme.decode(faced.code)!;
        expect(back.font, f);
        expect(back, faced);
        expect(back == dusk, isFalse, reason: 'a face makes it another look');
        expect((back.name, back.dark, back.paper, back.surface, back.ink, back.accent), (dusk.name, dusk.dark, dusk.paper, dusk.surface, dusk.ink, dusk.accent));
      }
      // The light half with a face: the flag's two parts apart.
      final light = dusk.copyWith(dark: false, paper: const Color(0xFFFFFFFF), surface: const Color(0xFFF1F1F1), ink: const Color(0xFF111111), font: 'mono');
      expect(CustomTheme.decode(light.code), light);
      expect(CustomTheme.decode(light.code)!.dark, isFalse);
      // Taken off again: GT1.
      expect(dusk.copyWith(font: 'readable').copyWith(font: null).code, dusk.code);
    });

    test('a GT2 with no face, or one not known, is no look; a face not known is held back in the editor', () {
      String code(String mark, List<int> bytes) => '$mark${base64Url.encode(bytes).replaceAll('=', '')}';
      final good = base64Url.decode(base64Url.normalize(dusk.code.substring(3)));
      expect(CustomTheme.decode(code('GT2', [1 | 2 << 1, ...good.sublist(1)]))!.font, 'readable');
      expect(CustomTheme.decode(code('GT2', good)), isNull, reason: 'GT2 says a face');
      expect(CustomTheme.decode(code('GT2', [1 | 4 << 1, ...good.sublist(1)])), isNull, reason: 'a face this build has not got');
      expect(CustomTheme.decode(code('GT1', [1 | 2 << 1, ...good.sublist(1)])), isNull, reason: 'a GT1 has no face');
      expect(dusk.copyWith(font: 'comic').problem, isNotNull);
    });

    testWidgets('in use, the page draws in it; the Readable font chosen in Appearance still goes over it', (tester) async {
      final accents = (await tester.runAsync(AccentSheets.load))!;
      final app = AppState();
      String face() => Tokens.root(accents.of(app), attrs: ghostAttrs(app, 'desktop')).families('glacier-font-sans').first;
      CustomTheme.save(app, dusk.copyWith(font: 'mono'));
      expect(ghostAttrs(app, 'desktop')['font'], 'mono');
      expect(face(), 'JetBrains Mono Variable');
      CustomTheme.save(app, dusk.copyWith(font: 'arimo'));
      expect(face(), 'Arimo');
      app.setFont('readable');
      expect(face(), 'Atkinson Hyperlegible Next Variable');
      app.setFont('default');
      CustomTheme.save(app, dusk);
      expect(ghostAttrs(app, 'desktop').containsKey('font'), isFalse);
      expect(face(), 'Inter Variable');
    });
  });

  group('the .ghostlook file', () {
    test('colours, font and CSS go out and come back the same', () {
      final theme = dusk.copyWith(font: 'readable');
      final text = LookFile.write(theme, css: css);
      final j = jsonDecode(text) as Map;
      expect(j['ghostlook'], 1);
      expect(j['colours'], {'background': '#101418', 'surface': '#1C222B', 'text': '#E6EAF0', 'accent': '#7AA2F7'});
      expect(j['font'], 'readable');
      final back = LookFile.read(text);
      expect(back.problem, isNull);
      expect(back.file!.theme, theme);
      expect(back.file!.theme.font, 'readable');
      expect(back.file!.css, css);
      expect(back.file!.passedOver, isEmpty);
      // No face and no CSS: neither is written, and neither comes back.
      final plain = LookFile.write(dusk, css: '  ');
      expect(jsonDecode(plain), isNot(contains('font')));
      expect(jsonDecode(plain), isNot(contains('css')));
      expect(LookFile.read(plain).file!.theme, dusk);
      expect(LookFile.read(plain).file!.css, isNull);
    });

    test('a file named from the look, in plain letters', () {
      expect(LookFile.fileName(dusk), 'Dusk.ghostlook');
      expect(LookFile.fileName(dusk.copyWith(name: 'Café / ☕ night')), 'Caf night.ghostlook');
      expect(LookFile.fileName(dusk.copyWith(name: '☕')), 'My look.ghostlook');
    });

    test('what is not a look is refused, with why', () {
      Map<String, Object?> j() => jsonDecode(LookFile.write(dusk)) as Map<String, Object?>;
      String w(Map<String, Object?> m) => jsonEncode(m);
      expect(LookFile.read('').file, isNull);
      expect(LookFile.read('not json').problem, 'That file isn\'t a look');
      expect(LookFile.read('{"name": "Dusk"}').problem, 'That file isn\'t a look');
      expect(LookFile.read(w(j()..['ghostlook'] = 2)).problem, contains('newer version'));
      expect(LookFile.read(w(j()..remove('colours'))).file, isNull);
      expect(LookFile.read(w(j()..['colours'] = {...(j()['colours'] as Map), 'accent': 'red'})).problem, contains('#RRGGBB'));
      expect(LookFile.read(w(j()..['colours'] = {...(j()['colours'] as Map), 'accent': '#7AA2F7; } body {'})).file, isNull);
      expect(LookFile.read(w(j()..['name'] = '  ')).problem, 'That look has no name');
      expect(LookFile.read(w(j()..['name'] = 'Du\nsk')).file, isNull);
      expect(LookFile.read(w(j()..['name'] = 'a' * 41)).file, isNull);
      // Words that can't be read on the page.
      expect(LookFile.read(w(j()..['colours'] = {...(j()['colours'] as Map), 'text': '#101418'})).problem, contains('background'));
      // CSS that is not text is not taken; the look is.
      expect(LookFile.read(w(j()..['css'] = 42)).file!.css, isNull);
    });

    test('a face a newer build has is passed over and said; CSS past the most kept is cut and said', () {
      final newer = LookFile.read(jsonEncode((jsonDecode(LookFile.write(dusk)) as Map)..['font'] = 'serif'));
      expect(newer.file!.theme.font, isNull);
      expect(newer.file!.passedOver.single, contains('font'));
      final long = LookFile.read(jsonEncode((jsonDecode(LookFile.write(dusk)) as Map)..['css'] = 'a' * (CustomCss.mostText + 10)));
      expect(long.file!.css!.length, CustomCss.mostText);
      expect(long.file!.passedOver.single, contains('${CustomCss.mostText}'));
    });

    testWidgets('taken in with its CSS: the editor shows it, and keeping it uses the look, the face and the CSS', (tester) async {
      final sheet = (await tester.runAsync(AccentSheets.load))!.base;
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      CustomCss.save(app, ':root { --glacier-radius-md: 9px; }', on: false);
      final text = LookFile.write(dusk.copyWith(font: 'mono'), css: css);
      await tester.pumpWidget(AppScope(
        state: app,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: GlacierTheme(
            sheet: sheet,
            attrs: const {'platform': 'desktop', 'theme': 'light'},
            child: GlacierToastProvider(
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (context, _, _) => GestureDetector(key: const ValueKey('take'), behavior: HitTestBehavior.opaque, onTap: () => takeLookFile(context, app, text), child: const SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('take')));
      await tester.pumpAndSettle();
      // Asked first: it would take the place of the CSS already written.
      expect(find.text('Dusk comes with custom CSS'), findsOneWidget);
      expect(find.text('It takes the place of your own custom CSS.'), findsOneWidget);
      await tester.tap(find.text('Use its CSS too'));
      await tester.pumpAndSettle();
      final preview = tester.widget<CustomThemePreview>(find.byKey(const ValueKey('custom-theme-preview')));
      expect(preview.theme.font, 'mono');
      expect(preview.theme.paper, dusk.paper);
      // The font row shows its face chosen.
      expect(tester.widget<GlacierSegmentedControl>(find.descendant(of: find.byKey(const ValueKey('custom-theme-font')), matching: find.byType(GlacierSegmentedControl))).value, 'mono');
      await tester.ensureVisible(find.byKey(const ValueKey('custom-theme-save')));
      await tester.tap(find.byKey(const ValueKey('custom-theme-save')));
      await tester.pumpAndSettle();
      expect(CustomTheme.used(app), dusk.copyWith(font: 'mono'));
      expect(CustomCss.text(app), css);
      expect(CustomCss.on(app), isTrue);
    });

    testWidgets('taken in without its CSS: the person\'s own stays', (tester) async {
      final sheet = (await tester.runAsync(AccentSheets.load))!.base;
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      const mine = ':root { --glacier-radius-md: 9px; }';
      CustomCss.save(app, mine, on: true);
      await tester.pumpWidget(AppScope(
        state: app,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: GlacierTheme(
            sheet: sheet,
            attrs: const {'platform': 'desktop', 'theme': 'light'},
            child: GlacierToastProvider(
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (context, _, _) => GestureDetector(key: const ValueKey('take'), behavior: HitTestBehavior.opaque, onTap: () => takeLookFile(context, app, LookFile.write(dusk, css: css)), child: const SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('take')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only its colours and font'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('custom-theme-save')));
      await tester.tap(find.byKey(const ValueKey('custom-theme-save')));
      await tester.pumpAndSettle();
      expect(CustomTheme.used(app), dusk);
      expect(CustomCss.text(app), mine);
    });
  });
}
