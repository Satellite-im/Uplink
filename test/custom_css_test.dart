import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/custom_css.dart';
import 'package:ghost_messaging/custom_theme.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/ui/custom_css_editor.dart';
import 'package:glacier/glacier.dart';

/// CSS of one's own over the look (GMFB-41; Matt, 2026-11-25: "it doesn't seem like the custom css i there", "where
/// can I find the css custom styles if I search css or styles i don't see anything in settings").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AccentSheets> sheets(WidgetTester tester) async {
    final accents = (await tester.runAsync(AccentSheets.load))!;
    // As the app does as it starts (lib/main.dart).
    installSettingsStyles(accents.base);
    return accents;
  }

  // The engine works in OKLCH: within a level of 255 is the same colour.
  void same(Color got, Color want) {
    for (final shift in [16, 8, 0]) {
      expect((((got.toARGB32() >> shift) & 0xFF) - ((want.toARGB32() >> shift) & 0xFF)).abs(), lessThanOrEqualTo(1), reason: '$got, not $want');
    }
  }

  Tokens page(AccentSheets accents, AppState app, String theme) => Tokens.root(accents.of(app), attrs: {...ghostAttrs(app, 'mobile'), 'theme': theme});

  testWidgets('a variable set on :root is what the app is drawn with, over the look and the bubble colour', (tester) async {
    final accents = await sheets(tester);
    final app = AppState()..setBubble('blue');
    same(page(accents, app, 'light').color('app-accent'), const Color(0xFF0A84FF));
    CustomCss.save(app, ":root { --app-accent: #ff5c8a; --glacier-radius-md: 3px; }\n:root[data-theme='dark'] { --app-accent: #22aa55; }", on: true);
    same(page(accents, app, 'light').color('app-accent'), const Color(0xFFFF5C8A));
    same(page(accents, app, 'dark').color('app-accent'), const Color(0xFF22AA55));
    expect(page(accents, app, 'light').len('glacier-radius-md'), 3);
    expect(CustomCss.last!.kept, 3);
    expect(CustomCss.last!.problems, isEmpty);
    // Over a look of one's own too.
    CustomTheme.save(app, const CustomTheme(name: 'Dusk', dark: true, paper: Color(0xFF14121C), surface: Color(0xFF221F2E), ink: Color(0xFFEDE9F7), accent: Color(0xFF8B7CF6)));
    same(page(accents, app, 'dark').color('app-accent'), const Color(0xFF22AA55));
    // Switched off, the app is as it was; the words are kept.
    CustomCss.save(app, CustomCss.text(app), on: false);
    same(page(accents, app, 'dark').color('app-accent'), const Color(0xFF8B7CF6));
    expect(CustomCss.text(app), contains('#ff5c8a'));
    expect(CustomCss.last, isNull);
  });

  testWidgets('a value the app could not read is left out and named, and the rest is used', (tester) async {
    final accents = await sheets(tester);
    final app = AppState();
    CustomCss.save(app, ':root { --app-accent: banana; --glacier-radius-md: red; --app-online: #00ff00; --app-paper: var(--app-paper); }', on: true);
    final t = page(accents, app, 'light');
    final plain = Tokens.root(accents.base, attrs: {...ghostAttrs(app, 'mobile'), 'theme': 'light'});
    // Every value the stylesheets name is still read, on both pages.
    for (final theme in ['light', 'dark']) {
      final now = page(accents, app, theme);
      expect(() => now.color('app-accent'), returnsNormally);
      expect(() => now.color('app-paper'), returnsNormally);
      expect(() => now.len('glacier-radius-md'), returnsNormally);
    }
    same(t.color('app-accent'), plain.color('app-accent'));
    expect(t.len('glacier-radius-md'), plain.len('glacier-radius-md'));
    same(t.color('app-online'), const Color(0xFF00FF00));
    final result = CustomCss.last!;
    expect(result.kept, 1);
    expect(result.problems.where((p) => p.startsWith('--app-accent: banana')), hasLength(1));
    expect(result.problems.where((p) => p.startsWith('--glacier-radius-md: red')), hasLength(1));
    expect(result.problems.where((p) => p.startsWith('--app-paper: var(--app-paper)')), hasLength(1));
  });

  testWidgets('words that could not be read on the page are left out, so the switch can always be seen', (tester) async {
    final accents = await sheets(tester);
    final app = AppState();
    CustomCss.save(app, ':root { --app-ink: #ffffff; --app-paper: #ffffff; }', on: true);
    for (final theme in ['light', 'dark']) {
      final t = page(accents, app, theme);
      expect(contrast(t.color('app-ink'), t.color('app-paper')), greaterThanOrEqualTo(3), reason: theme);
    }
    expect(CustomCss.last!.problems.join('\n'), contains('the words can\'t be read'));
  });

  testWidgets('what the app has nothing to read with is said, not applied', (tester) async {
    final accents = await sheets(tester);
    final app = AppState();
    CustomCss.save(app, 'button { --app-accent: #ff0000; }\n:root { color: red; --app-accent: #00aa00 !important; }\n@media (min-width: 400px) { :root { --app-accent: #0000ff; } }\n/* a note */ stray', on: true);
    same(page(accents, app, 'light').color('app-accent'), const Color(0xFF00AA00));
    final said = CustomCss.last!.problems.join('\n');
    expect(said, contains('"button" is passed over'));
    expect(said, contains('"color: red" does nothing here'));
    expect(said, contains('@ rules are not read'));
    expect(said, contains('"stray" is not a rule'));
    expect(CustomCss.last!.kept, 1);
  });

  testWidgets('the page: written, used, what was left out listed, and switched off', (tester) async {
    final accents = await sheets(tester);
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pumpWidget(AppScope(
      state: app,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => GlacierTheme(
            sheet: accents.of(app),
            attrs: {...ghostAttrs(app, 'mobile'), 'theme': 'light'},
            child: GlacierToastProvider(
              child: Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => CustomCssEditor(app: app))),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    Color accent() => tester.element(find.byKey(const ValueKey('custom-css-text'))).tokens.color('app-accent');
    final before = accent();
    // The example fills an empty box.
    await tester.tap(find.byKey(const ValueKey('custom-css-example')));
    await tester.pump();
    expect(tester.widget<EditableText>(find.byKey(const ValueKey('custom-css-text'))).controller.text, customCssExample);
    await tester.enterText(find.byKey(const ValueKey('custom-css-text')), ':root { --app-accent: #ff5c8a; --app-danger: nope; }');
    await tester.pump();
    same(accent(), before);
    await tester.tap(find.byKey(const ValueKey('custom-css-apply')));
    await tester.pumpAndSettle();
    expect(CustomCss.on(app), isTrue);
    same(accent(), const Color(0xFFFF5C8A));
    expect(find.text('1 value is in use.'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-css-problem-0')), findsOneWidget);
    expect(find.textContaining('--app-danger: nope is left out'), findsOneWidget);
    // Off with the switch: the app's own accent again.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('custom-css-on')), matching: find.byType(GlacierSwitch)));
    await tester.pumpAndSettle();
    expect(CustomCss.on(app), isFalse);
    same(accent(), before);
  });

  test('every variable the stylesheets name is listed for the page to copy', () async {
    await AccentSheets.load();
    expect(CustomCss.known, containsAll(['--app-accent', '--app-paper', '--glacier-radius-md']));
  });
}
