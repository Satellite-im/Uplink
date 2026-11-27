// The Marketplace on the relay (lib/market.dart; Matt, 2026-11-20: "I would like users to be able to develop and submit
// their own plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review
// process ... Add a submission area with a form to accept an icon, description, plugin tags, etc"): signed requests and
// what they cost a stranger, submissions and each refusal, review and its gate, what is served and how, and what is
// kept across a restart. The handles are stood in for (who owns which username, who is verified, who signed in to the
// admin page and when), the clock is the test's, and signature checks are counted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/feedback.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/files_roster.dart';
import 'package:ghost_relay/market.dart';
import 'package:ghost_relay/market_pack.dart';
import 'package:ghost_relay/market_store.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

import 'market_fixtures.dart';

/// Someone with a hub key, signing as the app does (lib/market/market_api.dart in the app).
class Sender {
  Sender(int n) : scalar = List.generate(32, (i) => (n * 41 + i * 11 + 7) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get id => FilesRoster.idOf(key);
  String get keyB64 => base64Encode(key);

  String sig(String words) {
    final message = utf8.encode(words);
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...message]);
    _nonce++;
    return base64Encode(P256.sign(scalar, message, nonce));
  }

  /// The headers of a signed request: its key, time and signature over the market's words, and with a body its hash
  /// and length said up front.
  Map<String, String> headers(String method, String path, List<int> body, {required int time}) {
    final sha = hexOf(sha256(body));
    final withBody = method != 'GET' && method != 'DELETE';
    return {
      'x-ghost-key': keyB64,
      'x-ghost-time': '$time',
      'x-ghost-sig': sig(Market.signedWords(method, path, time, sha)),
      if (withBody) Files.bodyShaHeader: sha,
      if (withBody) Files.bodyLengthHeader: '${body.length}',
    };
  }
}

class Answer {
  Answer(this.status, this.bytes, this.headers);
  final int status;
  final Uint8List bytes;
  final HttpHeaders headers;
  Map<String, dynamic> get json => (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
  String? get error => json['error'] as String?;

  @override
  String toString() => '$status ${utf8.decode(bytes, allowMalformed: true)}';
}

/// A key that isn't one, for when signatures are stood in for: 33 bytes starting 2.
List<int> fakeKey(Object n) => [2, ...sha256(utf8.encode('key $n')).sublist(0, 32)];

Map<String, String> fakeSigned(List<int> key, int time) => {'x-ghost-key': base64Encode(key), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(List.filled(64, 1))};

/// Bills with an id of its own, as [developer] sends it: its canonical bytes.
Uint8List packOf({String id = 'mybills', String version = '1.0.0', String developer = 'maya', List<String>? shots, Map<String, Object?> changes = const {}}) {
  final j = (jsonDecode(billsPack) as Map).cast<String, Object?>()
    ..['id'] = id
    ..['version'] = version
    ..['developer'] = developer;
  if (shots != null) j['shots'] = shots;
  j.addAll(changes);
  return canonicalBytes(j);
}

String shaOf(List<int> bytes) => hexOf(sha256(bytes));

/// A screenshot of [w] by [h], told apart from others by [n].
Uint8List shotPng(int n, {int w = 400, int h = 800, int fill = 16}) => png(w, h, chunks: [('IDAT', [n & 0xff, (n >> 8) & 0xff, ...List.filled(fill, 7)])]);

Map<String, Object?> shotOf(List<int> bytes) => {'mime': 'image/png', 'data': base64Encode(bytes)};

void main() {
  late Directory dir;
  late Relay relay;
  late Market market;
  late int port;
  late HttpClient http;
  late DateTime now;
  late Map<String, String> names;
  late Map<String, String> someone;
  late Map<String, DateTime> claimed;
  late Map<String, DateTime> adminAt;
  late Set<String> throwsFor;
  late int verifies;
  bool Function(List<int> key, List<int> message, List<int> sig)? fake;
  final maya = Sender(1), sam = Sender(2), matt = Sender(3), ada = Sender(4), theo = Sender(5);

  Future<void> boot({MarketConfig config = const MarketConfig(), Feedback? feedback, Files? files, Duration? bodyPause, Duration? bodyRateEvery}) async {
    market = Market(
      dir: Directory('${dir.path}/market'),
      config: config,
      ownsName: (id, name) => names[id] == name,
      whoOf: (id) {
        if (throwsFor.contains(id)) throw StateError('whoOf broke for this test');
        return someone[id];
      },
      adminSignedIn: (id, {Duration within = const Duration(hours: 8)}) => adminAt[id] != null && now.difference(adminAt[id]!) < within,
      claimedOn: (id) => claimed[id],
      usernameOf: (id) => names[id],
      verify: (key, message, sig) {
        verifies++;
        return fake != null ? fake!(key, message, sig) : P256.verify(key, message, sig);
      },
      now: () => now,
      bodyPause: bodyPause,
      bodyRateEvery: bodyRateEvery,
    );
    relay = Relay(market: market, feedback: feedback, files: files);
    port = await relay.start(port: 0);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ghost-market-test');
    http = HttpClient();
    now = DateTime.utc(2026, 11, 20, 12);
    names = {maya.id: 'maya', sam.id: 'sam', matt.id: 'matt', ada.id: 'ada', theo.id: 'theo'};
    someone = {maya.id: 'phone|maya', sam.id: 'phone|sam', matt.id: 'phone|matt', ada.id: 'phone|ada'};
    claimed = {for (final id in names.keys) id: DateTime.utc(2026, 10, 1)};
    adminAt = {};
    throwsFor = {};
    verifies = 0;
    fake = null;
    await boot();
  });
  tearDown(() async {
    http.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  });

  Future<Answer> call(String method, String path, {Sender? as, Object? json, List<int>? body, Map<String, String> headers = const {}, String address = '10.0.0.1', int? time}) async {
    // Each signed call a twentieth of a second on, so a test's calls stay within the relay's twenty signature checks a
    // second of its clock; the tests of that budget sign by hand and hold the clock still.
    if (as != null) now = now.add(const Duration(milliseconds: 50));
    final bytes = body ?? (json == null ? const <int>[] : utf8.encode(jsonEncode(json)));
    final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set('x-forwarded-for', address);
    if (as != null) as.headers(method, Uri.parse(path).path, bytes, time: time ?? now.millisecondsSinceEpoch).forEach(req.headers.set);
    headers.forEach(req.headers.set);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final got = BytesBuilder(copy: false);
    await for (final piece in res) {
      got.add(piece);
    }
    return Answer(res.statusCode, got.takeBytes(), res.headers);
  }

  /// A request written by hand, its answer's head read as soon as it comes: for bodies sent slowly, or never.
  Future<String> raw(String head, {List<int> body = const []}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    try {
      socket.write(head);
      socket.add(body);
      await socket.flush();
      // A guard against a hang, not a wait: the answer is read as it comes, to the end the relay makes of the connection.
      return await utf8.decoder.bind(socket).join().timeout(const Duration(seconds: 20));
    } finally {
      socket.destroy();
    }
  }

  int statusOf(String head) => int.parse(head.split(' ')[1]);

  String headOf(String method, String path, Map<String, String> headers, int length) => '$method $path HTTP/1.1\r\nHost: relay.test\r\nContent-Length: $length\r\n${headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n';

  Future<Answer> submit(Sender who, Uint8List package, {List<Object> shots = const [], String notes = '', String list = 'now', String address = '10.0.0.1'}) => call('POST', '/market/submissions', as: who, address: address, json: {'package': base64Encode(package), 'shots': shots, if (notes.isNotEmpty) 'notes': notes, 'list': list, 'agree': true});

  Map<String, Object?> approval(Sender by, String plugin, String version, String sha) => {'v': 1, 'plugin': plugin, 'version': version, 'sha256': sha, 'key': by.keyB64, 'sig': by.sig(Market.approvalWords(plugin, version, sha)), 'at': now.millisecondsSinceEpoch};

  Map<String, Object?> revocation(Sender by, String plugin, String sha, String why) {
    final at = now.millisecondsSinceEpoch;
    return {'v': 1, 'plugin': plugin, 'sha256': sha, 'at': at, 'why': why, 'key': by.keyB64, 'sig': by.sig(Market.revocationWords(plugin, sha, at, why))};
  }

  Map<String, Object?> retirement(Sender key) => {'v': 1, 'key': key.keyB64, 'at': now.millisecondsSinceEpoch, 'sig': key.sig(Market.retirementWords(key.keyB64))};

  Future<Answer> decide(String sid, Map<String, Object?> decision, {Sender? by}) => call('POST', '/market/review/$sid', as: by ?? matt, json: decision);

  /// [who]'s submission of [package], approved by [by] (signed in now): its sid.
  Future<String> approved(Sender who, Uint8List package, {Sender? by, List<Object> shots = const [], String list = 'now'}) async {
    final reviewer = by ?? matt;
    adminAt[reviewer.id] = now;
    final sent = await submit(who, package, shots: shots, list: list);
    expect(sent.status, 201, reason: '$sent');
    final s = sent.json['submission'] as Map;
    final done = await decide(s['sid'] as String, {'decision': 'approve', 'approval': approval(reviewer, s['plugin'] as String, s['version'] as String, s['sha256'] as String)}, by: reviewer);
    expect(done.status, 200, reason: '$done');
    return s['sid'] as String;
  }

  group('signing', () {
    test('unsigned, stale, replayed, badly signed, with a query, or a body not as its headers say: each refused', () async {
      expect((await call('GET', '/market/mine')).error, 'unsigned');
      final stale = await call('GET', '/market/mine', as: maya, time: now.subtract(const Duration(minutes: 6)).millisecondsSinceEpoch);
      expect((stale.status, stale.error), (401, 'bad_signature'));
      final once = maya.headers('GET', '/market/mine', const [], time: now.millisecondsSinceEpoch);
      expect((await call('GET', '/market/mine', headers: once)).status, 200);
      expect((await call('GET', '/market/mine', headers: once)).error, 'bad_signature', reason: 'the same request again');
      final forged = {...sam.headers('GET', '/market/mine', const [], time: now.millisecondsSinceEpoch + 1), 'x-ghost-key': maya.keyB64};
      expect((await call('GET', '/market/mine', headers: forged)).error, 'bad_signature', reason: 'Sam\'s signature with Maya\'s key');
      expect((await call('GET', '/market/mine', headers: {...forged, 'x-ghost-key': base64Encode(maya.key.sublist(1))})).error, 'bad_signature', reason: '32 bytes');
      expect((await call('GET', '/market/mine', headers: {...once, 'x-ghost-time': 'soon'})).error, 'bad_signature');
      final query = await call('GET', '/market/mine?all=1', as: maya);
      expect((query.status, query.error), (400, 'bad_request'));

      final body = utf8.encode(jsonEncode({'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': ''}));
      final signed = maya.headers('POST', '/market/report', body, time: now.millisecondsSinceEpoch + 2);
      final bare = Map.of(signed)
        ..remove(Files.bodyShaHeader)
        ..remove(Files.bodyLengthHeader);
      expect((await call('POST', '/market/report', body: body, headers: bare)).error, 'bad_request', reason: 'a body without its hash and length');
      final other = utf8.encode(jsonEncode({'plugin': 'mybills', 'version': '1.0.1', 'reason': 'spam', 'text': ''}));
      expect(other.length, body.length);
      final wrong = await call('POST', '/market/report', body: other, headers: signed);
      expect((wrong.status, wrong.error), (400, 'bad_request'), reason: 'the body isn\'t what its hash said');
      final long = maya.headers('POST', '/market/report', body, time: now.millisecondsSinceEpoch + 3)..[Files.bodyLengthHeader] = '${body.length + 1}';
      expect((await call('POST', '/market/report', body: body, headers: long)).error, 'bad_request', reason: 'a length that isn\'t Content-Length');
      expect((await call('POST', '/market/report', as: maya, json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam'})).error, 'not_found', reason: 'signed as it should be, it gets as far as the plugin');
    });

    test('a body larger than the market takes is refused before it is read', () async {
      await relay.stop();
      await boot(config: const MarketConfig(maxBody: 1000));
      final body = List.filled(2000, 0x20);
      final head = headOf('POST', '/market/submissions', maya.headers('POST', '/market/submissions', body, time: now.millisecondsSinceEpoch), body.length);
      // Refused unread, with its connection: dart:io lets the head out before it drops the connection, and the words
      // with it, as it does for Files' pieces refused unread (files_hardening_test.dart).
      final answer = await raw(head);
      expect(statusOf(answer), 413);
      expect(answer.toLowerCase(), contains('connection: close'));
    });

    test('a body that stops coming is refused once it has paused too long', () async {
      await relay.stop();
      await boot(bodyPause: const Duration(milliseconds: 200));
      final body = utf8.encode(jsonEncode({'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': 'x' * 100}));
      final head = headOf('POST', '/market/report', maya.headers('POST', '/market/report', body, time: now.millisecondsSinceEpoch), body.length);
      final answer = await raw(head, body: body.sublist(0, 20));
      expect(statusOf(answer), 400);
      expect((await call('GET', '/market')).status, 200, reason: 'and the market goes on');
    });

    test('a hundred fresh keys from one address: refused after sixty, with at most sixty signature checks', () async {
      fake = (key, message, sig) => true;
      final got = <int>[];
      for (var i = 0; i < 100; i++) {
        // Three a second of the market's clock, within its twenty checks a second and its minute.
        now = now.add(const Duration(milliseconds: 300));
        got.add((await call('GET', '/market/mine', headers: fakeSigned(fakeKey(i), now.millisecondsSinceEpoch), address: '203.0.113.9')).status);
      }
      expect(got.take(60), everyElement(200));
      expect(got.skip(60), everyElement(429));
      expect(verifies, 60);
      expect((await call('GET', '/market/mine', headers: fakeSigned(fakeKey(100), now.millisecondsSinceEpoch), address: '203.0.113.10')).status, 200, reason: 'another address is not held');
    });

    test('an unsigned 6 MiB POST is answered without its body being read', () async {
      final answer = await raw('POST /market/submissions HTTP/1.1\r\nHost: relay.test\r\nContent-Length: 6291456\r\n\r\n');
      expect(statusOf(answer), 401);
      expect(answer.toLowerCase(), contains('connection: close'));
    });

    test('past twenty signature checks in one second of the clock, busy; the next second, not', () async {
      fake = (key, message, sig) => true;
      final got = [
        for (var i = 0; i < 21; i++) (await call('GET', '/market/mine', headers: fakeSigned(fakeKey(i), now.millisecondsSinceEpoch), address: '198.51.100.$i')),
      ];
      expect(got.take(20).map((a) => a.status), everyElement(200));
      expect((got.last.status, got.last.error), (503, 'busy'));
      expect(verifies, 20);
      now = now.add(const Duration(seconds: 1));
      expect((await call('GET', '/market/mine', headers: fakeSigned(fakeKey(21), now.millisecondsSinceEpoch), address: '198.51.100.21')).status, 200);
    });

    test('a fourth large body in flight is busy', () async {
      final heard = [Completer<void>(), Completer<void>(), Completer<void>()];
      var checks = 0;
      fake = (key, message, sig) {
        if (checks < heard.length) heard[checks].complete();
        checks++;
        return true;
      };
      const length = 100000;
      final sha = shaOf(List.filled(length, 0x20));
      // Each from an address and a key of its own: one of each holds one large body at a time.
      String head(int i) => headOf('POST', '/market/submissions', {...fakeSigned(fakeKey('large $i'), now.millisecondsSinceEpoch), Files.bodyShaHeader: sha, Files.bodyLengthHeader: '$length', 'x-forwarded-for': '198.51.100.${40 + i}'}, length);
      final held = <Socket>[];
      try {
        for (var i = 0; i < 3; i++) {
          final s = await Socket.connect('127.0.0.1', port);
          held.add(s);
          s.write(head(i));
          s.add(List.filled(10, 0x20));
          await s.flush();
          // Its slot is taken once its signature is checked, before its body is read.
          await heard[i].future;
        }
        final fourth = await raw(head(3), body: List.filled(10, 0x20));
        expect(statusOf(fourth), 503);
        expect((await call('GET', '/market/mine', headers: fakeSigned(fakeKey('small'), now.millisecondsSinceEpoch), address: '10.9.9.9')).status, 200, reason: 'a request with no body is not held');
      } finally {
        for (final s in held) {
          s.destroy();
        }
      }
    });

    test('a signing header sent twice is a bad request, before anything is counted', () async {
      // dart:io's value() throws for a header that comes twice, which reached the catch-all as a 500 broken and a line on
      // stderr for each, a stranger's at no cost (review, 2026-11-20).
      final once = maya.headers('GET', '/market/mine', const [], time: now.millisecondsSinceEpoch);
      String lines(Map<String, String> h) => h.entries.map((e) => '${e.key}: ${e.value}\r\n').join();
      for (final twice in ['x-ghost-key', 'x-ghost-time', 'x-ghost-sig']) {
        for (var i = 0; i < 25; i++) {
          final answer = await raw('GET /market/mine HTTP/1.1\r\nHost: relay.test\r\nx-forwarded-for: 203.0.113.7\r\n${lines(once)}$twice: ${once[twice]}\r\n\r\n');
          expect(statusOf(answer), 400, reason: twice);
          expect(answer, contains('"error":"bad_request"'), reason: twice);
        }
      }
      final body = utf8.encode(jsonEncode({'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': ''}));
      final signed = maya.headers('POST', '/market/report', body, time: now.millisecondsSinceEpoch + 1);
      for (final twice in [Files.bodyShaHeader, Files.bodyLengthHeader]) {
        final answer = await raw('${headOf('POST', '/market/report', {...signed, 'x-forwarded-for': '203.0.113.7'}, body.length).replaceFirst('\r\n\r\n', '\r\n$twice: ${signed[twice]}\r\n\r\n')}', body: body);
        expect(statusOf(answer), 400, reason: twice);
      }
      expect(verifies, 0, reason: 'no signature was checked');
      expect((await call('GET', '/market/mine', as: maya, address: '203.0.113.7')).status, 200, reason: 'nor the address\'s sixty a minute spent');
    });

    test('bodies read and waiting their turn at route 8 keep their slots: a fourth large one is busy until route 8 is done with them', () async {
      // A slot was given back as soon as the body was read, so any number of read bodies waited in memory for route 8
      // behind a submission's writes, past the bound of 3 × maxBody (review, 2026-11-20).
      fake = (key, message, sig) => true;
      final entered = Completer<void>(), gate = Completer<void>();
      market.debugAfterWrites = () async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
      };
      final honest = submit(maya, packOf());
      await entered.future;
      var read = 0;
      final allRead = Completer<void>();
      market.debugAfterRead = () {
        if (++read == 3) allRead.complete();
      };
      const length = 100000;
      final body = List.filled(length, 0x20);
      Future<Answer> large(int i) => call('POST', '/market/submissions', body: body, address: '198.51.100.${60 + i}', headers: {...fakeSigned(fakeKey('held $i'), now.millisecondsSinceEpoch), Files.bodyShaHeader: shaOf(body), Files.bodyLengthHeader: '$length'});
      final waiting = [for (var i = 0; i < 3; i++) large(i)];
      await allRead.future;
      final fourth = await large(3);
      expect((fourth.status, fourth.error), (503, 'busy'), reason: 'three read and waiting hold every slot');
      gate.complete();
      expect((await honest).status, 201);
      for (final w in waiting) {
        expect((await w).error, 'bad_json', reason: 'read whole, then judged by route 8 in its turn');
      }
      market.debugAfterWrites = null;
      market.debugAfterRead = null;
      expect((await large(4)).error, 'bad_json', reason: 'their slots given back once route 8 was done with them');
    });

    test('one address and one key hold one large body at a time; another\'s is read meanwhile', () async {
      // One key at one address held all three slots by trickling three bodies, a byte every 20 s, and opening three more
      // each minute, within every budget: nobody could send a screenshot (review, 2026-11-20).
      final heard = <Completer<void>>[for (var i = 0; i < 4; i++) Completer<void>()];
      var checks = 0;
      fake = (key, message, sig) {
        if (checks < heard.length) heard[checks].complete();
        checks++;
        return true;
      };
      const length = 100000;
      final body = List.filled(length, 0x20);
      final sha = shaOf(body);
      final trickler = fakeKey('trickler');
      // Connection: close, so a body that is read has its answer end with its connection.
      String head(List<int> key, String address, int at) => headOf('POST', '/market/submissions', {...fakeSigned(key, at), Files.bodyShaHeader: sha, Files.bodyLengthHeader: '$length', 'x-forwarded-for': address, 'connection': 'close'}, length);
      final held = await Socket.connect('127.0.0.1', port);
      try {
        held.write(head(trickler, '203.0.113.7', now.millisecondsSinceEpoch));
        held.add(List.filled(10, 0x20));
        await held.flush();
        await heard[0].future;
        expect(statusOf(await raw(head(fakeKey('second'), '203.0.113.7', now.millisecondsSinceEpoch + 1), body: List.filled(10, 0x20))), 429, reason: 'its address has one being read');
        expect(statusOf(await raw(head(trickler, '203.0.113.8', now.millisecondsSinceEpoch + 2), body: List.filled(10, 0x20))), 429, reason: 'its key has one being read');
        // Another key at another address: read whole, and only then refused, for what it is.
        final other = await raw(head(fakeKey('developer'), '198.51.100.77', now.millisecondsSinceEpoch + 3), body: body);
        expect(statusOf(other), 400);
        expect(other, contains('"bad_json"'), reason: 'its body was read: it holds no JSON');
      } finally {
        held.destroy();
      }
    });

    test('a large body that falls behind is ended, and its slot taken by another', () async {
      await relay.stop();
      await boot(bodyRateEvery: const Duration(milliseconds: 300));
      fake = (key, message, sig) => true;
      const length = 100000;
      final body = List.filled(length, 0x20);
      final sha = shaOf(body);
      String head(Object n, String address, int at) => headOf('POST', '/market/submissions', {...fakeSigned(fakeKey(n), at), Files.bodyShaHeader: sha, Files.bodyLengthHeader: '$length', 'x-forwarded-for': address, 'connection': 'close'}, length);
      // Three trickles, a few bytes and no more, well within the pause between pieces: each is ended once it falls behind
      // the rate a slot is held to, long before its minute.
      final watch = Stopwatch()..start();
      final ended = await Future.wait([for (var i = 0; i < 3; i++) raw(head('trickle $i', '203.0.113.${20 + i}', now.millisecondsSinceEpoch + i), body: List.filled(10, 0x20))]);
      expect([for (final a in ended) statusOf(a)], [400, 400, 400]);
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)), reason: 'not its whole minute');
      final next = await raw(head('developer', '198.51.100.78', now.millisecondsSinceEpoch + 9), body: body);
      expect(next, contains('"bad_json"'), reason: 'the slots are free again: read whole');
    });

    test('after 20,001 good requests from many addresses the next still gets in, and a recent one sent again still does not', () async {
      await relay.stop();
      await boot(config: const MarketConfig(verifyASecond: 1000));
      fake = (key, message, sig) => true;
      final keys = [for (var i = 0; i < 101; i++) fakeKey('many $i')];
      Map<String, String> nth(int i) => fakeSigned(keys[i % keys.length], now.millisecondsSinceEpoch + i);
      var bad = 0;
      Future<void> run(int from, int to) async {
        final client = HttpClient();
        try {
          for (var i = from; i < to; i++) {
            // Two milliseconds a request: 500 checks a second, and the ten minutes of remembered requests never run out.
            now = now.add(const Duration(milliseconds: 2));
            final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/market/mine'));
            req.headers.set('x-forwarded-for', '10.${i ~/ 40 ~/ 256}.${(i ~/ 40) % 256}.1');
            nth(i).forEach(req.headers.set);
            final res = await req.close();
            await res.drain<void>();
            if (res.statusCode != 200) bad++;
          }
        } finally {
          client.close(force: true);
        }
      }

      await Future.wait([for (var w = 0; w < 4; w++) run(w * 5001, w * 5001 + 5001)]);
      expect(bad, 0);
      expect(verifies, 20004);
      final last = nth(30000);
      expect((await call('GET', '/market/mine', headers: last, address: '10.200.0.1')).status, 200, reason: 'the 20,002nd: the oldest remembered went, not this');
      expect((await call('GET', '/market/mine', headers: last, address: '10.200.0.2')).error, 'bad_signature', reason: 'and what it signed is remembered');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  Future<(int, String?)> code(Future<Answer> f) async {
    final a = await f;
    return (a.status, a.error);
  }

  /// The market started again with nothing kept and [config]'s limits.
  Future<void> fresh(MarketConfig config) async {
    await relay.stop();
    final kept = Directory('${dir.path}/market');
    if (kept.existsSync()) kept.deleteSync(recursive: true);
    await boot(config: config);
  }

  group('errors', () {
    test('a package nested 131,072 deep is refused before it is decoded, and the market answers after it', () async {
      final deep = Uint8List.fromList([...List.filled(131072, 0x5B), ...List.filled(131072, 0x5D)]);
      final got = await submit(maya, deep);
      expect((got.status, got.error), (400, 'invalid_package'));
      expect([for (final i in got.json['issues'] as List) (i['code'], i['path'])], [('too_deep', '')]);
      expect((await call('GET', '/market')).status, 200);
    });

    test('a screenshot\'s number that isn\'t one digit is no path at all, never parsed as a number', () async {
      expect(await code(call('GET', '/market/submissions/${'a' * 24}/shots/99999999999999999999', as: maya)), (404, 'not_found'));
      expect(await code(call('GET', '/market/submissions/${'a' * 24}/shots/x')), (404, 'not_found'));
      expect(await code(call('GET', '/market/submissions/${'a' * 24}/shots/1', as: maya)), (404, 'not_found'), reason: 'a path, but no such submission');
    });

    test('a handler that throws answers 500 broken, and the relay and its one-at-a-time submissions go on', () async {
      throwsFor.add(theo.id);
      expect(await code(submit(theo, packOf(developer: 'theo'))), (500, 'broken'));
      expect((await call('GET', '/market')).status, 200);
      expect((await submit(maya, packOf())).status, 201, reason: 'the chain route 8 runs through wasn\'t broken by it');
    });

    test('a path whose escapes aren\'t UTF-8 is a 400, and the relay and the market go on', () async {
      // The relay decoded the path before routing anything, outside the market's guard: GET /market/%FF ended it, and
      // every hub connection with it, and one every two seconds kept it down (review, 2026-11-20).
      for (final path in ['/market/%FF', '/market/%C3%28', '/market/%E0%A4', '/files/%FF', '/%FF', '/relay/%ff', '/link/%C3%28', '/word/%FF']) {
        final answer = await raw('GET $path HTTP/1.1\r\nHost: relay.test\r\n\r\n');
        expect(statusOf(answer), 400, reason: path);
      }
      expect((await call('GET', '/market')).status, 200, reason: 'still listening');
      expect((await submit(maya, packOf())).status, 201);
    });

    test('GET /market says what the store takes', () async {
      final got = await call('GET', '/market');
      expect(got.headers.contentType?.mimeType, 'application/json');
      expect(got.headers.contentType?.charset, 'utf-8');
      expect(got.headers.value('cache-control'), 'no-cache');
      expect(got.headers.value('content-security-policy'), "default-src 'none'; frame-ancestors 'none'; sandbox");
      expect(got.headers.value('referrer-policy'), 'no-referrer');
      expect(got.json, {
        'ok': true,
        'market': 1,
        'format': 'ghost-plugin/1',
        'open': true,
        'limits': {'package': 262144, 'icon': 48000, 'shot': 1048576, 'shotSide': 2400, 'shots': 4, 'body': 6291456, 'notes': 1000},
        'labels': ['bills', 'codes', 'deliveries', 'events', 'filters', 'health', 'language', 'money', 'quiet', 'replies', 'safety', 'school', 'shopping', 'sorting', 'travel', 'work'],
        'shelves': ['organise', 'safety', 'messages', 'tools'],
        'hues': ['amber', 'blue', 'coral', 'cyan', 'green', 'indigo', 'lime', 'magenta', 'mint', 'orange', 'purple', 'red', 'rose', 'slate', 'yellow', 'graphite'],
        'permissions': ['sort', 'move', 'markread', 'mute', 'copy', 'write', 'links'],
      });
      expect((await call('GET', '/market/')).json['format'], 'ghost-plugin/1');
    });
  });

  group('submissions', () {
    test('a good one is 201, and in mine, with its notes and its screenshots', () async {
      final a = shotPng(1), b = shotPng(2);
      final package = packOf(shots: [shaOf(a), shaOf(b)]);
      final got = await submit(maya, package, shots: [shotOf(a), shotOf(b)], notes: 'Try it on s01.\nThanks!');
      expect(got.status, 201, reason: '$got');
      expect(got.headers.value('cache-control'), 'no-store');
      final s = got.json['submission'] as Map;
      expect(s.keys.toSet(), {'sid', 'plugin', 'version', 'sha256', 'size', 'status', 'name', 'tagline', 'description', 'symbol', 'hue', 'shelf', 'labels', 'permissions', 'links', 'developer', 'support', 'whatsNew', 'minApp', 'submittedAt', 'updatedAt', 'notes', 'shots', 'list', 'listing', 'revoked'});
      expect(s['sid'], matches(RegExp(r'^[0-9a-f]{24}$')));
      expect([s['plugin'], s['version'], s['sha256'], s['size'], s['status'], s['name'], s['symbol'], s['hue'], s['shelf'], s['developer'], s['support'], s['list'], s['listing'], s['revoked'], s['whatsNew'], s['minApp']],
          ['mybills', '1.0.0', shaOf(package), package.length, 'submitted', 'Bills', 'calculator', 'amber', 'organise', 'maya', 'https://example.com/plugins/bills', 'now', null, null, null, null]);
      expect([s['labels'], s['permissions'], s['links']], [['bills', 'money', 'sorting'], ['sort', 'copy', 'markread'], <String>[]]);
      expect(s['notes'], [{'at': now.millisecondsSinceEpoch, 'by': 'developer', 'text': 'Try it on s01.\nThanks!', 'status': null}]);
      expect(s['shots'], [{'sha256': shaOf(a), 'mime': 'image/png'}, {'sha256': shaOf(b), 'mime': 'image/png'}]);
      final mine = (await call('GET', '/market/mine', as: maya)).json;
      expect(mine['blocked'], false);
      expect([for (final x in mine['submissions'] as List) x['sid']], [s['sid']]);
      expect(mine['plugins'], [{'id': 'mybills', 'listing': 'none', 'current': null, 'by': null, 'note': null, 'noteAt': null}]);
      expect((await call('GET', '/market/submissions/${s['sid']}', as: maya)).json['submission'], s);
      expect((await call('GET', '/market/submissions/${s['sid']}/package', as: maya)).bytes, package);
      expect((await call('GET', '/market/submissions/${s['sid']}/shots/1', as: maya)).bytes, b);
      expect(await code(call('GET', '/market/submissions/${s['sid']}/shots/2', as: maya)), (404, 'not_found'));
      expect(await code(call('GET', '/market/submissions/${s['sid']}', as: sam)), (403, 'not_admin'), reason: 'nobody\'s but hers and review\'s');
      expect((await call('GET', '/market/mine', as: sam)).json['submissions'], isEmpty);
    });

    test('each refusal of a submission, with its code', () async {
      expect(await code(submit(maya, packOf(developer: 'sam'))), (403, 'not_owner'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'agree': false})), (400, 'must_agree'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf())})), (400, 'must_agree'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'agree': true, 'extra': 1})), (400, 'bad_request'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'agree': true, 'list': 'soon'})), (400, 'bad_request'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'agree': true, 'notes': 'Hi\u{200B}'})), (400, 'bad_request'), reason: 'notes keep the words rule');
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': '${base64Encode(packOf())}\n', 'agree': true})), (400, 'bad_request'), reason: 'not base64 as the app writes it');
      expect(await code(call('POST', '/market/submissions', as: maya, body: utf8.encode('{"package":'))), (400, 'bad_json'));
      final pretty = utf8.encode(const JsonEncoder.withIndent('  ').convert(jsonDecode(utf8.decode(packOf()))));
      expect(await code(submit(maya, Uint8List.fromList(pretty))), (400, 'not_canonical'));
      final fraction = utf8.encode(utf8.decode(packOf()).replaceFirst('"version":"1.0.0"', '"version":"1.0.0","x":1.5'));
      expect(await code(submit(maya, Uint8List.fromList(fraction))), (400, 'not_canonical'));
      final badUtf8 = await submit(maya, Uint8List.fromList([0x7B, 0xFF, 0x7D]));
      expect([for (final i in badUtf8.json['issues'] as List) i['code']], ['bad_json']);
      final invalid = await submit(maya, packOf(developer: 'ghostdev'));
      expect((invalid.status, invalid.error), (400, 'invalid_package'));
      expect(invalid.json['issues'], [{'code': 'bad_developer', 'path': 'developer', 'message': isA<String>(), 'severity': 'error'}]);
      final example = await submit(maya, packOf(id: 'bills'));
      expect([for (final i in example.json['issues'] as List) (i['code'], i['path'])], [('id_example', 'id')]);
      final noIcon = await submit(maya, canonicalBytes((jsonDecode(utf8.decode(packOf())) as Map)..remove('icon')));
      expect([for (final i in noIcon.json['issues'] as List) (i['code'], i['path'])], [('missing', 'icon')]);

      claimed[maya.id] = now.subtract(const Duration(days: 6));
      expect(await code(submit(maya, packOf())), (403, 'too_new'));
      claimed[maya.id] = now.subtract(const Duration(days: 7));
      expect((await submit(maya, packOf())).status, 201);
      expect(await code(submit(maya, packOf(), address: '10.0.0.2')), (409, 'duplicate'));
      expect(await code(submit(sam, packOf(developer: 'sam'), address: '10.0.0.3')), (409, 'id_taken'));
      // Maya gives up her username and Sam claims it: plugins sent under it are still hers.
      names[sam.id] = 'maya';
      names.remove(maya.id);
      expect(await code(submit(sam, packOf(id: 'otherbills'), address: '10.0.0.3')), (409, 'name_used'));
      names[maya.id] = 'maya';
      names[sam.id] = 'sam';

      final a = shotPng(1), b = shotPng(2);
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(a)]), shots: [shotOf(b)], address: '10.0.0.2')), (400, 'bad_shot'), reason: 'not the screenshot the package lists');
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(a), shaOf(b)]), shots: [shotOf(b), shotOf(a)], address: '10.0.0.2')), (400, 'bad_shot'), reason: 'not in its order');
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(a)]), address: '10.0.0.2')), (400, 'bad_shot'), reason: 'none sent');
      final narrow = shotPng(3, w: 63);
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(narrow)]), shots: [shotOf(narrow)], address: '10.0.0.2')), (400, 'bad_shot'), reason: '63 pixels wide');
      final jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9];
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(jpeg)]), shots: [{'mime': 'image/jpeg', 'data': base64Encode(jpeg)}], address: '10.0.0.2')), (400, 'bad_shot'));
      final samShot = shotPng(9);
      expect((await submit(sam, packOf(id: 'samsbills', developer: 'sam', shots: [shaOf(samShot)]), shots: [shotOf(samShot)], address: '10.0.0.3')).status, 201);
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(samShot)]), shots: [{'keep': shaOf(samShot)}], address: '10.0.0.2')), (400, 'bad_shot'), reason: 'a screenshot kept from someone else\'s plugin');
      expect(await code(submit(maya, packOf(version: '1.0.1', shots: [shaOf(a)]), shots: [{'keep': shaOf(a)}], address: '10.0.0.2')), (400, 'bad_shot'), reason: 'one that was never sent');
    });

    test('the store\'s limits, each with its code', () async {
      final zoe = Sender(6);
      names[zoe.id] = 'zoe';
      claimed[zoe.id] = DateTime.utc(2026, 10, 1);

      await fresh(const MarketConfig(needVerified: true));
      expect(await code(submit(theo, packOf(developer: 'theo'))), (403, 'needs_verified'));
      expect((await submit(maya, packOf())).status, 201);

      await fresh(const MarketConfig(pluginsPerDeveloper: 1));
      expect((await submit(maya, packOf())).status, 201);
      expect(await code(submit(maya, packOf(id: 'secondbills'), address: '10.0.0.2')), (429, 'too_many_plugins'));
      expect((await submit(maya, packOf(version: '1.0.1'), address: '10.0.0.3')).status, 201, reason: 'a new version of the one she has');

      await fresh(const MarketConfig(bytesPerDeveloper: 3000));
      final big = shotPng(1, fill: 1200);
      expect(await code(submit(maya, packOf(shots: [shaOf(big)]), shots: [shotOf(big)])), (507, 'developer_full'));
      expect((await submit(maya, packOf(), address: '10.0.0.2')).status, 201);

      await fresh(const MarketConfig(total: 1000));
      expect(await code(submit(maya, packOf())), (507, 'full'));

      await fresh(const MarketConfig(openUnverified: 1));
      expect((await submit(theo, packOf(id: 'theobills', developer: 'theo'))).status, 201);
      expect(await code(submit(zoe, packOf(id: 'zoebills', developer: 'zoe'), address: '10.0.0.2')), (429, 'open_limit'), reason: 'the unverified share is taken');
      expect((await submit(maya, packOf(), address: '10.0.0.3')).status, 201, reason: 'a verified developer isn\'t held by it');

      await fresh(const MarketConfig(submissionsPerAddress: 10, openPerAddress: 2));
      expect((await submit(maya, packOf(), address: '192.0.2.7')).status, 201);
      expect((await submit(sam, packOf(id: 'samsbills', developer: 'sam'), address: '192.0.2.7')).status, 201);
      expect(await code(submit(ada, packOf(id: 'adasbills', developer: 'ada'), address: '192.0.2.7')), (429, 'open_limit'));
      expect((await submit(maya, packOf(version: '1.0.1'), address: '192.0.2.7')).status, 201, reason: 'replacing her own waiting one');

      await fresh(const MarketConfig(openPerDeveloper: 2));
      expect((await submit(maya, packOf(id: 'onebills'), address: '10.0.0.1')).status, 201);
      expect((await submit(maya, packOf(id: 'twobills'), address: '10.0.0.2')).status, 201);
      expect(await code(submit(maya, packOf(id: 'threebills'), address: '10.0.0.3')), (429, 'open_limit'));

      // The day's submissions from one address, and by one someone.
      await fresh(const MarketConfig());
      for (final (who, id) in [(maya, 'onebills'), (sam, 'twobills'), (ada, 'threebills')]) {
        expect((await submit(who, packOf(id: id, developer: names[who.id]!), address: '192.0.2.1')).status, 201);
      }
      expect(await code(submit(theo, packOf(id: 'fourbills', developer: 'theo'), address: '192.0.2.1')), (429, 'rate_limited'));
      for (var v = 1; v <= 4; v++) {
        expect((await submit(maya, packOf(id: 'onebills', version: '1.0.$v'), address: '192.0.2.${10 + v}')).status, 201);
      }
      expect(await code(submit(maya, packOf(id: 'onebills', version: '1.0.5'), address: '192.0.2.20')), (429, 'rate_limited'), reason: 'five a day by one someone');

      await fresh(const MarketConfig());
      await approved(maya, packOf());
      expect(await code(submit(maya, packOf(changes: {'tagline': 'Bills, in a tab'}), address: '10.0.0.2')), (409, 'version_not_newer'));
      expect(await code(submit(maya, packOf(version: '0.9.0'), address: '10.0.0.3')), (409, 'version_not_newer'));
    });

    test('an id held after a withdrawal counts again as it opens: no way past either plugin limit by withdrawing', () async {
      // Counted for new ids alone, a developer at the cap could withdraw ids and open them again later past both
      // limits, by any number (review, 2026-11-20).
      await fresh(const MarketConfig(pluginsPerDeveloper: 1));
      final first = ((await submit(maya, packOf(id: 'onebills'))).json['submission'] as Map)['sid'] as String;
      expect((await call('DELETE', '/market/submissions/$first', as: maya)).status, 200);
      expect((await submit(maya, packOf(id: 'twobills'), address: '10.0.0.2')).status, 201);
      expect(await code(submit(maya, packOf(id: 'onebills', version: '1.0.1'), address: '10.0.0.3')), (429, 'too_many_plugins'));
      expect((await submit(maya, packOf(id: 'twobills', version: '1.0.1'), address: '10.0.0.4')).status, 201, reason: 'the id she has takes new versions');
      final mine = (await call('GET', '/market/mine', as: maya)).json['submissions'] as List;
      expect({for (final s in mine) if (s['status'] == 'submitted') s['plugin']}, {'twobills'});

      await fresh(const MarketConfig(maxPlugins: 1));
      final held = ((await submit(ada, packOf(id: 'adasbills', developer: 'ada'))).json['submission'] as Map)['sid'] as String;
      expect((await call('DELETE', '/market/submissions/$held', as: ada)).status, 200);
      await approved(maya, packOf());
      expect(await code(submit(ada, packOf(id: 'adasbills', developer: 'ada', version: '1.0.1'), address: '10.0.0.5')), (429, 'too_many_plugins'), reason: 'the market is full, held id or not');
    });

    test('a version approved while a submission\'s files are written leaves no older one waiting to be listed', () async {
      // Route 16 isn't one at a time with route 8: an approve that came between 1.1.0's checks and its record left 1.1.0
      // waiting under a current 1.2.0, and approving it then listed the older version (review, 2026-11-20).
      for (final (version, changes) in [('1.1.0', const <String, Object?>{}), ('1.2.0', {'tagline': 'Bills, in a tab'})]) {
        await fresh(const MarketConfig());
        await approved(maya, packOf());
        final waiting = (await submit(maya, packOf(version: '1.2.0'), address: '10.0.0.2')).json['submission'] as Map;
        adminAt[matt.id] = now;
        var decided = 0;
        market.debugAfterWrites = () async {
          if (decided++ > 0) return;
          final got = await decide(waiting['sid'] as String, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.2.0', waiting['sha256'] as String)});
          expect(got.status, 200, reason: '$got');
        };
        final picture = shotPng(40 + decided);
        final refusedPackage = packOf(version: version, changes: changes, shots: [shaOf(picture)]);
        expect(await code(submit(maya, refusedPackage, shots: [shotOf(picture)], address: '10.0.0.3')), (409, 'version_not_newer'), reason: version);
        market.debugAfterWrites = null;
        expect(decided, 1);
        // What it wrote goes with it: no submission names it, so no sweep would ever have found it (review, 2026-11-20).
        expect(File('${dir.path}/market/packages/${shaOf(refusedPackage)}').existsSync(), isFalse, reason: version);
        expect(File('${dir.path}/market/shots/${shaOf(picture)}').existsSync(), isFalse, reason: version);
        expect([for (final e in (await call('GET', '/market/catalog')).json['plugins'] as List) (e['id'], e['version'])], [('mybills', '1.2.0')]);
        final mine = (await call('GET', '/market/mine', as: maya)).json['submissions'] as List;
        expect([for (final s in mine) if (s['status'] == 'submitted' || s['status'] == 'in_review') s['version']], isEmpty, reason: 'nothing older left to approve');
        // And the day's five are two sent and three to come: the refused one isn't counted.
        expect([for (var v = 3; v <= 6; v++) (await submit(maya, packOf(version: '1.$v.0'), address: '10.0.2.$v')).status], [201, 201, 201, 429]);
      }
    });

    test('a package of some 87,000 empty permissions from a key with no username is answered in a few KB', () async {
      // Any fresh key reached the structural checks, before its owner was asked, and had 87,308 issues built and sent
      // back: 14 MB, and 116 ms of the hub's one isolate a request (review, 2026-11-20).
      final stranger = Sender(40);
      final j = (jsonDecode(utf8.decode(packOf())) as Map).cast<String, Object?>()..['permissions'] = <String>[];
      // As many as fit in the largest package: each "" and its comma is three bytes.
      j['permissions'] = List.filled((262144 - canonicalBytes(j).length) ~/ 3, '');
      final package = canonicalBytes(j);
      expect(package.length, lessThanOrEqualTo(262144));
      expect((j['permissions'] as List).length, greaterThan(86000));
      final got = await call('POST', '/market/submissions', as: stranger, json: {'package': base64Encode(package), 'check': true});
      expect((got.status, got.error), (400, 'invalid_package'));
      expect([for (final i in got.json['issues'] as List) i['code']], ['too_many', ...List.filled(packPermissions.length, 'bad_permission')]);
      expect(got.bytes.length, lessThan(8 * 1024));
    });

    test('name_used holds every name another developer\'s plugins were sent under, not only the first', () async {
      // Only the name a plugin was first sent under was held: renamed, its update approved under the new name and
      // listed "By @" it, then renamed again, the developer left that name to whoever claimed it next, and two keys'
      // plugins were listed under one name (review, 2026-11-20).
      await approved(maya, packOf());
      names[maya.id] = 'mia';
      await approved(maya, packOf(version: '1.0.1', developer: 'mia'));
      expect([for (final e in (await call('GET', '/market/catalog')).json['plugins'] as List) e['version']], ['1.0.1']);
      names[maya.id] = 'mora';
      names[sam.id] = 'mia';
      expect(await code(submit(sam, packOf(id: 'evilbills', developer: 'mia'), address: '10.0.0.5')), (409, 'name_used'));
      names[sam.id] = 'maya';
      expect(await code(submit(sam, packOf(id: 'evilbills', developer: 'maya'), address: '10.0.0.6')), (409, 'name_used'), reason: 'the first name, as ever');
      expect((await submit(maya, packOf(version: '1.0.2', developer: 'mora'), address: '10.0.0.7')).status, 201, reason: 'her own names stay hers to use');
    });

    test('a first submission of a released id that fails as its files are written leaves the id free', () async {
      // Its record was taken back only where no submission named the id at all, and a released id keeps its earlier
      // developer's closed submissions: the record stayed, with no submission and no openUntil, and held the id for
      // good, against no limit of its holder's (review, 2026-11-20).
      final first = ((await submit(maya, packOf(id: 'coolbills'))).json['submission'] as Map)['sid'] as String;
      expect((await call('DELETE', '/market/submissions/$first', as: maya)).status, 200);
      now = now.add(const Duration(days: 31));
      await market.sweep();
      market.debugAfterWrites = () async => throw const FileSystemException('No space left on device');
      expect(await code(submit(sam, packOf(id: 'coolbills', developer: 'sam'), address: '10.0.0.2')), (500, 'broken'));
      market.debugAfterWrites = null;
      expect((await call('GET', '/market/mine', as: sam)).json['plugins'], isEmpty, reason: 'no record of an id it never sent');
      expect((await submit(ada, packOf(id: 'coolbills', developer: 'ada'), address: '10.0.0.3')).status, 201, reason: 'free for anyone');
    });

    test('a check stores nothing and counts nothing, and asks for no icon or help link yet', () async {
      for (var i = 0; i < 8; i++) {
        expect((await call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'check': true})).json, {'ok': true, 'checked': true});
      }
      final bare = (jsonDecode(utf8.decode(packOf())) as Map)
        ..remove('icon')
        ..remove('support');
      expect((await call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(canonicalBytes(bare)), 'check': true})).json, {'ok': true, 'checked': true});
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf(developer: 'sam')), 'check': true})), (403, 'not_owner'));
      expect(await code(call('POST', '/market/submissions', as: maya, json: {'package': base64Encode(packOf()), 'check': true, 'agree': true})), (400, 'bad_request'), reason: 'a check is the package and nothing else');
      expect((await call('GET', '/market/mine', as: maya)).json['submissions'], isEmpty);
      expect(Directory('${dir.path}/market/packages').existsSync(), isFalse, reason: 'nothing stored');
      // Five a day by one someone, all of them still to come.
      for (var v = 0; v < 5; v++) {
        expect((await submit(maya, packOf(version: '1.0.$v'), address: '10.0.1.$v')).status, 201);
      }
    });

    test('withdrawn by its developer, once, and by nobody else', () async {
      final sid = ((await submit(maya, packOf())).json['submission'] as Map)['sid'] as String;
      expect(await code(call('DELETE', '/market/submissions/$sid', as: sam)), (404, 'not_found'));
      final got = await call('DELETE', '/market/submissions/$sid', as: maya);
      expect(got.json['submission']['status'], 'withdrawn');
      expect((got.json['submission']['notes'] as List).last, {'at': now.millisecondsSinceEpoch, 'by': 'developer', 'text': 'Withdrawn.', 'status': 'withdrawn'});
      expect(await code(call('DELETE', '/market/submissions/$sid', as: maya)), (409, 'wrong_state'));
    });

    test('a new version replaces the one waiting', () async {
      final first = ((await submit(maya, packOf())).json['submission'] as Map)['sid'];
      now = now.add(const Duration(minutes: 1));
      final second = ((await submit(maya, packOf(version: '1.0.1'), address: '10.0.0.2')).json['submission'] as Map)['sid'];
      final at = now.millisecondsSinceEpoch;
      final mine = (await call('GET', '/market/mine', as: maya)).json['submissions'] as List;
      expect([for (final s in mine) (s['sid'], s['status'])], [(second, 'submitted'), (first, 'superseded')]);
      expect((mine.last['notes'] as List).last, {'at': at, 'by': 'developer', 'text': 'Replaced by 1.0.1.', 'status': 'superseded'});
    });

    test('two first submissions of one new id from two keys at once: one 201, the other id_taken', () async {
      final got = await Future.wait([submit(maya, packOf(id: 'sameid')), submit(sam, packOf(id: 'sameid', developer: 'sam'), address: '10.0.0.2')]);
      expect([for (final a in got) a.status]..sort(), [201, 409]);
      expect(got.firstWhere((a) => a.status == 409).error, 'id_taken');
    });
  });

  group('review', () {
    test('only a signed-in admin; an approve 31 minutes after signing in is not_admin, a start is not', () async {
      final package = packOf();
      final sid = ((await submit(maya, package)).json['submission'] as Map)['sid'] as String;
      expect(await code(call('GET', '/market/review', as: maya)), (403, 'not_admin'));
      expect(await code(call('GET', '/market/review', as: matt)), (403, 'not_admin'), reason: 'not signed in');
      adminAt[matt.id] = now;
      expect((await call('GET', '/market/review', as: matt)).status, 200);
      now = now.add(const Duration(minutes: 31));
      expect(await code(decide(sid, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.0.0', shaOf(package))})), (403, 'not_admin'));
      expect((await decide(sid, {'decision': 'start'})).json['submission']['status'], 'in_review');
      expect(await code(call('GET', '/market/review/$sid', as: maya)), (403, 'not_admin'));
      now = adminAt[matt.id]!.add(const Duration(hours: 8));
      expect(await code(call('GET', '/market/review', as: matt)), (403, 'not_admin'), reason: 'eight hours on');
    });

    test('the queue, and an item with the version before it, what review asked last time, and again', () async {
      final v1 = await approved(maya, packOf());
      now = now.add(const Duration(minutes: 1));
      final asked = ((await submit(maya, packOf(version: '1.1.0'), address: '10.0.0.2')).json['submission'] as Map)['sid'] as String;
      expect((await decide(asked, {'decision': 'changes', 'note': 'Say what "A bill" means in the description.'})).json['submission']['status'], 'changes_requested');
      now = now.add(const Duration(minutes: 1));
      final next = packOf(version: '1.1.1', changes: {'permissions': ['sort', 'copy', 'markread', 'move']});
      final sid = ((await submit(maya, next, address: '10.0.0.3')).json['submission'] as Map)['sid'] as String;
      final q = (await call('GET', '/market/review', as: matt)).json;
      expect([for (final s in q['open'] as List) s['sid']], [sid]);
      expect([for (final s in q['recent'] as List) (s['sid'], s['status'])], [(asked, 'superseded'), (v1, 'approved')]);
      expect(q['counts'], {'submitted': 1, 'in_review': 0, 'changes_requested': 0, 'reports': 0, 'abuse': 0});
      final row = (q['open'] as List).single as Map;
      expect([row['developerId'], row['verified'], row['blocked'], row['isUpdate'], row['newPermissions'], row['again']], [maya.id, true, false, true, ['move'], true]);
      final first = (q['recent'] as List).last as Map;
      expect([first['isUpdate'], first['again'], first['listing']], [false, false, 'listed']);
      final item = (await call('GET', '/market/review/$sid', as: matt)).json;
      expect(base64Decode(item['package'] as String), next);
      expect(item['submission'], row);
      expect(item['previous'], {'version': '1.0.0', 'sha256': shaOf(packOf()), 'package': base64Encode(packOf())});
      expect(item['asked'], {'sid': asked, 'version': '1.1.0', 'sha256': shaOf(packOf(version: '1.1.0')), 'package': base64Encode(packOf(version: '1.1.0')), 'note': 'Say what "A bill" means in the description.', 'status': 'changes_requested'});
      expect([for (final h in item['history'] as List) h['sid']], [asked, v1]);
      expect(item['developer'], {'id': maya.id, 'username': 'maya', 'blocked': false, 'plugins': 1, 'submissions': 3, 'firstAt': isA<int>()});
    });

    test('decisions: start, approve and what its approval must be, changes and reject with their notes, and nothing out of turn', () async {
      adminAt[matt.id] = now;
      adminAt[ada.id] = now;
      Future<String> sent(Uint8List package, String address) async => ((await submit(maya, package, address: address)).json['submission'] as Map)['sid'] as String;
      Future<(int, String?)> approve(String sid, Map<String, Object?> a, {Sender? by}) => code(decide(sid, {'decision': 'approve', 'approval': a}, by: by));
      final package = packOf();
      final sha = shaOf(package);
      final sid = await sent(package, '10.0.0.1');
      expect((await decide(sid, {'decision': 'start'})).json['submission']['status'], 'in_review');
      expect(await code(decide(sid, {'decision': 'start'})), (409, 'wrong_state'));
      expect(await code(decide(sid, {'decision': 'approve'})), (400, 'bad_request'), reason: 'no approval');
      expect(await code(decide(sid, {'decision': 'start', 'approval': approval(matt, 'mybills', '1.0.0', sha)})), (400, 'bad_request'));
      expect(await approve(sid, approval(sam, 'mybills', '1.0.0', sha)), (400, 'bad_approval'), reason: 'a key that isn\'t the request\'s');
      expect(await approve(sid, approval(matt, 'mybills', '1.0.0', '0' * 64)), (400, 'bad_approval'), reason: 'a wrong sha256');
      expect(await approve(sid, approval(matt, 'mybills', '1.0.1', sha)), (400, 'bad_approval'), reason: 'a wrong version');
      expect(await approve(sid, {...approval(matt, 'mybills', '1.0.0', sha), 'sig': matt.sig(Market.approvalWords('mybills', '1.0.0', '0' * 64))}), (400, 'bad_approval'), reason: 'signed over other words');
      expect(await approve(sid, {...approval(matt, 'mybills', '1.0.0', sha), 'v': 2}), (400, 'bad_approval'));
      final ok = await decide(sid, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.0.0', sha), 'note': 'Thanks: clear and careful.'});
      expect([ok.json['submission']['status'], ok.json['submission']['listing'], (ok.json['submission']['notes'] as List).last['text']], ['approved', 'listed', 'Thanks: clear and careful.']);
      expect(await approve(sid, approval(matt, 'mybills', '1.0.0', sha)), (409, 'wrong_state'));

      final second = await sent(packOf(version: '1.0.1'), '10.0.0.2');
      expect(await code(decide(second, {'decision': 'changes'})), (400, 'bad_request'), reason: 'changes need a note');
      expect(await code(decide(second, {'decision': 'reject'})), (400, 'bad_request'), reason: 'so does a rejection');
      expect((await decide(second, {'decision': 'changes', 'note': 'More words, please.'})).json['submission']['status'], 'changes_requested');
      expect(await code(decide(second, {'decision': 'start'})), (409, 'wrong_state'));
      expect(await code(decide(second, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.0.1', shaOf(packOf(version: '1.0.1')))})), (409, 'wrong_state'), reason: 'changes were asked for');
      expect((await decide(second, {'decision': 'reject', 'note': 'Not this time.'})).json['submission']['status'], 'rejected');
      expect(await code(decide(second, {'decision': 'reject', 'note': 'Again.'})), (409, 'wrong_state'));

      // A retired key's approvals are refused from then on; another review key's are not.
      expect((await call('POST', '/market/retire', json: retirement(matt))).status, 200);
      final third = await sent(packOf(version: '1.0.2'), '10.0.0.3');
      expect(await approve(third, approval(matt, 'mybills', '1.0.2', shaOf(packOf(version: '1.0.2')))), (400, 'bad_approval'));
      expect((await decide(third, {'decision': 'approve', 'approval': approval(ada, 'mybills', '1.0.2', shaOf(packOf(version: '1.0.2')))}, by: ada)).json['submission']['status'], 'approved');
    });

    test('where the store names its review keys, an approval by any other key is refused', () async {
      await relay.stop();
      await boot(config: MarketConfig(reviewKeys: [ada.keyB64]));
      adminAt[matt.id] = now;
      adminAt[ada.id] = now;
      final package = packOf();
      final sid = ((await submit(maya, package)).json['submission'] as Map)['sid'] as String;
      expect(await code(decide(sid, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.0.0', shaOf(package))})), (400, 'bad_approval'));
      expect((await decide(sid, {'decision': 'approve', 'approval': approval(ada, 'mybills', '1.0.0', shaOf(package))}, by: ada)).status, 200);
    });

    test('where the store names its review keys, a withdrawal by any other key is refused; a review key\'s is kept beside another\'s', () async {
      // Every app drops a withdrawal by a key its build doesn't pin: the store took one by another signed-in admin,
      // unlisted the plugin, answered 410 for it, and then kept that one as the withdrawal of the version, so the review
      // key's own was answered 200 and never kept (review, 2026-11-20).
      await relay.stop();
      await boot(config: MarketConfig(reviewKeys: [matt.keyB64]));
      await approved(maya, packOf());
      final sha = shaOf(packOf());
      adminAt[ada.id] = now;
      expect(await code(call('POST', '/market/plugins/mybills/revoke', as: ada, json: revocation(ada, 'mybills', sha, 'Broken'))), (400, 'bad_approval'));
      expect((await call('GET', '/market/catalog')).json['plugins'], hasLength(1), reason: 'still listed');
      expect((await call('GET', '/market/packages/$sha')).status, 200);
      // With no review keys named, any admin's is taken, and a review key's own of the same version is kept beside it.
      await fresh(const MarketConfig());
      await approved(maya, packOf());
      adminAt[ada.id] = now;
      final first = revocation(ada, 'mybills', sha, 'Broken');
      expect((await call('POST', '/market/plugins/mybills/revoke', as: ada, json: first)).json['revoked'], first);
      final review = revocation(matt, 'mybills', sha, 'It marked bank texts read.');
      expect((await call('POST', '/market/plugins/mybills/revoke', as: matt, json: review)).json['revoked'], review);
      expect([for (final r in (await call('GET', '/market/revoked')).json['revoked'] as List) r['key']], [ada.keyB64, matt.keyB64]);
      expect((await call('POST', '/market/plugins/mybills/revoke', as: matt, json: revocation(matt, 'mybills', sha, 'Again.'))).json['revoked'], review, reason: 'kept once a key');
    });

    test('approving an update may withdraw the version before it in the same step', () async {
      final v1 = await approved(maya, packOf());
      final update = packOf(version: '1.1.0');
      final second = ((await submit(maya, update, address: '10.0.0.2')).json['submission'] as Map)['sid'] as String;
      final rv = revocation(matt, 'mybills', shaOf(packOf()), 'Replaced by 1.1.0: update it from its page.');
      expect(await code(decide(second, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.1.0', shaOf(update)), 'revokes': [revocation(matt, 'mybills', '0' * 64, 'No such one.')]})), (404, 'not_found'), reason: 'every withdrawal is checked before anything is done');
      expect((await call('GET', '/market/review/$second', as: matt)).json['submission']['status'], 'submitted');
      final got = await decide(second, {'decision': 'approve', 'approval': approval(matt, 'mybills', '1.1.0', shaOf(update)), 'revokes': [rv]});
      expect(got.json['submission']['listing'], 'listed');
      expect((await call('GET', '/market/revoked')).json['revoked'], [rv]);
      expect(await code(call('GET', '/market/packages/${shaOf(packOf())}')), (410, 'revoked'));
      expect((await call('GET', '/market/packages/${shaOf(update)}')).bytes, update);
      expect([for (final e in (await call('GET', '/market/catalog')).json['plugins'] as List) (e['id'], e['version'])], [('mybills', '1.1.0')]);
      expect((await call('GET', '/market/submissions/$v1', as: maya)).json['submission']['revoked'], {'at': rv['at'], 'why': 'Replaced by 1.1.0: update it from its page.'});
    });

    test('sent to be listed later: approved, it waits for its developer to list it', () async {
      await approved(maya, packOf(), list: 'later');
      expect((await call('GET', '/market/catalog')).json['plugins'], isEmpty);
      final mine = (await call('GET', '/market/mine', as: maya)).json;
      expect(mine['plugins'], [{'id': 'mybills', 'listing': 'unlisted', 'current': '1.0.0', 'by': 'owner', 'note': null, 'noteAt': null}]);
      expect((mine['submissions'] as List).single['listing'], 'unlisted');
      expect((await call('POST', '/market/plugins/mybills/listing', as: maya, json: {'listed': true})).json['plugin']['listing'], 'listed');
      expect([for (final e in (await call('GET', '/market/catalog')).json['plugins'] as List) e['id']], ['mybills']);
    });

    test('its owner takes it off and lists it again, and can\'t list what review took off', () async {
      await approved(maya, packOf());
      Future<Answer> listing(Sender who, bool listed, {String? note}) => call('POST', '/market/plugins/mybills/listing', as: who, json: {'listed': listed, 'note': ?note});
      expect((await listing(maya, false)).json['plugin'], {'id': 'mybills', 'listing': 'unlisted', 'current': '1.0.0', 'by': 'owner', 'note': null, 'noteAt': null});
      expect((await call('GET', '/market/catalog')).json['plugins'], isEmpty);
      expect((await listing(maya, true)).json['plugin']['listing'], 'listed');
      expect(await code(listing(sam, false)), (403, 'not_admin'), reason: 'not his');
      now = now.add(const Duration(minutes: 31));
      expect(await code(listing(matt, false)), (403, 'not_admin'), reason: 'review signed in over 30 minutes ago');
      adminAt[matt.id] = now;
      final off = (await listing(matt, false, note: 'Taken off while a report is looked into.')).json['plugin'];
      expect([off['listing'], off['by'], off['note'], off['noteAt']], ['unlisted', 'admin', 'Taken off while a report is looked into.', now.millisecondsSinceEpoch]);
      expect(await code(listing(maya, true)), (409, 'admin_unlisted'));
      expect((await listing(maya, false)).json['plugin']['by'], 'admin', reason: 'taking it off again doesn\'t make it hers to list');
      expect(await code(listing(maya, true)), (409, 'admin_unlisted'));
      expect((await listing(matt, true)).json['plugin']['listing'], 'listed');
      expect(await code(call('POST', '/market/plugins/nosuchone/listing', as: maya, json: {'listed': false})), (404, 'not_found'));
    });
  });

  group('serving', () {
    test('the catalog: only what an approval covers, an ETag and 304, and made once a change, not once an asking', () async {
      expect((await call('GET', '/market/catalog')).json, {'ok': true, 'v': 1, 'at': 0, 'plugins': []});
      await approved(maya, packOf());
      final got = await call('GET', '/market/catalog');
      final c = got.json;
      expect(c.keys.toSet(), {'ok', 'v', 'at', 'plugins'});
      expect(c['at'], now.millisecondsSinceEpoch);
      final entry = (c['plugins'] as List).single as Map;
      expect(entry.keys.toSet(), {'id', 'version', 'sha256', 'size', 'approval', 'listedAt', 'updatedAt'});
      expect((entry['approval'] as Map).keys.toSet(), {'v', 'plugin', 'version', 'sha256', 'key', 'sig', 'at'});
      expect([entry['id'], entry['version'], entry['sha256'], entry['size'], (entry['approval'] as Map)['key']], ['mybills', '1.0.0', shaOf(packOf()), packOf().length, matt.keyB64]);
      final tag = got.headers.value('etag')!;
      expect(tag, '"${shaOf(got.bytes).substring(0, 16)}"');
      expect(got.headers.value('cache-control'), 'no-cache');
      final again = await call('GET', '/market/catalog', headers: {'if-none-match': tag});
      expect(again.status, 304);
      expect(again.bytes, isEmpty);
      now = now.add(const Duration(minutes: 5));
      expect((await call('GET', '/market/catalog')).bytes, got.bytes, reason: 'the same bytes, at and all: nothing listed changed');
      final rev = await call('GET', '/market/revoked');
      expect(rev.json, {'ok': true, 'v': 1, 'at': 0, 'revoked': [], 'retired': []});
      expect((await call('GET', '/market/revoked', headers: {'if-none-match': rev.headers.value('etag')!})).status, 304);
    });

    test('the catalog and the withdrawals: ten a minute from one address, 304s too', () async {
      for (var i = 0; i < 10; i++) {
        expect((await call('GET', i.isEven ? '/market/catalog' : '/market/revoked', address: '10.5.0.1')).status, 200);
      }
      expect(await code(call('GET', '/market/catalog', address: '10.5.0.1')), (429, 'rate_limited'));
      expect((await call('GET', '/market/catalog', address: '10.5.0.2')).status, 200);
      now = now.add(const Duration(minutes: 1));
      expect((await call('GET', '/market/catalog', address: '10.5.0.1')).status, 200);
    });

    test('packages and screenshots, served as files a browser never runs; there is no icon route', () async {
      final a = shotPng(1);
      final package = packOf(shots: [shaOf(a)]);
      final sid = await approved(maya, package, shots: [shotOf(a)]);
      final got = await call('GET', '/market/packages/${shaOf(package)}');
      expect(got.bytes, package);
      expect(got.headers.contentType?.mimeType, 'application/octet-stream');
      expect(got.headers.value('content-disposition'), 'attachment; filename="mybills-1.0.0.ghostplugin"');
      expect(got.headers.value('x-content-type-options'), 'nosniff');
      expect(got.headers.value('content-security-policy'), "default-src 'none'; sandbox");
      expect(got.headers.value('cache-control'), 'public, max-age=31536000, immutable');
      final shot = await call('GET', '/market/shots/${shaOf(a)}');
      expect(shot.bytes, a);
      expect(shot.headers.contentType?.mimeType, 'image/png');
      expect(shot.headers.value('content-disposition'), 'inline');
      expect(shot.headers.value('x-content-type-options'), 'nosniff');
      expect(shot.headers.value('content-security-policy'), "default-src 'none'; sandbox");
      expect(shot.headers.value('cache-control'), 'public, max-age=31536000, immutable');
      final own = await call('GET', '/market/submissions/$sid/package', as: maya);
      expect([own.headers.value('cache-control'), own.headers.value('content-disposition')], ['no-store', 'attachment; filename="mybills-1.0.0.ghostplugin"']);
      final ownShot = await call('GET', '/market/submissions/$sid/shots/0', as: maya);
      expect([ownShot.headers.contentType?.mimeType, ownShot.headers.value('cache-control')], ['image/png', 'no-store']);
      expect(await code(call('GET', '/market/packages/${shaOf(package)}/icon')), (404, 'not_found'));
      expect(await code(call('GET', '/market/packages/${'0' * 64}')), (404, 'not_found'));
      // A screenshot of something not listed is nobody's to read but its developer's and review's.
      final b = shotPng(2);
      final theirs = ((await submit(sam, packOf(id: 'samsbills', developer: 'sam', shots: [shaOf(b)]), shots: [shotOf(b)], address: '10.0.0.2')).json['submission'] as Map)['sid'];
      expect(await code(call('GET', '/market/shots/${shaOf(b)}')), (404, 'not_found'));
      expect(await code(call('GET', '/market/packages/${shaOf(packOf(id: 'samsbills', developer: 'sam', shots: [shaOf(b)]))}')), (404, 'not_found'), reason: 'not approved');
      adminAt[matt.id] = now;
      expect((await call('GET', '/market/submissions/$theirs/shots/0', as: matt)).bytes, b, reason: 'review sees it');
    });

    test('withdrawing a version: its five lines signed, in the withdrawals, out of the catalog, its package gone (410)', () async {
      expect(Market.revocationWords('mybills', 'a' * 64, 5, 'Broken').split('\n'), ['ghost-market revoke v1', 'mybills', 'a' * 64, '5', 'Broken']);
      final sid = await approved(maya, packOf());
      final sha = shaOf(packOf());
      Future<Answer> revoke(Map<String, Object?> r) => call('POST', '/market/plugins/mybills/revoke', as: matt, json: r);
      expect(await code(revoke(revocation(matt, 'mybills', sha, 'Bad\nwords'))), (400, 'bad_approval'));
      expect(await code(revoke(revocation(matt, 'mybills', sha, ''))), (400, 'bad_approval'));
      expect(await code(revoke(revocation(matt, 'mybills', sha, 'a' * 201))), (400, 'bad_approval'));
      expect(await code(revoke(revocation(matt, 'mybills', '0' * 64, 'Broken'))), (404, 'not_found'));
      expect(await code(revoke(revocation(sam, 'mybills', sha, 'Broken'))), (400, 'bad_approval'), reason: 'not the asker\'s key');
      expect(await code(revoke({...revocation(matt, 'mybills', sha, 'Broken'), 'why': 'Something else'})), (400, 'bad_approval'), reason: 'the reason is signed');
      now = now.add(const Duration(minutes: 31));
      expect(await code(revoke(revocation(matt, 'mybills', sha, 'Broken'))), (403, 'not_admin'));
      adminAt[matt.id] = now;
      final rv = revocation(matt, 'mybills', sha, 'It marked bank texts read.');
      final got = (await revoke(rv)).json;
      expect(got['revoked'], rv);
      expect(got['plugin'], {'id': 'mybills', 'listing': 'unlisted', 'current': '1.0.0', 'by': 'admin', 'note': null, 'noteAt': null});
      expect((await call('GET', '/market/revoked')).json['revoked'], [rv]);
      expect((await call('GET', '/market/catalog')).json['plugins'], isEmpty);
      expect(await code(call('GET', '/market/packages/$sha')), (410, 'revoked'));
      expect((await call('GET', '/market/submissions/$sid', as: maya)).json['submission']['revoked'], {'at': rv['at'], 'why': 'It marked bank texts read.'});
      expect((await revoke(revocation(matt, 'mybills', sha, 'Again.'))).json['revoked'], rv, reason: 'kept once');
      expect(await code(call('POST', '/market/plugins/mybills/listing', as: matt, json: {'listed': true})), (409, 'wrong_state'), reason: 'its current version is withdrawn');
    });

    test('retiring a key: only one the market has heard from, its signature checked, then in the withdrawals', () async {
      expect(await code(call('POST', '/market/retire', json: retirement(sam))), (404, 'not_found'), reason: 'a key that has signed nothing here');
      await approved(maya, packOf());
      final forged = {...retirement(matt), 'sig': sam.sig(Market.retirementWords(matt.keyB64))};
      expect(await code(call('POST', '/market/retire', json: forged)), (401, 'bad_signature'));
      final r = retirement(matt);
      expect((await call('POST', '/market/retire', json: r)).json, {'ok': true, 'retired': r});
      expect((await call('GET', '/market/revoked')).json['retired'], [r]);
      expect((await call('POST', '/market/retire', json: retirement(matt))).json['retired'], r, reason: 'kept once');
      expect(await code(call('POST', '/market/retire', json: {...r, 'extra': 1})), (400, 'bad_request'));
      for (var i = 0; i < 5; i++) {
        await call('POST', '/market/retire', json: r);
      }
      expect(await code(call('POST', '/market/retire', json: r)), (429, 'rate_limited'), reason: 'ten an hour from one address');
      expect((await call('POST', '/market/retire', json: r, address: '10.0.0.9')).status, 200);
    });

    test('the withdrawals list is never longer than an app reads: past its bytes or its count, one more is refused', () async {
      // An app reads 1 MiB and refused a longer list all at once, taking nothing from it, while the relay kept adding
      // to it: past some 3,200 withdrawals none reached a device but by a release (review, 2026-11-20). The app's
      // limits now, and the relay's, are the same numbers.
      final api = File('../lib/market/market_api.dart'), installer = File('../lib/plugins/pack/installed.dart');
      if (api.existsSync() && installer.existsSync()) {
        expect(api.readAsStringSync(), contains('static const int revoked = ${Market.withdrawalsMost ~/ (1024 * 1024)} * 1024 * 1024, revocations = InstalledPlugins.revocationsTaken, retirements = InstalledPlugins.retirementsTaken;'));
        expect(installer.readAsStringSync(), contains('static const int revocationsTaken = ${Market.revocationsMost}, retirementsTaken = ${Market.retirementsMost};'));
      }
      await approved(maya, packOf());
      final sha = shaOf(packOf());
      await relay.stop();
      // Kept from before: as many old withdrawals as leave less room than one more.
      final state = jsonDecode(File('${dir.path}/market/state.json').readAsStringSync()) as Map<String, dynamic>;
      Map<String, Object?> old(int i) => {'v': 1, 'plugin': 'old${i.toString().padLeft(6, '0')}', 'sha256': shaOf(utf8.encode('$i')), 'at': 1763000000000 + i, 'why': 'Withdrawn long ago, for a reason that took most of the words a withdrawal may have to say: $i.'.padRight(190, '.'), 'key': matt.keyB64, 'sig': base64Encode(List.filled(64, 1))};
      final one = utf8.encode(jsonEncode(old(0))).length + 1;
      final fill = <Map<String, Object?>>[];
      var size = utf8.encode(jsonEncode({'ok': true, 'v': 1, 'at': 1763000000000, 'revoked': [], 'retired': []})).length;
      while (size + one <= Market.withdrawalsMost - 150) {
        fill.add(old(fill.length));
        size += one;
      }
      state['revoked'] = fill;
      File('${dir.path}/market/state.json').writeAsStringSync(jsonEncode(state));
      await boot();
      final served = (await call('GET', '/market/revoked', address: '10.8.0.2')).bytes.length;
      expect(served, lessThanOrEqualTo(Market.withdrawalsMost));
      adminAt[matt.id] = now;
      final rv = revocation(matt, 'mybills', sha, 'It marked bank texts read, and a fraud alert with them, for weeks before anyone said.'.padRight(190, '.'));
      final refused = await call('POST', '/market/plugins/mybills/revoke', as: matt, json: rv);
      expect((refused.status, refused.error), (507, 'withdrawals_full'));
      expect(refused.json['message'], 'The list of withdrawals is as long as the app reads: no more can be added until it is made shorter.');
      expect((await call('GET', '/market/revoked', address: '10.8.0.3')).bytes.length, served, reason: 'nothing was added');
      expect((await call('GET', '/market/catalog', address: '10.8.0.3')).json['plugins'], hasLength(1), reason: 'and nothing was withdrawn');
      // A hundred retirements are as many as an app reads.
      await relay.stop();
      state['revoked'] = [];
      state['retired'] = [for (var i = 0; i < Market.retirementsMost; i++) {'v': 1, 'key': base64Encode(fakeKey('retired $i')), 'at': 1763000000000, 'sig': base64Encode(List.filled(64, 1))}];
      File('${dir.path}/market/state.json').writeAsStringSync(jsonEncode(state));
      await boot();
      expect(await code(call('POST', '/market/retire', json: retirement(matt))), (507, 'withdrawals_full'));
    });

    test('a report keeps nothing of who sent it but the username they chose to send', () async {
      // The report kept the hub id of whoever sent it, in state.json and for good in audit.jsonl, which the relay maps to
      // their username and number: Send my username with it off, it was theirs all the same (review, 2026-11-20).
      await approved(maya, packOf());
      expect((await call('POST', '/market/report', as: theo, json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'harmful', 'text': 'It took my bank\'s texts.'})).status, 201);
      expect((await call('POST', '/market/report', as: ada, address: '10.0.0.9', json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': '', 'username': 'ada'})).status, 201);
      await market.flush();
      final state = File('${dir.path}/market/state.json').readAsStringSync();
      final audit = File('${dir.path}/market/audit.jsonl').readAsStringSync();
      for (final who in [theo, ada]) {
        expect(state, isNot(contains(who.id)));
        expect(audit, isNot(contains(who.id)));
      }
      final reports = ((jsonDecode(state) as Map)['reports'] as Map).values.cast<Map>().toList();
      expect([for (final r in reports) r['username']], [null, 'ada']);
      expect(reports.any((r) => r.containsKey('by')), isFalse);
      expect([for (final l in const LineSplitter().convert(audit)) if ((jsonDecode(l) as Map)['what'] == 'report') (jsonDecode(l) as Map)['by']], ['reporter', 'reporter']);
      adminAt[matt.id] = now;
      expect([for (final r in (await call('GET', '/market/reports', as: matt)).json['reports'] as List) r['username']], ['ada', null], reason: 'what the reviewer reads is as it was');
    });

    test('reports: made, so many from one address and one someone, the newest 200 of a plugin kept, listed newest first, and marked done', () async {
      await approved(maya, packOf());
      Future<Answer> report(Sender by, {String plugin = 'mybills', String address = '10.1.0.1', String? username}) => call('POST', '/market/report', as: by, address: address, json: {'plugin': plugin, 'version': '1.0.0', 'reason': 'harmful', 'text': 'It took my bank\'s texts.', 'username': ?username});
      expect(await code(call('POST', '/market/report', as: sam, json: {'plugin': 'nothing', 'version': '1.0.0', 'reason': 'spam', 'text': ''})), (404, 'not_found'));
      expect(await code(call('POST', '/market/report', as: sam, json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'boring', 'text': ''})), (400, 'bad_request'));
      expect(await code(call('POST', '/market/report', as: sam, json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': 'a' * 1001})), (400, 'bad_request'));
      final made = await report(sam, username: 'sam');
      expect(made.status, 201);
      final rid = made.json['id'] as String;
      expect(rid, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect((await report(theo, username: 'maya', address: '10.1.0.2')).status, 201);
      adminAt[matt.id] = now;
      final listed = (await call('GET', '/market/reports', as: matt)).json['reports'] as List;
      expect([for (final x in listed) (x['username'], x['verified'])], [('maya', false), ('sam', true)]);
      expect((listed.last as Map).keys.toSet(), {'rid', 'plugin', 'version', 'reason', 'text', 'username', 'verified', 'at', 'done', 'doneAt'});

      // Five a day from one address, and five by one someone (two keys proving one number are one someone).
      for (var i = 0; i < 5; i++) {
        expect((await report(Sender(100 + i), address: '10.1.0.9')).status, 201);
      }
      expect(await code(report(Sender(105), address: '10.1.0.9')), (429, 'rate_limited'));
      for (var i = 0; i < 6; i++) {
        final s = Sender(200 + i);
        someone[s.id] = 'phone|one-number';
        expect((await report(s, address: '10.2.0.$i')).status, i < 5 ? 201 : 429);
      }

      // The newest 200 of one plugin.
      fake = (key, message, sig) => true;
      await approved(sam, packOf(id: 'samsbills', developer: 'sam'), by: ada);
      final rids = <String>[];
      final body = utf8.encode(jsonEncode({'plugin': 'samsbills', 'version': '1.0.0', 'reason': 'spam', 'text': ''}));
      for (var i = 0; i < 201; i++) {
        // Three keys' reports of one plugin a day each, five an address, within the clock's twenty checks a second.
        now = now.add(const Duration(milliseconds: 60));
        final key = fakeKey('reporter ${i ~/ 3}');
        final res = await call('POST', '/market/report', body: body, address: '10.4.${i ~/ 5}.2', headers: {...fakeSigned(key, now.millisecondsSinceEpoch), Files.bodyShaHeader: shaOf(body), Files.bodyLengthHeader: '${body.length}'});
        expect(res.status, 201, reason: '$i: $res');
        rids.add(res.json['id'] as String);
      }
      fake = null;
      final all = (await call('GET', '/market/reports', as: matt)).json['reports'] as List;
      final theirs = [for (final x in all) if (x['plugin'] == 'samsbills') x['rid']];
      expect(theirs, hasLength(200));
      expect(theirs, isNot(contains(rids.first)));
      expect(theirs.first, rids.last, reason: 'newest first');

      final q = (await call('GET', '/market/review', as: matt)).json['counts'] as Map;
      expect((await call('POST', '/market/reports/$rid', as: matt, json: {'done': true})).json, {'ok': true});
      final at = now.millisecondsSinceEpoch;
      final done = ((await call('GET', '/market/reports', as: matt)).json['reports'] as List).firstWhere((x) => x['rid'] == rid) as Map;
      expect([done['done'], done['doneAt']], [true, at]);
      expect(((await call('GET', '/market/review', as: matt)).json['counts'] as Map)['reports'], (q['reports'] as int) - 1);
      expect(await code(call('POST', '/market/reports/${'0' * 16}', as: matt, json: {'done': true})), (404, 'not_found'));
      expect(await code(call('POST', '/market/reports/$rid', as: matt, json: {'done': false})), (400, 'bad_request'));
      expect(await code(call('GET', '/market/reports', as: maya)), (403, 'not_admin'));
    });

    test('blocking a developer, and taking their plugins off with it', () async {
      await approved(maya, packOf());
      final got = await call('POST', '/market/developers/${maya.id}/block', as: matt, json: {'blocked': true, 'note': 'Spam in descriptions.', 'unlist': true});
      final at = now.millisecondsSinceEpoch;
      expect(got.json['developer'], {'id': maya.id, 'username': 'maya', 'blocked': true, 'plugins': 1, 'submissions': 1, 'firstAt': isA<int>()});
      expect((await call('GET', '/market/catalog')).json['plugins'], isEmpty);
      final mine = (await call('GET', '/market/mine', as: maya)).json;
      expect(mine['blocked'], true);
      expect(mine['plugins'], [{'id': 'mybills', 'listing': 'unlisted', 'current': '1.0.0', 'by': 'admin', 'note': 'Spam in descriptions.', 'noteAt': at}]);
      expect(await code(submit(maya, packOf(version: '1.0.1'), address: '10.0.0.2')), (403, 'blocked'));
      expect(await code(call('POST', '/market/plugins/mybills/listing', as: maya, json: {'listed': true})), (409, 'admin_unlisted'));
      final row = ((await call('GET', '/market/review', as: matt)).json['recent'] as List).single as Map;
      expect(row['blocked'], true);
      now = now.add(const Duration(minutes: 31));
      expect(await code(call('POST', '/market/developers/${maya.id}/block', as: matt, json: {'blocked': false})), (403, 'not_admin'));
      adminAt[matt.id] = now;
      expect((await call('POST', '/market/developers/${maya.id}/block', as: matt, json: {'blocked': false})).json['developer']['blocked'], false);
      expect((await submit(maya, packOf(version: '1.0.1'), address: '10.0.0.3')).status, 201);
    });
  });

  group('storage', () {
    Future<List<Object?>> everything() async {
      adminAt[matt.id] = now;
      return [
        utf8.decode((await call('GET', '/market/catalog', address: '10.8.0.1')).bytes),
        utf8.decode((await call('GET', '/market/revoked', address: '10.8.0.1')).bytes),
        (await call('GET', '/market/mine', as: maya)).json,
        (await call('GET', '/market/mine', as: sam)).json,
        (await call('GET', '/market/review', as: matt)).json,
        (await call('GET', '/market/reports', as: matt)).json,
      ];
    }

    test('a restart keeps everything', () async {
      final a = shotPng(1);
      final sid = await approved(maya, packOf(shots: [shaOf(a)]), shots: [shotOf(a)]);
      await submit(maya, packOf(version: '1.1.0'), notes: 'Now with receipts.', address: '10.0.0.2');
      await submit(sam, packOf(id: 'samsbills', developer: 'sam'), address: '10.0.0.3');
      await call('POST', '/market/report', as: theo, json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'broken', 'text': 'Nothing sorts.'});
      final before = await everything();
      await relay.stop();
      await boot();
      expect(await everything(), before);
      expect((await call('GET', '/market/shots/${shaOf(a)}')).bytes, a);
      expect((await call('GET', '/market/submissions/$sid/package', as: maya)).bytes, packOf(shots: [shaOf(a)]));
      expect(market.listed, 1);
    });

    test('a state.json that can\'t be read is put aside, and the copy before it read', () async {
      await approved(maya, packOf());
      // Saved once, then again as it stops: state.json.bak is the copy before the last save.
      await market.flush();
      await relay.stop();
      expect(File('${dir.path}/market/state.json.bak').existsSync(), isTrue);
      File('${dir.path}/market/state.json').writeAsStringSync('{"v":1,"plugins":');
      await boot();
      expect([for (final e in (await call('GET', '/market/catalog')).json['plugins'] as List) e['id']], ['mybills']);
      final names = [for (final e in Directory('${dir.path}/market').listSync()) e.uri.pathSegments.last];
      expect(names.where((n) => n.startsWith('state.json.broken-')), hasLength(1));
    });

    test('with neither readable it starts empty, keeps both aside, and still knows from audit.jsonl who sent which id', () async {
      await approved(maya, packOf());
      await relay.stop();
      File('${dir.path}/market/state.json').writeAsStringSync('nonsense');
      File('${dir.path}/market/state.json.bak').writeAsStringSync('{"v":2}');
      await boot();
      expect((await call('GET', '/market/catalog')).json['plugins'], isEmpty);
      final files = {for (final e in Directory('${dir.path}/market').listSync()) e.uri.pathSegments.last: e};
      final broken = files.keys.where((n) => n.startsWith('state.json.broken-')).single;
      expect(files.keys.where((n) => n.startsWith('state.json.bak.broken-')), hasLength(1));
      expect(File('${dir.path}/market/$broken').readAsStringSync(), 'nonsense', reason: 'never written over');
      expect(await code(submit(sam, packOf(developer: 'sam'), address: '10.0.0.2')), (409, 'id_taken'), reason: 'an empty start doesn\'t hand the id to whoever asks first');
      expect((await submit(maya, packOf(version: '1.0.1'), address: '10.0.0.3')).status, 201);
    });

    test('the sweep: an old closed submission\'s files go unless an approved version or a kept screenshot uses them, and an id with nothing approved is let go after 30 days', () async {
      final s1 = shotPng(1), s2 = shotPng(2), s3 = shotPng(3);
      final v1 = packOf(shots: [shaOf(s1)]);
      await approved(maya, v1, shots: [shotOf(s1)]);
      final v2 = packOf(version: '1.1.0', shots: [shaOf(s1), shaOf(s2)]);
      final second = ((await submit(maya, v2, shots: [{'keep': shaOf(s1)}, shotOf(s2)], address: '10.0.0.2')).json['submission'] as Map)['sid'] as String;
      expect((await decide(second, {'decision': 'reject', 'note': 'Not this one.'})).status, 200);
      final theirs = packOf(id: 'parcelsplus', developer: 'sam', shots: [shaOf(s3)]);
      final withdrawn = ((await submit(sam, theirs, shots: [shotOf(s3)], address: '10.0.0.3')).json['submission'] as Map)['sid'] as String;
      expect((await call('DELETE', '/market/submissions/$withdrawn', as: sam)).status, 200);
      bool there(String kind, List<int> bytes) => File('${dir.path}/market/$kind/${shaOf(bytes)}').existsSync();

      now = now.add(const Duration(days: 29));
      await market.sweep();
      expect([there('packages', v2), there('shots', s2), there('packages', theirs), there('shots', s3)], [true, true, true, true], reason: 'not 30 days yet');
      expect(await code(submit(ada, packOf(id: 'parcelsplus', developer: 'ada'), address: '10.0.0.4')), (409, 'id_taken'), reason: 'still held');

      now = now.add(const Duration(days: 2));
      await market.sweep();
      expect(there('packages', v1), isTrue, reason: 'an approved version');
      expect(there('shots', s1), isTrue, reason: 'the approved version\'s screenshot, which the rejected one kept');
      expect([there('packages', v2), there('shots', s2), there('packages', theirs), there('shots', s3)], [false, false, false, false]);
      final mine = (await call('GET', '/market/mine', as: maya)).json['submissions'] as List;
      expect([mine.first['status'], (mine.first['notes'] as List).last['text']], ['rejected', 'Not this one.'], reason: 'its record and notes are kept');
      expect(await code(call('GET', '/market/submissions/$second/package', as: maya)), (404, 'not_found'));
      expect((await submit(ada, packOf(id: 'parcelsplus', developer: 'ada'), address: '10.0.0.4')).status, 201, reason: 'the id let go');
      await market.flush();
      final audit = [for (final l in File('${dir.path}/market/audit.jsonl').readAsLinesSync()) jsonDecode(l) as Map];
      expect({for (final l in audit) if (l['what'] == 'sweep') l['sid']}, {second, withdrawn});
      expect([for (final l in audit) if (l['what'] == 'release') l['plugin']], ['parcelsplus']);
      expect(audit.first.keys.toSet(), containsAll(['at', 'by', 'what']));
    });

    test('stopped during a submission\'s writes: it is in the last save, never answered 201 and lost', () async {
      // stop() closed the store without waiting for route 8, and what finished after was answered and never saved; a new
      // id's record held it for good (review, 2026-11-20).
      Future<void>? stopped;
      market.debugAfterWrites = () async {
        stopped = market.stop();
      };
      final sent = await submit(maya, packOf());
      expect(sent.status, 201);
      await stopped;
      market.debugAfterWrites = null;
      expect(await code(call('GET', '/market')), (503, 'busy'), reason: 'nothing more is taken once it is stopping');
      final sid = (sent.json['submission'] as Map)['sid'];
      final kept = jsonDecode(File('${dir.path}/market/state.json').readAsStringSync()) as Map;
      expect((kept['submissions'] as Map).keys, [sid]);
      expect((kept['plugins'] as Map)['mybills']['openUntil'], isNull, reason: 'held while its submission is open');
      await relay.stop();
      await boot();
      expect([for (final s in (await call('GET', '/market/mine', as: maya)).json['submissions'] as List) s['sid']], [sid]);
    });

    test('a change or an audit line after the store\'s last save is written at once', () async {
      // A decision or a submission that finished while stop() waited for the audit's lines was answered and never saved
      // (review, 2026-11-20).
      final store = MarketStore(Directory('${dir.path}/alone'), now: () => now);
      await store.load();
      await store.close();
      store.plugins['latebills'] = MarketPlugin(id: 'latebills', owner: maya.id, developer: 'maya', createdAt: 1, updatedAt: 1);
      store.changed();
      store.audit(maya.id, 'submit', plugin: 'latebills');
      expect(((jsonDecode(File('${dir.path}/alone/state.json').readAsStringSync()) as Map)['plugins'] as Map).keys, ['latebills']);
      expect(File('${dir.path}/alone/audit.jsonl').readAsStringSync(), contains('"plugin":"latebills"'));
    });

    test('a new id\'s record left with no submission, as a crash between its writes and its record leaves it, is let go after 30 days, its files with it', () async {
      // Made with no openUntil and given one only by a submission it never got, it was held for good, its files named by
      // nothing and counted against the room for good (review, 2026-11-20).
      String? stateAtCrash, auditAtCrash;
      market.debugAfterWrites = () async {
        await market.flush();
        stateAtCrash = File('${dir.path}/market/state.json').readAsStringSync();
        final audit = File('${dir.path}/market/audit.jsonl');
        auditAtCrash = audit.existsSync() ? audit.readAsStringSync() : '';
      };
      final picture = shotPng(7);
      final package = packOf(id: 'coolbills', shots: [shaOf(picture)]);
      expect((await submit(maya, package, shots: [shotOf(picture)])).status, 201);
      market.debugAfterWrites = null;
      await relay.stop();
      // As the relay finds it after the crash: the record and the files, nothing of the submission.
      File('${dir.path}/market/state.json').writeAsStringSync(stateAtCrash!);
      File('${dir.path}/market/audit.jsonl').writeAsStringSync(auditAtCrash!);
      await boot();
      expect(((jsonDecode(stateAtCrash!) as Map)['plugins'] as Map)['coolbills']['openUntil'], now.millisecondsSinceEpoch + Market.idHeld.inMilliseconds);
      expect(await code(submit(sam, packOf(id: 'coolbills', developer: 'sam'), address: '10.0.0.2')), (409, 'id_taken'), reason: 'held while it may still come');
      bool there(String kind, List<int> bytes) => File('${dir.path}/market/$kind/${shaOf(bytes)}').existsSync();
      expect([there('packages', package), there('shots', picture)], [true, true]);
      now = now.add(const Duration(days: 31));
      await market.sweep();
      expect([there('packages', package), there('shots', picture)], [false, false], reason: 'named by nothing');
      expect((await submit(sam, packOf(id: 'coolbills', developer: 'sam'), address: '10.0.0.3')).status, 201, reason: 'the id let go');
    });

    test('saves that overlap are each written whole, in turn, and the one at stop() is last', () async {
      await approved(maya, packOf());
      final sends = <Future<void>>[];
      for (var i = 0; i < 12; i++) {
        sends.add(call('POST', '/market/report', as: Sender(300 + i), address: '10.3.0.$i', json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'other', 'text': 'Report $i'}).then((a) => expect(a.status, 201)));
        sends.add(market.flush());
      }
      await Future.wait(sends);
      await market.flush();
      final kept = jsonDecode(File('${dir.path}/market/state.json').readAsStringSync()) as Map;
      expect((kept['reports'] as Map).length, 12);
      expect(File('${dir.path}/market/state.json.tmp').existsSync(), isFalse);
      expect(jsonDecode(File('${dir.path}/market/state.json.bak').readAsStringSync()), isA<Map>());
      final under = market.flush();
      await call('POST', '/market/report', as: Sender(400), address: '10.3.1.1', json: {'plugin': 'mybills', 'version': '1.0.0', 'reason': 'other', 'text': 'The last one'});
      await relay.stop();
      await under;
      final last = jsonDecode(File('${dir.path}/market/state.json').readAsStringSync()) as Map;
      expect([for (final r in (last['reports'] as Map).values) r['text']], contains('The last one'));
      await boot();
      adminAt[matt.id] = now;
      expect((await call('GET', '/market/reports', as: matt)).json['reports'], hasLength(13));
    });

    test('GHOST_MARKET_ON=0: closed, and saying so', () async {
      await relay.stop();
      await boot(config: MarketConfig.fromEnvironment({'GHOST_MARKET_ON': '0'}));
      expect((await call('GET', '/market')).json['open'], false);
      for (final (method, path) in [('GET', '/market/catalog'), ('GET', '/market/revoked'), ('GET', '/market/mine'), ('POST', '/market/submissions'), ('POST', '/market/retire')]) {
        expect(await code(call(method, path, as: maya, json: method == 'POST' ? {} : null)), (503, 'off'), reason: '$method $path');
      }
    });

    test('an unknown /market path is a JSON 404, another way of asking a 405, and the relay\'s other routes are as they were', () async {
      final none = await call('GET', '/market/nothing');
      expect((none.status, none.error), (404, 'not_found'));
      expect(none.json['message'], 'There\'s nothing here by that name.');
      expect(none.headers.contentType?.mimeType, 'application/json');
      expect(none.headers.value('x-content-type-options'), 'nosniff');
      expect(await code(call('GET', '/market/catalog/more')), (404, 'not_found'));
      expect(await code(call('GET', '/market/Catalog')), (404, 'not_found'));
      expect(await code(call('PUT', '/market/catalog')), (405, 'method'));
      expect(await code(call('GET', '/market/submissions')), (405, 'method'));
      expect((await call('HEAD', '/market/catalog')).status, 405);
      await relay.stop();
      final filed = <Uri>[];
      await boot(
        files: Files(dir: Directory('${dir.path}/files')),
        feedback: Feedback(config: const FeedbackConfig(notionToken: 'ntn_test', dataSource: '41e2ecf7-f3ac-81dd-9d59-000b22859842'), ownsName: (id, name) => false, notion: (method, url, headers, body) async {
          filed.add(url);
          return (404, '{}');
        }),
      );
      final files = await call('GET', '/files');
      expect([files.status, files.json['files']], [200, 1]);
      final feedback = await call('POST', '/feedback', json: {'type': 'bug', 'text': 'Crash'});
      expect(feedback.status, 401);
      expect(feedback.json['error'], contains('signature'));
      expect(filed, isEmpty);
      final home = await call('GET', '/');
      expect([home.status, utf8.decode(home.bytes)], [200, 'Ghost Messaging relay\n']);
      expect((await call('GET', '/market')).json['ok'], true);
    });
  });
}
