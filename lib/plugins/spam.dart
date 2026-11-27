/// Spam filter: texts that look like spam, from numbers that are not contacts, in a section of their own (Matt,
/// 2026-11-14: "filtering out spam messages").
///
/// Off until it is chosen in Settings › Plugins: a filter that takes messages out of the list should be asked for.
/// The rules are few and can be said in a line each ([spamRules]): a text shows a sign or it does not, and a
/// conversation is spam when its newest text shows two of them, or three where it also holds a sign-in code, and
/// nobody in it is a contact. Everything is looked at on the phone; nothing is sent anywhere, deleted or blocked.
/// The conversation's row in Spam says which signs it showed, and "Not spam" puts it back in the main list, where
/// it stays whatever later texts in it say. A conversation the rules missed can be moved to Spam from its long
/// press.
///
/// The rules are a list of plain values, a pattern for the words or for the sender's address, so another list can
/// stand in for them (`SpamPlugin(rules: …)`), from this app or one day from outside it.
library;

import 'package:flutter/foundation.dart' show immutable;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import 'codes.dart';
import 'plugin.dart';
import 'ui.dart';

/// One sign that a text may be spam.
class SpamRule {
  const SpamRule({required this.id, required this.name, required this.says, required this.about, this.words, this.sender, this.strong = false}) : assert(words != null || sender != null);

  /// A sign hardly ever seen in a text that is not spam: it counts as two while "Strong signs count double" is on.
  final bool strong;

  final String id;

  /// What Settings calls it: "A link".
  final String name;

  /// How the row in Spam says it, after "Looks like spam:": "a link".
  final String says;

  /// What Settings says of it, in a line.
  final String about;

  /// A pattern for the text's words, letters in either case; or
  final String? words;

  /// a pattern for the address it came from.
  final String? sender;

  /// Whether the sign is in [facts]: its words in the text, or its pattern in any address the text came from.
  bool matches(MessageFacts facts) {
    final words = this.words;
    final sender = this.sender;
    if (words != null && _pattern(words).hasMatch(facts.text)) return true;
    return sender != null && facts.senders.any(_pattern(sender).hasMatch);
  }

  static final _patterns = <String, RegExp>{};
  static RegExp _pattern(String source) => _patterns[source] ??= RegExp(source, caseSensitive: false);
}

/// The signs, as the app ships them. Each phrase is a word or words of its own, never part of a longer word
/// ("locked" is not in "unlocked"), and no phrase is in two rules, so one fact about a text is one sign.
const List<SpamRule> spamRules = [
  SpamRule(
    id: 'link',
    name: 'A link',
    says: 'a link',
    about: 'The text has a web address in it.',
    words: r'(?:https?://|www\.)[^\s]+|(?<![@\w.-])[a-z0-9-]{2,}\.(?:com|net|org|info|biz|xyz|top|click|link|online|site|shop|store|vip|icu|buzz|club|win|live|ly|cc|co|io|me|app)(?:/[^\s]*)?(?![\w-]|\.[a-z])',
  ),
  SpamRule(
    id: 'email',
    name: 'Sent from an email address',
    says: 'sent from an email address',
    about: 'It came from an email address, not a phone number.',
    sender: r'@',
  ),
  SpamRule(
    id: 'prize',
    name: 'Prize wording',
    says: 'prize wording',
    about: 'It says you have won or been selected, or have a prize or a gift card to claim.',
    words: r"(?<![a-z0-9])(?:you(?:['’]ve| have)? won|winner|prize|lottery|jackpot|gift ?cards?|free gift|congratulations|been selected|claim (?:your|now|it|here))(?![a-z0-9])",
  ),
  SpamRule(
    id: 'pressure',
    name: 'Pressure to act',
    says: 'pressure to act',
    about: 'It says something is urgent, suspended, locked, unpaid or about to expire, or asks you to verify or confirm an account.',
    words: r'(?<![a-z0-9])(?:urgent(?! care)|urgently|immediately|act now|final notice|last chance|expires? (?:today|tonight|soon)|within \d+ ?(?:hours|hrs|hour|h)|suspended|suspension|locked|restricted|deactivated|unusual activity|suspicious activity|(?:verify|confirm|update) your (?:account|identity|information|details|payment|billing)|unpaid|overdue|outstanding balance|late fees?|pay now|penalt(?:y|ies)|avoid (?:additional |further |late )?(?:fees|charges|penalties|suspension)|(?:account|service) (?:has been|will be) (?:closed|terminated|cancell?ed|disabled))(?![a-z0-9])',
  ),
  SpamRule(
    id: 'money',
    name: 'A money offer',
    says: 'a money offer',
    about: 'It offers a loan, an investment, easy earnings or a refund that is waiting.',
    words: r'(?<![a-z0-9])(?:loans?|pre-?approved|debt relief|crypto|bitcoin|investments?|investing|earn \$?\d[\d,]*|\$\d[\d,]* (?:a|per|each|every) (?:day|week)|work from home|cash prize|refund (?:is |of \S+ is )?(?:pending|waiting|available|ready)|tax refund|(?:pay|send|payment|paid) (?:via|through|with|by|using) (?:zelle|venmo|cash ?app|gift ?cards?|bitcoin|crypto|usdt)|usdt|trading (?:platform|signals?|mentor)|guaranteed (?:returns?|profits?))(?![a-z0-9])',
  ),
  SpamRule(
    id: 'delivery',
    name: 'A delivery problem',
    says: 'a delivery problem',
    about: 'It says a package could not be delivered, is held, or needs an address or a fee.',
    words: r"(?<![a-z0-9])(?:(?:package|parcel|shipment|delivery)(?![a-z0-9]).{0,60}(?<![a-z0-9])(?:undeliverable|failed|on hold|held|rescheduled?|incomplete|incorrect|customs fees?|redelivery)|(?:could ?n[o'’]t|can ?not|can['’]t|unable to|failed to) (?:be )?deliver(?:ed)?)(?![a-z0-9])",
  ),
  // Seen on Matt's phone (2026-11-14): job offers, overseas numbers, invisible characters, lonely-hearts bait.
  SpamRule(
    id: 'job',
    name: 'A job offer out of nowhere',
    says: 'a job offer',
    about: 'A remote or part-time job, a recruiter who found your résumé, easy money an hour a day.',
    words: r'(?<![a-z0-9])(?:part-?time (?:remote |online )?(?:job|jobs|work|position|positions|opportunity|assistants?)|remote (?:online )?(?:job|work|position|opportunity)|recruit(?:er|ing|ment)|online partners|(?:resume|résumé) (?:has|have) been recommended|earn \$?\d{2,}[\d,]*(?:\s*[-–]\s*\$?\d+)?\s*(?:usd|dollars|a day|per day|daily))(?![a-z0-9])',
  ),
  SpamRule(
    id: 'abroad',
    name: 'From a number abroad',
    says: 'from a number abroad',
    about: 'The number is outside North America.',
    sender: r'^\+(?!1)\d',
  ),
  SpamRule(
    id: 'hidden',
    name: 'Hidden characters',
    says: 'hidden characters',
    about: 'The text has invisible characters in it, or letters from other alphabets standing in for ours, to slip past filters.',
    words: r'[\u200b\u200c\u200d\u2060\ufeff]|[\u0391-\u03c9\u0400-\u04ff\u13a0-\u13ff\ua640-\ua69f](?=[a-z])|(?<=[a-z])[\u0391-\u03c9\u0400-\u04ff\u13a0-\u13ff]',
  ),
  SpamRule(
    id: 'lonely',
    name: 'Lonely-hearts bait',
    says: 'lonely-hearts bait',
    about: 'Lonely nights, local singles, premium connections, discreet company.',
    words: r'(?<![a-z0-9])(?:lonely|hotties|singles near|local (?:girls|women|singles)|meet ?up tonight|instant meetup|premium connections|exclusive circle|discreet|companionship|distinguished gentlemen|social engagement services)(?![a-z0-9])',
  ),
  // Added 2026-11-16 (Matt: "Fix the filtering a bit more this message got through"): the scams most often texted in
  // 2025-26, each a sign of its own.
  SpamRule(
    id: 'toll',
    name: 'Tolls, tickets and the DMV',
    says: 'a toll or ticket notice',
    about: 'An unpaid toll, E-ZPass or SunPass, a traffic or parking ticket, a DMV notice or a licence about to be suspended.',
    strong: true,
    words: r'(?<![a-z0-9])(?:(?:unpaid|outstanding|overdue|pending) tolls?|toll (?:services?|balance|bill|charges?|violations?|notice|fees?|payment)|e-?z ?pass|sunpass|fastrak|peach ?pass|txtag|i-?pass|the toll roads|(?:dmv|department of motor vehicles)|traffic (?:violations?|tickets?|citations?)|parking (?:violations?|tickets?|citations?|fines?)|(?:driving|driver.?s)? ?(?:licen[cs]e|registration) (?:suspension|will be suspended|has been suspended))(?![a-z0-9])',
  ),
  SpamRule(
    id: 'replyy',
    name: 'The reply-Y trick',
    says: 'asks you to reply to turn on its link',
    about: '"Reply Y and reopen this message to activate the link", or "copy the link into your browser": ways round the phone switching off links from strangers.',
    strong: true,
    words: r'(?<![a-z0-9])(?:reply (?:with )?["“]?(?:y|yes|1)["”]?,? (?:and|then|to)? ?(?:re-?open|exit|return|activate|get|enable|open|click)|(?:activate|enable) the (?:link|url)|(?:copy|paste) (?:the|this) (?:link|url|address) (?:in|into|to) (?:your )?(?:browser|safari|chrome)|(?:link|url) (?:is|was) (?:not|in)active)',
  ),
  SpamRule(
    id: 'shortlink',
    name: 'A shortened link',
    says: 'a shortened link',
    about: 'A link through bit.ly, tinyurl and the like, which hides where it goes.',
    words: r'(?<![\w.])(?:bit\.ly|tinyurl\.com|t\.co|is\.gd|rb\.gy|cutt\.ly|tiny\.cc|ow\.ly|shorturl\.at|s\.id|t\.ly|rebrand\.ly|bl\.ink|qrco\.de|v\.gd|shorturl\.gg|u\.to|t2m\.io|2no\.co)/',
  ),
  SpamRule(
    id: 'opener',
    name: 'A wrong-number opener',
    says: 'a wrong-number opener',
    about: '"Hi, is this Anna?", "sorry to bother you", "do you remember me": how a stranger starts a conversation meant to become a scam.',
    words: r"^\W*(?:hi|hello|hey|hiya|good (?:morning|afternoon|evening))\b[^a-z]{0,12}(?:is this|are you|it'?s been|how are you|how have you been|long time)|wrong number|sorry to (?:bother|disturb) you|(?:did|do) you (?:still )?remember me|i got your (?:number|contact) from|is this (?:still )?(?:mr|ms|mrs|miss|dr)\.?\s",
  ),
  SpamRule(
    id: 'brand',
    name: 'Says it is a company',
    says: 'names a company',
    about: 'It names a bank, a carrier or a well-known company. The real ones text from a short code or are in your contacts; a stranger\'s number saying it is Amazon is not Amazon.',
    words: r'(?<![a-z0-9])(?:amazon|apple ?(?:id|pay|support)|icloud|paypal|usps|fedex|ups|dhl|wells ?fargo|chase (?:bank|card|alert|fraud)|bank of america|citi ?bank|capital one|netflix|irs|social security|medicare|venmo|zelle|cash ?app|coinbase|binance|geek squad|norton|mcafee|microsoft|walmart|costco|best ?buy|verizon|at&t|t-?mobile|comcast|xfinity|spectrum)(?![a-z0-9])',
  ),
];

/// How strict the filter is, and what else the person has set (Settings › Spam filter; Matt, 2026-11-16: "detailed
/// settings for the filtering with strictness settings and tweak options for everything").
@immutable
class SpamTuning {
  const SpamTuning({
    this.level = 'balanced',
    this.off = const {},
    this.codesLenient = true,
    this.shortLenient = true,
    this.strongDouble = true,
    this.alwaysWords = const [],
    this.neverWords = const [],
    this.alwaysSenders = const [],
    this.neverSenders = const [],
  });

  /// What the app ships with.
  static const standard = SpamTuning();

  factory SpamTuning.of(PluginPrefs prefs) => SpamTuning(
        level: prefs.get('level') ?? 'balanced',
        off: {for (final r in spamRules) if (!prefs.flag('rule_${r.id}')) r.id},
        codesLenient: prefs.flag('codes_lenient'),
        shortLenient: prefs.flag('short_lenient'),
        strongDouble: prefs.flag('strong_double'),
        alwaysWords: wordsOf(prefs, 'always_words'),
        neverWords: wordsOf(prefs, 'never_words'),
        alwaysSenders: wordsOf(prefs, 'always_senders'),
        neverSenders: wordsOf(prefs, 'never_senders'),
      );

  /// relaxed, balanced, strict or strictest.
  final String level;

  /// The rules switched off, by id.
  final Set<String> off;

  /// A text with a sign-in code needs one sign more.
  final bool codesLenient;

  /// A text from a company's short code needs one sign more.
  final bool shortLenient;

  /// A strong sign counts as two.
  final bool strongDouble;

  /// Words that make a text spam whatever else it says, and words that keep it out.
  final List<String> alwaysWords, neverWords;

  /// Numbers, addresses or names always spam, and never.
  final List<String> alwaysSenders, neverSenders;

  /// The signs it takes before allowances: three, two, two, one.
  int get base => switch (level) {
        'relaxed' => 3,
        'strictest' => 1,
        _ => 2,
      };

  /// Strict makes no allowance for sign-in codes and short codes.
  bool get allowances => level != 'strict' && level != 'strictest';

  static const levels = [
    SettingOption('relaxed', 'Relaxed', 'Three signs before a text is spam. Little is caught by mistake; some spam gets through.'),
    SettingOption('balanced', 'Balanced', 'Two signs, as the app ships. One more for a text with a sign-in code, or from a company\'s short code.'),
    SettingOption('strict', 'Strict', 'Two signs, with no allowance for sign-in codes or short codes.'),
    SettingOption('strictest', 'Strictest', 'Any one sign. Catches the most; check Spam now and then for a text that is not.'),
  ];
}

bool _hasWord(String text, String word) => RegExp('(?<![a-z0-9])${RegExp.escape(word)}(?![a-z0-9])', caseSensitive: false).hasMatch(text);

/// Whether [sender] is one of [list]: a number by its last ten digits, anything else by its words.
bool senderListed(Iterable<String> senders, List<String> list) {
  for (final want in list) {
    final digits = want.replaceAll(RegExp(r'\D'), '');
    for (final s in senders) {
      final have = s.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 4 && have.length >= 4) {
        final a = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
        final b = have.length > 10 ? have.substring(have.length - 10) : have;
        if (a == b) return true;
      } else if (s.toLowerCase().contains(want.toLowerCase())) {
        return true;
      }
    }
  }
  return false;
}

/// What the rules make of one text: the signs it shows, and whether that is enough.
class SpamVerdict {
  const SpamVerdict(this.signs, this.needed, {this.score, this.forced, this.listed});

  /// The rules it matched, in the order they are listed.
  final List<SpamRule> signs;

  /// How much it takes: two, or three for a text with a sign-in code in it, as the app ships.
  final int needed;

  /// What its signs add up to; their number where not given.
  final int? score;

  /// Decided by the person's own lists, whatever the signs say: true spam, false never.
  final bool? forced;

  /// The word or sender of theirs that decided it.
  final String? listed;

  bool get spam => forced ?? (score ?? signs.length) >= needed;

  /// The signs in words: "a link, prize wording".
  String get why => forced == true ? (listed ?? 'on your list') : signs.map((s) => s.says).join(', ');
}

/// Asks [rules] about a text. Who sent it is not asked here: a contact's text is never looked at ([SpamPlugin]).
SpamVerdict judgeSpam(MessageFacts facts, {List<SpamRule> rules = spamRules, SpamTuning tuning = SpamTuning.standard}) {
  if (senderListed(facts.senders, tuning.neverSenders)) return const SpamVerdict([], 0, forced: false);
  for (final w in tuning.neverWords) {
    if (_hasWord(facts.text, w)) return const SpamVerdict([], 0, forced: false);
  }
  if (senderListed(facts.senders, tuning.alwaysSenders)) return const SpamVerdict([], 0, forced: true, listed: 'a sender on your list');
  for (final w in tuning.alwaysWords) {
    if (_hasWord(facts.text, w)) return SpamVerdict(const [], 0, forced: true, listed: 'says "$w"');
  }
  final short = facts.senders.any((a) => RegExp(r'^\d{4,6}$').hasMatch(a.replaceAll(RegExp(r'[\s-]'), '')));
  // A company naming itself from its own short code is just the company.
  final signs = [for (final rule in rules) if (!tuning.off.contains(rule.id) && !(short && rule.id == 'brand') && rule.matches(facts)) rule];
  final score = signs.fold<int>(0, (n, r) => n + (r.strong && tuning.strongDouble ? 2 : 1));
  // A sign-in code often comes with a link and "if this wasn't you, act immediately": it takes one sign more.
  // A short code (five or six digits) is a company that registered it with the carriers: their bills and reminders
  // speak of paying and of links, and take one sign more (Matt's Verizon and urgent care texts, 2026-11-14).
  final allow = tuning.allowances;
  final needed = tuning.base + (allow && tuning.codesLenient && signInCode(facts.text) != null ? 1 : 0) + (allow && tuning.shortLenient && short ? 1 : 0);
  return SpamVerdict(signs, needed, score: score);
}

/// Whether [facts] are a chat on another network (Signal's, Telegram's), by its number (ListPlugins.chatThread).
bool isNetworkChat(MessageFacts facts) => facts.thread <= -(0x10000000000);

class SpamPlugin extends GhostPlugin {
  const SpamPlugin({this.rules = spamRules});

  /// The signs it looks for. Another list stands in for the app's own.
  final List<SpamRule> rules;

  /// The tag a text that looks like spam is given; its detail is the signs it showed.
  static const tag = 'spam';

  /// The section's id.
  static const section = 'spam';

  @override
  String get id => 'spam';

  @override
  String get name => 'Spam filter';

  @override
  String get description => 'Texts that look like spam, from numbers not in your contacts, go to a Spam section.';

  @override
  LucideIcon get icon => Lucide.triangleAlert;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.safety;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['safety', 'filters'];

  @override
  String get tagline => 'Texts that look like spam go to a tab of their own.';

  @override
  List<String> get adds => const ['A Spam tab in the list', '"Not spam" on a conversation, to put it back for good', 'How strict it is, and lists of your own'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.messageSquare, 'Texts from numbers not in your contacts', 'Read on this phone to judge them. Nothing is sent, deleted or blocked.'),
        PluginReach(Lucide.contactRound, 'Your contacts, so theirs are never judged'),
      ];

  /// On from the start, its kind hidden until shown (Matt, 2026-11-14: "a filter dropdown where showing spam, political
  /// messages, and debt collectors are filtered out by default"): it was off until chosen, and a tab of its own.
  @override
  bool get onByDefault => true;

  /// Out of Spam for good; and, while "Learn from what you move" is on, their sender is never spam again.
  static PluginAction _notSpam(int thread, [List<String> senders = const []]) => PluginAction(
        label: 'Not spam',
        icon: Lucide.check,
        run: (host) {
          host.move(thread, null);
          if (senders.isNotEmpty && host.prefs.flag('learn')) _learn(host.prefs, senders, keep: 'never_senders', drop: 'always_senders');
          host.say('Moved to Messages');
        },
      );

  /// Adds [senders] to the list kept under [keep] and takes them out of the one under [drop]: a sender is always
  /// spam or never spam, not both.
  static void _learn(PluginPrefs prefs, List<String> senders, {required String keep, required String drop}) {
    final kept = wordsOf(prefs, keep);
    final dropped = wordsOf(prefs, drop);
    for (final s in senders) {
      if (!kept.contains(s)) kept.add(s);
      dropped.remove(s);
    }
    prefs.set(keep, kept.join('\n'));
    prefs.set(drop, dropped.join('\n'));
  }

  @override
  List<TunedClassifier> get tuned => [
        (facts, prefs) {
          // Never a contact's, and never the person's own words.
          if (facts.contact || facts.outgoing == true) return const [];
          if (facts.group && !prefs.flag('groups')) return const [];
          if (isNetworkChat(facts) && !prefs.flag('networks')) return const [];
          final verdict = judgeSpam(facts, rules: rules, tuning: SpamTuning.of(prefs));
          return verdict.spam ? [Tag(tag, verdict.why)] : const [];
        },
      ];

  @override
  List<ListSection> get sections => [
        ListSection(
          id: section,
          label: 'Spam',
          icon: Lucide.triangleAlert,
          // A kind for the list's filter, hidden until shown (lib/plugins/kinds.dart says how kinds work).
          filter: true,
          hidden: true,
          takes: (facts, tags, prefs) => tags.has(tag),
          row: (facts, tags, prefs) {
            final why = tags.detail(tag);
            return RowLook(caption: why == null ? 'Moved here by you' : 'Looks like spam: $why', word: _notSpam(facts.thread, facts.senders));
          },
        ),
      ];

  @override
  List<SlotFill> get slots => [
        // Over the Spam list: what it is, and that nothing is lost.
        Slots.aboveList.fill((context, place, prefs) => [
              if (place.section == section) const PluginNote('Texts that look like spam, from numbers not in your contacts. Nothing here is deleted or blocked.'),
            ]),
        // A conversation's long press in the list: out of Spam for good, or into it by hand.
        Slots.conversationMenu.fill((place, prefs) {
          final thread = place.facts.thread;
          final senders = place.facts.senders;
          return [
            if (place.section == section)
              _notSpam(thread, senders)
            else if (!place.facts.contact)
              PluginAction(
                label: 'Move to Spam',
                icon: Lucide.triangleAlert,
                run: (host) {
                  host.move(thread, section);
                  if (host.prefs.flag('learn')) _learn(host.prefs, senders, keep: 'always_senders', drop: 'never_senders');
                  host.say('Moved to Spam');
                },
              ),
          ];
        }),
      ];

  /// A conversation in Spam is muted as its newest text is seen, so what comes in it next arrives quietly; and marked
  /// read, where the person asked for that.
  @override
  List<IncomingRule> get incoming => [
        (facts, tags, at, prefs) => [
              if (at == section && prefs.flag('mute')) const MuteNotification(),
              if (at == section && prefs.flag('read', fallback: false)) const MarkRead(),
            ],
      ];

  /// A section of its own in Settings, while the filter is on.
  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'red',
        intro: 'What looks like spam, from numbers that are not in your contacts, in a tab of its own.',
        summary: (prefs) {
          final level = SpamTuning.levels.firstWhere((o) => o.value == (prefs.get('level') ?? 'balanced'), orElse: () => SpamTuning.levels[1]).label;
          return '$level · ${prefs.flag('mute') ? 'muted' : 'still notifies'}';
        },
      );

  @override
  List<PluginSetting> get settings => [
        const PluginSetting.heading(label: 'How strict', hint: 'Each text from a number that is not in your contacts is looked at for the signs further down. How many it takes:'),
        const PluginSetting.choice(key: 'level', label: 'Strictness', options: SpamTuning.levels, choice: 'balanced'),
        const PluginSetting.heading(label: 'Allowances'),
        const PluginSetting.toggle(key: 'strong_double', label: 'Strong signs count double', hint: 'Tolls and tickets, the reply-Y trick and hidden characters are almost never in a real text: one is as good as two.', icon: Lucide.flame),
        const PluginSetting.toggle(key: 'codes_lenient', label: 'Go easy on sign-in codes', hint: 'A text with a code in it needs one sign more: real codes often say "if this wasn\'t you, act now" beside a link. Not at Strict or Strictest.', icon: Lucide.keyRound),
        const PluginSetting.toggle(key: 'short_lenient', label: 'Go easy on short codes', hint: 'A text from a five- or six-digit number (a company registered with the carriers) needs one sign more. Not at Strict or Strictest.', icon: Lucide.store),
        const PluginSetting.heading(label: 'Signs to look for', hint: 'Switch off a sign that catches texts you want.'),
        for (final rule in rules) PluginSetting.toggle(key: 'rule_${rule.id}', label: rule.name, hint: rule.strong ? '${rule.about} A strong sign.' : rule.about),
        const PluginSetting.heading(label: 'Your own lists', hint: 'These decide before any sign is counted. Never wins over always.'),
        const PluginSetting.words(key: 'always_words', label: 'Always spam: words', hint: 'A text with any of these, from someone not in your contacts, is spam.', placeholder: 'crypto, sweepstakes', icon: Lucide.ban),
        const PluginSetting.words(key: 'never_words', label: 'Never spam: words', hint: 'A text with any of these is never spam, whatever else it says.', placeholder: 'your school, your work', icon: Lucide.shieldCheck),
        const PluginSetting.words(key: 'always_senders', label: 'Always spam: senders', hint: 'Numbers, email addresses or names. A number matches by its last ten digits.', placeholder: '+1 555 010 0000', icon: Lucide.userX),
        const PluginSetting.words(key: 'never_senders', label: 'Never spam: senders', hint: 'Numbers, email addresses or names that are never spam, contact or not.', placeholder: '72975, alerts@bank.example', icon: Lucide.userCheck),
        const PluginSetting.toggle(key: 'learn', label: 'Learn from what you move', hint: '"Move to Spam" puts its sender on the always list, "Not spam" on the never list.', icon: Lucide.sparkles),
        const PluginSetting.heading(label: 'Where it looks'),
        const PluginSetting.toggle(key: 'groups', label: 'Group chats with strangers', hint: 'A group in which nobody is in your contacts is looked at too.', icon: Lucide.users),
        const PluginSetting.toggle(key: 'networks', label: 'Signal and Telegram', hint: 'Chats there from people you have not added, as texts are.', icon: Lucide.messageSquare),
        const PluginSetting.heading(label: 'When spam comes'),
        const PluginSetting.toggle(
          key: 'mute',
          label: 'Mute conversations in Spam',
          hint: 'Later texts in a conversation that is in Spam arrive without a notification. "Not spam" turns them back on.',
          icon: Lucide.bell,
        ),
        const PluginSetting.toggle(key: 'read', label: 'Mark spam as read', hint: 'So it adds nothing to the counts on the tabs and the app\'s icon.', icon: Lucide.checkCheck, fallback: false),
        const PluginSetting.note(
          label: 'On this phone only',
          hint: 'Texts are looked at here and sent nowhere. Nothing is deleted or blocked: a conversation in Spam opens as any other, and "Not spam" puts it back for good.',
          icon: Lucide.lock,
        ),
      ];
}
