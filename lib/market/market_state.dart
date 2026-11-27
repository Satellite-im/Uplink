/// The Marketplace as this device knows it (Matt, 2026-11-20: "I would like users to be able to develop and submit their
/// own plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review
/// process"): the catalog, each listed package fetched and checked before anything of it is shown, the updates waiting
/// for the store packs on this device, the withdrawals read from Uplink's own relay, and a developer's own
/// submissions, heard of without opening their page.
///
/// A listing is only ever what checked out: its package's SHA-256 is the catalog's, its approval verifies with a key
/// this build pins, it isn't withdrawn, and it parses as the plugin and version the catalog names. Everything shown of
/// it, the consent sheet included, comes from that package.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import '../aside.dart';

import 'package:flutter/foundation.dart';

import '../net/net.dart';
import '../plugins/pack/pack.dart';
import '../sms.dart';
import '../ui/settings_panes.dart' show appVersion;
import 'listing_plugin.dart';
import 'market_api.dart';
import 'market_models.dart';

/// One approval to check, as verifyApproval is asked it.
typedef ApprovalCheck = ({PackApproval approval, String plugin, String version, String sha256, List<String> keys, Set<String> retired});

/// How approvals are checked, a batch at once: [MarketState.verifyApprovals] unless a test wraps it, to count.
typedef MarketVerify = Future<List<bool>> Function(List<ApprovalCheck> checks);

/// What the Marketplace's screens listen to: the catalog, the listings that checked out, the developer's own
/// submissions and drafts. It fetches and checks; installing is [InstalledPlugins]'s.
class MarketState extends ChangeNotifier {
  /// Nothing is read or written here: [start] and [refresh] do it. [installed] and [cache] are read when first used, so
  /// lib/desktop/main.dart can put its own InstalledPlugins in place at startup after this is made. [now], [verify] and
  /// [appVersion] are a test's: its clock, the runtime's verifyApproval counted, the version its packs are read for.
  MarketState({MarketApi Function()? api, Directory? cache, InstalledPlugins? installed, DateTime Function()? now, MarketVerify? verify, String? appVersion})
      : _api = api,
        _cache = cache,
        _installed = installed,
        _now = now ?? DateTime.now,
        _verify = verify ?? verifyApprovals,
        _appVersion = appVersion;

  static MarketState instance = MarketState();

  final MarketApi Function()? _api;
  Directory? _cache;
  final InstalledPlugins? _installed;
  final DateTime Function() _now;
  final MarketVerify _verify;
  final String? _appVersion;

  /// Whether approvals are checked on an isolate of their own, as they are in the app: a P-256 verification in pure
  /// Dart costs milliseconds, and a catalog has many. A widget test's clock never lets an isolate's answer arrive, so
  /// under flutter test they are checked in place, as InstalledPlugins checks its own, unless a test asks for the
  /// isolate.
  @visibleForTesting
  static bool verifyInIsolate = !PlatformInfo.environment.containsKey('FLUTTER_TEST');

  /// The runtime's verifyApproval for each of [checks], in order; one that throws is false. Not an async function, so
  /// what goes to the isolate holds [checks] and nothing of an await's.
  static Future<List<bool>> verifyApprovals(List<ApprovalCheck> checks) {
    List<bool> all() => [
          for (final c in checks)
            () {
              try {
                return verifyApproval(c.approval, plugin: c.plugin, version: c.version, sha256: c.sha256, keys: c.keys, retired: c.retired);
              } catch (_) {
                return false;
              }
            }(),
        ];
    return verifyInIsolate ? runAside(all) : Future.value(all());
  }

  /// Asked each time: the identity and the relay can change while the app runs.
  MarketApi get api => (_api ?? MarketApi.live)();
  InstalledPlugins get installed => _installed ?? InstalledPlugins.instance;
  Directory get cache => _cache ??= Directory('${installed.root.parent.path}${PlatformInfo.pathSeparator}market');
  String get _version => _appVersion ?? appVersion;

  // --- what is known ------------------------------------------------------------------------------------------------

  /// The catalog as last read (or kept from before), null until one has been.
  Catalog? catalog;

  /// The checked listings, newest change first: an approved plugin's package that checked out.
  List<ListingPlugin> get listings => List.unmodifiable(_listings);
  List<ListingPlugin> _listings = const [];

  /// How many packages are still being fetched or checked.
  int checking = 0;

  /// Why nothing from other developers is shown, where something is wrong: 'unreachable' (the last refresh failed and
  /// nothing is kept), 'off' (the Marketplace said so), 'untrusted' (entries exist and none verifies with this build's
  /// keys); null otherwise.
  ({String code, DateTime at})? problem;

  /// Each store pack on this device, running or not, whose checked listing is newer and by the same developer, and that
  /// this app can install: one that needs a newer Uplink would be counted on the ring and refused at every
  /// press until the app itself is updated (review, 2026-11-20), so it waits until then.
  List<({InstalledPack installed, ListingPlugin listing})> get updates {
    final out = <({InstalledPack installed, ListingPlugin listing})>[];
    for (final p in installed.store) {
      final l = _listings.where((l) => l.pack.id == p.id).firstOrNull;
      if (l == null || l.needsNewerApp || !_newer(l.pack.version, p.version)) continue;
      // By the same developer as the copy here, as its pack, listing.json or file says: one nothing here can tell
      // isn't the same (review, 2026-11-20: a stuck copy that no longer parsed was offered another developer's
      // version as its update).
      if (p.developer == null || p.developer != l.pack.developer) continue;
      out.add((installed: p, listing: l));
    }
    return out;
  }

  /// The listing [packId] has, where it is by another developer than the store pack of that id on this device, or
  /// nothing here can tell who made that copy: offered as a new plugin, never as an update (D.5).
  ListingPlugin? developerChanged(String packId) {
    final p = installed.storeOf(packId);
    final l = _listings.where((l) => l.pack.id == packId).firstOrNull;
    return p != null && l != null && (p.developer == null || l.pack.developer != p.developer) ? l : null;
  }

  /// Whether version [a] is higher than [b]; false where either isn't a version.
  static bool _newer(String a, String b) {
    try {
      return compareVersions(a, b) > 0;
    } on FormatException {
      return false;
    }
  }

  /// What a developer is told without opening My submissions (D.11's toasts), and nothing else of this state's.
  Stream<PackNotice> get notices => _notices.stream;
  final _notices = StreamController<PackNotice>.broadcast();

  /// The developer's own, as route 9 last said: My submissions' row, and the submission form's "This account can't".
  MyMarket? mine;

  /// How many submissions wait in the review queue, as the queue was last read (the Review queue row's second line).
  int? reviewWaiting;

  /// The review queue's screen read the queue: [waiting] is how many it held.
  void reviewQueueRead(int waiting) {
    reviewWaiting = waiting;
    _say();
  }

  final Set<String> _adding = {};

  /// Whether the listing [packId] is being added now: its button says so and can't be pressed again.
  bool adding(String packId) => _adding.contains(packId);

  void _say() => notifyListeners();

  // --- refreshing ---------------------------------------------------------------------------------------------------

  Timer? _timer;
  bool _started = false;
  DateTime? _last;
  Future<void>? _refreshing;

  /// After 8 s and then every 6 hours: the catalog, the withdrawals, the packages to check, and the developer's own
  /// where they have any open. Once; never under a test, never on an iPhone (no store packs there at all).
  Future<void> start() async {
    if (_started || PlatformInfo.environment.containsKey('FLUTTER_TEST') || !installed.storeAllowed) return;
    _started = true;
    await loadDrafts();
    _timer = Timer(const Duration(seconds: 8), () {
      unawaited(refresh(force: true));
      _timer = Timer.periodic(const Duration(hours: 6), (_) => unawaited(refresh(force: true)));
    });
  }

  /// The Marketplace opened: what is older than 10 minutes is read again. Nothing until [start] has run.
  Future<void> opened() async {
    if (_started) await refresh();
  }

  /// Reads the catalog, the withdrawals and the packages, then the developer's own; [force] reads them however lately
  /// they were. One at a time: a second ask while one runs waits for it.
  Future<void> refresh({bool force = false}) {
    final running = _refreshing;
    if (running != null) return running;
    final last = _last;
    if (!force && last != null && _now().difference(last) < const Duration(minutes: 10)) return Future.value();
    return _refreshing = _refresh().whenComplete(() => _refreshing = null);
  }

  /// One refresh, in order: the catalog (a failure leaves the kept one standing), the withdrawals, the packages'
  /// check, then the developer's own.
  Future<void> _refresh() async {
    _last = _now();
    final api = this.api;
    var off = false;
    // What was read before this run started, with its ETag: a 304 then costs nothing.
    catalog ??= await _keptCatalog();
    try {
      final got = await api.catalog(etag: catalog?.etag);
      if (got != null) {
        catalog = got;
        await _keepCatalog(got);
      }
      problem = null;
    } on MarketError catch (e) {
      off = e.code == 'off';
      problem = off ? (code: 'off', at: _now()) : (catalog == null ? (code: 'unreachable', at: _now()) : null);
      _log('catalog: ${e.code}');
    }
    if (off) _listings = const [];
    _say();
    // The withdrawals: from where the catalog came, and from Uplink's own relay too where that is another
    // (a relay can withhold them; ours is read whatever net_hub says).
    await _takeRevoked(api);
    if (marketUrlFor(api.hubUrl).toString() != _defaultMarket) await _takeRevoked(api.at(Net.defaultHub));
    if (!off && catalog != null) await _check(api, catalog!);
    if (await _mineWanted()) await readMine();
  }

  static final String _defaultMarket = marketUrlFor(Net.defaultHub).toString();

  /// Reads [api]'s withdrawals and hands them to the installer, which checks each signature; a failure is only logged.
  Future<void> _takeRevoked(MarketApi api) async {
    try {
      final list = await api.revoked();
      // An empty list has nothing to take: the installer is left alone, and its revoked.json isn't written again.
      if (list != null && (list.revoked.isNotEmpty || list.retired.isNotEmpty)) await installed.takeRevocations(list.json);
    } catch (e) {
      _log('revoked: ${e is MarketError ? e.code : e}');
    }
  }

  /// Fetches and checks the catalog's packages: the newest changes first, at most 200, those already checked kept as
  /// they are. Each entry's approval is checked before anything else is done with it, since it needs the entry alone:
  /// only one whose signature holds is fetched (4 at a time), kept on disk and read, and the reading is done on an
  /// isolate of its own. A catalog of signatures that don't hold (a relay broken into could list 200 a refresh, each
  /// naming a pinned key and a package made to be slow to read) costs this device their checks and nothing more
  /// (review, 2026-11-20).
  Future<void> _check(MarketApi api, Catalog catalog) async {
    final entries = [...catalog.plugins]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final todo = entries.take(200).toList();
    final had = {for (final l in _listings) l.entry.sha256: l};
    final kept = <String, ListingPlugin>{};
    final fresh = <CatalogEntry>[];
    for (final e in todo) {
      final l = had[e.sha256];
      // Kept as checked, unless it has been withdrawn since or its key is no longer trusted.
      if (l != null && l.entry.id == e.id && l.entry.version == e.version && !installed.isRevoked(e.id, e.sha256) && _approvalWords(e, installed.reviewKeys, installed.retiredKeys) == null) {
        kept[e.sha256] = ListingPlugin(e, l.pack, this, needsNewerApp: l.needsNewerApp);
      } else {
        fresh.add(e);
      }
    }
    final keys = installed.reviewKeys;
    final retired = installed.retiredKeys;
    // Judged without a byte fetched: its words and its key, whether it was withdrawn, then its signature.
    var tried = 0;
    final candidates = <CatalogEntry>[];
    for (final e in fresh) {
      final why = _approvalWords(e, keys, retired);
      if (why != null) {
        tried++;
        _leaveOut(e, why);
      } else if (installed.isRevoked(e.id, e.sha256)) {
        _leaveOut(e, 'revoked');
      } else {
        candidates.add(e);
      }
    }
    checking = candidates.length;
    _say();
    final verified = await _verified(candidates, keys, retired);
    tried += candidates.length;
    checking = verified.length;
    _say();
    final fetched = <(CatalogEntry, Uint8List)>[];
    var next = 0;
    Future<void> worker() async {
      while (next < verified.length) {
        final e = verified[next++];
        try {
          final bytes = await _packageOf(api, e, keep: false);
          if (bytes == null) continue;
          if (sha256Hex(bytes) != e.sha256) {
            _leaveOut(e, 'sha_mismatch');
            continue;
          }
          fetched.add((e, bytes));
        } catch (err) {
          _leaveOut(e, 'failed: $err');
        } finally {
          checking--;
          _say();
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    final packs = await _read(fetched, _version);
    final checked = <String, (Uint8List, PluginPack)>{};
    for (var i = 0; i < fetched.length; i++) {
      final (e, bytes) = fetched[i];
      final pack = i < packs.length ? packs[i] : null;
      if (pack == null) {
        _leaveOut(e, 'invalid');
        continue;
      }
      if (pack.id != e.id || pack.version != e.version) {
        _leaveOut(e, 'listing_mismatch');
        continue;
      }
      checked[e.sha256] = (bytes, pack);
      // Only a package that became a listing is kept on disk.
      final file = _packageFile(e.sha256);
      if (!await file.exists()) await _keepPackage(file, bytes);
    }
    final listings = <ListingPlugin>[];
    for (final e in todo) {
      final old = kept[e.sha256];
      if (old != null) {
        listings.add(old);
        continue;
      }
      final got = checked[e.sha256];
      if (got == null) continue;
      final (bytes, pack) = got;
      _hold(e.sha256, bytes);
      listings.add(ListingPlugin(e, pack, this, needsNewerApp: pack.minApp != null && _newer(pack.minApp!, _version)));
    }
    _listings = listings;
    checking = 0;
    // Entries, and not one of them verifies with what this build trusts: an older build, or one that pins no key yet.
    if (problem == null && todo.isNotEmpty && kept.isEmpty && verified.isEmpty && (tried > 0 || keys.isEmpty)) problem = (code: 'untrusted', at: _now());
    _say();
  }

  /// Why [e]'s approval can't verify without looking at its signature, or null: it names another plugin, version or
  /// package than the entry, or a key this build doesn't trust.
  static String? _approvalWords(CatalogEntry e, List<String> keys, Set<String> retired) {
    final a = e.approval;
    if (a.v != 1 || a.plugin != e.id || a.version != e.version || a.sha256 != e.sha256) return 'bad_approval';
    if (!keys.contains(a.key) || retired.contains(a.key)) return 'untrusted_key';
    return null;
  }

  /// The entries of [entries] whose signatures verify, in order. A signature that verified once is kept in
  /// verified.json (by the SHA-256 of its key, signature and words), so a refresh checks only what is new.
  Future<List<CatalogEntry>> _verified(List<CatalogEntry> entries, List<String> keys, Set<String> retired) async {
    if (entries.isEmpty) return const [];
    final known = await _verifiedKept();
    final ask = [for (final e in entries) if (!known.contains(_markOf(e.approval))) e];
    final good = <CatalogEntry>{for (final e in entries) if (known.contains(_markOf(e.approval))) e};
    if (ask.isNotEmpty) {
      List<bool> ok;
      try {
        ok = await _verify([for (final e in ask) (approval: e.approval, plugin: e.id, version: e.version, sha256: e.sha256, keys: keys, retired: retired)]);
      } catch (e) {
        _log('verifying: $e');
        ok = List.filled(ask.length, false);
      }
      var added = false;
      for (var i = 0; i < ask.length; i++) {
        final e = ask[i];
        if (i < ok.length && ok[i]) {
          good.add(e);
          added = known.add(_markOf(e.approval)) || added;
        } else {
          _leaveOut(e, 'bad_approval');
        }
      }
      if (added) await _keepVerified(known);
    }
    return [for (final e in entries) if (good.contains(e)) e];
  }

  /// Each of [fetched] read as a pack for an app at [version] (its minApp left for the listing to say), on an isolate of
  /// its own in the app: a package is up to 256 KiB of phrases to compile. Null for one that isn't a pack.
  static Future<List<PluginPack?>> _read(List<(CatalogEntry, Uint8List)> fetched, String version) {
    if (fetched.isEmpty) return Future.value(const []);
    final all = [for (final (_, bytes) in fetched) bytes];
    List<PluginPack?> each() => [for (final bytes in all) parsePack(bytes, appVersion: version, checkMinApp: false).pack];
    return verifyInIsolate ? runAside(each) : Future.value(each());
  }

  /// What a verified signature is kept under in verified.json: the SHA-256 of its key, its signature and its words.
  static String _markOf(PackApproval a) => sha256Hex(utf8.encode('${a.key}\n${a.sig}\n${approvalWords(a.plugin, a.version, a.sha256)}'));

  void _leaveOut(CatalogEntry e, String why) => _log('${e.id} left out: $why');

  /// A line in the Developer log under 'market'; never throws.
  void _log(String line) {
    try {
      Sms.instance.devLog('market', line);
    } catch (_) {}
  }

  // --- the packages, kept -------------------------------------------------------------------------------------------

  /// Checked packages' bytes in memory, the least lately read going first past 64 MiB: what Add hands the installer,
  /// so the bytes installed are the bytes checked.
  final Map<String, Uint8List> _held = {};
  int _heldBytes = 0;
  static const int _most = 64 * 1024 * 1024;

  /// Holds [bytes] as the newest read; a map keeps the order its keys went in, so the first key is the least lately
  /// read.
  void _hold(String sha, Uint8List bytes) {
    final had = _held.remove(sha);
    if (had != null) _heldBytes -= had.length;
    _held[sha] = bytes;
    _heldBytes += bytes.length;
    while (_heldBytes > _most && _held.length > 1) {
      final first = _held.keys.first;
      _heldBytes -= _held.remove(first)!.length;
    }
  }

  /// The bytes held for [sha], now the newest read; null where none are.
  Uint8List? _heldOf(String sha) {
    final b = _held.remove(sha);
    if (b != null) _held[sha] = b;
    return b;
  }

  File _packageFile(String sha) => File('${cache.path}${PlatformInfo.pathSeparator}packages${PlatformInfo.pathSeparator}$sha');

  /// [e]'s package: held, kept on disk, or fetched (and then kept, unless [keep] is false: the check keeps only what
  /// became a listing). Null where it couldn't be had (said in the log).
  Future<Uint8List?> _packageOf(MarketApi api, CatalogEntry e, {bool keep = true}) async {
    final held = _heldOf(e.sha256);
    if (held != null) return held;
    final file = _packageFile(e.sha256);
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.length <= PackLimits.packageBytes) {
          unawaited(file.setLastModified(_now()).catchError((_) {}));
          return bytes;
        }
      }
    } catch (_) {}
    try {
      final bytes = await api.package(e.sha256);
      // Only what is the catalog's is kept under its name.
      if (keep && sha256Hex(bytes) == e.sha256) await _keepPackage(file, bytes);
      return bytes;
    } on MarketError catch (err) {
      _leaveOut(e, 'fetch ${err.code}');
      return null;
    }
  }

  /// Writes a package to the cache under its SHA-256, then trims the cache; a failure is let go, since the cache only
  /// saves a fetch.
  Future<void> _keepPackage(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await _write(file, bytes);
      // At most 64 MiB on disk too, the least lately read going first.
      final files = [for (final f in await file.parent.list().toList()) if (f is File && !f.path.endsWith('.tmp')) f];
      var total = 0;
      final sized = <(File, int, DateTime)>[];
      for (final f in files) {
        final s = await f.stat();
        total += s.size;
        sized.add((f, s.size, s.modified));
      }
      sized.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (f, size, _) in sized) {
        if (total <= _most || f.path == file.path) break;
        await f.delete();
        total -= size;
      }
    } catch (_) {}
  }

  // --- screenshots -----------------------------------------------------------------------------------------------------

  final Map<String, Uint8List> _shots = {};

  /// A listed plugin's screenshot by its SHA-256 (route 6), only where its bytes are that one, a few kept for the page
  /// that asks again; null where it can't be had.
  Future<Uint8List?> shotOf(String sha256) async {
    final had = _shots.remove(sha256);
    if (had != null) return _shots[sha256] = had;
    try {
      final bytes = await api.shot(sha256);
      if (sha256Hex(bytes) != sha256) return null;
      _shots[sha256] = bytes;
      while (_shots.length > 24) {
        _shots.remove(_shots.keys.first);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  // --- adding and updating ------------------------------------------------------------------------------------------

  /// Adds [l]: the bytes that were checked, with its approval, switched on (the person agreed on its sheet).
  Future<PackOutcome> install(ListingPlugin l) => _put(l, on: true);

  /// Puts [l] in place of the version on this device, the switch left as the person left it.
  Future<PackOutcome> update(ListingPlugin l) => _put(l, on: false);

  /// Hands [l]'s checked bytes and its approval to the installer, one at a time for each plugin ([adding]).
  Future<PackOutcome> _put(ListingPlugin l, {required bool on}) async {
    final id = l.pack.id;
    if (_adding.contains(id)) return PackOutcome.failed('busy', '${l.name} is being added.');
    _adding.add(id);
    _say();
    try {
      final bytes = await _packageOf(api, l.entry);
      if (bytes == null || sha256Hex(bytes) != l.entry.sha256) return PackOutcome.failed('fetch_failed', 'Couldn\'t fetch ${l.name}. Try again in a moment.');
      return await installed.installReviewed(bytes, l.entry.approval, listing: {'listedAt': l.entry.listedAt}, on: on);
    } catch (e) {
      return PackOutcome.failed('failed', 'Couldn\'t add ${l.name}: $e');
    } finally {
      _adding.remove(id);
      _say();
    }
  }

  // --- the developer's own --------------------------------------------------------------------------------------------

  File get _mineFile => File('${cache.path}${PlatformInfo.pathSeparator}mine.json');

  /// What mine.json last said: each submission's status by its sid, and each plugin's listing by its id.
  Future<({Map<String, String> seen, Map<String, String> plugins})?> _mineKept() async {
    try {
      final j = jsonDecode(await _mineFile.readAsString());
      if (j is! Map || j['v'] != 1) return null;
      Map<String, String> strings(Object? m) => {for (final e in (m is Map ? m : const {}).entries) if (e.key is String && e.value is String) e.key as String: e.value as String};
      return (seen: strings(j['seen']), plugins: strings(j['plugins']));
    } catch (_) {
      return null;
    }
  }

  /// Writes mine.json: what the next read is compared with, to tell what changed.
  Future<void> _keepMine(Map<String, String> seen, Map<String, String> plugins) async {
    try {
      await cache.create(recursive: true);
      await _write(_mineFile, utf8.encode(jsonEncode({'v': 1, 'seen': seen, 'plugins': plugins})));
    } catch (_) {}
  }

  /// Whether the developer has anything to hear of: a submission waiting, or a plugin listed.
  Future<bool> _mineWanted() async {
    final kept = await _mineKept();
    if (kept == null) return false;
    return kept.seen.values.any((s) => s == 'submitted' || s == 'in_review' || s == 'changes_requested') || kept.plugins.values.any((l) => l == 'listed');
  }

  /// A submission just sent: kept as waiting, so its decision is heard of later.
  Future<void> submitted(SubmissionView s) async {
    final kept = await _mineKept();
    await _keepMine({...?kept?.seen, s.sid: s.status}, {...?kept?.plugins});
  }

  /// Route 9: kept as [mine], and each change since it was last read told once as a notice (none the first time).
  Future<MyMarket?> readMine() async {
    final MyMarket got;
    try {
      got = await api.mine();
    } catch (e) {
      _log('mine: ${e is MarketError ? e.code : e}');
      return null;
    }
    await _heardMine(got, tell: true);
    return got;
  }

  /// Route 9's answer, read by My submissions itself: kept as [mine] and in mine.json as seen, with no notice, since the
  /// developer is looking at it.
  Future<void> seenMine(MyMarket got) => _heardMine(got, tell: false);

  /// Keeps [got] as [mine] and in mine.json. With [tell], a notice for each submission whose status changed since
  /// mine.json was written, and for each plugin the reviewer took off the Marketplace.
  Future<void> _heardMine(MyMarket got, {required bool tell}) async {
    mine = got;
    _say();
    final kept = tell ? await _mineKept() : null;
    final seen = {for (final s in got.submissions) s.sid: s.status};
    final plugins = {for (final p in got.plugins) p.id: p.listing};
    if (kept != null) {
      for (final s in got.submissions) {
        final was = kept.seen[s.sid];
        if (was == null || was == s.status) continue;
        final words = _toldOf(s, got);
        if (words != null) _notices.add(PackNotice('submission', s.plugin, words));
      }
      for (final p in got.plugins) {
        final was = kept.plugins[p.id];
        if (was == 'listed' && p.listing == 'unlisted' && p.by == 'admin') {
          final name = got.submissions.where((s) => s.plugin == p.id).firstOrNull?.name ?? p.id;
          _notices.add(PackNotice('submission', p.id, '$name was taken off the Marketplace.'));
        }
      }
    }
    await _keepMine(seen, plugins);
    _say();
  }

  /// The toast's words for a submission's new status; null for a status nobody is told of.
  static String? _toldOf(SubmissionView s, MyMarket mine) => switch (s.status) {
        'changes_requested' => '${s.name} ${s.version}: changes asked for. See Marketplace › My submissions.',
        'approved' => s.listing == 'listed' || (s.listing == null && s.list == 'now')
            ? '${s.name} ${s.version} was approved and is listed.'
            : '${s.name} ${s.version} was approved. List it from My submissions when you\'re ready.',
        'rejected' => '${s.name} ${s.version} wasn\'t accepted.',
        _ => null,
      };

  // --- the submission form's drafts (D.8) -----------------------------------------------------------------------------

  final Map<String, SubmitDraft> _drafts = {};

  /// The pack the submission form last held, in memory: the form opened again comes back to it and its draft, so
  /// leaving the Marketplace (Settings › Me, a notification's conversation) loses nothing. Null once it is sent.
  PluginPack? submitting;

  Directory _draftDir(String packId) => Directory('${cache.path}${PlatformInfo.pathSeparator}drafts${PlatformInfo.pathSeparator}$packId');

  /// The draft kept for [packId], where there is one.
  SubmitDraft? draftOf(String packId) => _drafts[packId];

  /// The writes of each pack's draft, one after another, so two saves never write the same files at once.
  final Map<String, Future<void>> _draftWrites = {};

  /// Every draft write asked for so far, done: what a test reads the disk after.
  @visibleForTesting
  Future<void> get draftsWritten => Future.wait([..._draftWrites.values]);

  /// Keeps [d] in memory at once (the form comes back to it however soon it is opened again), and, with [toDisk], on
  /// disk after any earlier save of the same draft, its new screenshots written beside it (`shot-<n>.png`). The form
  /// keeps each change in memory as it is made and writes the whole when a pack loads, its screenshots change and it
  /// goes: a screenshot is up to a megabyte, too much to write again for every letter typed.
  Future<void> saveDraft(SubmitDraft d, {bool toDisk = true}) {
    if (!packIdPattern.hasMatch(d.packId)) return Future.value();
    final kept = d.copyWith(at: _now().millisecondsSinceEpoch);
    _drafts[d.packId] = kept;
    if (!toDisk) return Future.value();
    final write = (_draftWrites[d.packId] ?? Future<void>.value()).then((_) => _writeDraft(kept));
    _draftWrites[d.packId] = write;
    return write.whenComplete(() {
      if (identical(_draftWrites[d.packId], write)) _draftWrites.remove(d.packId);
    });
  }

  /// [d] on disk: each screenshot that is new bytes as a file beside draft.json, which names the files.
  Future<void> _writeDraft(SubmitDraft d) async {
    // Sent for review (or dropped) while it waited: nothing of it is written again.
    if (_drafts[d.packId] == null) return;
    final dir = _draftDir(d.packId);
    final shots = <DraftShot>[];
    try {
      await dir.create(recursive: true);
      for (final (i, s) in d.shots.indexed) {
        if (s.keep != null || s.bytes == null) {
          shots.add(s);
          continue;
        }
        final file = File('${dir.path}${PlatformInfo.pathSeparator}shot-$i.png');
        await _write(file, s.bytes!);
        shots.add(DraftShot(bytes: s.bytes, path: file.path));
      }
      if (_drafts[d.packId] == null) return;
      await _write(File('${dir.path}${PlatformInfo.pathSeparator}draft.json'), utf8.encode(jsonEncode(d.copyWith(shots: shots).toJson())));
    } catch (_) {}
  }

  /// The version of [packId] the Marketplace holds as current, as route 9 last said (its developer's own plugin), else
  /// as the catalog lists it; null where it has none.
  String? currentVersionOf(String packId) => mine?.plugins.where((p) => p.id == packId).firstOrNull?.current ?? catalog?.plugins.where((e) => e.id == packId).firstOrNull?.version;

  /// Deletes the draft for [packId]: sent for review. After any save still writing it, so none puts it back.
  Future<void> dropDraft(String packId) async {
    _drafts.remove(packId);
    if (!packIdPattern.hasMatch(packId)) return;
    try {
      await _draftWrites[packId];
    } catch (_) {}
    try {
      final dir = _draftDir(packId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// The drafts kept on disk, read into memory (their screenshots' bytes with them).
  Future<void> loadDrafts() async {
    try {
      final root = Directory('${cache.path}${PlatformInfo.pathSeparator}drafts');
      if (!await root.exists()) return;
      await for (final dir in root.list()) {
        if (dir is! Directory) continue;
        try {
          final j = jsonDecode(await File('${dir.path}${PlatformInfo.pathSeparator}draft.json').readAsString());
          if (j is! Map) continue;
          final d = SubmitDraft.fromJson(j);
          if (!packIdPattern.hasMatch(d.packId)) continue;
          final shots = <DraftShot>[
            for (final s in d.shots)
              if (s.keep != null)
                s
              else if (s.path != null && await File(s.path!).exists())
                DraftShot(bytes: await File(s.path!).readAsBytes(), path: s.path),
          ];
          _drafts[d.packId] ??= d.copyWith(shots: shots);
        } catch (_) {}
      }
    } catch (_) {}
  }

  // --- the catalog and the signatures, kept ---------------------------------------------------------------------------

  File get _catalogFile => File('${cache.path}${PlatformInfo.pathSeparator}catalog.json');
  File get _verifiedFile => File('${cache.path}${PlatformInfo.pathSeparator}verified.json');

  /// The catalog as last read, with its ETag, written to and read from catalog.json: what a start shows before the
  /// relay answers, and what a 304 leaves standing.
  Future<void> _keepCatalog(Catalog c) async {
    try {
      await cache.create(recursive: true);
      await _write(_catalogFile, utf8.encode(jsonEncode({'etag': c.etag, 'catalog': c.toJson()})));
    } catch (_) {}
  }

  Future<Catalog?> _keptCatalog() async {
    try {
      final j = jsonDecode(await _catalogFile.readAsString());
      if (j is! Map || j['catalog'] is! Map) return null;
      return Catalog.fromJson(j['catalog'] as Map, etag: j['etag'] is String ? j['etag'] as String : null);
    } catch (_) {
      return null;
    }
  }

  /// The marks ([_markOf]) of the signatures that verified before, read from and written to verified.json.
  Future<Set<String>> _verifiedKept() async {
    try {
      final j = jsonDecode(await _verifiedFile.readAsString());
      if (j is Map && j['v'] == 1 && j['ok'] is List) return {for (final s in j['ok'] as List) if (s is String) s};
    } catch (_) {}
    return {};
  }

  Future<void> _keepVerified(Set<String> marks) async {
    try {
      await cache.create(recursive: true);
      await _write(_verifiedFile, utf8.encode(jsonEncode({'v': 1, 'ok': marks.toList()})));
    } catch (_) {}
  }

  /// [file] written whole or not at all: to its .tmp, then renamed into place.
  static Future<void> _write(File file, List<int> bytes) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_notices.close());
    super.dispose();
  }
}
