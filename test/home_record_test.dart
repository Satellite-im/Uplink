import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/home_record.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_relay/home_record.dart' as relay;
import 'package:ghost_relay/p256.dart';

/// The home record as the app makes and checks it (lib/net/home_record.dart; docs/OPEN_NETWORK.md, section 1), held
/// to the same bytes as the relay's (relay/lib/home_record.dart).
///
/// test/home_record_vectors.json holds the signed bytes for a few records, records each side signed, records that
/// are wrong with why, and hubs' addresses as they are compared. This test writes it (UPDATE_HOME_VECTORS=1, or
/// where it is missing) and holds both the app's code and the relay's to it; relay/test/home_record_test.dart reads
/// the same file with nothing of the app's in reach.

const _vectors = 'test/home_record_vectors.json';

/// The moment the vectors are checked at, and when their records were made: an hour before.
final _now = DateTime.utc(2026, 11, 22, 12);
final _made = _now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;

/// Two accounts' private keys, written out: nothing here is random, so the file is the same every time it is made.
final _maya = [for (var i = 1; i <= 32; i++) i];
final _sam = List.filled(32, 0x11);

String _hex(List<int> b) => NetCrypto.hex(b);

/// A record signed as the relay's own arithmetic signs (P256.sign, with a number written out here).
Map<String, Object> _signedByRelayCode(List<int> scalar, List<String> h, {int n = 1, int? t, List<int>? signWith, String? a, int nonce = 7}) {
  final key = P256.publicOf(scalar);
  final name = a ?? NetCrypto.idOf(key);
  final at = t ?? _made;
  final sig = P256.sign(signWith ?? scalar, relay.HomeRecord.signedBytes(a: name, n: n, t: at, h: h), List.filled(32, nonce));
  return {'v': 1, 'a': name, 'k': base64Encode(key), 'h': h, 'n': n, 't': at, 's': base64Encode(sig)};
}

Future<Map<String, Object?>> _build() async {
  final maya = KeysSigner(NetKeys.fromScalar(_maya)), sam = KeysSigner(NetKeys.fromScalar(_sam));
  final hosted = 'ghost-relay://${'ab' * 16}?n=${'cd' * 32}&via=${Uri.encodeQueryComponent('wss://gogho.st/hub')}';
  final long = 'wss://relay.example.com/${'x' * 172}/hub';
  final byApp = await HomeRecord.make(maya, addresses: ['wss://gogho.st/hub'], count: 1, now: DateTime.fromMillisecondsSinceEpoch(_made));
  final moved = await HomeRecord.make(maya, addresses: ['wss://relay.example.com/hub', hosted], count: 2, now: DateTime.fromMillisecondsSinceEpoch(_made + 1000));
  final good = <Map<String, Object?>>[
    {'name': 'signed by the app, one hub', 'rec': byApp.toJson()},
    {'name': 'signed by the app, the next count, a hub and a hosted relay', 'rec': moved.toJson()},
    {'name': 'signed by the relay\'s arithmetic', 'rec': _signedByRelayCode(_sam, ['wss://relay.example.com:8443/hub'])},
    {'name': 'three addresses, one of exactly 200 characters, the highest count there is', 'rec': _signedByRelayCode(_sam, [long, 'wss://b.example/hub', 'ws://10.0.0.5:8787/hub'], n: 0xffffffff)},
    {'name': 'made four minutes ahead of the clock', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub'], t: _now.millisecondsSinceEpoch + 4 * 60000)},
  ];
  final base = _signedByRelayCode(_sam, ['wss://gogho.st/hub']);
  Map<String, Object?> but(Map<String, Object?> changes) => {...base, ...changes};
  final bad = <Map<String, Object?>>[
    {'name': 'another version', 'why': 'shape', 'rec': but({'v': 2})},
    {'name': 'no key', 'why': 'shape', 'rec': Map.of(base)..remove('k')},
    {'name': 'a signature cut short', 'why': 'shape', 'rec': but({'s': base64Encode(base64Decode(base['s']! as String).sublist(0, 63))})},
    {'name': 'a name that is not hex', 'why': 'shape', 'rec': but({'a': 'Z' * 32})},
    {'name': 'not a map', 'why': 'shape', 'rec': 'a record'},
    {'name': 'Sam\'s name over a key that is not his, which did sign it', 'why': 'name', 'rec': {..._signedByRelayCode(_maya, ['wss://evil.example/hub'], a: NetCrypto.idOf(sam.publicKey)), 'k': base64Encode(maya.publicKey)}},
    {'name': 'no address', 'why': 'addresses', 'rec': _signedByRelayCode(_sam, [])},
    {'name': 'four addresses', 'why': 'addresses', 'rec': _signedByRelayCode(_sam, ['wss://1.example/hub', 'wss://2.example/hub', 'wss://3.example/hub', 'wss://4.example/hub'])},
    {'name': 'an address of 201 characters', 'why': 'addresses', 'rec': _signedByRelayCode(_sam, ['wss://relay.example.com/${'x' * 173}/hub'])},
    {'name': 'an address with a space in it', 'why': 'addresses', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub now'])},
    {'name': 'an address that is not a string', 'why': 'addresses', 'rec': but({'h': [7]})},
    {'name': 'a count of nothing', 'why': 'count', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub'], n: 0)},
    {'name': 'a count past four bytes', 'why': 'count', 'rec': but({'n': 0x100000000})},
    {'name': 'a count that is not a number', 'why': 'count', 'rec': but({'n': '1'})},
    {'name': 'a time before there was one', 'why': 'time', 'rec': but({'t': -1})},
    {'name': 'made six minutes ahead of the clock', 'why': 'future', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub'], t: _now.millisecondsSinceEpoch + 6 * 60000)},
    {'name': 'made thirty days before the clock: ended', 'why': 'old', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub'], t: _now.subtract(const Duration(days: 30)).millisecondsSinceEpoch)},
    {'name': 'an address changed after it was signed', 'why': 'signature', 'rec': but({'h': ['wss://evil.example/hub']})},
    {'name': 'an address added after it was signed', 'why': 'signature', 'rec': but({'h': ['wss://gogho.st/hub', 'wss://evil.example/hub']})},
    {'name': 'the count raised after it was signed', 'why': 'signature', 'rec': but({'n': 2})},
    {'name': 'the time changed after it was signed', 'why': 'signature', 'rec': but({'t': _made + 1})},
    {'name': 'signed by another key', 'why': 'signature', 'rec': _signedByRelayCode(_sam, ['wss://gogho.st/hub'], signWith: _maya)},
    {'name': 'the app\'s record with its address changed', 'why': 'signature', 'rec': {...byApp.toJson(), 'h': ['wss://evil.example/hub']}},
  ];
  // Which of two records for one account is believed: the higher count, then the later made, then the greater signature.
  final early = _signedByRelayCode(_sam, ['wss://a.example/hub'], n: 5, t: _made - 60000);
  final late = _signedByRelayCode(_sam, ['wss://b.example/hub'], n: 5, t: _made);
  final twinA = _signedByRelayCode(_sam, ['wss://c.example/hub'], n: 6, t: _made, nonce: 3);
  final twinB = _signedByRelayCode(_sam, ['wss://d.example/hub'], n: 6, t: _made, nonce: 4);
  final aFirst = () {
    final x = base64Decode(twinA['s']! as String), y = base64Decode(twinB['s']! as String);
    for (var i = 0; i < 64; i++) {
      if (x[i] != y[i]) return x[i] > y[i];
    }
    return false;
  }();
  final order = [
    {'name': 'the higher count, whatever else', 'older': _signedByRelayCode(_sam, ['wss://a.example/hub'], n: 4, t: _made), 'newer': early},
    {'name': 'one count: the later made', 'older': early, 'newer': late},
    {'name': 'one count, made at once: the greater signature', 'older': aFirst ? twinB : twinA, 'newer': aFirst ? twinA : twinB},
  ];
  return {
    'about': 'Home records as the app and the relay must both read them (docs/OPEN_NETWORK.md, section 1). Written by test/home_record_test.dart (UPDATE_HOME_VECTORS=1); read by it and by relay/test/home_record_test.dart.',
    'now': _now.millisecondsSinceEpoch,
    'bytes': [
      for (final r in [byApp, moved])
        {'a': r.a, 'n': r.n, 't': r.t, 'h': r.h, 'hex': _hex(HomeRecord.signedBytes(a: r.a, n: r.n, t: r.t, h: r.h))},
      {'a': 'ff' * 16, 'n': 0xffffffff, 't': 0x1fffffffffffff, 'h': ['a', 'b' * 200, 'c'], 'hex': _hex(HomeRecord.signedBytes(a: 'ff' * 16, n: 0xffffffff, t: 0x1fffffffffffff, h: ['a', 'b' * 200, 'c']))},
    ],
    'good': good,
    'bad': bad,
    'order': order,
    'hubs': [
      ['wss://gogho.st/hub', 'wss://gogho.st/hub'],
      ['WSS://Relay.Example.COM:443/hub/', 'wss://relay.example.com/hub'],
      ['wss://relay.example.com:8443/hub', 'wss://relay.example.com:8443/hub'],
      ['ws://10.0.0.5:8787/hub', 'ws://10.0.0.5:8787/hub'],
      ['ws://relay.example.com:80/hub//', 'ws://relay.example.com/hub'],
      ['wss://relay.example.com/a/b/hub', 'wss://relay.example.com/a/b/hub'],
      ['wss://[2001:DB8::1]/hub', 'wss://[2001:db8::1]/hub'],
      ['https://relay.example.com/hub', null],
      ['relay.example.com', null],
      ['wss://user@relay.example.com/hub', null],
      ['wss://relay.example.com/hub?x=1', null],
      ['wss://relay.example.com/hub#x', null],
      ['wss:///hub', null],
      ['ghost-relay://${'ab' * 16}?via=x', null],
    ],
  };
}

void main() {
  late Map<String, dynamic> v;
  late DateTime now;

  setUpAll(() async {
    final built = await _build();
    final file = File(_vectors);
    if (Platform.environment['UPDATE_HOME_VECTORS'] == '1' || !file.existsSync()) {
      file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(built)}\n');
    }
    v = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    now = DateTime.fromMillisecondsSinceEpoch(v['now'] as int, isUtc: true);
    // What this build makes is what the file holds: the app's own signing (which is the same every time) included.
    expect(v, jsonDecode(jsonEncode(built)), reason: 'run with UPDATE_HOME_VECTORS=1 to write $_vectors again');
  });

  test('the bytes an account signs are the same in the app and in the relay, and are the ones written down', () {
    for (final b in v['bytes'] as List) {
      final h = (b['h'] as List).cast<String>();
      final mine = HomeRecord.signedBytes(a: b['a'] as String, n: b['n'] as int, t: b['t'] as int, h: h);
      final theirs = relay.HomeRecord.signedBytes(a: b['a'] as String, n: b['n'] as int, t: b['t'] as int, h: h);
      expect(_hex(mine), b['hex']);
      expect(_hex(theirs), b['hex']);
    }
    // The layout, spelled out once: the words, the name, the count, the time, how many, each address with its length.
    final first = (v['bytes'] as List).first as Map;
    final address = ((first['h'] as List).single as String);
    expect(first['hex'], '${_hex(utf8.encode('ghost-home v1\n'))}${first['a']}00000001${(first['t'] as int).toRadixString(16).padLeft(16, '0')}01${address.length.toRadixString(16).padLeft(2, '0')}${_hex(ascii.encode(address))}');
  });

  test('a good record is taken by both, whichever signed it', () {
    for (final g in v['good'] as List) {
      final mine = HomeRecord.check(g['rec'], now: now);
      expect(mine, isNotNull, reason: 'the app: ${g['name']}');
      expect(mine!.toJson(), g['rec'], reason: 'and written out again as it came');
      final theirs = relay.HomeRecord.read(g['rec'], now: now);
      expect([theirs.err, theirs.rec?.toJson()], [null, g['rec']], reason: 'the relay: ${g['name']}');
    }
    expect((v['good'] as List).length, 5);
  });

  test('a record that is wrong is refused by both, each for the reason written down', () {
    final whys = <String>{};
    for (final b in v['bad'] as List) {
      expect(HomeRecord.check(b['rec'], now: now), isNull, reason: 'the app: ${b['name']}');
      expect(relay.HomeRecord.read(b['rec'], now: now).err, b['why'], reason: 'the relay: ${b['name']}');
      whys.add(b['why'] as String);
    }
    expect(whys, {'shape', 'name', 'addresses', 'count', 'time', 'future', 'old', 'signature'}, reason: 'every way of being wrong is in the file');
  });

  test('of two records for one account, both believe the same one: the higher count, the later made, the greater signature', () {
    for (final o in v['order'] as List) {
      final older = HomeRecord.check(o['older'], now: now)!, newer = HomeRecord.check(o['newer'], now: now)!;
      expect([newer.newerThan(older), older.newerThan(newer), HomeRecord.order(newer, older) > 0], [true, false, true], reason: 'the app: ${o['name']}');
      final ro = relay.HomeRecord.read(o['older'], now: now).rec!, rn = relay.HomeRecord.read(o['newer'], now: now).rec!;
      expect([rn.newerThan(ro), ro.newerThan(rn)], [true, false], reason: 'the relay: ${o['name']}');
    }
    expect((v['order'] as List).length, 3);
  });

  test('a record is good for thirty days by both, and ended after', () {
    final rec = ((v['good'] as List).first as Map)['rec'] as Map;
    final made = DateTime.fromMillisecondsSinceEpoch(rec['t'] as int, isUtc: true);
    expect(HomeRecord.check(rec, now: made.add(HomeRecord.goodFor - const Duration(milliseconds: 1))), isNotNull);
    expect(HomeRecord.check(rec, now: made.add(HomeRecord.goodFor)), isNull);
    expect(relay.HomeRecord.read(rec, now: made.add(HomeRecord.goodFor)).err, 'old');
    expect(HomeRecord.goodFor, relay.HomeRecord.goodFor);
  });

  test('a record is held to the account it is said to be for', () {
    final rec = ((v['good'] as List)[2] as Map)['rec'] as Map;
    final other = ((v['good'] as List)[0] as Map)['rec'] as Map;
    expect(HomeRecord.check(rec, now: now, forId: rec['a'] as String, forKey: rec['k'] as String), isNotNull);
    expect(HomeRecord.check(rec, now: now, forId: other['a'] as String), isNull, reason: 'someone else\'s record is not this friend\'s');
    expect(HomeRecord.check(rec, now: now, forId: rec['a'] as String, forKey: other['k'] as String), isNull);
  });

  test('made through a signer: this account\'s name and key, the count and addresses given, and a signature both take', () async {
    final signer = KeysSigner(NetKeys.generate());
    final rec = await HomeRecord.make(signer, addresses: ['wss://relay.example.com/hub'], count: 7, now: now);
    expect([rec.a, rec.k, rec.h, rec.n, rec.t], [signer.id, signer.publicKey, ['wss://relay.example.com/hub'], 7, now.millisecondsSinceEpoch]);
    expect(HomeRecord.check(jsonDecode(jsonEncode(rec.toJson())), now: now, forId: signer.id)!.n, 7);
    expect(relay.HomeRecord.read(jsonDecode(jsonEncode(rec.toJson())), now: now).err, isNull);
    // What it can't hold, it won't make.
    for (final bad in [<String>[], List.filled(4, 'wss://a.example/hub'), ['wss://a.example/${'x' * 190}/hub'], ['with a space']]) {
      await expectLater(HomeRecord.make(signer, addresses: bad, count: 1), throwsArgumentError);
    }
    await expectLater(HomeRecord.make(signer, addresses: ['wss://a.example/hub'], count: 0), throwsArgumentError);
  });

  test('hubs\' addresses are compared the same way by both', () {
    for (final pair in v['hubs'] as List) {
      expect(canonicalHub(pair[0] as String), pair[1], reason: 'the app: ${pair[0]}');
      expect(relay.canonicalHub(pair[0] as String), pair[1], reason: 'the relay: ${pair[0]}');
    }
  });

  test('which relay a record names, as a person reads it, and what it names', () async {
    final signer = KeysSigner(NetKeys.generate());
    Future<HomeRecord> at(List<String> h) => HomeRecord.make(signer, addresses: h, count: 1, now: now);
    expect((await at(['wss://relay.example.com/hub'])).relayHost, 'relay.example.com');
    expect((await at(['wss://relay.example.com:8443/hub'])).relayHost, 'relay.example.com:8443');
    expect((await at([hostedAddress('ab' * 16, 'wss://gogho.st/hub')])).relayHost, 'gogho.st');
    expect((await at(['ghost-relay://${'ab' * 16}?n=x'])).relayHost, '');
    expect((await at(['gopher://x', 'wss://second.example/hub'])).relayHost, 'second.example');
    final rec = await at(['wss://Relay.Example.com:443/hub/']);
    expect([rec.names('wss://relay.example.com/hub'), rec.names('wss://other.example/hub')], [true, false]);
    expect(hostedAddress('ab' * 16, 'wss://gogho.st/hub'), 'ghost-relay://${'ab' * 16}?via=wss%3A%2F%2Fgogho.st%2Fhub');
    expect(relay.HomeAddress.parse(hostedAddress('ab' * 16, 'wss://gogho.st/hub'))!.via, 'wss://gogho.st/hub', reason: 'the relay reads the address the app writes');
  });

  test('a username as it is added: on this relay, or name@relay for someone on another', () {
    expect(splitUsername('maya'), (name: 'maya', relay: null));
    expect(splitUsername(' @Maya '), (name: 'maya', relay: null));
    expect(splitUsername('maya@relay.example'), (name: 'maya', relay: 'relay.example'));
    expect(splitUsername('@@Maya@Relay.Example:8443'), (name: 'maya', relay: 'relay.example:8443'));
    expect(splitUsername('maya@'), (name: 'maya', relay: ''));
    for (final host in ['relay.example', 'gogho.st', 'a.b.c.example.org', 'relay.example:8443', '10.0.0.5:8787']) {
      expect(goodRelayHost(host), isTrue, reason: host);
    }
    for (final host in ['', 'localhost', 'relay', 'relay.example/hub', 'wss://relay.example', 'relay .example', '-relay.example', 'relay.example:', 'a@b.example', 'x' * 130]) {
      expect(goodRelayHost(host), isFalse, reason: host);
    }
    expect(hubOfHost('relay.example'), 'wss://relay.example/hub');
    expect(hubOfHost('relay.example:443'), 'wss://relay.example/hub');
    expect(hubOfHost('relay.example:8443'), 'wss://relay.example:8443/hub');
    expect(hubOfHost('not a host'), isNull);
  });
}
