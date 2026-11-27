/// The packs on this device (Matt, 2026-11-20: "I would like users to be able to develop and submit their own plugins
/// to our plugin marketplace", and "a developer setting for users to be able to manually upload plugins for
/// development testing"): those installed from the Marketplace, each checked again against its approval at every
/// load, and those loaded in Settings › Developer, unreviewed and on only while developer mode is. The disk is what is
/// installed; the app's choices hold only small indexes of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../platform_info.dart';
import '../../aside.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import '../../desktop/store.dart' show DeskStore;
import '../../sms.dart';
import '../plugin.dart';
import '../registry.dart';
import 'canonical.dart';
import 'format.dart';
import 'manifest.dart';
import 'pack_plugin.dart';
import 'review.dart';
import 'review_keys.dart';

/// This device's plugins folder when none is given: on Android the app's own files, on a computer or an iPhone the
/// folder lib/desktop/main.dart keeps everything else in (GHOST_DESK_DIR's where set). Under flutter test, a fresh
/// folder in the system's temp, never the installed app's.
Directory pluginsRoot() {
  if (PlatformInfo.environment.containsKey('FLUTTER_TEST')) return Directory.systemTemp.createTempSync('ghost-plugins-');
  if (PlatformInfo.isAndroid) return Directory('${Directory.systemTemp.parent.path}/files/plugins');
  final dir = PlatformInfo.environment['GHOST_DESK_DIR'];
  final base = dir == null || dir.isEmpty ? DeskStore.defaultDir() : Directory(dir);
  return Directory('${base.path}${PlatformInfo.pathSeparator}plugins');
}

/// Where a pack in development came from, so it can be loaded again.
class DevSource {
  const DevSource(this.kind, {this.url, this.path, this.name});
  final String kind;                // 'file', 'paste', 'link', 'api'
  final String? url;                // a link's address
  final String? path;               // a computer's file; Android's picked copies are not kept
  final String? name;               // the file's name, for the row

  static const kinds = ['file', 'paste', 'link', 'api'];

  /// A link, or a file with a path on a Mac or Windows.
  bool get reloadable => (kind == 'link' && url != null) || (kind == 'file' && path != null && (PlatformInfo.isMacOS || PlatformInfo.isWindows));

  Map<String, Object?> toJson() => {'kind': kind, if (url != null) 'url': url, if (path != null) 'path': path, if (name != null) 'name': name};

  /// FormatException where it isn't one of [kinds].
  factory DevSource.fromJson(Map j) {
    final kind = j['kind'];
    if (kind is! String || !kinds.contains(kind)) throw const FormatException('Not a plugin\'s source');
    String? text(String key) => j[key] is String ? j[key] as String : null;
    return DevSource(kind, url: text('url'), path: text('path'), name: text('name'));
  }
}

/// Something a pack in development threw, or was refused, while it ran.
class DevError {
  const DevError(this.at, this.line);
  final DateTime at;
  final String line;                // cut to 300
}

/// A pack installed from the Marketplace, as it stands on this device: running, or why not.
class InstalledPack {
  const InstalledPack({required this.id, required this.version, required this.sha256, required this.installedAt, this.approval, this.pack, this.plugin, this.running = false, this.revoked, this.problem, this.listing = const {}, String? developer}) : _developer = developer;
  final String id, version, sha256;
  final DateTime installedAt;
  final PackApproval? approval;
  final PluginPack? pack;           // null where it could not be read or parsed
  final PackPlugin? plugin;         // whenever it parsed, in the registry or not
  final bool running;               // in the registry now
  final PackRevocation? revoked;
  final String? problem;            // null, or: bad_approval, untrusted_key, invalid, needs_newer_app, revoked, io, id_taken, too_many_packs, paused
  final Map<String, Object?> listing;   // listing.json

  /// Who made it: its pack's developer, else as listing.json kept it at install or its file says where it no longer
  /// parses here; null where nothing here says. An update by anyone else, or by someone unknown, is refused
  /// (developer_changed) and offered as a new plugin instead (review, 2026-11-20).
  String? get developer => pack?.developer ?? _developer ?? (listing['developer'] is String ? listing['developer'] as String : null);
  final String? _developer;
}

/// A pack loaded in Settings › Developer, as it stands on this device.
class DevPack {
  const DevPack({required this.id, required this.source, required this.loadedAt, this.pack, this.plugin, this.issues = const [], this.errors = const [], this.agreed, this.problem, bool running = false}) : _running = running;
  final String id;
  final DevSource source;
  final DateTime loadedAt;
  final PluginPack? pack;           // null when the copy on disk does not parse
  final PackPlugin? plugin;         // the copy that is running, which may be an older one (below)
  final List<PackIssue> issues;     // of the newest copy
  final List<DevError> errors;      // newest first, at most 20: what it threw or was refused while running
  final List<String>? agreed;       // the packReaches and packAdds lines agreed to (D.5), null until it was first switched on
  final String? problem;            // null, or: invalid, new_copy_invalid, id_installed, dev_mode_off, paused, too_many_packs, needs_consent
  final bool _running;

  /// [plugin] is in the registry now.
  bool get running => plugin != null && _running;

  /// It can do something now that the person hasn't agreed to: some line of what it reaches or adds isn't among
  /// [agreed], or it was never agreed to at all.
  bool get needsConsent {
    final pack = this.pack;
    if (pack == null) return false;
    final agreed = this.agreed;
    if (agreed == null) return true;
    return consentLines(pack).any((line) => !agreed.contains(line));
  }

  /// What the person agrees to for [pack], a line each as text: its privacy card's lines, then what it adds, as they
  /// read on [here] (this device where null; the review screen asks for a phone's, where a pack does the most).
  static List<String> consentLines(PluginPack pack, {String? here}) => [
        for (final r in packReaches(pack, here: here)) r.hint == null ? r.label : '${r.label}: ${r.hint}',
        ...packAdds(pack, here: here),
      ];
}

/// What installing, loading or removing a pack came to.
class PackOutcome {
  const PackOutcome.ok(GhostPlugin this.plugin, {this.issues = const [], this.needsConsent = false}) : ok = true, code = null, message = '';
  const PackOutcome.failed(String this.code, this.message, {this.issues = const []}) : ok = false, plugin = null, needsConsent = false;
  final bool ok;
  final String? code;
  final String message;             // plain words for a toast or a row's hint
  final List<PackIssue> issues;
  final GhostPlugin? plugin;
  final bool needsConsent;          // loaded, but left off until the person agrees to what it can do now (D.5, D.7)
}

/// Something for the shell to toast (D.1).
class PackNotice {
  const PackNotice(this.kind, this.packId, this.words);
  final String kind;                // 'withdrawn', 'paused', 'api_loaded'; MarketState's own are 'submission' (D.11)
  final String packId;
  final String words;               // what the toast says (D.5, A.10.9, B.14)
}

/// The one place packs are installed, loaded and removed on this device: reads the plugins folder at [load], puts
/// what checks out into the registry, and tells its listeners of every change.
class InstalledPlugins extends ChangeNotifier {
  /// Nothing is read or written here: [load] reads the folder, and a test puts its own here (a temp [root], its own
  /// [reviewKeys]) without touching the installed app's.
  InstalledPlugins({Directory? root, PluginRegistry? registry, List<String>? reviewKeys, bool? storeAllowed, bool? devAllowed, HttpClient Function()? http, Future<bool> Function(String url)? openLink, DateTime Function()? now})
      : _root = root,
        _registry = registry,
        _reviewKeys = reviewKeys,
        _storeAllowed = storeAllowed,
        _devAllowed = devAllowed,
        _http = http,
        _openLink = openLink,
        _now = now ?? DateTime.now;

  static InstalledPlugins instance = InstalledPlugins();      // no I/O in the constructor; a test puts its own here and the old one back in tearDown

  /// Whether signatures are checked on an isolate of their own, as they are in the app: each is a P-256 check in pure
  /// Dart. A widget test's clock never lets an isolate's answer arrive, so under flutter test they are checked in
  /// place, unless a test asks for the isolate.
  @visibleForTesting
  static bool verifyInIsolate = !PlatformInfo.environment.containsKey('FLUTTER_TEST');

  /// The withdrawals and retirements this build carries (review_keys.dart), as [load] merges them: a test gives its
  /// own, since this build's are empty.
  @visibleForTesting
  static (List<Map<String, Object?>>, List<Map<String, Object?>>) shipped = (shippedRevocations, shippedRetirements);

  Directory? _root;
  final PluginRegistry? _registry;
  final List<String>? _reviewKeys;
  final bool? _storeAllowed;
  final bool? _devAllowed;
  final HttpClient Function()? _http;
  final Future<bool> Function(String url)? _openLink;
  final DateTime Function() _now;
  final _notices = StreamController<PackNotice>.broadcast();

  /// The plugins folder: the one given, else this device's ([pluginsRoot]), worked out when first asked.
  Directory get root => _root ??= pluginsRoot();

  // The registry given, else the app's own, read when used: lib/desktop/main.dart and the tests put theirs in place
  // after this is made.
  PluginRegistry get _reg => _registry ?? PluginRegistry.instance;

  /// The review keys whose approvals install: the ones given (a test's), else this build's.
  List<String> get reviewKeys => _reviewKeys ?? marketReviewKeys;

  /// Pinned keys retired by a verified PackRetirement.
  Set<String> get retiredKeys => {for (final k in _retired.keys) if (reviewKeys.contains(k)) k};

  /// No store packs at all on an iPhone, whose App Store reads a storefront of other developers' features against its
  /// rules.
  bool get storeAllowed => _storeAllowed ?? !PlatformInfo.isIOS;

  /// No plugins in development in an App Store build.
  bool get devAllowed => _devAllowed ?? !packAppStoreBuild;

  /// What the shell toasts: a pack withdrawn, paused, or loaded from the API.
  Stream<PackNotice> get notices => _notices.stream;

  AppState? _app;
  String _appVersion = '';
  var _loaded = false;
  Future<void>? _loading;
  var _devOn = false;
  var _gone = false;

  final _store = <String, _Store>{};                      // by pack id, in install order
  final _dev = <String, _Dev>{};                          // by pack id, in load order
  final _revocations = <String, PackRevocation>{};        // by '<plugin> <sha256>'
  final _retired = <String, PackRetirement>{};            // by key

  bool get loaded => _loaded;

  List<InstalledPack>? _storeView;
  List<DevPack>? _devView;

  /// In install order.
  List<InstalledPack> get store => _storeView ??= List.unmodifiable([for (final s in _store.values) s.view]);

  /// In load order.
  List<DevPack> get dev => _devView ??= List.unmodifiable([for (final d in _dev.values) d.view(devOn: _devOn)]);

  InstalledPack? storeOf(String packId) => store.where((p) => p.id == packId).firstOrNull;
  DevPack? devOf(String packId) => dev.where((p) => p.id == packId).firstOrNull;

  List<PackRevocation> get revocations => List.unmodifiable(_revocations.values);

  /// Whether the package [sha256] of the plugin [plugin] (a pack id) was withdrawn. A withdrawal counts only for the
  /// plugin it names: the reviewer signs it over a plugin and a package, and one signed over another plugin's hash (a
  /// relay broken into could hand the review screen one) must not switch off a plugin it never named (review,
  /// 2026-11-20).
  bool isRevoked(String plugin, String sha256) => _revocations.containsKey('$plugin $sha256');
  PackRevocation? _revocationOf(String plugin, String sha256) => _revocations['$plugin $sha256'];

  // The registry load listens to: the app's own may be another by the time this goes (a test puts its own in place).
  PluginRegistry? _listened;

  @override
  void dispose() {
    _gone = true;
    _app?.removeListener(_onApp);
    _listened?.removeErrorListener(_heard);
    super.dispose();
  }

  // --- telling ----------------------------------------------------------------------------------------------------

  var _pending = false;
  final _then = <void Function()>[];

  /// Every change is told through one microtask, never at once: a pack's trouble and its errors are often heard during
  /// a build (the list binds its tags and sorts while it builds), and a listener told then would mark other widgets
  /// dirty mid-build. What a pause writes ([work]) and every notice go in that same microtask.
  void _later([void Function()? work]) {
    _storeView = null;
    _devView = null;
    if (work != null) _then.add(work);
    if (_pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      final works = List.of(_then);
      _then.clear();
      for (final w in works) {
        try {
          w();
        } catch (_) {}
      }
      _storeView = null;
      _devView = null;
      if (!_gone) notifyListeners();
    });
  }

  /// Hands [n] to whoever listens to [notices].
  void _notice(PackNotice n) {
    if (!_notices.isClosed) _notices.add(n);
  }

  // --- the app's choices: small indexes, never the packs ----------------------------------------------------------

  static const _storeKey = 'plugins_store', _devKey = 'plugins_dev', _floorKey = 'plugins_floor', _pausedKey = 'plugins_paused';

  /// Writes one of the app's choices, only where it differs from what is kept; nothing before [load] gave the app.
  void _put(String key, String value) {
    final app = _app;
    if (app != null && app.choice(key, '') != value) app.set(key, value);
  }

  /// The choice [key] read as a JSON object; empty where it is unset or isn't one.
  Map<String, Object?> _index(String key) {
    try {
      final v = jsonDecode(_app?.choice(key, '') ?? '');
      return v is Map ? {for (final e in v.entries) '${e.key}': e.value} : {};
    } catch (_) {
      return {};
    }
  }

  /// The store packs running now (id to version) and the ids of the packs in development, written to the app's
  /// choices.
  void _writeIndexes() {
    _put(_storeKey, jsonEncode({for (final s in _store.values) if (s.running) s.id: s.version}));
    _put(_devKey, jsonEncode([for (final d in _dev.values) d.id]));
  }

  /// The highest version of [packId] ever installed here, and that copy's SHA-256: nothing lower, and no other copy of
  /// that same version, installs after it (not_newer).
  ({String version, String sha256})? _floorOf(String packId) {
    final f = _index(_floorKey)[packId];
    if (f is! Map || f['version'] is! String || f['sha256'] is! String || !packVersionPattern.hasMatch(f['version'] as String)) return null;
    return (version: f['version'] as String, sha256: f['sha256'] as String);
  }

  /// Raises [packId]'s floor to [version]; never lowers it.
  void _raiseFloor(String packId, String version, String sha256) {
    final floor = _floorOf(packId);
    if (floor != null && compareVersions(version, floor.version) <= 0) return;
    _put(_floorKey, jsonEncode({..._index(_floorKey), packId: {'version': version, 'sha256': sha256}}));
  }

  /// The SHA-256 of the copy of [registryId] that was paused, kept so a pause outlasts a restart, for that copy alone.
  String? _pausedSha(String registryId) => _index(_pausedKey)[registryId] as String?;

  /// Keeps the pause of [registryId]'s copy [sha256], or forgets it (null).
  void _setPaused(String registryId, String? sha256) {
    final paused = _index(_pausedKey);
    if (sha256 == null ? !paused.containsKey(registryId) : paused[registryId] == sha256) return;
    sha256 == null ? paused.remove(registryId) : paused[registryId] = sha256;
    _put(_pausedKey, jsonEncode(paused));
  }

  // The list classifies and sorts everything again: a paused pack's tags go, an unpaused one's come back.
  void _bumpTuned() {
    final app = _app;
    if (app != null) app.set(PluginRegistry.tunedKey, '${(int.tryParse(app.choice(PluginRegistry.tunedKey, '')) ?? 0) + 1}');
  }

  // --- the folder -------------------------------------------------------------------------------------------------

  String _storeDir(String id, [String? version]) => '${root.path}/store/$id${version == null ? '' : '/$version'}';
  String _devDir(String id) => '${root.path}/dev/$id';

  /// Written to `<file>.tmp` and renamed into place, so a file is the old one or the new one, never half of one.
  static void _write(String path, List<int> bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(path);
  }

  /// The JSON in the file at [path]; null where there is none or it doesn't parse.
  static Object? _readJson(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? jsonDecode(f.readAsStringSync()) : null;
    } catch (_) {
      return null;
    }
  }

  /// Removes the folder at [path] and everything in it; a failure is let go.
  static void _delete(String path) {
    try {
      final d = Directory(path);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  static String _nameOf(FileSystemEntity e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last;

  // --- one thing at a time ----------------------------------------------------------------------------------------

  Future<void> _queue = Future<void>.value();

  /// Installs, loads and removals one after another, after [load]: two at once would each count the caps without the
  /// other.
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _queue.then((_) => work());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  static const _notLoaded = PackOutcome.failed('not_loaded', 'Plugins haven\'t been read on this device yet. Try again in a moment.');

  // --- loading ----------------------------------------------------------------------------------------------------

  /// Reads the folder, once however often it is called, and puts what checks out into the registry. Returns when that
  /// is done or after [within], whichever comes first, so a slow disk never holds up the app's start.
  Future<void> load(AppState app, {required String appVersion, Duration within = const Duration(seconds: 3)}) async {
    _loading ??= _serial(() => _load(app, appVersion));
    final done = Completer<void>();
    void end([Object? _]) {
      if (!done.isCompleted) done.complete();
    }

    unawaited(_loading!.then(end, onError: end));
    // At most [within]: a slower disk finishes after, its packs going into the registry where they land.
    final timer = Timer(within, end);
    await done.future;
    timer.cancel();
  }

  Future<void> _load(AppState app, String appVersion) async {
    _app = app;
    _appVersion = appVersion;
    _devOn = app.flag('dev_mode', fallback: false);
    try {
      await _readRevoked();
      if (storeAllowed) await _loadStore();
      if (devAllowed) _loadDev();
    } catch (e) {
      Sms.instance.devLog('plugin', 'plugins: ${'$e'.split('\n').first}');
    }
    _listened = _reg..addErrorListener(_heard);
    app.addListener(_onApp);
    _loaded = true;
    _writeIndexes();
    _later();
  }

  /// The withdrawals and retirements this build ships with and those kept in revoked.json, checked and merged.
  Future<void> _readRevoked() async {
    final saved = _readJson('${root.path}/revoked.json');
    _readFailed();
    final (revs, rets) = shipped;
    _merge(await _check([...revs, if (saved is Map && saved['revoked'] is List) ...saved['revoked'] as List], [...rets, if (saved is Map && saved['retired'] is List) ...saved['retired'] as List]));
  }

  /// The marks ([_markOf]) of withdrawals and retirements signed, or said to be signed, by a pinned key whose check
  /// failed: a signature that doesn't verify never will. A relay broken into could hand every device thousands of them
  /// at every refresh, each a P-256 check in pure Dart (review, 2026-11-20); one that failed here once isn't checked
  /// again. Kept in unverified.json, the newest [_failedKept].
  final _failed = <String>{};
  static const _failedKept = 20000;
  bool _failedRead = false;

  /// How many signatures [_check] has handed over to be checked: a test counts them.
  @visibleForTesting
  int signaturesChecked = 0;

  /// What a withdrawal ('revoke') or a retirement ('retire') is known by here: the SHA-256 of its kind and its
  /// canonical JSON.
  static String _markOf(String kind, Map<String, Object?> json) => sha256Hex(utf8.encode('$kind\n${canonicalJson(json)}'));

  /// Reads unverified.json into [_failed], once.
  void _readFailed() {
    if (_failedRead) return;
    _failedRead = true;
    final saved = _readJson('${root.path}/unverified.json');
    final marks = saved is Map ? saved['marks'] : null;
    if (marks is List) _failed.addAll([for (final m in marks) if (m is String && m.length == 64) m]);
  }

  /// Writes [_failed] to unverified.json, the oldest dropped past [_failedKept].
  void _saveFailed() {
    while (_failed.length > _failedKept) {
      _failed.remove(_failed.first);
    }
    try {
      _write('${root.path}/unverified.json', utf8.encode(jsonEncode({'v': 1, 'marks': [..._failed]})));
    } catch (_) {}
  }

  /// The revocations and retirements of [revs] and [rets] this device doesn't hold yet that verify (on an isolate of
  /// their own in the app). Neither in nor holding up the installer's queue, which Add, Update, Remove and every load
  /// in development wait in: only the merge is the queue's ([_merge]). Only a pinned key's are checked at all (any
  /// other fails at once, as verifyRevocation would have it), each once however often it is sent, and never one that
  /// failed before.
  Future<(List<PackRevocation>, List<PackRetirement>)> _check(List<Object?> revs, List<Object?> rets) async {
    final keys = reviewKeys;
    final seen = <String>{};
    final fresh = <PackRevocation>[], retirements = <PackRetirement>[];
    final freshMarks = <String>[], retirementMarks = <String>[];
    for (final r in revs) {
      final rev = _revocationFrom(r);
      if (rev == null || !keys.contains(rev.key) || _revocations.containsKey('${rev.plugin} ${rev.sha256}')) continue;
      final mark = _markOf('revoke', rev.toJson());
      if (_failed.contains(mark) || !seen.add(mark)) continue;
      fresh.add(rev);
      freshMarks.add(mark);
    }
    for (final r in rets) {
      final ret = _retirementFrom(r);
      // Only a pinned key's retirement means anything here.
      if (ret == null || !keys.contains(ret.key) || _retired.containsKey(ret.key)) continue;
      final mark = _markOf('retire', ret.toJson());
      if (_failed.contains(mark) || !seen.add(mark)) continue;
      retirements.add(ret);
      retirementMarks.add(mark);
    }
    if (fresh.isEmpty && retirements.isEmpty) return (const <PackRevocation>[], const <PackRetirement>[]);
    signaturesChecked += fresh.length + retirements.length;
    final (okRevs, okRets) = await _verified(keys, fresh, retirements);
    var failed = false;
    for (var i = 0; i < fresh.length; i++) {
      if (!okRevs[i]) failed = _failed.add(freshMarks[i]) || failed;
    }
    for (var i = 0; i < retirements.length; i++) {
      if (!okRets[i]) failed = _failed.add(retirementMarks[i]) || failed;
    }
    if (failed) _saveFailed();
    return ([for (var i = 0; i < fresh.length; i++) if (okRevs[i]) fresh[i]], [for (var i = 0; i < retirements.length; i++) if (okRets[i]) retirements[i]]);
  }

  /// What [_check] found to hold, kept: a withdrawal by plugin and package, a retirement by key, the first of each.
  void _merge((List<PackRevocation>, List<PackRetirement>) held) {
    for (final r in held.$1) {
      _revocations.putIfAbsent('${r.plugin} ${r.sha256}', () => r);
    }
    for (final r in held.$2) {
      _retired.putIfAbsent(r.key, () => r);
    }
  }

  static PackRevocation? _revocationFrom(Object? j) {
    try {
      return j is Map ? PackRevocation.fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }

  static PackRetirement? _retirementFrom(Object? j) {
    try {
      return j is Map ? PackRetirement.fromJson(j) : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether each of [revs] and each of [rets] verifies, in their order. They cross to the isolate as plain JSON.
  static Future<(List<bool>, List<bool>)> _verified(List<String> keys, List<PackRevocation> revs, List<PackRetirement> rets) async {
    final k = List<String>.of(keys);
    final r = [for (final x in revs) x.toJson()];
    final t = [for (final x in rets) x.toJson()];
    final out = verifyInIsolate ? await runAside(() => _verifyBatch(k, r, t)) : _verifyBatch(k, r, t);
    return (out[0], out[1]);
  }

  /// Each store copy's approval, as (is it the reviewer's signature over its id, version and SHA-256 at all, is its
  /// key one this build trusts): one check per copy, the trust a matter of the pinned and retired keys.
  static Future<List<(bool, bool)>> _approvalsHold(List<(PackApproval, String, String, String)> copies, List<String> keys, Set<String> retired) async {
    final a = [for (final c in copies) c.$1.toJson()];
    final ids = [for (final c in copies) [c.$2, c.$3, c.$4]];
    final signed = verifyInIsolate ? await runAside(() => _signedBatch(a, ids)) : _signedBatch(a, ids);
    return [for (var i = 0; i < copies.length; i++) (signed[i], keys.contains(copies[i].$1.key) && !retired.contains(copies[i].$1.key))];
  }

  /// Reads `store/<id>/<version>/` for every pack, checks every copy, and puts one copy of each into the registry in
  /// install order, as far as the caps allow.
  Future<void> _loadStore() async {
    final base = Directory('${root.path}/store');
    if (!base.existsSync()) return;
    final packs = <(String, List<_Copy>)>[];
    for (final dir in base.listSync().whereType<Directory>()) {
      final id = _nameOf(dir);
      if (packIdOf(registryIdOf(id)) == null) continue;
      final versions = [for (final v in dir.listSync().whereType<Directory>()) if (packVersionPattern.hasMatch(_nameOf(v))) _nameOf(v)]..sort((a, b) => compareVersions(b, a));
      if (versions.isEmpty) continue;
      packs.add((id, [for (final v in versions) _readCopy(id, v)]));
    }
    // Every copy still standing after checks 1 to 5 has its approval checked, all at once.
    final asked = [for (final (_, copies) in packs) for (final c in copies) if (c.problem == null) c];
    final held = await _approvalsHold([for (final c in asked) (c.approval!, c.id, c.version, c.sha256!)], reviewKeys, retiredKeys);
    for (var i = 0; i < asked.length; i++) {
      final (signed, trusted) = held[i];
      final c = asked[i];
      if (!signed || c.parse!.pack!.id != c.id || c.parse!.pack!.version != c.version) {
        c.problem = 'bad_approval';
      } else if (!trusted) {
        c.problem = 'untrusted_key';
      }
    }
    final found = <_Store>[];
    for (final (id, copies) in packs) {
      // The highest version that checks out; else the highest version, and why it doesn't.
      final c = copies.firstWhere((c) => c.problem == null, orElse: () => copies.first);
      final pack = c.parse?.pack;
      found.add(_Store(
        id: id,
        version: c.version,
        sha256: c.sha256 ?? '',
        installedAt: c.installedAt,
        approval: c.approval,
        pack: pack,
        plugin: pack == null ? null : _storePlugin(pack, c.approval, paused: c.sha256 != null && _pausedSha(pack.registryId) == c.sha256),
        revoked: c.sha256 == null ? null : _revocationOf(id, c.sha256!),
        problem: c.problem,
        listing: c.listing,
        developer: pack?.developer ?? _developerIn(c),
      ));
    }
    found.sort((a, b) => a.installedAt.compareTo(b.installedAt));
    for (final s in found) {
      _store[s.id] = s;
      if (s.problem != null || s.plugin == null) continue;
      final (packs, phrases) = _running();
      if (packs + 1 > PackLimits.packs || phrases + _phrasesOf(s.pack!) > PackLimits.phrasesInAll) {
        s.problem = 'too_many_packs';
        continue;
      }
      if (_reg.install(s.plugin!) != null) {
        s.problem = 'id_taken';
        continue;
      }
      s.running = true;
    }
  }

  /// One version of a store pack as it is on disk, held to installReviewed's checks 2 to 5 (6, its approval, is
  /// [_loadStore]'s, for every copy at once).
  _Copy _readCopy(String id, String version) {
    final dir = _storeDir(id, version);
    final listing = _readJson('$dir/listing.json');
    final at = listing is Map && listing['installedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(listing['installedAt'] as int) : _modified(dir);
    final c = _Copy(id: id, version: version, installedAt: at, listing: listing is Map ? Map<String, Object?>.unmodifiable({for (final e in listing.entries) '${e.key}': e.value}) : const {});
    final Uint8List bytes;
    try {
      bytes = File('$dir/package.ghostplugin').readAsBytesSync();
      c.approval = PackApproval.fromJson(_readJson('$dir/approval.json') as Map);
    } catch (_) {
      c.problem = 'io';
      return c;
    }
    final sha256 = c.sha256 = sha256Hex(bytes);
    if (bytes.length > PackLimits.packageBytes) return c..problem = 'invalid';
    if (sha256 != c.approval!.sha256) return c..problem = 'bad_approval';
    final parse = c.parse = parsePack(bytes, appVersion: _appVersion);
    if (isRevoked(id, sha256)) return c..problem = 'revoked';
    final errors = parse.errors.toList();
    if (errors.isNotEmpty) return c..problem = errors.every((e) => e.code == 'needs_newer_app') ? 'needs_newer_app' : 'invalid';
    if (parse.pack!.icon == null || !_sameBytes(parse.canonical!, bytes)) return c..problem = 'invalid';
    return c;
  }

  /// Who made the copy [c] where it doesn't parse here: as its listing.json kept it at install, else as its file says,
  /// read as plain JSON, since a copy a later app's rules refuse, or one that needs a newer app, still names its
  /// developer. Null where neither says (a copy that can't be read at all, installed before listing.json kept it).
  String? _developerIn(_Copy c) {
    final kept = c.listing['developer'];
    if (kept is String) return kept;
    try {
      final bytes = File('${_storeDir(c.id, c.version)}/package.ghostplugin').readAsBytesSync();
      final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes.sublist(3) : bytes;
      if (bytes.length > PackLimits.packageBytes || !jsonDepthOk(body)) return null;
      final json = jsonDecode(utf8.decode(body));
      final named = json is Map ? json['developer'] : null;
      return named is String ? named : null;
    } catch (_) {
      return null;
    }
  }

  /// When the folder at [path] last changed, for a copy whose own file doesn't say when it came; the epoch where even
  /// that can't be read.
  static DateTime _modified(String path) {
    try {
      return Directory(path).statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  /// Reads `dev/<id>/` for every pack in development, in load order; each goes into the registry only while developer
  /// mode is on.
  void _loadDev() {
    final base = Directory('${root.path}/dev');
    if (!base.existsSync()) return;
    final found = <_Dev>[];
    for (final dir in base.listSync().whereType<Directory>()) {
      final id = _nameOf(dir);
      if (packIdOf(registryIdOf(id)) == null) continue;
      final Uint8List bytes;
      try {
        bytes = File('${dir.path}/package.ghostplugin').readAsBytesSync();
      } catch (_) {
        continue;
      }
      final src = _readJson('${dir.path}/source.json');
      DevSource source;
      try {
        source = DevSource.fromJson(src as Map);
      } catch (_) {
        source = const DevSource('paste');
      }
      final at = src is Map && src['loadedAt'] is int ? DateTime.fromMillisecondsSinceEpoch(src['loadedAt'] as int) : _modified(dir.path);
      final agreed = src is Map && src['agreed'] is List ? [for (final l in src['agreed'] as List) if (l is String) l] : null;
      final parse = parsePack(bytes, appVersion: _appVersion);
      final d = _Dev(id: id, source: source, loadedAt: at)
        ..pack = parse.pack?.id == id ? parse.pack : null
        ..sha256 = parse.sha256
        ..issues = parse.issues
        ..agreed = agreed;
      if (d.pack == null) {
        d.problem = 'invalid';
      } else {
        d.plugin = _devPlugin(d.pack!, paused: parse.sha256 != null && _pausedSha(d.pack!.registryId) == parse.sha256);
        d.pluginSha = parse.sha256;
      }
      found.add(d);
    }
    found.sort((a, b) => a.loadedAt.compareTo(b.loadedAt));
    for (final d in found) {
      _dev[d.id] = d;
      if (_devOn) _startDev(d);
    }
  }

  /// A store pack, and below it one in development, as a plugin: what it throws goes to the registry, its pause to
  /// [_trouble].
  PackPlugin _storePlugin(PluginPack pack, PackApproval? approval, {required bool paused}) =>
      PackPlugin(pack, source: PluginSource.reviewed, approval: approval, onError: (p, e) => _reg.failed(p, e), onTrouble: _trouble, openLink: _openLink, now: _now, paused: paused);

  PackPlugin _devPlugin(PluginPack pack, {required bool paused}) => PackPlugin(pack, source: PluginSource.dev, onError: (p, e) => _reg.failed(p, e), onTrouble: _trouble, openLink: _openLink, now: _now, paused: paused);

  /// How many phrases [p]'s tag rules hold, counted against PackLimits.phrasesInAll.
  static int _phrasesOf(PluginPack p) => p.rules.tags.fold(0, (n, r) => n + r.any.length + r.all.length + r.none.length);

  /// The packs running now and their phrases, all but [besides]'s (the copy an install or a load replaces).
  (int, int) _running({String? besides}) {
    var packs = 0, phrases = 0;
    for (final s in _store.values) {
      if (!s.running || s.id == besides) continue;
      packs++;
      phrases += _phrasesOf(s.pack!);
    }
    for (final d in _dev.values) {
      if (!d.running || d.id == besides) continue;
      packs++;
      phrases += _phrasesOf(d.plugin!.pack);
    }
    return (packs, phrases);
  }

  /// [d] into the registry, where it can be: developer mode is on, no store pack has its id, the caps allow it. One
  /// whose lines haven't all been agreed to is switched off.
  void _startDev(_Dev d) {
    final plugin = d.plugin;
    if (plugin == null || d.running) return;
    if (d.problem == 'too_many_packs' || d.problem == 'id_installed') d.problem = null;
    if (_store.containsKey(d.id)) {
      d.problem = 'id_installed';
      return;
    }
    final (packs, phrases) = _running();
    if (packs + 1 > PackLimits.packs || phrases + _phrasesOf(plugin.pack) > PackLimits.phrasesInAll) {
      d.problem = 'too_many_packs';
      return;
    }
    if (_reg.install(plugin) != null) {
      d.problem = 'id_installed';
      return;
    }
    d.running = true;
    final app = _app;
    if (app != null && d.view(devOn: true).needsConsent) _reg.setOn(plugin, AppStore(app), false);
  }

  /// [d] out of the registry; its files stay.
  void _stopDev(_Dev d) {
    if (!d.running) return;
    _reg.uninstall(registryIdOf(d.id));
    d.running = false;
  }

  // Developer mode switched off takes every pack in development out of the registry (their files stay); on, puts them
  // back.
  void _onApp() {
    final app = _app;
    if (app == null || _gone) return;
    final on = app.flag('dev_mode', fallback: false);
    if (on == _devOn) return;
    _devOn = on;
    if (!devAllowed) return;
    for (final d in _dev.values) {
      on ? _startDev(d) : _stopDev(d);
    }
    _writeIndexes();
    _later();
  }

  // What a pack in development threw, or was refused, kept for its page: only recorded, since it is often heard
  // during a build. Every plugin's errors already reach the Developer log through the registry's onError.
  void _heard(GhostPlugin plugin, Object error) {
    if (plugin is! PackPlugin || plugin.source != PluginSource.dev) return;
    final d = _dev[plugin.pack.id];
    if (d == null || !identical(d.plugin, plugin)) return;
    final line = _cut('$error', 300);
    final now = _now();
    // The same again at once is one line, and no word to the listeners: a page that rebuilds on them, and asks the
    // pack again as it builds, would otherwise be told, and rebuild, without end.
    final last = d.errors.firstOrNull;
    if (last != null && last.line == line && now.difference(last.at) < const Duration(seconds: 5)) return;
    d.heard(DevError(now, line));
    _later();
  }

  // A pack paused itself for slowing the app down (PackPlugin.onTrouble): the pause is kept for the copy that ran, the
  // list sorts again, and a store pack's is toasted.
  void _trouble(PackPlugin plugin, String what) {
    if (what != 'paused') return;
    final id = plugin.pack.id;
    final store = plugin.source == PluginSource.reviewed ? _store[id] : null;
    final dev = plugin.source == PluginSource.dev ? _dev[id] : null;
    if (store != null && !identical(store.plugin, plugin)) return;
    if (dev != null && !identical(dev.plugin, plugin)) return;
    final sha = store?.sha256 ?? dev?.pluginSha;
    dev?.heard(DevError(_now(), 'Paused: it was slowing the app down'));
    _later(() {
      if (sha != null) _setPaused(plugin.id, sha);
      _bumpTuned();
      Sms.instance.devLog('plugin', '${plugin.id}: Paused: it was slowing the app down');
      if (store != null) _notice(PackNotice('paused', id, '${plugin.name} was paused: it was slowing the app down. Turn it back on from its page in the Marketplace.'));
    });
  }

  // --- the Marketplace's packs ------------------------------------------------------------------------------------

  /// Installs a pack from the Marketplace, or updates the one here: [bytes] must be the very copy [approval] signs, by
  /// a review key this build trusts. [listing] is what the catalog said of it; [on] switches it on.
  Future<PackOutcome> installReviewed(Uint8List bytes, PackApproval approval, {Map<String, Object?> listing = const {}, bool on = true}) => _serial(() => _installReviewed(bytes, approval, listing: listing, on: on));

  Future<PackOutcome> _installReviewed(Uint8List bytes, PackApproval approval, {required Map<String, Object?> listing, required bool on}) async {
    final app = _app;
    if (app == null) return _notLoaded;
    final here = packHere();
    if (!storeAllowed) return const PackOutcome.failed('not_here', 'Plugins from other developers aren\'t on iPhone.');
    if (bytes.length > PackLimits.packageBytes) return PackOutcome.failed('too_large', 'It\'s ${bytes.length} bytes: a plugin is at most ${PackLimits.packageBytes}.');
    final sha256 = sha256Hex(bytes);
    if (sha256 != approval.sha256) return const PackOutcome.failed('sha_mismatch', 'This copy isn\'t the one that was reviewed.');
    // The approval's plugin, which step 7 holds to the pack's own id.
    if (isRevoked(approval.plugin, sha256)) return const PackOutcome.failed('revoked', 'It was withdrawn from the Marketplace.');
    final parse = parsePack(bytes, appVersion: _appVersion);
    final errors = parse.errors.toList();
    if (errors.isNotEmpty) {
      if (errors.every((e) => e.code == 'needs_newer_app')) return PackOutcome.failed('needs_newer_app', 'It needs a newer Uplink.', issues: parse.issues);
      return PackOutcome.failed('invalid', 'This version of Uplink can\'t run it.', issues: parse.issues);
    }
    final pack = parse.pack!;
    if (pack.icon == null) return PackOutcome.failed('invalid', 'It has no icon, which every plugin from the Marketplace has.', issues: parse.issues);
    if (!_sameBytes(parse.canonical!, bytes)) return const PackOutcome.failed('not_canonical', 'This copy isn\'t written as the Marketplace writes a plugin.');
    if (pack.id != approval.plugin || pack.version != approval.version) return const PackOutcome.failed('bad_approval', 'Its review is for another plugin or another version.');
    final (signed, trusted) = (await _approvalsHold([(approval, pack.id, pack.version, sha256)], reviewKeys, retiredKeys)).single;
    if (!signed) return const PackOutcome.failed('bad_approval', 'Its review doesn\'t check out.');
    if (!trusted) return const PackOutcome.failed('untrusted_key', 'This version of Uplink can\'t check its review. An update may fix it.');
    if (_dev.containsKey(pack.id)) return PackOutcome.failed('id_installed', 'Your development copy of ${pack.name} is loaded. Remove it in Settings › Developer first.');
    final floor = _floorOf(pack.id);
    if (floor != null) {
      final c = compareVersions(pack.version, floor.version);
      if (c < 0 || (c == 0 && floor.sha256 != sha256)) return PackOutcome.failed('not_newer', 'A newer version of ${pack.name} was on this $here already.');
    }
    final had = _store[pack.id];
    // Who made the copy here, as its pack, its listing.json or its file says. One nothing here can tell is taken as
    // someone else's: a stuck copy that no longer parsed skipped this check, so a relay could hand its id to another
    // developer and the newcomer's version came in as an "Update", the old switch on (review, 2026-11-20). That goes
    // through Remove and Add instead, its choices forgotten.
    if (had != null && (had.developer == null || had.developer != pack.developer)) return PackOutcome.failed('developer_changed', '${pack.name} is now by someone else. Remove it first, then add theirs.');
    final (packs, phrases) = _running(besides: pack.id);
    if (packs + 1 > PackLimits.packs) return PackOutcome.failed('too_many_packs', 'This $here has ${PackLimits.packs} plugins from other developers already: remove one first.');
    if (phrases + _phrasesOf(pack) > PackLimits.phrasesInAll) return const PackOutcome.failed('too_many_phrases', 'The plugins from other developers here look for as many words as they may already: remove one first.');

    final dir = _storeDir(pack.id, pack.version);
    final installedAt = had?.installedAt ?? _now();
    final listed = listing['listedAt'];
    // The developer too, so a copy that stops parsing here (a later app's stricter rules, a downgrade below its minApp)
    // still says whose it is.
    final kept = <String, Object?>{'v': 1, 'installedAt': installedAt.millisecondsSinceEpoch, 'listedAt': listed is int ? listed : null, 'name': pack.name, 'tagline': pack.tagline, 'hue': pack.hue, 'symbol': pack.symbol, 'developer': pack.developer};
    try {
      _write('$dir/package.ghostplugin', bytes);
      _write('$dir/approval.json', canonicalBytes(approval.toJson()));
      _write('$dir/listing.json', canonicalBytes(kept));
    } catch (e) {
      if (had?.version != pack.version) _delete(dir);
      return PackOutcome.failed('io', 'It couldn\'t be saved on this $here.');
    }
    // A pause is kept for the copy that was paused: another version starts afresh.
    final keepPause = _pausedSha(pack.registryId) == sha256;
    final plugin = _storePlugin(pack, approval, paused: keepPause);
    // An update takes the place of the copy it replaces: its sections keep their precedence, its switch is as it was.
    final refused = (had?.running ?? false) ? _reg.replace(plugin) : _reg.install(plugin);
    if (refused != null) {
      if (had?.version != pack.version) _delete(dir);
      return PackOutcome.failed('id_taken', 'Another plugin here already has its name in the app (${pack.registryId}).');
    }
    if (had != null && had.version != pack.version) _delete(_storeDir(pack.id, had.version));
    _newJobsOff(pack, had?.pack);
    if (on) _reg.setOn(plugin, AppStore(app), true);
    _raiseFloor(pack.id, pack.version, sha256);
    if (!keepPause) _setPaused(pack.registryId, null);
    // An update keeps its place in install order (a map keeps a key's place when its value changes), as in the registry.
    _store[pack.id] = _Store(id: pack.id, version: pack.version, sha256: sha256, installedAt: installedAt, approval: approval, pack: pack, plugin: plugin, running: true, listing: Map.unmodifiable(kept), developer: pack.developer);
    _writeIndexes();
    _later();
    return PackOutcome.ok(plugin);
  }

  /// Takes a store pack out of the registry and deletes its files. Its switch is cleared; with [forget], every other
  /// choice of its own too ([_forget]).
  Future<PackOutcome> removeStore(String packId, {bool forget = false}) => _serial(() async {
        final app = _app;
        if (app == null) return _notLoaded;
        final s = _store[packId];
        if (s == null) return const PackOutcome.failed('not_found', 'It isn\'t on this device.');
        if (s.running) _reg.uninstall(registryIdOf(packId));
        // Read before its folder goes: a copy that no longer parses here still names the switches it waited for.
        _forget(app, packId, s.pack != null ? _incomingOf(s.pack) : _incomingIn([for (final v in _versionsOf(packId)) '${_storeDir(packId, v)}/package.ghostplugin']), everything: forget);
        _delete(_storeDir(packId));
        _store.remove(packId);
        _setPaused(registryIdOf(packId), null);
        _writeIndexes();
        _later();
        return PackOutcome.ok(s.plugin ?? _Gone(packId, '${s.listing['name'] ?? packId}'));
      });

  /// Its switch, and the switches its incoming rules name ([incoming]), written '' (so adding it again asks again, and
  /// starts with them off); with [everything], every other choice of its own too. Its other choices are kept otherwise,
  /// as removing a built-in keeps them. Where no copy of it could be read to say which switches those are ([incoming]
  /// null), none of its switches is left on: a stuck pack's incoming rule would otherwise mark texts read or silence
  /// them the moment it was added again, with nobody having switched it on (review, 2026-11-20).
  void _forget(AppState app, String packId, Set<String>? incoming, {required bool everything}) {
    final id = registryIdOf(packId);
    _put('plugin_$id', '');
    if (incoming == null) {
      for (final e in app.withPrefix('plugin_${id}_').entries) {
        if (e.value == 'on') _put(e.key, '');
      }
    } else {
      for (final setting in incoming) {
        _put('plugin_${id}_$setting', '');
      }
    }
    if (everything) {
      for (final k in app.withPrefix('plugin_${id}_').keys) {
        _put(k, '');
      }
    }
  }

  /// The switches [pack]'s incoming rules wait for.
  static Set<String> _incomingOf(PluginPack? pack) => {for (final r in pack?.rules.incoming ?? const <PackIncoming>[]) r.setting};

  /// What each switch [pack]'s incoming rules wait for does once it is on: a section's key and a verb, a space between,
  /// for each section it marks read or silences.
  static Map<String, Set<String>> _jobsOf(PluginPack? pack) {
    final out = <String, Set<String>>{};
    for (final r in pack?.rules.incoming ?? const <PackIncoming>[]) {
      (out[r.setting] ??= {}).addAll([for (final v in r.verbs) '${r.section} $v']);
    }
    return out;
  }

  /// Writes '' to every switch an incoming rule of [pack] waits for whose job is new since [before], the copy it takes
  /// the place of (null for one new here, or one that couldn't be read: then every one). A switch on in the copy
  /// before for something else (a setting a tag rule reads), or for marking one kind read, kept its 'on' under the
  /// same key: the new copy marked texts read or took their notifications away the moment it was in, under sheets
  /// that said "once you switch it on" (review, 2026-11-20). So a switch is only ever on for what it was switched on
  /// for.
  void _newJobsOff(PluginPack pack, PluginPack? before) {
    final had = _jobsOf(before);
    for (final MapEntry(key: setting, value: jobs) in _jobsOf(pack).entries) {
      final was = had[setting] ?? const <String>{};
      if (!jobs.every(was.contains)) _put('plugin_${pack.registryId}_$setting', '');
    }
  }

  /// The version folders store/<[packId]>/ holds.
  List<String> _versionsOf(String packId) {
    try {
      return [for (final v in Directory(_storeDir(packId)).listSync().whereType<Directory>()) if (packVersionPattern.hasMatch(_nameOf(v))) _nameOf(v)];
    } catch (_) {
      return const [];
    }
  }

  /// The switches the incoming rules of each copy in [files] wait for, read however the copy can be: as a pack, the
  /// app's version not asked (needs_newer_app), else as plain JSON, since a copy a later app's rules refuse still says
  /// what it named. Null where no copy could be read at all.
  Set<String>? _incomingIn(List<String> files) {
    Set<String>? out;
    for (final path in files) {
      final Uint8List bytes;
      try {
        bytes = File(path).readAsBytesSync();
      } catch (_) {
        continue;
      }
      final pack = parsePack(bytes, appVersion: _appVersion, checkMinApp: false).pack;
      if (pack != null) {
        (out ??= {}).addAll(_incomingOf(pack));
        continue;
      }
      try {
        final body = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF ? bytes.sublist(3) : bytes;
        if (!jsonDepthOk(body)) continue;
        final json = jsonDecode(utf8.decode(body));
        if (json is! Map) continue;
        final rules = json['rules'];
        final incoming = rules is Map ? rules['incoming'] : null;
        final named = out ??= {};
        if (incoming is List) {
          for (final r in incoming) {
            if (r is Map && r['setting'] is String) named.add(r['setting'] as String);
          }
        }
      } catch (_) {}
    }
    return out;
  }

  // --- packs in development ---------------------------------------------------------------------------------------

  /// Loads a pack in development from [bytes], or a newer copy of one already loaded: unreviewed, and only while
  /// developer mode is on. A copy that doesn't parse is kept with its issues, an older one that runs going on running.
  Future<PackOutcome> loadDev(List<int> bytes, DevSource source, {bool on = false}) => _serial(() => _loadDevNow(bytes, source, on: on));

  /// Why nothing in development may be loaded now; null where it may.
  PackOutcome? _devRefused() {
    final app = _app;
    if (app == null) return _notLoaded;
    if (!devAllowed) return const PackOutcome.failed('not_here', 'Plugins in development aren\'t in this version of Uplink.');
    if (!app.flag('dev_mode', fallback: false)) return const PackOutcome.failed('dev_mode_off', 'Turn on developer mode first: tap Settings › About › Version twelve times.');
    return null;
  }

  Future<PackOutcome> _loadDevNow(List<int> bytes, DevSource source, {required bool on}) async {
    final refused = _devRefused();
    if (refused != null) return refused;
    final app = _app!;
    if (bytes.length > PackLimits.packageBytes) return PackOutcome.failed('too_large', 'It\'s ${bytes.length} bytes: a plugin is at most ${PackLimits.packageBytes}.');
    final parse = parsePack(bytes, appVersion: _appVersion);
    final pack = parse.pack;
    final id = pack?.id ?? _idIn(bytes);
    // Not JSON, or no id it could be known by: nothing is kept, and the issues say why.
    if (id == null) return PackOutcome.failed('invalid', parse.errors.firstOrNull?.message ?? 'It isn\'t a plugin.', issues: parse.issues);
    final installed = _store[id];
    if (installed != null) return PackOutcome.failed('id_installed', '${installed.pack?.name ?? installed.listing['name'] ?? id} is installed from the Marketplace. Remove it there first, or give your copy another id.');
    final had = _dev[id];
    final now = _now();
    if (pack == null) {
      // A good id but a broken copy: kept with its issues, for its row and page, while an older copy that runs goes
      // on running.
      final d = had ?? _Dev(id: id, source: source, loadedAt: now);
      d
        ..source = source
        ..loadedAt = now
        ..pack = null
        ..sha256 = parse.sha256
        ..issues = parse.issues
        ..problem = d.plugin != null ? 'new_copy_invalid' : 'invalid';
      _dev[id] = d;
      _saveDev(d, bytes);
      _writeIndexes();
      _later(source.kind == 'api' ? () => _notice(PackNotice('api_loaded', id, '$id was loaded from the API')) : null);
      return PackOutcome.failed('invalid', '${parse.errors.length} ${parse.errors.length == 1 ? 'problem' : 'problems'}: ${parse.errors.first.message}', issues: parse.issues);
    }
    final (packs, phrases) = _running(besides: id);
    if (packs + 1 > PackLimits.packs) return PackOutcome.failed('too_many_packs', 'This ${packHere()} has ${PackLimits.packs} plugins from other developers already: remove one first.');
    if (phrases + _phrasesOf(pack) > PackLimits.phrasesInAll) return const PackOutcome.failed('too_many_phrases', 'The plugins from other developers here look for as many words as they may already: remove one first.');
    final keepPause = _pausedSha(pack.registryId) == parse.sha256;
    final plugin = _devPlugin(pack, paused: keepPause);
    final wasRunning = had?.running ?? false;
    final why = wasRunning ? _reg.replace(plugin) : _reg.install(plugin);
    if (why != null) return PackOutcome.failed('id_installed', 'Another plugin here already has its name in the app (${pack.registryId}).');
    // Against the copy that ran (or would have), whose switches the person may have set.
    _newJobsOff(pack, had?.plugin?.pack ?? had?.pack);
    final d = had ?? _Dev(id: id, source: source, loadedAt: now);
    d
      ..source = source
      ..loadedAt = now
      ..pack = pack
      ..sha256 = parse.sha256
      ..plugin = plugin
      ..pluginSha = parse.sha256
      ..issues = parse.issues
      ..problem = null
      ..running = true;
    _dev[id] = d;
    _saveDev(d, bytes);
    if (!keepPause) _setPaused(pack.registryId, null);
    final consent = d.view(devOn: true).needsConsent;
    if (consent) {
      _reg.setOn(plugin, AppStore(app), false);
    } else if (on) {
      _reg.setOn(plugin, AppStore(app), true);
    }
    _writeIndexes();
    _later(source.kind == 'api' ? () => _notice(PackNotice('api_loaded', id, '${pack.name} was loaded from the API')) : null);
    return PackOutcome.ok(plugin, issues: parse.issues, needsConsent: consent);
  }

  /// The id [bytes] give themselves, where they are JSON with one a pack may have: what a broken copy is kept under.
  static String? _idIn(List<int> bytes) {
    try {
      var body = bytes;
      if (body.length >= 3 && body[0] == 0xEF && body[1] == 0xBB && body[2] == 0xBF) body = body.sublist(3);
      if (body.length > PackLimits.packageBytes || !jsonDepthOk(body)) return null;
      final json = jsonDecode(utf8.decode(body));
      final id = json is Map ? json['id'] : null;
      return id is String && packIdOf(registryIdOf(id)) != null ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes [d]'s source.json (where it came from, when, what was agreed to), and its package where [bytes] is given.
  void _saveDev(_Dev d, List<int>? bytes) {
    final dir = _devDir(d.id);
    try {
      if (bytes != null) _write('$dir/package.ghostplugin', bytes);
      _write('$dir/source.json', utf8.encode(jsonEncode({'v': 1, ...d.source.toJson(), 'loadedAt': d.loadedAt.millisecondsSinceEpoch, 'agreed': d.agreed})));
    } catch (e) {
      Sms.instance.devLog('plugin', '${registryIdOf(d.id)}: not saved: ${'$e'.split('\n').first}');
    }
  }

  /// Fetches a pack from [url], where [_linkAllowed] lets it, and loads it as one in development.
  Future<PackOutcome> loadDevFromLink(Uri url, {bool on = false}) async {
    final refused = _devRefused();
    if (refused != null) return refused;
    if (!_linkAllowed(url)) return const PackOutcome.failed('bad_link', 'Use http://127.0.0.1 with adb reverse, or https.');
    final got = await _fetch(url);
    if (got.$2 != null) return got.$2!;
    return loadDev(got.$1!, DevSource('link', url: '$url'), on: on);
  }

  /// https to anywhere; plain http only to this device itself: 127.0.0.1 on a phone (Android's network security
  /// config allows cleartext there alone, for adb reverse), and localhost or [::1] too on a computer.
  static bool _linkAllowed(Uri url) {
    if (url.scheme == 'https') return url.host.isNotEmpty;
    if (url.scheme != 'http') return false;
    if (url.host == '127.0.0.1') return true;
    return (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux) && (url.host == 'localhost' || url.host == '::1');
  }

  /// The bytes at [url], or why there are none: ten seconds to connect, twenty for all of it.
  Future<(Uint8List?, PackOutcome?)> _fetch(Uri url) async {
    final client = _http?.call() ?? HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      return await _get(client, url).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return (null, const PackOutcome.failed('fetch_failed', 'It took too long to answer.'));
    } catch (e) {
      return (null, PackOutcome.failed('fetch_failed', 'It couldn\'t be fetched: ${'$e'.split('\n').first}'));
    } finally {
      client.close(force: true);
    }
  }

  /// Redirects are followed by hand, three at most, and the reading stops once there is more than a package may be.
  Future<(Uint8List?, PackOutcome?)> _get(HttpClient client, Uri url) async {
    var at = url;
    for (var hops = 0;; hops++) {
      final request = await client.getUrl(at);
      request.followRedirects = false;
      final response = await request.close();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || hops >= 3) return (null, const PackOutcome.failed('fetch_failed', 'It sent the app on too many times.'));
        final next = at.resolve(location);
        // Each hop is held to the same rule as the first address.
        if (!_linkAllowed(next)) return (null, const PackOutcome.failed('bad_link', 'Use http://127.0.0.1 with adb reverse, or https.'));
        at = next;
        continue;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        return (null, PackOutcome.failed('fetch_failed', 'It answered ${response.statusCode}, not 200.'));
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response) {
        out.add(chunk);
        if (out.length > PackLimits.packageBytes) return (null, const PackOutcome.failed('too_large', 'It\'s more than ${PackLimits.packageBytes} bytes: a plugin is at most that.'));
      }
      return (out.takeBytes(), null);
    }
  }

  /// Loads [packId] again from where it came, its link or its file on a computer. Refused where the new copy names
  /// another id.
  Future<PackOutcome> reloadDev(String packId) async {
    final d = _dev[packId];
    if (d == null) return const PackOutcome.failed('not_found', 'It isn\'t loaded on this device.');
    final source = d.source;
    final List<int> bytes;
    if (source.kind == 'link' && source.url != null) {
      final url = Uri.tryParse(source.url!);
      if (url == null || !_linkAllowed(url)) return const PackOutcome.failed('bad_link', 'Use http://127.0.0.1 with adb reverse, or https.');
      final refused = _devRefused();
      if (refused != null) return refused;
      final got = await _fetch(url);
      if (got.$2 != null) return got.$2!;
      bytes = got.$1!;
    } else if (source.reloadable) {
      try {
        bytes = File(source.path!).readAsBytesSync();
      } catch (e) {
        return PackOutcome.failed('fetch_failed', 'The file couldn\'t be read: ${'$e'.split('\n').first}');
      }
    } else {
      return const PackOutcome.failed('not_reloadable', 'There\'s nothing to load it from again: load the new copy as you did this one.');
    }
    final now = _idIn(bytes);
    if (now != null && now != packId) return PackOutcome.failed('id_changed', 'The copy\'s id is now $now: load it as a new plugin.');
    return loadDev(bytes, source);
  }

  /// Takes a pack in development out of the registry and deletes its files, its switches cleared.
  Future<PackOutcome> removeDev(String packId) => _serial(() async {
        final app = _app;
        if (app == null) return _notLoaded;
        final d = _dev[packId];
        if (d == null) return const PackOutcome.failed('not_found', 'It isn\'t loaded on this device.');
        _stopDev(d);
        // The copy on disk is read too where the newest doesn't parse (after a restart nothing of it may be held): the
        // switches of whichever copy ran, and of that one.
        final pack = d.pack ?? d.plugin?.pack;
        final onDisk = pack == null || d.pack == null ? _incomingIn(['${_devDir(packId)}/package.ghostplugin']) : null;
        _forget(app, packId, pack == null ? onDisk : {..._incomingOf(pack), ...?onDisk}, everything: false);
        _delete(_devDir(packId));
        _dev.remove(packId);
        _setPaused(registryIdOf(packId), null);
        _writeIndexes();
        _later();
        return PackOutcome.ok(d.plugin ?? _Gone(packId, packId));
      });

  /// The person agreed on D.5's sheet: keep its lines, switch it on.
  Future<PackOutcome> agreeDev(String packId) => _serial(() async {
        final app = _app;
        if (app == null) return _notLoaded;
        final d = _dev[packId];
        if (d == null) return const PackOutcome.failed('not_found', 'It isn\'t loaded on this device.');
        final pack = d.pack;
        final plugin = d.plugin;
        if (pack == null || plugin == null) return const PackOutcome.failed('invalid', 'Its newest copy has problems: fix them and load it again.');
        d.agreed = DevPack.consentLines(pack);
        _saveDev(d, null);
        // Its switch is kept with the person's other choices, so it is on whenever developer mode is.
        _reg.setOn(plugin, AppStore(app), true);
        _later();
        return PackOutcome.ok(plugin);
      });

  /// It has been agreed to with every line it has now.
  bool mayTurnOnDev(String packId) {
    final d = devOf(packId);
    return d != null && d.pack != null && !d.needsConsent;
  }

  /// Lets a paused pack run again and forgets its pause; the list sorts again.
  void unpause(String packId) {
    final plugin = _store[packId]?.plugin ?? _dev[packId]?.plugin;
    if (plugin == null) return;
    plugin.unpause();
    _later(() {
      _setPaused(plugin.id, null);
      _bumpTuned();
    });
  }

  // --- withdrawals ------------------------------------------------------------------------------------------------

  /// The most of the withdrawals list taken, its withdrawals and its retirements: the Marketplace reads no more
  /// (lib/market/market_api.dart MarketReads), and the relay never keeps more (relay/lib/market.dart revocationsMost
  /// and retirementsMost, which a relay test holds to these). 5,000 was fewer than a list of 1 MiB held, so a longer
  /// list was refused whole on every device and no withdrawal reached one (review, 2026-11-20).
  static const int revocationsTaken = 25000, retirementsTaken = 100;

  /// GET /market/revoked's body: how many installed packs it newly withdrew. Its entries are checked before the queue,
  /// so a long list of them never holds up an install or a removal (review, 2026-11-20).
  Future<int> takeRevocations(Object? json) async {
    if (json is! Map) return 0;
    final revs = json['revoked'] is List ? (json['revoked'] as List).take(revocationsTaken).toList() : const <Object?>[];
    final rets = json['retired'] is List ? (json['retired'] as List).take(retirementsTaken).toList() : const <Object?>[];
    final held = await _check(revs, rets);
    return _serial(() async {
      _merge(held);
      _saveRevoked();
      var withdrew = 0;
      final retired = retiredKeys;
      for (final s in _store.values) {
        final revoked = _revocationOf(s.id, s.sha256);
        final untrusted = s.approval != null && retired.contains(s.approval!.key);
        if (revoked == null && !untrusted) continue;
        s
          ..revoked = revoked
          ..problem = revoked != null ? 'revoked' : 'untrusted_key';
        if (!s.running) continue;
        // Off, its files kept, so its page can say what happened and offer Remove.
        _reg.uninstall(registryIdOf(s.id));
        s.running = false;
        withdrew++;
        final name = s.pack?.name ?? '${s.listing['name'] ?? s.id}';
        _later(() => _notice(PackNotice('withdrawn', s.id, '$name was withdrawn from the Marketplace and is off.')));
      }
      _writeIndexes();
      _later();
      return withdrew;
    });
  }

  /// Writes every withdrawal and retirement held to revoked.json, which the next start reads ([_readRevoked]).
  void _saveRevoked() {
    try {
      _write('${root.path}/revoked.json', utf8.encode(jsonEncode({'v': 1, 'at': _now().millisecondsSinceEpoch, 'revoked': [for (final r in _revocations.values) r.toJson()], 'retired': [for (final r in _retired.values) r.toJson()]})));
    } catch (_) {}
  }
}

/// One store pack as it stands here: what [InstalledPack] shows of it.
class _Store {
  _Store({required this.id, required this.version, required this.sha256, required this.installedAt, this.approval, this.pack, this.plugin, this.running = false, this.revoked, this.problem, this.listing = const {}, this.developer});
  final String id, version, sha256;
  final DateTime installedAt;
  final PackApproval? approval;
  final PluginPack? pack;
  final PackPlugin? plugin;
  bool running;
  PackRevocation? revoked;
  String? problem;
  final Map<String, Object?> listing;
  final String? developer;

  InstalledPack get view => InstalledPack(id: id, version: version, sha256: sha256, installedAt: installedAt, approval: approval, pack: pack, plugin: plugin, running: running, revoked: revoked, problem: problem ?? (running && (plugin?.paused ?? false) ? 'paused' : null), listing: listing, developer: developer);
}

/// One version of a store pack read from disk, and the first of its checks it fails, if any.
class _Copy {
  _Copy({required this.id, required this.version, required this.installedAt, required this.listing});
  final String id, version;
  final DateTime installedAt;
  final Map<String, Object?> listing;
  PackApproval? approval;
  String? sha256;
  PackParse? parse;
  String? problem;
}

/// One pack in development as it stands here: what [DevPack] shows of it.
class _Dev {
  _Dev({required this.id, required this.source, required this.loadedAt});
  final String id;
  DevSource source;
  DateTime loadedAt;
  PluginPack? pack;           // the newest copy, where it parses
  String? sha256;             // the newest copy's
  PackPlugin? plugin;         // the copy that runs, or would
  String? pluginSha;          // that copy's
  List<PackIssue> issues = const [];
  final errors = <DevError>[];
  List<String>? agreed;
  String? problem;
  bool running = false;

  /// Newest first, the last 20 kept.
  void heard(DevError e) {
    errors.insert(0, e);
    if (errors.length > 20) errors.removeRange(20, errors.length);
  }

  /// As the screens see it. Where [problem] is unset, one is worked out: developer mode off, paused, or not yet agreed
  /// to, in that order.
  DevPack view({required bool devOn}) {
    final shown = DevPack(id: id, source: source, loadedAt: loadedAt, pack: pack, plugin: plugin, issues: issues, errors: List.unmodifiable(errors), agreed: agreed == null ? null : List.unmodifiable(agreed!), running: running);
    final why = problem ?? (!devOn ? 'dev_mode_off' : (running && (plugin?.paused ?? false) ? 'paused' : (shown.needsConsent ? 'needs_consent' : null)));
    return DevPack(id: id, source: source, loadedAt: loadedAt, pack: pack, plugin: plugin, issues: issues, errors: shown.errors, agreed: shown.agreed, problem: why, running: running);
  }
}

/// What an outcome names where the pack it was about could not be read: its id and name, and nothing else.
class _Gone extends GhostPlugin {
  const _Gone(this.packId, this.name);
  final String packId;
  @override
  String get id => registryIdOf(packId);
  @override
  final String name;
  @override
  String get description => '';
  @override
  bool get onByDefault => false;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [s] cut to [n] UTF-16 units at most, never between the two halves of a surrogate pair.
String _cut(String s, int n) {
  if (s.length <= n) return s;
  final last = s.codeUnitAt(n - 1);
  return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? n - 1 : n);
}

// On an isolate of their own in the app (InstalledPlugins.verifyInIsolate): plain values in, plain values out.

// Whether each withdrawal (first list) and each retirement (second) verifies, in the order given.
List<List<bool>> _verifyBatch(List<String> keys, List<Map<String, Object?>> revs, List<Map<String, Object?>> rets) => [
      [for (final r in revs) verifyRevocation(PackRevocation.fromJson(r), keys: keys)],
      [for (final r in rets) verifyRetirement(PackRetirement.fromJson(r))],
    ];

// Whether each approval is a good signature over its id, version and SHA-256 by its own key, whoever's key it is.
List<bool> _signedBatch(List<Map<String, Object?>> approvals, List<List<String>> ids) => [
      for (var i = 0; i < approvals.length; i++)
        () {
          final a = PackApproval.fromJson(approvals[i]);
          return verifyApproval(a, plugin: ids[i][0], version: ids[i][1], sha256: ids[i][2], keys: [a.key]);
        }(),
    ];
