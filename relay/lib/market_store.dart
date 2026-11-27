import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// What the Marketplace keeps (market.dart), under `<data>/market` (on the box, /var/lib/ghost-relay/market):
///
///     state.json         every record below, saved after each change
///     state.json.bak     the copy before the last save
///     packages/<sha256>  a package's canonical bytes; written as <sha256>.part, then renamed; never changed
///     shots/<sha256>     a screenshot's bytes, the same way
///     audit.jsonl        a line for each thing done: when, by whom, what, which plugin and submission
///
/// Saved after every change, not on the hub's ten-minute sweep, since deploys restart the relay often; and without
/// holding up the hub, as invites.dart saves: the words are made on another isolate, changes within a second are
/// written as one, and one chain of futures writes them in turn, each the state as it stands when it runs. Blob names
/// come only from SHA-256s the relay worked out itself. Nothing records which address read what.
class MarketStore {
  MarketStore(this.dir, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Directory dir;
  final DateTime Function() _now;

  /// Plugins by their pack id. [developers] is by the hub id of each one's key, [reports] by report id.
  final Map<String, MarketPlugin> plugins = {};

  /// In the order they were sent: a plugin's earlier submissions come before its later ones.
  final Map<String, MarketSubmission> submissions = {};
  final Map<String, MarketDeveloper> developers = {};
  final Map<String, MarketReport> reports = {};

  /// Reports of people and messages (GMFB-40), each sealed in the app to the review keys, in the order they came: the
  /// relay keeps what it can't read.
  final Map<String, MarketAbuse> abuse = {};

  /// PackRevocation and PackRetirement maps, as review signed them, oldest first.
  final List<Map<String, Object?>> revoked = [];
  final List<Map<String, Object?>> retired = [];

  /// When the catalog last changed, its `at`.
  int listingAt = 0;

  /// Each plugin id's owner as audit.jsonl tells it: the first `submit` of the id, until a `release`. Read at every
  /// start, so a state that couldn't be read and was started empty can't hand an id to whoever submits it first.
  final Map<String, String> auditOwners = {};

  /// The blobs on disk ('packages/<sha256>', 'shots/<sha256>') and their sizes, counted from the folders at start.
  final Map<String, int> blobs = {};
  int bytesInAll = 0;

  File get _state => File('${dir.path}/state.json');
  File get _bak => File('${dir.path}/state.json.bak');
  File get _tmp => File('${dir.path}/state.json.tmp');
  File get _audit => File('${dir.path}/audit.jsonl');
  File _blob(String name) => File('${dir.path}/$name');

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  // --- starting -------------------------------------------------------------------------------------------------------

  /// Reads state.json, or state.json.bak where it doesn't parse; where neither does, both are renamed
  /// `*.broken-<ms>`, a line goes to stderr and the market starts empty, never writing over a file it could not read.
  /// Then the owners from audit.jsonl, and the blobs on disk.
  Future<void> load() async {
    await dir.create(recursive: true);
    final stamp = _now().millisecondsSinceEpoch;
    _Parsed? got;
    if (_state.existsSync()) {
      got = _parse(_state);
      if (got == null) {
        final bak = _bak.existsSync() ? _parse(_bak) : null;
        _state.renameSync('${_state.path}.broken-$stamp');
        if (bak != null) {
          got = bak;
          stderr.writeln('market: state.json could not be read; kept as state.json.broken-$stamp, and started from state.json.bak');
        } else {
          if (_bak.existsSync()) _bak.renameSync('${_bak.path}.broken-$stamp');
          stderr.writeln('market: neither state.json nor state.json.bak could be read; kept as *.broken-$stamp, and started empty');
        }
      }
    } else if (_bak.existsSync()) {
      // Stopped between a save's two renames: the copy before it is the newest whole one.
      got = _parse(_bak);
      if (got == null) {
        _bak.renameSync('${_bak.path}.broken-$stamp');
        stderr.writeln('market: state.json.bak could not be read; kept as state.json.bak.broken-$stamp, and started empty');
      }
    }
    if (got != null) {
      plugins.addAll(got.plugins);
      submissions.addAll(got.submissions);
      developers.addAll(got.developers);
      reports.addAll(got.reports);
      abuse.addAll(got.abuse);
      revoked.addAll(got.revoked);
      retired.addAll(got.retired);
      listingAt = got.listingAt;
    }
    await _readAudit();
    _countBlobs();
  }

  /// Everything in [f], or null where any of it isn't of the shape toJson writes: a file is read whole or not at all.
  _Parsed? _parse(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map || j['v'] != 1) return null;
      Map<String, T> each<T>(String key, T Function(Map j) read) => {for (final e in (j[key] as Map).entries) e.key as String: read(e.value as Map)};
      List<Map<String, Object?>> maps(String key) => [for (final e in j[key] as List) (e as Map).cast<String, Object?>()];
      return _Parsed(
        plugins: each('plugins', MarketPlugin.fromJson),
        submissions: each('submissions', MarketSubmission.fromJson),
        developers: each('developers', MarketDeveloper.fromJson),
        reports: each('reports', MarketReport.fromJson),
        // Missing from a state.json written before GMFB-40: none yet, never an unreadable file.
        abuse: j['abuse'] == null ? {} : each('abuse', MarketAbuse.fromJson),
        revoked: maps('revoked'),
        retired: maps('retired'),
        listingAt: j['listingAt'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fills [auditOwners] from audit.jsonl, passing over any line that doesn't read.
  Future<void> _readAudit() async {
    if (!_audit.existsSync()) return;
    try {
      await for (final line in _audit.openRead().transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
        Object? j;
        try {
          j = jsonDecode(line);
        } catch (_) {
          continue;
        }
        if (j is! Map) continue;
        final plugin = j['plugin'], by = j['by'];
        if (plugin is! String || by is! String) continue;
        if (j['what'] == 'submit') auditOwners.putIfAbsent(plugin, () => by);
        if (j['what'] == 'release') auditOwners.remove(plugin);
      }
    } catch (e) {
      stderr.writeln('market: audit.jsonl could not be read: $e');
    }
  }

  /// Fills [blobs] and [bytesInAll] from the two folders, deleting any `.part` left from a write that never finished.
  void _countBlobs() {
    for (final kind in ['packages', 'shots']) {
      final d = Directory('${dir.path}/$kind');
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name.endsWith('.part')) {
          // A write the relay stopped in the middle of: never renamed, so nothing names it.
          try {
            e.deleteSync();
          } catch (_) {}
        } else if (_hex64.hasMatch(name)) {
          final size = e.lengthSync();
          blobs['$kind/$name'] = size;
          bytesInAll += size;
        }
      }
    }
  }

  // --- saving ---------------------------------------------------------------------------------------------------------

  // [_soon]: the second's wait before a save. [_saving]: the chain the saves run in, one after another. [_queued]:
  // the number of the newest save asked for, so an older one still waiting is skipped. [_auditing]: the chain the
  // audit's lines are appended in.
  Timer? _soon;
  Future<void> _saving = Future.value();
  int _queued = 0;
  bool _closed = false;
  Future<void> _auditing = Future.value();

  /// close() has made its last write ([_lastWritten]) and written every audit line asked for before it
  /// ([_auditNow]): a change or a line after that, from a request that finished as the relay stopped, is written at
  /// once, since nothing would write it after. It was answered and lost (review, 2026-11-20).
  bool _lastWritten = false, _auditNow = false;

  /// Something changed: saved within a second, with whatever else changes meanwhile; once closed, at once.
  void changed() {
    if (_closed) {
      if (_lastWritten) _writeNow();
      return;
    }
    _soon ??= Timer(const Duration(seconds: 1), () {
      _soon = null;
      _queue();
    });
  }

  /// Saved now, through the same chain, every save queued behind it done, and the audit's lines written: for the tests.
  Future<void> flush() async {
    _soon?.cancel();
    _soon = null;
    _queue();
    while (true) {
      final s = _saving, a = _auditing;
      await s;
      await a;
      if (identical(s, _saving) && identical(a, _auditing)) return;
    }
  }

  /// Puts a save at the end of the chain.
  void _queue() {
    if (_closed) return;
    final mine = ++_queued;
    _saving = _saving.then((_) async {
      // A save queued behind this one writes everything this one would have.
      if (mine != _queued || _closed) return;
      try {
        await _write();
      } catch (e) {
        stderr.writeln('market: state.json could not be written: $e');
      }
    });
  }

  /// One save: the state written beside, the file there before kept as state.json.bak, then the new one renamed in.
  Future<void> _write() async {
    final words = await _wordsOf(toJson());
    // stop() writes the newest itself, once this is done.
    if (_closed) return;
    await _tmp.writeAsString(words, flush: true);
    if (await _state.exists()) await _state.rename(_bak.path);
    await _tmp.rename(_state.path);
  }

  /// [state] in words, made on another isolate. Static, so all the isolate is sent is the copy, never the store.
  static Future<String> _wordsOf(Map<String, Object?> state) => Isolate.run(() => jsonEncode(state));

  /// Saves synchronously, after any save under way, so this one is the last; and the audit's lines with it. Anything
  /// changed after is written as it is changed ([changed], [audit]).
  Future<void> close() async {
    _closed = true;
    _soon?.cancel();
    _soon = null;
    await _saving;
    _writeNow();
    _lastWritten = true;
    while (true) {
      final a = _auditing;
      await a;
      if (identical(a, _auditing)) break;
    }
    _auditNow = true;
  }

  /// The same save, synchronously and on this isolate: for when the relay is stopping and nothing may be left to later.
  void _writeNow() {
    try {
      dir.createSync(recursive: true);
      _tmp.writeAsStringSync(jsonEncode(toJson()), flush: true);
      if (_state.existsSync()) _state.renameSync(_bak.path);
      _tmp.renameSync(_state.path);
    } catch (e) {
      stderr.writeln('market: state.json could not be written: $e');
    }
  }

  /// state.json's whole content, as a copy that shares nothing with the store, so another isolate can be sent it.
  Map<String, Object?> toJson() => {
        'v': 1,
        'plugins': {for (final e in plugins.entries) e.key: e.value.toJson()},
        'submissions': {for (final e in submissions.entries) e.key: e.value.toJson()},
        'developers': {for (final e in developers.entries) e.key: e.value.toJson()},
        'reports': {for (final e in reports.entries) e.key: e.value.toJson()},
        'abuse': {for (final e in abuse.entries) e.key: e.value.toJson()},
        'revoked': [for (final r in revoked) Map<String, Object?>.of(r)],
        'retired': [for (final r in retired) Map<String, Object?>.of(r)],
        'listingAt': listingAt,
      };

  /// A line in audit.jsonl, appended with flush, in the order they are made: `{at, by, what, plugin?, sid?, note?}`.
  void audit(String by, String what, {String? plugin, String? sid, String? note}) {
    final line = '${jsonEncode({'at': _now().millisecondsSinceEpoch, 'by': by, 'what': what, 'plugin': ?plugin, 'sid': ?sid, 'note': ?note})}\n';
    if (_auditNow) {
      try {
        dir.createSync(recursive: true);
        _audit.writeAsStringSync(line, mode: FileMode.append, flush: true);
      } catch (e) {
        stderr.writeln('market: audit.jsonl could not be written: $e');
      }
      return;
    }
    _auditing = _auditing.then((_) async {
      try {
        await dir.create(recursive: true);
        await _audit.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (e) {
        stderr.writeln('market: audit.jsonl could not be written: $e');
      }
    });
  }

  // --- blobs ----------------------------------------------------------------------------------------------------------

  /// Whether `<kind>/<sha>` is on disk.
  bool has(String kind, String sha) => blobs.containsKey('$kind/$sha');

  /// Writes [bytes] as `<kind>/<sha>` (`packages` or `shots`) where it isn't there already: `<sha>.part`, then renamed.
  Future<void> writeBlob(String kind, String sha, List<int> bytes) async {
    final name = '$kind/$sha';
    if (blobs.containsKey(name)) return;
    final f = _blob(name);
    await f.parent.create(recursive: true);
    final part = File('${f.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(f.path);
    blobs[name] = bytes.length;
    bytesInAll += bytes.length;
  }

  /// The bytes of `<kind>/<sha>`, or null where it isn't here or can't be read.
  Future<Uint8List?> readBlob(String kind, String sha) async {
    if (!blobs.containsKey('$kind/$sha')) return null;
    try {
      return await _blob('$kind/$sha').readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// Deletes `<kind>/<sha>` where it is there, its bytes no longer counted: what a submission refused after its writes
  /// had written (market.dart).
  Future<void> deleteBlob(String kind, String sha) => _deleteBlob('$kind/$sha');

  Future<void> _deleteBlob(String name) async {
    final size = blobs.remove(name);
    if (size == null) return;
    bytesInAll -= size;
    try {
      await _blob(name).delete();
    } catch (_) {}
  }

  // --- the daily sweep ------------------------------------------------------------------------------------------------

  /// Deletes the package and screenshots of every rejected, withdrawn and superseded submission closed over 30 days
  /// ago, where no approved version and no other kept submission (a screenshot kept from it) uses them, and marks it
  /// swept, keeping its record and notes; then lets go of every plugin id with no approved version whose 30 days since
  /// its last open submission have passed. What it swept and released, for the audit.
  Future<({List<MarketSubmission> swept, List<String> released, int orphaned})> sweep(DateTime now) async {
    final at = now.millisecondsSinceEpoch;
    final old = at - const Duration(days: 30).inMilliseconds;
    final going = [
      for (final s in submissions.values)
        if (!s.swept && (s.status == 'rejected' || s.status == 'withdrawn' || s.status == 'superseded') && s.updatedAt < old) s,
    ];
    final goingIds = {for (final s in going) s.sid};
    final used = <String>{
      for (final p in plugins.values)
        for (final v in p.versions) 'packages/${v.sha256}',
    };
    for (final s in submissions.values) {
      if (s.swept || goingIds.contains(s.sid)) continue;
      used.add('packages/${s.sha256}');
      for (final x in s.shots) {
        used.add('shots/${x.sha256}');
      }
    }
    for (final s in going) {
      for (final name in ['packages/${s.sha256}', for (final x in s.shots) 'shots/${x.sha256}']) {
        if (!used.contains(name)) await _deleteBlob(name);
      }
      s.swept = true;
    }
    // And what nothing names at all: a submission's files written as the relay stopped or crashed, before its record
    // was, counted against the room for good (review, 2026-11-20). In route 8's chain, so no submission is between its
    // writes and its record now.
    final orphans = [for (final name in blobs.keys) if (!used.contains(name)) name];
    for (final name in orphans) {
      await _deleteBlob(name);
    }
    final released = [
      for (final p in plugins.values)
        if (p.versions.isEmpty && p.openUntil != null && p.openUntil! <= at && !submissions.values.any((s) => s.plugin == p.id && openStates.contains(s.status))) p.id,
    ];
    for (final id in released) {
      plugins.remove(id);
      auditOwners.remove(id);
    }
    return (swept: going, released: released, orphaned: orphans.length);
  }
}

/// What one state file held, read whole before any of it is taken into the store.
class _Parsed {
  _Parsed({required this.plugins, required this.submissions, required this.developers, required this.reports, required this.abuse, required this.revoked, required this.retired, required this.listingAt});
  final Map<String, MarketPlugin> plugins;
  final Map<String, MarketSubmission> submissions;
  final Map<String, MarketDeveloper> developers;
  final Map<String, MarketReport> reports;
  final Map<String, MarketAbuse> abuse;
  final List<Map<String, Object?>> revoked, retired;
  final int listingAt;
}

/// A submission waiting for or in review: a new one of the same plugin replaces it.
const Set<String> openStates = {'submitted', 'in_review', 'changes_requested'};

/// Decided, one way or another.
const Set<String> closedStates = {'approved', 'rejected', 'withdrawn', 'superseded'};

// Reading a record back: anything not of its shape makes the whole file unreadable, which load() answers by trying the
// copy before it.
// By what they read: _s text, _i a whole number, _b true or false, _m an object, _l a list; with n, null is let be.
String _s(Map j, String k) => j[k] is String ? j[k] as String : throw FormatException('$k is not text');
String? _sn(Map j, String k) => j[k] == null ? null : _s(j, k);
int _i(Map j, String k) => j[k] is int ? j[k] as int : throw FormatException('$k is not a number');
int? _in(Map j, String k) => j[k] == null ? null : _i(j, k);
bool _b(Map j, String k) => j[k] is bool ? j[k] as bool : throw FormatException('$k is not true or false');
Map<String, Object?> _m(Map j, String k) => j[k] is Map ? (j[k] as Map).cast<String, Object?>() : throw FormatException('$k is not an object');
Map<String, Object?>? _mn(Map j, String k) => j[k] == null ? null : _m(j, k);
List<Object?> _l(Map j, String k) => j[k] is List ? j[k] as List : throw FormatException('$k is not a list');

/// A plugin by its pack id: who owns it (the hub id of the key that first sent it), its listing and its approved versions.
class MarketPlugin {
  MarketPlugin({required this.id, required this.owner, required this.developer, this.listing = 'none', this.by, this.note, this.noteAt, this.current, List<MarketVersion>? versions, required this.createdAt, required this.updatedAt, this.listedAt, this.openUntil}) : versions = versions ?? [];
  final String id;
  final String owner;

  /// The username it was first sent under: no other key may send plugins under it.
  final String developer;

  /// 'none' until its first approval, then 'listed' or 'unlisted'; [by] says who last unlisted it, 'owner' or 'admin'.
  String listing;
  String? by;

  /// The last note from review's listing or block, for its developer.
  String? note;
  int? noteAt;

  /// The approved version the catalog lists.
  MarketCurrent? current;

  /// Every version ever approved, oldest first, the current one among them.
  final List<MarketVersion> versions;
  final int createdAt;
  int updatedAt;

  /// When it last went from not listed to listed (ms): the catalog's `listedAt`.
  int? listedAt;

  /// With no approved version, when the id is let go: 30 days after its last open submission closed.
  int? openUntil;

  Map<String, Object?> toJson() => {
        'id': id,
        'owner': owner,
        'developer': developer,
        'listing': listing,
        'by': by,
        'note': note,
        'noteAt': noteAt,
        'current': current?.toJson(),
        'versions': [for (final v in versions) v.toJson()],
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'listedAt': listedAt,
        'openUntil': openUntil,
      };

  factory MarketPlugin.fromJson(Map j) => MarketPlugin(
        id: _s(j, 'id'),
        owner: _s(j, 'owner'),
        developer: _s(j, 'developer'),
        listing: _s(j, 'listing'),
        by: _sn(j, 'by'),
        note: _sn(j, 'note'),
        noteAt: _in(j, 'noteAt'),
        current: j['current'] == null ? null : MarketCurrent.fromJson(_m(j, 'current')),
        versions: [for (final v in _l(j, 'versions')) MarketVersion.fromJson(v as Map)],
        createdAt: _i(j, 'createdAt'),
        updatedAt: _i(j, 'updatedAt'),
        listedAt: _in(j, 'listedAt'),
        openUntil: _in(j, 'openUntil'),
      );
}

/// A plugin's current approved version, with the approval the catalog hands on.
class MarketCurrent {
  MarketCurrent({required this.version, required this.sha256, required this.size, required this.sid, required this.approval, required this.approvedAt});
  final String version, sha256, sid;
  final int size, approvedAt;

  /// The PackApproval as the reviewer signed it: {v, plugin, version, sha256, key, sig, at}.
  final Map<String, Object?> approval;

  Map<String, Object?> toJson() => {'version': version, 'sha256': sha256, 'size': size, 'sid': sid, 'approval': Map<String, Object?>.of(approval), 'approvedAt': approvedAt};

  factory MarketCurrent.fromJson(Map j) => MarketCurrent(version: _s(j, 'version'), sha256: _s(j, 'sha256'), size: _i(j, 'size'), sid: _s(j, 'sid'), approval: _m(j, 'approval'), approvedAt: _i(j, 'approvedAt'));
}

/// One approved version, current or not: its package stays downloadable unless it is withdrawn. [key] is the review key
/// that approved it, so that key's retirement is taken (route 22 takes one only for a key the market has heard from).
class MarketVersion {
  MarketVersion({required this.version, required this.sha256, required this.size, required this.sid, required this.approvedAt, this.key});
  final String version, sha256, sid;
  final int size, approvedAt;
  final String? key;

  Map<String, Object?> toJson() => {'version': version, 'sha256': sha256, 'size': size, 'sid': sid, 'approvedAt': approvedAt, 'key': ?key};

  factory MarketVersion.fromJson(Map j) => MarketVersion(version: _s(j, 'version'), sha256: _s(j, 'sha256'), size: _i(j, 'size'), sid: _s(j, 'sid'), approvedAt: _i(j, 'approvedAt'), key: _sn(j, 'key'));
}

/// One version of one plugin sent for review, with its screenshots and notes.
class MarketSubmission {
  MarketSubmission({required this.sid, required this.plugin, required this.version, required this.sha256, required this.size, required this.owner, this.address, this.status = 'submitted', this.list = 'now', required this.submittedAt, required this.updatedAt, required this.manifest, required this.shots, List<MarketNote>? notes, this.revoked, this.swept = false}) : notes = notes ?? [];
  final String sid, plugin, version, sha256, owner;
  final int size;

  /// The address it came from, kept only while it is open, for the per-address counts.
  String? address;

  /// One of [openStates] or [closedStates].
  String status;

  /// 'now', or 'later': approved, it waits for its developer to list it.
  final String list;
  final int submittedAt;
  int updatedAt;

  /// The pack's top level, the developer's own words back to them: name, tagline, description, symbol, hue, shelf,
  /// labels, permissions, links, developer, support, whatsNew, minApp.
  final Map<String, Object?> manifest;
  final List<MarketShot> shots;

  /// Oldest first, at most [notesKept]; the developer's notes for the reviewer are the first.
  final List<MarketNote> notes;

  /// {at, why}, where review withdrew this approved version.
  Map<String, Object?>? revoked;

  /// Its package and screenshots deleted by the daily sweep; its record and notes kept.
  bool swept;

  static const notesKept = 50;

  bool get open => openStates.contains(status);

  /// A note, the oldest after the developer's own going first once there are [notesKept].
  void note(MarketNote n) {
    notes.add(n);
    while (notes.length > notesKept) {
      notes.removeAt(notes.first.by == 'developer' && notes.first.status == null ? 1 : 0);
    }
  }

  Map<String, Object?> toJson() => {
        'sid': sid,
        'plugin': plugin,
        'version': version,
        'sha256': sha256,
        'size': size,
        'owner': owner,
        'address': address,
        'status': status,
        'list': list,
        'submittedAt': submittedAt,
        'updatedAt': updatedAt,
        'manifest': Map<String, Object?>.of(manifest),
        'shots': [for (final s in shots) s.toJson()],
        'notes': [for (final n in notes) n.toJson()],
        'revoked': revoked == null ? null : Map<String, Object?>.of(revoked!),
        'swept': swept,
      };

  factory MarketSubmission.fromJson(Map j) => MarketSubmission(
        sid: _s(j, 'sid'),
        plugin: _s(j, 'plugin'),
        version: _s(j, 'version'),
        sha256: _s(j, 'sha256'),
        size: _i(j, 'size'),
        owner: _s(j, 'owner'),
        address: _sn(j, 'address'),
        status: _s(j, 'status'),
        list: _s(j, 'list'),
        submittedAt: _i(j, 'submittedAt'),
        updatedAt: _i(j, 'updatedAt'),
        manifest: _m(j, 'manifest'),
        shots: [for (final s in _l(j, 'shots')) MarketShot.fromJson(s as Map)],
        notes: [for (final n in _l(j, 'notes')) MarketNote.fromJson(n as Map)],
        revoked: _mn(j, 'revoked'),
        swept: _b(j, 'swept'),
      );
}

/// One screenshot of a submission: its file is `shots/<sha256>`.
class MarketShot {
  MarketShot({required this.sha256, required this.mime, required this.size});
  final String sha256, mime;
  final int size;

  Map<String, Object?> toJson() => {'sha256': sha256, 'mime': mime, 'size': size};

  factory MarketShot.fromJson(Map j) => MarketShot(sha256: _s(j, 'sha256'), mime: _s(j, 'mime'), size: _i(j, 'size'));
}

/// What happened to a submission, by its developer or review: the decision's note, or "Withdrawn.", or "Replaced by
/// <version>.", and the status it set (null for the developer's own notes for the reviewer).
class MarketNote {
  MarketNote({required this.at, required this.by, required this.text, this.status});
  final int at;
  final String by, text;
  final String? status;

  Map<String, Object?> toJson() => {'at': at, 'by': by, 'text': text, 'status': status};

  factory MarketNote.fromJson(Map j) => MarketNote(at: _i(j, 'at'), by: _s(j, 'by'), text: _s(j, 'text'), status: _sn(j, 'status'));
}

/// Whoever has sent plugins, by the hub id of their key.
class MarketDeveloper {
  MarketDeveloper({required this.id, this.username, this.blocked = false, this.blockedNote, required this.firstAt, this.submissions = 0, this.bytes = 0});
  final String id;

  /// The username their latest submission was sent under.
  String? username;
  bool blocked;
  String? blockedNote;
  final int firstAt;
  int submissions;

  /// What their kept submissions hold on disk, packages and screenshots, each counted once.
  int bytes;

  Map<String, Object?> toJson() => {'id': id, 'username': username, 'blocked': blocked, 'blockedNote': blockedNote, 'firstAt': firstAt, 'submissions': submissions, 'bytes': bytes};

  factory MarketDeveloper.fromJson(Map j) => MarketDeveloper(id: _s(j, 'id'), username: _sn(j, 'username'), blocked: _b(j, 'blocked'), blockedNote: _sn(j, 'blockedNote'), firstAt: _i(j, 'firstAt'), submissions: _i(j, 'submissions'), bytes: _i(j, 'bytes'));
}

/// A report of a plugin, from someone who has it. Who sent it isn't kept: the username they chose to send, and nothing
/// else of theirs (review, 2026-11-20).
class MarketReport {
  MarketReport({required this.rid, required this.plugin, required this.version, required this.reason, required this.text, this.username, this.verified = false, required this.at, this.done = false, this.doneAt});
  final String rid, plugin, version, reason, text;

  /// The username they chose to send with it, and whether their key holds it.
  final String? username;
  final bool verified;
  final int at;
  bool done;
  int? doneAt;

  Map<String, Object?> toJson() => {'rid': rid, 'plugin': plugin, 'version': version, 'reason': reason, 'text': text, 'username': username, 'verified': verified, 'at': at, 'done': done, 'doneAt': doneAt};

  factory MarketReport.fromJson(Map j) => MarketReport(
        rid: _s(j, 'rid'),
        plugin: _s(j, 'plugin'),
        version: _s(j, 'version'),
        reason: _s(j, 'reason'),
        text: _s(j, 'text'),
        username: _sn(j, 'username'),
        verified: _b(j, 'verified'),
        at: _i(j, 'at'),
        done: _b(j, 'done'),
        doneAt: _in(j, 'doneAt'),
      );
}

/// A report of a person or a message (GMFB-40, from the Uplink gap review; Matt approved the reporting half): the app's
/// sealed envelope as it came, opened only by a review key's holder (lib/safety/abuse_report.dart). Who sent it isn't
/// kept, as with a plugin's report: the reporter's name and signature are inside, for the reviewer alone.
class MarketAbuse {
  MarketAbuse({required this.rid, required this.sealed, required this.at, this.done = false, this.doneAt});

  /// The report's id, as review names it to mark it dealt with.
  final String rid;

  /// Base64 of the envelope, as the app sent it.
  final String sealed;

  /// When it came (ms), whether review has dealt with it, and when.
  final int at;
  bool done;
  int? doneAt;

  Map<String, Object?> toJson() => {'rid': rid, 'sealed': sealed, 'at': at, 'done': done, 'doneAt': doneAt};

  factory MarketAbuse.fromJson(Map j) => MarketAbuse(rid: _s(j, 'rid'), sealed: _s(j, 'sealed'), at: _i(j, 'at'), done: _b(j, 'done'), doneAt: _in(j, 'doneAt'));
}
