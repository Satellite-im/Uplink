import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the relay checks of a plugin pack, "ghost-plugin/1", for the Marketplace's submissions (market.dart; Matt,
/// 2026-11-20: "I would like users to be able to develop and submit their own plugins to our plugin marketplace and I'd
/// like to be able to verify them for the store through a review process").
///
/// The relay can't import the app, so what the two must agree on is written again here: canonical JSON and the nesting
/// pass before it, the characters a pack's words may hold, the https and email addresses it may name, the PNG chunks of
/// its icon and screenshots, and the vocabularies. test/market_pack_test.dart holds this copy to the same vectors as the
/// app's lib/plugins/pack/, and to the same lists, read out of the app's format.dart.
///
/// Only a pack's top level is checked here: its rules are the reviewer's app's to check, which runs the whole format on
/// every submission before it can be approved, so a pack the relay takes and the app refuses is simply never approved.
/// The relay refuses nothing for a reason the app would not.

/// The `format` a pack must say: the one version of the format there is.
const String packFormat = 'ghost-plugin/1';

/// The format's own sizes, the same numbers as the app's: a package's bytes and how deep its JSON may nest; the icon's
/// base64 characters, bytes and pixels a side; a screenshot's pixels a side and how many; each field's characters; and
/// how many labels and links.
abstract final class PackLimits {
  static const int packageBytes = 262144, depth = 8;
  static const int iconChars = 48000, iconBytes = 36000, iconMin = 64, iconMax = 512;
  static const int shotMin = 64, shotMax = 2400, shots = 4;
  static const int name = 32, tagline = 60, description = 1500, whatsNew = 500, address = 200, symbol = 40;
  static const int labels = 4, links = 1;
}

/// The most issues one check keeps, the last of them saying how many more there were: the app's own number
/// (lib/plugins/pack/manifest.dart), so the two say the same of a package with too many problems to list.
const int packIssuesMost = 100;

/// A plugin's id (3 to 24 lower-case letters and digits, a letter first), a version (three numbers, none with a
/// leading nought or over five digits), and a username as Handles takes them.
final RegExp packIdPattern = RegExp(r'^[a-z][a-z0-9]{2,23}$');
final RegExp packVersionPattern = RegExp(r'^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})$');
final RegExp packUsernamePattern = RegExp(r'^[a-z0-9][a-z0-9._]{2,19}$');

// The vocabularies, the same lists as the app's lib/plugins/pack/format.dart (test/market_pack_test.dart compares them).

/// Ids kept for the app's own plugins and places, and any id holding `uplink`, `ghost` or `gogho`.
const Set<String> reservedPackIds = {
  'notion', 'spotify', 'codes', 'kinds', 'spam', 'embeds', 'actions', 'replies', 'quiet', 'strangers', 'cleaner', 'translate', 'recordcall', 'scribe', //
  'captions', 'watch', 'debt', 'political', 'sales', 'scams', 'reminders', 'food', 'deliveries', 'appointments', 'notices', 'other', //
  'ghost', 'ghostmessaging', 'official', 'admin', 'system', 'market', 'marketplace', 'store', 'plugin', 'plugins', 'settings', 'messages',
};

/// The docs' examples' ids, refused for a submission so the first person to send an example unchanged doesn't take the
/// id every later reader of the docs would hit.
const Set<String> examplePackIds = {'bills', 'parcels'};

/// None of these anywhere in a developer's username: a plugin listed as by @ghostdev or @officialbills reads as the app's.
const List<String> reservedDeveloperWords = ['uplink', 'ghost', 'gogho', 'official', 'verified', 'support'];

/// What a pack may name: its colour, the labels it is found by, the shelf of the store it sits on, and what it asks
/// to be allowed to do. GET /market hands these to the app.
const List<String> packHues = ['amber', 'blue', 'coral', 'cyan', 'green', 'indigo', 'lime', 'magenta', 'mint', 'orange', 'purple', 'red', 'rose', 'slate', 'yellow', 'graphite'];
const List<String> packLabels = ['bills', 'codes', 'deliveries', 'events', 'filters', 'health', 'language', 'money', 'quiet', 'replies', 'safety', 'school', 'shopping', 'sorting', 'travel', 'work'];
const List<String> packShelves = ['organise', 'safety', 'messages', 'tools'];
const List<String> packPermissions = ['sort', 'move', 'markread', 'mute', 'copy', 'write', 'links'];

/// Every field a pack's top level may have: anything else is an unknown field, since a later format is a new `format`
/// string and a reviewer must see everything a pack holds.
const List<String> packFields = ['format', 'id', 'version', 'name', 'tagline', 'description', 'icon', 'symbol', 'hue', 'shelf', 'labels', 'permissions', 'links', 'shots', 'developer', 'support', 'whatsNew', 'minApp', 'settings', 'rules'];

/// Negative, 0 or positive as [a] is older than, the same as or newer than [b], part by part as numbers; a
/// FormatException for anything that isn't a version.
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    if (!packVersionPattern.hasMatch(v)) throw FormatException('Not a version: $v');
    return [for (final p in v.split('.')) int.parse(p)];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final c = x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return 0;
}

// --- canonical JSON ----------------------------------------------------------------------------------------------------

/// [value] as the store keeps a package and hashes it: every object's keys sorted by `String.compareTo` (UTF-16 code
/// units), at every depth; arrays in order; strings as dart:convert writes them; no whitespace. An ArgumentError for a
/// double (a fraction was refused before this) or a key that isn't text. Only ever called on bytes that passed
/// [jsonDepthOk], so it recurses 8 deep at most.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

/// [canonicalJson] as UTF-8: the bytes a package is kept as, and whose SHA-256 an approval signs.
Uint8List canonicalBytes(Object? value) => utf8.encode(canonicalJson(value));

/// [v] built again with every object's keys in order, which is the order jsonEncode then writes them in.
Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) k is String ? k : throw ArgumentError('A key that isn\'t text: $k')]..sort();
    return LinkedHashMap<String, Object?>.fromIterable(keys, value: (k) => _sorted(v[k]));
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  if (v is double) throw ArgumentError('A number with a fraction: $v');
  if (v == null || v is bool || v is int || v is String) return v;
  throw ArgumentError('Not JSON: ${v.runtimeType}');
}

/// The pass over a file's bytes before anything is decoded: false as soon as `[` and `{` outside strings nest deeper
/// than [most]. jsonDecode doesn't recurse, so a 262,144-byte file of nested arrays gets through it, but would overflow
/// the stack in [canonicalJson]'s rebuild and in jsonEncode. A `"` starts or ends a string; inside one, `\` makes the
/// next byte part of it. Never recursive, never throws.
bool jsonDepthOk(List<int> bytes, {int most = PackLimits.depth}) {
  var depth = 0;
  var inString = false;
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    if (inString) {
      if (b == 0x5C) {
        i++;
      } else if (b == 0x22) {
        inString = false;
      }
    } else if (b == 0x22) {
      inString = true;
    } else if (b == 0x5B || b == 0x7B) {
      if (++depth > most) return false;
    } else if ((b == 0x5D || b == 0x7D) && depth > 0) {
      depth--;
    }
  }
  return true;
}

/// [text] decoded as base64 the way the app writes it: the standard alphabet with `=` padding and no whitespace, and
/// nothing a second spelling of the same bytes; null otherwise.
Uint8List? strictBase64(String text) {
  if (text.length % 4 != 0 || !_base64.hasMatch(text)) return null;
  try {
    final bytes = base64Decode(text);
    return base64Encode(bytes) == text ? bytes : null;
  } catch (_) {
    return null;
  }
}

final RegExp _base64 = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

// --- words ------------------------------------------------------------------------------------------------------------

/// No control characters (but a newline where one is allowed), format characters (bidi marks and overrides,
/// zero-width ones), private use (U+F8FF draws Apple's logo on Apple systems), line and paragraph separators, the
/// blank-looking letters that make a name look empty or padded, and the tag characters, assigned or not.
final RegExp _packBadChar = RegExp(r'[\p{Cf}\p{Co}\p{Zl}\p{Zp}\x00-\x09\x0B-\x1F\x7F-\x9F\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u2800\u3164\uFFA0\u{E0000}-\u{E007F}]', unicode: true);

/// Whether [s] may be a pack's words (and, here, a submission's notes or a report's): none of the characters above, no
/// leading or trailing whitespace, no unpaired surrogate, and a newline only where [newlines].
bool packTextOk(String s, {bool newlines = false}) => s == s.trim() && !_packBadChar.hasMatch(s) && (newlines || !s.contains('\n')) && !_hasLoneSurrogate(s);

/// Whether [s] holds half of a surrogate pair by itself, which is no character and can't be written as UTF-8.
bool _hasLoneSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= s.length) return true;
      final d = s.codeUnitAt(i + 1);
      if (d < 0xDC00 || d > 0xDFFF) return true;
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

// --- addresses --------------------------------------------------------------------------------------------------------

// One part of a host's name, its last part, an email address's shape, and any whitespace.
final RegExp _hostLabel = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final RegExp _lastLabel = RegExp(r'^[a-z]{2,63}$');
final RegExp _emailShape = RegExp(r'^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63}){1,4}$');
final RegExp _space = RegExp(r'\s');

/// Names that only reach something on the person's own network.
const List<String> _localSuffixes = ['.local', '.lan', '.home', '.internal', '.localhost', '.arpa'];

/// Uplink's own: their /join and /c/ addresses the app opens itself as Android App Links.
const List<String> _ownHosts = ['gogho.st', 'ghost-sms.com'];

/// Two or more labels of lower-case ASCII letters, digits and inner hyphens, no punycode (a look-alike's disguise), not
/// an IP address (a home router's page), not a local name, not ours. Its last label is letters alone, as every real one
/// is: a browser opens a host that ends in a number as an IP address (192.168.257 is 192.168.1.1), which
/// InternetAddress doesn't read as one. The app's rule (lib/plugins/pack/format.dart) is the same.
bool _hostOk(String host) {
  final labels = host.split('.');
  if (labels.length < 2) return false;
  for (final l in labels) {
    if (!_hostLabel.hasMatch(l) || l.startsWith('xn--')) return false;
  }
  if (!_lastLabel.hasMatch(labels.last) || InternetAddress.tryParse(host) != null) return false;
  for (final s in _localSuffixes) {
    if (host.endsWith(s)) return false;
  }
  for (final o in _ownHosts) {
    if (host == o || host.endsWith('.$o')) return false;
  }
  return true;
}

/// Null where [address] is an https address a pack may name (its one link, its help link): no user, port, fragment,
/// whitespace or braces, at most 200 characters, and a host as [_hostOk] says; else 'bad_url'. With [email], an email
/// address is taken too (a help link may be one), its domain held to the same rules; else 'bad_email'. A query is
/// allowed but fixed: nothing is ever put into an address, so no text's words can reach one.
String? packAddressIssue(String address, {bool email = false}) {
  if (email && address.contains('@') && !address.contains('://')) {
    if (address.length > PackLimits.address || !_emailShape.hasMatch(address)) return 'bad_email';
    return _hostOk(address.substring(address.indexOf('@') + 1).toLowerCase()) ? null : 'bad_email';
  }
  if (address.length > PackLimits.address || !address.startsWith('https://') || _space.hasMatch(address) || address.contains('{') || address.contains('}') || address.contains('#')) return 'bad_url';
  final uri = Uri.tryParse(address);
  if (uri == null || uri.scheme != 'https' || !uri.hasAuthority || uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) return 'bad_url';
  // The host as written, up to its path or query: Uri drops https' own port (443) and lower-cases a host, so it is the
  // words themselves that are held to the rules.
  final rest = address.substring('https://'.length);
  final end = rest.indexOf(RegExp(r'[/?]'));
  final host = end < 0 ? rest : rest.substring(0, end);
  return host == uri.host && _hostOk(host) ? null : 'bad_url';
}

// --- pictures ---------------------------------------------------------------------------------------------------------

/// What a PNG says of itself, read from its chunks alone: nothing is decoded or inflated.
class PngInfo {
  const PngInfo({required this.width, required this.height, required this.bitDepth, required this.colorType, required this.interlace, required this.chunks});
  final int width, height, bitDepth, colorType, interlace;

  /// The chunk types, in order.
  final List<String> chunks;
}

// The eight bytes every PNG starts with.
const List<int> _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Null where [bytes] isn't a PNG of whole chunks with IHDR (13 bytes) first and IEND last and nothing after it. CRCs
/// and the picture itself are not looked at: a picture that doesn't decode falls back to a symbol wherever it is drawn.
PngInfo? pngInfo(List<int> bytes) {
  if (bytes.length < 8) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  int u32(int at) => ((bytes[at] & 0xff) << 24) | ((bytes[at + 1] & 0xff) << 16) | ((bytes[at + 2] & 0xff) << 8) | (bytes[at + 3] & 0xff);
  final chunks = <String>[];
  var width = 0, height = 0, depth = 0, colour = 0, interlace = 0;
  var at = 8;
  // A chunk is its data's length (4 bytes), its type (4), the data, and a CRC (4): 12 bytes and the data.
  while (at < bytes.length) {
    if (bytes.length - at < 12) return null;
    final length = u32(at);
    if (length > bytes.length - at - 12) return null;
    final type = String.fromCharCodes([for (var i = at + 4; i < at + 8; i++) bytes[i] & 0xff]);
    if (chunks.isEmpty) {
      if (type != 'IHDR' || length != 13) return null;
      width = u32(at + 8);
      height = u32(at + 12);
      depth = bytes[at + 16] & 0xff;
      colour = bytes[at + 17] & 0xff;
      interlace = bytes[at + 20] & 0xff;
    }
    chunks.add(type);
    at += 12 + length;
    if (type == 'IEND') break;
  }
  if (chunks.isEmpty || chunks.last != 'IEND' || at != bytes.length) return null;
  return PngInfo(width: width, height: height, bitDepth: depth, colorType: colour, interlace: interlace, chunks: chunks);
}

/// The only chunks a pack's icon or a screenshot may hold: no animation (acTL), no text (tEXt, iTXt, zTXt), no EXIF,
/// no colour profile. Whatever is uploaded is served from gogho.st, the site's own origin.
const Set<String> pngChunksAllowed = {'IHDR', 'PLTE', 'tRNS', 'sRGB', 'gAMA', 'pHYs', 'IDAT', 'IEND'};

final RegExp _chunkName = RegExp(r'^[A-Za-z]{4}$');

/// Null where [bytes] is a PNG ([pngInfo]) holding only [pngChunksAllowed], each side between [min] and [max], and
/// square where [square]; else why not, in plain words. A pack's icon: (64, 512, square). A screenshot: (64, 2400).
String? pngProblem(List<int> bytes, {required int min, required int max, bool square = false}) {
  final info = pngInfo(bytes);
  if (info == null) return 'It isn\'t a PNG of whole chunks, IHDR first and IEND last with nothing after it.';
  for (final c in info.chunks) {
    if (!pngChunksAllowed.contains(c)) return 'It holds ${_chunkName.hasMatch(c) ? 'a $c chunk' : 'a chunk'}, and a picture here holds only IHDR, PLTE, tRNS, sRGB, gAMA, pHYs, IDAT and IEND.';
  }
  if (info.width < min || info.width > max || info.height < min || info.height > max) return 'It\'s ${info.width} by ${info.height} pixels: each side is $min to $max.';
  if (square && info.width != info.height) return 'It isn\'t square: ${info.width} by ${info.height} pixels.';
  return null;
}

/// Why [icon] isn't a pack's icon (base64 of a square PNG of 64 to 512 pixels, at most 36,000 bytes, as [pngProblem]
/// says), or null.
String? iconProblem(String icon) {
  if (icon.length > PackLimits.iconChars) return 'It\'s more than ${PackLimits.iconChars} characters of base64.';
  final bytes = strictBase64(icon);
  if (bytes == null) return 'It isn\'t base64 as the app writes it: the standard letters, = at the end, no spaces.';
  if (bytes.length > PackLimits.iconBytes) return 'It\'s ${bytes.length} bytes, and an icon is at most ${PackLimits.iconBytes}.';
  return pngProblem(bytes, min: PackLimits.iconMin, max: PackLimits.iconMax, square: true);
}

// --- a pack's top level -----------------------------------------------------------------------------------------------

/// Something wrong with a pack: the app's PackIssue, in the shape the app reads back (`PackIssue.fromJson`). Every one
/// the relay gives is an error; warnings are the app's.
class PackIssue {
  const PackIssue(this.code, this.path, this.message);

  /// One of the app's issue codes, those the relay gives too.
  final String code;

  /// Dotted and indexed from the top (`labels[2]`); '' for the whole file.
  final String path;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'path': path, 'message': message, 'severity': 'error'};

  @override
  String toString() => '$code at "$path": $message';
}

/// A submitted pack's top level, as the relay keeps it for the developer's list and the review queue: the developer's
/// own words back to them. The app draws a plugin from its package, never from these (the catalog carries none).
class PackTop {
  const PackTop({required this.id, required this.version, required this.name, required this.tagline, required this.description, required this.symbol, required this.hue, required this.shelf, required this.labels, required this.permissions, required this.links, required this.shots, required this.developer, this.support, this.whatsNew, this.minApp});
  final String id, version, name, tagline, description, symbol, hue, shelf, developer;

  /// Null only in a check made before the form has a help link.
  final String? support;
  final String? whatsNew, minApp;
  final List<String> labels, permissions, links;

  /// The screenshots' SHA-256s its page shows, in order: what the submission's screenshots must hash to.
  final List<String> shots;

  /// What a submission's record keeps of it (MarketSubmission.manifest): the words, never the icon or the rules.
  Map<String, Object?> get manifest => {
        'name': name,
        'tagline': tagline,
        'description': description,
        'symbol': symbol,
        'hue': hue,
        'shelf': shelf,
        'labels': labels,
        'permissions': permissions,
        'links': links,
        'developer': developer,
        'support': support,
        'whatsNew': whatsNew,
        'minApp': minApp,
      };
}

final RegExp _sha = RegExp(r'^[0-9a-f]{64}$');

/// Whether [name] is a username a plugin may be listed under: as Handles' usernames are, lower case, with none of
/// [reservedDeveloperWords] anywhere in it.
bool developerOk(String name) => packUsernamePattern.hasMatch(name) && !name.contains('..') && !reservedDeveloperWords.any(name.contains);

/// The top level of a submitted pack, every problem the relay looks for collected: an object with no unknown field;
/// `format`; `id` (its pattern, the ids kept for the app, an example's); `version`; the words and their lengths; the
/// icon; the vocabularies; the one link; the screenshots' hashes; the developer and the help link; `whatsNew`, `minApp`;
/// `settings` a list and `rules` an object. Nothing deeper.
///
/// [needIcon] and [needSupport] false for a check (`check: true`): the form checks a pack as soon as it is loaded, for
/// what only the store can say (the id taken, the username's owner, the quotas), before its icon and help link are
/// filled in.
({List<PackIssue> issues, PackTop? top}) checkPackTop(Object? pack, {bool needIcon = true, bool needSupport = true}) {
  final issues = <PackIssue>[];
  // At most [packIssuesMost] kept, the last saying how many more, as the app's check keeps them (manifest.dart): a
  // 256 KiB package of 87,000 empty permissions was 87,000 issues, a 14 MB answer and 116 ms of the hub's one isolate
  // for any stranger's key, before its owner was even asked (review, 2026-11-20).
  var more = 0;
  void add(String code, String path, String message) {
    if (issues.length >= packIssuesMost - 1) {
      more++;
      return;
    }
    issues.add(PackIssue(code, path, message));
  }

  List<PackIssue> kept() => [...issues, if (more > 0) PackIssue('too_many_issues', '', 'And $more more ${more == 1 ? 'problem' : 'problems'} like these: fix the ones above and check it again.')];
  if (pack is! Map) {
    add('not_object', '', 'The file is ${pack is List ? 'a list' : 'a single value'}, not a JSON object.');
    return (issues: kept(), top: null);
  }
  for (final k in pack.keys) {
    if (!packFields.contains(k)) add('unknown_field', '$k', '"$k" isn\'t a field of ghost-plugin/1.');
  }
  if (pack['format'] != packFormat) add('format_unknown', 'format', 'format: this version of Uplink reads "$packFormat".');

  // Three readers of a field, each adding its own issues and returning null where the field won't do: text (any
  // string), words (a string within its length and of allowed characters), and list (strings, each once, each passed
  // by [bad], which adds the issue itself and returns '' for one that is fine).
  String? text(String key, {required bool needed}) {
    if (!pack.containsKey(key)) {
      if (needed) add('missing', key, '$key: needed.');
      return null;
    }
    final v = pack[key];
    if (v is String) return v;
    add('wrong_type', key, '$key: should be text.');
    return null;
  }

  String? words(String key, {required int most, bool newlines = false, bool needed = true, int least = 1}) {
    final v = text(key, needed: needed);
    if (v == null) return null;
    if (v.length < least) {
      add('too_short', key, '$key: can\'t be empty.');
    } else if (v.length > most) {
      add('too_long', key, '$key: at most $most characters (this is ${v.length}).');
    } else if (!packTextOk(v, newlines: newlines)) {
      add('bad_text', key, '$key: holds a character a plugin\'s words can\'t have (a control, invisible or private-use one${newlines ? '' : ', or a line break'}), or starts or ends with a space.');
    } else {
      return v;
    }
    return null;
  }

  List<String>? list(String key, {required bool needed, int least = 0, required int most, required String Function(int i, Object? v) bad}) {
    if (!pack.containsKey(key)) {
      if (needed) add('missing', key, '$key: needed.');
      return null;
    }
    final v = pack[key];
    if (v is! List) {
      add('wrong_type', key, '$key: should be a list.');
      return null;
    }
    if (v.length < least) add('too_few', key, '$key: at least $least.');
    if (v.length > most) add('too_many', key, '$key: at most $most.');
    final seen = <String>{};
    final out = <String>[];
    var ok = v.length >= least && v.length <= most;
    // Only as many as there may be are looked at, as the app's check reads a list past its cap.
    for (var i = 0; i < v.length && i < most; i++) {
      final e = v[i];
      final code = bad(i, e);
      if (code.isNotEmpty) {
        ok = false;
      } else if (!seen.add(e as String)) {
        add('duplicate', '$key[$i]', '$key[$i]: "$e" is there twice.');
        ok = false;
      } else {
        out.add(e);
      }
    }
    return ok ? out : null;
  }

  final id = text('id', needed: true);
  if (id != null) {
    if (!packIdPattern.hasMatch(id)) {
      add('bad_id', 'id', 'id: 3 to 24 lower-case letters and digits, starting with a letter.');
    } else if (reservedPackIds.contains(id) || id.contains('uplink') || id.contains('ghost') || id.contains('gogho')) {
      add('id_reserved', 'id', 'id: "$id" is kept for Uplink\'s own plugins and places.');
    } else if (examplePackIds.contains(id)) {
      add('id_example', 'id', 'That\'s the example\'s id: give your plugin an id of its own.');
    }
  }
  final version = text('version', needed: true);
  if (version != null && !packVersionPattern.hasMatch(version)) add('bad_version', 'version', 'version: three numbers with dots between, as 1.0.0.');
  final name = words('name', most: PackLimits.name);
  final tagline = words('tagline', most: PackLimits.tagline);
  final description = words('description', most: PackLimits.description, newlines: true);
  final icon = text('icon', needed: needIcon);
  if (icon != null) {
    final why = iconProblem(icon);
    if (why != null) add('bad_icon', 'icon', 'icon: a square PNG of ${PackLimits.iconMin} to ${PackLimits.iconMax} pixels in base64. $why');
  }
  var symbol = 'puzzle';
  if (pack.containsKey('symbol')) {
    final s = text('symbol', needed: false);
    if (s != null && s.length > PackLimits.symbol) {
      add('too_long', 'symbol', 'symbol: at most ${PackLimits.symbol} characters.');
    } else if (s != null) {
      symbol = s;
    }
  }
  final hue = text('hue', needed: true);
  if (hue != null && !packHues.contains(hue)) add('bad_hue', 'hue', 'hue: one of ${packHues.join(', ')}.');
  final shelf = text('shelf', needed: true);
  if (shelf != null && !packShelves.contains(shelf)) add('bad_shelf', 'shelf', 'shelf: one of ${packShelves.join(', ')}.');
  final labels = list('labels', needed: true, least: 1, most: PackLimits.labels, bad: (i, v) {
    if (v is String && packLabels.contains(v)) return '';
    add('bad_label', 'labels[$i]', 'labels[$i]: one of ${packLabels.join(', ')}.');
    return 'bad_label';
  });
  // Seven words, each once, is the most there can be: more is too_many, as the app's check says.
  final permissions = list('permissions', needed: true, most: packPermissions.length, bad: (i, v) {
    if (v is String && packPermissions.contains(v)) return '';
    add('bad_permission', 'permissions[$i]', 'permissions[$i]: one of ${packPermissions.join(', ')}.');
    return 'bad_permission';
  });
  final links = pack.containsKey('links')
      ? list('links', needed: false, most: PackLimits.links, bad: (i, v) {
          if (v is String && packAddressIssue(v) == null) return '';
          add('bad_url', 'links[$i]', 'links[$i]: an https address of a public site, at most ${PackLimits.address} characters, with nothing put into it.');
          return 'bad_url';
        })
      : const <String>[];
  final shots = pack.containsKey('shots')
      ? list('shots', needed: false, most: PackLimits.shots, bad: (i, v) {
          if (v is String && _sha.hasMatch(v)) return '';
          add('bad_shot', 'shots[$i]', 'shots[$i]: a screenshot\'s SHA-256, 64 lower-case hex digits.');
          return 'bad_shot';
        })
      : const <String>[];
  final developer = text('developer', needed: true);
  if (developer != null && !developerOk(developer)) {
    add('bad_developer', 'developer', 'developer: a username of 3 to 20 lower-case letters, digits, dots and underscores, without ${reservedDeveloperWords.join(', ')} anywhere in it.');
  }
  String? support = text('support', needed: needSupport);
  if (support != null) {
    final code = support.length > PackLimits.address ? 'too_long' : packAddressIssue(support, email: true);
    if (code != null) {
      add(code, 'support', switch (code) {
        'too_long' => 'support: at most ${PackLimits.address} characters.',
        'bad_email' => 'support: an email address whose domain is a public site\'s.',
        _ => 'support: an https address of a public site, or an email address.',
      });
      support = null;
    }
  }
  final whatsNew = pack.containsKey('whatsNew') ? words('whatsNew', most: PackLimits.whatsNew, newlines: true, least: 0) : null;
  final minApp = text('minApp', needed: false);
  if (minApp != null && !packVersionPattern.hasMatch(minApp)) add('bad_version', 'minApp', 'minApp: a version, three numbers with dots between, as 1.0.0.');
  if (pack.containsKey('settings') && pack['settings'] is! List) add('wrong_type', 'settings', 'settings: should be a list.');
  if (!pack.containsKey('rules')) {
    add('missing', 'rules', 'rules: needed.');
  } else if (pack['rules'] is! Map) {
    add('wrong_type', 'rules', 'rules: should be an object.');
  }
  if (issues.isNotEmpty) return (issues: kept(), top: null);
  return (
    issues: issues,
    top: PackTop(
      id: id!,
      version: version!,
      name: name!,
      tagline: tagline!,
      description: description!,
      symbol: symbol,
      hue: hue!,
      shelf: shelf!,
      labels: labels!,
      permissions: permissions!,
      links: links!,
      shots: shots!,
      developer: developer!,
      support: support,
      whatsNew: whatsNew,
      minApp: minApp,
    ),
  );
}
