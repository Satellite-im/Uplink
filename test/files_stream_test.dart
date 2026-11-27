// A Files-space file played as it comes down (lib/files/file_stream.dart; Matt, 2026-11-18: "do we need to download
// the whole file to play? would it be possible to setup streaming and buffering of the file?", then "yes build it"):
// the loopback server's ranges against a relay of the test's own that keeps really sealed chunks.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

const chunk = FileSeal.chunk;

/// The relay's blobs as relay/lib/files.dart serves them: a sealed file, whole or the Range asked for. It says each
/// range it was asked for, and refuses a request without the space's token.
class FakeRelay {
  FakeRelay(this.sealed);
  Uint8List sealed;
  final asked = <(int, int)>[];
  late HttpServer _server;
  static const space = 'aabbccddeeff00112233445566778899';
  static const token = 'files-token';

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((r) async {
      final res = r.response;
      if (r.headers.value(HttpHeaders.authorizationHeader) != 'Ghost $token') {
        res.statusCode = 401;
        await res.close();
        return;
      }
      var start = 0, end = sealed.length - 1;
      final range = r.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = min(end, int.parse(m.group(2)!));
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${sealed.length}');
      }
      asked.add((start, end));
      res.contentLength = end - start + 1;
      res.add(Uint8List.sublistView(sealed, start, end + 1));
      await res.close();
    });
    return Uri.parse('http://127.0.0.1:${_server.port}/files');
  }

  Future<void> stop() => _server.close(force: true);
}

Uint8List bytesOf(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory dir;
  late FakeRelay relay;
  late FilesApi api;
  late Uint8List data;
  late SpaceFile file;
  final opened = <FileStream>[];
  final http = HttpClient();

  // Five whole chunks and a short sixth: ranges cross chunk edges and reach the short last one.
  final size = 5 * chunk + 1000;
  final key = NetCrypto.randomBytes(32), prefix = NetCrypto.randomBytes(8);
  const id = '00112233445566778899aabbccddeeff';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ghost-files-stream');
    data = bytesOf(size, 11);
    final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, plain: data));
    expect(sealed.length, FileSeal.sealedSize(size));
    relay = FakeRelay(sealed);
    final base = await relay.start();
    api = FilesApi(base: base, space: FakeRelay.space, token: FakeRelay.token, signer: KeysSigner(NetKeys.generate()));
    file = SpaceFile(id: id, name: 'Trip clip.mkv', size: size, mime: 'video/x-matroska', sha: NetCrypto.hex(NetCrypto.sha256(data)), key: key, prefix: prefix, by: 'x', byName: 'Maya', at: 0);
  });

  tearDown(() async {
    for (final s in opened) {
      s.close();
    }
    opened.clear();
    api.close();
    await relay.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await dir.delete(recursive: true);
  });

  String assembled(SpaceFile f) => '${dir.path}/cache/${f.id}/${f.name}';

  FileStream streamOf({int readAhead = 8 << 20, SpaceFile? f}) {
    final ff = f ?? file;
    final s = FileStream(file: ff, cacheDir: Directory('${dir.path}/cache'), assembledPath: assembled(ff), read: (a, z) => api.read(ff.id, start: a, end: z), readAhead: readAhead);
    opened.add(s);
    return s;
  }

  Future<({int status, HttpHeaders headers, Uint8List body})> get(String url, {String? range, String method = 'GET'}) async {
    final req = await http.openUrl(method, Uri.parse(url));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final b = BytesBuilder(copy: false);
    await for (final piece in res) {
      b.add(piece);
    }
    return (status: res.statusCode, headers: res.headers, body: b.takeBytes());
  }

  /// The sealed chunks the relay was asked for, by number: every request starts and ends on a chunk's edge.
  List<int> chunksAsked() {
    final out = <int>[];
    for (final (a, z) in relay.asked) {
      expect(a % (chunk + FileSeal.tag), 0, reason: 'a request starts on a sealed chunk: $a');
      final first = a ~/ (chunk + FileSeal.tag);
      final last = z ~/ (chunk + FileSeal.tag);
      expect(z == relay.sealed.length - 1 || (z + 1) % (chunk + FileSeal.tag) == 0, isTrue, reason: 'and ends on one: $z');
      for (var i = first; i <= last; i++) {
        out.add(i);
      }
    }
    return out;
  }

  test('the Range header read as a file server reads it', () {
    expect(FileStream.rangeOf('bytes=0-99', 1000), (0, 99));
    expect(FileStream.rangeOf('bytes=500-', 1000), (500, 999));
    expect(FileStream.rangeOf('bytes=-100', 1000), (900, 999));
    expect(FileStream.rangeOf('bytes=-5000', 1000), (0, 999));
    expect(FileStream.rangeOf('bytes=900-5000', 1000), (900, 999));
    expect(FileStream.rangeOf('bytes=0-1, 5-6', 1000), (0, 1));
    expect(FileStream.rangeOf('bytes=1000-', 1000), isNull);
    expect(FileStream.rangeOf('bytes=9-3', 1000), isNull);
    expect(FileStream.rangeOf('bytes=-', 1000), isNull);
    expect(FileStream.rangeOf('items=0-1', 1000), isNull);
  });

  test('ranges at the start, across chunk edges, at the end, from the end, and HEAD: the plain bytes, fetched by chunk', () async {
    final s = streamOf(readAhead: 0);
    final url = await s.open();
    expect(url, startsWith('http://127.0.0.1:'));
    expect(url, endsWith('/Trip%20clip.mkv'));

    final head = await get(url, method: 'HEAD');
    expect(head.status, 200);
    expect(head.headers.value(HttpHeaders.contentLengthHeader), '$size');
    expect(head.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(head.headers.contentType?.mimeType, 'video/x-matroska');
    expect(head.body, isEmpty);
    expect(relay.asked, isEmpty, reason: 'HEAD fetches nothing');

    final first = await get(url, range: 'bytes=0-99');
    expect(first.status, 206);
    expect(first.headers.value(HttpHeaders.contentRangeHeader), 'bytes 0-99/$size');
    expect(first.headers.value(HttpHeaders.contentLengthHeader), '100');
    expect(first.body, data.sublist(0, 100));

    // Across the edge between chunks 2 and 3: both opened, the slice either side of the edge given back.
    final across = await get(url, range: 'bytes=${3 * chunk - 50}-${3 * chunk + 49}');
    expect(across.status, 206);
    expect(across.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${3 * chunk - 50}-${3 * chunk + 49}/$size');
    expect(across.body, data.sublist(3 * chunk - 50, 3 * chunk + 50));

    // The end: the short last chunk.
    final end = await get(url, range: 'bytes=${size - 10}-');
    expect(end.status, 206);
    expect(end.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${size - 10}-${size - 1}/$size');
    expect(end.body, data.sublist(size - 10));
    final suffix = await get(url, range: 'bytes=-1500');
    expect(suffix.status, 206);
    expect(suffix.headers.value(HttpHeaders.contentRangeHeader), 'bytes ${size - 1500}-${size - 1}/$size');
    expect(suffix.body, data.sublist(size - 1500), reason: 'the last 1500 bytes span chunks 4 and 5');

    final refused = await get(url, range: 'bytes=$size-');
    expect(refused.status, 416);
    expect(refused.headers.value(HttpHeaders.contentRangeHeader), 'bytes */$size');

    // Only the chunks those ranges are in (and one ahead of each) were asked of the relay, each once.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final asked = chunksAsked();
    expect(asked.toSet().length, asked.length, reason: 'no chunk asked for twice: $asked');
    expect(asked.toSet(), isNot(contains(-1)));
    expect(asked.toSet().containsAll({0, 2, 3, 4, 5}), isTrue, reason: '$asked');

    // Asked again: from the disk, nothing more from the relay.
    final before = relay.asked.length;
    expect((await get(url, range: 'bytes=${3 * chunk - 50}-${3 * chunk + 49}')).body, data.sublist(3 * chunk - 50, 3 * chunk + 50));
    expect(relay.asked.length, before, reason: 'seeking back fetches nothing');
  });

  test('the whole file from the top, as a player first asks: 200 and every byte, then put together as the download', () async {
    final s = streamOf();
    final url = await s.open();
    final all = await get(url);
    expect(all.status, 200);
    expect(all.headers.value(HttpHeaders.contentLengthHeader), '$size');
    expect(all.body, data);
    // Every chunk here: the file put together where Save and Open look, byte for byte, and the parts let go.
    final path = assembled(file);
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!File(path).existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(File(path).readAsBytesSync(), data);
    expect(File(s.dataPath).existsSync(), isFalse);
    expect(File(s.indexPath).existsSync(), isFalse);
    expect(s.held(), [(0.0, 1.0)]);
    // Served on from the whole file, and a stream made again asks the relay nothing.
    expect((await get(url, range: 'bytes=${chunk - 3}-${chunk + 2}')).body, data.sublist(chunk - 3, chunk + 3));
    final asked = relay.asked.length;
    final again = streamOf();
    expect((await get(await again.open(), range: 'bytes=100-199')).body, data.sublist(100, 200));
    expect(relay.asked.length, asked);
    expect(again.fetches, 0);
  });

  test('chunks that came out of order are put in order; what came is kept for a stream made again', () async {
    final s = streamOf(readAhead: 0);
    final url = await s.open();
    expect((await get(url, range: 'bytes=${size - 100}-')).body, data.sublist(size - 100));
    expect((await get(url, range: 'bytes=${2 * chunk}-${2 * chunk + 9}')).body, data.sublist(2 * chunk, 2 * chunk + 10));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final had = s.held();
    expect(had, isNotEmpty);
    s.close();
    opened.remove(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Made again (the player opened again): what came is on the disk, the rest brought down for another app.
    final again = streamOf(readAhead: 0);
    await again.open();
    expect(again.held(), had);
    final before = chunksAsked().toSet();
    final progress = <int>[];
    final path = await again.whole((done, all) => progress.add(done));
    expect(path, assembled(file));
    expect(File(path).readAsBytesSync(), data);
    expect(progress.last, size);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    final asked = chunksAsked();
    expect(asked.length, asked.toSet().length, reason: 'nothing that had come was asked for again: $asked');
    expect(asked.toSet(), {0, 1, 2, 3, 4, 5});
    expect(before.length, lessThan(6));
  });

  test('a chunk changed on the relay is refused: an error, never its bytes, and nothing of it kept', () async {
    // One byte of chunk 2 flipped where the relay keeps it.
    relay.sealed[FileSeal.sealedOffset(2) + 1234] ^= 0x01;
    final s = streamOf(readAhead: 0);
    final url = await s.open();
    // Chunk 1 first, alone (it opens): then a range from it into the changed chunk 2 has begun when chunk 2 fails, and
    // is cut off, not given wrong bytes.
    expect((await get(url, range: 'bytes=${chunk + 10}-${chunk + 19}')).body, data.sublist(chunk + 10, chunk + 20));
    Object? cut;
    Uint8List? body;
    try {
      final r = await get(url, range: 'bytes=${chunk + 10}-${3 * chunk}');
      expect(r.status, 206);
      body = r.body;
    } catch (e) {
      cut = e;
    }
    expect(cut != null || (body != null && body.length < 2 * chunk - 9), isTrue, reason: 'cut short: ${body?.length}');
    if (body != null) expect(body, data.sublist(chunk + 10, chunk + 10 + body.length), reason: 'what came before the cut is right');
    expect(s.failure, contains('didn\'t open'));
    // A range that starts in the changed chunk is an error status.
    final bad = await get(url, range: 'bytes=${2 * chunk + 10}-${2 * chunk + 20}');
    expect(bad.status, 502);
    expect(s.held().any((p) => p.$1 <= 2 / 5.0 && p.$2 > 2 / 5.0 + 0.01), isFalse, reason: 'the changed chunk is not kept');
    // Cut short by the relay (the last chunk without its tag): refused too.
    final short = FakeRelay(Uint8List.sublistView(relay.sealed, 0, relay.sealed.length - 5));
    final shortBase = await short.start();
    final shortApi = FilesApi(base: shortBase, space: FakeRelay.space, token: FakeRelay.token, signer: KeysSigner(NetKeys.generate()));
    final f2 = SpaceFile(id: id, name: 'short.mkv', size: size, mime: 'video/x-matroska', sha: file.sha, key: key, prefix: prefix, by: 'x', byName: 'Maya', at: 0);
    final s2 = FileStream(file: f2, cacheDir: Directory('${dir.path}/cache2'), assembledPath: '${dir.path}/cache2/x/short.mkv', read: (a, z) => shortApi.read(id, start: a, end: z), readAhead: 0);
    opened.add(s2);
    expect((await get(await s2.open(), range: 'bytes=-10')).status, 502);
    shortApi.close();
    await short.stop();
  });

  test('only an address with the stream\'s token is answered', () async {
    final s = streamOf(readAhead: 0);
    final url = Uri.parse(await s.open());
    final token = url.pathSegments.first;
    expect(token, matches(RegExp(r'^[0-9a-f]{32}$')), reason: '128 random bits');
    final wrong = token.replaceRange(0, 1, token[0] == 'a' ? 'b' : 'a');
    expect((await get(url.replace(pathSegments: [wrong, 'Trip clip.mkv']).toString(), range: 'bytes=0-9')).status, 404);
    expect((await get('http://127.0.0.1:${url.port}/', range: 'bytes=0-9')).status, 404);
    expect((await get('http://127.0.0.1:${url.port}/Trip%20clip.mkv', range: 'bytes=0-9')).status, 404);
    expect(relay.asked, isEmpty, reason: 'nothing fetched for a wrong address');
    expect((await get(url.toString(), method: 'POST')).status, 405);
    expect((await get(url.toString(), range: 'bytes=0-9')).status, 206);
    // A second stream has a token of its own.
    final other = Uri.parse(await streamOf(readAhead: 0).open());
    expect(other.pathSegments.first, isNot(token));
    // Closed: the server is gone.
    s.close();
    opened.remove(s);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(get(url.toString(), range: 'bytes=0-9'), throwsA(isA<SocketException>()));
  });

  test('read ahead: a few megabytes past where the player is, without being asked', () async {
    final s = streamOf(readAhead: 3 * chunk);
    final url = await s.open();
    await get(url, range: 'bytes=0-9');
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (s.haveBytes < 4 * chunk && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(s.haveBytes, 4 * chunk, reason: 'chunk 0 and the three after it');
  });

  test('kept partial streams are bounded: the oldest beyond the limit, and any too old, go', () async {
    final cache = Directory('${dir.path}/evict')..createSync();
    final now = DateTime.now();
    void part(String name, int bytes, Duration ago) {
      File('${cache.path}/$name.stream')
        ..writeAsBytesSync(Uint8List(bytes))
        ..setLastModifiedSync(now.subtract(ago));
      File('${cache.path}/$name.chunks').writeAsBytesSync(Uint8List(4));
    }

    part('newest', 400, const Duration(minutes: 1));
    part('middle', 400, const Duration(hours: 1));
    part('oldest', 400, const Duration(hours: 2));
    part('ancient', 10, const Duration(days: 30));
    part('mine', 5000, const Duration(days: 30));
    File('${cache.path}/orphan.chunks').writeAsBytesSync(Uint8List(4));
    File('${cache.path}/aaaa/report.pdf')
      ..createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(10));
    FileStream.evict(cache, keep: {'mine'}, limit: 900);
    final left = cache.listSync(recursive: true).whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
    expect(left, {'newest.stream', 'newest.chunks', 'middle.stream', 'middle.chunks', 'mine.stream', 'mine.chunks', 'report.pdf'});
  });

  test('end to end on the relay itself: a file uploaded on one device plays on another as it comes, then is its download', () async {
    final real = Relay(files: Files(dir: Directory('${dir.path}/relay')));
    final base = Uri.parse('http://127.0.0.1:${await real.start(port: 0)}/files');
    final maya = KeysSigner(NetKeys.generate()), sam = KeysSigner(NetKeys.generate());
    final space = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Drop box', kind: SpaceKind.files, owner: NetCrypto.hex(maya.publicKey));
    final a = FilesStore.forTest(base: base, signer: maya, data: Directory('${dir.path}/Maya'));
    final b = FilesStore.forTest(base: base, signer: sam, data: Directory('${dir.path}/Sam'));
    try {
      final input = File('${dir.path}/in/holiday.mkv')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(data);
      a.upload(space, [input.path]);
      final until = DateTime.now().add(const Duration(seconds: 30));
      while (a.of(space).files.isEmpty && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await b.open(space);
      final f = b.of(space).files.values.single;
      expect(b.cached(f), isNull);
      final s = b.stream(space, f);
      final url = await s.open();
      expect((await get(url, range: 'bytes=${size - 2000}-')).body, data.sublist(size - 2000), reason: 'the end first, as an MKV player looks for its index');
      // Save while it plays: the rest is brought into the same stream, and the download is the file.
      final path = await b.fetch(space, f);
      expect(path, b.cachedPath(f));
      expect(File(path).readAsBytesSync(), data);
      expect(b.cached(f), path);
      expect(s.fetches, greaterThan(1), reason: 'brought down through the stream, not a second download beside it');
      expect(File('${dir.path}/Sam/cache/${f.id}.part').existsSync(), isFalse);
      expect((await get(url, range: 'bytes=0-99')).body, data.sublist(0, 100));
      s.close();
    } finally {
      await a.clear();
      await b.clear();
      await real.stop();
    }
  });
}
