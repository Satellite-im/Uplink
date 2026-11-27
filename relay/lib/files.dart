import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'files_roster.dart';
import 'p256.dart';
import 'sha256.dart';

/// A Files space's store (Matt, 2026-11-17: "add full functionality for filesharing in a space when the space is
/// designated a Files Space"). A Files space has to work while whoever added a file is away, and the hub holds nothing
/// for a room, so the files are kept here, on the relay's disk, under `/files/<space>`.
///
/// - **What it sees.** Blobs and their sizes, and the hub name of whoever wrote each. Every file is sealed on the phone
///   before it leaves (AES-256-GCM in chunks, lib/net/file_seal.dart in the app) with a key in the file's own
///   description, and that description is sealed in turn with a key made from the space's seed, which never comes
///   here. The list of what a space holds is a log of sealed operations it keeps in order and hands back.
/// - **Who gets in.** Every request carries `Authorization: Ghost <token>`, the space's token, made from its seed; the
///   first to name a space sets it, as a hub room's is (hub.dart). Every write is also signed with the writer's hub
///   key, the same P-256 key the hub knows them by: `X-Ghost-Key` (33 bytes, base64), `X-Ghost-Time` (ms) and
///   `X-Ghost-Sig` over [signedWords]. So a blob is written, finished and removed only by whoever started it, or by the
///   space's owner (the key named when it was made), or by a moderator or admin who shows a roster the owner's chain
///   of signatures vouches for ([FilesRoster]).
/// - **Newer apps ask for more, older ones still get what they had** (Matt, 2026-11-17: "Finish the missing pieces that
///   went unfinished" (of Circles and Files spaces, released in 0.9.2)). 0.9.2 is on people's phones and computers and
///   talks to this same relay, so each new rule is asked only of a request that says it follows it: a log entry sent
///   with `?after=` lands only right after that entry or not at all ([_handle]); a blob piece sent with
///   `X-Ghost-Body-Sha256` has its signature checked before a byte of it is read ([_writeBlob]); a delete that sends
///   a roster is judged by it. A request without these is taken as 0.9.2 sends it, and judged as before.
/// - **Memory.** Nothing big is held: a chunk is streamed to disk as it arrives and hashed as it goes, and a read is
///   streamed from disk with Range, so a 2 GB file passes through a relay held to 300 MB.
/// - **Limits** ([FilesConfig], from the environment): how big a file may be, how much a space may hold, how much all
///   spaces together, how many spaces one name may make, and how many writes a minute.
/// - **Who may fill it.** A space and its keys cost nothing to make, so the limits are on what is written, not only on
///   who signs: a space's log counts against its room and the whole store's as its files do (and has a cap of its
///   own), a room promised to a file that never gets a byte is let go after ten minutes, and how many spaces and how
///   many unfinished bytes one address may have going is limited as well as one key ([FilesConfig]).
/// - **What goes by itself.** A blob left unfinished for a day (one that never got a byte, ten minutes); a space nobody
///   has opened for ninety days.
///
/// Layout: `<dir>/<space>/meta.json` (its token's hash, owner, blobs), `log.jsonl` (one sealed operation a line), and
/// `blobs/<id>` (`<id>.part` while it is being written).
class Files {
  Files({required this.dir, this.config = const FilesConfig(), DateTime Function()? now, Random? random, this.verbose = false})
      : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  final Directory dir;
  final FilesConfig config;
  final bool verbose;
  final DateTime Function() _now;
  final Random _random;

  /// What a write is signed over: these words, the method, the path with its query, the time and the body's SHA-256.
  static String signedWords(String method, String path, int time, String bodySha) => 'ghost-files v1\n$method\n$path\n$time\n$bodySha';

  /// How far a write's time may be from the relay's.
  static const skew = Duration(minutes: 10);

  /// The most a log page hands back: this many operations, or [pageBytes] of them, whichever comes first.
  static const page = 500;
  static const pageBytes = 1 << 20;

  /// Log lines between the marks of where they start in the file, so a page is read from near where it begins.
  static const _markEvery = 256;

  /// How many log pages may be read at once; more are asked to come back.
  static const _readersAtOnce = 4;
  int _readers = 0;

  /// Spaces made today by each address, and the day counted.
  final Map<String, int> _madeBy = {};
  String _madeDay = '';

  final Map<String, _Space> _spaces = {};
  // Signed requests already taken (a hash of the key and what it signed -> the time it carried), so none is taken
  // twice ([_who]); forgotten once past twice [skew].
  final Map<String, int> _replays = {};
  // Writes by each hub name in the minute numbered [_minute], held to [FilesConfig.writesPerMinute] ([_allowed]).
  final Map<String, int> _writes = {};
  int _minute = 0;
  int _used = 0;
  Timer? _sweeper;

  int get spaces => _spaces.length;

  /// Bytes held (files and lists), and promised to blobs still being written, across every space.
  int get used => _used;

  /// The address a request came from: what Caddy, the one proxy in front, says it was; else the connection's own.
  static String addressOf(HttpRequest r) {
    final said = r.headers.value('x-forwarded-for')?.split(',').first.trim();
    return said != null && said.isNotEmpty ? said : (r.connectionInfo?.remoteAddress.address ?? '');
  }

  /// Unfinished bytes promised to blobs whose room was asked for from [ip].
  int _promisedTo(String ip) {
    var n = 0;
    for (final s in _spaces.values) {
      for (final b in s.blobs.values) {
        if (!b.done && b.ip == ip) n += b.size - b.have;
      }
    }
    return n;
  }

  void _say(String what) {
    if (verbose) stdout.writeln('${_now().toIso8601String()} files $what');
  }

  /// Reads every space from the disk, then sweeps every ten minutes.
  Future<void> start() async {
    await _load();
    _sweeper ??= Timer.periodic(const Duration(minutes: 10), (_) => unawaited(sweep()));
  }

  /// Stops sweeping and writes every space's meta.json, so a save that was still to come is not lost.
  void stop() {
    _sweeper?.cancel();
    _sweeper = null;
    for (final s in _spaces.values) {
      _saveNow(s);
    }
  }

  static final _hexOnly = RegExp(r'^[0-9a-f]+$');
  static bool _hex(Object? text, int length) => text is String && text.length == length && _hexOnly.hasMatch(text);
  String _day() => _now().toUtc().toIso8601String().substring(0, 10);

  // --- what is kept ----------------------------------------------------------------------------------------------------

  Directory _dirOf(String id) => Directory('${dir.path}/$id');
  File _blobFile(String space, String id, {bool part = false}) => File('${dir.path}/$space/blobs/$id${part ? '.part' : ''}');

  /// Reads each space's meta.json and sets right what the disk says otherwise: a blob being written is cut back to
  /// what was last saved, the log's size and count are taken from the file, and a finished blob whose file has gone is
  /// dropped.
  Future<void> _load() async {
    if (!dir.existsSync()) return;
    await for (final e in dir.list()) {
      final id = e.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
      if (e is! Directory || !_hex(id, 32)) continue;
      final meta = File('${e.path}/meta.json');
      if (!meta.existsSync()) continue;
      try {
        final s = _Space.fromJson(id!, jsonDecode(meta.readAsStringSync()) as Map);
        // What a blob being written has is no more than the last save said: a piece written since may be one whose
        // signature was never checked (the relay stopped in the middle of it), so the file is cut back to that.
        for (final b in s.blobs.values.where((b) => !b.done)) {
          final f = _blobFile(id, b.id, part: true);
          final length = f.existsSync() ? f.lengthSync() : 0;
          b.have = min(min(length, b.have), b.size);
          if (length > b.have) {
            try {
              final raf = f.openSync(mode: FileMode.append)..truncateSync(b.have);
              raf.closeSync();
            } catch (_) {}
          }
        }
        // The list: its bytes count against the space's room, and its last number is its count of lines (saved
        // lazily, so the lines are what to go by).
        final log = File('${e.path}/log.jsonl');
        if (log.existsSync()) {
          s.logBytes = log.lengthSync();
          s.used += s.logBytes;
          var lines = 0;
          await for (final _ in log.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
            lines++;
          }
          s.seq = max(s.seq, lines);
        }
        s.blobs.removeWhere((_, b) => b.done && !_blobFile(id, b.id).existsSync());
        _spaces[id] = s;
        _used += s.used;
      } catch (err) {
        stderr.writeln('files: $id/meta.json could not be read: $err');
      }
    }
    await sweep();
  }

  /// Writes [s]'s meta.json now (to a file beside, renamed over), in place of any save still to come.
  void _saveNow(_Space s) {
    s.saver?.cancel();
    s.saver = null;
    // A space removed meanwhile is not brought back by a save that was still to come.
    if (s.removed) return;
    try {
      final d = _dirOf(s.id)..createSync(recursive: true);
      final tmp = File('${d.path}/meta.json.tmp')..writeAsStringSync(jsonEncode(s.toJson()));
      tmp.renameSync('${d.path}/meta.json');
    } catch (err) {
      stderr.writeln('files: ${s.id.substring(0, 6)}/meta.json could not be written: $err');
    }
  }

  /// Writes [s]'s meta.json two seconds after its last change, so a run of pieces or log lines is one write.
  void _saveSoon(_Space s) {
    if (s.removed) return;
    s.saver?.cancel();
    s.saver = Timer(const Duration(seconds: 2), () => _saveNow(s));
  }

  // --- answering -------------------------------------------------------------------------------------------------------

  /// Answers [r] with [status] and [body] as JSON, never cached. [_refuse] is the same with `{"err": why}`.
  Future<void> _answer(HttpRequest r, int status, [Map<String, Object?>? body]) async {
    try {
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..headers.set('Cache-Control', 'no-store')
        ..write(jsonEncode(body ?? const {}));
      await r.response.close();
    } catch (_) {}
  }

  Future<void> _refuse(HttpRequest r, int status, String why) => _answer(r, status, {'err': why});

  /// Refuses [r] without reading its body: dart:io holds an answer back until the body has been read, so a piece
  /// refused before it is read lets go of the body (and the connection with it) for the answer to go at once. Only for
  /// a piece no honest app sends (a bad signature, someone else's blob), which is not told where to pick up from.
  Future<void> _refuseUnread(HttpRequest r, int status, String why) {
    try {
      r.listen(null).cancel();
      r.response.persistentConnection = false;
    } catch (_) {}
    return _refuse(r, status, why);
  }

  /// The most a request carrying a roster may send (a space's PUT, a blob's DELETE): a roster names everyone with a
  /// role, so it is bigger than anything else these carry.
  static const _proofMost = 64 << 10;

  /// A signature's s as the lower of its two twins (s and n - s both check out), so one signature is one key.
  static String _lowS(List<int> sig) {
    var v = BigInt.zero;
    for (final b in sig.sublist(32)) {
      v = (v << 8) | BigInt.from(b);
    }
    final half = P256.n >> 1;
    if (v > half) v = P256.n - v;
    return '${hexOf(sig.sublist(0, 32))}${v.toRadixString(16).padLeft(64, '0')}';
  }

  /// The roster [proof] carries (`{"r": <base64 of the bytes signed>, "s": <hex signature>}`), where it is one to
  /// believe for [s]'s owner and may follow what this space has believed; null otherwise, with why. A newer one becomes
  /// the space's newest. The last one checked is remembered (by its bytes and its signature's lower twin), so a device
  /// deleting again costs no signature checks.
  ///
  /// What may follow (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"): an admin's grant from the
  /// owner has no version and can't be withdrawn, so a demoted admin still holds one and can sign a roster that checks
  /// out, naming themselves admin again, at any version. Kept as the newest, it would have refused the owner's real
  /// rosters for good. So: never older than the newest believed, and at the same version only the same bytes; a newer
  /// one signed by the owner, at any version; one signed by an admin only one version on, and only by one of the admins
  /// of the version before (a space that has believed nothing yet: its first version only).
  ({FilesRoster? roster, String why}) _rosterOf(_Space s, Object? proof) {
    if (proof is! Map || proof['r'] is! String || proof['s'] is! String) return (roster: null, why: 'No roster.');
    if (s.owner.isEmpty) return (roster: null, why: 'This space\'s owner hasn\'t opened it yet, so no roster can be checked.');
    List<int> signed, sig;
    try {
      signed = base64Decode(proof['r'] as String);
      final hex = proof['s'] as String;
      if (!_hex(hex, 128)) return (roster: null, why: 'Not a roster.');
      sig = FilesRoster.unhex(hex);
    } catch (_) {
      return (roster: null, why: 'Not a roster.');
    }
    final h = hexOf(sha256(signed));
    final said = '$h:${_lowS(sig)}';
    var roster = s.rosterSaid == said ? s.roster : null;
    if (roster == null) {
      roster = FilesRoster.check(owner: s.owner, signed: signed, sig: sig);
      if (roster == null) return (roster: null, why: 'That roster isn\'t signed by this space\'s owner or an admin.');
    }
    if (roster.version < s.rosterV) return (roster: null, why: 'That roster is older than one this space has seen.');
    if (roster.version == s.rosterV && s.rosterH != null && s.rosterH != h) return (roster: null, why: 'This space has seen another roster at that version.');
    if (roster.version > s.rosterV && roster.by != roster.owner) {
      final admins = s.admins;
      final follows = roster.version == s.rosterV + 1 && (admins == null ? s.rosterV == 0 : admins.contains(roster.by));
      if (!follows) return (roster: null, why: 'That roster skips ahead of what this space has seen.');
    }
    s.roster = roster;
    s.rosterSaid = said;
    if (roster.version > s.rosterV || s.rosterH == null) {
      s.rosterV = roster.version;
      s.rosterH = h;
      s.admins = roster.admins;
      _saveSoon(s);
    }
    return (roster: roster, why: '');
  }

  /// What an owner's or admin's device says of the space's newest roster as it opens it (`rv` in the PUT's body, signed
  /// with the rest of the request by [who]): `{v, h, ad, g}`, its version, the SHA-256 of its signed bytes, the hub ids
  /// of its admins, and from an admin the owner's grant making them one. Not the roster: who has which role, the bans
  /// and mutes are for the space's members to know, and the relay needs them only to judge a moderator's delete
  /// ([_rosterOf]), which sends the roster then (Matt, 2026-11-17: "Finish the missing pieces that went unfinished").
  ///
  /// The owner's word is the last, at any version, lower too, so a version an admin pushed ahead (a demoted one still
  /// holding the owner's old grant) is undone when the owner's device next opens the space. An admin's, one version on
  /// and only from one of the admins of the version before, as in [_rosterOf]. Anything else is not learnt from; the
  /// opening goes on.
  void _learn(_Space s, _Who who, Object? j) {
    if (j is! Map || s.owner.isEmpty) return;
    final v = j['v'], h = j['h'], ad = j['ad'];
    if (v is! int || v < 0 || v > 1 << 50 || !_hex(h, 64) || ad is! List || ad.length > FilesRoster.mostAdmins || !ad.every((a) => _hex(a, 32))) return;
    final admins = {for (final a in ad) a as String};
    if (v == s.rosterV && h == s.rosterH) return;
    if (who.key != s.owner) {
      final g = j['g'];
      if (!_hex(g, 128)) return;
      if (v != s.rosterV + 1 || !(s.admins == null ? s.rosterV == 0 : s.admins!.contains(who.id))) return;
      if (!P256.verify(FilesRoster.unhex(s.owner), utf8.encode('ghost-hangout admin|${s.owner}|${who.id}'), FilesRoster.unhex(g as String))) return;
    }
    s.rosterV = v;
    s.rosterH = h as String;
    s.admins = admins;
    s.roster = null;
    s.rosterSaid = null;
    _saveSoon(s);
  }

  /// How long a body may pause between pieces before the request is given up on: a body trickled a byte at a time
  /// would otherwise hold its blob (and a connection) for ever.
  static const bodyPause = Duration(seconds: 30);

  /// Reads a small body whole: null where it is longer than [most].
  Future<List<int>?> _small(HttpRequest r, int most) async {
    if (r.contentLength > most) return null;
    final out = BytesBuilder(copy: false);
    await for (final piece in r.timeout(bodyPause)) {
      out.add(piece);
      if (out.length > most) return null;
    }
    return out.takeBytes();
  }

  /// Who signed [r], having checked their signature over [bodySha]: null where it does not check out.
  _Who? _who(HttpRequest r, String bodySha) {
    try {
      final key = base64Decode(r.headers.value('x-ghost-key') ?? '');
      final sig = base64Decode(r.headers.value('x-ghost-sig') ?? '');
      final time = int.parse(r.headers.value('x-ghost-time') ?? '');
      final now = _now().millisecondsSinceEpoch;
      if ((now - time).abs() > skew.inMilliseconds) return null;
      final words = signedWords(r.method, r.uri.toString(), time, bodySha);
      // Remembered by what was signed, not by the signature: a signature has a twin (s and n - s) that checks out as
      // well, which a cache of signatures would let through once more.
      final said = hexOf(sha256([...key, ...utf8.encode(words)]));
      if (_replays.containsKey(said)) return null;
      // Full (a flood of fresh keys): no write is taken until it empties, rather than forgetting recent ones, which
      // would let a captured request be sent again.
      if (_replays.length >= 100000) return null;
      if (!P256.verify(key, utf8.encode(words), sig)) return null;
      _replays[said] = time;
      return _Who(hexOf(sha256(key).sublist(0, 16)), hexOf(key));
    } catch (_) {
      return null;
    }
  }

  /// A write [id] was charged for and didn't make.
  void _refund(String id) {
    final n = _writes[id];
    if (n != null && n > 0) _writes[id] = n - 1;
  }

  /// Whether [id] may write once more this minute.
  bool _allowed(String id) {
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _minute) {
      _minute = minute;
      _writes.clear();
    }
    final n = (_writes[id] ?? 0) + 1;
    _writes[id] = n;
    return n <= config.writesPerMinute;
  }

  /// Takes a request under `/files` (the relay hands over any address whose first part is `files`).
  Future<void> handle(HttpRequest r) async {
    try {
      await _handle(r);
    } catch (err) {
      _say('error: $err');
      await _refuse(r, HttpStatus.internalServerError, 'Something went wrong.');
    }
  }

  /// The routes, each with the space's token in `Authorization` and every write signed ([_who]):
  ///
  /// - `GET /files`: what this store allows (`maxFile`, `quota`); no token.
  /// - `PUT /files/<space>`: makes the space, or opens the one there; answers [_info].
  /// - `GET /files/<space>`: [_info]. `DELETE /files/<space>`: removes it and all it holds; its owner only.
  /// - `GET /files/<space>/log?after=<n>`: a page of the list ([_readLog]). `POST …/log[?after=<n>]`: adds a sealed
  ///   operation to it ([_appendLine]).
  /// - `POST /files/<space>/blobs` with `{size, pre?}`: room for a file; answers its id.
  /// - `PUT …/blobs/<id>?offset=<n>`: the next piece ([_writeBlob]). `GET …/blobs/<id>/state`: how far it has got.
  ///   `POST …/blobs/<id>/done`: finishes it, once every byte is here; its writer only.
  /// - `GET` or `HEAD …/blobs/<id>`: the finished blob, with Range ([_readBlob]). `DELETE …/blobs/<id>`: removes it;
  ///   its writer, the owner, or someone the space's roster lets.
  Future<void> _handle(HttpRequest r) async {
    final parts = r.uri.pathSegments.where((s) => s.isNotEmpty).skip(1).toList();
    if (parts.isEmpty) {
      return _answer(r, HttpStatus.ok, {'files': 1, 'maxFile': config.maxFile, 'quota': config.spaceQuota});
    }
    final id = parts[0];
    if (!_hex(id, 32)) return _refuse(r, HttpStatus.notFound, 'No such space.');
    final auth = r.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final token = auth.startsWith('Ghost ') ? auth.substring(6).trim() : '';
    if (!_hex(token, 64)) return _refuse(r, HttpStatus.unauthorized, 'No token.');
    // A wrong token is answered as no space at all: the two are told apart by nothing (a space's id is made from its
    // seed, as its token is, so this only stops a probe telling which ids are in use).
    final hash = hexOf(sha256(utf8.encode(token)));
    final method = r.method;
    var s = _spaces[id];

    // Making a space, or finding the one there is. A newer app on the owner's or an admin's device says the space's
    // newest roster version as well ([_learn]), so the relay hears of a demotion before a moderator's old roster could
    // be shown to it.
    if (parts.length == 1 && method == 'PUT') {
      final body = await _small(r, _proofMost);
      if (body == null) return _refuse(r, HttpStatus.requestEntityTooLarge, 'Too big.');
      final who = _who(r, hexOf(sha256(body)));
      if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
      // The owner the body names is taken only from the owner themselves (the signer's own key): anyone else opening
      // the space first can't make themselves its owner, and the owner opening it later becomes it.
      String named = '';
      Object? said;
      try {
        final j = jsonDecode(utf8.decode(body)) as Map;
        final o = j['owner'];
        if (o is String && RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(o)) named = o;
        said = j['rv'];
      } catch (_) {}
      final owner = named == who.key ? named : '';
      if (s != null) {
        if (s.hash != hash) return _refuse(r, HttpStatus.notFound, 'No such space.');
        if (s.owner.isEmpty && owner.isNotEmpty) {
          s.owner = owner;
          _saveSoon(s);
        }
        // What it says of the roster is learnt from where it may be ([_learn]), and costs a write (an admin's is a
        // signature to check); one that doesn't check out, or comes too often, is no reason to refuse the opening.
        if (said != null && _allowed(who.id)) _learn(s, who, said);
        _touch(s);
        return _answer(r, HttpStatus.ok, _info(s));
      }
      if (!_allowed(who.id)) return _refuse(r, HttpStatus.tooManyRequests, 'Slow down.');
      if (_spaces.values.where((x) => x.by == who.id).length >= config.spacesPerId) return _refuse(r, HttpStatus.forbidden, 'Too many Files spaces made by this device.');
      // And by address: a fresh key costs nothing, an address does.
      final ip = addressOf(r);
      if (_madeDay != _day()) {
        _madeDay = _day();
        _madeBy.clear();
      }
      if ((_madeBy[ip] ?? 0) >= config.spacesPerAddress) return _refuse(r, HttpStatus.tooManyRequests, 'Too many Files spaces made from here today.');
      if (_spaces.length >= config.maxSpaces) return _refuse(r, HttpStatus.insufficientStorage, 'Full.');
      _madeBy[ip] = (_madeBy[ip] ?? 0) + 1;
      s = _spaces[id] = _Space(id: id, hash: hash, owner: owner, by: who.id, created: _now().millisecondsSinceEpoch, day: _day());
      Directory('${_dirOf(id).path}/blobs').createSync(recursive: true);
      if (said != null) _learn(s, who, said);
      _saveNow(s);
      _say('${id.substring(0, 6)} made');
      return _answer(r, HttpStatus.created, _info(s));
    }
    if (s == null || s.hash != hash) return _refuse(r, HttpStatus.notFound, 'No such space.');
    _touch(s);

    if (parts.length == 1) {
      if (method == 'GET') return _answer(r, HttpStatus.ok, _info(s));
      if (method == 'DELETE') {
        final who = _who(r, hexOf(sha256(const [])));
        if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
        // Only a known owner: with none named, nobody may (not even whoever opened it first, who may not be its owner).
        if (s.owner.isEmpty || who.key != s.owner) return _refuse(r, HttpStatus.forbidden, 'Only the space\'s owner can remove it.');
        _remove(s, 'removed');
        return _answer(r, HttpStatus.ok, {'ok': true});
      }
      return _refuse(r, HttpStatus.methodNotAllowed, 'No.');
    }

    switch (parts[1]) {
      case 'log' when parts.length == 2 && method == 'GET':
        return _readLog(r, s);
      case 'log' when parts.length == 2 && method == 'POST':
        final body = await _small(r, config.maxOp);
        if (body == null || body.isEmpty) return _refuse(r, HttpStatus.requestEntityTooLarge, 'An operation is at most ${config.maxOp} bytes.');
        final who = _who(r, hexOf(sha256(body)));
        if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
        if (!_allowed(who.id)) return _refuse(r, HttpStatus.tooManyRequests, 'Slow down.');
        // One entry at a time per space: two written at once were both given the same number (the next number was
        // taken before the line was written, the line written, and only then the number moved on), and a device
        // reading the log skipped the second as one it had (Matt, 2026-11-17: "Finish the missing pieces that went
        // unfinished").
        final turn = Completer<void>();
        final before = s.appending;
        s.appending = turn.future;
        await before;
        // The answer is worked out while the space is held and sent once it is let go: a writer slow to take its answer
        // no longer holds up everyone else writing to the space.
        int status;
        Map<String, Object?> answer;
        try {
          (status, answer) = await _appendLine(r, s, who, body);
        } finally {
          turn.complete();
        }
        if (status == HttpStatus.ok) _saveSoon(s);
        return _answer(r, status, answer);
      case 'blobs' when parts.length == 2 && method == 'POST':
        final body = await _small(r, 1024);
        if (body == null) return _refuse(r, HttpStatus.requestEntityTooLarge, 'Too big.');
        final who = _who(r, hexOf(sha256(body)));
        if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
        if (!_allowed(who.id)) return _refuse(r, HttpStatus.tooManyRequests, 'Slow down.');
        int size;
        bool pre;
        try {
          final j = jsonDecode(utf8.decode(body)) as Map;
          size = (j['size'] as num).toInt();
          pre = j['pre'] == true;
        } catch (_) {
          return _refuse(r, HttpStatus.badRequest, 'No size.');
        }
        if (size < 16) return _refuse(r, HttpStatus.badRequest, 'Too small.');
        if (size > config.maxFile) return _refuse(r, HttpStatus.requestEntityTooLarge, 'A file may be at most ${config.maxFile} bytes.');
        if (s.used + size > _quotaOf(s)) return _refuse(r, HttpStatus.insufficientStorage, 'This space is full.');
        if (_used + size > config.total) return _refuse(r, HttpStatus.insufficientStorage, 'The files server is full.');
        if (s.blobs.length >= config.maxBlobs) return _refuse(r, HttpStatus.insufficientStorage, 'This space holds as many files as it can.');
        // Room promised and not yet written, per address: a room asked for and never filled holds the store's room
        // from everyone else (it is let go after ten minutes without a byte, a day with some).
        final ip = addressOf(r);
        if (_promisedTo(ip) + size > config.promisedPerAddress) return _refuse(r, HttpStatus.tooManyRequests, 'Too many files on their way from here. Finish those first.');
        final bid = hexOf([for (var i = 0; i < 16; i++) _random.nextInt(256)]);
        final b = s.blobs[bid] = _Blob(id: bid, by: who.id, size: size, at: _now().millisecondsSinceEpoch, pre: pre)..ip = ip;
        s.used += size;
        _used += size;
        Directory('${_dirOf(s.id).path}/blobs').createSync(recursive: true);
        _blobFile(s.id, bid, part: true).writeAsBytesSync(const []);
        _saveNow(s);
        return _answer(r, HttpStatus.created, {'id': b.id, 'have': 0});
      case 'blobs' when parts.length >= 3:
        final b = s.blobs[parts[2]];
        if (b == null) return _refuse(r, HttpStatus.notFound, 'No such file.');
        if (parts.length == 3 && (method == 'GET' || method == 'HEAD')) return _readBlob(r, s, b);
        if (parts.length == 3 && method == 'PUT') return _writeBlob(r, s, b);
        if (parts.length == 3 && method == 'DELETE') {
          // 0.9.2 sends no body; a newer app asking as a moderator or admin sends its roster, signed over with the rest.
          final body = await _small(r, _proofMost);
          if (body == null) return _refuse(r, HttpStatus.requestEntityTooLarge, 'Too big.');
          final who = _who(r, hexOf(sha256(body)));
          if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
          if (who.id != b.by && (s.owner.isEmpty || who.key != s.owner)) {
            Object? proof;
            try {
              proof = body.isEmpty ? null : (jsonDecode(utf8.decode(body)) as Map)['roster'];
            } catch (_) {}
            if (proof == null) return _refuse(r, HttpStatus.forbidden, 'Only whoever added it, the space\'s owner, or a moderator can remove it.');
            // A roster is up to 65 signatures to check: it costs a write, so it can't be sent without end.
            if (!_allowed(who.id)) return _refuse(r, HttpStatus.tooManyRequests, 'Slow down.');
            final got = _rosterOf(s, proof);
            if (got.roster == null) return _refuse(r, HttpStatus.forbidden, got.why);
            if (!got.roster!.mayRemove(who.id, b.by)) return _refuse(r, HttpStatus.forbidden, 'This space\'s roles don\'t let you remove that file.');
          }
          _dropBlob(s, b);
          _saveNow(s);
          return _answer(r, HttpStatus.ok, {'ok': true});
        }
        if (parts.length == 4 && parts[3] == 'state' && method == 'GET') return _answer(r, HttpStatus.ok, {'have': b.have, 'size': b.size, 'done': b.done});
        if (parts.length == 4 && parts[3] == 'done' && method == 'POST') {
          await _small(r, 1024);
          final who = _who(r, hexOf(sha256(const [])));
          if (who == null) return _refuse(r, HttpStatus.unauthorized, 'Bad signature.');
          if (who.id != b.by) return _refuse(r, HttpStatus.forbidden, 'Not yours.');
          if (b.done) return _answer(r, HttpStatus.ok, {'have': b.have, 'done': true});
          if (b.writing || b.have != b.size) return _refuse(r, HttpStatus.conflict, 'Not all of it is here yet.');
          await _blobFile(s.id, b.id, part: true).rename(_blobFile(s.id, b.id).path);
          b.done = true;
          _saveNow(s);
          return _answer(r, HttpStatus.ok, {'have': b.have, 'done': true});
        }
    }
    return _refuse(r, HttpStatus.notFound, 'No.');
  }

  /// Adds [body] to [s]'s log as [who]'s entry, with the space held: what to answer.
  Future<(int, Map<String, Object?>)> _appendLine(HttpRequest r, _Space s, _Who who, List<int> body) async {
    if (s.removed) return (HttpStatus.notFound, <String, Object?>{'err': 'No such space.'});
    // Sent with the number of the last entry its writer had read (a newer app, which signs that number into the entry
    // itself): it goes right after that one or not at all, so an entry's place is the one its writer signed, and a
    // relay that moved it would be found out. 0.9.2 sends none and its entry goes at the end.
    final after = r.uri.queryParameters['after'];
    if (after != null && int.tryParse(after) != s.seq) {
      // Not written, so not counted against the writer's writes a minute: someone appending without pause can't use up
      // a newer app's writes by having each land a moment too late (Matt, 2026-11-17: "Finish the missing pieces that
      // went unfinished").
      _refund(who.id);
      return (HttpStatus.conflict, <String, Object?>{'err': 'The list has moved on. Read it again.', 'seq': s.seq});
    }
    if (s.seq >= config.maxOps) return (HttpStatus.insufficientStorage, <String, Object?>{'err': 'This space\'s list is full.'});
    final seq = s.seq + 1;
    // With the newest roster revision the relay has believed for the space ([_rosterOf], [_learn]): a newer app judges
    // the entry by a roster no older than that, so a moderator demoted since can't sign under the roster from before and
    // be believed. And `c`: this relay puts an entry sent with `?after=` only there, so a newer app reading a signed
    // entry out of its place knows it was moved. 0.9.2 reads past both.
    final line = utf8.encode('${jsonEncode({'s': seq, 'by': who.id, 'at': _now().millisecondsSinceEpoch, if (s.rosterV > 0) 'rv': s.rosterV, 'c': 1, 'o': base64Encode(body)})}\n');
    // The list takes room as its files do: in the space's, in the whole store's, and under a cap of its own.
    if (s.logBytes + line.length > config.maxLogBytes) return (HttpStatus.insufficientStorage, <String, Object?>{'err': 'This space\'s list is full.'});
    if (s.used + line.length > _quotaOf(s)) return (HttpStatus.insufficientStorage, <String, Object?>{'err': 'This space is full.'});
    if (_used + line.length > config.total) return (HttpStatus.insufficientStorage, <String, Object?>{'err': 'The files server is full.'});
    final log = File('${_dirOf(s.id).path}/log.jsonl');
    final at = s.logBytes;
    await log.writeAsBytes(line, mode: FileMode.append, flush: true);
    if (s.removed) return (HttpStatus.notFound, <String, Object?>{'err': 'No such space.'});
    final marks = s.marks;
    if ((seq - 1) % _markEvery == 0 && marks != null && marks.length == (seq - 1) ~/ _markEvery) marks.add(at);
    s.seq = seq;
    s.logBytes += line.length;
    s.used += line.length;
    _used += line.length;
    // Its number is its count of lines, read again at a restart: the save need not happen on every line.
    return (HttpStatus.ok, <String, Object?>{'seq': seq});
  }

  /// What a space says of itself to anyone with its token: how long its list is, how full it is, its limits, its owner
  /// and the newest roster version believed.
  /// What [s] may hold: [FilesConfig.spaceQuota], or for one of [FilesConfig.roomy] what the others of them leave of
  /// [FilesConfig.roomyQuota].
  int _quotaOf(_Space s) {
    if (!config.roomy.contains(s.id)) return config.spaceQuota;
    var others = 0;
    for (final id in config.roomy) {
      if (id != s.id) others += _spaces[id]?.used ?? 0;
    }
    return config.roomyQuota - others;
  }

  Map<String, Object?> _info(_Space s) => {
        'seq': s.seq,
        'used': s.used,
        'quota': _quotaOf(s),
        'maxFile': config.maxFile,
        'files': s.blobs.values.where((b) => b.done).length,
        'owner': s.owner,
        'rv': s.rosterV,
        // This relay puts an entry sent with `?after=` only right there (a newer app reads a signed entry out of its
        // place as moved, then); 0.9.2 reads past it.
        'cas': 1,
        // Uploads not finished yet, each holding its room until it is or is let go (a day after its last piece; Matt,
        // 2026-11-21: "I need a way to see partially uploaded files, the oddysey uploaded partially but then
        // disconnected when I restarted the app it stopped uploading but kept the space reserved"). Only what the relay
        // knows: its id, who started it, its size, how much is here and when it last moved; the name is sealed in the
        // device's own queue. The newest hundred.
        'parts': [
          for (final b in (s.blobs.values.where((b) => !b.done).toList()..sort((a, b) => b.at.compareTo(a.at))).take(100))
            {'id': b.id, 'by': b.by, 'z': b.size, 'h': b.have, 'at': b.at},
        ],
      };

  /// Notes that [s] was opened today, which is what keeps it from the ninety days' sweep; saved once a day at most.
  void _touch(_Space s) {
    final today = _day();
    if (s.day == today) return;
    s.day = today;
    _saveSoon(s);
  }

  /// A page of the log after `?after=`: at most [page] operations or [pageBytes] of them. Read from the mark nearest
  /// before where it starts ([_Space.marks]), not from the first line, and written out as the lines are on disk
  /// (each is already JSON), never decoded and held as maps: a page of big operations held three times over (maps,
  /// the encoded text, the bytes sent) came to over 100 MB, and a few at once took the relay past its memory.
  Future<void> _readLog(HttpRequest r, _Space s) async {
    final after = max(0, int.tryParse(r.uri.queryParameters['after'] ?? '0') ?? 0);
    final f = File('${_dirOf(s.id).path}/log.jsonl');
    if (after >= s.seq || !f.existsSync()) return _answer(r, HttpStatus.ok, {'ops': const [], 'seq': s.seq, 'more': false});
    if (_readers >= _readersAtOnce) {
      r.response.headers.set('Retry-After', '2');
      return _refuse(r, HttpStatus.serviceUnavailable, 'Busy. Try again in a moment.');
    }
    _readers++;
    try {
      final marks = s.marks ??= await _marksOf(f);
      final k = min(after ~/ _markEvery, marks.length - 1);
      var seq = k * _markEvery;
      final lines = <String>[];
      var bytes = 0;
      var more = false;
      await for (final line in f.openRead(marks[k]).transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        seq++;
        if (seq <= after) continue;
        if (lines.length >= page || (lines.isNotEmpty && bytes + line.length > pageBytes)) {
          more = true;
          break;
        }
        lines.add(line);
        bytes += line.length;
      }
      try {
        r.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..headers.set('Cache-Control', 'no-store')
          ..write('{"ops":[')
          ..write(lines.join(','))
          ..write('],"seq":${s.seq},"more":$more}');
        await r.response.close();
      } catch (_) {}
    } finally {
      _readers--;
    }
  }

  /// Where every [_markEvery]th line of a log starts (the first at 0), from one pass over it.
  Future<List<int>> _marksOf(File f) async {
    final marks = <int>[0];
    var at = 0, n = 0;
    await for (final chunk in f.openRead()) {
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 10) continue;
        n++;
        if (n % _markEvery == 0) marks.add(at + i + 1);
      }
      at += chunk.length;
    }
    return marks;
  }

  /// A blob, whole or the part a Range asks for, streamed from the disk.
  Future<void> _readBlob(HttpRequest r, _Space s, _Blob b) async {
    if (!b.done) return _refuse(r, HttpStatus.conflict, 'Not all of it is here yet.');
    final f = _blobFile(s.id, b.id);
    final length = f.lengthSync();
    var start = 0, end = length - 1;
    final range = r.headers.value(HttpHeaders.rangeHeader);
    final m = range == null ? null : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (range != null) {
      if (m == null || (m.group(1)!.isEmpty && m.group(2)!.isEmpty)) return _rangeRefused(r, length);
      // Figures too long to be a number are no range (416), not an error.
      final a = m.group(1)!.isEmpty ? null : int.tryParse(m.group(1)!), z = m.group(2)!.isEmpty ? null : int.tryParse(m.group(2)!);
      if ((m.group(1)!.isNotEmpty && a == null) || (m.group(2)!.isNotEmpty && z == null)) return _rangeRefused(r, length);
      if (a == null) {
        // The last n bytes.
        start = max(0, length - z!);
      } else {
        start = a;
        if (z != null) end = min(end, z);
      }
      if (start >= length || start > end) return _rangeRefused(r, length);
    }
    final res = r.response
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..headers.contentType = ContentType.binary
      ..headers.set('Accept-Ranges', 'bytes')
      ..headers.set('Cache-Control', 'no-store')
      ..contentLength = end - start + 1;
    if (range != null) res.headers.set('Content-Range', 'bytes $start-$end/$length');
    if (r.method == 'HEAD') return res.close();
    try {
      await f.openRead(start, end + 1).pipe(res);
    } catch (_) {}
  }

  /// 416 for a Range that is no part of the blob, with the blob's length.
  Future<void> _rangeRefused(HttpRequest r, int length) async {
    r.response
      ..statusCode = HttpStatus.requestedRangeNotSatisfiable
      ..headers.set('Content-Range', 'bytes */$length');
    await r.response.close();
  }

  /// The header a newer app sends with a blob piece: the SHA-256 of the body to come (hex), which its signature covers in
  /// place of the hash the relay would otherwise work out at the end; with its length in `X-Ghost-Body-Length`.
  static const bodyShaHeader = 'x-ghost-body-sha256', bodyLengthHeader = 'x-ghost-body-length';

  /// A piece of a blob, at `?offset=` (which must be where it has got to), streamed to the disk and hashed as it goes.
  ///
  /// Sent by a newer app, it says the body's hash and length up front ([bodyShaHeader]) and signs over that hash, so
  /// the signature is checked before a byte is read: someone who knows only an uploader's public key (it is in the
  /// roster) can no longer hold the blob, spend the uploader's writes a minute, or have up to 8 MB written to the disk
  /// before being found out (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"). What comes is then
  /// held to that hash. Sent by 0.9.2, without the header, the signature over the hash is checked at the end, as
  /// before, and a piece that does not check out is cut back off.
  Future<void> _writeBlob(HttpRequest r, _Space s, _Blob b) async {
    final offset = int.tryParse(r.uri.queryParameters['offset'] ?? '');
    if (b.done) return _answer(r, HttpStatus.conflict, {'err': 'Already finished.', 'have': b.have, 'done': true});
    if (offset == null || offset != b.have || b.writing) return _answer(r, HttpStatus.conflict, {'err': 'Send from where it has got to.', 'have': b.have});
    if (r.contentLength > config.maxBody) return _refuse(r, HttpStatus.requestEntityTooLarge, 'A piece is at most ${config.maxBody} bytes.');
    final said = r.headers.value(bodyShaHeader)?.trim().toLowerCase();
    String? saidSha;
    if (said != null) {
      // Said up front: its length must be the request's own, and fit; then the signature, before the body.
      final length = int.tryParse(r.headers.value(bodyLengthHeader)?.trim() ?? '${r.contentLength}');
      if (!_hex(said, 64) || length == null || length < 0 || length != r.contentLength) return _refuseUnread(r, HttpStatus.badRequest, 'The body\'s hash and length don\'t match the request.');
      if (offset + length > b.size) return _refuseUnread(r, HttpStatus.requestEntityTooLarge, 'More than the file was said to be.');
      final who = _who(r, said);
      if (who == null) return _refuseUnread(r, HttpStatus.unauthorized, 'Bad signature.');
      if (who.id != b.by) return _refuseUnread(r, HttpStatus.forbidden, 'Not yours.');
      saidSha = said;
    } else {
      // A blob its uploader started as a newer app (`pre`) has every piece say its hash up front: one that doesn't is
      // someone choosing the 0.9.2 way to have the relay read and hold up to 8 MB before the signature is checked, and
      // is refused unread, before it costs the uploader a write (Matt, 2026-11-17: "Finish the missing pieces that went
      // unfinished"). A blob 0.9.2 started still takes pieces its way.
      if (b.pre) return _refuseUnread(r, HttpStatus.forbidden, 'Say the piece\'s hash first.');
      // Who it is is known only once the body's hash is: the key is checked against the blob's writer first.
      List<int> key;
      try {
        key = base64Decode(r.headers.value('x-ghost-key') ?? '');
      } catch (_) {
        key = const [];
      }
      if (key.isEmpty || hexOf(sha256(key).sublist(0, 16)) != b.by) return _refuse(r, HttpStatus.forbidden, 'Not yours.');
    }
    if (!_allowed(b.by)) return _refuse(r, HttpStatus.tooManyRequests, 'Slow down.');
    b.writing = true;
    final file = _blobFile(s.id, b.id, part: true);
    RandomAccessFile? raf;
    var written = 0;
    var tooMuch = false;
    final hash = Sha256();
    try {
      raf = await file.open(mode: FileMode.append);
      await raf.truncate(offset);
      await raf.setPosition(offset);
      await for (final piece in r.timeout(bodyPause)) {
        if (written + piece.length > config.maxBody || offset + written + piece.length > b.size) {
          tooMuch = true;
          break;
        }
        hash.add(piece);
        await raf.writeFrom(piece);
        written += piece.length;
      }
      final got = tooMuch ? null : hexOf(hash.close());
      // Checked before (said up front): what came must be what was signed for. Else the signature over what came.
      final ok = got != null && (saidSha != null ? got == saidSha : _who(r, got)?.id == b.by);
      if (!ok) {
        await raf.truncate(offset);
        await raf.close();
        raf = null;
        b.writing = false;
        if (tooMuch) return await _refuse(r, HttpStatus.requestEntityTooLarge, 'More than the file was said to be.');
        return await (saidSha != null ? _refuse(r, HttpStatus.badRequest, 'The body isn\'t what its hash said.') : _refuse(r, HttpStatus.unauthorized, 'Bad signature.'));
      }
      await raf.flush();
      await raf.close();
      raf = null;
      b.writing = false;
      // Removed meanwhile (the space, or the blob): nothing to keep, and no save to bring it back.
      if (s.removed || s.blobs[b.id] != b) return await _refuse(r, HttpStatus.notFound, 'No such file.');
      b.have = offset + written;
      b.at = _now().millisecondsSinceEpoch;
      _saveSoon(s);
      return await _answer(r, HttpStatus.ok, {'have': b.have});
    } catch (err) {
      // Cut short (the phone lost its connection): the piece is cut back off, so what is kept always ends where a whole
      // piece did, at a chunk's edge, which the next try starts from.
      try {
        await raf?.truncate(offset);
        await raf?.close();
      } catch (_) {}
      b.have = offset;
      b.writing = false;
      rethrow;
    }
  }

  /// Forgets [b], gives back the room it was promised and deletes its file, finished or part. The caller saves.
  void _dropBlob(_Space s, _Blob b) {
    s.blobs.remove(b.id);
    s.used -= b.size;
    _used -= b.size;
    for (final f in [_blobFile(s.id, b.id), _blobFile(s.id, b.id, part: true)]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// Removes the space [s] and its whole folder; [why] is only for the log line.
  void _remove(_Space s, String why) {
    _spaces.remove(s.id);
    s.removed = true;
    s.saver?.cancel();
    _used -= s.used;
    try {
      _dirOf(s.id).deleteSync(recursive: true);
    } catch (_) {}
    _say('${s.id.substring(0, 6)} $why');
  }

  /// Blobs left unfinished for [FilesConfig.partLife], and spaces nobody has opened for [FilesConfig.idleLife].
  Future<void> sweep() async {
    final now = _now();
    final cutoff = now.subtract(config.idleLife).toUtc().toIso8601String().substring(0, 10);
    final stale = now.subtract(config.partLife).millisecondsSinceEpoch;
    for (final s in _spaces.values.toList()) {
      if (s.day.compareTo(cutoff) < 0) {
        _remove(s, 'unused');
        continue;
      }
      // A room promised and never given a byte goes after ten minutes; one with some, after [FilesConfig.partLife].
      final empty = now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
      final old = s.blobs.values.where((b) => !b.done && !b.writing && (b.at < stale || (b.have == 0 && b.at < empty))).toList();
      for (final b in old) {
        _dropBlob(s, b);
      }
      if (old.isNotEmpty) _saveNow(s);
    }
    final oldest = now.subtract(skew * 2).millisecondsSinceEpoch;
    _replays.removeWhere((_, at) => at < oldest);
  }
}

/// What the files store may hold, from the environment where it is set (`GHOST_FILES_*`, tool/deploy-relay.mjs).
class FilesConfig {
  const FilesConfig({
    // 50 GB a file as the app shows sizes (decimal), with room for its sealing (16 bytes a 256 KiB chunk, about 3.1 MB)
    // (Matt, 2026-11-17: "Bump the upload limit to 50GB"); a space holds two of them, the store about half the box's
    // free disk (640 GB that day).
    this.maxFile = 50000000000 + (4 << 20),
    // A space holds 50 GB while this is an alpha, the Alpha testers' too; OnlyGhosts' spaces ([roomy]: its Files and its
    // Recordings) hold 256 GB between them, and every space together 400 GB, which leaves the box over 150 GB of its own
    // (Matt, 2026-11-25: "Let's stick with 256gb for the onlyGhosts server and leave the rest of them including alpha to
    // 50gb"; 514 GB free that day, 52 GB of it Files').
    this.spaceQuota = 50000000000,
    this.roomyQuota = 256000000000,
    this.roomy = const {'ecf77f9db9ba82ef2d2ea508e657f36c', '78d09c1c0d49291a6f4b716b1a2ee200'},
    this.total = 400000000000,
    this.spacesPerId = 20,
    this.idleDays = 90,
    this.writesPerMinute = 600,
    this.maxBody = 8 << 20,
    this.maxOp = 32 << 10,
    this.maxOps = 20000,
    this.maxLogBytes = 16 << 20,
    this.maxBlobs = 10000,
    this.maxSpaces = 100000,
    this.partHours = 24,
    this.spacesPerAddress = 20,
    // Room promised to uploads not yet written, per address: one whole 50 GB file and some.
    this.promisedPerAddress = 60000000000,
  });

  /// The largest blob (a sealed file: its size and 16 bytes a chunk), in bytes.
  final int maxFile;

  /// What one space may hold, in bytes.
  final int spaceQuota;

  /// What the spaces in [roomy] (by their ids) may hold between them, in place of [spaceQuota] each.
  final int roomyQuota;
  final Set<String> roomy;

  /// What every space together may hold, in bytes: the box's disk is shared with everything else on it.
  final int total;

  /// How many spaces one device's key may make.
  final int spacesPerId;

  /// [idleDays]: days a space may go unopened before it is removed. [writesPerMinute]: signed writes one device's key
  /// may make in a minute, across every space.
  final int idleDays;
  final int writesPerMinute;

  /// The most one request may carry: a file goes up as a run of pieces no bigger than this.
  final int maxBody;

  /// The largest sealed operation in a space's log: room for a file's description with its small picture (at most
  /// 18 KB, about 24 KB as base64) and no more.
  final int maxOp;

  /// The most operations a space's log may hold.
  final int maxOps;

  /// The most a space's log may hold on disk, in bytes; it counts against [spaceQuota] and [total] too.
  final int maxLogBytes;

  /// How many spaces one address may make in a day, and how many bytes of unfinished files it may have promised.
  final int spacesPerAddress;
  final int promisedPerAddress;

  /// [maxBlobs]: the most files in one space, finished or not. [maxSpaces]: the most spaces in all. [partHours]:
  /// hours an unfinished file may go without a new piece before it is let go.
  final int maxBlobs;
  final int maxSpaces;
  final int partHours;

  Duration get idleLife => Duration(days: idleDays);
  Duration get partLife => Duration(hours: partHours);

  /// Every limit from its `GHOST_FILES_*` name where it is set to a whole number above nought, else as it was
  /// (tool/deploy-relay.mjs's KNOWN lists the same names): Matt, 2026-11-17: "Finish the missing pieces that went
  /// unfinished": the limits added after the first review had defaults only.
  factory FilesConfig.fromEnvironment(Map<String, String> env) {
    int read(String name, int fallback) {
      final v = int.tryParse(env[name]?.trim() ?? '');
      return v == null || v <= 0 ? fallback : v;
    }

    const d = FilesConfig();
    return FilesConfig(
      maxFile: read('GHOST_FILES_MAX_FILE', d.maxFile),
      spaceQuota: read('GHOST_FILES_SPACE_QUOTA', d.spaceQuota),
      roomyQuota: read('GHOST_FILES_ROOMY_QUOTA', d.roomyQuota),
      roomy: {...d.roomy, for (final id in (env['GHOST_FILES_ROOMY_SPACES'] ?? '').split(',')) if (RegExp(r'^[0-9a-f]{32}$').hasMatch(id.trim())) id.trim()},
      total: read('GHOST_FILES_TOTAL', d.total),
      spacesPerId: read('GHOST_FILES_SPACES_PER_ID', d.spacesPerId),
      idleDays: read('GHOST_FILES_IDLE_DAYS', d.idleDays),
      writesPerMinute: read('GHOST_FILES_WRITES_PER_MINUTE', d.writesPerMinute),
      // A piece may not be bigger than Caddy lets through (tool/deploy-site.mjs's request_body, 10 MiB).
      maxBody: min(read('GHOST_FILES_MAX_BODY', d.maxBody), 10 << 20),
      maxOp: read('GHOST_FILES_MAX_OP', d.maxOp),
      maxOps: read('GHOST_FILES_MAX_OPS', d.maxOps),
      maxLogBytes: read('GHOST_FILES_MAX_LOG_BYTES', d.maxLogBytes),
      maxBlobs: read('GHOST_FILES_MAX_BLOBS', d.maxBlobs),
      maxSpaces: read('GHOST_FILES_MAX_SPACES', d.maxSpaces),
      partHours: read('GHOST_FILES_PART_HOURS', d.partHours),
      spacesPerAddress: read('GHOST_FILES_SPACES_PER_ADDRESS', d.spacesPerAddress),
      promisedPerAddress: read('GHOST_FILES_PROMISED_PER_ADDRESS', d.promisedPerAddress),
    );
  }

  /// The names [FilesConfig.fromEnvironment] reads.
  static const names = [
    'GHOST_FILES_MAX_FILE',
    'GHOST_FILES_SPACE_QUOTA',
    'GHOST_FILES_TOTAL',
    'GHOST_FILES_SPACES_PER_ID',
    'GHOST_FILES_IDLE_DAYS',
    'GHOST_FILES_WRITES_PER_MINUTE',
    'GHOST_FILES_MAX_BODY',
    'GHOST_FILES_MAX_OP',
    'GHOST_FILES_MAX_OPS',
    'GHOST_FILES_MAX_LOG_BYTES',
    'GHOST_FILES_MAX_BLOBS',
    'GHOST_FILES_MAX_SPACES',
    'GHOST_FILES_PART_HOURS',
    'GHOST_FILES_SPACES_PER_ADDRESS',
    'GHOST_FILES_PROMISED_PER_ADDRESS',
  ];
}

/// Whoever signed a write, once the signature has checked out.
class _Who {
  _Who(this.id, this.key);

  /// The hub name of the key, and the key in hex.
  final String id;
  final String key;
}

/// One Files space as the relay knows it: what meta.json keeps, and what is worked out while it runs.
class _Space {
  _Space({required this.id, required this.hash, required this.owner, required this.by, required this.created, required this.day, this.seq = 0});
  final String id;

  /// SHA-256 of its token, in hex.
  final String hash;

  /// The owner's public key (hex), who may remove anyone's file; empty until the owner opens it themselves.
  String owner;

  /// The hub name of the device that made it.
  final String by;
  final int created;

  /// The day (UTC) it was last opened.
  String day;

  /// [seq]: the number of the last entry in its log (its count of lines). [used]: bytes it holds or has promised,
  /// its blobs' sizes and its log, held under [FilesConfig.spaceQuota].
  int seq;
  int used = 0;

  /// How many bytes its log holds (counted in [used] too).
  int logBytes = 0;

  /// Where every few lines of its log start (Files._marksOf); null until a page is first read.
  List<int>? marks;

  /// The newest roster version this space has believed ([Files._rosterOf], [Files._learn]); an older one is refused.
  /// With the SHA-256 of that version's signed bytes (another roster at the same version is refused) and its admins,
  /// who alone besides the owner may sign the next ([Files._rosterOf]); null where not known. Kept.
  int rosterV = 0;
  String? rosterH;
  Set<String>? admins;

  /// The last roster checked, and what it was (the hash of its signature and bytes), so it isn't checked again.
  FilesRoster? roster;
  String? rosterSaid;

  /// Taken away: a save still to come does nothing.
  bool removed = false;

  /// The entry being added to its log, which the next waits for ([Files._handle]).
  Future<void> appending = Future.value();
  final Map<String, _Blob> blobs = {};
  Timer? saver;

  Map<String, Object?> toJson() => {
        'v': 1,
        'h': hash,
        'o': owner,
        'by': by,
        'c': created,
        'd': day,
        'seq': seq,
        if (rosterV > 0) 'rv': rosterV,
        'rh': ?rosterH,
        if (admins != null) 'ad': admins!.toList()..sort(),
        'blobs': [for (final b in blobs.values) b.toJson()],
      };

  factory _Space.fromJson(String id, Map j) {
    final s = _Space(id: id, hash: j['h'] as String, owner: (j['o'] as String?) ?? '', by: (j['by'] as String?) ?? '', created: (j['c'] as num?)?.toInt() ?? 0, day: j['d'] as String, seq: (j['seq'] as num?)?.toInt() ?? 0)
      ..rosterV = (j['rv'] as num?)?.toInt() ?? 0
      ..rosterH = j['rh'] is String ? j['rh'] as String : null
      ..admins = j['ad'] is List ? {for (final a in j['ad'] as List) '$a'} : null;
    for (final b in (j['blobs'] as List? ?? const [])) {
      final blob = _Blob.fromJson(b as Map);
      s.blobs[blob.id] = blob;
      s.used += blob.size;
    }
    return s;
  }
}

/// One sealed file in a space. [by] is the hub name of whoever started it, [size] what it was said to be, [have] how
/// many bytes are on disk, [done] whether it was finished (and so may be read), [writing] whether a piece is arriving.
class _Blob {
  _Blob({required this.id, required this.by, required this.size, required this.at, this.have = 0, this.done = false, this.pre = false});
  final String id;
  final String by;
  final int size;
  int have;
  bool done;

  /// When it was last written to (ms): one being written that has gone quiet for a day is let go.
  int at;
  bool writing = false;

  /// Started by a newer app, whose every piece says its hash up front ([Files._writeBlob]). Kept.
  final bool pre;

  /// The address its room was asked for from (not kept: it only limits what one address has going).
  String ip = '';

  Map<String, Object?> toJson() => {'id': id, 'by': by, 'z': size, 'h': have, if (done) 'done': 1, 'at': at, if (pre) 'pre': 1};
  factory _Blob.fromJson(Map j) =>
      _Blob(id: j['id'] as String, by: j['by'] as String, size: (j['z'] as num).toInt(), have: (j['h'] as num?)?.toInt() ?? 0, done: j['done'] == 1, at: (j['at'] as num?)?.toInt() ?? 0, pre: j['pre'] == 1);
}
