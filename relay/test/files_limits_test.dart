// The Files store's limits (the review of the Files space, 2026-11-17): a space and a key cost nothing to make, so what
// is written is what is limited. A space's log counts against its room and the store's, pages of it are read from a
// mark near where they start and never held whole, a room promised and never filled is let go, one address can only
// have so much going, the owner is only ever the owner, and a restart never keeps bytes whose signature was not checked.
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

class Person {
  Person(int n) : scalar = List.generate(32, (i) => (n * 29 + i * 11 + 3) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get keyHex => hexOf(key);

  Map<String, String> signed(String method, String path, List<int> body) {
    final time = DateTime.now().millisecondsSinceEpoch;
    final words = Files.signedWords(method, path, time, hexOf(sha256(body)));
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...utf8.encode(words)]);
    _nonce++;
    return {'x-ghost-key': base64Encode(key), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(P256.sign(scalar, utf8.encode(words), nonce))};
  }
}

const space = 'abcdef0123456789abcdef0123456789';
final token = 'e' * 64;

void main() {
  late Directory dir;
  late Relay relay;
  late int port;
  late HttpClient http;
  var now = DateTime.now();

  Future<void> boot({FilesConfig config = const FilesConfig()}) async {
    relay = Relay(files: Files(dir: Directory('${dir.path}/files'), config: config, now: () => now));
    port = await relay.start(port: 0);
  }

  setUp(() async {
    now = DateTime.now();
    dir = await Directory.systemTemp.createTemp('ghost-files-limits');
    http = HttpClient();
    await boot();
  });
  tearDown(() async {
    http.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  });

  Future<({int status, Map json, List<int> bytes, HttpHeaders headers})> call(String method, String path, {Person? as, List<int> body = const [], Map<String, String> headers = const {}}) async {
    final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set('authorization', 'Ghost $token');
    if (as != null) as.signed(method, path, body).forEach(req.headers.set);
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    Map json = const {};
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map;
    } catch (_) {}
    return (status: res.statusCode, json: json, bytes: bytes, headers: res.headers);
  }

  List<int> json(Object o) => utf8.encode(jsonEncode(o));
  final maya = Person(1), owner = Person(2);

  test('nobody but the owner becomes the owner; with none, nobody removes the space', () async {
    expect((await call('PUT', '/files/$space', as: maya, body: json({'owner': maya.keyHex == owner.keyHex ? '' : owner.keyHex}))).json['owner'], '');
    expect((await call('DELETE', '/files/$space', as: maya)).status, HttpStatus.forbidden, reason: 'opening it first is not owning it');
    expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex}))).json['owner'], owner.keyHex);
    expect((await call('DELETE', '/files/$space', as: owner)).status, HttpStatus.ok);
  });

  test('a space\'s log counts against its room, and is refused once it is full', () async {
    await relay.stop();
    await boot(config: const FilesConfig(spaceQuota: 4000));
    await call('PUT', '/files/$space', as: maya, body: json({}));
    var status = 0, sent = 0;
    for (var i = 0; i < 20 && status != HttpStatus.insufficientStorage; i++) {
      status = (await call('POST', '/files/$space/log', as: maya, body: List.filled(500, i))).status;
      if (status == HttpStatus.ok) sent++;
    }
    expect(status, HttpStatus.insufficientStorage);
    expect(sent, inInclusiveRange(4, 6));
    final used = (await call('GET', '/files/$space')).json['used'] as int;
    expect(used, greaterThan(2000));
    expect(used, lessThanOrEqualTo(4000));
    expect(relay.files!.used, used);
    // And still after a restart, read again from the log on disk.
    await relay.stop();
    await boot(config: const FilesConfig(spaceQuota: 4000));
    expect((await call('GET', '/files/$space')).json['used'], used);
    expect((await call('GET', '/files/$space')).json['seq'], sent);
  });

  test('pages of the log: from the right place, in order, after a restart too, at most a page', () async {
    const config = FilesConfig(writesPerMinute: 5000);
    await relay.stop();
    await boot(config: config);
    await call('PUT', '/files/$space', as: maya, body: json({}));
    for (var i = 1; i <= 600; i++) {
      expect((await call('POST', '/files/$space/log', as: maya, body: [i & 0xff, i >> 8])).json['seq'], i);
    }
    Future<List<int>> seqs(int after) async => [for (final o in (await call('GET', '/files/$space/log?after=$after')).json['ops'] as List) (o as Map)['s'] as int];
    for (final round in [1, 2]) {
      final first = await call('GET', '/files/$space/log?after=0');
      expect((first.json['ops'] as List).length, Files.page);
      expect(first.json['more'], isTrue);
      final last = round == 1 ? 600 : 601;
      expect(await seqs(500), [for (var i = 501; i <= last; i++) i]);
      expect((await seqs(255)).first, 256);
      expect((await seqs(256)).first, 257);
      expect((await seqs(257)).take(3), [258, 259, 260]);
      expect(await seqs(last), isEmpty);
      final op = ((await call('GET', '/files/$space/log?after=511')).json['ops'] as List).first as Map;
      expect(base64Decode(op['o'] as String), [512 & 0xff, 512 >> 8]);
      if (round == 1) {
        await relay.stop();
        await boot(config: config);
        // Written after a restart, the marks still line up.
        expect((await call('POST', '/files/$space/log', as: maya, body: [1, 2, 3])).json['seq'], 601);
        expect(await seqs(599), [600, 601]);
      }
    }
  });

  test('a room promised and never given a byte goes after ten minutes; one address can only promise so much', () async {
    await relay.stop();
    await boot(config: const FilesConfig(promisedPerAddress: 1000));
    await call('PUT', '/files/$space', as: maya, body: json({}));
    final a = await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 800}));
    expect(a.status, HttpStatus.created);
    expect((await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 300}))).status, HttpStatus.tooManyRequests);
    expect((await call('GET', '/files/$space')).json['used'], 800);
    now = now.add(const Duration(minutes: 11));
    await relay.files!.sweep();
    // Back to the signers' clock, for the next request's time to check out.
    now = now.subtract(const Duration(minutes: 11));
    expect((await call('GET', '/files/$space')).json['used'], 0);
    expect((await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 300}))).status, HttpStatus.created);
  });

  test('after a restart a blob being written keeps only what was saved; ranges too long to read are refused', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 100}))).json['id'] as String;
    expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: List.filled(40, 1))).json['have'], 40);
    await relay.stop();
    // Bytes after what was saved, as a relay stopped mid-piece leaves them: never checked, so never kept.
    File('${dir.path}/files/$space/blobs/$id.part').writeAsBytesSync(List.filled(30, 9), mode: FileMode.append);
    await boot();
    expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 40);
    expect(File('${dir.path}/files/$space/blobs/$id.part').lengthSync(), 40);
    expect((await call('PUT', '/files/$space/blobs/$id?offset=40', as: maya, body: List.filled(60, 2))).json['have'], 100);
    expect((await call('POST', '/files/$space/blobs/$id/done', as: maya)).json['done'], isTrue);
    expect((await call('GET', '/files/$space/blobs/$id', headers: {'range': 'bytes=99999999999999999999999-'})).status, HttpStatus.requestedRangeNotSatisfiable);
    final head = await call('HEAD', '/files/$space/blobs/$id');
    expect(head.status, HttpStatus.ok);
    expect(head.headers.contentLength, 100);
  });

  // Matt, 2026-11-25: "Let's stick with 256gb for the onlyGhosts server and leave the rest of them including alpha to 50gb".
  test('OnlyGhosts\' spaces hold 256 GB between them, every other 50 GB', () {
    const d = FilesConfig();
    expect(d.spaceQuota, 50000000000);
    expect(d.roomyQuota, 256000000000);
    expect(d.roomy, {'ecf77f9db9ba82ef2d2ea508e657f36c', '78d09c1c0d49291a6f4b716b1a2ee200'});
    expect(d.total, greaterThanOrEqualTo(d.roomyQuota + d.spaceQuota));
    final c = FilesConfig.fromEnvironment({'GHOST_FILES_ROOMY_SPACES': '${'ab' * 16},not-an-id'});
    expect(c.roomy, hasLength(3), reason: 'the ones in the code stay, and what is not an id is left out');
  });

  test('two roomy spaces share their room; another keeps its own', () async {
    final a = '1' * 32, b = '2' * 32, other = '3' * 32;
    await relay.stop();
    await boot(config: FilesConfig(spaceQuota: 2500, roomyQuota: 6000, roomy: {a, b}));
    Future<int> fill(String id) async {
      await call('PUT', '/files/$id', as: maya, body: json({}));
      var sent = 0;
      for (var i = 0; i < 30; i++) {
        if ((await call('POST', '/files/$id/log', as: maya, body: List.filled(500, i))).status != HttpStatus.ok) break;
        sent++;
      }
      return sent;
    }
    final first = await fill(a);
    expect(first, greaterThan(6), reason: 'more than an ordinary space holds');
    await fill(b);
    Future<int> used(String id) async => (await call('GET', '/files/$id')).json['used'] as int;
    final both = await used(a) + await used(b);
    expect(both, lessThanOrEqualTo(6000), reason: 'the two share 6000');
    expect(both, greaterThan(5000), reason: 'and between them fill it');
    expect((await call('GET', '/files/$b')).json['quota'], 6000 - await used(a));
    await fill(other);
    expect(await used(other), inInclusiveRange(1500, 2500), reason: 'any other space its own 2500');
  });
}
