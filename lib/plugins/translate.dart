/// Translate: a text in another language is translated on the phone as it is shown, the translation in its bubble and
/// the words as they came over it, dimmed, in a card of their own (Matt, 2026-11-17: "add a translate plugin which can
/// automatically translate texts when detected from another language and show the original text dimmed in a card with
/// the translated text for the actual message bubble").
///
/// The work is the phone's: its language identification says what language a text is in and how sure it is, and its
/// on-device translation translates it (android/.../Translate.kt). A language's model, about 30 MB, is fetched once,
/// the first time a text needs it; meanwhile the card says the language is being got ready. A computer, or an iPhone
/// paired with a phone, asks the phone (lib/desktop/remote.dart); an iPhone on its own cannot translate yet, and says
/// so. Only texts that came to the person are translated, never their own, and only ones with words enough to tell
/// their language by (not a code, a link, an emoji or "ok lol": [TranslatePlugin.worth]).
///
/// Off until it is added: it fetches models.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../ui/common.dart' show GhostPage, push;
import 'codes.dart' show signInCode;
import 'plugin.dart';
import 'registry.dart';
import 'shown_store.dart';
import '../l10n/words.dart';

/// The languages the phone's translation has models for (ML Kit's 59, as of translate 17.0.3): each one's tag, its
/// name in English (the app's language) and its name in itself.
const Map<String, (String, String)> translateLanguages = {
  'af': ('Afrikaans', 'Afrikaans'),
  'ar': ('Arabic', 'العربية'),
  'be': ('Belarusian', 'Беларуская'),
  'bg': ('Bulgarian', 'Български'),
  'bn': ('Bengali', 'বাংলা'),
  'ca': ('Catalan', 'Català'),
  'cs': ('Czech', 'Čeština'),
  'cy': ('Welsh', 'Cymraeg'),
  'da': ('Danish', 'Dansk'),
  'de': ('German', 'Deutsch'),
  'el': ('Greek', 'Ελληνικά'),
  'en': ('English', 'English'),
  'eo': ('Esperanto', 'Esperanto'),
  'es': ('Spanish', 'Español'),
  'et': ('Estonian', 'Eesti'),
  'fa': ('Persian', 'فارسی'),
  'fi': ('Finnish', 'Suomi'),
  'fr': ('French', 'Français'),
  'ga': ('Irish', 'Gaeilge'),
  'gl': ('Galician', 'Galego'),
  'gu': ('Gujarati', 'ગુજરાતી'),
  'he': ('Hebrew', 'עברית'),
  'hi': ('Hindi', 'हिन्दी'),
  'hr': ('Croatian', 'Hrvatski'),
  'ht': ('Haitian Creole', 'Kreyòl ayisyen'),
  'hu': ('Hungarian', 'Magyar'),
  'id': ('Indonesian', 'Bahasa Indonesia'),
  'is': ('Icelandic', 'Íslenska'),
  'it': ('Italian', 'Italiano'),
  'ja': ('Japanese', '日本語'),
  'ka': ('Georgian', 'ქართული'),
  'kn': ('Kannada', 'ಕನ್ನಡ'),
  'ko': ('Korean', '한국어'),
  'lt': ('Lithuanian', 'Lietuvių'),
  'lv': ('Latvian', 'Latviešu'),
  'mk': ('Macedonian', 'Македонски'),
  'mr': ('Marathi', 'मराठी'),
  'ms': ('Malay', 'Bahasa Melayu'),
  'mt': ('Maltese', 'Malti'),
  'nl': ('Dutch', 'Nederlands'),
  'no': ('Norwegian', 'Norsk'),
  'pl': ('Polish', 'Polski'),
  'pt': ('Portuguese', 'Português'),
  'ro': ('Romanian', 'Română'),
  'ru': ('Russian', 'Русский'),
  'sk': ('Slovak', 'Slovenčina'),
  'sl': ('Slovenian', 'Slovenščina'),
  'sq': ('Albanian', 'Shqip'),
  'sv': ('Swedish', 'Svenska'),
  'sw': ('Swahili', 'Kiswahili'),
  'ta': ('Tamil', 'தமிழ்'),
  'te': ('Telugu', 'తెలుగు'),
  'th': ('Thai', 'ไทย'),
  'tl': ('Tagalog', 'Tagalog'),
  'tr': ('Turkish', 'Türkçe'),
  'uk': ('Ukrainian', 'Українська'),
  'ur': ('Urdu', 'اردو'),
  'vi': ('Vietnamese', 'Tiếng Việt'),
  'zh': ('Chinese', '中文'),
};

/// A language's name in English by its tag ("es", "pt-BR"), or null for one the phone has no model for.
String? languageName(String? tag) {
  if (tag == null || tag.isEmpty) return null;
  return translateLanguages[_base(tag)]?.$1;
}

/// The tag of a language named in English or in itself, or given by its tag ("French", "français", "fr"); null for
/// one the phone cannot translate.
String? languageTag(String said) {
  final s = said.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (translateLanguages.containsKey(_base(s))) return _base(s);
  for (final e in translateLanguages.entries) {
    if (e.value.$1.toLowerCase() == s || e.value.$2.toLowerCase() == s) return e.key;
  }
  return null;
}

/// A language tag without its region or script ("pt-BR" is "pt"), as the models name it ([languageAliases]).
String _base(String tag) {
  final base = tag.split(RegExp(r'[-_]')).first.toLowerCase();
  return languageAliases[base] ?? base;
}

/// A device's language codes that are not the models' tags (Translate.kt has the same): Norwegian Bokmål and Nynorsk
/// are both "no", Filipino is "tl", and the old codes for Hebrew, Indonesian and Yiddish. Without it a Norwegian phone
/// read no language there is a model for, and Norwegian texts were translated into English.
const Map<String, String> languageAliases = {'nb': 'no', 'nn': 'no', 'fil': 'tl', 'iw': 'he', 'in': 'id', 'ji': 'yi'};

class TranslatePlugin extends GhostPlugin {
  const TranslatePlugin();

  /// Messages translated by hand, from their menu, while translating by itself is off: by their id, for the session.
  static final Set<String> asked = {};

  /// How long the card waits before asking again while a language's model is coming.
  static const fetchingAgain = Duration(seconds: 4);
  static const wifiAgain = Duration(seconds: 30);

  /// How long before a text the device could not translate just now is asked about again: the phone out of reach, a
  /// computer that has not heard what its phone can do, a translation that failed (a translator let go mid-way).
  static const retryAgain = Duration(seconds: 20);

  @override
  String get id => 'translate';

  @override
  String get name => 'Translate';

  @override
  String get description => 'Texts in another language are translated on this phone, with the words as they were sent shown dimmed above.';

  @override
  LucideIcon get icon => LucideMore.languages;

  @override
  bool get onByDefault => false;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated
  // plugins page with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.messages;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['language'];

  @override
  String get tagline => 'Texts in another language translated on this phone, the words as sent shown over them.';

  // Whole on the featured card, which cut the tagline off at "the words as sent s…".
  @override
  String get pitch => 'Another language, translated on this phone. The original stays, dimmed.';

  @override
  List<String> get adds => const [
        'The translation in the bubble, with the words as they were sent in a dimmed card over it',
        'A tap on the card swaps the two',
        'Translate and Copy translation in a message\'s menu',
        'Texts, Telegram, Signal and spaces alike; on a computer, your phone translates',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.messageSquare, 'Texts that came to you, read on this phone', 'To tell their language and translate them, on the phone, with Google\'s on-device translation (ML Kit). Never your own, and nothing is sent anywhere.'),
        PluginReach(Lucide.download, 'A language model for each language, about 30 MB', 'Downloaded once from Google, on Wi-Fi unless you say otherwise, the first time a text needs it.'),
      ];

  // --- what it shows --------------------------------------------------------------------------------------------------

  /// Whether [text] has words enough to tell its language by: not a code, a link, an address, an emoji or two, or a
  /// couple of short words ("ok lol"), which language identification mistakes for anything. Three words of two or more
  /// letters, or twelve letters, once links, addresses, handles, :shortcodes:, numbers and codes are taken out; four
  /// characters of a script written without spaces (Chinese, Japanese, Korean, Thai); and letters at least half of
  /// what is left.
  static bool worth(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 4000) return false;
    final s = t
        .replaceAll(RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\S+@\S+\.\S+'), ' ')
        .replaceAll(RegExp(r'[@#][\w.]+'), ' ')
        .replaceAll(RegExp(r':[a-z0-9_+-]+:'), ' ')
        // A token with a digit in it: a code ("G-482913", "AB12CD"), a time, a price.
        .replaceAll(RegExp(r'\S*\d\S*'), ' ');
    final visible = s.replaceAll(RegExp(r'\s+'), '').length;
    final letters = RegExp(r'\p{L}', unicode: true).allMatches(s).length;
    if (letters == 0 || letters * 2 < visible) return false;
    final unspaced = RegExp(r'[぀-ヿ㐀-䶿一-鿿가-힯฀-๿]').allMatches(s).length;
    if (unspaced >= 4) return true;
    final words = RegExp(r'\p{L}{2,}', unicode: true).allMatches(s).length;
    return words >= 3 || letters >= 12;
  }

  /// The language texts are translated into: the one chosen, else the device's own; English where neither has a model.
  static String targetOf(PluginPrefs prefs, TextHost host) {
    for (final t in [prefs.get('to'), host.language]) {
      if (t != null && translateLanguages.containsKey(_base(t))) return _base(t);
    }
    return 'en';
  }

  /// The other languages the person reads, which are never translated.
  static List<String> knownOf(PluginPrefs prefs) => [for (final w in wordsOf(prefs, 'known')) ?languageTag(w)];

  /// The rule: what a message from someone else is shown as.
  static Future<ShownText?> shown(MessageFacts facts, PluginPrefs prefs, TextHost host) async {
    if (facts.outgoing != false || !host.canTranslate) return null;
    final words = facts.text.trim();
    final byHand = asked.contains(ShownStore.keyOf(facts));
    if (!byHand && (!prefs.flag('auto') || !worth(words))) return null;
    if (words.isEmpty) return null;
    // A sign-in code's text is left as it came unless asked for: a translation can group the digits or move them
    // about the words, and the code is what the text is for ("Tu código de verificación es 482913").
    if (!byHand && signInCode(words) != null) return null;
    final answer = await host.translate(words, to: targetOf(prefs, host), known: knownOf(prefs), fetch: true, wifiOnly: prefs.flag('wifi'));
    return shownOf(words, answer, byHand: byHand, into: targetOf(prefs, host));
  }

  /// What the card and the bubble say for what the device answered. [byHand]: the person asked for this one from its
  /// menu, so an answer of "nothing to do" is said rather than left unseen.
  static ShownText? shownOf(String words, DeviceTranslation answer, {bool byHand = false, String into = 'en'}) {
    final from = languageName(answer.from);
    switch (answer.state) {
      case 'done':
        final said = (answer.text ?? '').trim();
        if (said.isEmpty || said == words) return null;
        // Swapped, the card holds the translation and its heading says so: it read "As sent, in Spanish" over English
        // words, naming the bubble rather than the card it was on.
        final to = languageName(into);
        return ShownText(text: said, original: words, note: from == null ? 'Translated' : 'Translated from $from', flipNote: to == null ? 'Translation' : '$to translation', showShown: 'Swap back');
      case 'fetching':
        return ShownText(text: words, note: 'Getting ${from ?? 'the language'} ready…', busy: true, again: fetchingAgain);
      case 'waiting-wifi':
        return ShownText(text: words, note: '${from ?? 'This language'} will be ready on Wi-Fi', again: wifiAgain);
    }
    // Not now, but maybe soon: asked again in a little while rather than held as nothing for the session.
    // 'unavailable', 'offline', 'failed': those settled for these words are 'same', 'und' and 'unsupported'.
    final passing = !const {'same', 'und', 'unsupported', 'needs-model'}.contains(answer.state);
    if (!byHand) return passing ? const ShownText.later(retryAgain) : null;
    final note = switch (answer.state) {
      'same' => 'Already in ${languageName(into) ?? 'your language'}',
      'und' => 'Not sure which language this is',
      'unsupported' => from == null ? 'This language can\'t be translated yet' : '$from can\'t be translated yet',
      'unavailable' => 'Translation isn\'t available on this device',
      'offline' => 'Your phone is out of reach',
      _ => 'Couldn\'t translate this',
    };
    return ShownText(text: words, note: note, again: passing ? retryAgain : null);
  }

  @override
  List<TextRule> get text => const [shown];

  // --- a message's menu ---------------------------------------------------------------------------------------------

  /// The lines for one message's menu: Translate (where it is not done by itself), and once translated, Copy
  /// translation and the way round it is shown. "Show original" is the edit's own line (lib/ui/thread.dart), so
  /// these say "untranslated".
  static List<PluginAction> menu(MessageFacts facts, PluginPrefs prefs) {
    if (facts.outgoing != false || facts.id == null) return const [];
    final id = facts.id!;
    final store = ShownStore.instance;
    final held = store.held(id);
    if (held?.original != null && !held!.busy) {
      final flipped = store.flipped(id);
      return [
        PluginAction(label: 'Copy translation', icon: Lucide.copy, run: (host) => host.copy(held.text, say: 'Copied')),
        PluginAction(label: flipped ? 'Show translated' : 'Show untranslated', icon: LucideMore.languages, run: (_) => store.flip(id)),
      ];
    }
    if (held != null || asked.contains(id) || facts.text.trim().isEmpty) return const [];
    if (prefs.flag('auto') && worth(facts.text)) return const [];
    return [
      PluginAction(label: 'Translate', icon: LucideMore.languages, run: (_) {
        asked.add(id);
        store.again(id);
      }),
    ];
  }

  @override
  List<SlotFill> get slots => [
        Slots.messageMenu.fill((place, prefs) => menu(place.facts, prefs)),
        Slots.settings.fill((context, place, prefs) => _settingsRows(prefs)),
      ];

  // --- its settings -------------------------------------------------------------------------------------------------

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'purple',
        intro: 'Texts in other languages, translated on this phone into yours.',
        summary: (prefs) => 'Into ${languageName(targetOf(prefs, PluginRegistry.textHost)) ?? 'English'} · ${prefs.flag('auto') ? 'as they come' : 'from the menu'}',
      );

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(
          key: 'auto',
          label: 'Translate texts as they come',
          hint: 'When this is off, you choose Translate from a text\'s menu.',
          icon: LucideMore.languages,
        ),
        PluginSetting.toggle(
          key: 'wifi',
          label: 'Get languages on Wi-Fi only',
          hint: 'Each language is about 30 MB, fetched once, the first time a text needs it.',
          icon: Lucide.wifi,
        ),
        PluginSetting.note(
          label: 'On this phone only',
          hint: 'Texts are translated by on-device translation and are never sent anywhere. Each language\'s model is '
              'downloaded once from Google, under Google\'s terms for on-device translation. On a computer, your phone '
              'does the translating.',
          icon: Lucide.lock,
        ),
        PluginSetting.heading(label: 'Languages', hint: 'Texts are translated into your language. Ones in a language you also read are left as they are.'),
      ];
}

/// The plugin's own rows on its page ([Slots.settings]): your language, the others you read, the languages on the
/// phone; or, on an iPhone on its own, why there is no translation here.
List<Widget> _settingsRows(PluginPrefs prefs) => PluginRegistry.textHost.canTranslate
    ? [_YourLanguage(prefs: prefs), _AlsoRead(prefs: prefs), _OnThePhone(prefs: prefs)]
    : const [
        SettingRow(
          icon: AppIcon(Lucide.info, size: 18),
          label: 'Not on this device yet',
          hint: Tr('Translation runs on an Android phone. Pair this iPhone with one to translate here.'),
        ),
      ];

/// The language texts are translated into: this device's own unless one is chosen here.
class _YourLanguage extends StatelessWidget implements PaneRow {
  const _YourLanguage({required this.prefs});
  final PluginPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final host = PluginRegistry.textHost;
    final to = TranslatePlugin.targetOf(prefs, host);
    final own = translateLanguages.containsKey(_base(host.language)) ? _base(host.language) : 'en';
    // "Device language" is kept as an empty choice: that is not one chosen here.
    final chosenHere = (prefs.get('to') ?? '').isNotEmpty;
    return SettingRow(
      icon: const AppIcon(Lucide.globe, size: 18),
      label: 'Your language',
      hint: Text(chosenHere ? 'Chosen here' : 'This device\'s own'),
      value: Text(languageName(to) ?? 'English'),
      onPress: () => push(context, (_) => _LanguagePage(
            title: 'Your language',
            chosen: {to},
            firstRow: ('Device language (${languageName(own)})', !chosenHere),
            onFirst: () => prefs.set('to', ''),
            onPick: (tag, _) => prefs.set('to', tag),
          )),
    );
  }
}

/// The other languages the person reads, kept a line each under `known`: texts in them are left as they came.
class _AlsoRead extends StatelessWidget implements PaneRow {
  const _AlsoRead({required this.prefs});
  final PluginPrefs prefs;

  @override
  Widget build(BuildContext context) {
    final known = TranslatePlugin.knownOf(prefs);
    return SettingRow(
      icon: const AppIcon(Lucide.bookOpen, size: 18),
      label: 'Languages you also read',
      hint: const Tr('Never translated.'),
      value: Text(known.isEmpty ? 'None' : known.map((k) => languageName(k) ?? k).join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
      onPress: () => push(context, (_) => _LanguagePage(
            title: 'Languages you also read',
            chosen: known.toSet(),
            many: true,
            onPick: (tag, on) {
              final next = {...TranslatePlugin.knownOf(prefs)};
              on ? next.add(tag) : next.remove(tag);
              prefs.set('known', next.join('\n'));
            },
          )),
    );
  }
}

/// The languages whose models are on the phone, each with Delete to give its 30 MB back.
class _OnThePhone extends StatefulWidget implements PaneRow {
  const _OnThePhone({required this.prefs});
  final PluginPrefs prefs;

  @override
  State<_OnThePhone> createState() => _OnThePhoneState();
}

class _OnThePhoneState extends State<_OnThePhone> {
  late Future<List<DeviceLanguage>> _languages = PluginRegistry.textHost.languages();

  void _reload() => setState(() => _languages = PluginRegistry.textHost.languages());

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final host = PluginRegistry.textHost;
    final to = TranslatePlugin.targetOf(widget.prefs, host);
    return FutureBuilder<List<DeviceLanguage>>(
      future: _languages,
      builder: (context, snap) {
        final here = [for (final l in snap.data ?? const <DeviceLanguage>[]) if (l.downloaded || l.fetching) l];
        if (here.isEmpty) {
          return SettingRow(
            icon: const AppIcon(Lucide.download, size: 18),
            label: 'Languages on this phone',
            hint: Text(snap.connectionState == ConnectionState.done ? 'None yet. A language is fetched the first time a text needs it.' : 'Looking…'),
          );
        }
        final rule = BorderSide(color: t.color('app-rule'), width: t.len('glacier-hairline'));
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < here.length; i++)
            DecoratedBox(
              // The card's own hairline between rows, as it draws between two of its rows (PaneSection).
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(border: i == 0 ? null : Border(top: rule)),
              child: SettingRow(
                icon: const AppIcon(Lucide.download, size: 18),
                label: languageName(here[i].tag) ?? here[i].tag,
                hint: Text(here[i].fetching && !here[i].downloaded ? 'Getting it ready…' : 'On this phone · about 30 MB'),
                // English (every translation goes through it) and your own are what the next text needs: they stay.
                control: here[i].tag == 'en' || here[i].tag == to || !here[i].downloaded
                    ? null
                    : RowAction(
                        onPress: () async {
                          await host.model(here[i].tag, delete: true);
                          if (mounted) _reload();
                        },
                        child: const Tr('Delete'),
                      ),
              ),
            ),
        ]);
      },
    );
  }
}

/// A searchable list of the languages there are models for: one picked ([many] false) or several.
class _LanguagePage extends StatefulWidget {
  const _LanguagePage({required this.title, required this.chosen, required this.onPick, this.many = false, this.firstRow, this.onFirst});
  final String title;
  final Set<String> chosen;
  final bool many;
  final void Function(String tag, bool on) onPick;

  /// A row before the languages, with whether it is the one chosen: the device's own language.
  final (String, bool)? firstRow;
  final VoidCallback? onFirst;

  @override
  State<_LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<_LanguagePage> {
  String _query = '';
  late final Set<String> _chosen = {...widget.chosen};
  late bool _first = widget.firstRow?.$2 ?? false;

  /// With many, a tap ticks or unticks and the page stays; with one, it is chosen and the page closes.
  void _pick(String tag) {
    if (widget.many) {
      final on = !_chosen.contains(tag);
      setState(() => on ? _chosen.add(tag) : _chosen.remove(tag));
      widget.onPick(tag, on);
      return;
    }
    widget.onPick(tag, true);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final q = _query.trim().toLowerCase();
    final list = [
      for (final e in translateLanguages.entries)
        if (q.isEmpty || e.key == q || e.value.$1.toLowerCase().contains(q) || e.value.$2.toLowerCase().contains(q)) e,
    ]..sort((a, b) => a.value.$1.compareTo(b.value.$1));
    return GhostPage(
      title: widget.title,
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          GlacierSearchField(placeholder: 'Search languages'.t, onValueChange: (v) => setState(() => _query = v)),
          SizedBox(height: t.space(3)),
          if (widget.firstRow != null && q.isEmpty) ...[
            PaneSection(children: [
              SettingRow(
                label: widget.firstRow!.$1,
                control: Pick(
                  checked: _first,
                  label: widget.firstRow!.$1,
                  onPress: () {
                    setState(() => _first = true);
                    widget.onFirst?.call();
                    Navigator.of(context).maybePop();
                  },
                ),
              ),
            ]),
            SizedBox(height: t.space(3)),
          ],
          if (list.isEmpty)
            Padding(
              padding: EdgeInsets.all(t.space(6)),
              child: Text('No language matches "$_query".', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            )
          else
            PaneSection(children: [
              for (final e in list)
                SettingRow(
                  label: e.value.$1,
                  hint: e.value.$2 == e.value.$1 ? null : Text(e.value.$2),
                  control: Pick(checked: (!_first || widget.many) && _chosen.contains(e.key), label: e.value.$1, onPress: () => _pick(e.key)),
                ),
            ]),
        ],
      ),
    );
  }
}
