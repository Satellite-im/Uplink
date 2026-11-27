import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/shown_store.dart';
import 'package:ghost_messaging/plugins/translate.dart';
import 'package:ghost_messaging/ui/translated_card.dart';

import '../support/list_harness.dart';

/// The Translate plugin (lib/plugins/translate.dart; Matt, 2026-11-17: "add a translate plugin which can automatically
/// translate texts when detected from another language and show the original text dimmed in a card with the translated
/// text for the actual message bubble"): which texts are worth asking about, what the card and the bubble say for each
/// thing the phone can answer, that the person's own are never asked about, that an answer is kept while the words
/// and the choices stand, and the card drawn over a bubble. The phone's engine is a fake here.

/// The phone's translation, made up: [answers] by the words, and every text it was asked about.
class FakeHost implements TextHost {
  FakeHost(this.answers, {this.language = 'en', this.canTranslate = true});
  final Map<String, DeviceTranslation> answers;
  @override
  final String language;
  @override
  final bool canTranslate;
  final asked = <(String, String, List<String>)>[];

  @override
  Future<DeviceTranslation> translate(String text, {required String to, List<String> known = const [], bool fetch = true, bool wifiOnly = true}) async {
    asked.add((text, to, known));
    return answers[text] ?? const DeviceTranslation('same', from: 'en');
  }

  @override
  Future<List<DeviceLanguage>> languages() async => const [DeviceLanguage('en', downloaded: true), DeviceLanguage('es', downloaded: true)];

  @override
  Future<bool> model(String tag, {bool delete = false, bool wifiOnly = true}) async => true;
}

const _hola = 'Hola, ¿cómo estás? ¿Vienes a la fiesta esta noche?';
const _hello = 'Hi, how are you? Are you coming to the party tonight?';

MessageFacts _from(String text, {String id = 'sms:1', bool? outgoing = false}) => MessageFacts(thread: 1, senders: const ['+15551230001'], text: text, contact: true, outgoing: outgoing, id: id, network: 'sms');

void main() {
  late TextHost shippedHost;
  late PluginRegistry shipped;
  setUp(() {
    shippedHost = PluginRegistry.textHost;
    shipped = PluginRegistry.instance;
    TranslatePlugin.asked.clear();
    ShownStore.instance = ShownStore();
  });
  tearDown(() {
    PluginRegistry.textHost = shippedHost;
    PluginRegistry.instance = shipped;
  });

  group('worth asking about', () {
    test('a sentence or a few words of letters is', () {
      expect(TranslatePlugin.worth(_hola), isTrue);
      expect(TranslatePlugin.worth('Wo bist du gerade?'), isTrue);
      expect(TranslatePlugin.worth('Merci beaucoup pour hier soir'), isTrue);
      expect(TranslatePlugin.worth('明日の会議は何時ですか'), isTrue, reason: 'a script written without spaces counts its characters');
      expect(TranslatePlugin.worth('Привет, как дела?'), isTrue);
    });

    test('a code, a link, an emoji or "ok lol" is not', () {
      for (final no in ['', '   ', 'ok lol', '👍', '😂😂😂', 'haha yes 😂', 'G-482913', 'Your code: 482913', 'https://example.com/a/very/long/link?with=params', 'see https://example.com', '@maya', ':thumbsup:', '+1 (555) 123-4567', '12:30', 'Gracias', '好的', 'jaja']) {
        expect(TranslatePlugin.worth(no), isFalse, reason: no);
      }
    });

    test('mostly not letters is not', () {
      expect(TranslatePlugin.worth('ok 🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉'), isFalse);
    });
  });

  group('what the card and the bubble say', () {
    test('a translation: the bubble says it, the card the words as they came', () {
      final s = TranslatePlugin.shownOf(_hola, const DeviceTranslation('done', text: _hello, from: 'es'))!;
      expect(s.text, _hello);
      expect(s.original, _hola);
      expect(s.note, 'Translated from Spanish');
      expect(s.showOriginal, 'Show original');
      expect(s.busy, isFalse);
      expect(s.again, isNull);
    });

    test('a language being got ready says so, and is asked about again', () {
      final s = TranslatePlugin.shownOf(_hola, const DeviceTranslation('fetching', from: 'es'))!;
      expect(s.text, _hola, reason: 'the words as they came until the translation is here');
      expect(s.original, isNull);
      expect(s.note, 'Getting Spanish ready…');
      expect(s.busy, isTrue);
      expect(s.again, TranslatePlugin.fetchingAgain);
      expect(TranslatePlugin.shownOf(_hola, const DeviceTranslation('waiting-wifi', from: 'es'))!.note, 'Spanish will be ready on Wi-Fi');
    });

    test('a translation swapped back says what the card holds, and Swap back', () {
      final s = TranslatePlugin.shownOf(_hola, const DeviceTranslation('done', text: _hello, from: 'es'), into: 'en')!;
      final view = ShownView('sms:1', s, flipped: true);
      expect(view.card, _hello);
      expect(view.heading, 'English translation', reason: 'it read "As sent, in Spanish" over the English');
      expect(view.word, 'Swap back');
    });

    test('nothing to do is nothing shown, unless the person asked for it', () {
      for (final state in ['same', 'und', 'unsupported']) {
        expect(TranslatePlugin.shownOf(_hola, DeviceTranslation(state, from: 'es')), isNull, reason: state);
      }
      // Not now, but maybe soon: nothing shown, and asked again in a while rather than never for the session.
      for (final state in ['unavailable', 'offline', 'failed']) {
        final later = TranslatePlugin.shownOf(_hola, DeviceTranslation(state, from: 'es'))!;
        expect(later.later, isTrue, reason: state);
        expect(later.again, TranslatePlugin.retryAgain, reason: state);
      }
      expect(TranslatePlugin.shownOf(_hola, const DeviceTranslation('offline'), byHand: true)!.again, TranslatePlugin.retryAgain);
      expect(TranslatePlugin.shownOf('Good morning to you all', const DeviceTranslation('same', from: 'en'), byHand: true, into: 'en')!.note, 'Already in English');
      expect(TranslatePlugin.shownOf(_hola, const DeviceTranslation('und'), byHand: true)!.note, 'Not sure which language this is');
      // A translation that changed nothing is not one.
      expect(TranslatePlugin.shownOf(_hola, const DeviceTranslation('done', text: _hola, from: 'es')), isNull);
    });

    test('languages are named and found by name', () {
      expect(languageName('es'), 'Spanish');
      expect(languageName('pt-BR'), 'Portuguese');
      expect(languageName('xx'), isNull);
      expect(languageTag('French'), 'fr');
      expect(languageTag('français'), 'fr');
      expect(languageTag('de'), 'de');
      expect(languageTag('Klingon'), isNull);
      expect(translateLanguages.length, 59);
      // A phone's codes that are not the models' tags: a Norwegian phone reads Norwegian.
      expect(languageName('nb'), 'Norwegian');
      expect(languageName('fil'), 'Tagalog');
      expect(languageName('iw'), 'Hebrew');
      expect(TranslatePlugin.targetOf(PluginPrefs.none, FakeHost({}, language: 'nb')), 'no');
    });
  });

  group('the rule', () {
    test('your own are never asked about, nor anything while translating is off on this device', () async {
      final host = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')});
      expect(await TranslatePlugin.shown(_from(_hola, outgoing: true), PluginPrefs.none, host), isNull);
      expect(await TranslatePlugin.shown(_from(_hola, outgoing: null), PluginPrefs.none, host), isNull);
      expect(host.asked, isEmpty);
      final none = FakeHost({}, canTranslate: false);
      expect(await TranslatePlugin.shown(_from(_hola), PluginPrefs.none, none), isNull);
      expect(none.asked, isEmpty);
    });

    test('into the device\'s language, or the one chosen; the languages read too are passed on', () async {
      final host = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')}, language: 'de');
      final s = await TranslatePlugin.shown(_from(_hola), PluginPrefs.none, host);
      expect(s!.text, _hello);
      expect(host.asked.single.$2, 'de');
      final store = MemoryStore({'plugin_translate_to': 'fr', 'plugin_translate_known': 'Italian\nde'});
      final prefs = PluginRegistry([const TranslatePlugin()]).prefsOf(const TranslatePlugin(), store);
      await TranslatePlugin.shown(_from(_hola), prefs, host);
      expect(host.asked.last.$2, 'fr');
      expect(host.asked.last.$3, ['it', 'de']);
      // A device in a language with no model translates into English.
      expect(TranslatePlugin.targetOf(PluginPrefs.none, FakeHost({}, language: 'xx')), 'en');
    });

    test('with translating as texts come off, only a text asked for from its menu is', () async {
      final host = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')});
      final store = MemoryStore({'plugin_translate_auto': 'off'});
      final prefs = PluginRegistry([const TranslatePlugin()]).prefsOf(const TranslatePlugin(), store);
      final facts = _from(_hola);
      expect(await TranslatePlugin.shown(facts, prefs, host), isNull);
      expect(host.asked, isEmpty);
      final menu = TranslatePlugin.menu(facts, prefs);
      expect(menu.map((a) => a.label), ['Translate']);
      await menu.single.run(_NoHost());
      expect((await TranslatePlugin.shown(facts, prefs, host))!.text, _hello);
    });

    test('a sign-in code\'s text is left as it came, unless asked for from its menu', () async {
      const code = 'Tu código de verificación es 482913. No lo compartas con nadie.';
      final host = FakeHost({code: const DeviceTranslation('done', text: 'Your verification code is 482 913. Do not share it with anyone.', from: 'es')});
      final facts = _from(code, id: 'sms:7');
      expect(TranslatePlugin.worth(code), isTrue, reason: 'words enough: it is the code that keeps it as it came');
      expect(await TranslatePlugin.shown(facts, PluginPrefs.none, host), isNull);
      expect(host.asked, isEmpty);
      TranslatePlugin.asked.add('sms:7');
      expect((await TranslatePlugin.shown(facts, PluginPrefs.none, host))!.original, code);
    });

    test('a short text is not sent to be identified', () async {
      final host = FakeHost({});
      expect(await TranslatePlugin.shown(_from('ok lol'), PluginPrefs.none, host), isNull);
      expect(host.asked, isEmpty);
    });
  });

  group('kept while the words and the choices stand', () {
    test('asked once however often it is drawn; asked again when the words change', () async {
      final host = FakeHost({
        _hola: const DeviceTranslation('done', text: _hello, from: 'es'),
        'Hola, ¿cómo estás? Llego en diez minutos': const DeviceTranslation('done', text: 'Hi, how are you? I\'ll be there in ten minutes', from: 'es'),
      });
      PluginRegistry.textHost = host;
      final registry = PluginRegistry([const TranslatePlugin()]);
      final shown = ShownStore(registry: registry);
      final store = MemoryStore({'plugin_translate': 'on'});
      var told = 0;
      shown.addListener(() => told++);
      expect(shown.of(_from(_hola), store), isNull, reason: 'nothing until the phone answers');
      expect(shown.of(_from(_hola), store), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(1));
      expect(told, 1);
      expect(shown.of(_from(_hola), store)!.text, _hello);
      expect(shown.held('sms:1')!.text, _hello);
      expect(host.asked, hasLength(1), reason: 'scrolled past and back: not asked again');
      // Edited: the same message, new words.
      expect(shown.of(_from('Hola, ¿cómo estás? Llego en diez minutos'), store), isNull, reason: 'the old translation is for other words');
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(2));
      expect(shown.of(_from('Hola, ¿cómo estás? Llego en diez minutos'), store)!.text, startsWith('Hi, how are you? I\'ll'));
    });

    test('off, nothing is asked and nothing shown; a choice changed asks again, the old answer standing meanwhile', () async {
      final host = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')});
      PluginRegistry.textHost = host;
      final registry = PluginRegistry([const TranslatePlugin()]);
      final shown = ShownStore(registry: registry);
      final store = MemoryStore();
      expect(shown.of(_from(_hola), store), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, isEmpty, reason: 'off until it is added');
      registry.setOn(const TranslatePlugin(), store, true);
      shown.of(_from(_hola), store);
      await Future<void>.delayed(Duration.zero);
      expect(shown.of(_from(_hola), store)!.text, _hello);
      registry.prefsOf(const TranslatePlugin(), store).set('to', 'fr');
      expect(shown.of(_from(_hola), store)!.text, _hello, reason: 'no flicker while it is asked again');
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(2));
      expect(host.asked.last.$2, 'fr');
    });

    test('"later" is nothing shown, the next plugin asked, and asked again once its while has passed', () async {
      final registry = PluginRegistry([const _Later(), const _Shouts()]);
      final shown = ShownStore(registry: registry);
      final store = MemoryStore({'plugin_shouts': 'off'});
      _Later.calls = 0;
      shown.of(_from('anything at all here'), store);
      await Future<void>.delayed(Duration.zero);
      expect(shown.of(_from('anything at all here'), store), isNull);
      expect(shown.due('sms:1'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(shown.due('sms:1'), isTrue, reason: 'held as nothing for the session before');
      shown.of(_from('anything at all here'), store);
      await Future<void>.delayed(Duration.zero);
      expect(_Later.calls, 2);
      // With a plugin after it that answers, that one has the bubble.
      registry.setOn(const _Shouts(), store, true);
      shown.of(_from('anything at all here'), store);
      await Future<void>.delayed(Duration.zero);
      expect(shown.of(_from('anything at all here'), store)!.text, 'ANYTHING AT ALL HERE');
    });

    test('another plugin\'s choice asks nothing again; Translate\'s own does, and so does askAll', () async {
      final host = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')});
      PluginRegistry.textHost = host;
      final registry = PluginRegistry([const TranslatePlugin(), const _Shouts()]);
      final shown = ShownStore(registry: registry);
      final store = MemoryStore({'plugin_translate': 'on', 'plugin_shouts': 'off'});
      shown.of(_from(_hola), store);
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(1));
      // A conversation filed, a plugin with no text rules' choice: the stamp goes up, the translation stands.
      store.write('plugins_filed', '12');
      store.write('plugin_spam_level', 'strict');
      expect(shown.of(_from(_hola), store)!.text, _hello);
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(1));
      registry.prefsOf(const TranslatePlugin(), store).set('known', 'French');
      shown.of(_from(_hola), store);
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(2));
      // What the device can do changed (a computer heard from its phone): every message asked again.
      shown.askAll();
      expect(shown.due('sms:1'), isTrue);
      expect(shown.of(_from(_hola), store)!.text, _hello, reason: 'what was held stands meanwhile');
      await Future<void>.delayed(Duration.zero);
      expect(host.asked, hasLength(3));
    });

    test('the first plugin to answer has the bubble; one that throws is left out and told', () async {
      final errors = <String>[];
      final registry = PluginRegistry([const _Throws(), const _Shouts(), const _Shouts2()], onError: (p, e) => errors.add(p.id));
      final shown = ShownStore(registry: registry);
      final store = MemoryStore();
      shown.of(_from('anything at all here'), store);
      await Future<void>.delayed(Duration.zero);
      expect(shown.of(_from('anything at all here'), store)!.text, 'ANYTHING AT ALL HERE');
      expect(errors, ['throws']);
    });

    test('swapped by the person, held for the session', () {
      final shown = ShownStore();
      expect(shown.flipped('sms:1'), isFalse);
      shown.flip('sms:1');
      expect(shown.flipped('sms:1'), isTrue);
      final view = ShownView('sms:1', const ShownText(text: _hello, original: _hola, note: 'Translated from Spanish', flipNote: 'As sent, in Spanish'), flipped: true);
      expect(view.bubble, _hola);
      expect(view.card, _hello);
      expect(view.heading, 'As sent, in Spanish');
      expect(view.word, 'Show translation');
      // Still at work: nothing to swap.
      const busy = ShownView('sms:2', ShownText(text: _hola, note: 'Getting Spanish ready…', busy: true), flipped: true);
      expect(busy.bubble, _hola);
      expect(busy.canFlip, isFalse);
    });
  });

  group('the contract', () {
    test('the app ships it, off until it is added, with its own page and the Messages shelf', () {
      final registry = PluginRegistry.instance;
      final plugin = registry.plugins.whereType<TranslatePlugin>().single;
      expect(plugin.onByDefault, isFalse);
      expect(plugin.settingsPage?.hue, 'purple');
      expect(plugin.shelf, PluginShelf.messages);
      final store = MemoryStore();
      expect(registry.textRules(store), isEmpty);
      registry.setOn(plugin, store, true);
      expect(registry.textRules(store).map((r) => r.plugin.id), ['translate']);
      // A message's facts carry its id and where it came by, for a plugin not compiled in.
      expect(_from(_hola).toJson()['id'], 'sms:1');
      expect(_from(_hola).toJson()['network'], 'sms');
    });

    test('its settings name no brand but where the licence needs it', () {
      for (final s in const TranslatePlugin().settings) {
        final words = '${s.label} ${s.hint ?? ''}';
        if (words.contains('Google')) expect(s.label, 'On this phone only', reason: 'only the licence and privacy note');
      }
    });
  });

  group('the card over a bubble', () {
    testWidgets('says the language and Show original, the words dimmed; a tap swaps them', (tester) async {
      _quietChannel();
      PluginRegistry.textHost = FakeHost({_hola: const DeviceTranslation('done', text: _hello, from: 'es')});
      PluginRegistry.instance = PluginRegistry([const TranslatePlugin()]);
      final state = AppState()..set('plugin_translate', 'on');
      final sheet = await loadSheet(tester);
      await pumpScreen(
        tester,
        sheet,
        Center(
          child: ShownWords(
            facts: _from(_hola),
            builder: (context, view) => Column(mainAxisSize: MainAxisSize.min, children: [
              if (view != null) OriginalCard(view: view, maxWidth: 300),
              Text(view?.bubble ?? _hola, key: const ValueKey('bubble')),
            ]),
          ),
        ),
        state,
      );
      expect(tester.widget<Text>(find.byKey(const ValueKey('bubble'))).data, _hello);
      expect(find.textContaining('Translated from Spanish'), findsOneWidget);
      expect(find.text('Show original'), findsOneWidget);
      expect(find.text(_hola), findsOneWidget, reason: 'the words as they came, in the card');
      await tester.tap(find.byType(OriginalCard));
      await settle(tester);
      expect(tester.widget<Text>(find.byKey(const ValueKey('bubble'))).data, _hola);
      expect(find.text('Swap back'), findsOneWidget);
      expect(find.textContaining('English translation'), findsOneWidget, reason: 'the card says what it holds');
      expect(find.text(_hello), findsOneWidget);
    });
  });
}

class _NoHost implements PluginHost {
  @override
  PluginPrefs get prefs => PluginPrefs.none;
  @override
  void say(String words) {}
  @override
  void copy(String text, {String? say}) {}
  @override
  void open(int thread) {}
  @override
  Future<void> markRead(int thread) async {}
  @override
  void move(int thread, String? section) {}
  @override
  void write(String text) {}
  @override
  void present(WidgetBuilder page) {}
  @override
  Future<void> deleteThread(int thread) async {}
  @override
  Future<void> reload() async {}
}

class _Throws extends GhostPlugin {
  const _Throws();
  @override
  String get id => 'throws';
  @override
  String get name => 'Throws';
  @override
  String get description => '';
  @override
  List<TextRule> get text => [(facts, prefs, host) async => throw StateError('no')];
}

class _Shouts extends GhostPlugin {
  const _Shouts();
  @override
  String get id => 'shouts';
  @override
  String get name => 'Shouts';
  @override
  String get description => '';
  @override
  List<TextRule> get text => [(facts, prefs, host) async => ShownText(text: facts.text.toUpperCase(), original: facts.text)];
}

class _Later extends GhostPlugin {
  const _Later();
  static int calls = 0;
  @override
  String get id => 'later';
  @override
  String get name => 'Later';
  @override
  String get description => '';
  @override
  List<TextRule> get text => [
        (facts, prefs, host) async {
          calls++;
          return const ShownText.later(Duration(milliseconds: 10));
        }
      ];
}

class _Shouts2 extends GhostPlugin {
  const _Shouts2();
  @override
  String get id => 'shouts2';
  @override
  String get name => 'Shouts again';
  @override
  String get description => '';
  @override
  List<TextRule> get text => [(facts, prefs, host) async => const ShownText(text: 'second')];
}

void _quietChannel() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'prefs' ? <String, String>{} : null);
}
