import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the hub keeps for people who are away, on disk, so a restart doesn't lose it (GMFB-24: "Waiting packets survive
/// a hub restart (store them on disk, still sealed)"). Only where its keeper switched it on (hub.dart, `keepHeld`;
/// `GHOST_HUB_KEEP_HELD=1`): off, nothing here is made or read and the hub holds everything in memory, as before.
///
/// Two kinds of thing are kept, each exactly as the hub holds it in memory: a packet held for someone away (the sealed
/// bytes as the hub stamped them, with who it is for, when it came, and which of the sender's own devices sent it where
/// it was to their own name), and a packet a room keeps for whoever joins later (the sealed bytes, the room, the hash
/// of its token, when it came). Nothing else: no address, no name, nothing the hub can open.
///
/// **How it is written.** Append-only files (segments, `seg-<n>.log`, at most about [segmentBytes] each) of records,
/// each its length, a CRC-32 of it, then it: a thing kept (`add`, with a number of its own), or a thing gone (`drop`, by
/// that number: handed over, expired, or pushed out by a limit). Records wait in memory and are written together every
/// [flushEvery] (or as the hub stops), so a packet held costs the hot path a copy into a list, and a packet to someone
/// who is here is never written at all. A process killed at any moment leaves at most the last [flushEvery] of records
/// unwritten and at most one record half written, which reading drops: the length and checksum find where a file was
/// torn, and everything before it stands.
///
/// **How it stays small.** The oldest segment is written again into the newest whenever the files hold more than
/// twice what still stands plus [slack] (or the oldest holds nothing that stands): what still stands in it is appended
/// again under the same numbers, made sure of on disk, and only then is the old file deleted. A copy read twice (the
/// relay stopped between the copy and the delete) is the same thing twice, kept once. Always the oldest, so a `drop`
/// never outlives the `add` it takes away.
///
/// A write that fails (a full disk) turns the store off with a line on stderr: the hub goes on holding in memory.
class HeldStore {
  HeldStore(this.dir, {this.segmentBytes = 8 << 20, this.flushEvery = const Duration(milliseconds: 200), this.slack = 16 << 20});

  final Directory dir;
  final int segmentBytes;
  final Duration flushEvery;
  final int slack;

  /// The longest record read: a packet as long as the hub takes one ([maxPacket] and what the hub puts in front), and
  /// what is kept with it.
  static const maxPacket = 64 * 1024 + 64;
  static const _maxRecord = maxPacket + 512;
  static const _magic = 'GHHELD01';

  static const _add = 1, _keep = 2, _drop = 3;

  /// What stands, by number, and in which segment each is written.
  final Map<int, ({int seg, int size, StoredHeld item})> _live = {};
  final SplayTreeMap<int, int> _segBytes = SplayTreeMap();
  final Map<int, Set<int>> _inSeg = {};
  int _liveBytes = 0;
  int _next = 1;
  int _cur = 0;

  final List<({int seg, Uint8List bytes})> _pending = [];
  RandomAccessFile? _raf;
  int _rafSeg = -1;
  Timer? _timer;
  bool _compacting = false;
  bool _closed = false;
  bool _broken = false;
  bool _loaded = false;

  /// When the hub that last stopped cleanly had started, where it said so as it stopped ([close]); null after a crash,
  /// or where the store is new. Read once, by [load].
  int? cleanSince;

  /// How many things stand, their bytes as written, and the bytes of every segment on disk: for a test, and for what
  /// the store says it uses.
  int get live => _live.length;
  int get liveBytes => _liveBytes;
  int get diskBytes => _segBytes.values.fold(0, (n, b) => n + b);
  int get segments => _segBytes.length;

  /// Whether writes have stopped for a failure ([HeldStore] above); the hub then holds in memory alone.
  bool get broken => _broken;

  /// Whether nothing waits to be written and no old segment is being written again, for a test to wait on.
  bool get idle => _pending.isEmpty && _timer == null && !_compacting;

  /// Whether an old segment is being written again and deleted ([_maybeCompact]), for a test to wait on.
  bool get compacting => _compacting;

  File _segFile(int n) => File('${dir.path}/seg-${n.toString().padLeft(8, '0')}.log');
  File get _cleanFile => File('${dir.path}/clean.json');

  /// Reads everything kept, in the order it was kept, and starts a segment of its own to write to. A torn or unreadable
  /// end of a segment is passed over, never fatal.
  List<StoredHeld> load() {
    _loaded = true;
    try {
      dir.createSync(recursive: true);
    } catch (e) {
      _fail('could not make ${dir.path}: $e');
      return const [];
    }
    try {
      final clean = _cleanFile;
      if (clean.existsSync()) {
        final m = jsonDecode(clean.readAsStringSync());
        if (m is Map && m['since'] is int) cleanSince = m['since'] as int;
        clean.deleteSync();
      }
    } catch (_) {
      cleanSince = null;
    }
    final found = <int>[];
    for (final f in dir.listSync()) {
      final name = f.uri.pathSegments.last;
      final m = RegExp(r'^seg-(\d{8})\.log$').firstMatch(name);
      if (f is File && m != null) found.add(int.parse(m.group(1)!));
    }
    found.sort();
    for (final seg in found) {
      Uint8List bytes;
      try {
        bytes = _segFile(seg).readAsBytesSync();
      } catch (_) {
        bytes = Uint8List(0);
      }
      _segBytes[seg] = bytes.length;
      _inSeg[seg] = {};
      replay(bytes, (seq, item, size) {
        if (seq >= _next) _next = seq + 1;
        _forget(seq);
        if (item != null) _stand(seq, seg, size, item);
      });
    }
    _cur = (found.isEmpty ? 0 : found.last) + 1;
    _startSegment();
    final out = [for (final l in _live.values) l.item]..sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  /// Plays the records of one segment's [bytes]: [each] is told every number, with what it keeps (null for a drop) and
  /// the bytes its record took. Stops at the first record that is torn or doesn't check out, and says how far it read.
  static int replay(Uint8List bytes, void Function(int seq, StoredHeld? item, int size) each) {
    if (bytes.length < _magic.length || ascii.decode(bytes.sublist(0, _magic.length), allowInvalid: true) != _magic) return 0;
    final view = ByteData.sublistView(bytes);
    var off = _magic.length;
    while (off + 8 <= bytes.length) {
      final len = view.getUint32(off), crc = view.getUint32(off + 4);
      if (len < 9 || len > _maxRecord || off + 8 + len > bytes.length) break;
      final payload = Uint8List.sublistView(bytes, off + 8, off + 8 + len);
      if (crc32(payload) != crc) break;
      final decoded = _decode(payload);
      if (decoded == null) break;
      each(decoded.seq, decoded.item, 8 + len);
      off += 8 + len;
    }
    return off;
  }

  static ({int seq, StoredHeld? item})? _decode(Uint8List p) {
    final v = ByteData.sublistView(p);
    final kind = p[0], seq = v.getInt64(1);
    if (seq <= 0) return null;
    if (kind == _drop) return p.length == 9 ? (seq: seq, item: null) : null;
    if (p.length < 17) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(v.getInt64(9));
    if (kind == _add) {
      if (p.length < 17 + 16 + 2) return null;
      final to = _hexOf(p, 17, 16);
      final devLen = v.getUint16(33);
      if (p.length < 35 + devLen) return null;
      final dev = devLen == 0 ? null : utf8.decode(p.sublist(35, 35 + devLen), allowMalformed: true);
      return (seq: seq, item: StoredHeld.mail(seq, at, to, dev, Uint8List.fromList(p.sublist(35 + devLen))));
    }
    if (kind == _keep) {
      if (p.length < 17 + 1 + 16 + 32) return null;
      final room = '${p[17] == 1 ? 'ro:' : ''}${_hexOf(p, 18, 16)}';
      final hash = _hexOf(p, 34, 32);
      return (seq: seq, item: StoredHeld.kept(seq, at, room, hash, Uint8List.fromList(p.sublist(66))));
    }
    return null;
  }

  static const _digits = '0123456789abcdef';

  static String _hexOf(Uint8List b, int from, int n) {
    final out = Uint8List(2 * n);
    for (var i = 0; i < n; i++) {
      out[2 * i] = _digits.codeUnitAt(b[from + i] >> 4);
      out[2 * i + 1] = _digits.codeUnitAt(b[from + i] & 15);
    }
    return String.fromCharCodes(out);
  }

  static int _nibble(int c) => c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x57;

  static void _putHex(Uint8List into, int at, String hex) {
    for (var i = 0; i + 1 < hex.length; i += 2) {
      into[at + i ~/ 2] = (_nibble(hex.codeUnitAt(i)) << 4) | _nibble(hex.codeUnitAt(i + 1));
    }
  }

  static Uint8List _encode(int kind, int seq, StoredHeld? item) {
    Uint8List p;
    if (item == null) {
      p = Uint8List(9);
    } else if (item.isMail) {
      final dev = item.byDevice == null ? const <int>[] : utf8.encode(item.byDevice!);
      p = Uint8List(35 + dev.length + item.frame.length);
      _putHex(p, 17, item.to!);
      ByteData.sublistView(p).setUint16(33, dev.length);
      p.setRange(35, 35 + dev.length, dev);
      p.setRange(35 + dev.length, p.length, item.frame);
    } else {
      p = Uint8List(66 + item.frame.length);
      final room = item.room!;
      p[17] = room.startsWith('ro:') ? 1 : 0;
      _putHex(p, 18, room.startsWith('ro:') ? room.substring(3) : room);
      _putHex(p, 34, item.hash!);
      p.setRange(66, p.length, item.frame);
    }
    p[0] = kind;
    final v = ByteData.sublistView(p)..setInt64(1, seq);
    if (item != null) v.setInt64(9, item.at.millisecondsSinceEpoch);
    final out = Uint8List(8 + p.length);
    ByteData.sublistView(out)
      ..setUint32(0, p.length)
      ..setUint32(4, crc32(p));
    out.setRange(8, out.length, p);
    return out;
  }

  void _stand(int seq, int seg, int size, StoredHeld item) {
    _live[seq] = (seg: seg, size: size, item: item);
    (_inSeg[seg] ??= {}).add(seq);
    _liveBytes += size;
  }

  void _forget(int seq) {
    final was = _live.remove(seq);
    if (was == null) return;
    _inSeg[was.seg]?.remove(seq);
    _liveBytes -= was.size;
  }

  bool get _writing => _loaded && !_closed && !_broken;

  /// Keeps a packet held for [to] (32 hex digits) since [at]; [byDevice] for one an identity sent to its own name.
  /// Its number, for [drop]; 0 where the store isn't writing.
  int addMail(String to, DateTime at, String? byDevice, Uint8List frame) => _add_(StoredHeld.mail(0, at, to, byDevice, frame), _add);

  /// Keeps a packet the room kept under [room] (32 hex digits, `ro:` in front for a read-only room's) with the hash of
  /// its token [hash] (64 hex digits) since [at].
  int addKept(String room, String hash, DateTime at, Uint8List frame) => _add_(StoredHeld.kept(0, at, room, hash, frame), _keep);

  int _add_(StoredHeld item, int kind) {
    if (!_writing || item.frame.length > maxPacket) return 0;
    final seq = _next++;
    final stored = item.withSeq(seq);
    final bytes = _encode(kind, seq, stored);
    final seg = _enqueue(bytes);
    _stand(seq, seg, bytes.length, stored);
    return seq;
  }

  /// [seq] is gone: handed over, expired, or pushed out.
  void drop(int seq) {
    if (seq <= 0 || !_live.containsKey(seq)) return;
    _forget(seq);
    if (_writing) _enqueue(_encode(_drop, seq, null));
  }

  int _enqueue(Uint8List bytes) {
    final have = _segBytes[_cur] ?? 0;
    if (have > _magic.length && have + bytes.length > segmentBytes) {
      _cur++;
      _startSegment();
    }
    _pending.add((seg: _cur, bytes: bytes));
    _segBytes[_cur] = (_segBytes[_cur] ?? 0) + bytes.length;
    _timer ??= Timer(flushEvery, _tick);
    return _cur;
  }

  void _startSegment() {
    final head = Uint8List.fromList(ascii.encode(_magic));
    _inSeg[_cur] = {};
    _pending.add((seg: _cur, bytes: head));
    _segBytes[_cur] = head.length;
  }

  void _tick() {
    _timer = null;
    flushNow();
    _maybeCompact();
  }

  /// Writes what waits, now (no fsync: what is written survives the process being killed; [close] makes sure of it
  /// on disk).
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    if (_broken || _pending.isEmpty) return;
    try {
      // Together, a megabyte a write at most: one call for many small records.
      final run = BytesBuilder(copy: true);
      void out() {
        if (run.isEmpty) return;
        _raf!.writeFromSync(run.takeBytes());
      }

      for (final p in _pending) {
        if (p.seg != _rafSeg) {
          out();
          _raf?.closeSync();
          _raf = _segFile(p.seg).openSync(mode: FileMode.append);
          _rafSeg = p.seg;
        }
        run.add(p.bytes);
        if (run.length >= 1 << 20) out();
      }
      out();
      _pending.clear();
    } catch (e) {
      _fail('could not write: $e');
    }
  }

  void _fail(String why) {
    if (_broken) return;
    _broken = true;
    _pending.clear();
    stderr.writeln('relay: what is held for people away is kept in memory only from now: $why');
  }

  /// Writes the oldest segment again into the newest while the files hold far more than stands (see [HeldStore]).
  void _maybeCompact() {
    if (_compacting || !_writing) return;
    final sealed = _segBytes.keys.where((s) => s != _cur).toList();
    if (sealed.isEmpty) return;
    final oldest = sealed.first;
    final standing = _inSeg[oldest] ?? const <int>{};
    if (standing.isNotEmpty && diskBytes <= 2 * _liveBytes + slack) return;
    _compacting = true;
    for (final seq in standing.toList()) {
      final l = _live[seq]!;
      final bytes = _encode(l.item.isMail ? _add : _keep, seq, l.item);
      _forget(seq);
      _stand(seq, _enqueue(bytes), bytes.length, l.item);
    }
    flushNow();
    unawaited(_retire(oldest));
  }

  /// Makes sure of the copies on disk, then deletes the old segment.
  Future<void> _retire(int oldest) async {
    try {
      for (final s in _segBytes.keys.where((s) => s > oldest).toList()) {
        final f = await _segFile(s).open(mode: FileMode.append);
        await f.flush();
        await f.close();
      }
      if (_closed || _broken) return;
      await _segFile(oldest).delete();
      _segBytes.remove(oldest);
      _inSeg.remove(oldest);
    } catch (e) {
      // Left for the next look: a delete that failed leaves a segment read again, which is harmless.
    } finally {
      _compacting = false;
    }
    if (!_closed) _maybeCompact();
  }

  /// Writes what waits, makes sure of it on disk, and closes. [since] is when the hub started, said where nothing it
  /// held lived in memory alone: read by the next [load] ([cleanSince]), so a clean restart says it kept everything.
  void close({int? since}) {
    if (_closed || !_loaded) return;
    flushNow();
    _closed = true;
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    if (since != null && !_broken) {
      try {
        final tmp = File('${_cleanFile.path}.tmp');
        tmp.writeAsStringSync(jsonEncode({'since': since}), flush: true);
        tmp.renameSync(_cleanFile.path);
      } catch (_) {}
    }
  }

  static final Uint32List _table = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }();

  /// CRC-32 (the one zip and PNG use) of [bytes].
  static int crc32(List<int> bytes) {
    var c = 0xFFFFFFFF;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}

/// One thing the store keeps, as it is read back: a packet held for someone ([to]) or one a room keeps ([room]).
class StoredHeld {
  StoredHeld.mail(this.seq, this.at, String this.to, this.byDevice, this.frame)
      : room = null,
        hash = null;
  StoredHeld.kept(this.seq, this.at, String this.room, String this.hash, this.frame)
      : to = null,
        byDevice = null;

  final int seq;
  final DateTime at;
  final String? to, byDevice, room, hash;
  final Uint8List frame;
  bool get isMail => to != null;

  StoredHeld withSeq(int n) => isMail ? StoredHeld.mail(n, at, to!, byDevice, frame) : StoredHeld.kept(n, at, room!, hash!, frame);
}
