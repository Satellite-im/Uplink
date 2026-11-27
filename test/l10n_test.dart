import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/l10n/words.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsScreen, SettingsSectionScreen;

import '../tool/l10n.dart' as l10n;
import 'support/list_harness.dart';
import 'support/space_call_harness.dart' show SpaceHarness;

/// The app in more than one language (GMFB-32: "Flutter localization (ARB files) with English as the source; a first
/// extra language to prove it works"): lib/l10n/words.dart, tool/l10n.dart and assets/l10n.

/// An asset bundle that reads the repository's own files.
class _Files extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(await File(key).readAsBytes());
}

Map<String, String> _arb(String lang) => l10n.readArb(File('assets/l10n/app_$lang.arb'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
  tearDown(() => Words.instance.setForTest('en', const {}));

  test('app_en.arb is the English the code draws now: run `dart run tool/l10n.dart` after changing words', () {
    final now = l10n.extract(Directory.current.path);
    final kept = _arb('en');
    final added = now.keys.where((k) => !kept.containsKey(k)).map((k) => now[k]).take(5).toList();
    final gone = kept.keys.where((k) => !now.containsKey(k)).map((k) => kept[k]).take(5).toList();
    expect([added, gone], [isEmpty, isEmpty], reason: 'new in the code: $added; no longer in it: $gone');
    expect(File('assets/l10n/app_en.arb').readAsStringSync(), l10n.arb('en', now), reason: 'written as the tool writes it');
  });

  test('each piece of English has a key of its own, made from it alone', () {
    final en = _arb('en');
    expect(en.values.toSet().length, en.length, reason: 'two pieces of English with one key');
    for (final e in en.entries.take(50)) {
      expect(l10n.keyOf(e.value), e.key);
    }
    expect(l10n.keyOf('Settings'), isNot(l10n.keyOf('Settings ')));
  });

  for (final lang in Words.languages.keys.where((l) => l != 'en')) {
    test('$lang: every translation is of English the app has, keeps its {places}, and is not blank; most of the app is translated', () {
      final en = _arb('en'), there = _arb(lang);
      final strange = there.keys.where((k) => !en.containsKey(k)).toList();
      expect(strange, isEmpty, reason: 'translations of English no longer in the app: run tool/l10n.dart and drop them');
      final places = RegExp(r'\{[a-zA-Z]+\}');
      for (final e in there.entries) {
        final english = en[e.key]!;
        expect(e.value.trim(), isNotEmpty, reason: english);
        expect(places.allMatches(e.value).map((m) => m[0]).toSet(), places.allMatches(english).map((m) => m[0]).toSet(), reason: '"$english" → "${e.value}"');
      }
      expect(there.length / en.length, greaterThan(0.95), reason: '${there.length} of ${en.length}');
    });
  }

  test('a language written right to left draws the app right to left, and words someone wrote keep their own direction', () {
    for (final l in ['ar', 'fa', 'he', 'ur']) {
      Words.instance.setForTest(l, const {});
      expect(Words.instance.direction, TextDirection.rtl, reason: l);
    }
    expect(ownDirection('are you coming tonight?'), TextDirection.ltr);
    expect(ownDirection('مرحبا! hello'), TextDirection.rtl);
    expect(ownDirection('123 ...'), isNull, reason: 'no letter: the line\'s own way');
    expect(ownWords('thanks!'), '\u2068thanks!\u2069');
    for (final l in ['en', 'es', 'ja']) {
      Words.instance.setForTest(l, const {});
      expect(Words.instance.direction, TextDirection.ltr, reason: l);
    }
    expect(ownDirection('are you coming tonight?'), isNull, reason: 'left to right: drawn as ever');
    expect(ownWords('thanks!'), 'thanks!');
  });

  testWidgets('an icon that points a way points the other way right to left; one that doesn\'t is left as it is', (tester) async {
    Future<bool> flipped(LucideIcon icon, TextDirection d) async {
      await tester.pumpWidget(Directionality(textDirection: d, child: Center(child: AppIcon(icon))));
      return find.byType(Transform).evaluate().isNotEmpty;
    }

    expect(await flipped(Lucide.chevronLeft, TextDirection.rtl), isTrue);
    expect(await flipped(Lucide.chevronLeft, TextDirection.ltr), isFalse);
    expect(await flipped(Lucide.search, TextDirection.rtl), isFalse);
  });

  test('the language meant: the one chosen, else the device\'s where the app has it, else English', () {
    expect(Words.meant('es'), 'es');
    expect(Words.meant('en', device: 'es'), 'en');
    expect(Words.meant(Words.automatic, device: 'es'), 'es');
    expect(Words.meant(Words.automatic, device: 'ES'), 'es');
    expect(Words.meant(Words.automatic, device: 'fr'), 'fr');
    expect(Words.meant(Words.automatic, device: 'fi'), 'en', reason: 'a language the app has not');
    expect(Words.meant('xx', device: 'fi'), 'en', reason: 'a choice from a newer build that this one has not');
  });

  test('loaded from the files: English drawn as written, Spanish by its English, anything untranslated in English', () async {
    final app = AppState()..set(Words.key, 'en');
    await Words.instance.follow(app, bundle: _Files());
    expect(['Settings'.t, Words.instance.language], ['Settings', 'en']);
    app.set(Words.key, 'es');
    await Words.instance.settled;
    expect(Words.instance.language, 'es');
    expect('Settings'.t, isNot('Settings'));
    expect('Settings'.t, _arb('es')[l10n.keyOf('Settings')]);
    expect('Words nobody wrote down'.t, 'Words nobody wrote down');
    expect(Words.instance.coverage.all, _arb('en').length);
    // Places filled after translating.
    Words.instance.setForTest('es', {'{n} people': '{n} personas'});
    expect('{n} people'.tf({'n': 3}), '3 personas');
    app.set(Words.key, 'en');
    await Words.instance.settled;
    expect('Settings'.t, 'Settings');
  });

  testWidgets('a page drawn in Spanish: a section\'s title, a row\'s name, fixed words, and a const Tr redrawn when the language changes', (tester) async {
    final sheet = await loadSheet(tester);
    final app = AppState();
    await pumpScreen(
      tester,
      sheet,
      const SingleChildScrollView(
        child: PaneSection(title: 'Language', children: [SettingRow(label: 'Message previews', hint: Tr('Turn it off here if you like'))]),
      ),
      app,
    );
    await settle(tester);
    expect(find.text('LANGUAGE'), findsOneWidget);
    expect(find.text('Message previews'), findsOneWidget);
    Words.instance.setForTest('es', {'Language': 'Idioma', 'Message previews': 'Vista previa de mensajes', 'Turn it off here if you like': 'Desactívalo aquí si quieres'});
    Words.redrawAll();
    await settle(tester);
    expect([find.text('IDIOMA'), find.text('Vista previa de mensajes'), find.text('Desactívalo aquí si quieres')].map((f) => f.evaluate().length), [1, 1, 1]);
    expect(find.text('Message previews'), findsNothing);
  });

  testWidgets('pictures with real fonts: Settings and its Appearance page in Spanish (test/shots/l10n-es-*)', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.runAsync(() async {
      await Words.instance.follow(app, bundle: _Files());
      app.set(Words.key, 'es');
      await Words.instance.settled;
    });
    await h.shoot(tester, const SettingsScreen(), 'l10n-es-settings-fonts');
    expect(find.text('Apariencia'), findsWidgets);
    await h.shoot(tester, const SettingsSectionScreen('language'), 'l10n-es-language-fonts');
    expect(find.text('IDIOMA'), findsOneWidget);
    await tester.runAsync(() async {
      app.set(Words.key, 'en');
      await Words.instance.settled;
    });
  });

  testWidgets('Settings drawn in Spanish from the files, and its Appearance page with the Language row', (tester) async {
    final sheet = await loadSheet(tester);
    final app = AppState()..set(Words.key, 'es');
    await tester.runAsync(() => Words.instance.follow(app, bundle: _Files()));
    expect(Words.instance.language, 'es');
    await pumpScreen(tester, sheet, const SettingsScreen(), app, size: const Size(412, 1400));
    await settle(tester);
    expect(find.text('Ajustes'), findsWidgets);
    expect(find.text('Apariencia'), findsWidgets, reason: 'a section named in Spanish');
    expect(find.text('Appearance'), findsNothing);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('language'), app, size: const Size(412, 1400));
    await settle(tester);
    expect(find.text('IDIOMA'), findsOneWidget);
    expect(find.text('Español'), findsOneWidget, reason: 'the language chosen, named in itself');
    await tester.runAsync(() async {
      app.set(Words.key, 'en');
      await Words.instance.settled;
    });
  });

  test('what is drawn through Tr is fixed words only, and the app\'s words are never translated where they are sent or kept', () {
    // A Tr of words built at run time could never be looked up: the code makes them with .tf instead.
    final built = RegExp(r"""\bTr\(\s*'[^'\n]*\$""");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      expect(built.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    // The layer is only ever read where things are drawn: nothing under lib/net or the relay's code asks it.
    for (final dir in ['lib/net', 'relay/lib']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        expect(f.readAsStringSync().contains('l10n/words.dart'), isFalse, reason: f.path);
      }
    }
    expect(jsonDecode(File('assets/l10n/app_en.arb').readAsStringSync())['@@locale'], 'en');
  });
}
