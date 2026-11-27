import 'video_frame.dart';
import '../circles/circles.dart' show Circles, CirclePerm;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:isolate';
import '../aside.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../desktop/store.dart' show DeskStore;
import '../inbox/kept_writer.dart';
import '../me/me.dart';
import '../net/crypto.dart';
import '../net/file_seal.dart';
import '../net/hub_carrier.dart' show NetSigner;
import '../voice/channels.dart';
import '../voice/roles.dart';
import '../voice/hangout.dart' show ChatUploads, OutgoingFile;
import '../voice/voice.dart';
import '../net/file_seal_async.dart';
import 'apple_sha.dart';
import 'drive.dart';
import 'file_kinds.dart';
import 'file_sink.dart';
import 'file_source.dart';
import 'file_stream.dart';
import 'files_api.dart';
import 'files_http.dart';
import 'files_model.dart';

export 'file_kinds.dart';
export 'file_stream.dart' show FileStream, StreamedMedia;
export 'files_api.dart' show FilesError, FilesInfo, FilesPart;
export 'files_model.dart';
export 'file_source.dart' show FileSource, BytesSource;
export 'file_sink.dart' show HeldFiles;

/// A Files space's files on this device (Matt, 2026-11-17: "add full functionality for filesharing in a space when the
/// space is designated a Files Space"): the list each space's log makes, files going up and coming down with their
/// progress, and what is kept between runs.
///
/// - **The list** is the space's log on the relay (relay/lib/files.dart), read from where this device last got to and
///   kept on disk, so the list shows at once and offline. Each entry is opened with the space's files key and read
///   under the space's roles ([RosterRules]): every device reads the same log under the same roster and gets the same
///   list. Someone without the right to rename or remove a file has their entry skipped everywhere.
/// - **Live.** When a device adds to the log it says `{"t": "files", "seq": n}` in the space's chat room, sealed with
///   the space's key; everyone with the space open reads the log again. An older build ignores the word. A device that
///   was away catches up from its last number on opening, and an open space looks again every [poll] besides.
/// - **Going up** ([upload]): one file at a time, sealed in chunks (lib/net/file_seal.dart) a few megabytes a request.
///   The queue is kept on disk, so a file half sent when the app closes picks up where the relay says it got to.
///   On a phone the picked file is first copied into the app's own folder ([FilePlatform.keep]), since Android's
///   permission to read what was picked ends with the app. Once it is all there it is added to the log, and a line is
///   said in the space's chat ("Maya added report.pdf (2.1 MB)") so older builds see something.
/// - **Coming down** ([fetch]): opened chunk by chunk into a file of its own as it comes, so a download cut short goes on
///   from the last whole chunk, then checked against the SHA-256 its description gives.
class FilesStore extends ChangeNotifier implements ChatUploads {
  FilesStore._({
    required Uri? Function() base,
    required NetSigner? Function() signer,
    required String? Function() me,
    required Directory Function() data,
    required Directory Function() cache,
    required VoiceRoute? Function() route,
    required FilesRules Function(VoiceChannel c) rules,
    required Roster? Function(VoiceChannel c) roster,
    required String Function() myName,
    void Function(VoiceChannel c, String words)? announce,
    this.thumbnails = true,
    this.piece = 16,
    this.poll = const Duration(seconds: 45),
    bool? browser,
    FilesHttp Function()? http,
  })  : browser = browser ?? kIsWeb,
        _http = http ?? defaultFilesHttp,
        _base = base,
        _signer = signer,
        _me = me,
        _data = data,
        _cache = cache,
        _route = route,
        _rules = rules,
        _roster = roster,
        _myName = myName,
        _announce = announce;

  /// The app's: the relay the spaces' rooms are on, this install's hub key, the space's roster.
  static FilesStore instance = FilesStore._live();

  factory FilesStore._live() => FilesStore._(
        base: () {
          final r = Voice.instance.route;
          final hub = r is HubVoiceRoute ? r.hub.url : null;
          return hub == null ? null : FilesApi.baseFor(hub);
        },
        signer: () => Voice.instance.signer,
        me: () => Voice.instance.me,
        data: () => Directory('${_appDir().path}/space-files'),
        cache: () => Directory('${_cacheDir().path}/space-files'),
        route: () => Voice.instance.route,
        rules: (c) {
          final room = Voice.instance.hangoutFor(c);
          return room == null ? OwnerRules(_ownerId(c)) : RosterRules(room.roster);
        },
        roster: (c) => Voice.instance.hangoutFor(c)?.roster,
        myName: _myNameOf,
        announce: (c, words) {
          final room = Voice.instance.hangoutFor(c);
          if (room != null && room.opened && room.can(Perm.chat)) room.send(words);
        },
      );

  /// For a test: a store on [base] (a relay of the test's own), signing with [signer], keeping things in [data].
  @visibleForTesting
  factory FilesStore.forTest({
    required Uri? base,
    required NetSigner signer,
    required Directory data,
    Directory? cache,
    VoiceRoute? route,
    FilesRules Function(VoiceChannel c)? rules,
    Roster? Function(VoiceChannel c)? roster,
    String name = 'Tester',
    int piece = 16,
    Duration poll = const Duration(seconds: 45),
    void Function(VoiceChannel c, String words)? announce,
    bool browser = false,
    FilesHttp Function()? http,
  }) =>
      FilesStore._(
        base: () => base,
        signer: () => signer,
        me: () => signer.id,
        data: () => data,
        cache: () => cache ?? Directory('${data.path}/cache'),
        route: () => route,
        rules: rules ?? (c) => roster?.call(c) == null ? OwnerRules(_ownerId(c)) : RosterRules(roster!(c)!),
        roster: roster ?? (_) => null,
        myName: () => name,
        announce: announce,
        thumbnails: false,
        piece: piece,
        poll: poll,
        browser: browser,
        http: http,
      );

  final Uri? Function() _base;
  final NetSigner? Function() _signer;
  final String? Function() _me;
  final Directory Function() _data;
  final Directory Function() _cache;
  final VoiceRoute? Function() _route;
  final FilesRules Function(VoiceChannel c) _rules;
  final Roster? Function(VoiceChannel c) _roster;
  final String Function() _myName;
  final void Function(VoiceChannel c, String words)? _announce;

  /// A page in a browser (docs/OPEN_NETWORK.md, part 6): the same lists, rules, sealing and queue, with the bytes
  /// coming from the file a person picked ([uploadSources]) and going into the tab ([HeldFiles]), and nothing kept: no
  /// list, queue or file on disk (a page has none), so a space's list is read from the relay as it opens and an upload
  /// stops with the tab. A test of the browser's way sets it on a computer.
  final bool browser;

  /// How requests to the relay go (lib/files/files_http.dart).
  final FilesHttp Function() _http;

  /// What came down in a browser, by file id: the address each is held under in the tab ([HeldFiles]).
  final Map<String, String> _held = {};

  /// Small pictures of pictures added (dart:ui): off in a test without an engine.
  final bool thumbnails;

  /// How many chunks go up in one request (16 of 256 KB: 4 MB, under the relay's 8 MB a request).
  final int piece;

  /// How often an open space reads its log again, besides when it is told the log has grown.
  final Duration poll;

  /// What signs this device's writes to [c], and the id they go under: the install's hub key, but for an account's
  /// drive (lib/files/drive.dart, GMFB-37), which every device of the account writes to with the one key the drive's
  /// seed makes, so the relay knows them all as the drive's owner.
  NetSigner? _signerOf(VoiceChannel c) => Drive.signerOf(c) ?? _signer();
  String? _meOf(VoiceChannel c) => Drive.signerOf(c)?.id ?? _me();

  /// [c]'s rules: its roster's, but for an account's drive, which has no room and no roster: every device of the
  /// account is its owner.
  FilesRules _rulesOf(VoiceChannel c) {
    final drive = Drive.signerOf(c);
    return drive == null ? _rules(c) : OwnerRules(drive.id);
  }

  /// The hub id of [c]'s owner, from the owner's public key; null for a space with no owner (one from before roles).
  static String? _ownerId(VoiceChannel c) => c.owner.isEmpty ? null : NetCrypto.idOf(NetCrypto.unhex(c.owner));

  /// Whether a roster checked out for an owner: each is a few signatures to check, and the same rosters come round on
  /// every reading of a log. Known by what its signature covers and the signature itself, never the signature alone
  /// (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"): keyed by the signature's text, a member could
  /// put a changed roster in the log under the real one's signature and have it believed from here unchecked.
  static final Map<String, bool> _believed = {};
  static const _believedMost = 4096;

  /// Only a signature written the one way the app writes it (64 bytes as 128 lower-case hex): NetCrypto.unhex takes
  /// capitals and drops an odd last letter, so one signature could be written many ways, each a roster to check again.
  static final _sigHex = RegExp(r'^[0-9a-f]{128}$');

  static bool _trustedFor(Roster r, String owner) {
    final sig = r.sig;
    if (sig == null || owner.isEmpty || !_sigHex.hasMatch(sig)) return false;
    final key = '$owner:${NetCrypto.hex(NetCrypto.sha256(r.signed))}:$sig';
    final had = _believed.remove(key);
    if (had != null) return _believed[key] = had;
    // The oldest goes, one at a time: emptied all at once, a log of many rosters would have each checked again.
    while (_believed.length >= _believedMost) {
      _believed.remove(_believed.keys.first);
    }
    return _believed[key] = r.trustedFor(owner);
  }

  /// [c]'s roster as this device holds it, where it is signed and believed for [c]'s owner; null for a roster no one has
  /// signed yet (a space's first) or none at all.
  Roster? _trusted(VoiceChannel c) {
    // A drive has no room, so no roster (and asking for one would make a room for it).
    if (Drive.isDrive(c)) return null;
    final r = _roster(c);
    return r != null && _trustedFor(r, c.owner) ? r : null;
  }

  /// What a roster carried in [c]'s log says, where it is believed for [c]'s owner after [previous] (FilesList.read).
  BelievedRoster? _logged(VoiceChannel c, Object? j, BelievedRoster? previous) {
    final r = Roster.fromJson(j);
    if (r == null || !_trustedFor(r, c.owner)) return null;
    final last = previous?.held;
    if (!chained(r, last is Roster ? last : null, _trusted(c))) return null;
    return (version: r.version, rules: RosterRules(r), held: r);
  }

  /// Whether roster [r] (signed and believed for its owner) may follow [last] (the newest believed from the log) when
  /// this device holds [mine].
  ///
  /// An admin's grant has no revision and can't be taken back (lib/voice/roles.dart), so an admin the owner later
  /// demoted can still sign a roster that checks out, naming themselves admin again at any revision (Matt, 2026-11-17:
  /// "Finish the missing pieces that went unfinished"). So the owner's word stands at any revision, and an admin's only
  /// where they are an admin in the roster before it, one revision on: in [last] or [mine] for a roster newer than
  /// this device holds; in [mine] (still an admin today, or the very roster held) for one no newer, since this device
  /// knows better than a roster at that revision someone puts in the log.
  @visibleForTesting
  static bool chained(Roster r, Roster? last, Roster? mine) {
    final by = r.by;
    if (by == null) return false;
    if (by == r.ownerId) return true;
    if (mine != null && r.version <= mine.version) {
      if (r.version == mine.version) return r.sig == mine.sig || listEquals(r.signed, mine.signed);
      return mine.canManage(by);
    }
    bool after(Roster? p) => p != null && r.version <= p.version + 1 && p.canManage(by);
    return after(last) || after(mine);
  }

  /// [r] as the relay checks it (relay/lib/files_roster.dart): the bytes its author signed, and the signature. Sent only
  /// with the delete of someone else's file that needs it.
  static Map<String, Object?> _proof(Roster r) => {'r': base64Encode(r.signed), 's': r.sig};

  /// What an owner's or admin's device tells the relay of [r] as it opens a space (relay/lib/files.dart's `rv`): its
  /// revision, the hash of its signed bytes, who its admins are, and (from an admin) the owner's grant making them one;
  /// signed with the rest of the request. Null where this device doesn't sign rosters.
  ///
  /// Not the roster itself (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"): every member's id and
  /// role, the bans and mutes went to the relay on every open before, tied to the space and its uploaders, while it
  /// needs the whole roster only to judge a moderator's delete, which sends it then.
  Map<String, Object?>? _statement(VoiceChannel c, Roster r) {
    final me = _me();
    if (me == null || !r.canManage(me)) return null;
    final admins = [for (final e in r.assigned.entries) if (e.value == Role.admin) e.key]..sort();
    return {
      'v': r.version,
      'h': NetCrypto.hex(NetCrypto.sha256(r.signed)),
      'ad': admins,
      if (!r.isOwner(me)) 'g': r.adminGrants[me],
    };
  }

  /// The largest roster put in a log (an entry is at most 32 KB sealed on the relay).
  static const _rosterMost = 24 * 1024;

  /// What this person is called beside a file they add: the name a hangout room has for them, else the profile's.
  static String _myNameOf() {
    final v = Voice.instance;
    // What this device's hangout rooms are told it is called.
    for (final c in v.channels) {
      final room = v.hangoutFor(c);
      if (room != null && room.name.isNotEmpty) return room.name;
    }
    final me = Me.instance;
    return me.shownName;
  }

  /// Where the app keeps what must last (the lists, the upload queue): its files folder on Android, the desktop
  /// store's folder elsewhere.
  static Directory _appDir() {
    if (PlatformInfo.isAndroid) return Directory('${Directory.systemTemp.parent.path}/files');
    return DeskStore.defaultDir();
  }

  /// Where files that came down are kept, since they can be brought down again: the app's cache folder on Android and
  /// a Mac, a cache folder inside the desktop store's elsewhere.
  static Directory _cacheDir() {
    if (PlatformInfo.isAndroid) return Directory.systemTemp;
    final home = PlatformInfo.environment['HOME'];
    if (PlatformInfo.isMacOS && home != null) return Directory('$home/Library/Caches/Ghost Messaging');
    return Directory('${DeskStore.defaultDir().path}/cache');
  }

  final Map<String, FilesSpace> _spaces = {};

  /// Files going up and coming down, oldest first.
  final List<Transfer> transfers = [];
  bool _started = false;

  /// The space [c]'s files as this device has them.
  FilesSpace of(VoiceChannel c) => _spaces.putIfAbsent(c.seed, () => FilesSpace._(c, this).._load());

  /// How many files [c] holds, where its list is already held on this device (opened or read once); null where not.
  /// Reads nothing from disk, so a circle's list can show it on every rebuild.
  int? heldCount(VoiceChannel c) {
    final s = _spaces[c.seed];
    return s == null || !s.ready ? null : s.files.length;
  }

  /// For a picture or a test: [files] as [c]'s, with no relay.
  @visibleForTesting
  void put(VoiceChannel c, List<SpaceFile> files, {Set<String> folders = const {}, FilesInfo? info}) {
    final s = of(c);
    var seq = 0;
    s._log = [
      for (final f in files) LoggedOp(seq: ++seq, by: f.by, at: f.at, op: FileOp.add(f)),
      for (final d in folders) LoggedOp(seq: ++seq, by: f0(files)?.by ?? '', at: 0, op: FileOp.folder(d)),
    ];
    s.seq = seq;
    s.info = info;
    s._reread();
    s._kept = true;
    notifyListeners();
  }

  static SpaceFile? f0(List<SpaceFile> files) => files.firstOrNull;

  /// For a test of a browser's page: [f] as come down already, held in the tab under [url] (HeldFiles).
  @visibleForTesting
  void putHeld(SpaceFile f, String url) {
    _held[f.id] = url;
    notifyListeners();
  }

  /// For a picture or a test: a transfer shown as it would be.
  @visibleForTesting
  void putTransfer(Transfer t) {
    transfers.add(t);
    notifyListeners();
  }

  /// For a test: everything forgotten.
  @visibleForTesting
  Future<void> clear() async {
    for (final s in _spaces.values) {
      s._dispose();
    }
    _spaces.clear();
    for (final t in transfers) {
      t._cancel = true;
    }
    transfers.clear();
    _started = false;
    notifyListeners();
  }

  /// Everything of the Files spaces this device keeps deleted (lib/account/account.dart: signed out with everything
  /// deleted, or removed from the account): what was going up stopped, the spaces' lists and the queue, and every
  /// file brought down.
  Future<void> wipe() async {
    await clear();
    if (browser) {
      for (final url in _held.values) {
        HeldFiles.release(url);
      }
      _held.clear();
      return;
    }
    for (final dir in [_data(), _cache()]) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Picks up what was going up when the app last closed.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      // A browser keeps no queue: what it was sending stopped with the tab.
      final f = browser ? null : File('${_data().path}/queue.json');
      if (f != null && f.existsSync()) {
        for (final j in (jsonDecode(await f.readAsString()) as List)) {
          final t = Transfer._fromJson(j);
          if (t != null && !transfers.any((x) => x.id == t.id)) transfers.add(t);
        }
      }
    } catch (_) {}
    if (transfers.isNotEmpty) {
      notifyListeners();
      _pump();
    }
    // The relay coming (or a computer's own hub connecting): what waited for it goes on.
    if (identical(this, instance)) Voice.instance.addListener(_voiceChanged);
  }

  /// Voice changed (the relay came, a roster moved): open spaces listen and read again, and uploads that waited for
  /// the relay go back on the queue.
  void _voiceChanged() {
    if (_base() == null) return;
    _rosterMoved();
    _keepDrive();
    for (final s in _spaces.values.where((s) => s._holds > 0)) {
      s._listen();
      // Voice says something changed many times a minute: an unreachable relay is asked again at most every ten seconds.
      final due = DateTime.now().difference(s._tried) > const Duration(seconds: 10);
      if (s._waiting || (due && s.error != null && s.error!.offline)) unawaited(s.refresh());
    }
    final waiting = transfers.where((t) => t.up && t.state == TransferState.waiting).toList();
    for (final t in waiting) {
      t.state = TransferState.queued;
    }
    if (waiting.isNotEmpty) _pump();
  }

  /// When the account's drive was last looked at this run ([_keepDrive]), and whether that is done with for the run.
  DateTime _driveTried = DateTime.fromMillisecondsSinceEpoch(0);
  bool _driveKept = false;

  /// Looks at the account's drive on the relay once a run, as the relay comes ([touch]): the relay lets a space go that
  /// nobody has opened for ninety days, and nobody else will open this one (GMFB-37). Done with for the run once the
  /// relay has answered for it, or where no account is signed in to here; a relay out of reach, or a drive never made,
  /// is asked again in ten minutes at the soonest.
  void _keepDrive() {
    if (_driveKept || DateTime.now().difference(_driveTried) < const Duration(minutes: 10)) return;
    _driveTried = DateTime.now();
    unawaited(() async {
      final c = await Drive.mine();
      if (c == null || await touch(c)) _driveKept = true;
    }());
  }

  Timer? _notifySoon;

  void _changed() => notifyListeners();

  /// Told at most every 120 ms while a transfer moves.
  void _moved() {
    _notifySoon ??= Timer(const Duration(milliseconds: 120), () {
      _notifySoon = null;
      notifyListeners();
    });
  }

  /// Keeps the uploads still to finish in queue.json, written aside and renamed so it is never half written. A chat's
  /// files are left out: their messages ask again.
  Future<void> _saveQueue() async {
    if (browser) return;
    try {
      final d = _data()..createSync(recursive: true);
      final tmp = File('${d.path}/queue.json.tmp');
      await tmp.writeAsString(jsonEncode([for (final t in transfers) if (t.up && !t.chat && t.state != TransferState.done) t._toJson()]));
      await tmp.rename('${d.path}/queue.json');
    } catch (_) {}
  }

  final Map<String, FilesApi> _apis = {};

  /// The relay's files API for [c]: one kept per space, made again when the relay or the signing key changes. Null
  /// with no relay or key yet.
  FilesApi? _api(VoiceChannel c) {
    final base = _base();
    final signer = _signerOf(c);
    if (base == null || signer == null) return null;
    final room = FileSeal.filesRoom(c.seed);
    final had = _apis[room];
    if (had != null && had.base == base && identical(had.signer, signer)) return had;
    // The one it replaces lets its connections go, rather than keeping them open for as long as the app runs.
    had?.closeIdle();
    return _apis[room] = FilesApi(base: base, space: room, token: FileSeal.filesToken(c.seed), signer: signer, http: _http());
  }

  /// Opens [c] while something shows it: its list read and kept current. [close] when done.
  Future<void> open(VoiceChannel c) async {
    final s = of(c);
    s._holds++;
    s._listen();
    s._poller ??= Timer.periodic(poll, (_) => unawaited(s.refresh()));
    await s.refresh();
  }

  /// Ends one [open] of [c]: when the last one goes, the polling and the listening stop.
  void close(VoiceChannel c) {
    final s = _spaces[c.seed];
    if (s == null || s._holds == 0) return;
    if (--s._holds == 0) {
      s._poller?.cancel();
      s._poller = null;
      s._sub?.cancel();
      s._sub = null;
    }
  }

  /// Looks at [c] on the relay and no more, where it is there: the relay lets a space go that nobody has opened for
  /// ninety days (relay/lib/files.dart), and an account's drive is opened only when its owner thinks of it (GMFB-37).
  /// True where the relay answered for it.
  Future<bool> touch(VoiceChannel c) async {
    try {
      final api = _api(c);
      if (api == null) return false;
      await api.info();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether this device may add files to [c].
  bool canUpload(VoiceChannel c) {
    final me = _meOf(c);
    // In a circle, as its roles say too (lib/circles: CirclePerm.files).
    if (!Circles.instance.allows(c, CirclePerm.files)) return false;
    return me == null || _rulesOf(c).mayAdd(me);
  }

  /// Whether this device may rename, move or remove [f].
  bool canChange(VoiceChannel c, SpaceFile f) {
    final me = _meOf(c);
    return me != null && _rulesOf(c).mayChange(me, f);
  }

  /// Whether this device may make, move and remove folders in [c].
  bool canFolder(VoiceChannel c) {
    final me = _meOf(c);
    return me != null && _rulesOf(c).mayFolder(me);
  }

  // --- the log -----------------------------------------------------------------------------------------------------

  /// Adds [op] to [c]'s log, reads the list again and tells the others. False, with the space's error set, where it
  /// couldn't.
  Future<bool> _write(VoiceChannel c, Map<String, Object?> op) async {
    final api = _api(c);
    final s = of(c);
    if (api == null) {
      s.error = FilesError(0, 'Not connected to the relay yet.');
      notifyListeners();
      return false;
    }
    try {
      await s._ensure(api);
      final seq = await _append(c, api, s, op);
      await s.refresh();
      _ping(c, seq);
      return true;
    } on FilesError catch (e) {
      s.error = e;
      notifyListeners();
      return false;
    }
  }

  /// Adds [op] to [c]'s log, signed ([FileOp.sign]) for its place: right after the last entry this device has read,
  /// naming that entry's bytes, under the roster revision it holds. Where the log has moved on meanwhile (someone else
  /// wrote), it is read again and the entry signed again for its new place. Where this device holds a newer roster
  /// than the log does, the roster goes in first, so every device can judge the entry by the roster it was written
  /// under (FilesList.read). With no [op], only the roster.
  ///
  /// The revision signed is the one the log has once the roster is in (Matt, 2026-11-17: "Finish the missing pieces
  /// that went unfinished"): where the roster couldn't go in (too big for an entry, refused), the entry says the older
  /// revision the log holds, never one no reader can see.
  Future<int> _append(VoiceChannel c, FilesApi api, FilesSpace s, Map<String, Object?>? op) async {
    final signer = _signerOf(c);
    if (signer == null) throw FilesError(0, 'Not connected to the relay yet.');
    final key = FileSeal.filesKey(c.seed), room = FileSeal.filesRoom(c.seed);
    final roster = _trusted(c);
    Future<Uint8List> sealed(Map<String, Object?> o, int rv) async {
      final last = s._log.lastOrNull;
      final ph = last != null && last.seq == s.seq ? last.sh ?? '' : '';
      return FileOp.seal(key, await FileOp.sign(o, space: room, prev: s.seq, prevHash: ph, rv: rv, publicKey: signer.publicKey, sign: signer.sign));
    }

    var wrote = 0;
    for (var tries = 0;; tries++) {
      try {
        if (roster != null && roster.version > s._list.rosterVersion && roster.version != s._rosterRefused) {
          final rj = roster.toJson();
          if (utf8.encode(jsonEncode(rj)).length <= _rosterMost) {
            try {
              wrote = await api.append(await sealed(FileOp.roster(rj), roster.version), after: s.seq);
              await s.refresh();
            } on FilesError catch (e) {
              // Only a log that moved on, or a relay out of reach, is tried again; a roster the relay won't take (too
              // big, the list full) is left out until this device holds a newer one, rather than tried again first
              // on every write, and the entry says the revision the log has.
              if (e.status == HttpStatus.conflict || e.offline || e.status >= 500 && e.status != HttpStatus.insufficientStorage) rethrow;
              s._rosterRefused = roster.version;
            }
          } else {
            s._rosterRefused = roster.version;
          }
        }
        if (op == null) return wrote;
        final rv = math.min(roster?.version ?? 0, s._list.rosterVersion);
        return await api.append(await sealed(op, rv), after: s.seq);
      } on FilesError catch (e) {
        // The relay's list started again (swept after ninety days unused, or the box's data lost) while this device
        // kept its own: what it kept is let go, or every write would be sent after an entry the relay no longer has.
        if (e.status == HttpStatus.conflict && e.seq != null && e.seq! < s.seq) s._startOver();
        // No such space any more (the box's data lost while the app ran): opened again, which reads the new list from
        // its start, and the entry tried again there, once.
        if (e.status == HttpStatus.notFound && tries == 0) {
          s._ensured = false;
          await s.refresh();
          if (s.error != null) throw s.error!;
          continue;
        }
        if (e.status != HttpStatus.conflict || tries >= 16) rethrow;
        // Others writing at the same moment: a short wait of its own length each, so they don't meet again.
        if (tries > 0) await Future<void>.delayed(Duration(milliseconds: math.Random().nextInt(40 * (tries + 1))));
        await s.refresh();
      }
    }
  }

  /// The roster revision each Files space was last looked at under ([_rosterMoved]), by seed.
  final Map<String, int> _rosterSeen = {};

  /// A Files space's roster changed on this device while the app runs, where this device signs rosters (the owner's or
  /// an admin's): the relay and the log hear of it now, not when someone next opens or writes to the space (Matt,
  /// 2026-11-17: "Finish the missing pieces that went unfinished"). Until then a demoted or banned moderator's device
  /// could sign under the roster from before, and its deletes would be judged by that roster for good.
  void _rosterMoved() {
    final v = Voice.instance;
    final me = _me();
    if (me == null || _base() == null) return;
    for (final c in v.channels) {
      if (c.kind != SpaceKind.files) continue;
      // Only a room already made: a roster changes through its room, and none is made here for every space.
      final r = v.heldHangout(c)?.roster;
      if (r == null || r.sig == null) continue;
      final seen = _rosterSeen[c.seed];
      _rosterSeen[c.seed] = math.max(r.version, seen ?? -1);
      // The first look this run only notes it: what a space held at launch reaches the relay when it is opened.
      if (seen == null || r.version <= seen) continue;
      if (!r.canManage(me)) continue;
      unawaited(pushRoster(c));
    }
  }

  /// Tells the relay and [c]'s log of the roster this device holds, where it is newer than what they have.
  @visibleForTesting
  Future<void> pushRoster(VoiceChannel c) async {
    final api = _api(c);
    final roster = _trusted(c);
    if (api == null || roster == null) return;
    final s = of(c);
    try {
      await s.refresh();
      if (s.error != null) return;
      if (roster.version > s._list.rosterVersion) {
        final seq = await _append(c, api, s, null);
        await s.refresh();
        if (seq > 0) _ping(c, seq);
      }
    } on FilesError catch (_) {
      // Tried again on the next write or opening.
    }
  }

  /// Tells everyone with [c] open that its log has [seq] now.
  void _ping(VoiceChannel c, int seq) {
    // A drive has no chat room to say it in: the account's other devices read its list as they open it, and every
    // [poll] while it shows.
    if (Drive.isDrive(c)) return;
    try {
      _route()?.send(c.chatRoom, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'files', 'seq': seq}))));
    } catch (_) {}
  }

  /// Renames [f] for everyone. False where the name is empty or the same, or this device may not change the file.
  Future<bool> rename(VoiceChannel c, SpaceFile f, String name) async {
    final n = SpaceFile.cleanName(name);
    if (n.isEmpty || n == f.name || !canChange(c, f)) return false;
    return _write(c, FileOp.rename(f.id, n));
  }

  /// Moves [f] into [folder] (null for the top) for everyone.
  Future<bool> move(VoiceChannel c, SpaceFile f, String? folder) async {
    final d = SpaceFile.cleanFolder(folder);
    if (d == f.folder || !canChange(c, f)) return false;
    return _write(c, FileOp.move(f.id, d));
  }

  /// Makes the folder [name] in [parent] (null for the top), empty (Matt, 2026-11-18: "allow root level folders in the
  /// file sharing tab and nested folders"). No deeper than [SpaceFile.maxDepth], and not one there already.
  Future<bool> newFolder(VoiceChannel c, String name, {String? parent}) async {
    final top = SpaceFile.cleanFolder(parent);
    final d = SpaceFile.joinFolder(top, name);
    if (d == null || of(c).folders.contains(d)) return false;
    if (SpaceFile.folderNames(top).length + SpaceFile.folderNames(SpaceFile.cleanFolder(name)).length > SpaceFile.maxDepth) return false;
    return _write(c, FileOp.folder(d));
  }

  /// Why the folder [from] can't be moved to [to] (null: emptied into the folder it is in), in words; null where it can.
  /// Every device reads a `mvdir` the same way and lets it through only whole (FilesList.read), so what it would refuse
  /// is refused here first, in words.
  String? whyNotMoveFolder(VoiceChannel c, String from, String? to) {
    final s = of(c);
    if (!canFolder(c)) return 'Your role here can\'t change folders.';
    if (!s.folders.contains(from)) return 'That folder isn\'t here any more.';
    if (to != null && SpaceFile.inFolder(to, from)) return 'A folder can\'t go inside itself.';
    if (to != null && s.folders.contains(to)) return 'There\'s already a folder called ${SpaceFile.folderName(to)} there.';
    final base = SpaceFile.folderNames(to ?? SpaceFile.folderParent(from)).length;
    final from0 = SpaceFile.folderNames(from).length;
    final deepest = [from, ...s._list.foldersUnder(from)].fold(0, (n, p) => math.max(n, SpaceFile.folderNames(p).length - from0));
    if (base + deepest > SpaceFile.maxDepth) return 'Folders go at most ${SpaceFile.maxDepth} deep.';
    if (s._list.filesUnder(from).any((f) => !canChange(c, f))) return 'Some of the files in it are someone else\'s, and only they or someone who manages files can move them.';
    return null;
  }

  /// Moves the folder [from], with all it holds, to [to] (a path; null empties it into the folder it is in). A rename is
  /// a move to another name in the same folder ([renameFolder]).
  Future<bool> moveFolder(VoiceChannel c, String from, String? to) async {
    final d = to == null ? null : SpaceFile.cleanFolder(to);
    if ((to != null && d == null) || d == from || whyNotMoveFolder(c, from, d) != null) return false;
    return _write(c, FileOp.moveFolder(from, d));
  }

  /// Renames the folder at [path] to [name] (one name, no slash), leaving it in the folder it is in.
  Future<bool> renameFolder(VoiceChannel c, String path, String name) async {
    final n = SpaceFile.cleanFolder(name);
    if (n == null || n.contains('/')) return false;
    return moveFolder(c, path, SpaceFile.joinFolder(SpaceFile.folderParent(path), n));
  }

  /// Lets the folder at [path] go. One that holds nothing simply goes; what one holds is either moved up into the
  /// folder it is in ([deleteFiles] false: its files and folders go up a level, kept) or deleted, file by file, for
  /// everyone ([deleteFiles] true) before it goes.
  Future<bool> removeFolder(VoiceChannel c, String path, {bool deleteFiles = false}) async {
    final s = of(c);
    final inside = s._list.filesUnder(path).toList();
    final subs = s._list.foldersUnder(path).toList();
    if (inside.isEmpty && subs.isEmpty) return _write(c, FileOp.unfolder(path));
    if (!deleteFiles) return moveFolder(c, path, null);
    if (inside.any((f) => !canChange(c, f))) return false;
    for (final f in inside) {
      if (!await delete(c, of(c).files[f.id] ?? f)) return false;
    }
    return _write(c, FileOp.unfolder(path));
  }

  /// Removes [f] from the list, and its sealed blob from the relay: whoever added it and the space's owner by who they
  /// are; someone with Manage files above the uploader by showing the relay the space's roster, which it checks the
  /// way every device does (relay/lib/files_roster.dart). Before (Matt, 2026-11-17: "Finish the missing pieces that
  /// went unfinished"), a moderator's delete only took the file off the list, and the blob stayed until the space went
  /// unused. A relay from before rosters still keeps the blob then (it says no, and that is no matter here).
  Future<bool> delete(VoiceChannel c, SpaceFile f) async {
    if (!canChange(c, f)) return false;
    final ok = await _write(c, FileOp.delete(f.id));
    if (!ok) return false;
    final me = _meOf(c);
    final roster = me == f.by || me == _ownerId(c) ? null : _trusted(c);
    if (me == f.by || me == _ownerId(c) || roster != null) {
      try {
        await _api(c)?.deleteBlob(f.id, roster: roster == null ? null : _proof(roster));
      } catch (_) {}
    }
    _forgetCached(f);
    return true;
  }

  // --- unfinished uploads ------------------------------------------------------------------------------------------

  /// Uploads to [c] the relay holds part of that nothing on this device is sending or can pick up (Matt, 2026-11-21:
  /// "I need a way to see partially uploaded files, the oddysey uploaded partially but then disconnected when I
  /// restarted the app it stopped uploading but kept the space reserved"): another device's, one this device's queue
  /// lost (a file sent from a space's chat is never kept on the queue), or one from before an app was reinstalled. Each
  /// holds its room until it is removed or the relay lets it go, a day after its last piece. One this device's queue
  /// still has shows as its transfer instead, which goes on by itself or with Try again.
  List<FilesPart> unfinished(VoiceChannel c) {
    final held = {for (final t in transfers) if (t.blob != null && t.space.seed == c.seed) t.blob};
    return [for (final p in of(c).info?.parts ?? const <FilesPart>[]) if (!held.contains(p.id)) p];
  }

  /// [p] as a file in the list would be, for the space's rules (who may remove it).
  SpaceFile _asFile(FilesPart p) => SpaceFile(id: p.id, name: '', size: p.size, mime: '', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: p.by, byName: '', at: p.at.millisecondsSinceEpoch);

  /// Whether this device may let [p] go: whoever started it, the space's owner, or someone whose role may remove it.
  bool canRemoveUnfinished(VoiceChannel c, FilesPart p) => canChange(c, _asFile(p));

  /// Who started [p], as the space's list names them ("you" for this install), or null where it doesn't.
  String? unfinishedBy(VoiceChannel c, FilesPart p) {
    if (p.by == _meOf(c)) return 'you';
    for (final f in of(c).files.values) {
      if (f.by == p.by && f.byName.isNotEmpty) return f.byName;
    }
    return null;
  }

  /// Lets [p] go on the relay, freeing its room, as [delete] does a file's blob (the roster shown where it isn't this
  /// device's or the owner's). Whether the relay let it go.
  Future<bool> removeUnfinished(VoiceChannel c, FilesPart p) async {
    if (!canRemoveUnfinished(c, p)) return false;
    final api = _api(c);
    if (api == null) return false;
    final me = _meOf(c);
    final roster = me == p.by || me == _ownerId(c) ? null : _trusted(c);
    try {
      await api.deleteBlob(p.id, roster: roster == null ? null : _proof(roster));
    } on FilesError catch (e) {
      // Already gone (finished elsewhere, or let go by the relay meanwhile): what was wanted.
      if (e.status != HttpStatus.notFound) return false;
    } catch (_) {
      return false;
    }
    await of(c).refresh();
    notifyListeners();
    return true;
  }

  // --- going up ------------------------------------------------------------------------------------------------------

  /// Adds files at [paths] (on this device) to [c], in [folder]. [owned] marks copies the app made (a phone's picks),
  /// which go once they are up.
  void upload(VoiceChannel c, List<String> paths, {String? folder, bool owned = false}) {
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final name = SpaceFile.cleanName(p.split(PlatformInfo.pathSeparator).last.split('/').last);
      transfers.add(Transfer._up(
        space: c,
        path: p,
        name: name.isEmpty ? 'File' : name,
        size: f.lengthSync(),
        mime: FileKind.mimeOf(name),
        folder: SpaceFile.cleanFolder(folder),
        owned: owned,
      ));
    }
    notifyListeners();
    unawaited(_saveQueue());
    _pump();
  }

  /// Adds files that are no paths on this device to [c], in [folder]: in a browser, those a person picked or dropped
  /// on the page (lib/files/browser_files.dart). They go up as any upload does, read a piece at a time.
  void uploadSources(VoiceChannel c, List<FileSource> sources, {String? folder}) {
    for (final src in sources) {
      final name = SpaceFile.cleanName(src.name.split('/').last.split(r'\\').last);
      final shown = name.isEmpty ? 'File' : name;
      transfers.add(Transfer._source(
        space: c,
        source: src,
        name: shown,
        size: src.size,
        mime: FileKind.mimeOf(shown),
        folder: SpaceFile.cleanFolder(folder),
      ));
    }
    notifyListeners();
    _pump();
  }

  /// The SHA-256 of what [t] sends, said in hundredths as it reads ([told]): its file's path on another isolate, or its
  /// [FileSource] a piece at a time.
  Future<String> _shaOf(Transfer t, void Function(int read)? told) {
    final src = t.source;
    if (src != null) return shaOfSource(src, told: told);
    return _shaAside(t.path!, told: told);
  }

  bool _pumping = false;

  /// Sends the queued uploads one after another; only one pump runs at a time. Those left waiting for the relay are
  /// queued again after five seconds, then longer each try, up to a minute.
  void _pump() {
    if (_pumping) return;
    _pumping = true;
    unawaited(() async {
      try {
        while (true) {
          // Waiting ones are tried again by the timer below, not at once.
          final t = transfers.where((t) => t.up && t.state == TransferState.queued && !t._cancel).firstOrNull;
          if (t == null) break;
          await _runUpload(t);
        }
      } finally {
        _pumping = false;
      }
      // What waits for the relay is tried again in a while.
      final waiting = transfers.where((t) => t.up && t.state == TransferState.waiting && !t._held).toList();
      if (waiting.isNotEmpty) {
        for (final t in waiting) {
          t._held = true;
        }
        Timer(Duration(seconds: math.min(60, 5 * (1 << math.min(4, waiting.first.tries - 1)))), () {
          for (final t in waiting) {
            t._held = false;
            if (t.state == TransferState.waiting && !t._cancel) t.state = TransferState.queued;
          }
          _pump();
        });
      }
    }());
  }

  /// Sends one upload: hashes the file, seals it piece by piece onto the relay from where the relay says it got to,
  /// then adds it to the space's log (a chat's file goes in no log). Sets [t]'s state as it goes and never throws.
  Future<void> _runUpload(Transfer t) async {
    final c = t.space;
    final api = _api(c);
    if (api == null) {
      t._wait('Waiting for the relay');
      notifyListeners();
      return;
    }
    final src = t.source;
    final file = src == null ? File(t.path!) : null;
    if (file != null && !file.existsSync()) {
      t._fail('The file isn\'t there any more.');
      await _settle(t);
      return;
    }
    t.state = TransferState.running;
    t.error = null;
    notifyListeners();
    final s = of(c);
    try {
      await s._ensure(api);
      // Failures no retry can mend say so (no Try again): a file over the limit, and a space without the room for it.
      // The limit is said per file, so it does not read as the space's own room (the storage bar shows that).
      if (s.info != null && s.info!.maxFile > 0 && FileSeal.sealedSize(t.size) > s.info!.maxFile) {
        t._fail('Too big: files can be up to ${fileSize(s.info!.maxFile)} each.', retryable: false);
        await _settle(t);
        return;
      }
      if (t.blob == null && s.info != null && s.info!.quota > 0 && s.info!.used + FileSeal.sealedSize(t.size) > s.info!.quota) {
        t._fail('Not enough room left in this space.', retryable: false);
        await _settle(t);
        return;
      }
      // The same file as when it was sealed before, or nothing is sent: a chunk sealed again under its nonce must say
      // the same words, or the key would be given away.
      final modified = file == null ? src!.modified : file.lastModifiedSync().millisecondsSinceEpoch;
      if (t.sha != null && (t.modified != modified || (file == null ? src!.size : file.lengthSync()) != t.size)) {
        t._fail('The file changed while it was going up. Add it again.');
        await _settle(t);
        return;
      }
      t.modified = modified;
      if (t.sha == null) {
        t.status = 'Getting it ready';
        notifyListeners();
        final path = t.path;
        // The whole file is read once for its checksum before any of it goes: said in hundredths, so a big one is
        // seen to be moving (in a browser, from 8 MB: it reads more slowly there).
        var said = -1;
        t.sha = await _shaOf(t, t.size < (browser ? 8 << 20 : 64 << 20) ? null : (read) {
          final pct = t.size <= 0 ? 0 : (read * 100 ~/ t.size).clamp(0, 99);
          if (pct == said) return;
          said = pct;
          t.status = 'Getting it ready · $pct%';
          notifyListeners();
        });
        t.fileKey ??= NetCrypto.randomBytes(32);
        t.prefix ??= NetCrypto.randomBytes(8);
        // Its small picture, for everyone's list and grid: a picture's own (a GIF's first frame), or a video's frame from
        // its first minute (lib/files/video_frame.dart; Matt, 2026-11-18: "videos having a frame from the first minute").
        final kind = FileKind.of(t.name, t.mime);
        if (thumbnails && kind == FileKind.image && t.size <= 40 << 20) {
          final made = src != null ? await thumbnailOf(await src.read(0, t.size), most: t.thumbMost) : await thumbnailOfFile(path!, kind, most: t.thumbMost);
          t.thumb = made?.png;
          t.width = made?.width ?? 0;
          t.height = made?.height ?? 0;
        } else if (thumbnails && kind == FileKind.video && path != null) {
          // A video's frame takes a player to open it: made while the file goes up, and waited for only at the end
          // (videoFrame gives up after frameLimit), so the upload never stands waiting on it.
          _videoThumbs[t] = thumbnailOfFile(path, kind, most: t.thumbMost);
        }
        await _saveQueue();
      }
      final sealed = FileSeal.sealedSize(t.size);
      var have = 0;
      if (t.blob != null) {
        try {
          final st = await api.state(t.blob!);
          have = st.done ? sealed : st.have;
        } on FilesError catch (e) {
          // Let go of by the relay (a day unfinished): started again.
          if (e.status != HttpStatus.notFound) rethrow;
          t.blob = null;
        }
      }
      t.blob ??= await api.newBlob(sealed);
      await _saveQueue();
      // Picking up part way on a file this app doesn't hold its own copy of (a computer's own file, where it lies): the
      // chunks still to go are sealed under the same key and nonces as before, so they must be the same words. A file
      // changed in place keeps its length and, on some disks, its time; only its hash tells. Changed, it is not sent on
      // (sealing other words under a nonce already used would give the key away).
      // A big file's check takes minutes (a film: tens of gigabytes), so it says how far it has got, and the bar shows
      // what the relay already has, rather than the upload looking stopped after the app opens again.
      Future<bool> unchanged() async {
        if (t.owned) return true;
        var said = -1;
        final sha = await _shaOf(t, t.size < 64 << 20 ? null : (read) {
          final pct = t.size <= 0 ? 0 : (read * 100 ~/ t.size).clamp(0, 99);
          if (pct == said) return;
          said = pct;
          t.status = 'Checking it before going on · $pct%';
          notifyListeners();
        });
        t.status = null;
        return sha == t.sha;
      }

      if (have > 0) {
        t.done = math.min(t.size, (have / sealed * t.size).round());
        if (t.size >= 64 << 20) t.status = 'Checking it before going on';
        notifyListeners();
      }
      if (have > 0 && !await unchanged()) {
        t._fail('The file changed while it was going up. Add it again.', retryable: false);
        await _settle(t);
        return;
      }
      t.status = null;
      const step = FileSeal.chunk + FileSeal.tag;
      final total = FileSeal.chunks(t.size);
      // Each piece is read and sealed on its own (its own handle on the file, so one sealed ahead while another goes up
      // never shares a position), across several cores (_sealParallel).
      Future<Uint8List> sealPiece(int first) async {
        final count = math.min(piece, total - first);
        final from = first * FileSeal.chunk;
        final length = math.min(t.size - from, count * FileSeal.chunk);
        if (file == null) {
          // A browser's: the piece read from the picked file, sealed by the browser's own AES-GCM (SealAsync).
          final plain = await src!.read(from, length);
          if (plain.length != length) throw const FileSystemException('The file changed while it was going up.');
          return SealAsync.sealRun(SealRun(key: t.fileKey!, prefix: t.prefix!, fileId: t.blob!, size: t.size, first: first, plain: plain));
        }
        final raf = await file.open();
        try {
          await raf.setPosition(from);
          final plain = await raf.read(length);
          if (plain.length != length) throw const FileSystemException('The file changed while it was going up.');
          final run = SealRun(key: t.fileKey!, prefix: t.prefix!, fileId: t.blob!, size: t.size, first: first, plain: plain);
          return run.plain.length > 64 * 1024 ? await _sealParallel(run) : FileSeal.sealRun(run);
        } finally {
          await raf.close();
        }
      }

      // The next piece is sealed while this one goes up (Matt, 2026-11-18, of uploading to a circle being slow), so
      // sealing and sending overlap rather than take turns.
      Future<Uint8List>? ahead;
      var aheadFirst = -1;
      try {
        while (have < sealed) {
          if (t._cancel) break;
          final first = have ~/ step;
          final Uint8List sealedRun;
          if (ahead != null && aheadFirst == first) {
            sealedRun = await ahead;
          } else {
            ahead?.ignore();
            sealedRun = await sealPiece(first);
          }
          ahead = null;
          final next = first + math.min<int>(piece, total - first);
          if (next < total) {
            aheadFirst = next;
            ahead = sealPiece(next);
          }
          // Where the relay has part of a chunk (a restart in the middle of a write), the rest of it: sealing the same
          // chunk again under the same nonce gives the same bytes, so what was there joins up with what follows.
          final skip = have - first * step;
          final bytes = skip > 0 ? Uint8List.sublistView(sealedRun, skip) : sealedRun;
          try {
            have = await api.put(t.blob!, have, bytes);
          } on FilesError catch (e) {
            if (e.status == HttpStatus.conflict && e.have != null) {
              // Told to go back (the relay kept less than was sent): what is sealed again must be what was.
              if (e.have! < have && !await unchanged()) throw const FileSystemException('The file changed while it was going up. Add it again.');
              have = e.have!;
              continue;
            }
            rethrow;
          }
          t.done = math.min(t.size, (have / sealed * t.size).round());
          _moved();
        }
      } finally {
        ahead?.ignore();
      }
      if (t._cancel) return;
      await api.done(t.blob!);
      final videoThumb = _videoThumbs.remove(t);
      if (videoThumb != null) t.thumb = (await videoThumb)?.png ?? t.thumb;
      final me = _signerOf(c)!.id;
      final f = SpaceFile(
        id: t.blob!,
        name: t.name,
        size: t.size,
        mime: t.mime,
        sha: t.sha!,
        key: t.fileKey!,
        prefix: t.prefix!,
        by: me,
        byName: t.chat ? (t.chatName ?? '') : _myName(),
        at: DateTime.now().millisecondsSinceEpoch,
        folder: t.folder,
        thumb: t.thumb,
        width: t.width,
        height: t.height,
      );
      if (t.chat) {
        // A chat's file: up, and nothing more here. It goes in no list (no `add` in the log, no word in the chat): the
        // message that carries it is what says it is there ([uploadForChat]).
        await _keepLocal(t, f);
        t.state = TransferState.done;
        t.done = t.size;
        t._chatFile = f;
        final done = t._chatDone;
        if (done != null && !done.isCompleted) done.complete(f);
        await _settle(t);
        return;
      }
      final seq = await _append(c, api, s, FileOp.add(f));
      // This device has the file already: kept as if it had come down, so it opens at once.
      await _keepLocal(t, f);
      // Listed before it is called done: whoever watches the upload finds the file in the list once it is.
      await s.refresh();
      t.state = TransferState.done;
      t.done = t.size;
      _ping(c, seq);
      if (!Drive.isDrive(c)) _announce?.call(c, '${f.byName.isEmpty ? 'Someone' : f.byName} added ${f.name} (${fileSize(f.size)})');
      await _settle(t);
    } on FilesError catch (e) {
      // The space gone from the relay meanwhile: opened again on the next try, which comes by itself.
      final gone = e.status == HttpStatus.notFound && e.message == 'No such space.';
      if (gone) s._ensured = false;
      if (e.offline || e.status >= 500 && e.status != HttpStatus.insufficientStorage || gone) {
        t._wait(e.message);
      } else if (e.status == HttpStatus.requestEntityTooLarge) {
        t._fail(s.info != null && s.info!.maxFile > 0 ? 'Too big: files can be up to ${fileSize(s.info!.maxFile)} each.' : 'Too big for this space.', retryable: false);
        await _settle(t);
      } else if (e.status == HttpStatus.insufficientStorage && e.message.contains('This space')) {
        t._fail('Not enough room left in this space.', retryable: false);
        await _settle(t);
      } else {
        t._fail(e.message);
        await _settle(t);
      }
      notifyListeners();
    } on FileSystemException catch (e) {
      t._fail(e.message.isEmpty ? 'The file couldn\'t be read.' : e.message);
      await _settle(t);
    } catch (e) {
      // A browser's file that can't be read any more (moved, deleted or changed since it was picked: NotReadableError).
      if (src == null) rethrow;
      t._fail('The file couldn\'t be read. Add it again.');
      await _settle(t);
    }
  }

  /// A finished or failed upload: off the queue on disk, and (done) off the list a moment later.
  Future<void> _settle(Transfer t) async {
    await _saveQueue();
    // A chat's file that stopped: its message is told why, and asks again to try again ([uploadForChat]).
    final waiting = t._chatDone;
    if (t.chat && t.state == TransferState.failed && waiting != null && !waiting.isCompleted) {
      waiting.future.ignore();
      waiting.completeError(FilesError(t.retryable ? 0 : HttpStatus.requestEntityTooLarge, t.error ?? 'It didn\'t go up.'));
    }
    notifyListeners();
    if (t.state == TransferState.done) {
      if (t.owned) _deleteQuietly(t.path!);
      Timer(const Duration(seconds: 3), () {
        transfers.remove(t);
        notifyListeners();
      });
    }
  }

  /// Puts the uploaded file where a download of [f] would lie ([cachedPath]): the app's own copy is moved there,
  /// someone's own file is copied where it is 64 MB or less.
  Future<void> _keepLocal(Transfer t, SpaceFile f) async {
    // A browser's upload is no file on this device: it comes down again if it is opened here.
    if (t.path == null) return;
    try {
      final at = File(cachedPath(f));
      await at.parent.create(recursive: true);
      if (t.owned) {
        await File(t.path!).rename(at.path);
      } else if (t.size <= 64 << 20) {
        await File(t.path!).copy(at.path);
      }
    } catch (_) {}
  }

  /// Stops [t]: an upload's blob is let go on the relay; a download's part is deleted.
  Future<void> cancel(Transfer t) async {
    t._cancel = true;
    transfers.remove(t);
    notifyListeners();
    if (t.up) {
      final waiting = t._chatDone;
      if (waiting != null && !waiting.isCompleted) {
        waiting.future.ignore();
        waiting.completeError(FilesError(-1, 'Stopped.'));
      }
      await _saveQueue();
      if (t.blob != null) {
        try {
          await _api(t.space)?.deleteBlob(t.blob!);
        } catch (_) {}
      }
      if (t.owned) _deleteQuietly(t.path!);
    } else {
      final f = t.file;
      // A browser's part is in memory, let go as its download sees it was stopped.
      if (f != null && !browser) _deleteQuietly(_partPath(f));
      t._done?.completeError(FilesError(-1, 'Stopped.'));
      _downloads.remove(t.file?.id);
    }
  }

  /// Tries [t] again where it failed.
  void retry(Transfer t) {
    if (!t.up) return;
    t.state = TransferState.queued;
    t.error = null;
    t.tries = 0;
    notifyListeners();
    _pump();
  }

  // --- a space's chat --------------------------------------------------------------------------------------------------

  /// [f] up for a message in [c]'s chat (Matt, 2026-11-18: "I also want full support for uploading attachements gifs
  /// stickers etc like we support in other chats"): sealed and kept on the relay as a Files space's file is, under the
  /// chat space's own seed (FileSeal.filesRoom), by the same queue ([upload]'s), and in no list. The relay asks only for the space's
  /// token and a signature by the uploader's hub key (relay/lib/files.dart): who may send a file is whoever may write
  /// in the chat, which each device judges by the roster, as it does the message itself.
  @override
  Future<SpaceFile> uploadForChat(VoiceChannel c, OutgoingFile f, {required String byName, required int thumbMost, required void Function() moved}) {
    final had = f.handle;
    if (had is Transfer && had._chatFile != null) return Future.value(had._chatFile);
    final done = Completer<SpaceFile>();
    final Transfer t;
    if (had is Transfer && transfers.contains(had)) {
      // Asked again after it stopped: it goes on from where the relay says it got to.
      t = had
        ..state = TransferState.queued
        ..error = null
        ..tries = 0;
    } else {
      t = Transfer._up(space: c, path: f.path, name: f.name, size: f.size, mime: f.mime, owned: f.owned)
        ..chat = true
        ..chatName = byName;
      transfers.add(t);
      f.handle = t;
    }
    t.thumbMost = thumbMost;
    t._chatDone = done;
    void watch() {
      f.progress = t.progress;
      f.waiting = t.state == TransferState.waiting ? (t.error ?? 'Waiting for the relay') : null;
      f.retryable = t.retryable;
      moved();
    }

    addListener(watch);
    done.future.then((_) {
      f.progress = 1;
      f.waiting = null;
    }, onError: (_) => watch()).whenComplete(() => removeListener(watch));
    notifyListeners();
    _pump();
    return done.future;
  }

  @override
  void drop(OutgoingFile f) {
    final t = f.handle;
    if (t is Transfer) unawaited(cancel(t));
  }

  // --- coming down ---------------------------------------------------------------------------------------------------

  /// Where [f] is kept on this device once it has come down: a folder of its own, under its own name.
  String cachedPath(SpaceFile f) => '${_cache().path}/${f.id}/${f.name.replaceAll(RegExp(r'[/\\:]'), '_')}';

  /// Where [f] is written while it comes down ([_runDownload]).
  String _partPath(SpaceFile f) => '${_cache().path}/${f.id}.part';

  /// [f]'s file on this device, where it has come down already.
  String? cached(SpaceFile f) {
    if (browser) return _held[f.id];
    final p = cachedPath(f);
    if (File(p).existsSync()) return p;
    // Renamed since it came down: the one there under its old name.
    final dir = Directory('${_cache().path}/${f.id}');
    if (!dir.existsSync()) return null;
    final other = dir.listSync().whereType<File>().firstOrNull;
    if (other == null) return null;
    try {
      return other.renameSync(p).path;
    } catch (_) {
      return other.path;
    }
  }

  /// Deletes all this device keeps of [f]: the file that came down, a part of one, and what a stream kept of it.
  void _forgetCached(SpaceFile f) {
    if (browser) {
      final url = _held.remove(f.id);
      if (url != null) HeldFiles.release(url);
      return;
    }
    try {
      final dir = Directory('${_cache().path}/${f.id}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    _deleteQuietly(_partPath(f));
    _deleteQuietly('${_cache().path}/${f.id}.stream');
    _deleteQuietly('${_cache().path}/${f.id}.chunks');
  }

  /// Downloads under way, by file id, so a second [fetch] of a file waits on the first.
  final Map<String, Transfer> _downloads = {};

  /// Files being played as they come down, by id: one [FileStream] each, however many hold it.
  final Map<String, FileStream> _streams = {};

  /// [f] served to the app's player as it comes down, a few chunks at a time, rather than brought down whole first
  /// (Matt, 2026-11-18: "would it be possible to setup streaming and buffering of the file?" ... "yes build it").
  /// [FileStream.close] it when done; once all of it has come it is the ordinary download ([cached]).
  FileStream stream(VoiceChannel c, SpaceFile f) {
    // A page has no server to play from: there a video comes down whole and plays from the tab ([fetch]).
    if (browser) throw UnsupportedError('A browser plays a file once it has come down.');
    final had = _streams[f.id];
    if (had != null && !had.closed) {
      had.hold();
      return had;
    }
    late final FileStream s;
    s = FileStream(
      file: f,
      cacheDir: _cache(),
      assembledPath: cachedPath(f),
      read: (start, end) async {
        final api = _api(c);
        if (api == null) throw FilesError(0, 'Not connected to the relay yet.');
        return api.read(f.id, start: start, end: end);
      },
      onWhole: (_) => notifyListeners(),
      onClosed: () {
        if (identical(_streams[f.id], s)) _streams.remove(f.id);
      },
    );
    _streams[f.id] = s;
    return s;
  }

  /// The download of [f] under way, if one is.
  Transfer? downloading(SpaceFile f) => _downloads[f.id];

  /// [f] on this device: there already, or brought down (its progress in [transfers]). Its path.
  Future<String> fetch(VoiceChannel c, SpaceFile f) {
    final have = cached(f);
    if (have != null) return Future.value(have);
    final going = _downloads[f.id];
    if (going != null) return going._done!.future;
    final t = Transfer._down(space: c, file: f);
    _downloads[f.id] = t;
    transfers.add(t);
    notifyListeners();
    final streaming = _streams[f.id];
    if (streaming != null && !streaming.closed) {
      // Being played as it comes: the rest is brought into the same chunks, not down a second time beside them.
      streaming.hold();
      t.state = TransferState.running;
      unawaited(streaming.whole((done, _) {
        t.done = done;
        _moved();
      }).then((path) {
        t.state = TransferState.done;
        _endDownload(t, path: path);
      }, onError: (Object e) => _endDownload(t, error: e is FilesError ? e : FilesError(0, '$e'))).whenComplete(streaming.close));
      return t._done!.future;
    }
    unawaited(browser ? _runHeldDownload(t) : _runDownload(t));
    return t._done!.future;
  }

  /// Brings [t]'s file down into its part file, going on from the last whole chunk there and opening the chunks as
  /// they come; then checks its SHA-256 and moves it to [cachedPath].
  Future<void> _runDownload(Transfer t) async {
    final c = t.space;
    final f = t.file!;
    final api = _api(c);
    if (api == null) {
      _endDownload(t, error: FilesError(0, 'Not connected to the relay yet.'));
      return;
    }
    final part = File(_partPath(f));
    RandomAccessFile? out;
    try {
      await part.parent.create(recursive: true);
      out = await part.open(mode: FileMode.append);
      final chunks = FileSeal.chunks(f.size, chunkSize: f.chunk);
      // What came before: whole chunks only.
      var whole = (await out.length()) ~/ f.chunk;
      if (whole >= chunks) whole = chunks - 1;
      await out.truncate(whole * f.chunk);
      await out.setPosition(whole * f.chunk);
      t.done = whole * f.chunk;
      t.state = TransferState.running;
      _moved();
      final stream = await api.read(f.id, start: FileSeal.sealedOffset(whole, chunkSize: f.chunk));
      final step = f.chunk + FileSeal.tag;
      final lastLen = FileSeal.plainLength(chunks - 1, f.size, chunkSize: f.chunk) + FileSeal.tag;
      // Opened up to 16 chunks at a time (4 MB) as they come: the next piece is not read while a lot is being opened.
      int lotOf(int i) => math.min(16, chunks - i);
      int bytesOf(int i) => lotOf(i) == chunks - i ? (lotOf(i) - 1) * step + lastLen : lotOf(i) * step;
      final buffer = BytesBuilder(copy: false);
      var index = whole;
      await for (final piece in stream) {
        if (t._cancel) throw FilesError(-1, 'Stopped.');
        buffer.add(piece);
        while (index < chunks && buffer.length >= bytesOf(index)) {
          final need = bytesOf(index), lot = lotOf(index), first = index;
          final bytes = buffer.takeBytes();
          buffer.add(Uint8List.sublistView(bytes, need));
          final run = OpenRun(key: f.key, prefix: f.prefix, fileId: f.id, size: f.size, first: first, sealed: Uint8List.sublistView(bytes, 0, need), chunkSize: f.chunk);
          final plain = need > 64 * 1024 ? await _openAside(run) : FileSeal.openRun(run);
          if (plain == null) throw FilesError(-2, 'The file didn\'t open: it was changed on the way, or isn\'t whole.');
          await out.writeFrom(plain);
          index += lot;
          t.done = math.min(f.size, t.done + plain.length);
          _moved();
        }
      }
      if (index < chunks) throw FilesError(-2, 'The file came down short.');
      await out.flush();
      await out.close();
      out = null;
      if (f.sha.isNotEmpty) {
        final path = part.path;
        final sha = await _shaAside(path);
        if (sha != f.sha) {
          _deleteQuietly(part.path);
          throw FilesError(-2, 'The file came down different from what was added.');
        }
      }
      final at = File(cachedPath(f));
      await at.parent.create(recursive: true);
      await part.rename(at.path);
      // Marked as come from the internet, as a browser's download is, so the system's own checks (Gatekeeper, the
      // Windows SmartScreen) still look at it if it is opened from its folder.
      await markFromInternet(at.path);
      t.state = TransferState.done;
      t.done = f.size;
      _endDownload(t, path: at.path);
    } catch (e) {
      try {
        await out?.close();
      } catch (_) {}
      _endDownload(t, error: e is FilesError ? e : FilesError(0, '$e'));
    }
  }

  /// A browser's download (docs/OPEN_NETWORK.md, part 6): read from the relay as it streams, opened [16] chunks at a
  /// time by the browser's own AES-GCM, each handed to the tab as it opens ([HeldFiles]) and hashed as it goes, then
  /// checked against its SHA-256 as the app checks its part file. Held for the tab's life under the address [fetch]
  /// gives; nothing is kept once the tab closes. Stopped, nothing is held. A cut connection is read again from the
  /// last whole lot, twice, as a stream's is (lib/files/file_stream.dart).
  Future<void> _runHeldDownload(Transfer t) async {
    final c = t.space;
    final f = t.file!;
    final api = _api(c);
    if (api == null) {
      _endDownload(t, error: FilesError(0, 'Not connected to the relay yet.'));
      return;
    }
    final out = HeldFiles.sink();
    final hash = _ShaSink();
    try {
      final chunks = FileSeal.chunks(f.size, chunkSize: f.chunk);
      final step = f.chunk + FileSeal.tag;
      final lastLen = FileSeal.plainLength(chunks - 1, f.size, chunkSize: f.chunk) + FileSeal.tag;
      int lotOf(int i) => math.min(16, chunks - i);
      int bytesOf(int i) => lotOf(i) == chunks - i ? (lotOf(i) - 1) * step + lastLen : lotOf(i) * step;
      t.state = TransferState.running;
      _moved();
      var index = 0;
      for (var tries = 0; index < chunks; tries++) {
        final buffer = BytesBuilder(copy: false);
        try {
          final stream = await api.read(f.id, start: FileSeal.sealedOffset(index, chunkSize: f.chunk));
          await for (final piece in stream) {
            if (t._cancel) throw FilesError(-1, 'Stopped.');
            buffer.add(piece);
            while (index < chunks && buffer.length >= bytesOf(index)) {
              final need = bytesOf(index), lot = lotOf(index), first = index;
              final bytes = buffer.takeBytes();
              buffer.add(Uint8List.sublistView(bytes, need));
              final plain = await SealAsync.openRun(OpenRun(key: f.key, prefix: f.prefix, fileId: f.id, size: f.size, first: first, sealed: Uint8List.sublistView(bytes, 0, need), chunkSize: f.chunk));
              if (plain == null) throw FilesError(-2, 'The file didn\'t open: it was changed on the way, or isn\'t whole.');
              if (t._cancel) throw FilesError(-1, 'Stopped.');
              out.add(plain);
              hash.add(plain);
              index += lot;
              t.done = math.min(f.size, t.done + plain.length);
              _moved();
            }
          }
          if (index < chunks) throw FilesError(0, 'The file came down short.');
        } on FilesError catch (e) {
          // Only the relay out of reach is tried again, from the last whole lot; a refusal or a lot that didn't open is not.
          if (!e.offline || tries >= 2 || t._cancel) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 400 * (tries + 1)));
        }
      }
      if (f.sha.isNotEmpty && hash.hex() != f.sha) throw FilesError(-2, 'The file came down different from what was added.');
      final url = out.finish(f.mime);
      _held[f.id] = url;
      t.state = TransferState.done;
      t.done = f.size;
      _endDownload(t, path: url);
    } catch (e) {
      out.abort();
      _endDownload(t, error: e is FilesError ? e : FilesError(0, '$e'));
    }
  }

  /// Takes a download off the lists and tells whoever waits on [fetch]: [path] where it came, else [error].
  void _endDownload(Transfer t, {String? path, FilesError? error}) {
    _downloads.remove(t.file?.id);
    transfers.remove(t);
    notifyListeners();
    final done = t._done!;
    if (done.isCompleted) return;
    if (path != null) {
      done.complete(path);
    } else {
      // Nobody may be waiting: the error is still taken, so it is not one nobody handled.
      done.future.ignore();
      done.completeError(error ?? FilesError(0, 'Stopped.'));
    }
  }

  static void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Videos' small pictures being made while they go up, by their upload.
  final Map<Object, Future<({Uint8List png, int width, int height})?>> _videoThumbs = {};

  /// A small PNG of the picture or video at [path] ([kind] says which), no more than 160 across and 18 KB: what the list
  /// and grid show of it. A video's is a frame from its first minute.
  static Future<({Uint8List png, int width, int height})?> thumbnailOfFile(String path, FileKind kind, {int most = SpaceFile.maxThumb}) async {
    try {
      final bytes = kind == FileKind.video ? await videoFrame(path) : await File(path).readAsBytes();
      return bytes == null ? null : await thumbnailOf(bytes, most: most);
    } catch (_) {
      return null;
    }
  }

  /// A small PNG of the encoded picture [bytes], no more than 160 across and [most] bytes (18 KB).
  static Future<({Uint8List png, int width, int height})?> thumbnailOf(Uint8List bytes, {int most = SpaceFile.maxThumb}) async {
    try {
      final full = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(full);
      final w = desc.width, h = desc.height;
      desc.dispose();
      full.dispose();
      // Smaller still for a space's chat, whose message carries several in one packet ([most] below 18 KB).
      for (final side in [160, 120, 88, 64, if (most < SpaceFile.maxThumb) ...[48, 32]]) {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: w >= h ? side : null, targetHeight: h > w ? side : null);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        frame.image.dispose();
        codec.dispose();
        if (data == null) return null;
        final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (png.length <= most) return (png: Uint8List.fromList(png), width: w, height: h);
      }
    } catch (_) {}
    return null;
  }
}

// The heavy work on an isolate of its own, from functions at the top so that what crosses is the one argument and
// nothing of the store around it (a closure made inside a method carries that method's whole context with it).
/// Marks the file at [path] as downloaded from the internet: the quarantine attribute on a Mac, the Zone.Identifier
/// stream (zone 3, the internet) on Windows. Nothing elsewhere; a failure is no matter (the file is still there).
Future<void> markFromInternet(String path) async {
  try {
    if (PlatformInfo.isMacOS) {
      final secs = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toRadixString(16);
      await Process.run('xattr', ['-w', 'com.apple.quarantine', '0081;$secs;Uplink;', path]);
    } else if (PlatformInfo.isWindows) {
      await File('$path:Zone.Identifier').writeAsString('[ZoneTransfer]\r\nZoneId=3\r\n');
    }
  } catch (_) {}
}

Future<String> _shaAside(String path, {void Function(int read)? told}) => shaOfFileAside(path, told: told);
Future<Uint8List> _sealAside(SealRun run) => runAside(() => FileSeal.sealRun(run));

/// [run] sealed on as many isolates as there are cores to spare (up to four), each a share of its chunks: AES on one
/// core runs at about 25 MB/s, under most connections (Matt, 2026-11-18, of uploading to a circle being slow).
Future<Uint8List> _sealParallel(SealRun run) async {
  final n = FileSeal.chunks(run.size, chunkSize: run.chunkSize);
  final count = (run.plain.length + run.chunkSize - 1) ~/ run.chunkSize;
  // In a call, two at most: the call's sound and pictures need the cores more than an upload needs to be quick
  // (GMFB-6, @matt: "The app is super laggy when in a voice call and uploading a video to the files").
  final most = Voice.instance.session != null ? 2 : 4;
  final ways = math.min(math.min(most, math.max(1, PlatformInfo.numberOfProcessors - 1)), count);
  if (ways <= 1 || run.first + count > n) return _sealAside(run);
  final per = (count + ways - 1) ~/ ways;
  final parts = <Future<Uint8List>>[];
  for (var k = 0; k < count; k += per) {
    final from = k * run.chunkSize;
    final to = math.min(run.plain.length, (k + per) * run.chunkSize);
    parts.add(_sealAside(SealRun(key: run.key, prefix: run.prefix, fileId: run.fileId, size: run.size, first: run.first + k, plain: Uint8List.sublistView(run.plain, from, to), chunkSize: run.chunkSize)));
  }
  final out = BytesBuilder(copy: false);
  for (final p in await Future.wait(parts)) {
    out.add(p);
  }
  return out.takeBytes();
}
Future<Uint8List?> _openAside(OpenRun run) => runAside(() => FileSeal.openRun(run));
Future<List<LoggedOp>> _checkAside(List<LoggedOp> log, String space) => runAside(() => checkAll(log, space));

/// The SHA-256 of the file at [path], in hex, read a megabyte at a time: run on another isolate.
String shaOfFile(String path, {void Function(int read)? told, @visibleForTesting bool plain = false}) {
  // [plain]: the Dart reader even where the device has its own, for a test of it on a Mac.
  final hash = (plain ? null : _AppleSha.open()) ?? _DartSha();
  final raf = File(path).openSync();
  try {
    final buf = Uint8List(4 << 20);
    var read = 0;
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      hash.add(buf, n);
      read += n;
      told?.call(read);
    }
    return NetCrypto.hex(hash.end());
  } finally {
    raf.closeSync();
    hash.close();
  }
}

/// [shaOfFile] off the screen's thread, saying how far it has read as it goes ([told], a few times a second at most).
/// A big file takes minutes even at its fastest (Matt, 2026-11-21, of a 26 GB file: "it's taking a long time to
/// 'getting file ready'"), so it has to be able to say where it is.
Future<String> shaOfFileAside(String path, {void Function(int read)? told}) async {
  if (told == null) return runAside(() => shaOfFile(path));
  final port = ReceivePort();
  final done = Completer<String>();
  port.listen((m) {
    if (m is int) {
      told(m);
    } else if (m is String) {
      done.complete(m);
    } else if (!done.isCompleted) {
      done.completeError(m is List && m.isNotEmpty ? FileSystemException('${m.first}', path) : FileSystemException('The file could not be read.', path));
    }
  });
  try {
    await Isolate.spawn(_shaTelling, (path, port.sendPort), onError: port.sendPort, errorsAreFatal: true);
    return await done.future;
  } finally {
    port.close();
  }
}

/// The isolate's side of [shaOfFileAside]: sends how many bytes are read, four times a second at most, and ends by
/// sending the hash.
void _shaTelling((String, SendPort) job) {
  final (path, port) = job;
  final clock = Stopwatch()..start();
  var last = 0;
  final sha = shaOfFile(path, told: (read) {
    if (clock.elapsedMilliseconds - last < 250) return;
    last = clock.elapsedMilliseconds;
    port.send(read);
  });
  Isolate.exit(port, sha);
}

/// A browser download's SHA-256, taken as its chunks come ([FilesStore._runHeldDownload]).
class _ShaSink {
  final _out = _DigestSink();
  late final ByteConversionSink _in = crypto.sha256.startChunkedConversion(_out);
  void add(Uint8List bytes) => _in.add(bytes);
  String hex() {
    _in.close();
    return NetCrypto.hex(Uint8List.fromList(_out.value!.bytes));
  }
}

/// SHA-256 a piece at a time. The plain Dart one (package:crypto) reads about 100 MB a second, five times what
/// pointycastle's did (19 MB/s: twenty minutes and more for a 26 GB file); a Mac's and an iPhone's own, on the
/// processor's SHA instructions, reads faster than the disk gives it.
abstract class _Sha {
  // Takes the first [length] bytes of [bytes]; [end] gives the 32 bytes of the hash; [close] frees what it held.
  void add(Uint8List bytes, int length);
  Uint8List end();
  void close() {}
}

/// package:crypto's, in Dart: what every device has.
class _DartSha implements _Sha {
  _DartSha() {
    _in = crypto.sha256.startChunkedConversion(_out);
  }
  final _DigestSink _out = _DigestSink();
  late final ByteConversionSink _in;

  @override
  void add(Uint8List bytes, int length) => _in.addSlice(bytes, 0, length, false);
  @override
  Uint8List end() {
    _in.close();
    return Uint8List.fromList(_out.value!.bytes);
  }

  @override
  void close() {}
}

/// Holds the one digest package:crypto hands over as its input is closed.
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// CommonCrypto's, which every Mac and iPhone has (libSystem): CC_SHA256_Init, _Update, _Final. They are reached
/// through `dart:ffi`, which a browser's build can't name, so the calls themselves are in apple_sha.dart's two halves.
class _AppleSha implements _Sha {
  _AppleSha._(this._own);
  final AppleSha _own;

  static _AppleSha? open() {
    final own = AppleSha.open();
    return own == null ? null : _AppleSha._(own);
  }

  @override
  void add(Uint8List bytes, int length) => _own.add(bytes, length);
  @override
  Uint8List end() => _own.end();
  @override
  void close() => _own.close();
}

/// What the roster of a space's chat room says of its files (lib/voice/roles.dart): adding needs Add files; renaming,
/// moving and removing someone else's needs Manage files and a higher role, or being the owner. A space from before
/// roles (no owner) lets everyone add and change their own.
class RosterRules implements FilesRules {
  const RosterRules(this.roster);
  final Roster roster;

  @override
  bool mayAdd(String by) => !roster.hasOwner ? !roster.banned.contains(by) : roster.can(by, Perm.uploadFiles);

  @override
  bool mayChange(String by, SpaceFile file) {
    if (roster.banned.contains(by)) return false;
    if (by == file.by || roster.isOwner(by)) return true;
    return roster.hasOwner && roster.can(by, Perm.manageFiles) && roster.outranks(by, file.by);
  }

  @override
  bool mayFolder(String by) => mayAdd(by);
}

/// One space's files on this device.
class FilesSpace {
  FilesSpace._(this.channel, this._store);
  final VoiceChannel channel;
  final FilesStore _store;

  /// The log's last number this device has read.
  int seq = 0;
  List<LoggedOp> _log = const [];
  FilesList _list = FilesList.read(const [], const OwnerRules(null));

  /// What the relay last said of the space: how much it holds and may.
  FilesInfo? info;

  /// Why the list could not be read just now; it shows what was kept.
  FilesError? error;
  bool loading = false;

  /// Whether a list was ever had (from disk or the relay): an empty space and one not read yet look different.
  bool _kept = false;
  bool get ready => _kept;

  /// How many [FilesStore.open]s hold this space: the poller and the chat room's listener run while any does.
  int _holds = 0;
  Timer? _poller;
  StreamSubscription<Object?>? _sub;

  /// The space was made or found on the relay this run ([_ensure]); set back when the relay says it has no such space.
  bool _ensured = false;

  /// The reading under way, so two [refresh]es at once are one.
  Future<void>? _refreshing;

  /// Read while there was no relay to read from: read again as soon as there is.
  bool _waiting = false;

  /// A roster revision the relay wouldn't take into the log ([FilesStore._append]): not tried again first on every write.
  int _rosterRefused = -1;

  /// The last entry read when this device first heard the relay say it takes `?after=` (FilesInfo.cas): a signed entry
  /// after it out of its place was moved by the relay (FilesList.read). Kept.
  int? _strictAfter;

  /// When the relay was last asked for the log ([_refresh]).
  DateTime _tried = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, SpaceFile> get files => _list.files;

  /// The log as this device holds it, each entry with how far it is believed.
  @visibleForTesting
  List<LoggedOp> get log => _log;
  Set<String> get folders => {..._list.folders};

  /// The folders right inside [parent] (null for the top), in order of their names; the files right in [folder]; and
  /// what is anywhere inside [path] (FilesList).
  List<String> subfolders(String? parent) => _list.subfolders(parent);
  Iterable<SpaceFile> filesIn(String? folder) => _list.filesIn(folder);
  Iterable<SpaceFile> filesUnder(String path) => _list.filesUnder(path);
  Iterable<String> foldersUnder(String path) => _list.foldersUnder(path);
  int get bytes => _list.bytes;

  /// Where this space's log, its last number and the relay's last word are kept between runs.
  File get _file => File('${_store._data().path}/spaces/${FileSeal.filesRoom(channel.seed)}.json');

  void _load() {
    // A browser keeps no list: it is read from the relay as the space opens.
    if (_store.browser) return;
    try {
      final f = _file;
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as Map;
      final room = FileSeal.filesRoom(channel.seed);
      // What was kept was checked as it came (and says how far it is believed), but for what 0.9.2 kept unchecked.
      _log = [
        for (final e in (j['log'] as List? ?? const [])) ?switch (LoggedOp.fromJson(e)) { final o? when o.trust == OpTrust.unchecked => o.checked(room), final o => o },
      ];
      seq = (j['seq'] as num?)?.toInt() ?? 0;
      _strictAfter = (j['sa'] as num?)?.toInt();
      if (j['info'] is Map) info = FilesInfo.from((j['info'] as Map).cast<String, dynamic>());
      _kept = true;
      _reread();
    } catch (_) {}
  }

  /// The log is kept by another isolate, soon after it changes (lib/inbox/kept_writer.dart): the whole of it, which
  /// only grows, was made JSON and written on the thread that draws at each refresh and each packet
  /// (docs/performance-audit.md, finding 4).
  late final KeptWriter _writer = KeptWriter(
    file: () => _file,
    snapshot: () => {'seq': seq, 'log': [for (final e in _log) e.toJson()], 'sa': ?_strictAfter, if (info != null) 'info': info!.toJson()},
    wait: const Duration(milliseconds: 300),
    most: const Duration(seconds: 2),
  );

  /// Has the log written soon ([_writer]).
  void _save() {
    if (!_store.browser) _writer.save();
  }

  /// Writes the log now (a test that reads the file after).
  @visibleForTesting
  void flushKept() {
    if (!_store.browser) _writer.flush();
  }

  /// Reads the list again from the log: each signed entry under the roster it was written under where that is known
  /// (the log's own rosters, or this device's), the rest under the roster as it is now (FilesList.read).
  void _reread() => _list = FilesList.read(_log, _store._rulesOf(channel),
      rosters: (j, previous) => _store._logged(channel, j, previous), rulesVersion: _store._trusted(channel)?.version ?? 0, strictAfter: _strictAfter);

  /// The relay's list has started again, behind what this device kept (swept after ninety days unused, or its data
  /// lost): what was kept is let go and the list read from its start (Matt, 2026-11-17: "Finish the missing pieces that
  /// went unfinished"). Before, a newer app went on sending each write after an entry the relay no longer had, and was
  /// refused for good; 0.9.2, which says no place, wasn't.
  void _startOver() {
    _log = const [];
    seq = 0;
    _strictAfter = null;
    _rosterRefused = -1;
    _reread();
    _save();
  }

  /// The roster revision last told to the relay ([_ensure]).
  int _toldRv = -1;

  /// Makes or finds the space on the relay and tells it the roster revision this device holds. Throws where the relay
  /// names another owner for it.
  Future<void> _ensure(FilesApi api) async {
    final roster = _store._trusted(channel);
    final rv = roster?.version ?? 0;
    // Once, and again whenever this device holds a newer roster than it told the relay of: the relay keeps the newest
    // it has believed and refuses an older one, so a demoted moderator's old roster is refused (files_roster.dart).
    if (_ensured && rv <= _toldRv) return;
    final said = roster == null ? null : _store._statement(channel, roster);
    FilesInfo got;
    try {
      got = await api.ensure(owner: channel.owner, rv: said);
    } on FilesError catch (e) {
      // A relay from before rosters takes at most 4 KB here, and may say so by closing the connection rather than with
      // a 413: asked again without it.
      if (said == null || !(e.status == HttpStatus.requestEntityTooLarge || e.offline)) rethrow;
      got = await api.ensure(owner: channel.owner);
    }
    info = got;
    // The relay names the owner only from the owner's own request; one that names someone else is not this space's.
    final held = info?.owner ?? '';
    if (held.isNotEmpty && channel.owner.isNotEmpty && held != channel.owner) throw FilesError(HttpStatus.forbidden, 'This space\'s files are held by someone else.');
    if (got.seq < seq) _startOver();
    _ensured = true;
    _toldRv = rv;
  }

  /// Reads what the log has after [seq], and what the relay says of the space.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    _tried = DateTime.now();
    final api = _store._api(channel);
    if (api == null) {
      // Before the relay is connected (the app just opened): the list kept is shown as it is, and it is read again as
      // the relay comes (FilesStore._voiceChanged). Only a space never read says why it is empty.
      error = _kept ? null : FilesError(0, 'Not connected to the relay yet.');
      _waiting = true;
      _reread();
      _store._changed();
      return;
    }
    loading = true;
    _waiting = false;
    _store._changed();
    try {
      for (var tries = 0;; tries++) {
        try {
          await _read(api);
          break;
        } on FilesError catch (e) {
          // No such space any more (swept as unused while the app ran): opened again, once.
          if (e.status != HttpStatus.notFound || tries > 0) rethrow;
          _ensured = false;
        }
      }
      error = null;
      _kept = true;
      _reread();
      _save();
    } on FilesError catch (e) {
      error = e;
      _reread();
    } finally {
      loading = false;
      _store._changed();
    }
  }

  /// Reads the log's pages after [seq], opens and checks each entry, and asks the relay how much the space holds.
  Future<void> _read(FilesApi api) async {
    await _ensure(api);
    final key = FileSeal.filesKey(channel.seed);
    var fresh = <LoggedOp>[];
    var more = true;
    while (more) {
      final page = await api.log(after: seq);
      if (page.seq < seq) {
        // Behind what this device kept: the relay's list started again.
        _startOver();
        fresh = [];
        continue;
      }
      for (final o in page.ops) {
        final s = (o['s'] as num).toInt();
        if (s <= seq) continue;
        List<int> sealed;
        try {
          sealed = base64Decode(o['o'] as String);
        } catch (_) {
          sealed = const [];
        }
        fresh.add(LoggedOp(
          seq: s,
          by: '${o['by']}',
          at: (o['at'] as num?)?.toInt() ?? 0,
          op: FileOp.open(key, sealed),
          relayRv: (o['rv'] as num?)?.toInt(),
          sh: FileOp.sealedHash(sealed),
          cas: o['c'] == 1,
        ));
        seq = s;
      }
      more = page.more && page.ops.isNotEmpty;
    }
    // Each entry's signature, author and place checked as it comes (FileOp.check): a few at once here, a page of them
    // on another isolate.
    final room = FileSeal.filesRoom(channel.seed);
    if (fresh.length > 8) {
      fresh = await _checkAside(fresh, room);
    } else {
      fresh = checkAll(fresh, room);
    }
    info = await api.info();
    if (fresh.isNotEmpty) _log = [..._log, ...fresh];
    // Heard for the first time that this relay takes `?after=`: from here on, a signed entry out of its place was moved.
    if (info!.cas && _strictAfter == null) _strictAfter = seq;
  }

  /// Listens in the space's chat room for others saying the log has grown.
  void _listen() {
    if (_sub != null) return;
    final route = _store._route();
    if (route == null) return;
    _sub = route.packets.where((p) => p.room == channel.chatRoom).listen((p) {
      final clear = NetCrypto.open(channel.key, p.bytes);
      if (clear == null) return;
      try {
        final m = jsonDecode(utf8.decode(clear)) as Map;
        if (m['t'] == 'files' && (m['seq'] is! int || (m['seq'] as int) > seq)) unawaited(refresh());
      } catch (_) {}
    });
  }

  void _dispose() {
    _poller?.cancel();
    _sub?.cancel();
  }
}

/// Where a transfer stands. `waiting` is an upload that is tried again by itself (no relay, or the relay failing);
/// `failed` stays until the person tries again.
enum TransferState { queued, running, waiting, failed, done }

/// A file going up or coming down: how far it has got.
class Transfer {
  Transfer._up({required this.space, required String this.path, required this.name, required this.size, required this.mime, this.folder, this.owned = false})
      : up = true,
        file = null,
        source = null,
        id = '${space.seed}:${DateTime.now().microsecondsSinceEpoch}:$path';

  /// An upload of a file that is no path here ([FilesStore.uploadSources]): a browser's.
  Transfer._source({required this.space, required FileSource this.source, required this.name, required this.size, required this.mime, this.folder})
      : up = true,
        file = null,
        path = null,
        owned = false,
        id = '${space.seed}:${DateTime.now().microsecondsSinceEpoch}:${source.name}';

  Transfer._down({required this.space, required SpaceFile this.file})
      : up = false,
        path = null,
        source = null,
        name = file.name,
        size = file.size,
        mime = file.mime,
        folder = file.folder,
        owned = false,
        id = '${space.seed}:${file.id}',
        _done = Completer<String>();

  /// For a picture or a test: one shown part way.
  @visibleForTesting
  Transfer.shown({required this.space, required this.name, required this.size, this.done = 0, this.up = true, this.state = TransferState.running, this.error, this.retryable = true})
      : path = null,
        source = null,
        file = null,
        mime = FileKind.mimeOf(name),
        folder = null,
        owned = false,
        id = '${space.seed}:$name';

  /// Which transfer this is, for a list's key.
  final String id;

  /// Going up (true) or coming down. An upload has a [path], a download a [file].
  final bool up;
  final VoiceChannel space;
  final String? path;

  /// What an upload of no path reads from ([Transfer._source]).
  final FileSource? source;
  final SpaceFile? file;
  final String name;
  final int size;
  final String mime;
  final String? folder;

  /// The file at [path] is a copy the app made (a phone's pick): deleted or moved into the cache once it is up.
  final bool owned;

  /// Bytes of the file gone up or come down so far.
  int done = 0;
  TransferState state = TransferState.queued;

  /// Why it stopped, or what it is waiting for.
  String? error;

  /// What it is doing before it moves (hashing a big file).
  String? status;
  int tries = 0;

  // An upload's sealing, kept so it picks up where it was.
  String? sha;
  Uint8List? fileKey;
  Uint8List? prefix;
  String? blob;
  Uint8List? thumb;
  int width = 0, height = 0;

  /// When the file was last changed as it was sealed: a file changed since is not sent on.
  int? modified;

  /// A file for a message in a space's chat ([FilesStore.upload]): kept off the queue on disk and out of the Files
  /// screen, and written in no list. Its small picture no more than [thumbMost] bytes, the name it goes under, what
  /// waits for it, and what it came to.
  bool chat = false;
  int thumbMost = SpaceFile.maxThumb;
  String? chatName;
  Completer<SpaceFile>? _chatDone;
  SpaceFile? _chatFile;

  /// Stopped by the person ([FilesStore.cancel]): whatever is running for it gives up at its next step.
  bool _cancel = false;

  /// A timer is already set to try it again ([FilesStore._pump]).
  bool _held = false;

  /// A download's path once it has come, for whoever waits on [FilesStore.fetch].
  Completer<String>? _done;

  double get progress => size <= 0 ? (state == TransferState.done ? 1 : 0) : (done / size).clamp(0.0, 1.0);

  /// Put aside to be tried again by itself; each try counted lengthens the next wait ([FilesStore._pump]).
  void _wait(String why) {
    state = TransferState.waiting;
    status = null;
    error = why;
    tries++;
  }

  /// Whether trying again could mend a failure: not for a file over the limit or a space without the room for it.
  bool retryable = true;

  /// Stopped for [why], until the person tries again.
  void _fail(String why, {bool retryable = true}) {
    state = TransferState.failed;
    status = null;
    error = why;
    this.retryable = retryable;
  }

  /// As kept in queue.json: the space, the file's path, and its sealing so far (hash, key, nonce prefix, blob), so it
  /// goes on under the same key where it was.
  Map<String, Object?> _toJson() => {
        'c': {...space.toJson(), 'k': space.kind.wire, if (space.circle != null) 'ci': space.circle},
        'p': path,
        'n': name,
        'z': size,
        'm': mime,
        if (folder != null) 'd': folder,
        if (owned) 'own': 1,
        if (sha != null) 'h': sha,
        if (fileKey != null) 'k': base64Encode(fileKey!),
        if (prefix != null) 'x': base64Encode(prefix!),
        if (blob != null) 'b': blob,
        if (modified != null) 'mt': modified,
        if (thumb != null) 'th': base64Encode(thumb!),
        if (width > 0) 'w': width,
        if (height > 0) 'ht': height,
        if (state == TransferState.failed) 'err': error,
        if (state == TransferState.failed && !retryable) 'nr': 1,
      };

  static Transfer? _fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final cj = j['c'] as Map;
      final base = VoiceChannel.fromJson(cj);
      if (base == null) return null;
      final c = VoiceChannel(seed: base.seed, name: base.name, owner: base.owner, kind: SpaceKind.files, circle: cj['ci'] as String?);
      final t = Transfer._up(space: c, path: j['p'] as String, name: j['n'] as String, size: (j['z'] as num).toInt(), mime: j['m'] as String, folder: j['d'] as String?, owned: j['own'] == 1);
      t.sha = j['h'] as String?;
      if (j['k'] is String) t.fileKey = base64Decode(j['k'] as String);
      if (j['x'] is String) t.prefix = base64Decode(j['x'] as String);
      t.blob = j['b'] as String?;
      t.modified = (j['mt'] as num?)?.toInt();
      if (j['th'] is String) t.thumb = base64Decode(j['th'] as String);
      t.width = (j['w'] as num?)?.toInt() ?? 0;
      t.height = (j['ht'] as num?)?.toInt() ?? 0;
      if (j['err'] is String) t._fail(j['err'] as String, retryable: j['nr'] != 1);
      return t;
    } catch (_) {
      return null;
    }
  }
}
