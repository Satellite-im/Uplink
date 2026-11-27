/// The pack format "ghost-plugin/1": what a plugin from another developer is (Matt, 2026-11-20: "I would like users
/// to be able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them
/// for the store through a review process"). A pack is data, never code: one JSON object of rules the app compiles into
/// the extension points its own plugins use (plugin.dart), matched with a phrase language of its own (phrases.dart)
/// rather than regular expressions, and signed by the reviewer before the Marketplace lists it (review.dart).
///
/// This file holds the format's limits and vocabularies, how a pack's ids become the registry's, what a pack may see
/// and act on, and the words its privacy card and "What it adds" are made of, always from the pack itself. The relay
/// keeps its own copies of the vocabularies (relay/lib/market_pack.dart), held to these by a test that reads this file
/// as text: keep each list on one line, its words in single quotes.
library;

import 'dart:io';
import '../../platform_info.dart';

import '../../art/lucide.g.dart';
import '../../sms.dart';
import '../codes.dart' show signInCode;
import '../plugin.dart';
import '../registry.dart' show shippedPlugins;
import 'manifest.dart';

const String packFormat = 'ghost-plugin/1';
const String packExtension = '.ghostplugin';

/// An App Store build (`--dart-define=GHOST_STORE=appstore`): no plugins in development and no API to load them, since a
/// storefront of other developers' features reads against the App Store's rules however its packs are made.
const bool packAppStoreBuild = String.fromEnvironment('GHOST_STORE') == 'appstore';

/// Every size and count the format caps, in one place: bytes for files, pixels for a picture's side, UTF-16 units for
/// text, and how many of each thing a pack, or a device, may hold.
abstract final class PackLimits {
  static const int packageBytes = 262144, depth = 8;
  static const int iconChars = 48000, iconBytes = 36000, iconMin = 64, iconMax = 512;
  static const int shotBytes = 1048576, shotMin = 64, shotMax = 2400, shots = 4;
  static const int name = 32, tagline = 60, description = 1500, whatsNew = 500, address = 200;
  static const int labels = 4, links = 1, settings = 24;
  static const int tagRules = 32, sections = 4, actions = 12, incoming = 8;
  static const int any = 30, all = 8, none = 20, from = 50, tagged = 8;
  static const int phrases = 200, anchorless = 8, phrase = 120, tokens = 4;
  static const int scan = 2000, detail = 200, personWords = 50, personWord = 60;
  static const int headerActions = 1, menuActions = 3;
  static const int packs = 16, phrasesInAll = 1600;                     // on one device, store and dev packs together
  static const Duration slow = Duration(milliseconds: 20);              // a classification this long, twice running, is a strike
  static const Duration slowInASecond = Duration(milliseconds: 100);    // this much classifying within one second is a strike,
  static const Duration slowOnAverage = Duration(milliseconds: 1);      // where its runs took this long each on average,
  static const Duration slowInASecondAlways = Duration(milliseconds: 500); // or this much, whatever the average
  static const int strikes = 5;                                         // this many within [strikeWindow] pause the pack
  static const Duration strikeWindow = Duration(minutes: 10);
}

final RegExp packIdPattern = RegExp(r'^[a-z][a-z0-9]{2,23}$');
final RegExp packVersionPattern = RegExp(r'^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$');
final RegExp packUsernamePattern = RegExp(r'^[a-z0-9][a-z0-9._]{2,19}$');   // and no "..", and none of reservedDeveloperWords
const List<String> reservedDeveloperWords = ['uplink', 'ghost', 'gogho', 'official', 'verified', 'support'];

/// Ids no pack may have: the built-ins' and their sections', and the app's own words. Any id with uplink, ghost or gogho in it
/// is refused too.
const Set<String> reservedPackIds = {'notion', 'spotify', 'codes', 'kinds', 'spam', 'embeds', 'actions', 'replies', 'quiet', 'strangers', 'cleaner', 'translate', 'recordcall', 'scribe', 'captions', 'watch', 'debt', 'political', 'sales', 'scams', 'reminders', 'food', 'deliveries', 'appointments', 'notices', 'other', 'ghost', 'ghostmessaging', 'official', 'admin', 'system', 'market', 'marketplace', 'store', 'plugin', 'plugins', 'settings', 'messages'};

/// The docs' examples (examples/plugins): refused for a submission (id_example), so the first person to send one
/// unchanged doesn't take the id every later reader of the docs would hit.
const Set<String> examplePackIds = {'bills', 'parcels'};

/// Icons a pack may not draw: the app's own mark, the Marketplace's ring, and the privacy card's "Can't reach the
/// internet".
const Set<String> reservedIconNames = {'ghost', 'store', 'shield-check'};

const List<String> packHues = ['amber', 'blue', 'coral', 'cyan', 'green', 'indigo', 'lime', 'magenta', 'mint', 'orange', 'purple', 'red', 'rose', 'slate', 'yellow', 'graphite'];

/// The store tags a pack may carry, wire name to what the app shows.
const Map<String, String> packLabels = {'bills': 'Bills', 'codes': 'Codes', 'deliveries': 'Deliveries', 'events': 'Events', 'filters': 'Filters', 'health': 'Health', 'language': 'Language', 'money': 'Money', 'quiet': 'Quiet', 'replies': 'Replies', 'safety': 'Safety', 'school': 'School', 'shopping': 'Shopping', 'sorting': 'Sorting', 'travel': 'Travel', 'work': 'Work'};

const List<String> packShelves = ['organise', 'safety', 'messages', 'tools'];
const List<String> packSlots = ['row', 'list.conversation.menu', 'conversation.header', 'conversation.message.menu'];
const List<String> packVerbs = ['say', 'copy', 'write', 'markread', 'move', 'link'];

/// What a pack may do beyond reading texts to tag them. Every one a rule uses must be listed, and every one listed used.
enum PackPermission {
  sort('sort'), move('move'), markRead('markread'), mute('mute'), copy('copy'), write('write'), links('links');

  const PackPermission(this.wire);
  final String wire;

  /// The permission a pack's file writes as [wire]; null for a word that is none.
  static PackPermission? byWire(String wire) {
    for (final p in values) {
      if (p.wire == wire) return p;
    }
    return null;
  }
}

// --- ids ---------------------------------------------------------------------------------------------------------------

/// The registry's id for the pack [packId]: no built-in's starts with x, so the two never meet.
String registryIdOf(String packId) => 'x$packId';

/// 'xbills' → 'bills'; null for anything that is not a pack's.
String? packIdOf(String registryId) {
  if (!registryId.startsWith('x')) return null;
  final id = registryId.substring(1);
  return packIdPattern.hasMatch(id) && !_reservedId(id) ? id : null;
}

bool _reservedId(String id) => reservedPackIds.contains(id) || ownWordIn(id);

/// Whether [folded] (an id, or a name through [packFold]) holds one of the app's own words: its name, the name it had
/// until 2026-11-27, or its site's. Nobody else's plugin, id or section may read as the app's.
///
/// The name is looked for with i and l as one letter: in most faces nobody tells "UpIink", written with a capital i,
/// from the app's own.
bool ownWordIn(String folded) => folded.replaceAll('i', 'l').contains('upllnk') || folded.contains('ghost') || folded.contains('gogho');

/// A pack's section [key] as the registry knows it: its keys are letters only, so the last 0 parses back.
String sectionIdOf(String packId, String key) => 'x${packId}0$key';

/// A pack's tag [tag] as a classifier gives it: a pack's conditions read only its own, so none can test, give or
/// forge spam, code or kind.
String tagNameOf(String packId, String tag) => 'x$packId.$tag';

/// [a] against [b] part by part as numbers: negative, 0 or positive. A FormatException for one that isn't a version.
int compareVersions(String a, String b) {
  final x = _versionParts(a), y = _versionParts(b);
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

List<int> _versionParts(String version) {
  final m = packVersionPattern.firstMatch(version);
  if (m == null) throw FormatException('Not a version: "$version"', version);
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

// --- what a pack sees ----------------------------------------------------------------------------------------------------

/// 'phone', 'computer' or 'iPhone': where this app is, as the Plugins page says it (lib/ui/plugins_page pluginsHere).
String packHere() => Sms.remote ? (PlatformInfo.isIOS ? 'iPhone' : 'computer') : 'phone';

/// Whether a pack is shown [f] at all. A pack reads texts from a number not in the phone's contacts, one to one, and
/// nothing else: a stranger's rules never see a contact's words, the person's own, a group's (whose last words may be
/// anyone's, and whose sender who matches nobody reads as not a contact), a text sent with Uplink's own
/// encryption, another network's chat, or a circle's or a space's message.
bool packSees(MessageFacts f) =>
    !f.contact &&                                   // never anyone in the phone's contacts
    (!f.contactByName || MessageFacts.contactsReadable) && // and only where "not a contact" can be told: without Contacts no number has a name, so everyone would read as a stranger (review, 2026-11-20)
    f.outgoing == false &&                          // words known to be theirs: never the person's own, nor a list row whose words may be either
    !f.group &&                                     // never a group: its last words may be anyone's, and a sender who matches nobody reads as not a contact
    !f.encrypted &&                                 // never a text sent with Uplink's own encryption
    f.thread >= 0 &&                                // a texts conversation: other networks' chats are ListPlugins.chatThread (below -2^40), inbox and space messages -1, bridged ones below -1
    (f.network == null || f.network == 'sms') &&    // texts only
    f.senders.length == 1 &&
    !f.senders.single.startsWith('@');              // not a friend by username (UsernameChats.addressOf is '@<name>')

/// What a pack may do to a conversation it sees: sort it, keep it filed, draw its row, mark it read or take its
/// notification away. Never for a text with a sign-in code in it (lib/plugins/codes.dart signInCode, Notifier.otp's
/// rules, and the wider [packMayHoldCode]), whatever Codes' own switch says: a pack can tag a bank's code, never hide
/// it. Nor while such a text waits unread under newer words ([MessageFacts.codeWaiting]): marking the conversation read
/// or taking its one notification away would hide that code just the same (review, 2026-11-20).
bool packMayAct(MessageFacts f) => packSees(f) && !f.codeWaiting && signInCode(f.text) == null && !packMayHoldCode(f.text);

/// Whether [text] may hold a sign-in code, more widely than [signInCode] finds one: that is Notifier.otp's rule to the
/// letter, which decides the Copy button, and it misses Google's "G-482913 is your Google verification code.",
/// Facebook's "FB-48291", a Steam Guard code of letters and digits, a code in Russian, Chinese or a German compound
/// word, and any code in a text past 400 characters (review, 2026-11-20). Here a false positive only leaves a text
/// alone, which a pack may still tag but never sorts, marks read or silences, so it holds wherever a word that speaks
/// of a code is anywhere in the text, inside a longer word too ("Bestätigungscode", "验证码"), and a run of 4 to 10
/// letters and digits with a digit in it (or 123-456) stands on its own, after "G-" too. No length cap.
bool packMayHoldCode(String text) => _mayCodeWord.hasMatch(text) && _mayCodeRun.hasMatch(text);

// The short words alone stand as words ("pin" is in "shopping", "otp" in "hotpot"); the rest are found anywhere.
final RegExp _mayCodeWord = RegExp(r'code|c[oó]digo|codice|(?<!\p{L})k[oó]d|код|пароль|passwor|kennwort|wachtwoord|senha|contrase[nñ]a|clave|mot de passe|(?<!\p{L})pin(?!\p{L})|(?<!\p{L})otp(?!\p{L})|(?<![\p{L}\p{N}])2fa(?!\p{L})|one[- ]?time|v[eé]rif|log[- ]?in|sign[- ]?in|security|confirm|authent|authori[sz]|验证|驗證|认证|認證|認証|码|碼|コード|パスワード|暗証|인증|비밀번호|κωδικ|رمز|كود|קוד|कोड|รหัส|(?<!\p{L})mã(?!\p{L})', caseSensitive: false, unicode: true);

// ASCII letters and digits only, so a code is found inside words of a script with no spaces ("验证码是482913请勿泄露").
final RegExp _mayCodeRun = RegExp(r'(?<![A-Za-z0-9])(?=[A-Za-z]*[0-9])[A-Za-z0-9]{4,10}(?![A-Za-z0-9])|(?<![0-9])[0-9]{3}[- ][0-9]{3}(?![0-9])');

// --- text a pack may hold ------------------------------------------------------------------------------------------------

// The characters no string in a pack may hold: controls but the newline, format characters (bidi marks and overrides,
// zero-width ones, the tag characters' assigned half), private use (U+F8FF draws Apple's logo on Apple systems), the
// line and paragraph separators, and the blank-looking letters that make a name look empty or padded. The tag block is
// a range of its own, since its unassigned code points are Cn, not Cf.
final RegExp _packBadChar = RegExp(r'[\p{Cf}\p{Co}\p{Zl}\p{Zp}\x00-\x09\x0B-\x1F\x7F-\x9F\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u2800\u3164\uFFA0\u{E0000}-\u{E007F}]', unicode: true);

/// Whether [s] may be in a pack: no character of [_packBadChar], no unpaired surrogate, no whitespace at either end,
/// and a newline only where [newlines] (a description, what's new, a setting's hint).
bool packTextOk(String s, {bool newlines = false}) => s == s.trim() && !_packBadChar.hasMatch(s) && (newlines || !s.contains('\n')) && !_hasLoneSurrogate(s);

// A half of a surrogate pair without its other half: not valid UTF-16, and not something UTF-8 can carry.
bool _hasLoneSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xDC00 && c <= 0xDFFF) return true;
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= s.length) return true;
      final next = s.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    }
  }
  return false;
}

// --- addresses -----------------------------------------------------------------------------------------------------------

final RegExp _hostLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
final RegExp _lastLabel = RegExp(r'^[a-z]{2,63}$');
final RegExp _emailPattern = RegExp(r'^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63}){1,4}$');
const List<String> _localSuffixes = ['.local', '.lan', '.home', '.internal', '.localhost', '.arpa'];

// The app opens their /join and /c/ addresses itself, as Android App Links: a pack's button must never look like one.
const List<String> _ownHosts = ['gogho.st', 'ghost-sms.com'];

/// Why [address] can't be a pack's https address (its link, a link action's, its help), or null where it can: 'bad_url'.
/// With [email] (a pack's help, which may be an email address instead) an address with an @ and no :// is held to
/// the email rules: 'bad_email'. Nothing is ever put into an address, so its query is fixed and no text's words or
/// numbers can reach one.
String? packAddressIssue(String address, {bool email = false}) {
  if (email && !address.contains('://') && address.contains('@')) return _emailOk(address) ? null : 'bad_email';
  return _httpsOk(address) ? null : 'bad_url';
}

// https alone, no longer than an address may be, with no spaces, braces, fragment, user or port, to a host [_hostOk]
// lets through.
bool _httpsOk(String address) {
  if (address.length > PackLimits.address || !address.startsWith('https://')) return false;
  if (address.contains(RegExp(r'\s')) || address.contains('{') || address.contains('}') || address.contains('#')) return false;
  final uri = Uri.tryParse(address);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) return false;
  // The host as written, up to its path or query: lower case, with no user and no port to hide behind (Uri drops a
  // port that is https' own, 443, and lower-cases a host, so the words themselves are what is held to the rules).
  final rest = address.substring('https://'.length);
  final end = rest.indexOf(RegExp(r'[/?]'));
  final host = end < 0 ? rest : rest.substring(0, end);
  return host == uri.host && _hostOk(host);
}

bool _emailOk(String address) => address.length <= PackLimits.address && _emailPattern.hasMatch(address) && _hostOk(address.substring(address.indexOf('@') + 1).toLowerCase());

/// Two or more labels of lower-case letters, digits and inner hyphens, none punycode (no look-alikes); never an IP
/// address, nor a name only a home network knows, nor the app's own. Its last label is letters alone, as every real
/// one is: a browser reads a host that ends in a number as an IP address (192.168.257 opens 192.168.1.1, a router's
/// page), which InternetAddress doesn't.
bool _hostOk(String host) {
  final labels = host.split('.');
  if (labels.length < 2) return false;
  for (final label in labels) {
    if (!_hostLabel.hasMatch(label) || label.startsWith('xn--')) return false;
  }
  if (!_lastLabel.hasMatch(labels.last) || InternetAddress.tryParse(host) != null) return false;
  if (_localSuffixes.any(host.endsWith)) return false;
  return !_ownHosts.any((own) => host == own || host.endsWith('.$own'));
}

// --- names like the app's own -------------------------------------------------------------------------------------------

/// What a name is compared as, for name_reserved: lower-cased; each character mapped through [packConfusables];
/// then only letters and digits kept (\p{L}\p{N}; spaces, punctuation and combining marks go). Dart has no Unicode
/// normaliser without a new package, so the table does what NFKC would for the look-alikes that matter here. The
/// table is also asked before lower-casing, since a capital can pass for another letter than its small one does
/// (Greek Ν is an N, ν a v), and so lower-casing alone would let "Νotes" by.
String packFold(String s) {
  final mapped = _confuse(_confuse(s).toLowerCase());
  return mapped.replaceAll(_notLetterOrDigit, '');
}

final RegExp _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]', unicode: true);

// [s] with each character [packConfusables] knows replaced by what it passes for.
String _confuse(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    final plain = packConfusables[rune];
    plain == null ? out.writeCharCode(rune) : out.write(plain);
  }
  return out.toString();
}

/// Fullwidth U+FF01 to U+FF5E to ASCII; the Cyrillic and Greek letters that look Latin (а в е к м н о р с т у х і ј ѕ ԁ
/// ӏ, α β ε ι κ ν ο ρ τ υ χ, and their capitals) to the Latin letter; the Latin-1 and Latin Extended-A letters with a
/// mark to the plain letter (é → e, ł → l, ø → o, ß → ss); ı → i; 0 → o, 1 → l, 5 → s. A test pins: "Сodes" (a
/// Cyrillic С), "Ｃｏｄｅｓ", "Códes", "C o d e s" all fold to "codes"; "Gh0st Helper" folds to "ghosthelper".
const Map<int, String> packConfusables = {
  // Fullwidth U+FF01 to U+FF5E: the ASCII they are wide forms of.
  0xFF01: '!', 0xFF02: '"', 0xFF03: '#', 0xFF04: '\$', 0xFF05: '%', 0xFF06: '&', 0xFF07: '\'', 0xFF08: '(', 0xFF09: ')', 0xFF0A: '*', 0xFF0B: '+', 0xFF0C: ',',
  0xFF0D: '-', 0xFF0E: '.', 0xFF0F: '/', 0xFF10: '0', 0xFF11: '1', 0xFF12: '2', 0xFF13: '3', 0xFF14: '4', 0xFF15: '5', 0xFF16: '6', 0xFF17: '7', 0xFF18: '8',
  0xFF19: '9', 0xFF1A: ':', 0xFF1B: ';', 0xFF1C: '<', 0xFF1D: '=', 0xFF1E: '>', 0xFF1F: '?', 0xFF20: '@', 0xFF21: 'A', 0xFF22: 'B', 0xFF23: 'C', 0xFF24: 'D',
  0xFF25: 'E', 0xFF26: 'F', 0xFF27: 'G', 0xFF28: 'H', 0xFF29: 'I', 0xFF2A: 'J', 0xFF2B: 'K', 0xFF2C: 'L', 0xFF2D: 'M', 0xFF2E: 'N', 0xFF2F: 'O', 0xFF30: 'P',
  0xFF31: 'Q', 0xFF32: 'R', 0xFF33: 'S', 0xFF34: 'T', 0xFF35: 'U', 0xFF36: 'V', 0xFF37: 'W', 0xFF38: 'X', 0xFF39: 'Y', 0xFF3A: 'Z', 0xFF3B: '[', 0xFF3C: '\\',
  0xFF3D: ']', 0xFF3E: '^', 0xFF3F: '_', 0xFF40: '`', 0xFF41: 'a', 0xFF42: 'b', 0xFF43: 'c', 0xFF44: 'd', 0xFF45: 'e', 0xFF46: 'f', 0xFF47: 'g', 0xFF48: 'h',
  0xFF49: 'i', 0xFF4A: 'j', 0xFF4B: 'k', 0xFF4C: 'l', 0xFF4D: 'm', 0xFF4E: 'n', 0xFF4F: 'o', 0xFF50: 'p', 0xFF51: 'q', 0xFF52: 'r', 0xFF53: 's', 0xFF54: 't',
  0xFF55: 'u', 0xFF56: 'v', 0xFF57: 'w', 0xFF58: 'x', 0xFF59: 'y', 0xFF5A: 'z', 0xFF5B: '{', 0xFF5C: '|', 0xFF5D: '}', 0xFF5E: '~',
  // Cyrillic letters that look Latin, small then capital (а в е к м н о р с т у х і ј ѕ ԁ ӏ).
  0x0430: 'a', 0x0432: 'b', 0x0435: 'e', 0x043A: 'k', 0x043C: 'm', 0x043D: 'h', 0x043E: 'o', 0x0440: 'p', 0x0441: 'c', 0x0442: 't', 0x0443: 'y', 0x0445: 'x',
  0x0455: 's', 0x0456: 'i', 0x0458: 'j', 0x04CF: 'l', 0x0501: 'd', 0x0405: 's', 0x0406: 'i', 0x0408: 'j', 0x0410: 'a', 0x0412: 'b', 0x0415: 'e', 0x041A: 'k',
  0x041C: 'm', 0x041D: 'h', 0x041E: 'o', 0x0420: 'p', 0x0421: 'c', 0x0422: 't', 0x0423: 'y', 0x0425: 'x', 0x04C0: 'l', 0x0500: 'd',
  // Greek letters that look Latin, small then capital (α β ε ι κ ν ο ρ τ υ χ): a capital can look like another letter than its small one (Ν is N, ν is v).
  0x03B1: 'a', 0x03B2: 'b', 0x03B5: 'e', 0x03B9: 'i', 0x03BA: 'k', 0x03BD: 'v', 0x03BF: 'o', 0x03C1: 'p', 0x03C4: 't', 0x03C5: 'u', 0x03C7: 'x', 0x0391: 'a',
  0x0392: 'b', 0x0395: 'e', 0x0399: 'i', 0x039A: 'k', 0x039D: 'n', 0x039F: 'o', 0x03A1: 'p', 0x03A4: 't', 0x03A5: 'y', 0x03A7: 'x',
  // Latin-1 and Latin Extended-A letters with a mark: the plain letter (é → e, ł → l, ø → o, ß → ss, ı → i).
  0x00C0: 'a', 0x00C1: 'a', 0x00C2: 'a', 0x00C3: 'a', 0x00C4: 'a', 0x00C5: 'a', 0x00C6: 'ae', 0x00C7: 'c', 0x00C8: 'e', 0x00C9: 'e', 0x00CA: 'e', 0x00CB: 'e',
  0x00CC: 'i', 0x00CD: 'i', 0x00CE: 'i', 0x00CF: 'i', 0x00D0: 'd', 0x00D1: 'n', 0x00D2: 'o', 0x00D3: 'o', 0x00D4: 'o', 0x00D5: 'o', 0x00D6: 'o', 0x00D8: 'o',
  0x00D9: 'u', 0x00DA: 'u', 0x00DB: 'u', 0x00DC: 'u', 0x00DD: 'y', 0x00DF: 'ss', 0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a', 0x00E5: 'a',
  0x00E6: 'ae', 0x00E7: 'c', 0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e', 0x00EC: 'i', 0x00ED: 'i', 0x00EE: 'i', 0x00EF: 'i', 0x00F0: 'd', 0x00F1: 'n',
  0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o', 0x00F6: 'o', 0x00F8: 'o', 0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u', 0x00FD: 'y', 0x00FF: 'y',
  0x0100: 'a', 0x0101: 'a', 0x0102: 'a', 0x0103: 'a', 0x0104: 'a', 0x0105: 'a', 0x0106: 'c', 0x0107: 'c', 0x0108: 'c', 0x0109: 'c', 0x010A: 'c', 0x010B: 'c',
  0x010C: 'c', 0x010D: 'c', 0x010E: 'd', 0x010F: 'd', 0x0110: 'd', 0x0111: 'd', 0x0112: 'e', 0x0113: 'e', 0x0114: 'e', 0x0115: 'e', 0x0116: 'e', 0x0117: 'e',
  0x0118: 'e', 0x0119: 'e', 0x011A: 'e', 0x011B: 'e', 0x011C: 'g', 0x011D: 'g', 0x011E: 'g', 0x011F: 'g', 0x0120: 'g', 0x0121: 'g', 0x0122: 'g', 0x0123: 'g',
  0x0124: 'h', 0x0125: 'h', 0x0126: 'h', 0x0127: 'h', 0x0128: 'i', 0x0129: 'i', 0x012A: 'i', 0x012B: 'i', 0x012C: 'i', 0x012D: 'i', 0x012E: 'i', 0x012F: 'i',
  0x0130: 'i', 0x0131: 'i', 0x0132: 'ij', 0x0133: 'ij', 0x0134: 'j', 0x0135: 'j', 0x0136: 'k', 0x0137: 'k', 0x0138: 'k', 0x0139: 'l', 0x013A: 'l', 0x013B: 'l',
  0x013C: 'l', 0x013D: 'l', 0x013E: 'l', 0x013F: 'l', 0x0140: 'l', 0x0141: 'l', 0x0142: 'l', 0x0143: 'n', 0x0144: 'n', 0x0145: 'n', 0x0146: 'n', 0x0147: 'n',
  0x0148: 'n', 0x0149: 'n', 0x014A: 'n', 0x014B: 'n', 0x014C: 'o', 0x014D: 'o', 0x014E: 'o', 0x014F: 'o', 0x0150: 'o', 0x0151: 'o', 0x0152: 'oe', 0x0153: 'oe',
  0x0154: 'r', 0x0155: 'r', 0x0156: 'r', 0x0157: 'r', 0x0158: 'r', 0x0159: 'r', 0x015A: 's', 0x015B: 's', 0x015C: 's', 0x015D: 's', 0x015E: 's', 0x015F: 's',
  0x0160: 's', 0x0161: 's', 0x0162: 't', 0x0163: 't', 0x0164: 't', 0x0165: 't', 0x0166: 't', 0x0167: 't', 0x0168: 'u', 0x0169: 'u', 0x016A: 'u', 0x016B: 'u',
  0x016C: 'u', 0x016D: 'u', 0x016E: 'u', 0x016F: 'u', 0x0170: 'u', 0x0171: 'u', 0x0172: 'u', 0x0173: 'u', 0x0174: 'w', 0x0175: 'w', 0x0176: 'y', 0x0177: 'y',
  0x0178: 'y', 0x0179: 'z', 0x017A: 'z', 0x017B: 'z', 0x017C: 'z', 0x017D: 'z', 0x017E: 'z', 0x017F: 's',
  // Digits that pass for letters in a name.
  0x0030: 'o', 0x0031: 'l', 0x0035: 's',
};

/// packFold of every shipped plugin's name and every one of its sections' labels (computed once, from shippedPlugins).
Set<String> get reservedPluginNames => _reservedPluginNames;

final Set<String> _reservedPluginNames = Set.unmodifiable({
  for (final p in shippedPlugins) ...[packFold(p.name), for (final s in p.sections) packFold(s.label)],
});

// --- what a pack's page says it does -----------------------------------------------------------------------------------

/// A.11's lines for [pack], on [here] (default packHere()); a pack has its permissions, its links and its rules, so the
/// lines are always made from the file itself, never from a listing's words. Each line is there where the pack's
/// rules do what it says; on a computer or an iPhone, where a pack's incoming rules never run, it says only what runs
/// there.
List<PluginReach> packReaches(PluginPack pack, {String? here}) {
  final at = here ?? packHere();
  final phone = at == 'phone';
  final verbs = {for (final a in pack.rules.actions) a.verb};
  final asks = {for (final r in pack.rules.incoming) ...r.verbs};
  final host = pack.links.isEmpty ? null : Uri.tryParse(pack.links.first)?.host;
  return [
    // Without Contacts no number has a name, and a stranger can't be told from a contact: it then reads nothing.
    PluginReach(Lucide.eye, 'Reads texts from numbers not in your contacts', 'Their words and who they\'re from, on this $at, to sort them. Never your contacts\' texts, group texts, texts sent with Uplink\'s encryption, your own, chats on other networks, or circles and spaces. Nothing at all while Uplink can\'t read your contacts.'),
    if (pack.rules.sections.isNotEmpty) const PluginReach(Lucide.listFilter, 'Sorts texts into its own tabs and kinds', 'They leave Messages for its tab while it\'s added. Remove it and they\'re back. Texts with a sign-in code in them are never sorted.'),
    if (verbs.contains('move')) const PluginReach(Lucide.folderInput, 'Moves a conversation when you ask', 'Only when you press its button, into its own tabs or back to Messages.'),
    if (phone && (verbs.contains('markread') || asks.contains('markread')))
      const PluginReach(Lucide.checkCheck, 'Can mark texts as read', 'Only the conversation you press it on, or texts in its own tabs and kinds as they come once you switch that on in its settings. A text marked read loses its notification.')
    else if (verbs.contains('markread'))
      const PluginReach(Lucide.checkCheck, 'Can mark texts as read', 'Only the conversation you press it on.'),
    if (phone && asks.contains('mute')) const PluginReach(Lucide.bell, 'Can silence notifications', 'Only texts in its own tabs and kinds, once you switch that on in its settings. Each one\'s notification is taken away as it comes.'),
    if (verbs.contains('copy')) const PluginReach(Lucide.copy, 'Copies to your clipboard when you ask', 'Only when you press its button.'),
    if (verbs.contains('write')) const PluginReach(Lucide.pencil, 'Writes a reply for you to send', 'Only when you press its button. Nothing is sent until you send it.'),
    if (verbs.contains('link')) PluginReach(Lucide.link, 'Opens ${host ?? 'a page'} in your browser', 'Only when you press its button. The address never changes, and nothing from your texts goes with it.'),
    const PluginReach(Lucide.shieldCheck, 'Can\'t reach the internet', 'It has no way to send anything over the internet itself. A button you press can open its page in your browser or copy words to your clipboard.'),
  ];
}

/// The page's "What it adds" lines for [pack], on [here] (default packHere()): its tabs, then its kinds, then the
/// places its buttons go, then what it does as texts come (on a phone; elsewhere one line says it doesn't run there),
/// then its settings.
List<String> packAdds(PluginPack pack, {String? here}) {
  final at = here ?? packHere();
  final sections = pack.rules.sections;
  final slots = {for (final a in pack.rules.actions) ...a.slots};
  String labelOf(String key) => sections.where((s) => s.key == key).firstOrNull?.label ?? key;
  final asks = <String>[
    if (at == 'phone')
      for (final r in pack.rules.incoming)
        for (final verb in r.verbs) verb == 'markread' ? 'Can mark ${labelOf(r.section)} texts as read as they come, once you switch it on' : 'Can silence ${labelOf(r.section)} texts as they come, once you switch it on',
    if (at != 'phone' && pack.rules.incoming.isNotEmpty) 'On your phone it can also mark read or silence texts as they come; not on this $at.',
  ];
  return [
    for (final s in sections)
      if (s.kind == 'tab') 'A ${s.label} tab in the list',
    for (final s in sections)
      if (s.kind == 'filter') 'A kind in the list\'s filter: ${s.label}',
    if (slots.contains('list.conversation.menu')) 'Choices in a conversation\'s menu in the list',
    if (slots.contains('conversation.header')) 'A button in a conversation\'s header',
    if (slots.contains('conversation.message.menu')) 'Choices in a message\'s menu',
    ...asks,
    if (pack.settings.isNotEmpty) 'Settings of its own, on its page',
  ];
}
