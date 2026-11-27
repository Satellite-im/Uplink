import 'dart:async';
import 'dart:io';
import '../aside.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';
import '../net/file_seal.dart';
import 'files_api.dart';
import 'files_model.dart';
import 'files_store.dart' show markFromInternet, shaOfFile;

/// The sealed bytes [start] to [end] (inclusive) of a file's blob on the relay, as they come: FilesApi.read in the app.
typedef SealedRead = Future<Stream<List<int>>> Function(int start, int end);

/// Something a player can be pointed at before the whole of it is here (lib/ui/video_screen.dart): an address to play
/// from, how much of it is already on this device, and the whole file when another app needs it.
abstract class StreamedMedia {
  /// The address the player opens. Throws a [FilesError] where it can't be served.
  Future<String> open();

  /// The parts already on this device, each as fractions of the whole (start, end): shown on the scrubber where the
  /// player says nothing of its own buffer.
  List<(double, double)> held();

  /// Told whenever [held] grows or the stream fails.
  Listenable get changes;

  /// Why it stopped serving (the relay away, a chunk that didn't open), or null.
  String? get failure;

  /// The whole file on this device (for another app to open), brought down where it isn't; [progress] says how many
  /// plain bytes are here as it comes.
  Future<String> whole(void Function(int done, int size) progress);

  /// Let go by whoever was given it.
  void close();
}

/// A Files-space file served to the app's own player as it comes down (Matt, 2026-11-18: "do we need to download the
/// whole file to play? would it be possible to setup streaming and buffering of the file?", then "yes build it"; a
/// big MKV had seemed to "load forever in the app" while it came down whole before playing).
///
/// - A small HTTP server on 127.0.0.1, on a port the system picks, answers only paths that start with a random token
///   of 128 bits made for this stream: another app on the device can reach the port, but can't guess the address.
/// - It answers Range requests (206, Content-Range, HEAD) as any file server does, so ExoPlayer, AVFoundation and
///   libmpv seek in it as they would in a file on a website. For each range it works out which sealed chunks
///   (lib/net/file_seal.dart) hold those bytes, asks the relay for only those with a ranged read, opens each here (its
///   tag checked, so a changed, moved or short chunk is refused, never played), and writes out the plain slice. The
///   relay sees what it always has: sealed chunks.
/// - Each chunk opened is kept on disk beside the app's downloads (`<id>.stream`, written in the order chunks come,
///   with `<id>.chunks` saying where each is), so seeking back or watching again asks for nothing. A few megabytes
///   past where the player is are fetched ahead of it ([readAhead]).
/// - Once every chunk is here the file is put together as the ordinary download (FilesStore.cachedPath), checked
///   against its SHA-256 as a download is, so Save and Open use it afterwards without bringing it down again.
/// - Kept partial files are bounded ([partialLimit] across the others, and none older than [partialAge]): the oldest
///   go first, as a new stream starts.
class FileStream implements StreamedMedia {
  FileStream({
    required this.file,
    required this.cacheDir,
    required this.assembledPath,
    required SealedRead read,
    this.readAhead = 8 << 20,
    this.runChunks = 16,
    this.partialLimit = 1 << 30,
    this.partialAge = const Duration(days: 14),
    this.onWhole,
    this.onClosed,
  }) : _read = read;

  final SpaceFile file;
  final Directory cacheDir;

  /// Where the whole file goes once put together: the store's ordinary download.
  final String assembledPath;
  final SealedRead _read;

  /// How far past where the player is reading to fetch before it asks: 8 MB is a few seconds of a big video, and a
  /// couple of requests to the relay.
  final int readAhead;

  /// The most chunks asked of the relay in one request (16 is 4 MB): fewer round trips, still soon to start.
  final int runChunks;

  /// The bytes other files' partial streams may keep on disk, and how old one may be, before it is let go.
  final int partialLimit;
  final Duration partialAge;

  /// Told once the file is whole on the device (the store lets its list know), and once it is let go.
  final void Function(String path)? onWhole;
  final VoidCallback? onClosed;

  // A chunk's plain size and how many the file has; then where the chunks opened so far are kept, and the index
  // that says which slot each is in.
  int get _chunk => file.chunk;
  int get _count => FileSeal.chunks(file.size, chunkSize: _chunk);
  String get dataPath => '${cacheDir.path}/${file.id}.stream';
  String get indexPath => '${cacheDir.path}/${file.id}.chunks';

  final _changes = _Changes();
  @override
  Listenable get changes => _changes;

  String? _failure;
  @override
  String? get failure => _failure;

  /// Where each chunk is in the data file (its slot), or -1 while it isn't here.
  Int32List? _slots;

  // The next free slot in the data file, how many chunks are here, and the two files while they are open.
  int _nextSlot = 0;
  int _have = 0;
  RandomAccessFile? _data;
  RandomAccessFile? _index;

  /// The whole file, once it is: read from there from then on, chunk i at slot i.
  String? _whole;
  Future<void>? _loaded;
  Future<void>? _assembling;

  /// Chunks on their way: done once each is on disk.
  final Map<int, Future<void>> _coming = {};

  /// File work one thing at a time: a chunk written, read, or the whole put together.
  Future<void> _lock = Future.value();
  Future<T> _locked<T>(Future<T> Function() work) {
    final next = _lock.then((_) => work());
    _lock = next.then((_) {}, onError: (_) {});
    return next;
  }

  // The local server and the secret first part of its paths, once [open] has made them.
  HttpServer? _server;
  String? _token;

  // How many hold the stream ([hold], [close]) and how many [whole]s are under way: it shuts once both are none.
  int _users = 1;
  int _wholes = 0;
  bool _closed = false;
  bool get closed => _closed;

  /// How many requests the relay has been sent, for a test.
  @visibleForTesting
  int fetches = 0;

  /// Held once more: let go with [close] as many times.
  void hold() => _users++;

  // --- what is here --------------------------------------------------------------------------------------------------

  /// Finds what is on this device, once: the whole file where it came down before, else what an earlier stream of it
  /// kept.
  Future<void> _load() => _loaded ??= _loadNow();

  Future<void> _loadNow() async {
    final n = _count;
    if (File(assembledPath).existsSync()) {
      await _useWhole(assembledPath);
      return;
    }
    await cacheDir.create(recursive: true);
    final slots = Int32List(n)..fillRange(0, n, -1);
    final index = File(indexPath), data = File(dataPath);
    // What an earlier look at it kept, where both halves are there and the index is the right size for this file.
    if (index.existsSync() && data.existsSync() && index.lengthSync() == n * 4) {
      final bytes = index.readAsBytesSync();
      final view = ByteData.sublistView(bytes);
      final length = data.lengthSync();
      for (var i = 0; i < n; i++) {
        final s = view.getInt32(i * 4, Endian.little);
        // A slot the data file doesn't reach to was never written whole: it isn't here.
        if (s >= 0 && s * _chunk + FileSeal.plainLength(i, file.size, chunkSize: _chunk) <= length) slots[i] = s;
      }
    } else {
      _deleteQuietly(indexPath);
      _deleteQuietly(dataPath);
    }
    _slots = slots;
    _have = slots.where((s) => s >= 0).length;
    _nextSlot = slots.isEmpty ? 0 : slots.reduce(math.max) + 1;
    _data = await data.open(mode: FileMode.append);
    _index = await index.open(mode: FileMode.append);
    if (await _index!.length() != n * 4) {
      await _index!.truncate(0);
      await _index!.setPosition(0);
      final fill = ByteData(n * 4);
      for (var i = 0; i < n; i++) {
        fill.setInt32(i * 4, slots[i], Endian.little);
      }
      await _index!.writeFrom(fill.buffer.asUint8List());
    }
    // Touched, so the oldest kept streams go first, and others' kept beyond the bound go now.
    try {
      data.setLastModifiedSync(DateTime.now());
    } catch (_) {}
    unawaited(Future(() => evict(cacheDir, keep: {file.id}, limit: partialLimit, age: partialAge)));
    if (_have == n) await _assemble();
  }

  /// Reads from the finished file at [path] from now on: every chunk is here, chunk i at slot i.
  Future<void> _useWhole(String path) async {
    _whole = path;
    final n = _count;
    _slots = Int32List.fromList(List.generate(n, (i) => i));
    _have = n;
    _nextSlot = n;
    await _data?.close();
    await _index?.close();
    _index = null;
    _data = await File(path).open();
  }

  bool _here(int i) => _slots![i] >= 0;

  @override
  List<(double, double)> held() {
    final slots = _slots;
    if (slots == null || file.size <= 0) return const [];
    final parts = <(double, double)>[];
    int? from;
    for (var i = 0; i <= slots.length; i++) {
      final here = i < slots.length && slots[i] >= 0;
      if (here && from == null) from = i;
      if (!here && from != null) {
        parts.add((math.min(1.0, from * _chunk / file.size), math.min(1.0, i * _chunk / file.size)));
        from = null;
      }
    }
    return parts;
  }

  /// How many plain bytes are here.
  int get haveBytes {
    final slots = _slots;
    if (slots == null) return 0;
    var n = 0;
    for (var i = 0; i < slots.length; i++) {
      if (slots[i] >= 0) n += FileSeal.plainLength(i, file.size, chunkSize: _chunk);
    }
    return n;
  }

  // --- bringing chunks down ------------------------------------------------------------------------------------------

  /// Chunk [i], here: from the disk, or brought down first (with the chunks after it, up to [upTo], in one request).
  Future<Uint8List> _chunkAt(int i, {int? upTo}) async {
    await _ensure(i, upTo: upTo ?? (i + runChunks - 1));
    return _locked(() async {
      final raf = _data!;
      await raf.setPosition(_slots![i] * _chunk);
      final want = FileSeal.plainLength(i, file.size, chunkSize: _chunk);
      final bytes = await raf.read(want);
      if (bytes.length != want) throw FilesError(-2, 'A kept part of the file is short.');
      return bytes;
    });
  }

  /// Chunk [i] on disk: done already where it is here, the fetch under way where one is, else a new fetch of it and
  /// the missing chunks right after it.
  Future<void> _ensure(int i, {required int upTo}) {
    if (_here(i)) return Future.value();
    final coming = _coming[i];
    if (coming != null) return coming;
    // A run of chunks not here and not on their way, from i, no further than upTo and no more than runChunks.
    final last = math.min(_count - 1, math.max(i, upTo));
    var j = i;
    while (j + 1 <= last && j + 1 - i < runChunks && !_here(j + 1) && !_coming.containsKey(j + 1)) {
      j++;
    }
    final run = _fetchRun(i, j - i + 1);
    for (var k = i; k <= j; k++) {
      _coming[k] = run;
    }
    run.then((_) {}, onError: (_) {}).whenComplete(() {
      for (var k = i; k <= j; k++) {
        if (identical(_coming[k], run)) _coming.remove(k);
      }
    });
    return run;
  }

  /// Brings [count] chunks from [first] down in one ranged read, opens them, and writes each to the data file and
  /// the index.
  Future<void> _fetchRun(int first, int count) async {
    final last = first + count - 1;
    final start = FileSeal.sealedOffset(first, chunkSize: _chunk);
    final end = FileSeal.sealedOffset(last, chunkSize: _chunk) + FileSeal.plainLength(last, file.size, chunkSize: _chunk) + FileSeal.tag - 1;
    Uint8List? sealed;
    // A connection that drops is tried again twice; a refusal or a chunk that doesn't open is not.
    for (var tries = 0;; tries++) {
      try {
        fetches++;
        final b = BytesBuilder(copy: false);
        await for (final piece in await _read(start, end)) {
          b.add(piece);
          if (b.length > end - start + 1) break;
        }
        sealed = b.takeBytes();
        if (sealed.length != end - start + 1) throw FilesError(0, 'The file came down short.');
        break;
      } on FilesError catch (e) {
        if (!e.offline || tries >= 2 || _closed) {
          _fail(e.message);
          rethrow;
        }
      } catch (e) {
        if (tries >= 2 || _closed) {
          _fail('$e');
          throw FilesError(0, '$e');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 400 * (tries + 1)));
    }
    final run = OpenRun(key: file.key, prefix: file.prefix, fileId: file.id, size: file.size, first: first, sealed: sealed, chunkSize: _chunk);
    final plain = sealed.length > 64 * 1024 ? await _openAside(run) : FileSeal.openRun(run);
    if (plain == null) {
      const why = 'The file didn\'t open: it was changed on the way, or isn\'t whole.';
      _fail(why);
      throw FilesError(-2, why);
    }
    await _locked(() async {
      if (_whole != null) return;
      final raf = _data!, index = _index!;
      var at = 0;
      for (var i = first; i <= last; i++) {
        final len = FileSeal.plainLength(i, file.size, chunkSize: _chunk);
        if (_slots![i] < 0) {
          // The chunk's bytes first, then the index that says they are there: cut off between, it is only not here.
          final slot = _nextSlot++;
          await raf.setPosition(slot * _chunk);
          await raf.writeFrom(plain, at, at + len);
          final word = ByteData(4)..setInt32(0, slot, Endian.little);
          await index.setPosition(i * 4);
          await index.writeFrom(word.buffer.asUint8List());
          _slots![i] = slot;
          _have++;
        }
        at += len;
      }
    });
    _changes.tell();
    if (_have == _count) unawaited(_assemble().catchError((_) {}));
  }

  /// Fetches ahead of the player: the chunks from [from] to [readAhead] past it that aren't here or coming.
  void _readAhead(int from) {
    if (_closed && _wholes == 0) return;
    final until = math.min(_count - 1, from + math.max<int>(1, readAhead ~/ _chunk) - 1);
    for (var i = from; i <= until; i++) {
      if (_here(i) || _coming.containsKey(i)) continue;
      unawaited(_ensure(i, upTo: until).catchError((_) {}));
    }
  }

  /// Notes why serving stopped (the first reason stands) and tells whoever listens.
  void _fail(String why) {
    if (_failure != null) return;
    _failure = why;
    _changes.tell();
  }

  // --- the whole of it -----------------------------------------------------------------------------------------------

  /// Every chunk here: the file put together as the ordinary download, checked against its SHA-256.
  Future<void> _assemble() => _assembling ??= _locked(() async {
        if (_whole != null) return;
        final data = _data!;
        _data = null;
        await data.flush();
        await data.close();
        await _index?.close();
        _index = null;
        final slots = _slots!;
        var inOrder = true;
        for (var i = 0; i < slots.length; i++) {
          if (slots[i] != i) {
            inOrder = false;
            break;
          }
        }
        final out = File('$assembledPath.assembling');
        await out.parent.create(recursive: true);
        try {
          if (inOrder) {
            // Watched straight through: the chunks are already in order, the file is the data file cut to size.
            final raf = await File(dataPath).open(mode: FileMode.append);
            await raf.truncate(file.size);
            await raf.close();
            await File(dataPath).rename(out.path);
          } else {
            await _inOrderAside(dataPath, out.path, slots, file.size, _chunk);
            _deleteQuietly(dataPath);
          }
          if (file.sha.isNotEmpty) {
            final sha = await _shaAside(out.path);
            if (sha != file.sha) throw FilesError(-2, 'The file came down different from what was added.');
          }
          await out.rename(assembledPath);
          _deleteQuietly(indexPath);
          await markFromInternet(assembledPath);
          await _useWhole(assembledPath);
        } catch (e) {
          // Nothing kept that is wrong: it is brought down again from the start, if asked for again.
          _deleteQuietly(out.path);
          _deleteQuietly(dataPath);
          _deleteQuietly(indexPath);
          _fail(e is FilesError ? e.message : '$e');
          slots.fillRange(0, slots.length, -1);
          _have = 0;
          _nextSlot = 0;
          _data = await File(dataPath).open(mode: FileMode.append);
          _index = await File(indexPath).open(mode: FileMode.append);
          await _index!.writeFrom(Uint8List(slots.length * 4)..fillRange(0, slots.length * 4, 0xff));
          _assembling = null;
          rethrow;
        }
        onWhole?.call(assembledPath);
        _changes.tell();
      });

  @override
  Future<String> whole(void Function(int done, int size) progress) async {
    _wholes++;
    try {
      await _load();
      progress(haveBytes, file.size);
      for (var i = 0; i < _count; i++) {
        if (_whole != null) break;
        if (_here(i)) continue;
        _readAhead(i);
        await _ensure(i, upTo: _count - 1);
        progress(haveBytes, file.size);
      }
      if (_whole == null) await _assemble();
      progress(file.size, file.size);
      return _whole!;
    } finally {
      _wholes--;
      _maybeShut();
    }
  }

  // --- the server ----------------------------------------------------------------------------------------------------

  @override
  Future<String> open() async {
    if (_closed) throw FilesError(-1, 'Stopped.');
    await _load();
    final server = _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_token == null) {
      _token = NetCrypto.hex(NetCrypto.randomBytes(16));
      server.autoCompress = false;
      server.idleTimeout = const Duration(seconds: 30);
      server.listen((r) => unawaited(_serve(r)), onError: (_) {});
    }
    // The file's own name after the token, so a player that looks at the ending (libmpv, ExoPlayer) sees .mkv or .mp4.
    final name = Uri.encodeComponent(file.name.isEmpty ? 'file' : file.name.replaceAll(RegExp(r'[/\\]'), '_'));
    return 'http://127.0.0.1:${server.port}/$_token/$name';
  }

  /// The port being served on, for a test.
  @visibleForTesting
  int? get port => _server?.port;

  /// Whether [a] is [b], taking the same time wherever they differ, so the token can't be found a letter at a time
  /// by timing the answers.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }

  /// `bytes=a-b`, `bytes=a-` or `bytes=-n` of a file of [size]: the first and last byte, or null where it can't be met.
  /// More than one range asked for is answered with the first.
  @visibleForTesting
  static (int, int)? rangeOf(String header, int size) {
    final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(,.*)?$').firstMatch(header);
    if (m == null) return null;
    final a = m.group(1)!, z = m.group(2)!;
    if (a.isEmpty && z.isEmpty) return null;
    if (a.isEmpty) {
      final n = int.tryParse(z);
      if (n == null || n == 0 || size == 0) return null;
      return (math.max(0, size - n), size - 1);
    }
    final start = int.tryParse(a);
    if (start == null || start >= size) return null;
    final end = z.isEmpty ? size - 1 : int.tryParse(z);
    if (end == null || end < start) return null;
    return (start, math.min(end, size - 1));
  }

  /// Answers one request from the player: checks the token and the method, works the range out, then writes the
  /// plain bytes a chunk at a time as each is had.
  Future<void> _serve(HttpRequest r) async {
    final res = r.response;
    var started = false;
    try {
      final segments = r.uri.pathSegments;
      final token = _token;
      if (token == null || segments.isEmpty || !_same(segments.first, token)) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (r.method != 'GET' && r.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await res.close();
        return;
      }
      final size = file.size;
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, file.mime.isEmpty ? 'application/octet-stream' : file.mime)
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      var start = 0, end = size - 1;
      final range = r.headers.value(HttpHeaders.rangeHeader);
      final partial = range != null;
      if (partial) {
        final asked = rangeOf(range, size);
        if (asked == null) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          res.contentLength = 0;
          await res.close();
          return;
        }
        (start, end) = asked;
      }
      final length = size == 0 ? 0 : end - start + 1;
      void head() {
        res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
        res.contentLength = length;
        if (partial) res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$size');
      }

      if (r.method == 'HEAD' || length == 0) {
        head();
        await res.close();
        return;
      }
      var i = start ~/ _chunk;
      final lastChunk = end ~/ _chunk;
      // The first chunk before anything is said: one that can't be had is an error status, not a body cut short.
      var plain = await _chunkAt(i, upTo: math.min(lastChunk, i + runChunks - 1));
      _readAhead(i + 1);
      head();
      started = true;
      var at = start;
      while (true) {
        final from = at - i * _chunk;
        final take = math.min(plain.length - from, end - at + 1);
        res.add(Uint8List.sublistView(plain, from, from + take));
        at += take;
        if (at > end) break;
        // Sent before the next is fetched: a player that has gone (it seeked, and dropped this connection) stops it.
        await res.flush();
        i++;
        plain = await _chunkAt(i, upTo: math.min(lastChunk, i + runChunks - 1));
        _readAhead(i + 1);
      }
      await res.close();
    } catch (e) {
      if (!started) {
        try {
          res.statusCode = HttpStatus.badGateway;
          res.contentLength = -1;
          res.headers.contentType = ContentType.text;
          res.write(e is FilesError ? e.message : 'unavailable');
          await res.close();
        } catch (_) {}
      } else {
        // Part way through: the connection is cut, so the player sees a short body and asks again, not wrong bytes.
        try {
          final socket = await res.detachSocket(writeHeaders: false);
          socket.destroy();
        } catch (_) {
          try {
            await res.close();
          } catch (_) {}
        }
      }
    }
  }

  // --- letting go ----------------------------------------------------------------------------------------------------

  @override
  void close() {
    if (_users <= 0) return;
    _users--;
    if (_users > 0) return;
    _closed = true;
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    _maybeShut();
  }

  /// Closes the files and says so ([onClosed]), once nobody holds the stream and no [whole] is under way.
  void _maybeShut() {
    if (!_closed || _wholes > 0 || _users > 0) return;
    // Its files closed once whatever is being written is.
    unawaited(_locked(() async {
      await _data?.close();
      await _index?.close();
      _data = null;
      _index = null;
    }).catchError((_) {}));
    onClosed?.call();
  }

  static void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Lets go of kept partial streams in [dir] but those of [keep]: any older than [age], then the least lately used
  /// until what is left is no more than [limit] bytes.
  static void evict(Directory dir, {Set<String> keep = const {}, required int limit, Duration age = const Duration(days: 14)}) {
    try {
      if (!dir.existsSync()) return;
      final kept = <(File, DateTime, int)>[];
      final now = DateTime.now();
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name.endsWith('.chunks')) {
          // An index whose data has gone is nothing.
          if (!File('${e.path.substring(0, e.path.length - 7)}.stream').existsSync()) _deleteQuietly(e.path);
          continue;
        }
        if (!name.endsWith('.stream')) continue;
        if (keep.contains(name.substring(0, name.length - 7))) continue;
        final st = e.statSync();
        kept.add((e, st.modified, st.size));
      }
      kept.sort((a, b) => b.$2.compareTo(a.$2));
      var total = 0;
      for (final (f, touched, size) in kept) {
        total += size;
        if (total > limit || now.difference(touched) > age) {
          _deleteQuietly(f.path);
          _deleteQuietly('${f.path.substring(0, f.path.length - 7)}.chunks');
        }
      }
    } catch (_) {}
  }
}

/// A notifier the stream can tell from outside it (notifyListeners is for a notifier's own class).
class _Changes extends ChangeNotifier {
  void tell() => notifyListeners();
}

// The heavy work on isolates of their own, from functions at the top, so what crosses is the arguments and nothing of
// the stream (its server and open files can't cross).
Future<Uint8List?> _openAside(OpenRun run) => runAside(() => FileSeal.openRun(run));
Future<String> _shaAside(String path) => runAside(() => shaOfFile(path));
Future<void> _inOrderAside(String from, String to, Int32List slots, int size, int chunk) => runAside(() => _inOrder(from, to, slots, size, chunk));

/// The chunks of the data file at [from], laid in order into [to]: run on an isolate of its own.
void _inOrder(String from, String to, Int32List slots, int size, int chunk) {
  final src = File(from).openSync();
  final out = File(to).openSync(mode: FileMode.write);
  try {
    for (var i = 0; i < slots.length; i++) {
      final len = FileSeal.plainLength(i, size, chunkSize: chunk);
      src.setPositionSync(slots[i] * chunk);
      final bytes = src.readSync(len);
      if (bytes.length != len) throw FilesError(-2, 'A kept part of the file is short.');
      out.writeFromSync(bytes);
    }
  } finally {
    src.closeSync();
    out.closeSync();
  }
}
