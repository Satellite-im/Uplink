import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/files_roster.dart';
import 'package:ghost_relay/market.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// Reports of people and messages (GMFB-40): routes 23 to 25 under /market. The relay keeps an envelope sealed in the
/// app to the review keys, holds the sender to its limits, and hands the envelopes to review alone.
class _Sender {
  _Sender(int n) : scalar = List.generate(32, (i) => (n * 37 + i * 13 + 5) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get id => FilesRoster.idOf(key);

  Map<String, String> headers(String method, String path, List<int> body, {required int time}) {
    final sha = hexOf(sha256(body));
    final words = utf8.encode(Market.signedWords(method, path, time, sha));
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...words]);
    _nonce++;
    final withBody = method != 'GET' && method != 'DELETE';
    return {
      'x-ghost-key': base64Encode(key),
      'x-ghost-time': '$time',
      'x-ghost-sig': base64Encode(P256.sign(scalar, words, nonce)),
      if (withBody) Files.bodyShaHeader: sha,
      if (withBody) Files.bodyLengthHeader: '${body.length}',
    };
  }
}

void main() {
  late Directory dir;
  late Relay relay;
  late Market market;
  late int port;
  late HttpClient http;
  late DateTime now;
  late Map<String, String> someone;
  late Map<String, DateTime> adminAt;
  final maya = _Sender(1), sam = _Sender(2), matt = _Sender(3), stranger = _Sender(4);

  Future<void> boot({MarketConfig config = const MarketConfig()}) async {
    market = Market(
      dir: Directory('${dir.path}/market'),
      config: config,
      ownsName: (_, _) => false,
      whoOf: (id) => someone[id],
      adminSignedIn: (id, {Duration within = const Duration(hours: 8)}) => adminAt[id] != null && now.difference(adminAt[id]!) < within,
      claimedOn: (_) => null,
      now: () => now,
    );
    relay = Relay(market: market);
    port = await relay.start(port: 0);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ghost-market-abuse-test');
    http = HttpClient();
    now = DateTime.utc(2026, 11, 22, 12);
    someone = {maya.id: 'phone|maya', sam.id: 'phone|sam', matt.id: 'phone|matt'};
    adminAt = {};
    await boot();
  });
  tearDown(() async {
    http.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> call(String method, String path, {required _Sender as, Object? json, String address = '10.0.0.1'}) async {
    now = now.add(const Duration(milliseconds: 50));
    final bytes = json == null ? const <int>[] : utf8.encode(jsonEncode(json));
    final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set('x-forwarded-for', address);
    as.headers(method, path, bytes, time: now.millisecondsSinceEpoch).forEach(req.headers.set);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final got = BytesBuilder(copy: false);
    await for (final piece in res) {
      got.add(piece);
    }
    return (res.statusCode, (jsonDecode(utf8.decode(got.takeBytes())) as Map).cast<String, dynamic>());
  }

  String sealedOf(int n, {int size = 200}) => base64Encode(List.generate(size, (i) => (n * 7 + i) & 0xff));

  Future<(int, Map<String, dynamic>)> report(_Sender by, String sealed, {String address = '10.0.0.1'}) => call('POST', '/market/abuse', as: by, json: {'sealed': sealed}, address: address);

  test('a sealed report is kept as it came, listed newest first for review alone, and marked done', () async {
    final (s1, j1) = await report(maya, sealedOf(1));
    expect(s1, 201);
    expect(j1['id'], matches(RegExp(r'^[0-9a-f]{16}$')));
    final (s2, _) = await report(sam, sealedOf(2), address: '10.0.0.2');
    expect(s2, 201);

    // Not review: refused, whoever asks.
    expect((await call('GET', '/market/abuse', as: maya)).$2['error'], 'not_admin');
    adminAt[matt.id] = now;
    final (ls, list) = await call('GET', '/market/abuse', as: matt);
    expect(ls, 200);
    final reports = (list['reports'] as List).cast<Map>();
    expect([for (final r in reports) r['sealed']], [sealedOf(2), sealedOf(1)]);
    expect(reports.every((r) => r['done'] == false), isTrue);
    // Nothing of who sent it, in the answer or on disk.
    expect(reports.every((r) => !r.containsKey('by') && !r.containsKey('from')), isTrue);

    // The queue counts the open ones.
    expect(((await call('GET', '/market/review', as: matt)).$2['counts'] as Map)['abuse'], 2);

    final rid = j1['id'] as String;
    expect((await call('POST', '/market/abuse/$rid', as: maya, json: {'done': true})).$2['error'], 'not_admin');
    expect((await call('POST', '/market/abuse/$rid', as: matt, json: {'done': false})).$2['error'], 'bad_request');
    expect((await call('POST', '/market/abuse/0123456789abcdef', as: matt, json: {'done': true})).$2['error'], 'not_found');
    expect((await call('POST', '/market/abuse/$rid', as: matt, json: {'done': true})).$1, 200);
    final after = ((await call('GET', '/market/abuse', as: matt)).$2['reports'] as List).cast<Map>();
    expect(after.firstWhere((r) => r['rid'] == rid)['done'], isTrue);
    expect(((await call('GET', '/market/review', as: matt)).$2['counts'] as Map)['abuse'], 1);

    // Kept over a restart, with nothing of the sender in state.json.
    await relay.stop();
    final state = File('${dir.path}/market/state.json').readAsStringSync();
    final kept = ((jsonDecode(state) as Map)['abuse'] as Map).values.cast<Map>().toList();
    for (final r in kept) {
      expect(r.keys.toSet(), {'rid', 'sealed', 'at', 'done', 'doneAt'});
    }
    expect(state.contains(maya.id), isFalse);
    expect(state.contains(sam.id), isFalse);
    await boot();
    expect(((await call('GET', '/market/abuse', as: matt)).$2['reports'] as List).length, 2);
  });

  test('only a sealed envelope of its shape is taken', () async {
    expect((await call('POST', '/market/abuse', as: maya, json: {'sealed': sealedOf(1), 'more': 1})).$2['error'], 'bad_request');
    expect((await call('POST', '/market/abuse', as: maya, json: {'sealed': 5})).$2['error'], 'bad_request');
    expect((await report(maya, 'not base64 at all!')).$2['error'], 'bad_request');
    expect((await report(maya, sealedOf(1, size: 10))).$2['error'], 'bad_request', reason: 'too short to be an envelope');
    expect((await report(maya, 'A' * (Market.abuseSealedMost + 4))).$2['error'], 'too_large');
    expect((await call('DELETE', '/market/abuse', as: maya)).$2['error'], 'method');
  });

  test('one key, one address and one someone are held to their limits; strangers share the day\'s', () async {
    // A key: five an hour.
    for (var i = 0; i < Market.abuseByKeyAnHour; i++) {
      expect((await report(maya, sealedOf(i), address: '10.1.0.$i')).$1, 201);
    }
    expect((await report(maya, sealedOf(9), address: '10.1.0.99')).$2['error'], 'rate_limited');
    // An hour on, more, up to the day's.
    now = now.add(const Duration(hours: 1, minutes: 1));
    for (var i = 0; i < Market.abuseByKeyADay - Market.abuseByKeyAnHour; i++) {
      if (i > 0 && i % Market.abuseByKeyAnHour == 0) now = now.add(const Duration(hours: 1, minutes: 1));
      expect((await report(maya, sealedOf(100 + i), address: '10.2.0.$i')).$1, 201, reason: 'report ${i + 1} of the day past the first hour');
    }
    now = now.add(const Duration(hours: 1, minutes: 1));
    expect((await report(maya, sealedOf(200), address: '10.3.0.1')).$2['error'], 'rate_limited', reason: 'the day\'s fifteen');

    // An address, whoever's keys.
    for (var i = 0; i < Market.abuseByAddressADay; i++) {
      someone[_Sender(1000 + i).id] = 'phone|$i';
      expect((await report(_Sender(1000 + i), sealedOf(300 + i), address: '10.9.9.9')).$1, 201);
    }
    expect((await report(sam, sealedOf(400), address: '10.9.9.9')).$2['error'], 'rate_limited');

    // Strangers (no number, no account) share reportsADay.
    await relay.stop();
    await boot(config: const MarketConfig(reportsADay: 2));
    expect((await report(stranger, sealedOf(500), address: '10.4.0.1')).$1, 201);
    expect((await report(_Sender(77), sealedOf(501), address: '10.4.0.2')).$1, 201);
    expect((await report(_Sender(78), sealedOf(502), address: '10.4.0.3')).$2['error'], 'rate_limited');
    expect((await report(sam, sealedOf(503), address: '10.4.0.4')).$1, 201, reason: 'someone with a number is not counted with strangers');
  });

  test('past the most kept, the oldest done goes first, then the oldest', () async {
    adminAt[matt.id] = now;
    // Many senders, each well within their limits.
    final rids = <String>[];
    for (var i = 0; i < Market.abuseKept; i++) {
      final who = _Sender(2000 + i);
      someone[who.id] = 'phone|k$i';
      final (s, j) = await report(who, sealedOf(i), address: '10.5.${i ~/ 10}.${i % 10}');
      expect(s, 201);
      rids.add(j['id'] as String);
    }
    expect((await call('POST', '/market/abuse/${rids[5]}', as: matt, json: {'done': true})).$1, 200);
    final extra = _Sender(9000);
    someone[extra.id] = 'phone|extra';
    expect((await report(extra, sealedOf(9000), address: '10.6.0.1')).$1, 201);
    var kept = [for (final r in (await call('GET', '/market/abuse', as: matt)).$2['reports'] as List) (r as Map)['rid']];
    expect(kept.length, Market.abuseKept);
    expect(kept.contains(rids[5]), isFalse, reason: 'the one marked done went');
    expect(kept.contains(rids[0]), isTrue);
    final more = _Sender(9001);
    someone[more.id] = 'phone|more';
    expect((await report(more, sealedOf(9001), address: '10.6.0.2')).$1, 201);
    kept = [for (final r in (await call('GET', '/market/abuse', as: matt)).$2['reports'] as List) (r as Map)['rid']];
    expect(kept.contains(rids[0]), isFalse, reason: 'none done: the oldest went');
  });
}
