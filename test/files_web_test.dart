// A Files space from a page in a browser (GMFB-30; docs/OPEN_NETWORK.md part 6), tried on a computer: the files
// store in its browser's way (FilesStore.browser) over the page's fetch (FetchFilesHttp), the fetch here a stand-in
// that does what a browser's does (says the length itself, streams the answer), against the relay's own files
// service on this machine. What only a browser can run (the fetch itself, WebCrypto, Blobs, the picker) is tried by
// tool/web/e2e.mjs.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/files/files_http.dart';
import 'package:ghost_messaging/files/files_http_fetch.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

Uint8List bytesOf(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Future<void> until(bool Function() test, {String? reason, Duration most = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(most);
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('waited too long${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A page's fetch, as far as the relay can tell: what is sent says its own length, a header a page may not set never
/// arrives, and the answer streams. [asked] keeps every request's method, address and headers; [down] makes every
/// request fail as a fetch does when the network is gone; [ignoreRange] answers a ranged read with the whole blob.
class StandInFetch {
  final _client = HttpClient();
  final asked = <({String method, Uri url, Map<String, String> headers})>[];
  bool down = false;
  bool ignoreRange = false;

  /// Each piece of an answer's body held back this long: a slow connection, so a download is still coming when stopped.
  Duration? drip;

  Future<FilesAnswer> call(String method, Uri url, Map<String, String> headers, Uint8List? body) async {
    asked.add((method: method, url: url, headers: headers));
    if (down) throw StateError('TypeError: Failed to fetch');
    final req = await _client.openUrl(method, url);
    headers.forEach((k, v) {
      if (ignoreRange && k == 'range') return;
      req.headers.set(k, v);
    });
    req.contentLength = body?.length ?? 0;
    if (body != null) req.add(body);
    final res = await req.close();
    final wait = drip;
    return (status: res.statusCode, body: wait == null ? res as Stream<List<int>> : res.asyncMap((p) => Future<List<int>>.delayed(wait, () => p)));
  }

  void close() => _client.close(force: true);
}

void main() {
  test('FileSeal.runChunks walks a run as sealRun and openRun always did: every chunk, the last marked, short refused', () {
    const size = 2500, chunk = 1000;
    final plain = [for (final c in FileSeal.runChunks(size: size, first: 0, length: size, chunkSize: chunk, sealed: false)) (c.index, c.last, c.start, c.end)];
    expect(plain, [(0, false, 0, 1000), (1, false, 1000, 2000), (2, true, 2000, 2500)]);
    final sealed = [for (final c in FileSeal.runChunks(size: size, first: 1, length: FileSeal.sealedSize(size, chunkSize: chunk) - 1016, chunkSize: chunk, sealed: true)) (c.index, c.last, c.start, c.end)];
    expect(sealed, [(1, false, 0, 1016), (2, true, 1016, 1532)]);
    // Sealed bytes that stop inside a chunk: that chunk has no end, and opening says no.
    expect(FileSeal.runChunks(size: size, first: 0, length: 1500, chunkSize: chunk, sealed: true).last.end, -1);
    expect(() => FileSeal.runChunks(size: size, first: 0, length: 1500, chunkSize: chunk, sealed: false).toList(), throwsArgumentError);
    // An empty file is one empty chunk, its last.
    expect([for (final c in FileSeal.runChunks(size: 0, first: 0, length: 0, chunkSize: chunk, sealed: false)) (c.index, c.last)], [(0, true)]);
  });

  test('a fetch that throws is the relay out of reach (status 0), its words kept short; the length is never set by the page', () async {
    final sent = <Map<String, String>>[];
    final http = FetchFilesHttp((m, u, h, b) async {
      sent.add(h);
      throw StateError('TypeError: Failed to fetch\nat somewhere');
    });
    await expectLater(http.send('PUT', Uri.parse('http://127.0.0.1:1/files/x'), {'content-length': '3', 'authorization': 'Ghost t'}, [1, 2, 3]),
        throwsA(isA<FilesError>().having((e) => e.offline, 'offline', isTrue).having((e) => e.message, 'message', 'Can\'t reach the files server (Bad state: TypeError: Failed to fetch).')));
    expect(sent.single, {'authorization': 'Ghost t'});
    // A body that breaks part way is the relay out of reach too.
    Stream<List<int>> breaks() async* {
      yield [1, 2];
      throw StateError('network');
    }

    final broken = FetchFilesHttp((m, u, h, b) async => (status: 200, body: breaks()));
    final got = await broken.send('GET', Uri.parse('http://127.0.0.1:1/'), const {}, null);
    await expectLater(got.body.toList(), throwsA(isA<FilesError>().having((e) => e.offline, 'offline', isTrue)));
    // Closed, a read under way ends with an error and nothing new is sent.
    final slow = StreamController<List<int>>();
    final held = FetchFilesHttp((m, u, h, b) async => (status: 200, body: slow.stream));
    final reading = (await held.send('GET', Uri.parse('http://127.0.0.1:1/'), const {}, null)).body.toList();
    held.close(force: true);
    await expectLater(reading, throwsA(isA<FilesError>()));
    await expectLater(held.send('GET', Uri.parse('http://127.0.0.1:1/'), const {}, null), throwsA(isA<FilesError>()));
    await slow.close();
  });

  group('two browsers and an app, and the relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    final maya = KeysSigner(NetKeys.generate()), sam = KeysSigner(NetKeys.generate()), theo = KeysSigner(NetKeys.generate());
    late VoiceChannel space;
    final stores = <FilesStore>[];
    final fetches = <StandInFetch>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ghost-files-web');
      space = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Drop box', kind: SpaceKind.files, owner: NetCrypto.hex(maya.publicKey));
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay'), config: const FilesConfig()));
      base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
    });

    tearDown(() async {
      for (final s in stores) {
        await s.wipe();
      }
      stores.clear();
      for (final f in fetches) {
        f.close();
      }
      fetches.clear();
      await relay.stop();
      // The app's store writes its list a moment after it changes, by another isolate: what it writes as the folder
      // goes is waited out.
      for (var i = 0;; i++) {
        try {
          await dir.delete(recursive: true);
          break;
        } on FileSystemException {
          if (i >= 50) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    /// A page in a browser: its store in the browser's way, over a stand-in fetch, with a folder it must never write to.
    (FilesStore, StandInFetch) page(KeysSigner who, String name) {
      final fetch = StandInFetch();
      fetches.add(fetch);
      final s = FilesStore.forTest(base: base, signer: who, data: Directory('${dir.path}/$name'), name: name, piece: 2, browser: true, http: () => FetchFilesHttp(fetch.call));
      stores.add(s);
      return (s, fetch);
    }

    test('a file picked in one browser goes up a piece at a time, is listed in another, and comes down byte for byte; nothing is kept on disk', () async {
      final (a, aFetch) = page(maya, 'Maya');
      final (b, _) = page(sam, 'Sam');
      await a.start();
      await a.open(space);
      await b.open(space);
      expect(b.of(space).files, isEmpty);
      final data = bytesOf(1300 * 1000 + 17, 7); // five chunks, three pieces of two
      final picked = BytesSource('report.pdf', data, modified: 1);
      a.uploadSources(space, [picked]);
      expect(a.transfers.single.up, isTrue);
      expect(a.transfers.single.source, same(picked));
      await until(() => a.transfers.isEmpty || a.transfers.first.state == TransferState.done, reason: '${a.transfers.firstOrNull?.error}');
      // Read a piece at a time (4 MB at most for its hash, two chunks a piece going up), never whole.
      expect(picked.most, lessThanOrEqualTo(4 << 20));
      expect(picked.reads, greaterThan(3));
      // Every request said the space's token, and every write was signed, as the app's are.
      expect(aFetch.asked.every((r) => r.headers['authorization']?.startsWith('Ghost ') ?? false), isTrue);
      expect(aFetch.asked.where((r) => r.method != 'GET').every((r) => r.headers.containsKey('x-ghost-sig')), isTrue);
      expect(aFetch.asked.any((r) => r.headers.containsKey('content-length')), isFalse);
      await b.of(space).refresh();
      final f = b.of(space).files.values.single;
      expect(f.name, 'report.pdf');
      expect(f.size, data.length);
      // Not here until it is brought down; then held in the tab under an address, the same address after.
      expect(b.cached(f), isNull);
      final url = await b.fetch(space, f);
      expect(await HeldFiles.bytes(url), data);
      expect(b.cached(f), url);
      expect(await b.fetch(space, f), url);
      // Nothing written to disk by either page: no list, no queue, no part file.
      expect(Directory('${dir.path}/Maya').existsSync(), isFalse);
      expect(Directory('${dir.path}/Sam').existsSync(), isFalse);
      // Deleted for everyone: the other page lets go of what it held.
      expect(await a.delete(space, a.of(space).files.values.single), isTrue);
      await b.of(space).refresh();
      expect(b.of(space).files, isEmpty);
    });

    test('what a browser puts up an app brings down, and what an app puts up a browser brings down: one sealing', () async {
      final (web, _) = page(maya, 'Maya');
      final app = FilesStore.forTest(base: base, signer: theo, data: Directory('${dir.path}/Theo'), name: 'Theo', piece: 2);
      stores.add(app);
      await web.open(space);
      await app.open(space);
      final fromWeb = bytesOf(700 * 1000, 3), fromApp = bytesOf(900 * 1000, 4);
      web.uploadSources(space, [BytesSource('from the page.bin', fromWeb)]);
      final inFile = File('${dir.path}/in/from the app.bin')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(fromApp);
      app.upload(space, [inFile.path]);
      await until(() => web.transfers.isEmpty && app.transfers.isEmpty, reason: '${web.transfers.firstOrNull?.error} ${app.transfers.firstOrNull?.error}');
      await web.of(space).refresh();
      await app.of(space).refresh();
      SpaceFile named(FilesStore s, String n) => s.of(space).files.values.firstWhere((f) => f.name == n);
      expect(await File(await app.fetch(space, named(app, 'from the page.bin'))).readAsBytes(), fromWeb);
      expect(await HeldFiles.bytes(await web.fetch(space, named(web, 'from the app.bin'))), fromApp);
    });

    test('a relay that ignores the Range still comes down right, and a fetch that fails makes an upload wait, then go on', () async {
      final (a, aFetch) = page(maya, 'Maya');
      final (b, bFetch) = page(sam, 'Sam');
      await a.open(space);
      final data = bytesOf(600 * 1000, 9);
      aFetch.down = true;
      a.uploadSources(space, [BytesSource('later.bin', data)]);
      await until(() => a.transfers.single.state == TransferState.waiting);
      expect(a.transfers.single.error, startsWith('Can\'t reach the files server'));
      aFetch.down = false;
      a.retry(a.transfers.single);
      await until(() => a.transfers.isEmpty || a.transfers.single.state == TransferState.done, reason: '${a.transfers.firstOrNull?.error}');
      bFetch.ignoreRange = true;
      await b.open(space);
      final f = b.of(space).files.values.single;
      expect(await HeldFiles.bytes(await b.fetch(space, f)), data);
    });

    test('a download stopped holds nothing; one whose bytes were changed on the relay is refused, not held', () async {
      final (a, _) = page(maya, 'Maya');
      final (b, bFetch) = page(sam, 'Sam');
      await a.open(space);
      a.uploadSources(space, [BytesSource('big.bin', bytesOf(5 * 1000 * 1000, 2))]);
      await until(() => a.transfers.isEmpty, reason: '${a.transfers.firstOrNull?.error}');
      await b.open(space);
      final f = b.of(space).files.values.single;
      final held = HeldFiles.count;
      // A connection slow enough that the file is still coming once the first lot has been opened.
      bFetch.drip = const Duration(milliseconds: 5);
      final going = expectLater(b.fetch(space, f), throwsA(isA<FilesError>()));
      await until(() => b.downloading(f)?.done != null && b.downloading(f)!.done > 0);
      await b.cancel(b.downloading(f)!);
      await going;
      expect(b.cached(f), isNull);
      expect(HeldFiles.count, held);
      bFetch.drip = null;
      // A byte of the sealed blob changed where the relay keeps it.
      final blob = Directory('${dir.path}/relay').listSync(recursive: true).whereType<File>().firstWhere((x) => x.lengthSync() == FileSeal.sealedSize(f.size));
      final raf = blob.openSync(mode: FileMode.append)..setPositionSync(300 * 1000);
      final at = raf.readSync(1);
      raf
        ..setPositionSync(300 * 1000)
        ..writeFromSync([at[0] ^ 1])
        ..closeSync();
      await expectLater(b.fetch(space, f), throwsA(isA<FilesError>().having((e) => e.message, 'message', contains('didn\'t open'))));
      expect(b.cached(f), isNull);
      expect(HeldFiles.count, held);
    });
  });
}
