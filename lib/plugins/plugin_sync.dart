/// Which plugins are on, synced across every device signed in to one Uplink account (GMFB-9, @kevin: "Sync plugins: It
/// would be convenient to sync plugins across devices at least for the messaging apps and stuff"; Matt asked for it to
/// be built, 2026-11-21).
///
/// **What is synced.** A list, one line per plugin the person switched (by its registry id): on or off, when, and for a
/// Marketplace pack the version that was on. The app's own plugins, the network plugins (WhatsApp, Matrix, Teams, ...;
/// lib/plugins/networks.dart) and packs from the Marketplace. Never a plugin in development (it came from this device's
/// own files), never a plugin's own choices, and never a sign-in: a network plugin synced on is switched on so it
/// offers its sign-in on that device, nothing more. Sessions stay on the device that made them, both ways.
///
/// **Where it lives.** Beside the extension's cURL entries in the account's one sealed blob on the relay (`curl-keep`,
/// lib/inbox/curl_sync.dart), under `plugins`: `{v:1, entries:{...}, plugins:{v:1, list:{<id>:{on, at, ver?}}}}`. The
/// relay keeps that slot per account identity and can't read it; it is sealed with the key every device of the account
/// derives from its recovery words (Me.curlKeyOf, 'ghost curl v1'). So no relay change: the relay holds one opaque blob
/// per account and doesn't know what is in it. Each device also keeps the whole list in its own preferences
/// (`plugins_sync`), so a blob written by something that doesn't know of `plugins` (an extension from before this, or
/// two writers racing) loses nothing for long: the next device to sync writes its list back.
///
/// **The rule.** Only what the person does is a line: a switch pressed, a pack added or removed, here (or by the app's
/// API). What the app does by itself — a network settled off at an upgrade, a pack withdrawn or paused, a switch the
/// sync itself moved — is never one. Two lines for one plugin: the newer wins (equal times: on wins, so a clock tie
/// never takes a plugin away). A device applies a line once, when it first sees it (it remembers what it applied), so
/// switching a plugin back here afterwards is a newer line of its own, not undone by the old one.
///   * On: switched on here; a Marketplace pack not on this device is fetched and checked as any pack from the
///     Marketplace is (MarketState.install: the reviewed package, its signature, its hash), once its listing is here.
///   * Off: switched off here, which is what the person did on the other device. Except a network signed in to here:
///     its session is this device's, and sync never ends one (it is left on; the person signs out here if they want).
///     A pack removed on another device is switched off here, not deleted: its files and choices stay until removed
///     here.
///   * A plugin no line names is left as it is. Turning sync on (or a first sync with an account) seeds the list with
///     what this device has chosen so far — every plugin switched by hand, and the packs and networks that are on — at
///     times before any real change (on just after off), so the first syncs join the devices' plugins rather than one
///     device's defaults taking the others' away.
///
/// **When.** On each change, a few seconds later (one write for a run of changes); on reaching the relay (Me's hello,
/// at start and every reconnect); and as the app comes back to the front, at most once a minute. Quiet: nothing is
/// asked or toasted; a pack waiting on the Marketplace's listings is added when they arrive.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../inbox/inbox.dart';
import '../market/market_state.dart';
import '../me/me.dart';
import '../net/crypto.dart';
import 'networks.dart';
import 'pack/format.dart' show compareVersions, packIdOf;
import 'pack/installed.dart';
import 'pack/pack_plugin.dart';
import 'plugin.dart';
import 'registry.dart';

/// One plugin's line in the synced list: switched [on] or off by the person at [at] (ms since the epoch); for a pack
/// from the Marketplace, the [version] that was on.
@immutable
class SyncedPlugin {
  const SyncedPlugin({required this.on, required this.at, this.version});
  final bool on;
  final int at;
  final String? version;

  /// What a device remembers having applied: a line is applied again only once it is another line.
  String get mark => '$at${on ? '+' : '-'}';

  Map<String, Object?> toJson() => {'on': on, 'at': at, if (version != null) 'ver': version};

  static SyncedPlugin? fromJson(Object? j) {
    if (j is! Map) return null;
    final on = j['on'], at = j['at'], ver = j['ver'];
    if (on is! bool || at is! num) return null;
    return SyncedPlugin(on: on, at: at.toInt(), version: ver is String && ver.isNotEmpty ? ver : null);
  }

  @override
  bool operator ==(Object other) => other is SyncedPlugin && other.on == on && other.at == at && other.version == version;
  @override
  int get hashCode => Object.hash(on, at, version);
}

/// The synced list's rules, apart from any device: read, written, joined.
abstract final class PluginSyncList {
  static const version = 1;

  /// Seeded lines' times (see the library's rule): before any real change, on after off.
  static const seedOff = 1, seedOn = 2;

  // An id as the registry has them (lower-case letters and digits, a pack's starting with x), at most 33 long.
  static final _id = RegExp(r'^[a-z0-9]{1,40}$');

  /// The list in `plugins` of the account's blob, or in this device's own preferences; {} for anything else.
  static Map<String, SyncedPlugin> parse(Object? section) {
    if (section is! Map || section['v'] != version) return {};
    final list = section['list'];
    if (list is! Map) return {};
    return {
      for (final e in list.entries)
        if (e.key is String && _id.hasMatch(e.key as String)) e.key as String: ?SyncedPlugin.fromJson(e.value),
    };
  }

  /// [list] as it is written, in the blob's `plugins` and in this device's preferences: what [parse] reads.
  static Map<String, Object?> encode(Map<String, SyncedPlugin> list) => {
        'v': version,
        'list': {for (final e in list.entries) e.key: e.value.toJson()},
      };

  /// Whether [a] wins over [b], two lines for one plugin: the newer; at the same time, on over off, then the higher
  /// version, so two devices always agree on one.
  static bool wins(SyncedPlugin a, SyncedPlugin b) {
    if (a.at != b.at) return a.at > b.at;
    if (a.on != b.on) return a.on;
    final av = a.version, bv = b.version;
    if (av == null || bv == null) return av != null;
    return compareVersions(av, bv) > 0;
  }

  /// [a] and [b] joined: every plugin either names, with the line that [wins].
  static Map<String, SyncedPlugin> merge(Map<String, SyncedPlugin> a, Map<String, SyncedPlugin> b) {
    final out = {...a};
    for (final e in b.entries) {
      final had = out[e.key];
      if (had == null || wins(e.value, had)) out[e.key] = e.value;
    }
    return out;
  }

  /// Whether two lists hold the same lines: where they do, nothing is written to the relay.
  static bool same(Map<String, SyncedPlugin> a, Map<String, SyncedPlugin> b) => mapEquals(a, b);

  /// The account's blob with [list] in it: everything else in [kept] (the extension's cURL entries) as it was.
  static Map<String, Object?> blobWith(Map<String, Object?>? kept, Map<String, SyncedPlugin> list) => {
        ...?kept,
        'v': kept?['v'] ?? 1,
        'entries': kept?['entries'] ?? const <String, Object?>{},
        'plugins': encode(list),
      };

  /// [whole] sealed with the account's key, as Me.curlKeep seals it.
  static Uint8List seal(List<int> key, Map<String, Object?> whole) => NetCrypto.seal(key, utf8.encode(jsonEncode(whole)));

  /// The list in a blob sealed with [key]; null where it doesn't open with that key.
  static Map<String, SyncedPlugin>? open(List<int> key, List<int> sealed) {
    final clear = NetCrypto.open(key, sealed);
    if (clear == null) return null;
    final whole = jsonDecode(utf8.decode(clear));
    return whole is Map ? parse(whole['plugins']) : {};
  }
}

/// A plugin as this device has it now, for applying a line.
@immutable
class PluginHere {
  const PluginHere({required this.on, this.network = false, this.signedIn = false, this.version});
  final bool on;

  /// A network plugin, and whether it is signed in to here (a session sync never ends).
  final bool network, signedIn;

  /// A Marketplace pack's version here.
  final String? version;
}

/// What fetching a Marketplace pack came to.
enum PackFetch {
  /// It is on this device now, switched on.
  done,

  /// Not yet (no listing yet, an older one, a newer app needed, the Marketplace unreachable): tried again later.
  later,

  /// It can't be on this device (an iPhone, which has no packs; withdrawn): nothing more is tried for this line.
  never,
}

/// What plugin sync needs of a device: the relay's blob and this device's plugins. The app's is [AppPluginSyncHost]; a
/// test has its own.
abstract interface class PluginSyncHost {
  /// Whether an Uplink account is here to sync with (its key, and the relay reachable).
  Future<bool> ready();

  /// The account's whole blob, opened; null where nothing is kept. Throws where it can't be read (so it isn't
  /// written over).
  Future<Map<String, Object?>?> kept();

  /// Seals [whole] and keeps it on the relay in place of the account's blob.
  Future<void> keep(Map<String, Object?> whole);

  /// Which account this is, so a list kept for another one is not carried into it.
  String get account;

  /// [id] as it is here; null where no plugin of that id is here (yet): a pack not installed, a network not started,
  /// a plugin of a newer build.
  PluginHere? here(String id);

  /// Switches [id] on or off here (as its switch does; a network: started, or stopped where it isn't signed in to).
  Future<void> turn(String id, bool on);

  /// Fetches and adds the Marketplace pack [packId], at [version] or newer, switched on.
  Future<PackFetch> fetch(String packId, String? version);

  /// What this device has chosen so far, for seeding: every plugin switched by hand here, and the packs and networks
  /// that are on, each with its version where it is a pack.
  Map<String, ({bool on, String? version})> chosen();

  /// This device's own copy of the list, and what it has applied ([SyncedPlugin.mark] by id).
  String read(String key);
  void write(String key, String value);

  /// The time, in ms since the epoch: a line's [SyncedPlugin.at]. A test sets its own.
  int now();
}

/// Plugin sync for this device: [switched] when the person moves a switch, [sync] to meet the account's list.
class PluginSync {
  PluginSync({PluginSyncHost? host}) : _host = host;
  static PluginSync instance = PluginSync();

  PluginSyncHost? _host;
  PluginSyncHost? get host => _host;

  /// The switch in Settings › Plugins (and the Marketplace's Added): on unless switched off. Nothing is synced without
  /// an Uplink account, whatever it says.
  static const onKey = 'plugins_sync_on';

  /// This device's copy: `{v:1, list:{...}, applied:{id:mark}, seeded:bool, account:'...'}`. Not under `plugin_`, the
  /// plugins' own choices.
  static const stateKey = 'plugins_sync';

  bool get enabled => _host != null && _host!.read(onKey) != 'off';

  // This device's copy ([stateKey]), read once ([_read]): the list, the mark of each line already applied here, whether
  // the list has been seeded with this device's choices, and the account it was kept for.
  Map<String, SyncedPlugin> _list = {};
  Map<String, String> _applied = {};
  bool _seeded = false;
  String _account = '';
  bool _read = false;

  /// Ids a sync is switching right now: what the switches say of them is the sync's doing, not the person's.
  final Set<String> _applying = {};

  // The sync a few seconds after a change, the next try at lines still waiting, the sync running now (and whether to
  // run once more after it), and when the app last came to the front.
  Timer? _push;
  Timer? _retry;
  Future<void>? _running;
  bool _again = false;
  DateTime? _lastFront;

  /// The list as this device has it (a test's look).
  Map<String, SyncedPlugin> get list => Map.unmodifiable(_list);

  /// Starts it on [app]: the app's own host, the registry's switches heard, the Marketplace's listings watched (a pack
  /// waiting for them), and the app coming to the front.
  void start(AppState app) {
    if (_host != null) return;
    _host = AppPluginSyncHost(app);
    attachHooks();
    MarketState.instance.addListener(_marketChanged);
    WidgetsBinding.instance.addObserver(_Front(this));
    // And every two minutes while the app runs: a computer's window stays open, never "brought to the front", and
    // another device's switch reached it only at the next start (Matt, 2026-11-21: "Plugins should sync across
    // devices also").
    Timer.periodic(const Duration(minutes: 2), (_) => unawaited(sync()));
  }

  /// Hears the person's switches: the registry's, where every plugin's switch goes (a test calls it with its own host).
  @visibleForTesting
  void attachHooks() {
    PluginRegistry.switched = _registrySwitched;
  }

  void _load() {
    if (_read) return;
    final host = _host;
    if (host == null) return;
    _read = true;
    try {
      final j = jsonDecode(host.read(stateKey));
      if (j is Map) {
        _list = PluginSyncList.parse(j);
        _applied = {for (final e in (j['applied'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
        _seeded = j['seeded'] == true;
        _account = j['account'] is String ? j['account'] as String : '';
      }
    } catch (_) {}
  }

  void _save() => _host?.write(stateKey, jsonEncode({...PluginSyncList.encode(_list), 'applied': _applied, 'seeded': _seeded, 'account': _account}));

  // --- the person's changes -----------------------------------------------------------------------------------------

  /// A plugin's switch moved in the registry: a line for it, with a Marketplace pack's version.
  void _registrySwitched(GhostPlugin plugin, bool on) {
    String? version;
    if (plugin is PackPlugin) {
      // A plugin in development is this device's own files: never synced.
      if (plugin.source != PluginSource.reviewed) return;
      version = plugin.pack.version;
    }
    switched(plugin.id, on, version: version);
  }

  /// The person switched [id] on or off here (a pack added or removed, a network's switch in Settings › Connections):
  /// a line, kept for the other devices a few seconds later.
  void switched(String id, bool on, {String? version}) {
    final host = _host;
    if (host == null || !enabled || _applying.contains(id)) return;
    _load();
    final had = _list[id];
    // Later than the line it replaces, whatever this device's clock says.
    final at = had != null && had.at >= host.now() ? had.at + 1 : host.now();
    final line = SyncedPlugin(on: on, at: at, version: version ?? (on ? null : had?.version));
    _list[id] = line;
    _applied[id] = line.mark;
    _save();
    _push?.cancel();
    _push = Timer(const Duration(seconds: 3), () => unawaited(sync()));
  }

  /// Sync switched on or off in Settings. On again: what this device chose meanwhile is seeded again, and it syncs.
  void setEnabled(bool on) {
    final host = _host;
    if (host == null) return;
    host.write(onKey, on ? 'on' : 'off');
    if (!on) return;
    _load();
    _seeded = false;
    _save();
    unawaited(sync());
  }

  // --- meeting the account's list ------------------------------------------------------------------------------------

  /// Reads the account's list, joins it with this device's, applies what is new here, and keeps the joined list where
  /// it differs. One at a time; asked again while one runs, it runs once more after.
  Future<void> sync() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _sync().whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        unawaited(sync());
      }
    });
  }

  Future<void> _sync() async {
    final host = _host;
    if (host == null || !enabled) return;
    try {
      if (!await host.ready()) return;
      _load();
      // Another account than the one this list was kept for: its list is that account's, not this one's. (None yet: a
      // first sync, whose lines are this device's own changes so far, kept.)
      if (_account != host.account) {
        if (_account.isNotEmpty) {
          _list = {};
          _applied = {};
          _seeded = false;
        }
        _account = host.account;
      }
      if (!_seeded) _seed(host);
      final kept = await host.kept();
      final there = PluginSyncList.parse(kept?['plugins']);
      _list = PluginSyncList.merge(_list, there);
      _save();
      await _apply(host);
      if (!PluginSyncList.same(_list, there)) await host.keep(PluginSyncList.blobWith(kept, _list));
    } catch (_) {
      // The relay away, the blob unreadable: nothing written; the next sync tries again.
    }
  }

  /// What this device has chosen so far, as lines from before any real change (see the library's rule): only where the
  /// list has no line for that plugin yet.
  void _seed(PluginSyncHost host) {
    for (final e in host.chosen().entries) {
      if (_list.containsKey(e.key)) continue;
      final line = SyncedPlugin(on: e.value.on, at: e.value.on ? PluginSyncList.seedOn : PluginSyncList.seedOff, version: e.value.version);
      _list[e.key] = line;
      _applied[e.key] = line.mark;
    }
    _seeded = true;
  }

  /// Applies every line this device hasn't yet, from its own copy (no relay): after a sync, and when what was waiting
  /// may be ready (the Marketplace's listings arrived, a minute passed).
  Future<void> applyPending() async {
    final host = _host;
    if (host == null || !enabled) return;
    _load();
    await _apply(host);
  }

  Future<void>? _applyRun;

  // One pass at a time: a pass asked for while one runs (the Marketplace telling of the install the pass is doing) is
  // that pass's work already.
  Future<void> _apply(PluginSyncHost host) {
    final running = _applyRun;
    if (running != null) return running;
    return _applyRun = _applyAll(host).whenComplete(() => _applyRun = null);
  }

  /// Applies each line not yet applied here, remembering those done; where any must wait, tries again in a minute.
  Future<void> _applyAll(PluginSyncHost host) async {
    var waiting = false;
    var changed = false;
    for (final e in _list.entries.toList()) {
      if (_applied[e.key] == e.value.mark) continue;
      final bool done;
      _applying.add(e.key);
      try {
        done = await _applyOne(host, e.key, e.value);
      } catch (_) {
        waiting = true;
        continue;
      } finally {
        _applying.remove(e.key);
      }
      if (done) {
        _applied[e.key] = e.value.mark;
        changed = true;
      } else {
        waiting = true;
      }
    }
    if (changed) _save();
    _retry?.cancel();
    if (waiting) _retry = Timer(const Duration(minutes: 1), () => unawaited(applyPending()));
  }

  /// True where [line] is applied here (or never can be); false to try again later.
  static Future<bool> _applyOne(PluginSyncHost host, String id, SyncedPlugin line) async {
    final here = host.here(id);
    final packId = packIdOf(id);
    if (line.on) {
      if (here == null) {
        if (packId == null) return false; // a network not started yet, or a plugin of a newer build: later
        return await host.fetch(packId, line.version) != PackFetch.later;
      }
      if (!here.on) await host.turn(id, true);
      return true;
    }
    if (here == null || !here.on) return true;
    // A session is this device's: sync never signs one out.
    if (here.network && here.signedIn) return true;
    await host.turn(id, false);
    return true;
  }

  /// Whether a Marketplace listing at [listed] may be added for a line that synced [synced]: as new or newer (an older
  /// listing is a catalog not read again yet; the version the person had is waited for).
  static bool listingWillDo(String listed, String? synced) => synced == null || compareVersions(listed, synced) >= 0;

  // A pack waiting for its listing may have one now.
  void _marketChanged() {
    if (_list.entries.any((e) => _applied[e.key] != e.value.mark)) unawaited(applyPending());
  }

  /// The app came back to the front: syncs, at most once a minute.
  void _front() {
    final now = DateTime.now();
    if (_lastFront != null && now.difference(_lastFront!) < const Duration(minutes: 1)) return;
    _lastFront = now;
    unawaited(sync());
  }
}

/// Tells [PluginSync] when the app is resumed.
class _Front with WidgetsBindingObserver {
  _Front(this.sync);
  final PluginSync sync;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync._front();
  }
}

/// The app's plugin sync host: the account blob through Me, the plugins through the registry, Inbox and the Marketplace.
class AppPluginSyncHost implements PluginSyncHost {
  AppPluginSyncHost(this.app);
  final AppState app;

  PluginRegistry get _registry => PluginRegistry.instance;
  AppStore get _store => AppStore(app);

  // Packs whose listing failed to add this run: not tried again until the app starts again.
  final Set<String> _tried = {};

  @override
  Future<bool> ready() async => Me.instance.reachable && await Me.instance.curlReady();

  @override
  Future<Map<String, Object?>?> kept() => Me.instance.curlKept(strict: true);

  @override
  Future<void> keep(Map<String, Object?> whole) => Me.instance.curlKeep(whole);

  @override
  String get account => app.choice('acct_address', '');

  GhostPlugin? _plugin(String id) => _registry.plugins.where((p) => p.id == id).firstOrNull;

  @override
  PluginHere? here(String id) {
    final p = _plugin(id);
    if (p == null) return null;
    if (p is NetworkPlugin) {
      final n = p.connection;
      // Not started yet (nothing to keep its switch in), or not offered in this build: nothing to switch yet.
      if (n == null || n.soon || n.listStore == null) return null;
      return PluginHere(on: n.enabled, network: true, signedIn: n.state == InboxState.ready || n.state == InboxState.signingIn);
    }
    if (p is PackPlugin) {
      // A development copy of a pack is this device's own: the synced line is for the Marketplace's, so left alone.
      if (p.source != PluginSource.reviewed) return const PluginHere(on: false);
      return PluginHere(on: _registry.isOn(p, _store), version: p.pack.version);
    }
    return PluginHere(on: _registry.isOn(p, _store));
  }

  @override
  Future<void> turn(String id, bool on) async {
    final p = _plugin(id);
    if (p == null) return;
    if (p is NetworkPlugin) return p.turn(on);
    _registry.setOn(p, _store, on);
  }

  @override
  Future<PackFetch> fetch(String packId, String? version) async {
    final installed = InstalledPlugins.instance;
    if (!installed.storeAllowed) return PackFetch.never;
    // Installed but not running (paused, stuck, waiting on a newer app): it is this device's copy; nothing to fetch.
    if (installed.storeOf(packId) != null) return PackFetch.never;
    final market = MarketState.instance;
    final l = market.listings.where((l) => l.pack.id == packId).firstOrNull;
    if (l == null) {
      // Withdrawn from the Marketplace: never coming.
      if (market.catalog != null && !market.catalog!.plugins.any((e) => e.id == packId)) return PackFetch.never;
      unawaited(market.refresh());
      return PackFetch.later;
    }
    if (l.needsNewerApp || !PluginSync.listingWillDo(l.pack.version, version)) return PackFetch.later;
    if (_tried.contains(l.entry.sha256)) return PackFetch.later;
    final out = await market.install(l);
    if (out.ok) return PackFetch.done;
    _tried.add(l.entry.sha256);
    return switch (out.code) { 'revoked' || 'not_here' || 'developer_changed' || 'id_installed' => PackFetch.never, _ => PackFetch.later };
  }

  @override
  Map<String, ({bool on, String? version})> chosen() {
    final out = <String, ({bool on, String? version})>{};
    for (final p in _registry.plugins) {
      if (p is NetworkPlugin) {
        final n = p.connection;
        if (n != null && !n.soon && n.enabled) out[p.id] = (on: true, version: null);
      } else if (p is PackPlugin) {
        if (p.source == PluginSource.reviewed) out[p.id] = (on: _registry.isOn(p, _store), version: p.pack.version);
      } else if (_store.read(PluginRegistry.switchKey(p)) != null) {
        out[p.id] = (on: _registry.isOn(p, _store), version: null);
      }
    }
    return out;
  }

  @override
  String read(String key) => app.choice(key, '');

  // `keep`, not `set`: bookkeeping no screen draws from. The switch itself is drawn, so it goes through `set`.
  @override
  void write(String key, String value) => key == PluginSync.onKey ? app.set(key, value) : app.keep(key, value);

  @override
  int now() => DateTime.now().millisecondsSinceEpoch;
}
