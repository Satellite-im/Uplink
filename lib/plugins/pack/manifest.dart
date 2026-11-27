/// A pack as the app holds it once it has been checked (A.1 to A.14 of the format), and the checking: [parsePack] takes
/// a file's bytes and gives the pack, or every issue found, in plain words for the developer and the reviewer.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../art/lucide.g.dart';
import '../plugin.dart' show SettingOption;
import 'canonical.dart';
import 'format.dart';
import 'phrases.dart';
import 'png.dart';
import 'trial.dart' show lintPack;

/// How much an issue matters: an error stops the pack, a warning is for the developer and the reviewer to look at.
enum PackSeverity { error, warning }

/// One thing wrong with a pack (an error, which stops it loading or being sent) or worth a second look (a warning).
class PackIssue {
  const PackIssue(this.code, this.path, this.message, {this.severity = PackSeverity.error});

  /// What kind of problem, as the format names it ('bad_text', 'phrase_bad_token', 'needs_permission').
  final String code;

  /// Where, dotted and indexed from the top (`rules.tags[0].any[2]`); '' for the whole file.
  final String path;

  /// Plain words for a developer, e.g. 'rules.tags[0].any[2]: "{foo}" is not a token.'
  final String message;
  final PackSeverity severity;

  bool get isError => severity == PackSeverity.error;

  Map<String, Object?> toJson() => {'code': code, 'path': path, 'message': message, 'severity': severity.name};

  /// The relay's invalid_package issues come back in this shape. Anything it doesn't say reads as an error, so a
  /// refusal is never shown as a mere warning.
  factory PackIssue.fromJson(Map j) => PackIssue('${j['code'] ?? 'invalid'}', '${j['path'] ?? ''}', '${j['message'] ?? ''}', severity: j['severity'] == 'warning' ? PackSeverity.warning : PackSeverity.error);

  @override
  String toString() => '${severity.name} $code at "$path": $message';
}

/// A condition (`when`, and a section's `takes`): every part given must hold.
class PackWhen {
  const PackWhen({this.from = const [], this.tagged = const [], this.untagged = const [], this.setting, this.settingIs, this.section});

  /// The senders it holds for, each as compared: only digits for a number, else trimmed and lower-cased. An entry with
  /// nothing left to compare is '' and holds for no one; where none is given at all, any sender will do.
  final List<String> from;

  /// Own tag names (without the `x<id>.` prefix) that must all be there, and that must all be missing.
  final List<String> tagged;
  final List<String> untagged;

  /// A setting's key: with no [settingIs], that toggle is on; else the choice's value (or a toggle's 'on' or 'off').
  final String? setting;
  final String? settingIs;

  /// An action's alone: the section of the place it is offered in, an own section key or 'main' for the main list.
  final String? section;
}

/// One tag rule (`rules.tags`): the phrases that give the tag, the person's own words joining them where [wordsFrom]
/// names a words setting, and what the tag says with it.
class PackTagRule {
  const PackTagRule({required this.tag, this.any = const [], this.anyGiven = false, this.atLeast = 1, this.all = const [], this.none = const [], this.wordsFrom, this.when, this.detail, this.detailFrom});
  final String tag;

  /// Compiled when the pack was checked, once: the pack's plugin never compiles them again.
  final List<Phrase> any;

  /// The rule says `any` at all, even as []: it then counts its phrases (A.8.2 step 2), and with none to count it
  /// never fires, as a rule whose only phrases are the person's words does nothing until they type some.
  final bool anyGiven;
  final int atLeast;
  final List<Phrase> all;
  final List<Phrase> none;
  final String? wordsFrom;
  final PackWhen? when;

  /// The tag's words where the rule gives fixed ones.
  final String? detail;

  /// 'token' (the first token's capture) or 'match' (the whole match), where the words come from the text instead.
  final String? detailFrom;
}

/// How a pack's section draws its rows: [value] and [caption] are templates of its tags (`{tag:bill}`); [end],
/// [word] and [tap] name its actions. Never a title: the row keeps the conversation's own name.
class PackRow {
  const PackRow({this.value, this.caption, this.faceName, this.faceColor, this.end, this.word, this.tap});
  final String? value;
  final String? caption;

  /// A face of plain words on a colour (0xRRGGBB), never a company's mark.
  final String? faceName;
  final int? faceColor;
  final String? end;
  final String? word;
  final String? tap;
}

/// One of a pack's sections (`rules.sections`): a tab of its own or a kind in the list's filter.
class PackSection {
  const PackSection({required this.key, required this.label, required this.icon, required this.kind, this.leavesMain = true, this.takes = const PackWhen(), this.row});

  /// Letters only: the registry knows it as `x<id>0<key>` (format.dart sectionIdOf).
  final String key;
  final String label;

  /// An icon's name (a key of Lucide.all).
  final String icon;

  /// 'tab' or 'filter'.
  final String kind;
  final bool leavesMain;
  final PackWhen takes;
  final PackRow? row;
}

/// One of a pack's buttons (`rules.actions`): where it is offered, when, and its one verb with that verb's fields.
class PackAction {
  const PackAction({required this.id, required this.label, required this.icon, required this.verb, required this.slots, this.when, this.text, this.say, this.to, this.url});
  final String id;
  final String label;
  final String icon;

  /// 'say', 'copy', 'write', 'markread', 'move' or 'link'.
  final String verb;

  /// Where it is offered: 'row', 'list.conversation.menu', 'conversation.header', 'conversation.message.menu'.
  final List<String> slots;
  final PackWhen? when;

  /// What a say says, a copy copies (a template) or a write writes.
  final String? text;

  /// What a copy says once it has copied.
  final String? say;

  /// Where a move files the conversation: 'main' or an own tab's key.
  final String? to;

  /// The pack's one link, for a link.
  final String? url;
}

/// One of a pack's incoming rules (`rules.incoming`): for texts its section [section] takes as they come, once the
/// toggle [setting] is on, mark them read and/or take their notification away.
class PackIncoming {
  const PackIncoming({required this.section, required this.verbs, required this.setting, this.when});

  /// The rule's `in`: an own section key.
  final String section;

  /// The rule's `do`: 'markread' and/or 'mute'.
  final List<String> verbs;
  final String setting;
  final PackWhen? when;
}

/// One of a pack's settings, as A.7 has them: 'toggle', 'choice', 'words', 'note' or 'heading'.
class PackSetting {
  const PackSetting({required this.type, this.key, required this.label, this.hint, this.icon, this.fallback = false, this.options = const [], this.choice, this.placeholder});
  final String type;
  final String? key;
  final String label;
  final String? hint;

  /// An icon's name.
  final String? icon;

  /// A toggle's default.
  final bool fallback;

  /// A choice's values, and its default.
  final List<SettingOption> options;
  final String? choice;

  /// A words field's placeholder.
  final String? placeholder;
}

/// A pack's rules: what it tags, the sections it adds, its buttons, and what it does as texts come.
class PackRules {
  const PackRules({this.tags = const [], this.sections = const [], this.actions = const [], this.incoming = const []});
  final List<PackTagRule> tags;
  final List<PackSection> sections;
  final List<PackAction> actions;
  final List<PackIncoming> incoming;
}

/// A pack that has been checked: everything it says, ready for its plugin (pack_plugin.dart) and its pages.
class PluginPack {
  const PluginPack({required this.id, required this.version, required this.name, required this.tagline, required this.description, this.symbol = 'puzzle', required this.hue, required this.shelf, this.icon, required this.labels, this.permissions = const {}, this.links = const [], this.shots = const [], this.developer, this.support, this.whatsNew, this.minApp, this.settings = const [], this.rules = const PackRules(), this.json = const {}});
  final String id, version, name, tagline, description, symbol, hue, shelf;
  final Uint8List? icon;             // the decoded PNG; null for a pack loaded in developer mode without one
  final List<String> labels;
  final Set<PackPermission> permissions;
  final List<String> links;          // 0 or 1
  final List<String> shots;          // the screenshots' SHA-256s its page shows, in order
  final String? developer, support, whatsNew, minApp;
  final List<PackSetting> settings;
  final PackRules rules;
  final Map<String, Object?> json;   // the pack as parsed; anyone who changes it works on a deep copy (D.8)
  String get registryId => registryIdOf(id);
}

/// What checking a file gave: the pack where nothing was wrong, every issue found, and the pack's canonical bytes and
/// their SHA-256 wherever the file was JSON without fractions (so a reviewer sees the hash of what they check).
class PackParse {
  const PackParse({this.pack, this.issues = const [], this.canonical, this.sha256});
  final PluginPack? pack;            // null when there is any error
  final List<PackIssue> issues;      // errors, then warnings (lintPack, run only when there is no error)
  final Uint8List? canonical;        // the canonical bytes, wherever the file was JSON without fractions
  final String? sha256;              // of canonical
  bool get ok => pack != null;
  Iterable<PackIssue> get errors => issues.where((i) => i.isError);
  Iterable<PackIssue> get warnings => issues.where((i) => !i.isError);
}

/// Checks [bytes] as a ghost-plugin/1 pack (A.1 to A.14) for an app at [appVersion]. Never throws: it runs
/// jsonDepthOk first (too_deep), then decodes, and catches anything thrown on the way, StackOverflowError included
/// (an issue bad_json at "" with the error's words). [submission]: also require what the store requires (`icon`,
/// `developer` and `support`, `missing` otherwise; an example's id is `id_example`), as the submission form and the
/// reviewer's screen ask; loading in developer mode and the store's installer leave it false. [checkMinApp] false
/// leaves `minApp` unchecked, for the Marketplace to draw a listing that needs a newer app (D.11).
PackParse parsePack(List<int> bytes, {required String appVersion, bool submission = false, bool checkMinApp = true}) {
  try {
    if (bytes.length > PackLimits.packageBytes) return PackParse(issues: [PackIssue('too_large', '', 'The file is ${bytes.length} bytes: a plugin is at most ${PackLimits.packageBytes}.')]);
    // A leading BOM, as some editors write: loading in developer mode takes any form of the JSON, the store only the
    // canonical bytes (which have none), and its installer checks those against the bytes itself.
    final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes.sublist(3) : bytes;
    // Before anything is decoded: a file of 131,072 brackets decodes, then overflows the stack wherever it is
    // written out again.
    if (!jsonDepthOk(body)) return const PackParse(issues: [PackIssue('too_deep', '', 'Its brackets nest more than ${PackLimits.depth} deep: no plugin needs more than 6.')]);
    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      return const PackParse(issues: [PackIssue('bad_utf8', '', 'It isn\'t text in UTF-8: save it again as UTF-8.')]);
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      return PackParse(issues: [PackIssue('bad_json', '', 'It isn\'t JSON: ${e.message}${e.offset == null ? '' : ', at character ${e.offset}'}.')]);
    }
    return parsePackJson(json, appVersion: appVersion, submission: submission, checkMinApp: checkMinApp);
  } catch (e) {
    return PackParse(issues: [PackIssue('bad_json', '', 'It couldn\'t be read: ${'$e'.split('\n').first}')]);
  }
}

/// [parsePack] for a pack already decoded: the submission form's, as it is typed.
PackParse parsePackJson(Object? json, {required String appVersion, bool submission = false, bool checkMinApp = true}) {
  try {
    return _Checker(appVersion: appVersion, submission: submission, checkMinApp: checkMinApp).run(json);
  } catch (e) {
    return PackParse(issues: [PackIssue('bad_json', '', 'It couldn\'t be read: ${'$e'.split('\n').first}')]);
  }
}

/// A sender as a pack's `from` compares it (A.8.1): a number, however it is written, as its digits alone; anything
/// else trimmed and lower-cased. A condition's entries and a text's sender both go through it.
String packSenderOf(String address) => _numberLike.hasMatch(address) ? address.replaceAll(_notDigit, '') : address.trim().toLowerCase();

final RegExp _numberLike = RegExp(r'^[0-9 +().\-]+$');
final RegExp _notDigit = RegExp(r'[^0-9]');

// --- the checking --------------------------------------------------------------------------------------------------------

final RegExp _settingKey = RegExp(r'^[a-z][a-z0-9]{0,23}$');
final RegExp _sectionKey = RegExp(r'^[a-z]{1,12}$');
final RegExp _tagName = RegExp(r'^[a-z][a-z0-9]{0,15}$');
final RegExp _actionId = RegExp(r'^[a-z][a-z0-9]{0,23}$');
final RegExp _optionValue = RegExp(r'^[a-z0-9]{1,16}$');
final RegExp _shot = RegExp(r'^[0-9a-f]{64}$');
final RegExp _colour = RegExp(r'^#[0-9A-Fa-f]{6}$');
final RegExp _base64 = RegExp(r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$');
final RegExp _leadingVersion = RegExp(r'^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})');

const Set<String> _topFields = {'format', 'id', 'version', 'name', 'tagline', 'description', 'icon', 'symbol', 'hue', 'shelf', 'labels', 'permissions', 'links', 'shots', 'developer', 'support', 'whatsNew', 'minApp', 'settings', 'rules'};

// Each kind of setting's fields (A.7).
const Map<String, Set<String>> _settingFields = {
  'toggle': {'type', 'key', 'label', 'hint', 'icon', 'default'},
  'choice': {'type', 'key', 'label', 'hint', 'icon', 'options', 'default'},
  'words': {'type', 'key', 'label', 'hint', 'icon', 'placeholder'},
  'note': {'type', 'label', 'hint', 'icon'},
  'heading': {'type', 'label', 'hint'},
};

// Each verb's own fields, and those it can't do without (A.8.5).
const Map<String, Set<String>> _verbFields = {'say': {'text'}, 'copy': {'text', 'say'}, 'write': {'text'}, 'markread': {}, 'move': {'to'}, 'link': {'url'}};
const Map<String, Set<String>> _verbNeeds = {'say': {'text'}, 'copy': {'text'}, 'write': {'text'}, 'markread': {}, 'move': {'to'}, 'link': {'url'}};
const List<String> _allVerbFields = ['text', 'say', 'to', 'url'];

// What a reviewer would have to take on trust, so this version has none of it: each one's own words.
const Map<String, String> _notInRules = {'text': 'Rules that change the words a message shows aren\'t in this version: a stranger\'s rule could rewrite what a sender said.'};
const Map<String, String> _notInRow = {'title': 'A row keeps its conversation\'s own name: a plugin can\'t give it a title, or whoever sent a text could choose what its conversation is called.'};
const Map<String, String> _notInSection = {'hidden': 'A plugin\'s kinds start shown: the person hides one in the list\'s filter, as for any kind.'};
const Map<String, String> _notInWhen = {'group': 'A plugin never sees a group\'s texts, so it has no group to ask about.'};
const Map<String, String> _notInFace = {'domain': 'A plugin\'s face is its words on a colour: never a company\'s logo.', 'mark': 'A plugin\'s face is its words on a colour: never a company\'s logo.'};

/// The path of [key] under [path], as an issue names it: `rules.tags[2].when`.
String _at(String path, String key) => path.isEmpty ? key : '$path.$key';

/// Where a condition is: a tag rule's (seeing only the tags of the rules before it), a section's `takes`, a button's
/// (which alone may name a section), or an incoming rule's.
class _Where {
  const _Where.tagRule(this.earlier) : action = false;
  const _Where.elsewhere()
      : earlier = null,
        action = false;
  const _Where.action()
      : earlier = null,
        action = true;
  final Set<String>? earlier;
  final bool action;
}

/// The most issues one check gives, the last of them saying how many more there were. A file of 256 KiB holds some
/// 65,000 one-letter phrases, each a problem of its own, and the reviewer's screen drew a line for every one: minutes on
/// the one phone that holds the review key, from any stranger's submission (review, 2026-11-20). The first hundred say
/// what is wrong as well as all of them would.
const int packIssuesMost = 100;

/// One check of one file's JSON against the format: every problem is gathered with the path it is at, not only the
/// first, and a pack comes of it only where there was none. [submission] asks for what a listing needs as well (an
/// icon, a developer, a support address, an id that isn't the example's).
class _Checker {
  _Checker({required this.appVersion, required this.submission, required this.checkMinApp});
  final String appVersion;
  final bool submission, checkMinApp;
  final issues = <PackIssue>[];

  /// The issues past [packIssuesMost], counted rather than kept.
  var _more = 0;

  /// The file nests deeper than the format: nothing else is looked at.
  var tooDeep = false;

  // What the pack has, read before its rules are checked, so a reference to one is judged against all of them.
  final settingsByKey = <String, PackSetting>{};
  final allTags = <String>{};
  final sectionKinds = <String, String?>{};
  final actionsById = <String, ({String? verb, List<String> slots})>{};
  var hasIncoming = false, hasLink = false;
  List<String> links = const [];
  var phraseCount = 0, anchorlessCount = 0;

  /// Any problem found means the pack doesn't load, so one past [packIssuesMost] is only counted.
  void error(String code, String path, String words) {
    if (issues.length >= packIssuesMost - 1) {
      _more++;
      return;
    }
    issues.add(PackIssue(code, path, path.isEmpty ? words : '$path: $words'));
  }

  /// The issues kept, and one more saying how many weren't, where there were too many to keep.
  List<PackIssue> get kept => [...issues, if (_more > 0) PackIssue('too_many_issues', '', 'And $_more more ${_more == 1 ? 'problem' : 'problems'} like these: fix the ones above and check it again.')];

  // --- the whole value, before any field ----------------------------------------------------------------------------

  /// One pass over [json] with a stack of its own, never recursive: JSON's own kinds only, no fractions, and no deeper
  /// than the format nests. False where canonical bytes can't be made of it.
  bool walk(Object? json) {
    var ok = true;
    final stack = <(Object?, String, int)>[(json, '', 1)];
    while (stack.isNotEmpty) {
      final (v, path, depth) = stack.removeLast();
      if (v == null || v is bool || v is int || v is String) continue;
      if (v is double) {
        error('fraction', path, 'A plugin holds whole numbers only: ${v.isFinite && v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : 'no fraction or exponent'}.');
        ok = false;
        continue;
      }
      if (v is! List && v is! Map) {
        error('wrong_type', path, 'isn\'t a JSON value.');
        ok = false;
        continue;
      }
      if (depth > PackLimits.depth) {
        tooDeep = true;
        error('too_deep', path, 'nests more than ${PackLimits.depth} deep: no plugin needs more than 6.');
        return false;
      }
      if (v is List) {
        for (var i = v.length - 1; i >= 0; i--) {
          stack.add((v[i], '$path[$i]', depth + 1));
        }
      } else if (v is Map) {
        for (final e in v.entries.toList().reversed) {
          if (e.key is! String) {
            error('wrong_type', path, 'an object\'s keys are words in quotes.');
            ok = false;
            continue;
          }
          stack.add((e.value, _at(path, e.key as String), depth + 1));
        }
      }
    }
    return ok;
  }

  /// The whole check: the walk, the canonical bytes and their SHA-256 where they can be made, then the fields. The
  /// hash is given even for a pack with problems, so a broken copy can still be told from another.
  PackParse run(Object? json) {
    final canonicalOk = walk(json);
    // Asked of the walk itself, not of the issues kept: past the most kept, its too_deep would be only counted.
    if (tooDeep) return PackParse(issues: kept);
    final canonical = canonicalOk ? canonicalBytes(json) : null;
    final sha256 = canonical == null ? null : sha256Hex(canonical);
    PackParse done([PluginPack? pack]) {
      final out = issues.isEmpty ? pack : null;
      // Lints are for a pack that loads: a broken one's issues come first, and alone.
      return PackParse(pack: out, issues: [...kept, if (out != null) ...lintPack(out)], canonical: canonical, sha256: sha256);
    }

    if (json is! Map) {
      // A fraction, or something JSON hasn't, was said of the whole file already.
      if (issues.isEmpty) error('not_object', '', 'A plugin is one JSON object, in braces: {…}.');
      return done();
    }
    final top = _keyed(json);
    if (top['format'] != packFormat) {
      error('format_unknown', 'format', top.containsKey('format') ? 'is "$packFormat" for this version of Uplink, not ${top['format'] is String ? '"${top['format']}"' : 'that'}.' : 'is needed: "$packFormat".');
      return done();
    }
    return done(_pack(top, json));
  }

  // --- small checks -------------------------------------------------------------------------------------------------

  // In the checks below a double is never said to be the wrong type: the walk said "fraction" of it already.

  /// [m] with its string keys alone (the walk has said of any other).
  Map<String, Object?> _keyed(Map m) => {for (final e in m.entries) if (e.key is String) e.key as String: e.value};

  /// [v] where it is an object; null, with why, where it isn't. [what] names it in the words ("A setting").
  Map<String, Object?>? object(Object? v, String path, String what) {
    if (v is Map) return _keyed(v);
    if (v is! double) error('not_object', path, '$what is an object, in braces: {…}.');
    return null;
  }

  /// Every field of [m] that isn't one of [keys] is a problem: with [notInV1]'s own words where it is something this
  /// version leaves out on purpose, else as a likely misspelling.
  void known(Map<String, Object?> m, String path, Set<String> keys, [Map<String, String> notInV1 = const {}]) {
    for (final k in m.keys) {
      if (keys.contains(k)) continue;
      error('unknown_field', _at(path, k), notInV1[k] ?? '"$k" isn\'t something a plugin has here: check its spelling. A plugin holds only what the format names, so a reviewer sees everything it does.');
    }
  }

  /// [m]'s [key] where it is a string; null, with why, where it is missing ([required]), not a string, or null.
  String? string(Map<String, Object?> m, String key, String path, {bool required = false}) {
    final p = _at(path, key);
    if (!m.containsKey(key)) {
      if (required) error('missing', p, 'is needed.');
      return null;
    }
    final v = m[key];
    if (v is String) return v;
    if (v is! double) error('wrong_type', p, v == null ? 'can\'t be null: leave it out instead.' : 'is words, in quotes.');
    return null;
  }

  /// [string], held to A.4 and to its lengths; [braces] false: no { or } at all; [placeholders] false: no {tag:…}.
  String? text(Map<String, Object?> m, String key, String path, {bool required = false, int min = 1, required int max, bool newlines = false, bool braces = true, bool placeholders = false}) {
    final v = string(m, key, path, required: required);
    if (v != null) checkText(v, _at(path, key), min: min, max: max, newlines: newlines, braces: braces, placeholders: placeholders);
    return v;
  }

  /// What [text] holds a string to, for one that didn't come from a field of a map (a list's entry, a detail).
  void checkText(String v, String p, {int min = 1, required int max, bool newlines = false, bool braces = true, bool placeholders = false}) {
    if (!packTextOk(v, newlines: newlines)) error('bad_text', p, 'holds a character a plugin can\'t: ${newlines ? '' : 'a line break, '}an invisible or private one, or a space at either end.');
    if (v.length < min) error('too_short', p, min == 1 ? 'can\'t be empty.' : 'is at least $min characters.');
    if (v.length > max) error('too_long', p, 'is at most $max characters: this is ${v.length}.');
    if (!braces && (v.contains('{') || v.contains('}'))) {
      error('bad_template', p, 'holds no { or }: its words are shown as they are written, never with a text\'s words in them.');
    } else if (!placeholders && v.contains('{tag:')) {
      error('bad_template', p, 'can\'t hold a placeholder: only a row\'s value and caption and a copy\'s text do.');
    }
  }

  bool? boolean(Map<String, Object?> m, String key, String path, {bool required = false}) {
    final p = _at(path, key);
    if (!m.containsKey(key)) {
      if (required) error('missing', p, 'is needed: true or false.');
      return null;
    }
    final v = m[key];
    if (v is bool) return v;
    if (v is! double) error('wrong_type', p, 'is true or false.');
    return null;
  }

  int? integer(Map<String, Object?> m, String key, String path) {
    final v = m[key];
    if (v is int) return v;
    if (v is! double) error('wrong_type', _at(path, key), 'is a whole number.');
    return null;
  }

  /// [m]'s [key] where it is a list, cut to [max]; null, with why, where it is missing ([required]) or not a list.
  List<Object?>? list(Map<String, Object?> m, String key, String path, {bool required = false, int min = 0, required int max}) {
    final p = _at(path, key);
    if (!m.containsKey(key)) {
      if (required) error('missing', p, 'is needed: a list, in square brackets.');
      return null;
    }
    final v = m[key];
    if (v is! List) {
      if (v is! double) error('wrong_type', p, 'is a list, in square brackets: [...].');
      return null;
    }
    if (v.length < min) error('too_few', p, min == 1 ? 'needs one at least.' : 'needs $min at least.');
    if (v.length > max) {
      error('too_many', p, 'has ${v.length}: at most $max.');
      // Only as many as there may be are looked at: nothing past a cap is checked, compiled or listed as a problem of
      // its own, however long a list a file holds.
      return v.sublist(0, max);
    }
    return v;
  }

  /// The strings of [raw] (a list at [p]) as they are, each that isn't one said, and each one twice said once.
  List<String> strings(List<Object?> raw, String p, {bool unique = true}) {
    final out = <String>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      if (v is! String) {
        if (v is! double) error('wrong_type', '$p[$i]', 'is words, in quotes.');
        continue;
      }
      if (unique && !seen.add(v)) error('duplicate', '$p[$i]', '"$v" is here twice.');
      out.add(v);
    }
    return out;
  }

  /// [v] must be one of the app's icons by name, and not one of the few the app keeps for itself.
  void iconName(String v, String p) {
    if (reservedIconNames.contains(v)) {
      error('bad_icon_name', p, '"$v" is the app\'s own: the ghost is its mark, the store is the Marketplace\'s and the shield with a tick says "Can\'t reach the internet".');
    } else if (!Lucide.all.containsKey(v)) {
      error('bad_icon_name', p, '"$v" isn\'t an icon\'s name: the docs list them (calculator, map-pin, copy, …).');
    }
  }

  /// A name or a label that reads as one of the app's own, once folded ([packFold]), is refused.
  void reserved(String v, String p) {
    final folded = packFold(v);
    if (reservedPluginNames.contains(folded) || ownWordIn(folded)) {
      error('name_reserved', p, '"$v" reads as one of Uplink\'s own names: choose one of your own.');
    }
  }

  // --- the pack ----------------------------------------------------------------------------------------------------

  /// The top-level fields in the format's order, then settings before rules, since rules name settings. Every field is
  /// checked even after one has failed; null where anything did.
  PluginPack? _pack(Map<String, Object?> top, Map json) {
    known(top, '', _topFields);

    final id = string(top, 'id', '', required: true);
    if (id != null) {
      if (!packIdPattern.hasMatch(id)) {
        error('bad_id', 'id', '"$id": an id is 3 to 24 lower-case letters and digits, starting with a letter.');
      } else if (reservedPackIds.contains(id) || ownWordIn(id)) {
        error('id_reserved', 'id', '"$id" is kept for the app itself: choose another.');
      } else if (submission && examplePackIds.contains(id)) {
        error('id_example', 'id', 'That\'s the example\'s id: give your plugin an id of its own.');
      }
    }
    final version = string(top, 'version', '', required: true);
    if (version != null && !packVersionPattern.hasMatch(version)) error('bad_version', 'version', '"$version": a version is three numbers with dots between them, as 1.0.0.');

    final name = text(top, 'name', '', required: true, max: PackLimits.name);
    if (name != null && packTextOk(name)) reserved(name, 'name');
    final tagline = text(top, 'tagline', '', required: true, max: PackLimits.tagline);
    final description = text(top, 'description', '', required: true, max: PackLimits.description, newlines: true);

    final iconText = string(top, 'icon', '', required: submission);
    final icon = iconText == null ? null : _icon(iconText);
    final symbol = string(top, 'symbol', '');
    if (symbol != null) iconName(symbol, 'symbol');
    final hue = string(top, 'hue', '', required: true);
    if (hue != null && !packHues.contains(hue)) error('bad_hue', 'hue', '"$hue" isn\'t a colour here: ${packHues.join(', ')}.');
    final shelf = string(top, 'shelf', '', required: true);
    if (shelf != null && !packShelves.contains(shelf)) error('bad_shelf', 'shelf', '"$shelf" isn\'t a shelf: ${packShelves.join(', ')}.');

    final labelsRaw = list(top, 'labels', '', required: true, min: 1, max: PackLimits.labels);
    final labels = labelsRaw == null ? const <String>[] : strings(labelsRaw, 'labels');
    for (var i = 0; i < labels.length; i++) {
      if (!packLabels.containsKey(labels[i])) error('bad_label', 'labels[$i]', '"${labels[i]}" isn\'t a tag here: ${packLabels.keys.join(', ')}.');
    }

    final permissionsRaw = list(top, 'permissions', '', required: true, max: PackPermission.values.length);
    final permissionWords = permissionsRaw == null ? const <String>[] : strings(permissionsRaw, 'permissions');
    final permissions = <PackPermission>{};
    for (var i = 0; i < permissionWords.length; i++) {
      final p = PackPermission.byWire(permissionWords[i]);
      p == null ? error('bad_permission', 'permissions[$i]', '"${permissionWords[i]}" isn\'t a permission: ${PackPermission.values.map((p) => p.wire).join(', ')}.') : permissions.add(p);
    }

    final linksRaw = list(top, 'links', '', max: PackLimits.links);
    links = linksRaw == null ? const [] : strings(linksRaw, 'links');
    for (var i = 0; i < links.length; i++) {
      if (!packTextOk(links[i])) {
        error('bad_text', 'links[$i]', 'holds a character an address can\'t.');
      } else if (packAddressIssue(links[i]) != null) {
        error('bad_url', 'links[$i]', '"${links[i]}" isn\'t an address a plugin can open: https, a name (no numbers for an address, no punycode, nothing local), no port, nothing after a #, at most ${PackLimits.address} characters, and not Uplink\'s own.');
      }
    }

    final shotsRaw = list(top, 'shots', '', max: PackLimits.shots);
    final shots = shotsRaw == null ? const <String>[] : strings(shotsRaw, 'shots');
    for (var i = 0; i < shots.length; i++) {
      if (!_shot.hasMatch(shots[i])) error('bad_shot', 'shots[$i]', 'is a screenshot\'s SHA-256: 64 lower-case hex characters.');
    }

    final developer = string(top, 'developer', '', required: submission);
    if (developer != null && (!packUsernamePattern.hasMatch(developer) || developer.contains('..') || reservedDeveloperWords.any(developer.contains))) {
      error('bad_developer', 'developer', '"$developer" isn\'t a username a plugin can be listed under: 3 to 20 lower-case letters, digits, dots and underscores, and none of ${reservedDeveloperWords.join(', ')} in it.');
    }
    final support = string(top, 'support', '', required: submission);
    if (support != null) {
      if (!packTextOk(support)) {
        error('bad_text', 'support', 'holds a character an address can\'t.');
      } else {
        final why = packAddressIssue(support, email: true);
        if (why == 'bad_email') error('bad_email', 'support', '"$support" isn\'t an email address a plugin can give.');
        if (why == 'bad_url') error('bad_url', 'support', '"$support" isn\'t an https address or an email address a plugin can give: at most ${PackLimits.address} characters, a name (no numbers for an address, nothing local), no port, nothing after a #.');
      }
    }
    final whatsNew = text(top, 'whatsNew', '', min: 0, max: PackLimits.whatsNew, newlines: true);
    final minApp = string(top, 'minApp', '');
    if (minApp != null) {
      if (!packVersionPattern.hasMatch(minApp)) {
        error('bad_version', 'minApp', '"$minApp": a version is three numbers with dots between them, as 0.10.1.');
      } else if (checkMinApp) {
        final app = _leadingVersion.firstMatch(appVersion)?.group(0);
        if (app != null && compareVersions(minApp, app) > 0) error('needs_newer_app', 'minApp', 'It needs Uplink $minApp or newer: this is $app.');
      }
    }

    final settingsRaw = list(top, 'settings', '', max: PackLimits.settings);
    final settings = settingsRaw == null ? const <PackSetting>[] : _settings(settingsRaw);

    final rulesMap = top.containsKey('rules') ? object(top['rules'], 'rules', 'rules') : null;
    if (!top.containsKey('rules')) error('missing', 'rules', 'is needed: what it tags and sorts.');
    final rules = rulesMap == null ? null : _rules(rulesMap);

    if (rules != null) _permissions(rules, permissions, permissionWords);
    if (issues.isNotEmpty || rules == null) return null;
    return PluginPack(
      id: id!,
      version: version!,
      name: name!,
      tagline: tagline!,
      description: description!,
      symbol: symbol ?? 'puzzle',
      hue: hue!,
      shelf: shelf!,
      icon: icon,
      labels: List.unmodifiable(labels),
      permissions: Set.unmodifiable(permissions),
      links: List.unmodifiable(links),
      shots: List.unmodifiable(shots),
      developer: developer,
      support: support,
      whatsNew: whatsNew,
      minApp: minApp,
      settings: List.unmodifiable(settings),
      rules: rules,
      json: _frozen(json) as Map<String, Object?>,
    );
  }

  /// The icon's bytes from its base64, where it is a square PNG within the format's sizes; null, with why, otherwise.
  Uint8List? _icon(String v) {
    if (v.length > PackLimits.iconChars) {
      error('bad_icon', 'icon', 'is ${v.length} characters of base64: at most ${PackLimits.iconChars}.');
      return null;
    }
    if (!_base64.hasMatch(v)) {
      error('bad_icon', 'icon', 'isn\'t base64 (A to Z, a to z, 0 to 9, + and /, with = at the end to fill it out, and no spaces).');
      return null;
    }
    // The shape above lets through a last group whose unused bits aren't zero ("AB=="), which Dart's decoder refuses
    // with a FormatException: that is the icon's problem, at `icon`, not the whole file's bad_json, which would drop
    // every other issue and the hash with it. Read back as the relay's strictBase64 reads it, so the app and the relay
    // refuse the same strings with the same code.
    Uint8List? read;
    try {
      read = base64Decode(v);
    } on FormatException {
      read = null;
    }
    if (read == null || base64Encode(read) != v) {
      error('bad_icon', 'icon', 'isn\'t base64 as it is written: the bits before the = at its end must be zero. Encode the picture again.');
      return null;
    }
    final bytes = read;
    if (bytes.length > PackLimits.iconBytes) {
      error('bad_icon', 'icon', 'is ${bytes.length} bytes: a plugin\'s icon is at most ${PackLimits.iconBytes}.');
      return null;
    }
    final why = pngProblem(bytes, min: PackLimits.iconMin, max: PackLimits.iconMax, square: true);
    if (why != null) {
      error('bad_icon', 'icon', why);
      return null;
    }
    return bytes;
  }

  // --- settings (A.7) ------------------------------------------------------------------------------------------------

  /// The settings that could be read, each kept in [settingsByKey] under its key for the rules to name.
  List<PackSetting> _settings(List<Object?> raw) {
    final out = <PackSetting>[];
    for (var i = 0; i < raw.length; i++) {
      final p = 'settings[$i]';
      final m = object(raw[i], p, 'A setting');
      if (m == null) continue;
      final type = string(m, 'type', p, required: true);
      if (type == null) continue;
      final fields = _settingFields[type];
      if (fields == null) {
        error('wrong_type', _at(p, 'type'), '"$type" isn\'t a kind of setting: toggle, choice, words, note or heading.');
        continue;
      }
      known(m, p, fields);
      String? key;
      if (fields.contains('key')) {
        key = string(m, 'key', p, required: true);
        if (key != null) {
          if (!_settingKey.hasMatch(key)) {
            error('bad_key', _at(p, 'key'), '"$key": a setting\'s key is 1 to 24 lower-case letters and digits, starting with a letter.');
          } else if (settingsByKey.containsKey(key)) {
            error('duplicate', _at(p, 'key'), '"$key" is another setting\'s key too.');
          }
        }
      }
      final label = text(m, 'label', p, required: true, max: 60) ?? '';
      final hint = text(m, 'hint', p, max: 200, newlines: true);
      final icon = fields.contains('icon') ? string(m, 'icon', p) : null;
      if (icon != null) iconName(icon, _at(p, 'icon'));
      final PackSetting setting;
      switch (type) {
        case 'toggle':
          setting = PackSetting(type: type, key: key, label: label, hint: hint, icon: icon, fallback: boolean(m, 'default', p, required: true) ?? false);
        case 'choice':
          final optionsRaw = list(m, 'options', p, required: true, min: 2, max: 8);
          final options = <SettingOption>[];
          final values = <String>{};
          for (var j = 0; j < (optionsRaw?.length ?? 0); j++) {
            final q = '${_at(p, 'options')}[$j]';
            final o = object(optionsRaw![j], q, 'An option');
            if (o == null) continue;
            known(o, q, const {'value', 'label', 'hint'});
            final value = string(o, 'value', q, required: true);
            if (value != null) {
              if (!_optionValue.hasMatch(value)) {
                error('bad_key', _at(q, 'value'), '"$value": an option\'s value is 1 to 16 lower-case letters and digits.');
              } else if (!values.add(value)) {
                error('duplicate', _at(q, 'value'), '"$value" is another option\'s value too.');
              }
            }
            final optionLabel = text(o, 'label', q, required: true, max: 40) ?? '';
            final optionHint = text(o, 'hint', q, max: 120);
            if (value != null) options.add(SettingOption(value, optionLabel, optionHint));
          }
          final chosen = string(m, 'default', p, required: true);
          if (chosen != null && optionsRaw != null && !values.contains(chosen)) error('choice_default', _at(p, 'default'), '"$chosen" isn\'t one of its options\' values.');
          setting = PackSetting(type: type, key: key, label: label, hint: hint, icon: icon, options: List.unmodifiable(options), choice: chosen);
        case 'words':
          setting = PackSetting(type: type, key: key, label: label, hint: hint, icon: icon, placeholder: text(m, 'placeholder', p, max: 60));
        default:
          setting = PackSetting(type: type, label: label, hint: hint, icon: icon);
      }
      if (key != null && !settingsByKey.containsKey(key)) settingsByKey[key] = setting;
      out.add(setting);
    }
    return out;
  }

  // --- rules (A.8) ---------------------------------------------------------------------------------------------------

  PackRules? _rules(Map<String, Object?> m) {
    known(m, 'rules', const {'tags', 'sections', 'actions', 'incoming'}, _notInRules);
    final tagsRaw = list(m, 'tags', 'rules', max: PackLimits.tagRules) ?? const [];
    final sectionsRaw = list(m, 'sections', 'rules', max: PackLimits.sections) ?? const [];
    final actionsRaw = list(m, 'actions', 'rules', max: PackLimits.actions) ?? const [];
    final incomingRaw = list(m, 'incoming', 'rules', max: PackLimits.incoming) ?? const [];
    if (tagsRaw.isEmpty && sectionsRaw.isEmpty) error('empty_pack', 'rules', 'A plugin needs a tag rule or a section at least, or it does nothing.');

    // What each rule names, read first, so a reference is judged against all of them, and one broken rule doesn't
    // make every rule that names it broken too.
    final tagOf = <String?>[for (final r in tagsRaw) r is Map && r['tag'] is String ? r['tag'] as String : null];
    allTags.addAll(tagOf.whereType<String>());
    for (final s in sectionsRaw) {
      if (s is Map && s['key'] is String) sectionKinds.putIfAbsent(s['key'] as String, () => s['kind'] is String ? s['kind'] as String : null);
    }
    for (final a in actionsRaw) {
      if (a is Map && a['id'] is String) actionsById.putIfAbsent(a['id'] as String, () => (verb: a['do'] is String ? a['do'] as String : null, slots: [if (a['slots'] is List) for (final s in a['slots'] as List) if (s is String) s]));
    }
    hasIncoming = incomingRaw.isNotEmpty;
    hasLink = actionsRaw.any((a) => a is Map && a['do'] == 'link');

    final tags = <PackTagRule>[];
    for (var i = 0; i < tagsRaw.length; i++) {
      final rule = _tagRule(tagsRaw[i], 'rules.tags[$i]', {for (final t in tagOf.take(i)) ?t});
      if (rule != null) tags.add(rule);
    }
    if (phraseCount > PackLimits.phrases) error('too_many_phrases', 'rules.tags', 'has $phraseCount phrases in all: at most ${PackLimits.phrases}.');
    if (anchorlessCount > PackLimits.anchorless) error('too_many_anchorless', 'rules.tags', 'has $anchorlessCount phrases with no word of three letters or more in them: at most ${PackLimits.anchorless}, since each is looked for in every text.');

    final sections = <PackSection>[];
    final sectionKeys = <String>{};
    for (var i = 0; i < sectionsRaw.length; i++) {
      final section = _section(sectionsRaw[i], 'rules.sections[$i]', sectionKeys);
      if (section != null) sections.add(section);
    }

    final actions = <PackAction>[];
    final actionIds = <String>{};
    final inSlot = <String, int>{};
    for (var i = 0; i < actionsRaw.length; i++) {
      final action = _action(actionsRaw[i], 'rules.actions[$i]', actionIds, inSlot);
      if (action != null) actions.add(action);
    }

    final incoming = <PackIncoming>[];
    for (var i = 0; i < incomingRaw.length; i++) {
      final rule = _incoming(incomingRaw[i], 'rules.incoming[$i]');
      if (rule != null) incoming.add(rule);
    }
    return PackRules(tags: List.unmodifiable(tags), sections: List.unmodifiable(sections), actions: List.unmodifiable(actions), incoming: List.unmodifiable(incoming));
  }

  /// The phrases of the list [m]'s [key], compiled; each counts toward the pack's phrase caps whether it compiles or
  /// not.
  List<Phrase> _phrases(Map<String, Object?> m, String key, String path, {required int min, required int max}) {
    final raw = list(m, key, path, min: min, max: max);
    if (raw == null) return const [];
    final out = <Phrase>[];
    final p = _at(path, key);
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      phraseCount++;
      if (v is! String) {
        if (v is! double) error('wrong_type', '$p[$i]', 'is a phrase, in quotes.');
        continue;
      }
      try {
        final phrase = Phrase.compile(v);
        if (phrase.anchorless) anchorlessCount++;
        out.add(phrase);
      } on PhraseError catch (e) {
        error(e.code, '$p[$i]', e.message);
      }
    }
    return List.unmodifiable(out);
  }

  /// One tag rule; [earlier] is the tags of the rules before it, the only ones its condition may name.
  PackTagRule? _tagRule(Object? raw, String p, Set<String> earlier) {
    final m = object(raw, p, 'A tag rule');
    if (m == null) return null;
    known(m, p, const {'tag', 'any', 'atLeast', 'all', 'none', 'wordsFrom', 'when', 'detail'});
    final tag = string(m, 'tag', p, required: true);
    if (tag != null && !_tagName.hasMatch(tag)) error('bad_key', _at(p, 'tag'), '"$tag": a tag is 1 to 16 lower-case letters and digits, starting with a letter.');
    final anyRaw = m['any'];
    final any = _phrases(m, 'any', p, min: 0, max: PackLimits.any);
    final all = _phrases(m, 'all', p, min: 1, max: PackLimits.all);
    final none = _phrases(m, 'none', p, min: 1, max: PackLimits.none);
    final wordsFrom = string(m, 'wordsFrom', p);
    if (wordsFrom != null && settingsByKey[wordsFrom]?.type != 'words') error('unknown_setting', _at(p, 'wordsFrom'), '"$wordsFrom" isn\'t one of its words settings.');
    var atLeast = 1;
    if (m.containsKey('atLeast')) {
      final n = integer(m, 'atLeast', p);
      if (n != null) {
        if (n < 1) error('too_few', _at(p, 'atLeast'), 'is 1 at least.');
        if (n > 5) error('too_many', _at(p, 'atLeast'), 'is 5 at most.');
        if (n >= 1 && n <= 5 && wordsFrom == null && n > (anyRaw is List ? anyRaw.length : 0)) error('too_many', _at(p, 'atLeast'), 'is more than its "any" phrases: it could never be reached.');
        atLeast = n;
      }
    }
    final when = m.containsKey('when') ? _when(m['when'], _at(p, 'when'), _Where.tagRule(earlier)) : null;
    String? detail, detailFrom;
    if (m.containsKey('detail')) {
      final v = m['detail'];
      final q = _at(p, 'detail');
      if (v is String) {
        checkText(v, q, max: PackLimits.detail);
        detail = v;
      } else if (v is Map) {
        final d = _keyed(v);
        known(d, q, const {'from'});
        final from = string(d, 'from', q, required: true);
        if (from != null && from != 'token' && from != 'match') error('wrong_type', _at(q, 'from'), 'is "token" (the first token\'s words) or "match" (the whole phrase\'s).');
        detailFrom = from;
      } else if (v != null && v is! double) {
        error('wrong_type', q, 'is words, or {"from": "token"} or {"from": "match"}, or null.');
      }
    }
    final triggered = (anyRaw is List && anyRaw.isNotEmpty) || m.containsKey('all') || wordsFrom != null || (when?.from.isNotEmpty ?? false) || (when?.tagged.isNotEmpty ?? false);
    if (!triggered) error('tag_rule_no_trigger', p, 'gives its tag on nothing: give it "any" or "all" phrases, a "wordsFrom", or a "when" with "from" or "tagged".');
    if (tag == null) return null;
    return PackTagRule(tag: tag, any: any, anyGiven: m.containsKey('any'), atLeast: atLeast, all: all, none: none, wordsFrom: wordsFrom, when: when, detail: detail, detailFrom: detailFrom);
  }

  /// A condition, checked for where it stands ([where]): which tags it may name, and whether it may ask for a section.
  PackWhen? _when(Object? raw, String path, _Where where) {
    final m = object(raw, path, 'A condition');
    if (m == null) return null;
    known(m, path, const {'from', 'tagged', 'untagged', 'setting', 'section'}, _notInWhen);
    var from = const <String>[];
    final fromRaw = list(m, 'from', path, min: 1, max: PackLimits.from);
    if (fromRaw != null) {
      final p = _at(path, 'from');
      if (hasIncoming) error('from_with_incoming', p, 'A plugin that marks texts read or silences them as they come can\'t pick texts by who sent them: a reviewer can\'t judge numbers they don\'t know.');
      // Anywhere in the pack, not only in the link's own condition: a tag given by sender, a tab that takes by sender
      // or that tab's row would offer the link only for those numbers just the same (review, 2026-11-20).
      if (hasLink) error('bad_link_when', p, 'A plugin with a link can\'t pick texts by who sent them: which texts offer the link, by a tag, a tab or a row, could tell the page it opens which numbers wrote.');
      final entries = strings(fromRaw, p, unique: false);
      for (var i = 0; i < entries.length; i++) {
        checkText(entries[i], '$p[$i]', min: 3, max: 64);
      }
      // Every entry as it compares, even one with nothing left to compare ("(-)" is no number and no name): it holds
      // for no sender, as A.8.1 says. Dropped, it left the condition with no senders at all, and so holding for every
      // one (review, 2026-11-20).
      from = List.unmodifiable({for (final e in entries) packSenderOf(e)});
    }
    List<String> names(String key) {
      final raw = list(m, key, path, min: 1, max: PackLimits.tagged);
      if (raw == null) return const [];
      final p = _at(path, key);
      final out = strings(raw, p);
      for (var i = 0; i < out.length; i++) {
        final earlier = where.earlier;
        if (earlier != null && !earlier.contains(out[i])) {
          error('unknown_tag', '$p[$i]', allTags.contains(out[i]) ? '"${out[i]}" is given only by this rule or a later one: a tag rule sees the tags of the rules before it.' : '"${out[i]}" is no tag of this plugin\'s.');
        } else if (earlier == null && !allTags.contains(out[i])) {
          error('unknown_tag', '$p[$i]', '"${out[i]}" is no tag of this plugin\'s: no tag rule gives it.');
        }
      }
      return List.unmodifiable(out);
    }

    final tagged = names('tagged'), untagged = names('untagged');
    String? setting, settingIs;
    if (m.containsKey('setting')) {
      final p = _at(path, 'setting');
      final v = m['setting'];
      if (v is String) {
        if (settingsByKey[v]?.type != 'toggle') error('unknown_setting', p, '"$v" isn\'t one of its switches.');
        setting = v;
      } else if (v is Map) {
        final o = _keyed(v);
        known(o, p, const {'key', 'is'});
        final key = string(o, 'key', p, required: true);
        final value = string(o, 'is', p, required: true);
        final s = key == null ? null : settingsByKey[key];
        if (key != null && (s == null || (s.type != 'toggle' && s.type != 'choice'))) {
          error('unknown_setting', _at(p, 'key'), '"$key" isn\'t one of its switches or choices.');
        } else if (s != null && value != null && !(s.type == 'toggle' ? (value == 'on' || value == 'off') : s.options.any((o) => o.value == value))) {
          error('unknown_setting', _at(p, 'is'), s.type == 'toggle' ? 'is "on" or "off" for a switch.' : '"$value" isn\'t one of its values: ${s.options.map((o) => o.value).join(', ')}.');
        }
        setting = key;
        settingIs = value;
      } else if (v is! double) {
        error('wrong_type', p, 'is a switch\'s key, or {"key": …, "is": …}.');
      }
    }
    String? section;
    if (m.containsKey('section')) {
      final p = _at(path, 'section');
      if (!where.action) {
        error('section_condition', p, 'Only a button\'s condition can ask which section it is in.');
      } else {
        section = string(m, 'section', path);
        if (section != null && section != 'main' && !sectionKinds.containsKey(section)) error('unknown_section', p, '"$section" is none of its sections, nor "main".');
      }
    }
    return PackWhen(from: from, tagged: tagged, untagged: untagged, setting: setting, settingIs: settingIs, section: section);
  }

  PackSection? _section(Object? raw, String p, Set<String> keys) {
    final m = object(raw, p, 'A section');
    if (m == null) return null;
    known(m, p, const {'key', 'label', 'icon', 'kind', 'leavesMain', 'takes', 'row'}, _notInSection);
    final key = string(m, 'key', p, required: true);
    if (key != null) {
      if (!_sectionKey.hasMatch(key)) {
        error('bad_key', _at(p, 'key'), '"$key": a section\'s key is 1 to 12 lower-case letters, no digits.');
      } else if (!keys.add(key)) {
        error('duplicate', _at(p, 'key'), '"$key" is another section\'s key too.');
      }
    }
    final label = text(m, 'label', p, required: true, max: 24);
    if (label != null && packTextOk(label)) reserved(label, _at(p, 'label'));
    final icon = string(m, 'icon', p, required: true);
    if (icon != null) iconName(icon, _at(p, 'icon'));
    final kind = string(m, 'kind', p, required: true);
    if (kind != null && kind != 'tab' && kind != 'filter') error('bad_verb', _at(p, 'kind'), '"$kind": a section is a "tab" or a "filter".');
    final leavesMain = boolean(m, 'leavesMain', p);
    if (leavesMain != null && kind == 'filter') error('leaves_main_on_filter', _at(p, 'leavesMain'), 'is a tab\'s: a kind in the filter stays in Messages while it is shown.');
    PackWhen? takes;
    if (!m.containsKey('takes')) {
      error('missing', _at(p, 'takes'), 'is needed: which conversations it takes.');
    } else {
      takes = _when(m['takes'], _at(p, 'takes'), const _Where.elsewhere());
      if (takes != null && takes.tagged.isEmpty && takes.from.isEmpty) error('takes_nothing', _at(p, 'takes'), 'takes nothing without "tagged" or "from".');
    }
    final row = m.containsKey('row') ? _row(m['row'], _at(p, 'row')) : null;
    if (key == null || label == null || icon == null || kind == null || takes == null) return null;
    return PackSection(key: key, label: label, icon: icon, kind: kind, leavesMain: leavesMain ?? true, takes: takes, row: row);
  }

  /// How a section draws its rows: a value and a caption as templates, a face, and up to three of its buttons by id.
  PackRow? _row(Object? raw, String p) {
    final m = object(raw, p, 'A row');
    if (m == null) return null;
    known(m, p, const {'value', 'caption', 'face', 'end', 'word', 'tap'}, _notInRow);
    final value = _template(m, 'value', p, max: 24);
    final caption = _template(m, 'caption', p, max: 60);
    String? faceName;
    int? faceColor;
    if (m.containsKey('face')) {
      final q = _at(p, 'face');
      final face = object(m['face'], q, 'A face');
      if (face != null) {
        known(face, q, const {'name', 'color'}, _notInFace);
        faceName = text(face, 'name', q, required: true, max: 24, braces: false);
        final colour = string(face, 'color', q, required: true);
        if (colour != null) {
          if (_colour.hasMatch(colour)) {
            faceColor = int.parse(colour.substring(1), radix: 16);
          } else {
            error('bad_color', _at(q, 'color'), '"$colour": a colour is # and six hex digits, as #4F46E5.');
          }
        }
      }
    }
    String? action(String key) {
      final id = string(m, key, p);
      if (id == null) return null;
      final a = actionsById[id];
      final q = _at(p, key);
      if (a == null || !a.slots.contains('row')) {
        error('unknown_action', q, '"$id" is none of its buttons that list "row" in their slots.');
      } else if (a.verb == 'write') {
        error('verb_not_here', q, 'A row\'s button can\'t write: only a conversation\'s header and a message\'s menu can.');
      } else if (key == 'tap' && a.verb != 'copy') {
        error('verb_not_here', q, 'Tapping a row can only copy: a tap on what looks like a conversation never opens a page or changes anything.');
      }
      return id;
    }

    return PackRow(value: value, caption: caption, faceName: faceName, faceColor: faceColor, end: action('end'), word: action('word'), tap: action('tap'));
  }

  /// [text] that may hold {tag:…} placeholders, each checked ([_checkTemplate]).
  String? _template(Map<String, Object?> m, String key, String path, {required int max}) {
    final v = text(m, key, path, max: max, placeholders: true);
    if (v != null) _checkTemplate(v, _at(path, key));
    return v;
  }

  // A.8.7: {tag:<name>} placeholders of its own tags, {{ and }} for braces, nothing else in braces.
  void _checkTemplate(String v, String p) {
    var i = 0;
    while (i < v.length) {
      final c = v[i];
      if (c == '{') {
        if (i + 1 < v.length && v[i + 1] == '{') {
          i += 2;
          continue;
        }
        final end = v.indexOf('}', i + 1);
        if (end < 0) return error('bad_template', p, 'A "{" is never closed: write {{ for a brace itself.');
        final inside = v.substring(i + 1, end);
        if (!inside.startsWith('tag:')) return error('bad_template', p, '"{$inside}" isn\'t a placeholder: they are {tag:<a tag of its own>}.');
        final name = inside.substring('tag:'.length);
        if (!allTags.contains(name)) error('unknown_tag', p, '"$name" is no tag of this plugin\'s.');
        i = end + 1;
        continue;
      }
      if (c == '}') {
        if (i + 1 < v.length && v[i + 1] == '}') {
          i += 2;
          continue;
        }
        return error('bad_template', p, 'A "}" with no "{" before it: write }} for a brace itself.');
      }
      i++;
    }
  }

  /// One button: its verb's own fields and no other verb's, and its slots, of which [inSlot] counts how many buttons
  /// each has so far across the pack.
  PackAction? _action(Object? raw, String p, Set<String> ids, Map<String, int> inSlot) {
    final m = object(raw, p, 'A button');
    if (m == null) return null;
    known(m, p, const {'id', 'label', 'icon', 'slots', 'when', 'do', 'text', 'say', 'to', 'url'});
    final id = string(m, 'id', p, required: true);
    if (id != null) {
      if (!_actionId.hasMatch(id)) {
        error('bad_key', _at(p, 'id'), '"$id": a button\'s id is 1 to 24 lower-case letters and digits, starting with a letter.');
      } else if (!ids.add(id)) {
        error('duplicate', _at(p, 'id'), '"$id" is another button\'s id too.');
      }
    }
    final label = text(m, 'label', p, required: true, max: 32, braces: false);
    final icon = string(m, 'icon', p, required: true);
    if (icon != null) iconName(icon, _at(p, 'icon'));
    final slotsRaw = list(m, 'slots', p, required: true, min: 1, max: 4);
    final slots = slotsRaw == null ? const <String>[] : strings(slotsRaw, _at(p, 'slots'));
    for (var j = 0; j < slots.length; j++) {
      if (!packSlots.contains(slots[j])) error('bad_slot', '${_at(p, 'slots')}[$j]', '"${slots[j]}" isn\'t a place for a button: ${packSlots.join(', ')}.');
    }
    final verb = string(m, 'do', p, required: true);
    final verbOk = verb != null && packVerbs.contains(verb);
    if (verb != null && !verbOk) error('bad_verb', _at(p, 'do'), '"$verb" isn\'t something a button does: ${packVerbs.join(', ')}.');
    final when = m.containsKey('when') ? _when(m['when'], _at(p, 'when'), const _Where.action()) : null;
    String? words, say, to, url;
    if (verbOk) {
      for (final f in _allVerbFields) {
        if (m.containsKey(f) && !_verbFields[verb]!.contains(f)) error('verb_fields', _at(p, f), 'A "$verb" button has no "$f".');
      }
      for (final f in _verbNeeds[verb]!) {
        if (!m.containsKey(f)) error('verb_fields', _at(p, f), 'is needed for a "$verb" button.');
      }
      switch (verb) {
        case 'say':
          words = text(m, 'text', p, max: 80, braces: false);
        case 'copy':
          words = _template(m, 'text', p, max: 200);
          say = text(m, 'say', p, max: 80, braces: false);
        case 'write':
          words = text(m, 'text', p, max: 300, braces: false);
        case 'move':
          to = string(m, 'to', p);
          if (to != null && to != 'main') {
            if (!sectionKinds.containsKey(to)) {
              error('unknown_section', _at(p, 'to'), '"$to" is none of its sections, nor "main".');
            } else if (sectionKinds[to] == 'filter') {
              error('verb_not_here', _at(p, 'to'), '"$to" is a kind in the filter: a kind is shown or hidden, never filed into.');
            }
          }
        case 'link':
          url = string(m, 'url', p);
          if (url != null && (links.isEmpty || url != links.first)) error('link_not_declared', _at(p, 'url'), 'is the plugin\'s one address in "links", exactly: ${links.isEmpty ? 'it has none' : links.first}.');
      }
      for (var j = 0; j < slots.length; j++) {
        final slot = slots[j];
        if (verb == 'write' && slot != 'conversation.header' && slot != 'conversation.message.menu') error('verb_not_here', '${_at(p, 'slots')}[$j]', 'A button that writes goes in a conversation\'s header or a message\'s menu, where there is something being written.');
        if (verb == 'move' && slot == 'conversation.message.menu') error('verb_not_here', '${_at(p, 'slots')}[$j]', 'A message\'s menu can\'t move a conversation.');
      }
    }
    for (var j = 0; j < slots.length; j++) {
      final slot = slots[j];
      if (!packSlots.contains(slot) || slot == 'row') continue;
      final n = inSlot[slot] = (inSlot[slot] ?? 0) + 1;
      if (slot == 'conversation.header' && n > PackLimits.headerActions) error('header_full', '${_at(p, 'slots')}[$j]', 'A conversation\'s header has room for one button of a plugin\'s.');
      if (slot != 'conversation.header' && n > PackLimits.menuActions) error('slot_full', '${_at(p, 'slots')}[$j]', 'A menu has room for ${PackLimits.menuActions} of a plugin\'s lines.');
    }
    if (id == null || label == null || icon == null || !verbOk) return null;
    return PackAction(id: id, label: label, icon: icon, verb: verb, slots: List.unmodifiable(slots), when: when, text: words, say: say, to: to, url: url);
  }

  /// One incoming rule: what is done to texts arriving in one of its sections, behind a switch that starts off.
  PackIncoming? _incoming(Object? raw, String p) {
    final m = object(raw, p, 'An incoming rule');
    if (m == null) return null;
    known(m, p, const {'in', 'do', 'setting', 'when'});
    final section = string(m, 'in', p, required: true);
    if (section != null && !sectionKinds.containsKey(section)) error('unknown_section', _at(p, 'in'), '"$section" is none of its sections.');
    final doRaw = list(m, 'do', p, required: true, min: 1, max: 2);
    final verbs = doRaw == null ? const <String>[] : strings(doRaw, _at(p, 'do'));
    for (var j = 0; j < verbs.length; j++) {
      if (verbs[j] != 'markread' && verbs[j] != 'mute') error('bad_verb', '${_at(p, 'do')}[$j]', '"${verbs[j]}": as a text comes a plugin can "markread" or "mute", nothing else.');
    }
    final setting = string(m, 'setting', p, required: true);
    if (setting != null) {
      final s = settingsByKey[setting];
      if (s == null) {
        error('unknown_setting', _at(p, 'setting'), '"$setting" is none of its settings.');
      } else if (s.type != 'toggle' || s.fallback) {
        error('incoming_needs_toggle', _at(p, 'setting'), 'is a switch that starts off ("default": false): nothing is marked read or silenced until the person switches it on.');
      }
    }
    final when = m.containsKey('when') ? _when(m['when'], _at(p, 'when'), const _Where.elsewhere()) : null;
    if (section == null || setting == null) return null;
    return PackIncoming(section: section, verbs: List.unmodifiable(verbs), setting: setting, when: when);
  }

  // --- permissions (A.11): each used is listed, and each listed used ---------------------------------------------------

  void _permissions(PackRules rules, Set<PackPermission> listed, List<String> words) {
    final verbs = {for (final a in rules.actions) a.verb};
    final asks = {for (final r in rules.incoming) ...r.verbs};
    final used = <PackPermission, String>{
      if (rules.sections.isNotEmpty) PackPermission.sort: 'it has a section',
      if (verbs.contains('move')) PackPermission.move: 'a button moves conversations',
      if (verbs.contains('markread') || asks.contains('markread')) PackPermission.markRead: verbs.contains('markread') ? 'a button marks texts read' : 'an incoming rule marks texts read',
      if (asks.contains('mute')) PackPermission.mute: 'an incoming rule silences texts',
      if (verbs.contains('copy')) PackPermission.copy: 'a button copies',
      if (verbs.contains('write')) PackPermission.write: 'a button writes',
      if (verbs.contains('link')) PackPermission.links: 'a button opens its link',
    };
    for (final e in used.entries) {
      if (!listed.contains(e.key)) error('needs_permission', 'permissions', '"${e.key.wire}" is needed: ${e.value}.');
    }
    for (var i = 0; i < words.length; i++) {
      final p = PackPermission.byWire(words[i]);
      if (p != null && !used.containsKey(p)) error('permission_unused', 'permissions[$i]', '"${words[i]}" isn\'t used by any rule: a plugin asks only for what it does.');
    }
  }
}

/// [v] made unmodifiable at every depth: the pack's JSON as parsed, which nothing may change in place (D.8 works on a
/// deep copy).
Object? _frozen(Object? v) {
  if (v is Map) return Map<String, Object?>.unmodifiable({for (final e in v.entries) e.key as String: _frozen(e.value)});
  if (v is List) return List<Object?>.unmodifiable([for (final x in v) _frozen(x)]);
  return v;
}
