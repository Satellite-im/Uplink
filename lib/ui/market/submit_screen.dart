/// Submit a plugin (Matt, 2026-11-20: "Add a submission area with a form to accept an icon, description, plugin tags,
/// etc", and "I would like users to be able to develop and submit their own plugins to our plugin marketplace and I'd
/// like to be able to verify them for the store through a review process"): a plugin's file loaded (chosen, pasted, or
/// one in development), how it is listed (its icon, name, short line, description, category, colour and tags), this
/// version (its number, what's new, where to get help), its screenshots, whether to list it once approved, notes for the
/// reviewer and the agreement, then sent for review signed with this device's hub key.
///
/// The form's values are a draft kept per plugin (MarketState), so leaving the Marketplace loses nothing, and loading a
/// corrected copy of the same plugin keeps every field the person changed here. Each change is checked as the reviewer
/// will check it (parsePackJson with `submission`), and the Marketplace is asked, before anything else is filled in,
/// whether it would take the plugin at all (route 8's check: the id, the username, the quotas).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../platform_info.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show Clipboard, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_api.dart';
import '../../market/market_files.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../../me/me.dart';
import '../../net/net.dart';
import '../../plugins/pack/pack.dart';
import '../../plugins/plugin.dart';
import '../../plugins/registry.dart' show AppStore;
import '../../sms.dart';
import '../common.dart';
import '../plugins_page/market_parts.dart' show MarketChip;
import '../plugins_page/plugin_art.dart';
import '../settings_panes.dart' show appVersion;
import '../shell.dart';
import 'market_forms.dart';
import 'my_submissions.dart';
import 'try_pack.dart';
import '../../l10n/words.dart';

/// Where the form is drawn, as it decides what it offers: Android and a Mac choose files; Windows has no picture panel;
/// a computer pastes pictures.
String get _platform => SubmitPluginScreen.debugPlatform ?? (PlatformInfo.isAndroid ? 'android' : (PlatformInfo.isMacOS ? 'macos' : (PlatformInfo.isWindows ? 'windows' : (PlatformInfo.isIOS ? 'ios' : 'linux'))));
bool get _canPickFile => SubmitPluginScreen.debugPlatform == null ? canPickPluginFile : (_platform == 'android' || _platform == 'macos');
bool get _canChoosePicture => _platform != 'windows';
bool get _computer => SubmitPluginScreen.debugPlatform == null ? Sms.computer : (_platform == 'macos' || _platform == 'windows' || _platform == 'linux');

/// The fields a check's issue belongs under, by the first part of its path; anything else is the plugin's own (its id,
/// rules, permissions, settings), under "The plugin".
const Map<String, String> _sectionOf = {
  'name': 'listed', 'tagline': 'listed', 'description': 'listed', 'icon': 'listed', 'symbol': 'listed', 'hue': 'listed', 'shelf': 'listed', 'labels': 'listed',
  'version': 'version', 'whatsNew': 'version', 'support': 'version', 'minApp': 'version',
  'shots': 'shots',
  'developer': 'send',
};

/// The form's name for the field at [path], for the list of problems.
String _fieldName(String path) {
  final top = path.split(RegExp(r'[.\[]')).first;
  return switch (top) {
    'name' => 'Name',
    'tagline' => 'Short line',
    'description' => 'Description',
    'icon' => 'Icon',
    'hue' => 'Colour',
    'shelf' => 'Category',
    'labels' => 'Tags',
    'version' => 'Version',
    'whatsNew' => 'What\'s new',
    'support' => 'Help link or email',
    'shots' => 'Screenshots',
    'developer' => 'Username',
    _ => 'The plugin',
  };
}

/// [i]'s words without the path the checker puts in front of them, for under the field it is about.
String _bare(PackIssue i) => i.path.isNotEmpty && i.message.startsWith('${i.path}: ') ? i.message.substring(i.path.length + 2) : i.message;

/// A loaded pack in a few words: its id and version, then how many tag rules, tabs, kinds and buttons it has.
String packSummary(PluginPack p) {
  String n(int count, String one, String many) => '$count ${count == 1 ? one : many}';
  final tabs = p.rules.sections.where((s) => s.kind == 'tab').length, kinds = p.rules.sections.length - tabs;
  return [
    '${p.id} · ${p.version}',
    [n(p.rules.tags.length, 'tag rule', 'tag rules'), if (tabs > 0) n(tabs, 'tab', 'tabs'), if (kinds > 0) n(kinds, 'kind', 'kinds'), if (p.rules.actions.isNotEmpty) n(p.rules.actions.length, 'button', 'buttons')].join(', '),
  ].join(' · ');
}

/// [version] with its last part one higher (1.2.3 → 1.2.4), or as it is where it isn't a version.
String nextVersion(String version) {
  final m = packVersionPattern.firstMatch(version);
  if (m == null) return version;
  return '${m.group(1)}.${m.group(2)}.${int.parse(m.group(3)!) + 1}';
}

/// One of the form's screenshots: new bytes the app made (a plain PNG), or one kept from an earlier submission of the
/// plugin by its SHA-256, its thumbnail fetched once (route 12).
class _Shot {
  _Shot.fresh(Uint8List this.bytes)
      : sha = sha256Hex(bytes),
        kept = false;
  _Shot.kept(this.sha) : kept = true;
  final String sha;
  final bool kept;
  Uint8List? bytes;
}

/// Marketplace › Submit a plugin: the form. What isn't required is for a test, or to start it with a pack already.
class SubmitPluginScreen extends StatefulWidget {
  const SubmitPluginScreen({super.key, this.api, this.market, this.pickFile, this.pickPicture, this.pastePicture, this.iconOf, this.shotOf, this.start, this.startVersion, this.startFor, this.from, this.hub});

  /// The Marketplace: MarketState.instance.api where null, which is Uplink's own (MarketApi.live) in the app.
  final MarketApi? api;
  final MarketState? market;
  final Future<PickedPlugin?> Function()? pickFile;
  final Future<Uint8List?> Function()? pickPicture;
  final Future<Uint8List?> Function()? pastePicture;

  /// How a picture becomes the plugin's icon (pluginIconOf) and a screenshot (shrinkScreenshot): a test passes its own,
  /// since picture work doesn't finish under a widget test's clock.
  final Future<String?> Function(Uint8List bytes)? iconOf;
  final Future<Uint8List?> Function(Uint8List bytes)? shotOf;

  /// The pack the form starts with: a plugin in development's ("Submit it"), or a submission's ("Submit a new version").
  final PluginPack? start;

  /// The version the form starts at, where it isn't [start]'s own.
  final String? startVersion;

  /// The id of the plugin in development the form was opened for ("Submit it"): where its newest copy doesn't load,
  /// the form says so with its problems, and never starts with another plugin it held before (review, 2026-11-20).
  final String? startFor;

  /// The submission "Submit a new version" was pressed on: its screenshots start the form as kept ones.
  final SubmissionView? from;

  /// The server this app uses (Net.instance.hubUrl where null): a test's other server.
  final String? hub;

  /// For a test: the platform the form is drawn for ('android', 'macos', 'windows'), in place of this one.
  @visibleForTesting
  static String? debugPlatform;

  @override
  State<SubmitPluginScreen> createState() => _SubmitPluginScreenState();
}

class _SubmitPluginScreenState extends State<SubmitPluginScreen> with WidgetsBindingObserver {
  // The Marketplace's own api where none is given: in the app MarketApi.live(), Uplink's own relay signed
  // with this install's hub key; a test's Marketplace in a test.
  MarketState get _market => widget.market ?? MarketState.instance;
  late final MarketApi _api = widget.api ?? _market.api;

  final _name = TextEditingController();
  final _tagline = TextEditingController();
  final _description = TextEditingController();
  final _version = TextEditingController();
  final _whatsNew = TextEditingController();
  final _support = TextEditingController();
  final _notes = TextEditingController();

  /// The pack as loaded from its file, and its JSON, which every send starts from a deep copy of.
  PluginPack? _pack;
  Map<String, Object?> _base = const {};

  /// What was wrong with a file that didn't load at all.
  List<PackIssue> _fileIssues = const [];

  String? _icon;
  String _hue = 'slate';
  String _shelf = 'tools';
  List<String> _labels = [];
  List<_Shot> _shots = [];
  bool _list = true;
  bool _agree = false;

  /// The fields the person changed here: a corrected copy of the same plugin keeps these and takes the rest from its
  /// file.
  Set<String> _changed = {};

  /// The form as the reviewer will check it, made again with every change.
  PackParse? _parse;

  /// The Marketplace's answer to route 8's check: a refusal (id_taken, not_owner, version_not_newer, the quotas), or
  /// null; [_checked] once it has answered at all.
  MarketError? _check;
  bool _checked = false, _checking = false;
  String? _checkedVersion;

  /// The SHA-256 of the bytes last checked: a refusal of those bytes themselves ("That exact plugin was sent
  /// already") no longer holds once they differ.
  String? _checkedSha;
  bool _checkWasIncomplete = false;
  int _checks = 0;

  bool _busy = false, _sending = false, _sent = false;
  MarketError? _refused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // What route 9 says of this developer (blocked, their plugins' versions, earlier screenshots), read again now.
    if (_api.signer != null) unawaited(_market.readMine().then((_) => _changedLater()));
    final asked = widget.startFor == null ? null : InstalledPlugins.instance.devOf(widget.startFor!);
    if (widget.start == null && asked != null && asked.pack == null) {
      _fileIssues = asked.issues.isEmpty ? [PackIssue('invalid', '', '${asked.id}\'s newest copy doesn\'t load: see its problems in Settings › Developer.')] : asked.issues;
      return;
    }
    final remembered = _market.submitting;
    final start = widget.start ?? (remembered == null ? null : (InstalledPlugins.instance.devOf(remembered.id)?.pack ?? remembered));
    if (start != null) _apply(start, startVersion: widget.start != null ? widget.startVersion : null);
  }

  /// Written to disk as the app goes to the background: Android may end it there, Choose a picture's picker among the
  /// ways, and what was typed since the last write was in memory alone (review, 2026-11-20).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) _keep(toDisk: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Kept as it stands, with its screenshots, for whenever the form is opened again.
    _keep(toDisk: true);
    for (final c in [_name, _tagline, _description, _version, _whatsNew, _support, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Route 9 answered: the version listed may be known only now, and a version the person didn't choose goes above it.
  void _changedLater() {
    if (!mounted) return;
    final pack = _pack, current = _current;
    final bump = pack != null && current != null && !_changed.contains('version') && _notNewer(_version.text.trim(), current);
    if (bump) _version.text = nextVersion(current);
    setState(_reparse);
    if (bump) {
      _keep();
      unawaited(_maybeCheck());
    }
  }

  // --- the draft --------------------------------------------------------------------------------------------------

  /// The form as it stands, for [MarketState] to keep: every field, and which of them the person changed here.
  SubmitDraft _draft() => SubmitDraft(
        packId: _pack!.id,
        name: _name.text,
        tagline: _tagline.text,
        description: _description.text,
        icon: _icon,
        hue: _hue,
        shelf: _shelf,
        labels: [..._labels],
        version: _version.text,
        whatsNew: _whatsNew.text,
        support: _support.text,
        shots: [for (final s in _shots) s.kept ? DraftShot(keep: s.sha) : DraftShot(bytes: s.bytes)],
        notes: _notes.text,
        list: _list,
        agree: _agree,
        changed: {..._changed},
      );

  /// Keeps the form as it stands: in memory at every change, on disk where [toDisk].
  void _keep({bool toDisk = false}) {
    if (_pack == null || _sent) return;
    unawaited(_market.saveDraft(_draft(), toDisk: toDisk));
  }

  // --- loading a pack ---------------------------------------------------------------------------------------------

  /// The form filled from [pack]: each field from the draft kept for its id where the person changed it there, else
  /// from the file; the notes, the listing switch, the agreement and the screenshots from the draft where there is one.
  void _apply(PluginPack pack, {String? startVersion}) {
    final d = _market.draftOf(pack.id);
    bool mine(String field) => d != null && d.changed.contains(field);
    _pack = pack;
    _market.submitting = pack;
    _fileIssues = const [];
    _base = (jsonDecode(jsonEncode(pack.json)) as Map).cast<String, Object?>();
    _changed = {...?d?.changed};
    _name.text = mine('name') ? d!.name ?? pack.name : pack.name;
    _tagline.text = mine('tagline') ? d!.tagline ?? pack.tagline : pack.tagline;
    _description.text = mine('description') ? d!.description ?? pack.description : pack.description;
    _icon = mine('icon') ? d!.icon : (pack.json['icon'] is String ? pack.json['icon'] as String : null);
    _hue = mine('hue') ? d!.hue ?? pack.hue : pack.hue;
    _shelf = mine('shelf') ? d!.shelf ?? pack.shelf : pack.shelf;
    _labels = mine('labels') ? [...?d!.labels] : [...pack.labels];
    final current = _market.currentVersionOf(pack.id);
    _version.text = mine('version') ? d!.version ?? pack.version : (startVersion ?? (current != null && _notNewer(pack.version, current) ? nextVersion(current) : pack.version));
    _whatsNew.text = mine('whatsNew') ? d!.whatsNew ?? '' : (pack.whatsNew ?? '');
    _support.text = mine('support') ? d!.support ?? '' : (pack.support ?? '');
    _notes.text = d?.notes ?? '';
    _list = d?.list ?? true;
    _agree = d?.agree ?? false;
    if (mine('shots')) {
      _shots = [for (final s in d!.shots) if (s.keep != null) _Shot.kept(s.keep!) else if (s.bytes != null) _Shot.fresh(s.bytes!)];
    } else {
      // A new version of a plugin starts with the screenshots it has, kept by their SHA-256 so an update never empties
      // "How it looks": those its package names that an earlier submission of it holds (a submission's own package
      // names exactly its screenshots), else those of the submission "Submit a new version" was pressed on, or of its
      // current version. A hash no earlier submission holds can't be kept, and is left out.
      final holders = [?widget.from, ...?_market.mine?.submissions.where((s) => s.plugin == pack.id)];
      final known = {for (final h in holders) ...h.shots};
      final named = [for (final sha in pack.shots) if (known.contains(sha)) sha];
      final earlier = widget.from ?? holders.where((s) => s.shots.isNotEmpty && (s.listing != null || s.status == 'approved')).firstOrNull;
      final kept = named.isNotEmpty ? named : (earlier?.plugin == pack.id ? earlier!.shots : const <String>[]);
      _shots = [for (final sha in kept.take(PackLimits.shots)) _Shot.kept(sha)];
    }
    _check = null;
    _checked = false;
    _checkedVersion = null;
    _checkedSha = null;
    _reparse();
    _keep(toDisk: true);
    for (final s in _shots) {
      if (s.kept) unawaited(_thumbOf(s));
    }
    unawaited(_maybeCheck());
  }

  static bool _notNewer(String a, String b) {
    try {
      return compareVersions(a, b) <= 0;
    } on FormatException {
      return false;
    }
  }

  /// A kept screenshot's thumbnail: route 12 for an earlier submission that holds it, shown only where its bytes are it.
  Future<void> _thumbOf(_Shot s) async {
    final holders = [?widget.from, ...?_market.mine?.submissions];
    for (final h in holders) {
      final n = h.shots.indexOf(s.sha);
      if (n < 0) continue;
      try {
        final bytes = await _api.submissionShot(h.sid, n);
        if (sha256Hex(bytes) != s.sha || !mounted) continue;
        setState(() => s.bytes = bytes);
        return;
      } catch (_) {}
    }
  }

  /// [bytes] as a plugin's file: loaded where it reads as one, else its problems said under The plugin.
  Future<void> _loadBytes(List<int> bytes) async {
    final parse = parsePack(bytes, appVersion: appVersion);
    if (parse.pack == null) {
      if (!mounted) return;
      setState(() {
        _fileIssues = parse.errors.isEmpty ? parse.issues : parse.errors.toList();
        _pack = null;
        _parse = null;
      });
      return;
    }
    await _loadPack(parse.pack!);
  }

  /// Loads [pack], asking first where it is another plugin than the one in the form.
  Future<void> _loadPack(PluginPack pack) async {
    final had = _pack;
    if (had != null && had.id != pack.id) {
      var again = false;
      await showChoices(context, title: 'Start again with ${pack.id}? What you filled in for ${had.id} is kept for when you load it again.', choices: [
        Choice('Start again with ${pack.id}', Lucide.rotateCcw, () => again = true),
        Choice('Keep ${had.id}', Lucide.x, () {}),
      ]);
      if (!again || !mounted) return;
    }
    // What the form holds now is kept first: a corrected copy of the same plugin takes it back. Another plugin's is
    // written to disk too, as the sheet promised: the form writes only the plugin it holds when it goes, so what was
    // typed for this one was in memory alone, and gone with the app (review, 2026-11-20).
    _keep(toDisk: had != null && had.id != pack.id);
    if (!mounted) return;
    setState(() {
      _refused = null;
      _apply(pack);
    });
  }

  Future<void> _fromFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await (widget.pickFile ?? pickPluginFile)();
      if (picked != null) await _loadBytes(picked.bytes);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t open that file: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasted() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) return toast(context, 'Copy the plugin\'s words first, then paste them here.');
    await _loadBytes(utf8.encode(text));
  }

  void _fromDev() {
    final devs = InstalledPlugins.instance.dev;
    showChoices(context, title: 'Which plugin in development?', choices: [
      for (final d in devs)
        Choice(d.pack?.name ?? d.id, Lucide.flaskConical, () {
          final pack = d.pack;
          if (pack == null) return toast(context, '${d.id} doesn\'t load: see its problems in Settings › Developer.', tone: GlacierToastTone.danger);
          unawaited(_loadPack(pack));
        }, hint: d.pack == null ? 'Doesn\'t load' : '${d.pack!.version} · ${d.pack!.id}'),
    ]);
  }

  // --- the form as the reviewer will read it ----------------------------------------------------------------------

  String? get _username {
    final u = Me.instance.username;
    return u == null ? null : tidyHandle(u);
  }

  /// The loaded pack's JSON, a deep copy, with the form's fields set: what is sent.
  Map<String, Object?> _merged() {
    final m = (jsonDecode(jsonEncode(_base)) as Map).cast<String, Object?>();
    m['name'] = _name.text.trim();
    m['tagline'] = _tagline.text.trim();
    // Line ends one kind: a description pasted from Windows held \r, which the format refuses, unseen (review, 2026-11-20).
    m['description'] = marketWords(_description.text);
    if (_icon == null) {
      m.remove('icon');
    } else {
      m['icon'] = _icon;
    }
    m['hue'] = _hue;
    m['shelf'] = _shelf;
    m['labels'] = [..._labels];
    m['version'] = _version.text.trim();
    final news = marketWords(_whatsNew.text);
    if (news.isEmpty) {
      m.remove('whatsNew');
    } else {
      m['whatsNew'] = news;
    }
    m['support'] = _support.text.trim();
    final who = _username;
    if (who != null) m['developer'] = who;
    m['shots'] = [for (final s in _shots) s.sha];
    return m;
  }

  void _reparse() {
    _parse = _pack == null ? null : parsePackJson(_merged(), appVersion: appVersion, submission: true);
  }

  /// The version the Marketplace holds as current for the loaded plugin, where it has one.
  String? get _current => _pack == null ? null : _market.currentVersionOf(_pack!.id);

  /// What stops it being sent, beyond the checks' own: the version and what's new against the version listed, and the
  /// Marketplace's refusal.
  List<String> get _formProblems {
    final out = <String>[];
    final current = _current;
    final version = _version.text.trim();
    if (current != null && packVersionPattern.hasMatch(version) && _notNewer(version, current)) out.add('Version: higher than $current, the version listed.');
    if (current != null && _whatsNew.text.trim().isEmpty) out.add('What\'s new: say what\'s new in this version.');
    final check = _check;
    if (check != null) out.add(check.message);
    // The notes are held to a plugin's own rule for words by the relay, which answers a slip with "Something in that
    // isn't right." alone: said here, under its name (review, 2026-11-20).
    final notes = marketWordsProblem(marketWords(_notes.text), MarketMost.notes);
    if (notes != null) out.add('Notes: $notes');
    return out;
  }

  List<PackIssue> get _errors => [...?_parse?.errors];

  bool get _serverOther => marketHubIsOther(widget.hub);

  bool get _ready => _pack != null && !_sending && !_sent && _agree && !_serverOther && _errors.isEmpty && _formProblems.isEmpty && _parse?.canonical != null && _api.signer != null && _username != null;

  /// A field the person changed: kept as theirs, the form checked again, and the Marketplace asked again where it was
  /// the version.
  void _edited(String field) {
    _changed.add(field);
    setState(() {
      _refused = null;
      _reparse();
    });
    _keep();
    unawaited(_maybeCheck());
  }

  /// Route 8's check, for a loaded pack: when it loads, when its version changes to another version, once more when a
  /// form the check couldn't judge yet (the Marketplace said it has problems) has none, and once more when the bytes it
  /// refused as sent already have changed. A version where changes were asked for starts as the copy sent, which is
  /// "sent already" until the change asked for is made; that refusal held Send back for good, whatever was changed
  /// after it (review, 2026-11-20). [force]: asked again whatever it said before ("Ask the Marketplace again").
  Future<void> _maybeCheck({bool force = false}) async {
    final parse = _parse;
    final bytes = parse?.canonical;
    if (_pack == null || bytes == null || _api.signer == null || _serverOther) return;
    final version = _version.text.trim();
    if (!packVersionPattern.hasMatch(version)) return;
    final sha = sha256Hex(bytes);
    final sentAlready = _check?.code == 'duplicate' && sha != _checkedSha;
    final again = (_checkWasIncomplete && parse!.errors.isEmpty) || sentAlready || force;
    if (_checkedVersion == version && !again) return;
    _checkedVersion = version;
    _checkedSha = sha;
    _checkWasIncomplete = false;
    final mine = ++_checks;
    setState(() {
      _checking = true;
      // Not these bytes' refusal any more: Send is the Marketplace's to judge again.
      if (sentAlready || force) _check = null;
      if (force) _unreachable = false;
    });
    // One at a time, the newest only: two at once ("1.0.1", then "1.0.10"), the Marketplace answers the second
    // rate_limited where the plugin is large (one large body at a time from one key), and that one is the answer kept
    // (review, 2026-11-20). One that is no longer the newest by its turn isn't sent at all.
    final before = _asking;
    final turn = Completer<void>();
    _asking = turn.future;
    MarketError? refused;
    try {
      await before;
      if (!mounted || mine != _checks) return;
      try {
        await _api.check(base64Encode(bytes));
      } on MarketError catch (e) {
        refused = e;
      } catch (_) {
        refused = const MarketError('unreachable', marketUnreachableWords);
      }
    } finally {
      turn.complete();
    }
    if (!mounted || mine != _checks) return;
    setState(() {
      _checking = false;
      // What the form says itself (its problems) isn't the check's to repeat: the check is for what only the
      // Marketplace knows. Unreachable says so, and holds nothing back.
      final incomplete = refused != null && (refused.code == 'invalid_package' || refused.code == 'not_canonical' || refused.code == 'bad_shot');
      // A Marketplace too busy to ask, or broken (503, 500, a proxy's 502), didn't judge the plugin at all: it is as if
      // it couldn't be reached, which holds nothing back, since Send is checked in full anyway. Its "Too much at once.
      // Try again in a minute." held Send back for good over a form with nothing to try again with (review,
      // 2026-11-20). rate_limited stays a refusal: the day's submissions answer the check with it as well.
      final transient = refused != null && (refused.code == 'unreachable' || refused.code == 'busy' || refused.code == 'broken' || refused.status >= 500);
      _checkWasIncomplete = incomplete;
      _check = refused == null || incomplete || transient || refused.code == 'no_identity' ? null : refused;
      _checked = refused == null || !(incomplete || transient);
      _unreachable = transient;
    });
  }

  /// The check couldn't be asked: the Marketplace was out of reach, too busy or broken.
  bool _unreachable = false;

  /// The check being asked now, which the next waits for.
  Future<void> _asking = Future.value();

  // --- pictures ---------------------------------------------------------------------------------------------------

  Future<Uint8List?> _choose() async {
    final pick = widget.pickPicture;
    if (pick != null) return pick();
    final picked = await Sms.instance.pickImages();
    if (picked.isEmpty) return null;
    return File(await Sms.instance.cacheCopy(picked.first)).readAsBytes();
  }

  /// Makes the plugin's icon of the picture [get] gives (chosen or pasted), and keeps the draft.
  Future<void> _iconFrom(Future<Uint8List?> Function() get) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await get();
      if (bytes == null) return;
      final icon = await (widget.iconOf ?? pluginIconOf)(bytes);
      if (!mounted) return;
      if (icon == null) return toast(context, 'Couldn\'t make an icon of that picture.', tone: GlacierToastTone.danger);
      _icon = icon;
      _edited('icon');
      _keep(toDisk: true);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Adds the picture [get] gives as a screenshot, up to [PackLimits.shots] of them and never the same one twice.
  Future<void> _shotFrom(Future<Uint8List?> Function() get) async {
    if (_busy || _shots.length >= PackLimits.shots) return;
    setState(() => _busy = true);
    try {
      final bytes = await get();
      if (bytes == null) return;
      // Always a PNG made again here: no EXIF, no text, nothing but its pixels goes to the Marketplace.
      final png = await (widget.shotOf ?? shrinkScreenshot)(bytes);
      if (!mounted) return;
      if (png == null) return toast(context, 'Couldn\'t use that picture: a screenshot is 64 to 2,400 pixels a side.', tone: GlacierToastTone.danger);
      if (_shots.any((s) => s.sha == sha256Hex(png))) return toast(context, 'That screenshot is in already.');
      _shots = [..._shots, _Shot.fresh(png)];
      _edited('shots');
      _keep(toDisk: true);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t add the screenshot: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _samples() async {
    final pack = _pack;
    if (pack == null) return;
    await _shotFrom(() async {
      final png = await samplesPicture(context, pack);
      if (png == null && mounted) toast(context, 'None of the sample texts go to ${pack.name}\'s tabs or kinds.');
      return png;
    });
  }

  void _removeShot(int i) {
    _shots = [..._shots]..removeAt(i);
    _edited('shots');
    _keep(toDisk: true);
  }

  // --- choices ----------------------------------------------------------------------------------------------------

  void _chooseShelf() => showChoices(context, title: 'Category', choices: [
        for (final s in packShelves)
          Choice(PluginShelf.values.asNameMap()[s]?.label ?? s, s == _shelf ? Lucide.check : Lucide.layoutGrid, () {
            _shelf = s;
            _edited('shelf');
          }),
      ]);

  void _chooseHue() {
    final t = context.tokens;
    showChoices(context, title: 'Colour', choices: [
      for (final h in packHues)
        Choice(_hueWords(h), Lucide.circle, () {
          _hue = h;
          _edited('hue');
        }, mark: _swatch(t, h, chosen: h == _hue)),
    ]);
  }

  static String _hueWords(String hue) => '${hue[0].toUpperCase()}${hue.substring(1)}';

  static Widget _swatch(Tokens t, String hue, {bool chosen = false}) {
    final c = PluginHues.of(t, hue);
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(gradient: c.gradient, shape: BoxShape.circle, border: chosen ? Border.all(color: t.color('app-ink'), width: 2) : null),
    );
  }

  void _label(String wire) {
    if (_labels.contains(wire)) {
      _labels = [..._labels]..remove(wire);
    } else {
      if (_labels.length >= PackLimits.labels) return toast(context, 'Up to ${PackLimits.labels} tags.');
      _labels = [..._labels, wire];
    }
    _edited('labels');
  }

  // --- sending ----------------------------------------------------------------------------------------------------

  /// Sends the package in its canonical form with the screenshots and notes, drops the draft, and goes to My
  /// submissions with the new one marked. What the Marketplace refuses stays on the form.
  Future<void> _send() async {
    if (!_ready) return;
    final pack = _pack!;
    final parse = parsePackJson(_merged(), appVersion: appVersion, submission: true);
    if (parse.errors.isNotEmpty || parse.canonical == null) return setState(() => _parse = parse);
    setState(() {
      _sending = true;
      _refused = null;
    });
    try {
      final view = await _api.submit(SubmissionRequest(
        package: base64Encode(parse.canonical!),
        shots: [for (final s in _shots) s.kept ? ShotUpload.kept(s.sha) : ShotUpload.png(s.bytes!)],
        notes: marketWords(_notes.text),
        list: _list,
        agree: true,
      ));
      _sent = true;
      unawaited(_market.submitted(view));
      unawaited(_market.dropDraft(pack.id));
      _market.submitting = null;
      if (!mounted) return;
      toast(context, 'Sent for review', tone: GlacierToastTone.success);
      final shell = AppShell.maybeOf(context);
      if (shell != null) {
        shell.marketplace(section: 'mine', arg: view.sid);
      } else {
        Navigator.of(context).pushReplacement(PageRouteBuilder<void>(pageBuilder: (_, _, _) => MySubmissionsScreen(api: widget.api, highlight: view.sid)));
      }
    } on MarketError catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _refused = e;
      });
      toast(context, e.message, tone: GlacierToastTone.danger);
    }
  }

  // --- drawing ----------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Me.instance, _market, InstalledPlugins.instance]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(height: t.space(5));
    final server = _serverOther;
    final Widget? block;
    if (_api.signer == null) {
      block = marketWhoBlock(context, key: const ValueKey('market-submit-who'), rowKey: const ValueKey('market-submit-me'));
    } else if (_username == null) {
      block = MarketBlock(
        key: const ValueKey('market-submit-username'),
        words: 'Claim a username in Settings › Me first: your plugin is listed under it.',
        icon: Lucide.atSign,
        action: 'Open Settings › Me',
        actionKey: const ValueKey('market-submit-me'),
        onAction: () => openSettingsMe(context),
      );
    } else if (_market.mine?.blocked == true) {
      block = const MarketBlock(key: ValueKey('market-submit-blocked'), words: 'This account can\'t submit plugins.', icon: Lucide.ban);
    } else {
      block = null;
    }
    return GhostPage(
      key: const ValueKey('market-submit'),
      title: 'Submit a plugin',
      actions: [docsButton('plugin-submit')],
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: LayoutBuilder(builder: (context, box) {
          final side = math.max(t.space(4), (box.maxWidth - 640) / 2);
          return ListView(
            key: const ValueKey('market-submit-list-view'),
            padding: EdgeInsetsDirectional.fromSTEB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              if (server) ...[
                PaneSection(children: [SettingRow(key: const ValueKey('market-submit-server'), icon: const AppIcon(Lucide.globe, size: 18), label: marketServerWords(widget.hub ?? Net.instance.hubUrl))]),
                gap,
              ],
              if (block != null) block else ..._form(context, t, gap),
            ],
          );
        }),
      ),
    );
  }

  /// [issues] under a section, each in its own words.
  Widget? _issuesUnder(Tokens t, List<PackIssue> issues) {
    if (issues.isEmpty) return null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final i in issues.take(12)) Text('${_fieldName(i.path)}: ${_bare(i)}', style: TextStyle(color: t.danger)),
      if (issues.length > 12) Text('And ${issues.length - 12} more.', style: TextStyle(color: t.danger)),
    ]);
  }

  List<Widget> _form(BuildContext context, Tokens t, Widget gap) {
    final pack = _pack;
    final errors = _errors;
    List<PackIssue> under(String section) => [for (final e in errors) if ((_sectionOf[e.path.split(RegExp(r'[.\[]')).first] ?? 'plugin') == section) e];
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-2'));
    final mono = TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.45, color: t.color('app-ink-2'));
    final devs = InstalledPlugins.instance.dev;
    final face = pack == null ? null : MarketFace(id: pack.registryId, name: _name.text.ifEmpty(pack.name), symbol: pack.symbol, hue: _hue, iconPng: _iconBytes);
    final current = _current;
    final who = _username ?? '';
    final ownerOff = pack != null && (_market.mine?.plugins.any((p) => p.id == pack.id && p.listing == 'unlisted' && p.by == 'owner') ?? false);
    final checkLine = _checking
        ? 'Asking the Marketplace whether it can take it…'
        : _check != null
            ? _check!.message
            : _unreachable
                ? 'Couldn\'t ask the Marketplace whether it can take it just now. It\'s asked again when you send it.'
                : _checked
                    ? 'The Marketplace can take it.'
                    : null;
    final problems = [
      for (final e in errors) '${_fieldName(e.path)}: ${_bare(e)}',
      ..._formProblems,
      if (_refused != null && _refused!.code != 'invalid_package') _refused!.message,
      for (final i in _refused?.issues ?? const <PackIssue>[]) '${_fieldName(i.path)}: ${_bare(i)}',
    ];
    final sendHint = _sending
        ? 'One moment.'
        : pack == null
            ? 'Load the plugin first.'
            : _serverOther
                ? 'Switch back to Uplink\'s own server first.'
                : problems.isNotEmpty
                    ? 'Put the problems above right first.'
                    : !_agree
                        ? 'Agree to the guidelines first.'
                        : 'It goes to Uplink\'s review. You\'ll hear when it\'s decided.';
    return [
      PaneSection(
        title: 'The plugin',
        description: const Tr('A .ghostplugin file: the plugin\'s rules, and what it says about itself.'),
        footer: _issuesUnder(t, under('plugin')),
        children: [
          if (_canPickFile)
            SettingRow(key: const ValueKey('market-submit-file'), icon: const AppIcon(Lucide.folderOpen, size: 18), label: 'Choose the plugin file', disabled: _sending || _busy, onPress: _fromFile),
          SettingRow(key: const ValueKey('market-submit-paste'), icon: const AppIcon(Lucide.clipboardPaste, size: 18), label: 'Paste the plugin', hint: const Tr('Its words, copied from anywhere.'), disabled: _sending, onPress: () => unawaited(_pasted())),
          if (devs.isNotEmpty) SettingRow(key: const ValueKey('market-submit-dev'), icon: const AppIcon(Lucide.flaskConical, size: 18), label: 'Use one in development', disabled: _sending, onPress: _fromDev),
          if (pack != null)
            SettingRow(
              key: const ValueKey('market-submit-loaded'),
              icon: face == null ? null : PluginTile(plugin: face, size: t.lenOf('1.85rem')),
              label: packSummary(pack),
              hint: checkLine == null ? null : Text(checkLine, key: const ValueKey('market-submit-check'), style: _check != null ? TextStyle(color: t.danger) : null),
            ),
          // Whatever the check last said but "it can take it", it can be asked again: a busy Marketplace, a day's
          // submissions or a username's week pass with time, and nothing in the form changes for them (review,
          // 2026-11-20).
          if (pack != null && !_checking && (_check != null || _unreachable))
            SettingRow(key: const ValueKey('market-submit-check-again'), icon: const AppIcon(Lucide.refreshCw, size: 18), label: 'Ask the Marketplace again', disabled: _sending, onPress: () => unawaited(_maybeCheck(force: true)))
          else if (pack == null && _fileIssues.isNotEmpty)
            SettingRowBox(
              key: const ValueKey('market-submit-loaded'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_fileIssues.length == 1 ? 'It couldn\'t be loaded:' : 'It couldn\'t be loaded: ${_fileIssues.length} problems', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.danger)),
                SizedBox(height: t.space(1)),
                for (final i in _fileIssues.take(20)) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text('${i.code}${i.path.isEmpty ? '' : ' at ${i.path}'}: ${i.message}', style: mono)),
              ]),
            ),
        ],
      ),
      if (pack != null) ...[
        gap,
        TryPackSection(pack, key: ValueKey('market-submit-try-${pack.id}-${pack.version}'), keyPrefix: 'market-submit-', store: AppStore(AppState.of(context))),
        gap,
        PaneSection(
          title: 'How it\'s listed',
          footer: _issuesUnder(t, under('listed')),
          children: [
            SettingRow(
              key: const ValueKey('market-submit-icon'),
              icon: face == null ? const AppIcon(Lucide.image, size: 18) : PluginTile(plugin: face, size: t.lenOf('1.85rem')),
              label: 'Icon',
              hint: Text(_icon == null ? 'A square picture, 64 to 512 pixels a side. Needed to send it.' : 'Its own picture, as it shows on its card and page.'),
              value: _canChoosePicture ? const Tr('Choose a picture') : null,
              disabled: _sending || _busy,
              onPress: _canChoosePicture ? () => unawaited(_iconFrom(_choose)) : null,
            ),
            if (_computer) SettingRow(key: const ValueKey('market-submit-icon-paste'), icon: const AppIcon(Lucide.clipboardPaste, size: 18), label: 'Paste a picture', hint: const Tr('A copied picture becomes its icon.'), disabled: _sending || _busy, onPress: () => unawaited(_iconFrom(widget.pastePicture ?? pastePicture))),
            SettingRowBox(child: GlacierInput(key: const ValueKey('market-submit-name'), controller: _name, placeholder: 'Name'.t, ariaLabel: 'Name', maxLength: PackLimits.name, autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md, readOnly: _sending, onChange: (_) => _edited('name'))),
            SettingRowBox(child: GlacierInput(key: const ValueKey('market-submit-tagline'), controller: _tagline, placeholder: 'Short line: what it does, in a few words'.t, ariaLabel: 'Short line', maxLength: PackLimits.tagline, autoCapitalize: TextCapitalization.sentences, size: GlacierFieldSize.md, readOnly: _sending, onChange: (_) => _edited('tagline'))),
            SettingRowBox(child: MarketTextArea(key: const ValueKey('market-submit-description'), controller: _description, label: 'Description', placeholder: 'Description: what it does, and what it never does'.t, most: PackLimits.description, readOnly: _sending, onChanged: (_) => _edited('description'))),
            SettingRow(key: const ValueKey('market-submit-shelf'), icon: const AppIcon(Lucide.layoutGrid, size: 18), label: 'Category', value: Text(PluginShelf.values.asNameMap()[_shelf]?.label ?? _shelf), disabled: _sending, onPress: _chooseShelf),
            SettingRow(key: const ValueKey('market-submit-hue'), icon: const AppIcon(Lucide.palette, size: 18), label: 'Colour', value: Row(mainAxisSize: MainAxisSize.min, children: [_swatch(t, _hue), SizedBox(width: t.space(2)), Text(_hueWords(_hue))]), disabled: _sending, onPress: _chooseHue),
            SettingRowBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Tags', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                SizedBox(height: t.space(1)),
                Tr('One to four: people find it by them.', style: quiet),
                SizedBox(height: t.space(2)),
                Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                  for (final e in packLabels.entries) MarketChip(key: ValueKey('market-submit-label-${e.key}'), label: e.value, chosen: _labels.contains(e.key), onPress: _sending ? () {} : () => _label(e.key)),
                ]),
              ]),
            ),
          ],
        ),
        gap,
        PaneSection(
          title: 'This version',
          footer: _issuesUnder(t, under('version')),
          children: [
            SettingRow(
              icon: const AppIcon(Lucide.tag, size: 18),
              label: 'Version',
              hint: Text(current == null ? 'Three numbers with dots between them, as 1.0.0.' : 'Higher than $current, the version listed.'),
              control: SizedBox(width: t.lenOf('7rem'), child: GlacierInput(key: const ValueKey('market-submit-version'), controller: _version, ariaLabel: 'Version', size: GlacierFieldSize.sm, readOnly: _sending, onChange: (_) => _edited('version'))),
            ),
            SettingRowBox(child: MarketTextArea(key: const ValueKey('market-submit-whatsnew'), controller: _whatsNew, label: 'What\'s new', placeholder: current == null ? 'What\'s new (for a later version)' : 'What\'s new since $current', most: PackLimits.whatsNew, minLines: 2, maxLines: 6, readOnly: _sending, onChanged: (_) => _edited('whatsNew'))),
            SettingRow(
              icon: const AppIcon(Lucide.mail, size: 18),
              label: 'Help link or email',
              hint: const Tr('Shown on your plugin\'s page for anyone to see.'),
              layout: SettingRowLayout.stacked,
              control: GlacierInput(key: const ValueKey('market-submit-support'), controller: _support, placeholder: 'https://… or you@example.com'.t, ariaLabel: 'Help link or email', autoCorrect: false, autoCapitalize: TextCapitalization.none, size: GlacierFieldSize.md, readOnly: _sending, onChange: (_) => _edited('support')),
            ),
          ],
        ),
        gap,
        PaneSection(
          title: 'Screenshots',
          description: const Tr('Everyone sees these once it\'s listed. Use made-up texts, never real conversations or anyone\'s number.'),
          footer: _issuesUnder(t, under('shots')) ?? Text('Up to ${PackLimits.shots}.'),
          children: [
            if (_shots.isNotEmpty) SettingRowBox(child: Wrap(spacing: t.space(3), runSpacing: t.space(3), children: [for (final (i, s) in _shots.indexed) _thumb(t, i, s)])),
            if (_shots.length < PackLimits.shots) ...[
              if (_canChoosePicture) SettingRow(key: const ValueKey('market-submit-shot-add'), icon: const AppIcon(Lucide.imagePlus, size: 18), label: _busy ? 'Adding…' : 'Add a screenshot', disabled: _sending || _busy, onPress: () => unawaited(_shotFrom(_choose))),
              if (_computer) SettingRow(key: const ValueKey('market-submit-shot-paste'), icon: const AppIcon(Lucide.clipboardPaste, size: 18), label: 'Paste a picture', disabled: _sending || _busy, onPress: () => unawaited(_shotFrom(widget.pastePicture ?? pastePicture))),
              SettingRow(key: const ValueKey('market-submit-shot-samples'), icon: const AppIcon(Lucide.listChecks, size: 18), label: 'Add a picture of the samples', hint: const Tr('The list\'s rows for the sample texts it sorts: made-up texts, safe to show.'), disabled: _sending || _busy, onPress: () => unawaited(_samples())),
            ],
          ],
        ),
        gap,
        PaneSection(
          title: 'Listing',
          children: [
            SettingRow(
              key: const ValueKey('market-submit-listing'),
              icon: const AppIcon(Lucide.store, size: 18),
              label: 'List it once it\'s approved',
              // Taken off the Marketplace by its developer, a plugin's next version is approved unlisted whatever this
              // says (C.6): the switch promised a listing the relay doesn't make (review, 2026-11-20).
              hint: Text(ownerOff
                  ? 'You took it off the Marketplace: approved, it stays off until you list it again in My submissions.'
                  : _list
                      ? 'It goes in the Marketplace as soon as it\'s approved.'
                      : 'Approved, it waits until you list it in My submissions.'),
              control: GlacierSwitch(key: const ValueKey('market-submit-list'), checked: _list && !ownerOff, disabled: _sending || ownerOff, onCheckedChange: (on) => setState(() {
                _list = on;
                _keep();
              }), ariaLabel: 'List it once it\'s approved'),
            ),
          ],
        ),
        gap,
        PaneSection(
          title: 'For the reviewer',
          children: [
            SettingRowBox(
              child: MarketTextArea(
                key: const ValueKey('market-submit-notes'),
                controller: _notes,
                label: 'Notes',
                placeholder: 'Notes for the reviewer (optional): how to try it, what changed'.t,
                most: MarketMost.notes,
                minLines: 3,
                maxLines: 8,
                readOnly: _sending,
                // Checked as they change, and a refusal of what was sent is no longer what the form holds.
                onChanged: (_) {
                  setState(() => _refused = null);
                  _keep();
                },
              ),
            ),
            _PressToggle(
              key: const ValueKey('market-submit-agree'),
              label: 'I made this plugin, and it follows the Marketplace guidelines',
              checked: _agree,
              disabled: _sending,
              onChanged: (on) => setState(() {
                _agree = on;
                _keep();
              }),
            ),
            SettingRow(key: const ValueKey('market-submit-guidelines'), icon: const AppIcon(Lucide.bookOpen, size: 18), label: 'Read the Marketplace guidelines', onPress: () => openDocs('plugin-guidelines')),
          ],
        ),
        gap,
        PaneSection(
          title: 'Send',
          children: [
            SettingRow(key: const ValueKey('market-submit-as'), icon: const AppIcon(Lucide.atSign, size: 18), label: 'As @$who', hint: const Tr('Your username, help link and screenshots are shown to everyone once it\'s listed.')),
            if (problems.isNotEmpty)
              SettingRowBox(
                key: const ValueKey('market-submit-problems'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(problems.length == 1 ? 'One thing to put right' : '${problems.length} things to put right', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.danger)),
                  SizedBox(height: t.space(1)),
                  for (final p in problems.take(30)) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text(p, style: quiet)),
                ]),
              ),
            SettingRow(
              key: const ValueKey('market-submit-send'),
              icon: const AppIcon(Lucide.send, size: 18),
              label: _sending ? 'Sending…' : 'Send for review',
              hint: Text(sendHint),
              disabled: !_ready,
              onPress: _ready ? () => unawaited(_send()) : null,
            ),
          ],
        ),
      ],
    ];
  }

  Uint8List? get _iconBytes {
    final b64 = _icon;
    if (b64 == null) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Widget _thumb(Tokens t, int i, _Shot s) {
    final side = t.lenOf('6rem');
    return SizedBox(
      key: ValueKey('market-submit-shot-$i'),
      width: side,
      height: side,
      child: Stack(children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('md')),
            child: DecoratedBox(
              decoration: BoxDecoration(color: t.color('app-paper-3')),
              child: s.bytes == null
                  ? Center(child: AppIcon(Lucide.image, size: 20, color: t.color('app-ink-3')))
                  : Image.memory(s.bytes!, fit: BoxFit.cover, cacheWidth: 240, gaplessPlayback: true, semanticLabel: 'Screenshot ${i + 1}', errorBuilder: (context, _, _) => Center(child: AppIcon(Lucide.image, size: 20, color: t.color('app-ink-3')))),
            ),
          ),
        ),
        if (s.kept)
          PositionedDirectional(
            start: t.space(1),
            bottom: t.space(1),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(1), vertical: 1),
              decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('sm'))),
              child: Text('Kept', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-2'))),
            ),
          ),
        PositionedDirectional(
          top: t.space(1),
          end: t.space(1),
          child: Container(
            decoration: BoxDecoration(color: t.color('app-paper'), shape: BoxShape.circle),
            child: IconTap(key: ValueKey('market-submit-shot-remove-$i'), icon: Lucide.x, label: 'Remove screenshot ${i + 1}', size: 14, box: t.lenOf('1.75rem'), onPressed: _sending ? null : () => _removeShot(i)),
          ),
        ),
      ]),
    );
  }
}

/// A row with a switch whose whole row toggles it: the agreement, which is read before it is switched.
class _PressToggle extends StatelessWidget implements PaneRow {
  const _PressToggle({super.key, required this.label, required this.checked, required this.onChanged, this.disabled = false});
  final String label;
  final bool checked, disabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : () => onChanged(!checked),
        child: SettingRow(
          icon: const AppIcon(Lucide.circleCheck, size: 18),
          label: label,
          control: GlacierSwitch(checked: checked, disabled: disabled, onCheckedChange: onChanged, ariaLabel: label),
        ),
      );
}

/// The list's rows for the sample texts [pack] sorts, each as the list draws a sorted conversation (its tab or kind,
/// its row's value and caption, the words), drawn off the screen and made a plain PNG: a screenshot of made-up texts
/// alone, never anyone's conversations. Null where it sorts none of them, or the picture couldn't be made.
Future<Uint8List?> samplesPicture(BuildContext context, PluginPack pack) async {
  final rows = <(PackSample, PackTrial)>[];
  for (final s in packSamples) {
    try {
      final r = tryPack(pack, text: s.text, from: s.from);
      if (r.seen && r.section != null) rows.add((s, r));
    } catch (_) {}
  }
  if (rows.isEmpty) return null;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  final key = GlobalKey();
  // Off the screen to the left: drawn and painted as any other entry, never seen.
  final entry = OverlayEntry(builder: (context) => PositionedDirectional(start: -6000, top: 0, width: 400, child: RepaintBoundary(key: key, child: _SampleRows(pack: pack, rows: rows))));
  overlay.insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = key.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return cleanPng(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
  }
}

/// The sample texts' rows as [samplesPicture] draws them.
class _SampleRows extends StatelessWidget {
  const _SampleRows({required this.pack, required this.rows});
  final PluginPack pack;
  final List<(PackSample, PackTrial)> rows;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = t.color('app-ink');
    final face = MarketFace.ofPack(pack);
    String label(String key) => pack.rules.sections.where((s) => s.key == key).firstOrNull?.label ?? key;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Padding(
        padding: EdgeInsets.all(t.space(3)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            PluginTile(plugin: face, size: 28),
            SizedBox(width: t.space(2)),
            Expanded(child: Text(pack.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
          ]),
          SizedBox(height: t.space(2)),
          for (final (s, r) in rows)
            Container(
              margin: EdgeInsets.only(bottom: t.space(2)),
              padding: EdgeInsets.all(t.space(3)),
              decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: PluginHues.of(t, pack.hue).wash, shape: BoxShape.circle),
                  child: Text(s.from.substring(0, math.min(2, s.from.length)), style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: PluginHues.of(t, pack.hue).accent)),
                ),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(s.from, maxLines: 1, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
                      Text(label(r.section!), style: pageText(t, t.fontSize('xs'), weight: 'medium', color: PluginHues.of(t, pack.hue).accent)),
                    ]),
                    if (r.row?.value != null) Text(r.row!.value!, maxLines: 1, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: ink)),
                    if (r.row?.caption != null) Text(r.row!.caption!, maxLines: 1, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                    Text(s.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), height: 1.35, color: t.color('app-ink-2'))),
                  ]),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}
