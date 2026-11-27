import 'inbox.dart';

/// Spam and scams in chats on Telegram and the other networks (Matt, 2026-11-15: "i also want spam filters on them to
/// work and cut out fake romance scams and other telegram scams").
///
/// A chat is taken out of the list, into Spam, when:
///
/// - the network itself marks the account a scam or a fake (Telegram's own labels, `verification_status`); or
/// - an account names itself Telegram without being Telegram's own; or
/// - someone who is not a contact wrote first (Telegram shows its "Report spam" bar for such a chat) and the newest
///   message shows a sign of one of [scamSigns]: the come-on and the flirty emoji, the romance opener ("hello dear",
///   "sorry, wrong number"), the
///   "investment" pitch (crypto, forex, trading mentors), the fake Telegram support or giveaway, the money ask (gift
///   cards, sugar daddies, loans), or the too-good job; or the name is dressed for romance: a heart, a kiss or a rose
///   in it, or three emoji or more, whatever the newest message is (a photo, a sticker).
///
/// A contact's chat, or a group, is never taken out; "Not spam" puts a chat back for good. Everything is looked at on
/// the device; nothing is reported, blocked or deleted.
class ScamSign {
  const ScamSign(this.id, this.says, this.pattern, {this.coldOnly = false});
  final String id;

  /// A sign that counts only where a stranger wrote and was never answered ([InboxChat.cold]); none does for now.
  final bool coldOnly;

  /// How the row in Spam says it, after "Looks like a scam:".
  final String says;
  final String pattern;

  /// Whether [text] shows this sign, whatever its case. Each pattern is compiled once and kept, since a sign is const
  /// and can hold no RegExp of its own.
  bool matches(String text) => (_compiled[pattern] ??= RegExp(pattern, caseSensitive: false)).hasMatch(text);
  static final _compiled = <String, RegExp>{};
}

// A word's start and end in a pattern: no letter or digit just before, or just after.
const _b = r'(?<![a-z0-9])';
const _e = r'(?![a-z0-9])';

const List<ScamSign> scamSigns = [
  ScamSign(
    'romance',
    'a romance opener',
    '$_b(?:(?:hello|hi|hey|good (?:morning|evening))[ ,]+(?:my )?(?:dear|darling|handsome|beautiful|sweetheart)|how are you (?:my )?dear|nice to meet you dear|are you single|'
        'looking for (?:a )?(?:serious |long[- ]term )?(?:relationship|partner)|sorry,? (?:wrong (?:number|person)|i (?:added|messaged) the wrong)|'
        'my (?:friend|cousin) gave me your (?:number|contact)|i saw your profile|can we be friends|'
        // Matt, 2026-11-17, one that got through: "Your profile looks great and caught my attention. Is that your real
        // photo? Nice to meet you 😊".
        'your (?:profile|photo|picture|pic)s? (?:looks?|is|are) (?:so |really )?(?:great|nice|beautiful|amazing|lovely|cute|stunning)|caught my (?:attention|eye)|'
        '(?:is|was) (?:that|this) (?:really )?your (?:real )?(?:photo|picture|pic|face)|your real (?:photo|picture|pic))$_e',
  ),
  // The come-on that gets past Telegram's own filter: one message from a stranger, romantic or sexual, often with a
  // flirty emoji (Matt, 2026-11-15, three of them: "I want to see your face. Are you free? I have a surprise.", "Hiya! ✨
  // What a pleasant 😍 surprise!", "Want to meet someone close to you?"). From anyone not a contact, whether or not
  // they were answered (Matt: "Those two messages you tested against were not friends but instead also scammer", of
  // "Free tonight for the game? 🏀" and "haha so cute 😍").
  ScamSign(
    'flirt',
    'a come-on from a stranger',
    '$_b(?:see your face|are you free(?: tonight| now)?|i have a surprise|(?:what a )?pleasant surprise|meet (?:someone|a girl|girls|women|singles) (?:close|near) (?:to )?you|'
        'someone (?:close|near) (?:to )?you|want to (?:see|meet|chat with|talk to) you|hiya|hey (?:cutie|handsome|sexy|babe|baby|stranger)|cutie|sexy|naughty|horny|kisses|'
        'hot (?:pics|photos|girls|singles)|send (?:me )?(?:a |your )?(?:pic|photo|selfie)s?|come over|bored (?:tonight|at home|and alone)|hook ?up|nudes?|lonely tonight|'
        'looking for (?:fun|a friend|company)|can i (?:get to )?know you|free (?:tonight|this evening|right now)|(?:so )?cute)$_e',
  ),
  ScamSign('flirt-emoji', 'a flirty emoji', '(?:😍|😘|🥰|💋|🫦|🍑|🍒|🍆|💦|😈|😏|💕|💖|💗|💓|❤️‍🔥|🌹|😻|🫕)'),
  ScamSign(
    'invest',
    'an investment pitch',
    '$_b(?:invest(?:ment|ing)?|usdt|bitcoin|btc|ethereum|crypto(?:currency)?|forex|trading (?:signals?|mentor|platform|account)|guaranteed (?:profit|returns?)|'
        'daily (?:profit|returns?)|airdrop|mining pool|liquidity pool|withdraw(?:al)?|double your)$_e',
  ),
  ScamSign(
    'support',
    'a fake support or giveaway message',
    '$_b(?:telegram (?:support|team|security|administration)|your account (?:will be|has been|is) (?:banned|deleted|suspended|restricted|locked)|'
        'verify your (?:account|identity)|premium (?:gift|giveaway)|claim your (?:prize|gift|reward)|you(?:\'ve| have) won)$_e',
  ),
  ScamSign(
    'money',
    'a money ask',
    '$_b(?:gift ?cards?|steam card|cash ?app|paypal flip|western union|moneygram|send me (?:money|\\\$)|loan offer|instant loan|sugar (?:daddy|mommy|baby)|weekly allowance)$_e',
  ),
  ScamSign(
    'job',
    'a too-good job',
    '$_b(?:work from home|earn \\\$?\\d+[k]? (?:a|per) (?:day|hour|week)|part[- ]time (?:job|work) (?:offer|available)|remote job offer|no experience (?:needed|required)|easy money)$_e',
  ),
];

/// A private chat whose name is Telegram's own, which only Telegram's real account (777000, [InboxChat.service]) may
/// have: two of Matt's three came from accounts calling themselves "Telegram".
final _pretends = RegExp(r'^\W*(?:telegram|telegram (?:support|team|security|premium|notifications?|official)|support team|security team)\W*$', caseSensitive: false);

/// A name dressed for romance (Matt, 2026-11-17: "when the telegram user has excessive emoji's especially hearts and
/// romance based stuff", of "Jeong❤️💋🌹"): any heart, kiss, lips or rose in it.
final _romanceName = RegExp('(?:❤|🧡|💛|💚|💙|💜|🖤|🤍|🤎|🩷|🩵|🩶|💕|💖|💗|💓|💞|💘|💝|❣|💌|💋|👄|🫦|🌹|🥀|💐|😘|😍|🥰|😻)');

/// Any emoji: a name with three or more is dressed up rather than a person's.
final _emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true);

/// What a stranger's name says, where it says something: hearts and roses, or a run of emoji.
String? _nameSign(String title) {
  if (_romanceName.hasMatch(title)) return 'hearts and roses in the name';
  if (_emoji.allMatches(title).length >= 3) return 'a name full of emoji';
  return null;
}

/// Why [chat] looks like spam or a scam, in words for its row; null where it does not.
///
/// Remembered for a chat as it stands (its name, its newest words, who it is from): the list asks for every chat at
/// every build, and the signs are a dozen patterns run over the words (docs/performance-audit.md, finding 2).
String? scamOf(InboxChat chat) {
  final key = '${chat.network}\u001f${chat.id}\u001f${chat.title}\u001f${chat.snippet}\u001f${chat.flag}\u001f${chat.group}${chat.lastFromMe}${chat.service}${chat.stranger}${chat.cold}';
  if (_scams.containsKey(key)) return _scams[key];
  if (_scams.length >= 4000) _scams.clear();
  return _scams[key] = _scamOf(chat);
}

final Map<String, String?> _scams = {};

String? _scamOf(InboxChat chat) {
  if (chat.group || chat.lastFromMe && chat.flag == null) return null;
  final flag = chat.flag;
  if (flag != null) return flag;
  if (!chat.service && chat.network == 'telegram' && _pretends.hasMatch(chat.title)) return 'Pretends to be Telegram';
  if (!chat.stranger) return null;
  final signs = [
    ?_nameSign(chat.title),
    for (final s in scamSigns) if ((!s.coldOnly || chat.cold) && s.matches(chat.snippet)) s.says,
  ];
  return signs.isEmpty ? null : 'Looks like a scam: ${signs.join(', ')}';
}
