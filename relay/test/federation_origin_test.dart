import 'package:test/test.dart';

import 'fed_support.dart';

/// Allowances by where installs come from (federation.dart, `_origin` and `established`; found in the second review,
/// 2026-11-23). Installs cost nothing to make, so shares kept per install alone were shares for however many installs
/// one person made: four new installs a minute asking for names at hosts that don't exist used up this relay's dials,
/// so every real lookup at a relay not yet linked was busy; eight installs used up a day of bytes at another relay.
/// Now one place (an IPv4 address, or an IPv6 address's first 48 bits) has twice one install's share, and installs
/// not established here (a username, or their own record, held here for two days) have half of each shared allowance
/// together, the rest kept for those who are.
void main() {
  late FakeNet net;
  setUp(() => net = FakeNet());

  /// An install signed in to [relay] from [from], holding the username [name] for three days: established there.
  Future<Install> established(TestRelay relay, String name, {String from = '198.51.100.1'}) async {
    final i = Install();
    await i.signIn(relay, from: from);
    await i.giveHome(relay);
    await i.claim(name);
    return i;
  }

  Future<void> threeDaysOn() async {
    for (var d = 0; d < 3; d++) {
      await net.pass(const Duration(days: 1));
    }
  }

  test('installs not established share half the new relays dialled a minute: past it they are busy, and an established install\'s lookup still goes', () async {
    final a = TestRelay(net, 'a.test', seed: 1, shipped: true), b = TestRelay(net, 'b.test', seed: 2, shipped: true);
    final alice = await established(a, 'alice');
    final maya = Install();
    await maya.signIn(b);
    await maya.claim('maya');
    await threeDaysOn();
    expect(a.fed.established(alice.id), isTrue);
    // Twenty new installs, from twenty places, each asking for a name at a host that doesn't exist, in one minute.
    final made = <Install>[];
    for (var i = 0; i < 20; i++) {
      final x = Install();
      await x.signIn(a, from: '203.0.113.${i + 1}');
      expect(a.fed.established(x.id), isFalse);
      x.say({'dir': 'whois', 'name': 'nobody', 'at': 'ghost$i.test'});
      made.add(x);
    }
    await net.settle();
    final busy = made.where((x) => x.said.any((m) => m['dir'] == 'whois' && m['why'] == 'busy')).length;
    expect(busy, 5, reason: 'fifteen of the thirty dials a minute are theirs');
    expect(net.dialled.where((u) => u.contains('ghost')), hasLength(15));
    alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
    await net.settle();
    await net.settle();
    expect(alice.said.lastWhere((m) => m['dir'] == 'whois'), containsPair('id', maya.id), reason: 'the rest of the minute is there for her');
  });

  test('one place makes this relay dial at most twice one install\'s new relays an hour, however many installs it has', () async {
    final a = TestRelay(net, 'a.test', seed: 1, shipped: true, dialsAMinute: 1000);
    final three = [for (var i = 0; i < 3; i++) await established(a, 'user$i', from: '203.0.113.7')];
    await threeDaysOn();
    var n = 0;
    for (final x in three) {
      for (var i = 0; i < 8; i++) {
        x.say({'dir': 'whois', 'name': 'nobody', 'at': 'ghost${n++}.test'});
      }
    }
    await net.settle();
    expect(net.dialled.where((u) => u.contains('ghost')), hasLength(16), reason: 'sixteen for the place, though each install has eight');
    final another = await established(a, 'other', from: '198.51.100.9');
    await threeDaysOn();
    another.say({'dir': 'whois', 'name': 'nobody', 'at': 'ghost-else.test'});
    await net.settle();
    expect(net.dialled.where((u) => u.contains('ghost-else')), hasLength(1), reason: 'another place has its own');
  });

  test('installs not established share half of a day of bytes to another relay: eight of them can\'t use up what an established install sends there', () async {
    final a = TestRelay(net, 'a.test', seed: 1, bytesADay: 300000), b = TestRelay(net, 'b.test', seed: 2, bytesADay: 300000);
    final alice = await established(a, 'alice');
    final bob = Install();
    await bob.signIn(b);
    final bobs = await bob.giveHome(b);
    alice.say({'dir': 'home', 'rec': bobs});
    await threeDaysOn();
    final eight = <Install>[];
    for (var i = 0; i < 8; i++) {
      final x = Install();
      await x.signIn(a, from: '203.0.113.${i + 1}');
      await x.giveHome(a);
      x.say({'dir': 'home', 'rec': bobs});
      eight.add(x);
    }
    await net.settle();
    final answers = <(Install, int)>[];
    for (final x in eight) {
      for (var k = 0; k < 3; k++) {
        answers.add((x, x.send(bob.id, List.filled(10000, 7))));
      }
    }
    await net.settle();
    final refused = answers.where((p) => p.$1.answerTo(p.$2)?['err'] == 'busy').length;
    expect(refused, 10, reason: '14 of 10,384 as counted fit in their 150,000; the other 10 are busy');
    final n = alice.send(bob.id, [1]);
    await net.settle();
    expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true}, reason: 'the other half is there for her');
    expect(bob.frames.last, handed(alice.id, [1]));
  });

  test('one place has twice one install\'s share of a day of bytes, however many installs it has', () async {
    final a = TestRelay(net, 'a.test', seed: 1, bytesADay: 300000), b = TestRelay(net, 'b.test', seed: 2, bytesADay: 300000);
    final bob = Install();
    await bob.signIn(b);
    final bobs = await bob.giveHome(b);
    final three = <Install>[];
    for (var i = 0; i < 3; i++) {
      three.add(await established(a, 'user$i', from: '203.0.113.7'));
      three.last.say({'dir': 'home', 'rec': bobs});
    }
    await threeDaysOn();
    final sent = <(Install, int)>[];
    for (final x in three) {
      for (var k = 0; k < 3; k++) {
        sent.add((x, x.send(bob.id, List.filled(10000, 7))));
      }
    }
    await net.settle();
    final errs = [for (final p in sent) p.$1.answerTo(p.$2)?['err']];
    expect([errs.where((e) => e == null).length, errs.where((e) => e == 'busy').length], [7, 2], reason: '75,000 for the place: seven of 10,384 as counted, whichever install sent them');
  });

  test('established is what this relay saw: a username held two days, or an own record given here two days ago; neither as the install says', () async {
    final a = TestRelay(net, 'a.test', seed: 1);
    final named = Install(), recorded = Install(), fresh = Install();
    await named.signIn(a);
    await named.claim('named');
    await recorded.signIn(a);
    await recorded.giveHome(a);
    await fresh.signIn(a);
    expect([a.fed.established(named.id), a.fed.established(recorded.id)], [false, false]);
    await net.pass(const Duration(days: 1));
    expect([a.fed.established(named.id), a.fed.established(recorded.id)], [false, false]);
    await threeDaysOn();
    expect([a.fed.established(named.id), a.fed.established(recorded.id), a.fed.established(fresh.id)], [true, true, false]);
    // A record made, by its own word, long ago, given today: not established for it.
    final backdated = Install();
    await backdated.signIn(a);
    backdated.say({'dir': 'home', 'rec': backdated.record([a.url], at: net.clock.subtract(const Duration(days: 20)))});
    await net.settle();
    expect(a.fed.established(backdated.id), isFalse);
  });
}
