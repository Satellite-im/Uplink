/// Kinds of text: what a text from someone who is not a contact is about, sorted on the phone so the list can show
/// or hide each kind (Matt, 2026-11-14: "I'd like to have tabs for messages with a intelligent spam filter, debt
/// collectors, political messages, payment reminders, tracking information, etc ... I'm thinking a filter dropdown
/// where showing spam, political messages, and debt collectors are filtered out by default", and "also add in
/// blocking of door to door sales and other sales messages like tree trimming, gutter cleaning, buying the house,
/// etc").
///
/// Each kind is a section of the list that is a filter, not a tab ([ListSection.filter]): its conversations stay in
/// Messages while it is shown, and leave it while it is hidden; the filter menu beside the tabs says which, and can
/// show one kind alone. Political texts, debt collectors and sales are hidden until shown; payment reminders,
/// deliveries and appointments are shown. Spam is the Spam filter's (spam.dart), a kind like these.
///
/// A kind is a few patterns for a text's words, said in a line each in Settings. A text is of a kind when it shows
/// one of its strong signs, or two of its others. Nobody in your contacts is ever sorted, nor your own words; a
/// kind that is shown (a delivery, a reminder) does not take a text the Spam filter would call spam, so a fake
/// "your parcel is held, pay the fee" goes to Spam. Nothing is sent anywhere, deleted or blocked: a hidden kind is
/// one press away ("N hidden" at the list's foot), and "Not political" on a conversation puts it back in Messages
/// for good.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import 'plugin.dart';
import 'spam.dart';

/// One kind of text.
class TextKind {
  const TextKind({
    required this.id,
    required this.label,
    required this.one,
    required this.icon,
    required this.about,
    required this.strong,
    this.weak = const [],
    this.hidden = false,
    this.notSpam = false,
  });

  /// Its section's id.
  final String id;

  /// What the filter menu and its tab say: "Political".
  final String label;

  /// One conversation of it, for "Not …": "political".
  final String one;
  final LucideIcon icon;

  /// What Settings says of it.
  final String about;

  /// Patterns any one of which makes a text this kind.
  final List<String> strong;

  /// Patterns two of which make a text this kind.
  final List<String> weak;

  /// Hidden from Messages until the person shows it.
  final bool hidden;

  /// A text the Spam filter would call spam is not this kind: it is shown, so a scam dressed as it must not be.
  final bool notSpam;

  static final _patterns = <String, RegExp>{};
  static RegExp _re(String source) => _patterns[source] ??= RegExp(r'(?<![a-z0-9])(?:' + source + r')(?![a-z0-9])', caseSensitive: false);

  /// Whether [text] is this kind: one strong sign, one of [extra] (the person's own words for it), or [weakNeeded]
  /// of the others (none at all where that is 0).
  bool matches(String text, {int weakNeeded = 2, List<String> extra = const []}) {
    for (final s in strong) {
      if (_re(s).hasMatch(text)) return true;
    }
    for (final w in extra) {
      if (_re(RegExp.escape(w)).hasMatch(text)) return true;
    }
    if (weakNeeded <= 0) return false;
    var n = 0;
    for (final w in weak) {
      if (_re(w).hasMatch(text) && ++n >= weakNeeded) return true;
    }
    return false;
  }
}

/// The kinds, in the order a text is asked about them: the first that takes it has it.
const List<TextKind> textKinds = [
  TextKind(
    id: 'debt',
    label: 'Debt collectors',
    one: 'a debt collector',
    icon: LucideMore.circleDollarSign,
    hidden: true,
    // A toll or DMV "final notice" with a link to pay is a scam: Spam's, not a collector's.
    notSpam: true,
    about: 'Collection agencies: an attempt to collect a debt, an account in collections, settling a balance.',
    strong: [
      r'(?:attempt|trying) to collect a debt',
      r'debt collector',
      r'collections? (?:agency|department|account|notice)',
      r'(?:placed|referred|sent|assigned) (?:in|into|to|for) collections?',
      r'settle (?:your|this|the) (?:debt|balance|account)',
      r'(?:resolve|settle) (?:your|this) (?:outstanding )?(?:debt|balance)',
      r'reported to (?:the )?credit bureaus?',
      // Debt relief sellers and hardship plans (seen on Matt's phone, 2026-11-14).
      r'debt (?:relief|consolidation|settlement|help|resolution)',
      r'(?:pds|national|freedom|accredited) debt',
      r'financial hardship',
      r'(?:an )?option tied to the amount',
    ],
    weak: [r'past due', r'delinquent', r'outstanding balance', r'collections?', r'creditor', r'settlement offer', r'credit (?:report|score|bureau)'],
  ),
  TextKind(
    id: 'political',
    label: 'Political',
    one: 'political',
    icon: LucideMore.landmark,
    hidden: true,
    about: 'Campaigns, candidates and causes: a vote, a ballot, a donation, "paid for by".',
    strong: [
      r'paid for by',
      r'election day',
      r'(?:mail-?in|absentee|your) ballots?',
      r'polls? (?:open|close|are open|location)',
      r'chip in',
      // Ways to vote, not voting on where to eat.
      r'(?:vote|voting) (?:early|yes on|no on|by mail|in person)',
      r'(?:register(?:ed)?|make a plan) to vote',
      r'(?:democrats?|republicans?|gop|dnc|rnc|maga)',
      r'(?:presidential|senate|congressional|gubernatorial|midterm|primary) (?:race|election|campaign)',
      // "Surveys" and "polls" on issues, which are campaigns' (seen on Matt's phone, 2026-11-14).
      r'(?:local|important|community) issues?',
      r'issues? (?:survey|poll)',
      r'research-?polls?',
      r'gauging (?:views|opinions)',
      r'campaign updates',
      r'residents (?:across|of) (?:our|the|your)',
      // Advocacy texts, a cause asking you to lean on your lawmakers (Matt's screenshot, 2026-11-17: "Tell Congress where
      // you stand on smoke-free nicotine options").
      r'(?:tell|urge|ask|call on|contact|write to|email|call) (?:congress|your (?:senators?|representatives?|reps?|congress(?:man|woman|person)?|lawmakers?|legislators?|elected officials?))',
      r'(?:take action|make your voice heard|add your (?:name|voice))',
    ],
    weak: [r'vote', r'election', r'campaign', r'candidates?', r'donat(?:e|ion|ions)', r'congress(?:man|woman)?', r'senators?', r'governor', r'president', r'petition', r'rally', r'endorse', r'where you stand on'],
  ),
  TextKind(
    id: 'sales',
    label: 'Sales & solicitors',
    one: 'sales',
    icon: Lucide.megaphone,
    hidden: true,
    about: 'Door-to-door and other selling: tree trimming, gutters, roofs, solar, "we buy houses", offers and promo codes.',
    strong: [
      r"(?:we(?:'| a)re|we have a crew|our crew is|we will be) (?:working |out )?in your (?:area|neighbou?rhood)",
      r'tree (?:trimmings?|removals?|services?|cutting|work|projects?|care)',
      r'(?:local )?arborists?',
      r'gutters? (?:cleaning|guards?|replacement|install)',
      r'(?:buy|buying|purchase|purchasing) your (?:house|home|property|land)',
      r'(?:traditional listing|direct sale)',
      r'(?:cash|an offer|a cash offer) (?:for|on) your (?:house|home|property|land)',
      r'(?:interested in|thought about|considering) selling (?:your )?(?:house|home|property|land)?',
      r'we buy (?:houses|homes|property)',
      r'roof(?:ing)? (?:inspections?|replacement|repairs?|estimates?)',
      r'no-?cost (?:roof |home )?(?:inspections?|estimates?|quotes?)',
      r'(?:kitchen|bathroom|shower|home) (?:& |and )?(?:bathroom )?remodels?',
      r'(?:health |life |auto |car |home )?insurance (?:quotes?|plans?)',
      r'(?:want|like|need|interested in) (?:a |some )?(?:free )?quotes?',
      r'(?:send|get) you (?:a few |some |a )?(?:free )?quotes?',
      r'pre-?approved (?:for )?\$?\d',
      r'(?:tickets are )?selling fast',
      r'eligible to add',
      r'solar (?:panels?|savings|consultation|program)',
      r'(?:pressure|power) washing',
      // Matt's screenshot, 2026-11-14: "a free attic insulation, window, or gutter service quote ... while we're in
      // your area".
      r'(?:attic |home |spray foam )?insulation',
      r'gutter (?:service|work|repair)s?',
      r'(?:hvac|furnace|ac|a/c|heat pump|water heater) (?:tune-?up|service|install(?:ation)?|replacement|quote)s?',
      r'free .{0,60}quote',
      r'(?:lawn|landscaping|yard) (?:care|service|services|maintenance)',
      r'pest control',
      r'window (?:cleaning|replacement)',
      r'driveway (?:sealing|paving|repair)',
      r'free (?:estimate|estimates|quote|quotes|inspection|consultation)',
      r'promo code',
      // Seen on Matt's phone, 2026-11-14: health plans, loans, PR and websites sold by text, and brands' pushes.
      r'(?:health|ppo|medical|dental) (?:plans?|options?|insurance|coverage)',
      r'(?:low(?:er)?|no) (?:monthly|deductibles?|copays?|premiums?)',
      r'(?:price|cost) estimate',
      r'(?:simple|quick|few|free) quotes?',
      r'(?:pricing|quotes?) for',
      r'compar(?:e|ing) (?:options|plans|terms)',
      r'(?:access|get|qualify for|borrow) up to \$?[\d,.]+k?',
      r'new low rates',
      r'\$[\d,]+ for \$?\d+/mo',
      r'(?:get you )?featured in',
      r'(?:pr|media) (?:consultant|researcher|agency|feature)',
      r'editors are looking',
      r'(?:a |new |fresh )+website',
      r'(?:make|build) (?:you )?(?:one|it) (?:live )?for free',
      r'last chance',
      r'walk-?in or book',
      r'(?:usa today|business insider|forbes|yahoo finance) feature',
      r'online reputation',
      r'better value when',
      r"don'?t miss out",
      r'free trial',
      r'save up to',
      r'keep you in the loop',
      r'(?:events|specials),? (?:and|&) ',
      r'(?:sale|offer) ends',
      r'\d+% off',
      r'shop now',
    ],
    // "Reply STOP to opt out" is one sign however many of its words a text has.
    weak: [r'neighbou?rhood', r'your (?:home|house|property)', r'special offer', r'limited time', r'discounts?', r'deals?', r'(?:reply|text|txt) ?stop|stop ?to ?(?:end|opt|quit|cancel|unsubscribe)|unsubscribe|opt[ -]?out', r'book (?:now|today)', r'\$\d+(?:\.\d\d)?/mo', r'quotes?'],
  ),
  TextKind(
    id: 'scams',
    label: 'Likely scams',
    one: 'a likely scam',
    icon: Lucide.triangleAlert,
    hidden: true,
    about: 'Wrong-number openers, strangers who are single, job offers out of nowhere, a club that wants you.',
    strong: [
      // Seen on Matt's phone, 2026-11-14.
      r'years old and (?:still )?single',
      r'long time no see',
      r'(?:i )?sent you (?:the )?pictures from',
      r'one day we.ll meet',
      r'(?:largest|exclusive) private club',
      r'beautiful women',
      r'(?:part-?time|work-?from-?home|remote|outside sales) (?:role|job|position|opportunity)',
      r"(?:we'?re|we are) hiring",
      r'(?:technical )?recruiter with',
      r'(?:virtual|online) interview',
      r'(?:your )?(?:resume|résumé) (?:for|was|has been) (?:\S+ ){0,6}?reviewed',
      r'available to travel anytime',
    ],
  ),
  TextKind(
    id: 'reminders',
    label: 'Payment reminders',
    one: 'a payment reminder',
    icon: LucideMore.receipt,
    notSpam: true,
    about: 'Bills and payments: an amount due, a due date, autopay, a statement that is ready.',
    strong: [
      r'payment (?:is )?(?:due|reminder|scheduled|received|confirmation)',
      r'(?:amount|balance|minimum payment) due',
      r'due (?:on|by) (?:\d|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|mon|tue|wed|thu|fri|sat|sun|today|tomorrow)',
      r'autopay',
      r'(?:your )?(?:bill|statement) is (?:ready|available|due)',
      r'(?:rent|premium|invoice|bill) (?:is )?due',
      r'(?:past[- ]due|unpaid) (?:bill|balance|payment|amount)',
      r'(?:issues?|problems?|trouble) collecting (?:your )?payment',
      r'(?:scheduled for |service )interruption',
    ],
    weak: [r'bill', r'statement', r'payment', r'past due', r'balance', r'account ending', r'pay (?:now|online|here)'],
  ),
  // Asked before deliveries, so "your Dasher is on the way" is food, not a parcel (Matt, 2026-11-14: "Add a food
  // delivery text filter too").
  TextKind(
    id: 'food',
    label: 'Food delivery',
    one: 'a food delivery',
    icon: LucideMore.utensils,
    notSpam: true,
    about: 'Takeout and groceries: DoorDash, Uber Eats, Grubhub, Instacart, a driver or Dasher on the way, your food is here.',
    strong: [
      r'door-?dash|uber ?eats|grubhub|postmates|instacart|seamless|caviar|gopuff|deliveroo|just ?eat|skip ?the ?dishes|waitr|favor delivery|shipt',
      r'(?:your )?dasher',
      r'(?:your )?(?:food|meal|takeout|take-out|groceries|grocery order|pizza) (?:is|has|will be|was) (?:here|on (?:its|the) way|ready|arriving|being prepared|delivered|picked up|out for delivery)',
      r'(?:restaurant|kitchen) (?:is preparing|has (?:started|accepted)|confirmed) your order',
      r'(?:your )?(?:driver|courier|shopper) (?:is|has) (?:on (?:the|their) way|arriving|arrived|picked up|nearby|outside|here|almost there)',
      r'(?:leave|left) (?:it |your order |the food )?at (?:the|your) door',
      r'order (?:is )?ready for pick-?up',
      r'dropped off your .{0,30}(?:groceries|order|food)',
    ],
    weak: [r'order', r'food', r'restaurant', r'driver', r'pick(?:ed)?-?up', r'tip', r'eta', r'minutes? away', r'meal', r'groceries'],
  ),
  TextKind(
    id: 'deliveries',
    label: 'Deliveries & tracking',
    one: 'a delivery',
    icon: LucideMore.package,
    notSpam: true,
    about: 'Orders and parcels: shipped, out for delivery, delivered, a tracking number.',
    strong: [
      r'out for delivery',
      r'(?:has been|was|is|were|should be) delivered',
      r'delivered today',
      r'(?:order|package|parcel|delivery) (?:was|has been) (?:dropped off|left)',
      r'(?:has |have )?(?:shipped|been shipped)',
      r'tracking (?:number|#|no\.?|id|info|information|link|update)',
      r'track your (?:package|order|shipment|parcel|delivery)',
      r'(?:package|parcel|order|shipment) (?:is )?(?:on its way|arriving|arrives|will arrive|delayed)',
      r'arriving (?:today|tomorrow|by)',
      r'expected (?:delivery|arrival)',
    ],
    // A carrier's name alone is not a delivery: their sign-in codes and alerts are not.
    weak: [r'order', r'package', r'parcel', r'shipment', r'delivery', r'arriv(?:e|ing|al)', r'ups|fedex|usps|dhl|amazon|ontrac|lasership|dasher'],
  ),
  TextKind(
    id: 'appointments',
    label: 'Appointments',
    one: 'an appointment',
    icon: LucideMore.calendarCheck,
    notSpam: true,
    about: 'Bookings and reminders: an appointment, a reservation, "reply C to confirm".',
    strong: [
      r'appointments? (?:reminder|confirmed|confirmation|is (?:on|at|scheduled|tomorrow|today)|on|at|for|with)',
      r'reply (?:c|y|yes|1) to confirm',
      r'(?:your )?(?:reservation|booking) (?:is )?(?:confirmed|for|on|at|reminder)',
      r'(?:check-?in|check in) (?:is )?(?:at|opens|now open)',
      r'reminder: you have',
      r'(?:your )?appt\.?',
      r'(?:service professional|technician|tech) .{0,120}(?:is )?on (?:the|their|his|her) way',
      r"i'?m (?:en|in) route",
      r'(?:join|joining) your video visit',
      r'(?:your )?(?:chat|call|visit) with us is coming up',
      r'your table is ready',
      r'(?:return to|come to) the host stand',
    ],
    weak: [r'appointment', r'reservation', r'booking', r'reschedule', r'clinic', r'dentist', r'doctor', r'scheduled for'],
  ),
  // Last, and shown: what a company tells you, which is no person's (Matt, 2026-11-14: "there is still a lot of
  // messages that are unsorted that are spam or confirmation based things that land in personal messages").
  TextKind(
    id: 'notices',
    label: 'Notifications & receipts',
    one: 'a notification',
    icon: Lucide.bell,
    notSpam: true,
    about: 'Receipts, sign-in and security alerts, subscribed and unsubscribed, surveys, balances, documents ready.',
    strong: [
      r'(?:successfully )?(?:been )?unsubscribed',
      r'(?:reply|text|txt) start to',
      r'no (?:more|longer receive) (?:any )?(?:more )?messages',
      r'welcome to [a-z0-9]',
      r'you will receive up to',
      r'msg(?:\.| )?(?:&|and) ?data rates',
      r'msg frequency',
      r'thanks? (?:you )?for (?:your purchase|ordering|your order|visiting|parking|using|choosing|shopping)',
      r'(?:view|see) your (?:receipt|tickets|order)',
      r'receipt',
      r'(?:take|begin|share|complete) (?:a|our|the|this)? ?(?:quick |short )?survey',
      r'survey',
      r'(?:your )?feedback (?:is important|matters)',
      r'(?:rate|review) (?:your visit|my work|us|your experience)',
      r'tell us how we did',
      r'how did we do',
      r'share your thoughts',
      r'two[- ]factor',
      r'sign(?:ed)?[- ]in (?:from|to)',
      r'(?:pin|password|settings) (?:was|were|has been|have) changed',
      r"(?:didn'?t make this request|if this wasn'?t you|if you did not request)",
      r'verification link',
      r'(?:mobile )?authenticator',
      r'deposit of \$[\d,.]+',
      r'available balance',
      r"you'?ll be charged",
      r'return was accepted',
      r'documents?(?:\(s\))? (?:are|is) available',
      r'(?:subscriber )?profile has been deleted',
      r'membership expires',
      r'(?:card|payment method) on file',
      r'(?:invited you|rsvp)',
      r'(?:service|pickup|collection) (?:.{0,40} )?(?:is |has been )?delayed',
      r'your feedback',
      r'reply yes to (?:continue|confirm|join)',
      r'sent you a (?:new )?snap',
      r'free message',
      r'network msg',
      r'response has been recorded',
      r'(?:your )?(?:delivery|order) (?:from .{1,40} )?has been (?:canceled|cancelled)',
      r'(?:test )?results? (?:are ready|with you|is ready)',
      r'(?:the )?referral',
      r'patient alerts',
      r'automated (?:system|message)',
    ],
    weak: [r'(?:reply|txt|text) (?:help|stop)', r'opt[ -]?(?:out|in)', r'your account', r'account', r'notifications?', r'alerts?'],
  ),
];

class KindsPlugin extends GhostPlugin {
  const KindsPlugin({this.kinds = textKinds, this.spam = spamRules});

  final List<TextKind> kinds;

  /// What a shown kind asks before taking a text: whether the Spam filter would call it spam.
  final List<SpamRule> spam;

  /// The tag a text of a kind is given: `kind`, its detail the kind's id.
  static const tag = 'kind';

  @override
  String get id => 'kinds';

  @override
  String get name => 'Kinds of text';

  @override
  String get description => 'Texts from numbers not in your contacts are sorted by what they are about, for the filter beside the tabs.';

  @override
  LucideIcon get icon => Lucide.listFilter;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.organise;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['sorting', 'filters'];

  @override
  String get tagline => 'Texts from strangers sorted by what they are about.';

  @override
  List<String> get adds => const ['A filter beside the tabs, with a switch for each kind', 'Deliveries, sales, political texts, debt collectors and the rest, each said as it is'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.messageSquare, 'Texts from numbers not in your contacts', 'Read on this phone to sort them. Nothing is sent, deleted or blocked.'),
        PluginReach(Lucide.contactRound, 'Your contacts, to know who is a stranger', 'Your contacts\' own texts are never sorted.'),
      ];

  /// How strict the sorting is: relaxed (strong signs only), balanced (one strong or two others), strict (one of
  /// either). Matt, 2026-11-16: "detailed settings for the filtering with strictness settings".
  static const levels = [
    SettingOption('relaxed', 'Relaxed', 'Only the surest signs: "paid for by", "attempt to collect a debt", "out for delivery". Less is sorted, and less by mistake.'),
    SettingOption('balanced', 'Balanced', 'One sure sign, or two lesser ones ("vote" and "election"), as the app ships.'),
    SettingOption('strict', 'Strict', 'Any one sign, sure or lesser. Sorts the most; a text now and then lands in a kind it is not.'),
  ];

  static int weakNeededOf(PluginPrefs prefs) => switch (prefs.get('level')) {
        'relaxed' => 0,
        'strict' => 1,
        _ => 2,
      };

  @override
  List<TunedClassifier> get tuned => [
        (facts, prefs) {
          if (facts.contact || facts.outgoing == true || facts.text.trim().isEmpty) return const [];
          if (facts.group && !prefs.flag('groups')) return const [];
          if (isNetworkChat(facts) && !prefs.flag('networks')) return const [];
          final weakNeeded = weakNeededOf(prefs);
          final spamFirst = prefs.flag('spam_first');
          bool? looksSpam;
          for (final k in kinds) {
            if (!prefs.flag('kind_${k.id}')) continue;
            if (!k.matches(facts.text, weakNeeded: weakNeeded, extra: wordsOf(prefs, 'words_${k.id}'))) continue;
            if (spamFirst && k.notSpam && (looksSpam ??= judgeSpam(facts, rules: spam).spam)) continue;
            return [Tag(tag, k.id)];
          }
          return const [];
        },
      ];

  static PluginAction _not(TextKind k, int thread) => PluginAction(
        label: 'Not ${k.one}',
        icon: Lucide.check,
        run: (host) {
          host.move(thread, null);
          host.say('Moved to Messages');
        },
      );

  @override
  List<ListSection> get sections => [
        for (final k in kinds)
          ListSection(
            id: k.id,
            label: k.label,
            icon: k.icon,
            filter: true,
            hidden: k.hidden,
            takes: (facts, tags, prefs) => tags.detail(tag) == k.id,
            row: (facts, tags, prefs) => RowLook(caption: tags.detail(tag) == k.id ? k.label : 'Moved here by you', word: _not(k, facts.thread)),
          ),
      ];

  @override
  List<SlotFill> get slots => [
        // A conversation's long press: out of its kind for good.
        Slots.conversationMenu.fill((place, prefs) => [
              for (final k in kinds)
                if (place.section == k.id) _not(k, place.facts.thread),
            ]),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'slate',
        intro: 'Texts from numbers that are not in your contacts, sorted by what they are about. The filter beside the tabs shows or hides each kind.',
        summary: (prefs) {
          final on = kinds.where((k) => prefs.flag('kind_${k.id}')).length;
          final level = levels.firstWhere((o) => o.value == (prefs.get('level') ?? 'balanced'), orElse: () => levels[1]).label;
          return '$level · $on of ${kinds.length} kinds';
        },
      );

  @override
  List<PluginSetting> get settings => [
        const PluginSetting.heading(label: 'How strict', hint: 'Each kind has sure signs and lesser ones. How many it takes to sort a text:'),
        const PluginSetting.choice(key: 'level', label: 'Strictness', options: levels, choice: 'balanced'),
        const PluginSetting.heading(label: 'Kinds', hint: 'Switch off a kind to stop sorting texts into it. Whether a kind shows in Messages is chosen in the filter beside the tabs.'),
        for (final k in kinds) PluginSetting.toggle(key: 'kind_${k.id}', label: k.label, hint: '${k.about}${k.hidden ? ' Hidden from Messages until you show it.' : ''}', icon: k.icon),
        const PluginSetting.heading(label: 'Your own words', hint: 'A text from someone not in your contacts with any of these is sorted into that kind, as a sure sign is. Commas between them.'),
        for (final k in kinds) PluginSetting.words(key: 'words_${k.id}', label: 'Words for ${k.label.toLowerCase()}', icon: k.icon, placeholder: _examples[k.id]),
        const PluginSetting.heading(label: 'Where it looks'),
        const PluginSetting.toggle(key: 'groups', label: 'Group chats with strangers', hint: 'A group in which nobody is in your contacts is sorted too.', icon: Lucide.users),
        const PluginSetting.toggle(key: 'networks', label: 'Signal and Telegram', hint: 'Chats there from people you have not added, as texts are.', icon: Lucide.messageSquare),
        const PluginSetting.toggle(
          key: 'spam_first',
          label: 'Spam before shown kinds',
          hint: 'A text that looks like spam is not sorted as a delivery, a reminder or an appointment, so a fake "your parcel is held, pay the fee" stays hidden in Spam.',
          icon: Lucide.shieldCheck,
        ),
        const PluginSetting.note(
          label: 'On this phone only',
          hint: 'Texts are looked at here and sent nowhere. Nothing is deleted or blocked, and your contacts are never sorted. "Not …" on a conversation puts it back in Messages for good.',
          icon: Lucide.lock,
        ),
      ];

  static const _examples = {
    'debt': 'balance owed, collections',
    'political': 'a candidate\'s name',
    'sales': 'solar, roofing',
    'scams': 'investment club',
    'reminders': 'your landlord\'s name',
    'food': 'a local restaurant',
    'deliveries': 'a courier you use',
    'appointments': 'your dentist',
    'notices': 'a service you use',
  };
}
