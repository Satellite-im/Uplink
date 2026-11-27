/// The app in more than one language (GMFB-32, from the Uplink gap review: "Flutter localization (ARB files) with
/// English as the source; a first extra language to prove it works").
///
/// **English is the source**, written where it is drawn, as it always was. Each other language is an ARB file
/// (`assets/l10n/app_<language>.arb`) whose keys are those of assets/l10n/app_en.arb, which tool/l10n.dart makes from
/// the code: every key names one piece of English, and a translation is looked up by that English. A piece with no
/// translation is drawn in English, so a screen is never blank or broken for a word not yet translated.
///
/// **What is translated** is what is drawn through:
/// - [Tr], a `Text` of fixed words that translates itself (`const Tr('Settings')`), and `'Settings'.t` ([Translated])
///   where words are handed on as a `String`;
/// - the kit's own words: a setting's name ([SettingRow]), a section's title ([PaneSection]), Settings' sections, a
///   menu's title and choices ([showChoices]), a page's title ([GhostPage]), a button's name ([IconTap]), and the
///   like. Each of those translates what it is given, so the code that gives it English needs nothing.
///
/// Words made up as the app runs (a name, a count, "Maya is typing") stay English until they are written with
/// [TranslatedWith.tf]. What the app sends, keeps or says to other devices is never translated: only what is drawn.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';

class Words extends ChangeNotifier {
  Words._();
  static final Words instance = Words._();

  /// The languages there are, by their code, each named in itself.
  ///
  /// The twenty most spoken (Matt, 2026-11-26: "Add translations for the 20 most popular languages"). Chinese is
  /// Simplified (a device in Chinese of any kind is given it). Then eight more, two of them written right to left
  /// (Matt, 2026-11-26: "Translate some RLT and LTR languages"): Hebrew, Persian, Italian, Dutch, Polish, Ukrainian,
  /// Thai and Greek. Arabic, Urdu, Hebrew and Persian draw the whole app mirrored ([rightToLeft]).
  static const languages = {
    'en': 'English',
    'ar': 'العربية',
    'bn': 'বাংলা',
    'de': 'Deutsch',
    'el': 'Ελληνικά',
    'es': 'Español',
    'fa': 'فارسی',
    'fr': 'Français',
    'he': 'עברית',
    'hi': 'हिन्दी',
    'id': 'Bahasa Indonesia',
    'it': 'Italiano',
    'ja': '日本語',
    'ko': '한국어',
    'mr': 'मराठी',
    'nl': 'Nederlands',
    'pl': 'Polski',
    'pt': 'Português',
    'ru': 'Русский',
    'sw': 'Kiswahili',
    'ta': 'தமிழ்',
    'te': 'తెలుగు',
    'th': 'ไทย',
    'tr': 'Türkçe',
    'uk': 'Українська',
    'ur': 'اردو',
    'vi': 'Tiếng Việt',
    'zh': '简体中文',
  };

  /// The languages written right to left: the app is drawn mirrored in them, its start on the right (Matt,
  /// 2026-11-26, asked whether to: "Yes, flip them").
  static const rightToLeft = {'ar', 'fa', 'he', 'ur'};

  /// Which way the app is drawn in the language drawn now.
  TextDirection get direction => rightToLeft.contains(_language) ? TextDirection.rtl : TextDirection.ltr;

  /// Where the choice is kept: a code of [languages], or [automatic] for the device's own where it is one of them.
  static const key = 'language', automatic = 'auto';

  /// The language drawn now.
  String get language => _language;
  String _language = 'en';

  /// English → this language's words; empty for English.
  Map<String, String> _now = const {};

  /// How much of the app's words [language] has: translated, and in all (English's, from app_en.arb).
  ({int translated, int all}) get coverage => (translated: _now.length, all: _all);
  int _all = 0;

  /// The words for [english] in the language drawn now; [english] itself where there are none.
  String say(String english) => _now[english] ?? english;

  /// The language [choice] means on this device: its own where it is automatic and the device's is one there is.
  static String meant(String choice, {String? device}) {
    if (languages.containsKey(choice) && choice != automatic) return choice;
    final own = (device ?? _deviceLanguage()).toLowerCase();
    return languages.containsKey(own) ? own : 'en';
  }

  static String _deviceLanguage() => WidgetsBinding.instance.platformDispatcher.locale.languageCode;

  AppState? _app;
  Future<void>? _loading;

  /// Follows [app]'s choice from now on, loading the language it means.
  Future<void> follow(AppState app, {AssetBundle? bundle}) {
    _app?.removeListener(_changed);
    _app = app..addListener(_changed);
    _bundle = bundle;
    return use(meant(app.choice(key, automatic)));
  }

  AssetBundle? _bundle;

  void _changed() {
    final app = _app;
    if (app == null) return;
    final want = meant(app.choice(key, automatic));
    if (want != _language) _loading = use(want);
  }

  /// Draws [language] from now on: its words loaded, and every page drawn again in it.
  Future<void> use(String language) async {
    final bundle = _bundle ?? rootBundle;
    Map<String, String> now = const {};
    var all = _all;
    if (language != 'en') {
      try {
        final en = parseArb(await bundle.loadString('assets/l10n/app_en.arb'));
        final there = parseArb(await bundle.loadString('assets/l10n/app_$language.arb'));
        all = en.length;
        now = {
          for (final e in there.entries)
            if (en[e.key] case final english? when e.value.trim().isNotEmpty) english: e.value,
        };
      } catch (e) {
        debugPrint('words: $language not loaded: $e');
        language = 'en';
      }
    }
    _language = language;
    _now = now;
    _all = all;
    notifyListeners();
    redrawAll();
  }

  /// Waits for a language being loaded (a test).
  @visibleForTesting
  Future<void> get settled => _loading ?? Future.value();

  /// Sets the words directly (a test): English → its translation.
  @visibleForTesting
  void setForTest(String language, Map<String, String> words) {
    _language = language;
    _now = words;
    notifyListeners();
  }

  /// An ARB file's messages, by key: the `@@locale` and every `@` entry (a message's description) left out.
  static Map<String, String> parseArb(String text) {
    final out = <String, String>{};
    final m = (jsonDecode(text) as Map).cast<String, Object?>();
    for (final e in m.entries) {
      if (e.key.startsWith('@') || e.value is! String) continue;
      out[e.key] = e.value as String;
    }
    return out;
  }

  /// Every page drawn again, so words already drawn are drawn in the new language. A language is changed seldom:
  /// the cost of drawing all of it once is nothing beside a page left half in the old one.
  static void redrawAll() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    mark(root);
  }
}

/// Which way words someone wrote run, where the app is drawn right to left: by their first letter, as a phone's own
/// messages app does, so an English message keeps its "?" at its end. Null where the app runs left to right (they
/// are drawn as ever) or the words have no letter.
TextDirection? ownDirection(String words) {
  if (Words.instance.direction == TextDirection.ltr) return null;
  for (final r in words.runes) {
    if ((r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF)) return TextDirection.rtl;
    if (_letter.hasMatch(String.fromCharCode(r))) return TextDirection.ltr;
  }
  return null;
}

final _letter = RegExp(r'\p{L}', unicode: true);

/// [words] someone wrote, kept to their own direction inside a line drawn right to left (a first-strong isolate), so
/// English punctuation stays at the English end. As they are where the app runs left to right.
String ownWords(String words) => Words.instance.direction == TextDirection.ltr || words.isEmpty ? words : '\u2068$words\u2069';

/// `'Settings'.t`: these words in the language drawn now.
extension Translated on String {
  String get t => Words.instance.say(this);
}

/// `'{n} people'.tf({'n': 3})`: words with places in them, translated, then each `{name}` filled. The English
/// itself, with its places, is what is looked up.
extension TranslatedWith on String {
  String tf(Map<String, Object?> fill) {
    var out = Words.instance.say(this);
    for (final e in fill.entries) {
      out = out.replaceAll('{${e.key}}', '${e.value}');
    }
    return out;
  }
}

/// [words] translated as a whole where it can be, else each part between ` · ` on its own: a state line made of fixed
/// pieces ("Light · White bubbles") is translated piece by piece, and whatever piece is a name or a count stays.
String translatedParts(String words) {
  final whole = Words.instance.say(words);
  if (!identical(whole, words) && whole != words) return whole;
  if (!words.contains(' · ')) return words;
  return words.split(' · ').map((p) => p.t).join(' · ');
}

/// A `Text` of fixed words, drawn in the language drawn now. Takes what a `Text` of words mostly takes.
class Tr extends StatelessWidget {
  const Tr(this.words, {super.key, this.style, this.textAlign, this.maxLines, this.overflow, this.softWrap, this.textScaler, this.semanticsLabel});
  final String words;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextScaler? textScaler;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) =>
      Text(words.t, style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow, softWrap: softWrap, textScaler: textScaler, semanticsLabel: semanticsLabel?.t);
}
