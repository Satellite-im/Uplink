// The Marketplace's limits from the relay's environment (relay/lib/market.dart MarketConfig.fromEnvironment; Matt,
// 2026-11-20: "I'd like to be able to verify them for the store through a review process"): each name's default, what a
// value is held to, what is ignored, and that the deploy scripts know the names and the route.
import 'dart:io';

import 'package:ghost_relay/market.dart';
import 'package:test/test.dart';

void main() {
  const d = MarketConfig();
  List<Object> all(MarketConfig c) => [
        c.on, c.maxPackage, c.maxShot, c.maxShots, c.maxBody, c.total, c.submissionsADay, c.submissionsPerAddress, c.openPerDeveloper, c.openPerAddress, c.openTotal, c.openUnverified, //
        c.nameAgeDays, c.pluginsPerDeveloper, c.maxPlugins, c.bytesPerDeveloper, c.signedAnHour, c.signedPerAddress, c.verifyASecond, c.bodiesInFlight, c.readsPerMinute, c.reportsADay, c.needVerified, c.reviewKeys,
      ];
  final key1 = 'A${'b' * 42}=';
  final key2 = 'Ag${'c' * 42}';
  final key3 = 'Aw${'d' * 42}';

  test('the defaults, set or not', () {
    expect(all(d), [true, 262144, 1048576, 4, 6291456, 1073741824, 5, 3, 3, 3, 200, 20, 7, 20, 1000, 25165824, 300, 60, 20, 3, 240, 500, false, <String>[]]);
    expect(all(MarketConfig.fromEnvironment(const {})), all(d));
    expect(MarketConfig.names, hasLength(24));
    expect(MarketConfig.names.toSet(), hasLength(24));
  });

  test('each name sets its own limit', () {
    final values = {
      'GHOST_MARKET_MAX_PACKAGE': (100000, (MarketConfig c) => c.maxPackage),
      'GHOST_MARKET_MAX_SHOT': (500000, (MarketConfig c) => c.maxShot),
      'GHOST_MARKET_MAX_SHOTS': (6, (MarketConfig c) => c.maxShots),
      'GHOST_MARKET_MAX_BODY': (4000000, (MarketConfig c) => c.maxBody),
      'GHOST_MARKET_TOTAL': (2000000000, (MarketConfig c) => c.total),
      'GHOST_MARKET_SUBMISSIONS_A_DAY': (9, (MarketConfig c) => c.submissionsADay),
      'GHOST_MARKET_SUBMISSIONS_PER_ADDRESS': (8, (MarketConfig c) => c.submissionsPerAddress),
      'GHOST_MARKET_OPEN_PER_DEVELOPER': (7, (MarketConfig c) => c.openPerDeveloper),
      'GHOST_MARKET_OPEN_PER_ADDRESS': (6, (MarketConfig c) => c.openPerAddress),
      'GHOST_MARKET_OPEN_TOTAL': (150, (MarketConfig c) => c.openTotal),
      'GHOST_MARKET_OPEN_UNVERIFIED': (15, (MarketConfig c) => c.openUnverified),
      'GHOST_MARKET_NAME_AGE_DAYS': (14, (MarketConfig c) => c.nameAgeDays),
      'GHOST_MARKET_PLUGINS_PER_DEVELOPER': (12, (MarketConfig c) => c.pluginsPerDeveloper),
      'GHOST_MARKET_MAX_PLUGINS': (900, (MarketConfig c) => c.maxPlugins),
      'GHOST_MARKET_BYTES_PER_DEVELOPER': (10000000, (MarketConfig c) => c.bytesPerDeveloper),
      'GHOST_MARKET_SIGNED_AN_HOUR': (250, (MarketConfig c) => c.signedAnHour),
      'GHOST_MARKET_SIGNED_PER_ADDRESS': (30, (MarketConfig c) => c.signedPerAddress),
      'GHOST_MARKET_VERIFY_A_SECOND': (40, (MarketConfig c) => c.verifyASecond),
      'GHOST_MARKET_BODIES_IN_FLIGHT': (5, (MarketConfig c) => c.bodiesInFlight),
      'GHOST_MARKET_READS_PER_MINUTE': (120, (MarketConfig c) => c.readsPerMinute),
      'GHOST_MARKET_REPORTS_A_DAY': (250, (MarketConfig c) => c.reportsADay),
    };
    expect({...values.keys, 'GHOST_MARKET_ON', 'GHOST_MARKET_NEED_VERIFIED', 'GHOST_MARKET_REVIEW_KEYS'}, MarketConfig.names.toSet(), reason: 'every name is tried');
    for (final MapEntry(key: name, value: (value, of)) in values.entries) {
      final c = MarketConfig.fromEnvironment({name: '$value'});
      expect(of(c), value, reason: name);
      expect(of(c), isNot(of(d)), reason: '$name: not its default');
    }
    // All of them at once, read as they are written in the box's env file.
    final c = MarketConfig.fromEnvironment({for (final e in values.entries) e.key: ' ${e.value.$1} '});
    for (final MapEntry(key: name, value: (value, of)) in values.entries) {
      expect(of(c), value, reason: name);
    }
  });

  test('held to what each may be', () {
    MarketConfig of(String name, String value) => MarketConfig.fromEnvironment({name: value});
    expect(of('GHOST_MARKET_MAX_PACKAGE', '9999999').maxPackage, 1048576);
    expect(of('GHOST_MARKET_MAX_SHOT', '9999999').maxShot, 2097152);
    expect(of('GHOST_MARKET_MAX_SHOTS', '99').maxShots, 8);
    expect(of('GHOST_MARKET_MAX_BODY', '${64 << 20}').maxBody, 10485760, reason: 'no bigger than Caddy lets through');
    expect(of('GHOST_MARKET_VERIFY_A_SECOND', '5000').verifyASecond, 1000);
    expect(of('GHOST_MARKET_BODIES_IN_FLIGHT', '50').bodiesInFlight, 20);
    expect(of('GHOST_MARKET_NAME_AGE_DAYS', '999').nameAgeDays, 365);
    expect(of('GHOST_MARKET_NAME_AGE_DAYS', '0').nameAgeDays, 0, reason: 'a username may submit at once where Matt says so');
    expect(of('GHOST_MARKET_OPEN_UNVERIFIED', '0').openUnverified, 0, reason: 'none from unverified developers at all');
    expect(of('GHOST_MARKET_OPEN_UNVERIFIED', '500').openUnverified, 200, reason: 'at most the open total');
    final both = MarketConfig.fromEnvironment({'GHOST_MARKET_OPEN_TOTAL': '10', 'GHOST_MARKET_OPEN_UNVERIFIED': '50'});
    expect([both.openTotal, both.openUnverified], [10, 10]);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_OPEN_TOTAL': '10'}).openUnverified, 10, reason: 'its default, held to a smaller total');
  });

  test('a value that doesn\'t read keeps the default', () {
    for (final junk in ['lots', '-1', '1.5', '1e6', '', ' ', '0x10', '12abc', '99999999999999999999']) {
      final c = MarketConfig.fromEnvironment({for (final n in MarketConfig.names) n: junk});
      expect(all(c), all(d), reason: '"$junk"');
    }
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_MAX_PACKAGE': '0', 'GHOST_MARKET_TOTAL': '0', 'GHOST_MARKET_OPEN_TOTAL': '0'}).maxPackage, d.maxPackage, reason: 'above nothing');
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_TOTAL': '0'}).total, d.total);
  });

  test('the switches: 0 and 1, and nothing else', () {
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_ON': '0'}).on, isFalse);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_ON': '1'}).on, isTrue);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_NEED_VERIFIED': '1'}).needVerified, isTrue);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_NEED_VERIFIED': '0'}).needVerified, isFalse);
    for (final junk in ['yes', 'true', 'off', '2', '']) {
      expect(MarketConfig.fromEnvironment({'GHOST_MARKET_ON': junk}).on, isTrue, reason: junk);
      expect(MarketConfig.fromEnvironment({'GHOST_MARKET_NEED_VERIFIED': junk}).needVerified, isFalse, reason: junk);
    }
  });

  test('the review keys: base64 of 33-byte compressed keys, commas between; any that isn\'t one keeps the default', () {
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_REVIEW_KEYS': key2}).reviewKeys, [key2]);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_REVIEW_KEYS': '$key2,$key3'}).reviewKeys, [key2, key3]);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_REVIEW_KEYS': ' $key2 , $key3 '}).reviewKeys, [key2, key3]);
    for (final bad in [key1, 'A' * 44, '$key2,', '$key2,short', 'x' * 45]) {
      expect(MarketConfig.fromEnvironment({'GHOST_MARKET_REVIEW_KEYS': bad}).reviewKeys, isEmpty, reason: bad);
    }
  });

  test('tool/deploy-relay.mjs knows every name, and tool/deploy-site.mjs passes /market to the relay from both sites', () {
    final known = File('../tool/deploy-relay.mjs').readAsStringSync();
    for (final n in MarketConfig.names) {
      expect(known, contains('$n:'), reason: n);
    }
    expect(known, contains("GHOST_MARKET_REVIEW_KEYS: 'base64 public keys of 44 characters, commas between'"));
    final site = File('../tool/deploy-site.mjs').readAsStringSync();
    expect('@files path /files /files/* /feedback /bounty /souls/* /market /market/*'.allMatches(site), hasLength(2), reason: 'gogho.st\'s block and ghost-sms.com\'s');
    expect(RegExp(r'@files path /files /files/\* /feedback\n').hasMatch(site), isFalse, reason: 'no block left without it');
    // Caddy's MB is 1,000,000 bytes: the relay's clamp on a body (MAX_BODY's most, and Files' 10 << 20) is 10 MiB, so is Caddy's.
    expect(RegExp(r'max_size (\S+)').allMatches(site).map((m) => m[1]).toList(), ['10MiB', '10MiB']);
    expect(MarketConfig.fromEnvironment({'GHOST_MARKET_MAX_BODY': '${64 << 20}'}).maxBody, 10 << 20);
  });
}
