import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// Someone with a key, talking to the files store as the app does (lib/files/files_api.dart in the app).
class Person {
  Person(int n) : scalar = List.generate(32, (i) => (n * 31 + i * 7 + 1) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get id => hexOf(sha256(key).sublist(0, 16));
  String get keyHex => hexOf(key);

  Map<String, String> signed(String method, String path, List<int> body, {int? at}) {
    final time = at ?? DateTime.now().millisecondsSinceEpoch;
    final words = Files.signedWords(method, path, time, hexOf(sha256(body)));
    final nonce = sha256([...scalar, ..._bytes(_nonce++), ...utf8.encode(words)]);
    return {'x-ghost-key': base64Encode(key), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(P256.sign(scalar, utf8.encode(words), nonce))};
  }

  static List<int> _bytes(int n) => [for (var i = 0; i < 8; i++) (n >> (8 * i)) & 0xff];
}

class Answer {
  Answer(this.status, this.bytes, this.headers);
  final int status;
  final List<int> bytes;
  final HttpHeaders headers;
  Map get json => jsonDecode(utf8.decode(bytes)) as Map;
}

const space = '0123456789abcdef0123456789abcdef';
final token = 'b' * 64;

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
    dir = await Directory.systemTemp.createTemp('ghost-files-test');
    http = HttpClient();
    await boot();
  });
  tearDown(() async {
    http.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  });

  Future<Answer> call(String method, String path, {Person? as, List<int> body = const [], String? tok, Map<String, String> headers = const {}, bool sign = true}) async {
    final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set('authorization', 'Ghost ${tok ?? token}');
    if (as != null && sign) as.signed(method, path, body).forEach(req.headers.set);
    if (as != null && !sign) req.headers.set('x-ghost-key', base64Encode(as.key));
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return Answer(res.statusCode, bytes, res.headers);
  }

  List<int> json(Object o) => utf8.encode(jsonEncode(o));

  final maya = Person(1), sam = Person(2), owner = Person(3);

  test('a streamed SHA-256 is the whole one', () {
    final r = Random(4);
    for (final n in [0, 1, 55, 56, 63, 64, 65, 1000, 70000]) {
      final bytes = List.generate(n, (_) => r.nextInt(256));
      final s = Sha256();
      for (var at = 0; at < n; at += 37) {
        s.add(bytes.sublist(at, min(n, at + 37)));
      }
      expect(hexOf(s.close()), hexOf(sha256(bytes)), reason: '$n bytes');
    }
  });

  test('a space is made by the first to name it, and not found with another token', () async {
    final made = await call('PUT', '/files/$space', as: maya, body: json({'owner': owner.keyHex}));
    expect(made.status, HttpStatus.created);
    expect(made.json['owner'], '', reason: 'an owner is taken only from the owner\'s own signed request');
    expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex}))).json['owner'], owner.keyHex, reason: 'the owner opening it becomes it');
    expect((await call('PUT', '/files/$space', as: sam, body: json({}))).status, HttpStatus.ok, reason: 'found, not made again');
    expect((await call('GET', '/files/$space', tok: 'c' * 64)).status, HttpStatus.notFound, reason: 'a wrong token is no space at all');
    expect((await call('GET', '/files/$space', tok: 'nope')).status, HttpStatus.unauthorized);
    expect((await call('GET', '/files/ffffffffffffffffffffffffffffffff')).status, HttpStatus.notFound);
    final info = await call('GET', '/files/$space');
    expect(info.json, containsPair('seq', 0));
  });

  test('a write without a good signature is refused; a replayed one too', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    expect((await call('POST', '/files/$space/log', as: maya, body: [1, 2, 3], sign: false)).status, HttpStatus.unauthorized);
    // Signed for other words.
    final req = await http.openUrl('POST', Uri.parse('http://127.0.0.1:$port/files/$space/log'));
    req.headers.set('authorization', 'Ghost $token');
    maya.signed('POST', '/files/$space/log', [9, 9]).forEach(req.headers.set);
    req.add([1, 2, 3]);
    expect((await req.close()).statusCode, HttpStatus.unauthorized);
    // An old time.
    final stale = maya.signed('POST', '/files/$space/log', [1], at: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch);
    expect((await call('POST', '/files/$space/log', body: [1], headers: stale)).status, HttpStatus.unauthorized);
    // The same signature twice.
    final once = maya.signed('POST', '/files/$space/log', [7]);
    expect((await call('POST', '/files/$space/log', body: [7], headers: once)).status, HttpStatus.ok);
    expect((await call('POST', '/files/$space/log', body: [7], headers: once)).status, HttpStatus.unauthorized);
  });

  test('the log keeps sealed operations in order, by who wrote them, a page at a time', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    for (var i = 1; i <= 3; i++) {
      final a = await call('POST', '/files/$space/log', as: i == 2 ? sam : maya, body: [i, i, i]);
      expect(a.json['seq'], i);
    }
    final all = await call('GET', '/files/$space/log?after=0');
    final ops = all.json['ops'] as List;
    expect([for (final o in ops) (o as Map)['s']], [1, 2, 3]);
    expect((ops[1] as Map)['by'], sam.id);
    expect(base64Decode((ops[2] as Map)['o'] as String), [3, 3, 3]);
    expect(((await call('GET', '/files/$space/log?after=2')).json['ops'] as List).length, 1);
    expect((await call('POST', '/files/$space/log', as: maya, body: List.filled(70 * 1024, 1))).status, HttpStatus.requestEntityTooLarge);
  });

  test('a blob goes up in pieces, picks up where it stopped, and comes back whole or by Range', () async {
    await call('PUT', '/files/$space', as: maya, body: json({'owner': owner.keyHex}));
    final data = List.generate(100000, (i) => (i * 13) & 0xff);
    final made = await call('POST', '/files/$space/blobs', as: maya, body: json({'size': data.length}));
    expect(made.status, HttpStatus.created);
    final id = made.json['id'] as String;
    // Someone else can't write to it.
    expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: sam, body: data.sublist(0, 10))).status, HttpStatus.forbidden);
    expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: data.sublist(0, 40000))).json['have'], 40000);
    // Sent again from the start: told where it has got to.
    final again = await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: data.sublist(0, 10));
    expect(again.status, HttpStatus.conflict);
    expect(again.json['have'], 40000);
    // Not finished yet: can't be read or called done.
    expect((await call('GET', '/files/$space/blobs/$id')).status, HttpStatus.conflict);
    expect((await call('POST', '/files/$space/blobs/$id/done', as: maya)).status, HttpStatus.conflict);
    // A restart in between: what was written is still there.
    await relay.stop();
    await boot();
    expect((await call('GET', '/files/$space/blobs/$id/state')).json, {'have': 40000, 'size': 100000, 'done': false});
    // Listed as unfinished in the space's info, with who started it and how far it got; gone from the list once done.
    final parts = (await call('GET', '/files/$space')).json['parts'] as List;
    expect(parts, hasLength(1));
    expect(parts.single, containsPair('id', id));
    expect(parts.single, containsPair('by', maya.id));
    expect(parts.single, containsPair('z', 100000));
    expect(parts.single, containsPair('h', 40000));
    expect((await call('PUT', '/files/$space/blobs/$id?offset=40000', as: maya, body: data.sublist(40000))).json['have'], 100000);
    // More than it was said to be is refused.
    expect((await call('POST', '/files/$space/blobs/$id/done', as: maya)).json['done'], true);
    final whole = await call('GET', '/files/$space/blobs/$id');
    expect(whole.status, HttpStatus.ok);
    expect(whole.bytes, data);
    final part = await call('GET', '/files/$space/blobs/$id', headers: {'range': 'bytes=1000-1999'});
    expect(part.status, HttpStatus.partialContent);
    expect(part.bytes, data.sublist(1000, 2000));
    expect(part.headers.value('content-range'), 'bytes 1000-1999/100000');
    final tail = await call('GET', '/files/$space/blobs/$id', headers: {'range': 'bytes=99990-'});
    expect(tail.bytes, data.sublist(99990));
    expect((await call('GET', '/files/$space/blobs/$id', headers: {'range': 'bytes=200000-'})).status, HttpStatus.requestedRangeNotSatisfiable);
    expect((await call('GET', '/files/$space')).json['files'], 1);
    expect((await call('GET', '/files/$space')).json['parts'], isEmpty);
  });

  test('a piece past the size said, or a bad signature, is cut back off', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 100}))).json['id'] as String;
    expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: List.filled(150, 1))).status, HttpStatus.requestEntityTooLarge);
    expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 0);
    // Signed over other bytes: written, then cut off.
    final req = await http.openUrl('PUT', Uri.parse('http://127.0.0.1:$port/files/$space/blobs/$id?offset=0'));
    req.headers.set('authorization', 'Ghost $token');
    maya.signed('PUT', '/files/$space/blobs/$id?offset=0', List.filled(50, 2)).forEach(req.headers.set);
    req.add(List.filled(50, 1));
    expect((await req.close()).statusCode, HttpStatus.unauthorized);
    expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 0);
  });

  test('a blob is removed by whoever added it or the owner, nobody else', () async {
    await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex}));
    Future<String> add() async {
      final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 20}))).json['id'] as String;
      await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: List.filled(20, 5));
      await call('POST', '/files/$space/blobs/$id/done', as: maya);
      return id;
    }

    final a = await add(), b = await add();
    expect((await call('GET', '/files/$space')).json['used'], 40);
    expect((await call('DELETE', '/files/$space/blobs/$a', as: sam)).status, HttpStatus.forbidden);
    expect((await call('DELETE', '/files/$space/blobs/$a', as: maya)).status, HttpStatus.ok);
    expect((await call('DELETE', '/files/$space/blobs/$b', as: owner)).status, HttpStatus.ok);
    expect((await call('GET', '/files/$space/blobs/$a')).status, HttpStatus.notFound);
    expect((await call('GET', '/files/$space')).json['used'], 0);
    expect(Directory('${dir.path}/files/$space/blobs').listSync(), isEmpty);
    // The whole space, by its owner alone.
    expect((await call('DELETE', '/files/$space', as: maya)).status, HttpStatus.forbidden);
    expect((await call('DELETE', '/files/$space', as: owner)).status, HttpStatus.ok);
    expect((await call('GET', '/files/$space')).status, HttpStatus.notFound);
  });

  test('quotas: a file too big, a space too full, too many spaces from one device', () async {
    await relay.stop();
    await boot(config: const FilesConfig(maxFile: 1000, spaceQuota: 1500, spacesPerId: 2));
    await call('PUT', '/files/$space', as: maya, body: json({}));
    expect((await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 1001}))).status, HttpStatus.requestEntityTooLarge);
    expect((await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 1000}))).status, HttpStatus.created);
    expect((await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 600}))).status, HttpStatus.insufficientStorage);
    expect((await call('PUT', '/files/${'1' * 32}', as: maya, body: json({}))).status, HttpStatus.created);
    expect((await call('PUT', '/files/${'2' * 32}', as: maya, body: json({}))).status, HttpStatus.forbidden);
  });

  test('sweeping lets go of unfinished blobs after a day and spaces unused for ninety days', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    await call('PUT', '/files/${'1' * 32}', as: maya, body: json({}), tok: 'd' * 64);
    final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 100}))).json['id'] as String;
    await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: List.filled(30, 1));
    now = now.add(const Duration(hours: 25));
    await call('GET', '/files/$space'); // opened today: kept
    await relay.files!.sweep();
    expect((await call('GET', '/files/$space/blobs/$id/state')).status, HttpStatus.notFound);
    expect(File('${dir.path}/files/$space/blobs/$id.part').existsSync(), isFalse);
    now = now.add(const Duration(days: 91));
    await relay.files!.sweep();
    expect(relay.files!.spaces, 0);
    expect(Directory('${dir.path}/files/$space').existsSync(), isFalse);
  });

  test('a big blob streams through without being held', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    const size = 24 << 20;
    final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': size}))).json['id'] as String;
    final piece = Uint8List(8 << 20);
    for (var at = 0; at < size; at += piece.length) {
      piece.fillRange(0, piece.length, at >> 20);
      expect((await call('PUT', '/files/$space/blobs/$id?offset=$at', as: maya, body: piece)).status, HttpStatus.ok);
    }
    await call('POST', '/files/$space/blobs/$id/done', as: maya);
    final last = await call('GET', '/files/$space/blobs/$id', headers: {'range': 'bytes=${size - 4}-'});
    expect(last.bytes, [16, 16, 16, 16]);
    expect(File('${dir.path}/files/$space/blobs/$id').lengthSync(), size);
  });
}
