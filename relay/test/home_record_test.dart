import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/home_record.dart';
import 'package:test/test.dart';

/// The home record as the relay checks it (lib/home_record.dart; docs/OPEN_NETWORK.md, section 1), held to the file
/// the app is held to: ../test/home_record_vectors.json, which the app's test/home_record_test.dart writes. The
/// records in it were signed by the app's own code and by this folder's arithmetic; here nothing of the app's is in
/// reach, and the relay's reading must come to the same.
void main() {
  final v = jsonDecode(File('../test/home_record_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final now = DateTime.fromMillisecondsSinceEpoch(v['now'] as int, isUtc: true);
  String hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  test('the bytes an account signs are the ones written down', () {
    final all = v['bytes'] as List;
    expect(all, hasLength(3));
    for (final b in all) {
      expect(hex(HomeRecord.signedBytes(a: b['a'] as String, n: b['n'] as int, t: b['t'] as int, h: (b['h'] as List).cast<String>())), b['hex']);
    }
  });

  test('every good record is taken, and written out again as it came: the app\'s signatures and this folder\'s own', () {
    final good = v['good'] as List;
    expect(good, hasLength(5));
    for (final g in good) {
      final read = HomeRecord.read(g['rec'], now: now);
      expect(read.err, isNull, reason: '${g['name']}');
      expect(read.rec!.toJson(), g['rec'], reason: '${g['name']}');
    }
    expect(good.where((g) => '${g['name']}'.contains('signed by the app')), hasLength(2));
  });

  test('every record that is wrong is refused, for the reason written down', () {
    final bad = v['bad'] as List;
    for (final b in bad) {
      final read = HomeRecord.read(b['rec'], now: now);
      expect([read.rec, read.err], [isNull, b['why']], reason: '${b['name']}');
    }
    expect({for (final b in bad) b['why']}, {'shape', 'name', 'addresses', 'count', 'time', 'future', 'old', 'signature'});
  });

  test('a record made ahead of the clock is taken up to five minutes, by this relay\'s own clock', () {
    final ahead = ((v['good'] as List).firstWhere((g) => '${g['name']}'.contains('ahead')) as Map)['rec'] as Map;
    final made = DateTime.fromMillisecondsSinceEpoch(ahead['t'] as int, isUtc: true);
    expect(HomeRecord.read(ahead, now: made.subtract(HomeRecord.ahead)).err, isNull);
    expect(HomeRecord.read(ahead, now: made.subtract(HomeRecord.ahead + const Duration(milliseconds: 1))).err, 'future');
  });

  test('a record is good for thirty days from its time, and refused as old after, whoever gave it', () {
    final rec = ((v['good'] as List).first as Map)['rec'] as Map;
    final made = DateTime.fromMillisecondsSinceEpoch(rec['t'] as int, isUtc: true);
    expect(HomeRecord.read(rec, now: made.add(HomeRecord.goodFor - const Duration(milliseconds: 1))).err, isNull);
    expect(HomeRecord.read(rec, now: made.add(HomeRecord.goodFor)).err, 'old');
    expect(HomeRecord.read(rec, now: made.add(const Duration(days: 4000)), verify: false).err, 'old', reason: 'read back from its file too');
  });

  test('read back from its own file a record is taken for its shape alone, never a wrong shape', () {
    final tampered = ((v['bad'] as List).firstWhere((b) => b['why'] == 'signature') as Map)['rec'];
    expect(HomeRecord.read(tampered, now: now, verify: false).err, isNull, reason: 'what was checked when it was kept is not checked again');
    for (final b in (v['bad'] as List).where((b) => const {'shape', 'name', 'addresses', 'count', 'time'}.contains(b['why']))) {
      expect(HomeRecord.read(b['rec'], now: now, verify: false).err, b['why'], reason: '${b['name']}');
    }
  });

  test('of two records for one account, the one believed: the higher count, the later made, the greater signature', () {
    for (final o in v['order'] as List) {
      final older = HomeRecord.read(o['older'], now: now).rec!, newer = HomeRecord.read(o['newer'], now: now).rec!;
      expect([newer.newerThan(older), older.newerThan(newer)], [true, false], reason: '${o['name']}');
    }
    expect((v['order'] as List), hasLength(3));
  });

  test('hubs\' addresses as they are compared', () {
    for (final pair in v['hubs'] as List) {
      expect(canonicalHub(pair[0] as String), pair[1], reason: '${pair[0]}');
    }
  });

  test('the addresses a relay reads from a record: a hub\'s, a hosted relay\'s with the relay it stays linked to, and nothing else', () {
    final hub = HomeAddress.parse('WSS://Relay.Example.com:443/hub/')!;
    expect([hub.url, hub.relay, hub.via], ['wss://relay.example.com/hub', null, null]);
    final hosted = HomeAddress.parse('ghost-relay://${'ab' * 16}?n=${'cd' * 32}&via=wss%3A%2F%2Fgogho.st%2Fhub')!;
    expect([hosted.url, hosted.relay, hosted.via], [null, 'ab' * 16, 'wss://gogho.st/hub']);
    expect(HomeAddress.parse('ghost-relay://${'ab' * 16}?n=x')!.via, isNull, reason: 'one with no relay it stays linked to');
    expect(HomeAddress.parse('ghost-relay://${'ab' * 16}?via=not-an-address')!.via, isNull);
    for (final bad in ['ghost-relay://short?via=wss%3A%2F%2Fgogho.st%2Fhub', 'ghost-relay://${'AB' * 16}:99?via=x', 'gopher://x.example/hub', 'https://x.example/hub', 'x.example', '', 'ghost-relay://user@${'ab' * 16}']) {
      expect(HomeAddress.parse(bad), isNull, reason: bad);
    }
    // A record's addresses, in order, those it can't read passed over.
    final rec = HomeRecord.read(((v['good'] as List)[1] as Map)['rec'], now: now).rec!;
    expect(rec.addresses.map((a) => a.url ?? '${a.relay} via ${a.via}').toList(), ['wss://relay.example.com/hub', '${'ab' * 16} via wss://gogho.st/hub']);
  });
}
