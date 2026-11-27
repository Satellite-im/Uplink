import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/custom_theme.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/ui/custom_theme_editor.dart';
import 'package:glacier/glacier.dart';

/// GMFB-41 (from the Uplink gap review: "Customization: custom CSS-style themes, dyslexia font, ..."): looks of one's
/// own, shared as codes (lib/custom_theme.dart), and the Readable font (assets/css/app.css, lib/looks.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  const dusk = CustomTheme(name: 'Dusk', dark: true, paper: Color(0xFF101418), surface: Color(0xFF1C222B), ink: Color(0xFFE6EAF0), accent: Color(0xFF7AA2F7));

  group('codes', () {
    test('a look goes out as a short code and comes back the same', () {
      final code = dusk.code;
      expect(code, startsWith('GT1'));
      expect(code.length, lessThan(30), reason: 'short enough to paste in a message');
      expect(CustomTheme.decode(code), dusk);
      final back = CustomTheme.decode(code)!;
      expect((back.name, back.dark, back.paper, back.surface, back.ink, back.accent), (dusk.name, dusk.dark, dusk.paper, dusk.surface, dusk.ink, dusk.accent));
      // A name in any language, and the light half, survive too.
      const light = CustomTheme(name: 'Café ☕ 夜', dark: false, paper: Color(0xFFFFFFFF), surface: Color(0xFFF1F1F1), ink: Color(0xFF111111), accent: Color(0xFFBE185D));
      expect(CustomTheme.decode(light.code), light);
    });

    test('a code is found in a message or a link around it', () {
      expect(CustomTheme.decode('Try my look: ${dusk.code} — it is nice'), dusk);
      expect(CustomTheme.decode('https://gogho.st/look#${dusk.code}'), dusk);
      expect(CustomTheme.decode('  ${dusk.code}\n'), dusk);
    });

    test('anything but a look\'s colours and name is refused', () {
      String code(List<int> bytes) => 'GT1${base64Url.encode(bytes).replaceAll('=', '')}';
      final good = base64Url.decode(base64Url.normalize(dusk.code.substring(3)));
      expect(CustomTheme.decode(code(good)), dusk, reason: 'the bytes as made are a look');
      expect(CustomTheme.decode(''), isNull);
      expect(CustomTheme.decode('hello there'), isNull);
      expect(CustomTheme.decode('GT1'), isNull);
      expect(CustomTheme.decode('GT2${dusk.code.substring(3)}'), isNull, reason: 'a version this build does not know');
      expect(CustomTheme.decode('<script>alert(1)</script>'), isNull);
      expect(CustomTheme.decode('body { background: red }'), isNull, reason: 'no stylesheet is taken in');
      // Cut short: the colours without a name, or not all the colours.
      expect(CustomTheme.decode(code(good.sublist(0, 13))), isNull);
      expect(CustomTheme.decode(code(good.sublist(0, 10))), isNull);
      // A flag that means nothing.
      expect(CustomTheme.decode(code([7, ...good.sublist(1)])), isNull);
      // A name too long, one that is not text, and one with a line break in it.
      expect(CustomTheme.decode(code([...good.sublist(0, 13), ...List.filled(41, 0x61)])), isNull);
      expect(CustomTheme.decode(code([...good.sublist(0, 13), 0xC3, 0x28])), isNull);
      expect(CustomTheme.decode(code([...good.sublist(0, 13), ...utf8.encode('Du\nsk')])), isNull);
      expect(CustomTheme.decode(code([...good.sublist(0, 13), ...utf8.encode('   ')])), isNull);
      // Words that can't be read: ink the same as the page.
      final unreadable = Uint8List.fromList(good)..setRange(7, 10, good.sublist(1, 4));
      expect(CustomTheme.decode(code(unreadable)), isNull);
    });

    test('the editor holds back a look without a name, or whose words can\'t be read', () {
      expect(dusk.problem, isNull);
      expect(dusk.copyWith(name: '  ').problem, 'Give it a name');
      expect(dusk.copyWith(ink: const Color(0xFF151A20)).problem, contains('background'));
      expect(dusk.copyWith(surface: const Color(0xFFD0D4DA)).problem, contains('surface'));
      expect(dusk.onAccent, const Color(0xFF16181D), reason: 'dark words on a light accent');
      expect(dusk.copyWith(accent: const Color(0xFF1D3B8F)).onAccent, const Color(0xFFFFFFFF));
    });
  });

  group('in the app', () {
    test('kept, used, edited and removed; your bubbles wear it and get their colour back after', () {
      final app = AppState()..setBubble('pink');
      expect(CustomTheme.used(app), isNull);
      CustomTheme.save(app, dusk);
      expect(CustomTheme.saved(app), [dusk]);
      expect(CustomTheme.used(app), dusk);
      expect(app.bubble, 'theme', reason: 'your bubbles are the look\'s accent');
      // Edited in place: one look, the new colours.
      final bluer = dusk.copyWith(accent: const Color(0xFF3B82F6));
      CustomTheme.save(app, bluer, replacing: dusk);
      expect(CustomTheme.saved(app), [bluer]);
      expect(CustomTheme.used(app), bluer);
      // One of the app's looks chosen: yours goes, and the colour your bubbles had comes back.
      CustomTheme.chooseLook(app, Look.ghost);
      expect(CustomTheme.used(app), isNull);
      expect(app.bubble, 'pink');
      expect(CustomTheme.saved(app), [bluer], reason: 'still kept, to use again');
      CustomTheme.use(app, bluer);
      CustomTheme.remove(app, bluer);
      expect(CustomTheme.saved(app), isEmpty);
      expect(CustomTheme.used(app), isNull);
      expect(app.bubble, 'pink');
    });

    test('in use, it stamps its own preset and brightness whatever Theme says', () {
      final app = AppState()..setTheme('light');
      CustomTheme.save(app, dusk);
      expect(ghostAttrs(app, 'desktop'), {'platform': 'desktop', 'theme': 'dark', 'theme-preset': 'custom'});
      CustomTheme.chooseLook(app, Look.mist);
      expect(ghostAttrs(app, 'desktop')['theme-preset'], 'mist');
    });

    testWidgets('its four colours are what the page is drawn in, light or dark', (tester) async {
      final accents = (await tester.runAsync(AccentSheets.load))!;
      for (final theme in [dusk, const CustomTheme(name: 'Paper', dark: false, paper: Color(0xFFF4F1EA), surface: Color(0xFFE7E1D3), ink: Color(0xFF2B2118), accent: Color(0xFF0C7F7A))]) {
        final app = AppState();
        CustomTheme.save(app, theme);
        final t = Tokens.root(accents.of(app), attrs: ghostAttrs(app, 'mobile'));
        expect(t.isDark, theme.dark);
        // The engine works in OKLCH: within a level of 255 is the same colour.
        void same(String token, Color want) {
          final got = t.color(token).toARGB32(), w = want.toARGB32();
          for (final shift in [16, 8, 0]) {
            expect((((got >> shift) & 0xFF) - ((w >> shift) & 0xFF)).abs(), lessThanOrEqualTo(1), reason: '${theme.name} $token: ${hex(t.color(token))}, not ${hex(want)}');
          }
        }

        same('app-paper', theme.paper);
        same('app-paper-2', theme.surface);
        same('app-ink', theme.ink);
        same('app-accent', theme.accent);
        same('app-bubble-mine', theme.accent);
        same('app-on-accent', theme.onAccent);
        // The ground itself.
        same('glacier-bg', theme.paper);
      }
    });

    testWidgets('the editor shows the colours as they change, and keeps it', (tester) async {
      final sheet = (await tester.runAsync(AccentSheets.load))!.base;
      // Tall enough for the whole page, the mixer open.
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = AppState();
      await tester.pumpWidget(AppScope(
        state: app,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: GlacierTheme(
            sheet: sheet,
            attrs: const {'platform': 'mobile', 'theme': 'light'},
            child: GlacierToastProvider(
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => CustomThemeEditor(app: app, start: dusk.copyWith(name: '')),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      CustomThemePreview preview() => tester.widget<CustomThemePreview>(find.byKey(const ValueKey('custom-theme-preview')));
      expect(preview().theme.paper, dusk.paper);
      // No name yet: not kept.
      await tester.tap(find.byKey(const ValueKey('custom-theme-save')));
      await tester.pump();
      expect(CustomTheme.saved(app), isEmpty);
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('custom-theme-name')), matching: find.byType(EditableText)), 'Night');
      await tester.pump();
      expect(preview().theme.name, 'Night');
      // The accent's mixer: a colour typed in its hex field is the preview's at once.
      await tester.tap(find.byKey(const ValueKey('custom-theme-accent')));
      await tester.pumpAndSettle();
      final hexField = find.descendant(of: find.byKey(const ValueKey('custom-theme-picker-accent')), matching: find.byType(EditableText));
      expect(hexField, findsOneWidget);
      await tester.enterText(hexField, '#22AA55');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(preview().theme.accent, const Color(0xFF22AA55));
      await tester.ensureVisible(find.byKey(const ValueKey('custom-theme-save')));
      await tester.tap(find.byKey(const ValueKey('custom-theme-save')));
      await tester.pumpAndSettle();
      expect(CustomTheme.saved(app).single.name, 'Night');
      expect(CustomTheme.used(app)!.accent, const Color(0xFF22AA55));
    });
  });

  group('the Readable font', () {
    testWidgets('chosen, everything is drawn in Atkinson Hyperlegible Next, in every look; unchosen, the look\'s own', (tester) async {
      final accents = (await tester.runAsync(AccentSheets.load))!;
      final app = AppState();
      String face() => Tokens.root(accents.of(app), attrs: ghostAttrs(app, 'mobile')).families('glacier-font-sans').first;
      expect(face(), 'Inter Variable');
      app.setFont('readable');
      expect(ghostAttrs(app, 'mobile')['font'], 'readable');
      expect(face(), 'Atkinson Hyperlegible Next Variable');
      // Over a look's own face: Dial-Up's Arimo, Runestone's own letters.
      for (final look in [Look.dialup, Look.runestone, Look.mist]) {
        app.setLook(look);
        expect(face(), 'Atkinson Hyperlegible Next Variable', reason: look.name);
      }
      // And over a look of one's own.
      CustomTheme.save(app, dusk);
      expect(face(), 'Atkinson Hyperlegible Next Variable');
      app.setFont('default');
      CustomTheme.chooseLook(app, Look.dialup);
      expect(face(), 'Arimo', reason: 'the look\'s own again');
    });

    testWidgets('the face is bundled and loads', (tester) async {
      final data = await tester.runAsync(() => rootBundle.load('assets/fonts/AtkinsonHyperlegibleNextVariable-latin.ttf'));
      expect(data!.lengthInBytes, greaterThan(50000));
      // Its licence beside it, as Arimo's is.
      expect(File('assets/fonts/OFL-Atkinson.txt').readAsStringSync(), allOf(contains('SIL OPEN FONT LICENSE Version 1.1'), contains('Atkinson Hyperlegible Next')));
    });
  });
}
