import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/friends/vouches.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/packet.dart';

import 'support/vouch_world.dart';

/// Vouches (GMFB-33; lib/friends/vouches.dart, docs/proofs.md): a friend's signed word that an account is who they say,
/// sent sealed to them, carried with their profile to their friends, and counted by a viewer only for the viewer's own
/// friends, checked against the keys the viewer holds. The installs are test/support/vouch_world.dart's.
void main() {
  test('a vouch reaches the friend, travels with their profile, and counts for a viewer whose friend gave it; taking it back is newest and stands against the old one sent again', () async {
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
    final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)]);
    final mayaAtSam = b[sam]!.byId(maya.keys.id)!, mayaAtTheo = b[theo]!.byId(maya.keys.id)!;
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty);

    await b[sam]!.vouch(mayaAtSam);
    await pumpEventQueue();
    expect(b[sam]!.vouchedFor(mayaAtSam), isTrue);
    expect([for (final v in b[maya]!.vouchersOf(null)) v.username], ['sam'], reason: 'Maya holds Sam\'s vouch for her');
    expect([for (final v in b[theo]!.vouchersOf(mayaAtTheo)) v.username], ['sam'], reason: 'carried to Theo, whose friend Sam is');
    final sent = sam.sent.where((s) => s.envelope.kind == 'vouch').single;
    expect([sent.to, sent.sealed], [maya.keys.id, true]);
    // What Maya carried went sealed, and never in a request in the clear.
    expect(maya.sent.where((s) => s.envelope.body.containsKey('vo')).every((s) => s.sealed), isTrue);
    final oldVouch = sent.envelope;
    final oldCarried = maya.sent.lastWhere((s) => s.to == theo.keys.id && s.envelope.body['s'] == 'vo').envelope;

    await b[sam]!.vouch(mayaAtSam, on: false);
    await pumpEventQueue();
    expect([b[maya]!.vouchersOf(null), b[theo]!.vouchersOf(mayaAtTheo)], [isEmpty, isEmpty]);
    expect(b[sam]!.vouchedFor(mayaAtSam), isFalse);

    // Replays of the vouch from before it was taken back: Sam's own envelope to Maya, and Maya's old profile to Theo.
    sam.deliver(maya, oldVouch);
    maya.deliver(theo, oldCarried);
    await pumpEventQueue();
    expect(b[maya]!.vouchersOf(null), isEmpty, reason: 'the old vouch is older than its withdrawal');
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty, reason: 'Theo saw the withdrawal, and keeps it');
    for (final x in b.values) {
      x.dispose();
    }
  });

  test('a non-friend\'s vouch, and one forged in a friend\'s name, count for nobody', () async {
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo'), mallory = VouchPort(w, 'mallory');
    final b = await makeFriends([(maya, sam), (maya, theo), (maya, mallory), (sam, theo)]);
    final mayaAtTheo = b[theo]!.byId(maya.keys.id)!;
    // Mallory is Maya's friend, not Theo's: Maya holds her vouch, Theo doesn't count it.
    await b[mallory]!.vouch(b[mallory]!.byId(maya.keys.id)!);
    await pumpEventQueue();
    expect([for (final v in b[maya]!.vouchersOf(null)) v.username], ['mallory']);
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty);

    // Mallory signs a vouch in Sam's name (Sam is Theo's friend) and gets it to Theo in Maya's profile.
    final t = DateTime.now().millisecondsSinceEpoch;
    final forged = Vouch(by: sam.keys.id, forId: maya.keys.id, on: true, t: t, sig: NetCrypto.sign(mallory.keys, Vouch.signedBytes(by: sam.keys.id, forId: maya.keys.id, forKey: maya.key, on: true, t: t)));
    maya.deliver(theo, Envelope(kind: 'buddy', body: {'s': 'vo', 'vo': [forged.carried()]}));
    await pumpEventQueue();
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty, reason: 'it isn\'t Sam\'s signature');
    // Nor does Maya take it from Mallory as Sam's.
    mallory.deliver(maya, Envelope(kind: 'vouch', body: forged.toJson()));
    await pumpEventQueue();
    expect([for (final v in b[maya]!.vouchersOf(null)) v.username], ['mallory']);
    for (final x in b.values) {
      x.dispose();
    }
  });

  test('a vouch is for a key: someone under the same name with a new key carries none of it', () async {
    final w = VouchWorld();
    // Maya, and Maya's new install: the same username, another key, friends with Theo too.
    final maya = VouchPort(w, 'maya'), maya2 = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
    final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo), (maya2, theo)]);
    await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
    await pumpEventQueue();
    final carried = maya.sent.lastWhere((s) => s.to == theo.keys.id && s.envelope.body['s'] == 'vo').envelope;
    // The new install says it holds the old key's vouches.
    maya2.deliver(theo, carried);
    await pumpEventQueue();
    expect(b[theo]!.vouchersOf(b[theo]!.byId(maya2.keys.id)), isEmpty);
    expect(b[theo]!.vouchersOf(b[theo]!.byId(maya.keys.id)).length, 1, reason: 'the old key still has it');
    for (final x in b.values) {
      x.dispose();
    }
  });

  test('hidden, the vouches go from friends\' view; removing a friend drops their vouch', () async {
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
    final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)]);
    final mayaAtTheo = b[theo]!.byId(maya.keys.id)!;
    await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
    await pumpEventQueue();
    expect(b[theo]!.vouchersOf(mayaAtTheo).length, 1);
    await b[maya]!.hideVouches(true);
    await pumpEventQueue();
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty);
    expect(b[maya]!.vouchersOf(null).length, 1, reason: 'still hers to see');
    await b[maya]!.hideVouches(false);
    await pumpEventQueue();
    expect(b[theo]!.vouchersOf(mayaAtTheo).length, 1);

    await b[maya]!.remove(b[maya]!.byId(sam.keys.id)!);
    await pumpEventQueue();
    expect(b[maya]!.vouchersOf(null), isEmpty);
    expect(b[maya]!.vouches.held, isEmpty);
    expect(b[theo]!.vouchersOf(mayaAtTheo), isEmpty, reason: 'her friends are told she holds it no more');
    expect(b[sam]!.vouchedFor(mayaAtTheo), isFalse, reason: 'she ended it with Sam, who forgets his vouch');
    for (final x in b.values) {
      x.dispose();
    }
  });

  test('what a profile carries is bounded, kept apart from the list the phone reads keys from, and survives a restart', () async {
    final store = <String, String>{};
    Vouches make() => Vouches(read: (k) => store[k] ?? '', write: (k, v) => store[k] = v);
    final me = NetKeys.generate(), friend = NetKeys.generate();
    final v = make()..load(me.id);
    // 500 vouches for a friend from 500 others: no more than 2 × 64 are read, and 64 kept.
    final recent = DateTime.now().millisecondsSinceEpoch - 600000;
    final many = [
      for (var i = 0; i < 500; i++) {'b': NetCrypto.hex(NetCrypto.sha256([i]).sublist(0, 16)), 't': recent + i, 's': base64Encode(List.filled(64, 1))},
    ];
    v.tookCarried(friend.id, many);
    expect(v.carried[friend.id]!.length, Vouches.most);
    // A malformed one, or one with a huge signature, is passed over.
    v.tookCarried('b' * 32, [{'b': 'x', 't': 1, 's': ''}, {'b': 'c' * 32, 't': 1, 's': 'A' * 400}]);
    expect(v.carried['b' * 32] ?? const {}, isEmpty);

    // Kept: read back after a restart.
    final again = make()..load(me.id);
    expect(again.carried[friend.id]!.length, Vouches.most);

    // A word made with a clock that went back is still later than the one before it.
    var clock = 5000;
    final mine = Vouches.inMemory(now: () => clock);
    final first = await mine.make(me: me.id, forId: friend.id, forKey: base64Encode(friend.public), on: true, sign: (m) async => NetCrypto.sign(me, m));
    clock = 10;
    final back = await mine.make(me: me.id, forId: friend.id, forKey: base64Encode(friend.public), on: false, sign: (m) async => NetCrypto.sign(me, m));
    expect(back.t, greaterThan(first.t));
    expect(back.checks(byKey: base64Encode(me.public), forKey: base64Encode(friend.public)), isTrue);
  });

  test('the friends list the phone keeps is unchanged by vouches, and an envelope of a kind or step it doesn\'t know changes nothing', () async {
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam');
    final b = await makeFriends([(maya, sam)]);
    await pumpEventQueue();
    final before = maya.list;
    await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
    await pumpEventQueue();
    expect(maya.list, before, reason: 'held apart, so the phone\'s list (and every build that reads it) is the same');
    // A build from before carried no `vo`: what is held of them stays as it was.
    sam.deliver(maya, Envelope(kind: 'buddy', body: {'s': 'me', 'n': 'Sam'}));
    sam.deliver(maya, Envelope(kind: 'buddy', body: {'s': 'whatever'}));
    await pumpEventQueue();
    expect(b[maya]!.vouchersOf(null).length, 1);
    expect(b[maya]!.friends.single.name, 'Sam');
    for (final x in b.values) {
      x.dispose();
    }
  });

  group('a vouch is good for a year from when it was signed', () {
    const day = 24 * 3600 * 1000;
    late int clock;
    late VouchWorld w;
    late VouchPort maya, sam, theo;
    late Map<VouchPort, Buddies> b;
    late Map<VouchPort, Map<String, String>> kept;

    setUp(() async {
      clock = DateTime.utc(2026, 11, 23).millisecondsSinceEpoch;
      w = VouchWorld();
      maya = VouchPort(w, 'maya');
      sam = VouchPort(w, 'sam');
      theo = VouchPort(w, 'theo');
      kept = {for (final p in [maya, sam, theo]) p: <String, String>{}};
      b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)], stores: {
        for (final p in [maya, sam, theo]) p: Vouches(read: (k) => kept[p]![k] ?? '', write: (k, v) => kept[p]![k] = v, now: () => clock),
      });
    });
    tearDown(() {
      for (final x in b.values) {
        x.dispose();
      }
    });

    Buddy mayaAt(VouchPort p) => b[p]!.byId(maya.keys.id)!;

    test('run out: counted by nobody, carried to nobody, dropped from what is kept', () async {
      await b[sam]!.vouch(mayaAt(sam));
      await pumpEventQueue();
      expect(b[sam]!.vouchRunsOut(mayaAt(sam)), DateTime.fromMillisecondsSinceEpoch(clock + 365 * day));
      clock += 365 * day - 1;
      expect([b[maya]!.vouchersOf(null).length, b[theo]!.vouchersOf(mayaAt(theo)).length], [1, 1], reason: 'good to the last moment of the year');
      clock += 1;
      expect([b[maya]!.vouchersOf(null), b[theo]!.vouchersOf(mayaAt(theo))], [isEmpty, isEmpty]);
      expect(b[maya]!.vouches.carry(), isEmpty, reason: 'not carried to friends');
      expect(b[sam]!.vouchedFor(mayaAt(sam)), isFalse, reason: 'Sam is offered Vouch for again');
      // Dropped from the store as it is next read.
      final again = Vouches(read: (k) => kept[maya]![k] ?? '', write: (k, v) => kept[maya]![k] = v, now: () => clock)..load(maya.keys.id);
      expect(again.held, isEmpty);
      expect(kept[maya]!.values.single, isNot(contains(sam.keys.id)));
      // And an expired one sent again is not taken.
      final old = sam.sent.lastWhere((s) => s.envelope.kind == 'vouch').envelope;
      sam.deliver(maya, old);
      await pumpEventQueue();
      expect(b[maya]!.vouches.held, isEmpty);
    });

    test('Vouch for again renews it for a year from then', () async {
      await b[sam]!.vouch(mayaAt(sam));
      await pumpEventQueue();
      clock += 200 * day;
      await b[sam]!.vouch(mayaAt(sam));
      await pumpEventQueue();
      clock += 300 * day;
      expect(b[theo]!.vouchersOf(mayaAt(theo)).length, 1, reason: 'a year from the renewal, not from the first');
      expect(b[sam]!.vouchRunsOut(mayaAt(sam)), DateTime.fromMillisecondsSinceEpoch(clock - 300 * day + 365 * day));
      clock += 66 * day;
      expect(b[theo]!.vouchersOf(mayaAt(theo)), isEmpty);
    });

    test('a later time written in a vouch (to make it last longer) breaks its signature', () async {
      await b[sam]!.vouch(mayaAt(sam));
      await pumpEventQueue();
      final carried = maya.sent.lastWhere((s) => s.to == theo.keys.id && s.envelope.body['s'] == 'vo').envelope;
      final moved = [for (final v in carried.body['vo'] as List) {...(v as Map), 't': (v['t'] as int) + 300 * day}];
      clock += 400 * day;
      maya.deliver(theo, Envelope(kind: 'buddy', body: {'s': 'vo', 'vo': moved}));
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(mayaAt(theo)), isEmpty);
      // Nor is one signed further ahead than a clock can be wrong believed.
      final ahead = clock + 30 * day;
      final sig = NetCrypto.sign(sam.keys, Vouch.signedBytes(by: sam.keys.id, forId: maya.keys.id, forKey: maya.key, on: true, t: ahead));
      maya.deliver(theo, Envelope(kind: 'buddy', body: {'s': 'vo', 'vo': [Vouch(by: sam.keys.id, forId: maya.keys.id, on: true, t: ahead, sig: sig).carried()]}));
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(mayaAt(theo)), isEmpty);
    });

    test('a viewer who never saw the withdrawal stops counting the old vouch within the year', () async {
      await b[sam]!.vouch(mayaAt(sam));
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(mayaAt(theo)).length, 1);
      // Theo hears nothing more from Maya, so never sees Sam take it back.
      maya.cut.add(theo.keys.id);
      sam.cut.add(theo.keys.id);
      clock += 10 * day;
      await b[sam]!.vouch(mayaAt(sam), on: false);
      await pumpEventQueue();
      expect(b[maya]!.vouchersOf(null), isEmpty);
      expect(b[theo]!.vouchersOf(mayaAt(theo)).length, 1, reason: 'the limit the year is for');
      clock += 355 * day;
      expect(b[theo]!.vouchersOf(mayaAt(theo)), isEmpty);
    });
  });

  // From the review of 2026-11-23 (did-fix.md).
  group('review fixes', () {
    test('one friend toggling a vouch: the person takes every word but tells each friend once, later', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), x = VouchPort(w, 'x');
      final others = [for (var i = 0; i < 10; i++) VouchPort(w, 'f$i')];
      final b = await makeFriends([(maya, x), for (final o in others) (maya, o)], carryAfter: const Duration(hours: 1));
      final mayaAtX = b[x]!.byId(maya.keys.id)!;
      for (var i = 0; i < 20; i++) {
        await b[x]!.vouch(mayaAtX, on: i.isEven);
        await pumpEventQueue();
      }
      expect(maya.sent.where((s) => s.envelope.body['s'] == 'vo'), isEmpty, reason: 'nothing at once');
      // Every word is taken (the newest stands: x's last was a withdrawal); only the telling waits.
      expect(b[maya]!.vouches.held[x.keys.id]!.on, isFalse);
      await b[maya]!.carryNow();
      await b[maya]!.carryNow();
      expect(maya.sent.where((s) => s.envelope.body['s'] == 'vo').length, 11, reason: 'one envelope a friend, and none again for the same');
      for (final y in b.values) {
        y.dispose();
      }
    });

    test('a long list of one voucher\'s entries costs one signature check', () {
      final sam = NetKeys.generate(), maya = NetKeys.generate(), theo = NetKeys.generate();
      final viewer = Vouches.inMemory()..load(theo.id);
      final recent = DateTime.now().millisecondsSinceEpoch - 600000;
      final list = [for (var i = 0; i < 500; i++) {'b': sam.id, 't': recent + i, 's': base64Encode(List.filled(64, i % 250 + 1))}];
      final before = NetCrypto.verifications;
      viewer.tookCarried(maya.id, list, friendKey: base64Encode(maya.public), keyOf: (id) => id == sam.id ? base64Encode(sam.public) : null);
      expect(NetCrypto.verifications - before, lessThanOrEqualTo(1));
    });

    test('a withdrawal is carried only while what it took back could still count, and an unchecked one is not kept', () async {
      var clock = DateTime.utc(2026, 11, 23).millisecondsSinceEpoch;
      const day = 24 * 3600 * 1000;
      final sam = NetKeys.generate(), maya = NetKeys.generate(), theo = NetKeys.generate();
      final samKey = base64Encode(sam.public), mayaKey = base64Encode(maya.public);
      Future<Uint8List> sign(List<int> m) async => NetCrypto.sign(sam, m);
      final samV = Vouches.inMemory(now: () => clock)..load(sam.id, key: samKey);
      final held = Vouches.inMemory(now: () => clock)..load(maya.id, key: mayaKey);
      // A withdrawal of nothing Maya held: kept (against an old vouch sent again) and never carried.
      clock += day;
      final bare = await samV.make(me: sam.id, forId: maya.id, forKey: mayaKey, on: false, sign: sign);
      expect(held.heard(bare.toJson(), from: sam.id, fromKey: samKey, me: maya.id, meKey: mayaKey), isTrue);
      expect(held.carry(), isEmpty);
      // A vouch, then its withdrawal: carried until the vouch would have run out.
      final yes = await samV.make(me: sam.id, forId: maya.id, forKey: mayaKey, on: true, sign: sign);
      held.heard(yes.toJson(), from: sam.id, fromKey: samKey, me: maya.id, meKey: mayaKey);
      clock += 100 * day;
      final no = await samV.make(me: sam.id, forId: maya.id, forKey: mayaKey, on: false, sign: sign);
      held.heard(no.toJson(), from: sam.id, fromKey: samKey, me: maya.id, meKey: mayaKey);
      expect(held.carry().single['x'], 1);
      clock = yes.until;
      expect(held.carry(), isEmpty);
      // A viewer keeps no withdrawal it couldn't check (a stranger's, or forged), whatever the profile says later.
      final viewer = Vouches.inMemory(now: () => clock)..load(theo.id);
      final fake = [for (var i = 0; i < 64; i++) {'b': NetCrypto.hex(NetCrypto.sha256([i]).sublist(0, 16)), 't': clock - day, 's': base64Encode(List.filled(64, 7)), 'x': 1}];
      viewer.tookCarried(maya.id, fake, friendKey: mayaKey, keyOf: (_) => null);
      expect(viewer.carried[maya.id] ?? const {}, isEmpty);
    });

    test('two devices of the voucher: a withdrawal on the one whose clock is behind still wins', () async {
      final sam = NetKeys.generate(), maya = NetKeys.generate();
      final samKey = base64Encode(sam.public), mayaKey = base64Encode(maya.public);
      Future<Uint8List> sign(List<int> m) async => NetCrypto.sign(sam, m);
      final phone = Vouches.inMemory(now: () => 2000000)..load(sam.id, key: samKey);
      final laptop = Vouches.inMemory(now: () => 1000000)..load(sam.id, key: samKey); // 16 minutes behind
      final yes = await phone.make(me: sam.id, forId: maya.id, forKey: mayaKey, on: true, sign: sign);
      // Maya's profile carries the phone's vouch back to the laptop.
      laptop.tookCarried(maya.id, [yes.carried()], friendKey: mayaKey, keyOf: (id) => id == sam.id ? samKey : null);
      expect(laptop.givenFor(maya.id, forKey: mayaKey), isNotNull, reason: 'the laptop knows Sam vouches');
      final no = await laptop.make(me: sam.id, forId: maya.id, forKey: mayaKey, on: false, sign: sign);
      expect(no.t, greaterThan(yes.t));
      final held = Vouches.inMemory(now: () => 2000000)..load(maya.id, key: mayaKey);
      held.heard(yes.toJson(), from: sam.id, fromKey: samKey, me: maya.id, meKey: mayaKey);
      expect(held.heard(no.toJson(), from: sam.id, fromKey: samKey, me: maya.id, meKey: mayaKey), isTrue);
      expect(held.held[sam.id]!.on, isFalse);
    });

    test('two devices of the one vouched for, saying a little apart: the viewer merges them, and the count holds', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), ana = VouchPort(w, 'ana'), theo = VouchPort(w, 'theo');
      final b = await makeFriends([(maya, sam), (maya, ana), (maya, theo), (sam, theo), (ana, theo)]);
      await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
      await b[ana]!.vouch(b[ana]!.byId(maya.keys.id)!);
      await pumpEventQueue();
      final mayaAtTheo = b[theo]!.byId(maya.keys.id)!;
      expect(b[theo]!.vouchersOf(mayaAtTheo).length, 2);
      // Maya's other device heard only Sam's.
      final samsOnly = [b[maya]!.vouches.held[sam.keys.id]!.carried()];
      maya.deliver(theo, Envelope(kind: 'buddy', body: {'s': 'vo', 'vo': samsOnly}));
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(mayaAtTheo).length, 2);
      for (final y in b.values) {
        y.dispose();
      }
    });
  });

  // From the second review of 2026-11-23.
  group('second review fixes', () {
    test('a carrying the app closed before making is made at its next start', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
      final store = <String, String>{};
      Vouches mayaStore() => Vouches(read: (k) => store[k] ?? '', write: (k, v) => store[k] = v);
      final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)], stores: {maya: mayaStore()}, carryAfter: const Duration(hours: 1));
      await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
      await pumpEventQueue();
      b[maya]!.dispose(); // closed well inside the wait
      final again = Buddies(maya, vouches: mayaStore(), carryAfter: Duration.zero);
      await again.start();
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(b[theo]!.byId(maya.keys.id)).length, 1);
      // And once told, a start after doesn't tell again.
      again.dispose();
      final sent = maya.sent.length;
      final third = Buddies(maya, vouches: mayaStore(), carryAfter: Duration.zero);
      await third.start();
      await pumpEventQueue();
      expect(maya.sent.where((s) => s.envelope.body['s'] == 'vo').length, maya.sent.take(sent).where((s) => s.envelope.body['s'] == 'vo').length);
      third.dispose();
      for (final x in [b[sam]!, b[theo]!]) {
        x.dispose();
      }
    });

    test('a first start with no vouches at all tells nobody anything', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam');
      final b = await makeFriends([(maya, sam)]);
      await pumpEventQueue();
      expect(maya.sent.where((s) => s.envelope.body['s'] == 'vo'), isEmpty);
      for (final x in b.values) {
        x.dispose();
      }
    });

    test('past four changes an hour from one friend, the word is still taken and friends are still told', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
      final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)]);
      final mayaAtSam = b[sam]!.byId(maya.keys.id)!;
      for (final on in [true, false, true, false, true, false, true]) {
        await b[sam]!.vouch(mayaAtSam, on: on);
        await pumpEventQueue();
      }
      expect(b[maya]!.vouchersOf(null).length, 1, reason: 'the seventh, a vouch, is held');
      await b[maya]!.carryNow(); // what the hour's timer does
      await pumpEventQueue();
      expect(b[theo]!.vouchersOf(b[theo]!.byId(maya.keys.id)).length, 1);
      for (final x in b.values) {
        x.dispose();
      }
    });

    test('a withdrawal a viewer can\'t check yet takes away the vouch it holds, so it never counts once they are friends', () {
      final sam = NetKeys.generate(), maya = NetKeys.generate(), theo = NetKeys.generate();
      final samKey = base64Encode(sam.public), mayaKey = base64Encode(maya.public);
      final now = DateTime.now().millisecondsSinceEpoch;
      Vouch word(bool on, int t) => Vouch(by: sam.id, forId: maya.id, on: on, t: t, sig: NetCrypto.sign(sam, Vouch.signedBytes(by: sam.id, forId: maya.id, forKey: mayaKey, on: on, t: t)));
      final viewer = Vouches.inMemory()..load(theo.id);
      viewer.tookCarried(maya.id, [word(true, now - 2000).carried()], friendKey: mayaKey, keyOf: (_) => null);
      expect(viewer.carried[maya.id]!.containsKey(sam.id), isTrue);
      viewer.tookCarried(maya.id, [word(false, now - 1000).carried()], friendKey: mayaKey, keyOf: (_) => null);
      expect(viewer.carried[maya.id]?[sam.id], isNull);
      expect(viewer.vouchersOf(maya.id, mayaKey, [sam.id], id: (x) => x, key: (_) => samKey), isEmpty);
    });

    test('a dropped voucher is told only to friends who were carried their vouch', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo'), zoe = VouchPort(w, 'zoe');
      final b = await makeFriends([(maya, sam), (maya, theo)]);
      await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
      await pumpEventQueue();
      // Zoe becomes Maya's friend after Sam's vouch was carried, and Maya then removes Sam.
      final mz = await makeFriends([(maya, zoe)]);
      b[maya]!.all = [...b[maya]!.all, friendOf(zoe)];
      maya.list = jsonEncode([for (final x in b[maya]!.all) x.toJson()]);
      await b[maya]!.remove(b[maya]!.byId(sam.keys.id)!);
      await pumpEventQueue();
      await b[maya]!.carryNow();
      final vo = maya.sent.where((s) => s.envelope.body['s'] == 'vo' && s.envelope.body.containsKey('vd'));
      expect({for (final s in vo) s.to}, {theo.keys.id}, reason: 'Theo was carried Sam\'s vouch; Zoe never learns Sam vouched');
      for (final x in [...b.values, ...mz.values]) {
        x.dispose();
      }
    });
  });

  group('the account\'s own devices (GMFB-33)', () {
    test('a vouch made on one device is known on the others, its taking back too, and a device that was closed is told as it asks', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya');
      final phone = _Device(w, 'sam'), mac = _Device(w, 'sam', keys: phone.keys);
      phone.others = [mac];
      mac.others = [phone];
      final b = await makeFriends([(maya, phone)]);
      mac.list = phone.list;
      final onMac = Buddies(mac, carryAfter: Duration.zero);
      await onMac.start();
      // Maya shows nobody her vouches, so nothing comes back to Sam's devices in her profile.
      await b[maya]!.hideVouches(true);
      await pumpEventQueue();
      final mayaOnPhone = b[phone]!.byId(maya.keys.id)!, mayaOnMac = onMac.byId(maya.keys.id)!;

      await b[phone]!.vouch(mayaOnPhone);
      await pumpEventQueue();
      expect(onMac.vouchedFor(mayaOnMac), isTrue, reason: 'the Mac knows what the phone gave');
      expect(onMac.vouchRunsOut(mayaOnMac), b[phone]!.vouchRunsOut(mayaOnPhone));
      final told = phone.mine.single;
      expect(told.kind, Buddies.ownKind);

      // Taken back on the Mac: the phone stops saying it vouches.
      await onMac.vouch(mayaOnMac, on: false);
      await pumpEventQueue();
      expect(b[phone]!.vouchedFor(mayaOnPhone), isFalse);
      // The phone's old telling, come again, does not bring the vouch back.
      phone.deliver(mac, told);
      await pumpEventQueue();
      expect(onMac.vouchedFor(mayaOnMac), isFalse);

      // A tablet that was closed through all of it asks as it starts, and is told.
      await b[phone]!.vouch(mayaOnPhone);
      await pumpEventQueue();
      final tablet = _Device(w, 'sam', keys: phone.keys)..list = phone.list;
      tablet.others = [phone, mac];
      phone.others = [mac, tablet];
      mac.others = [phone, tablet];
      final onTablet = Buddies(tablet, carryAfter: Duration.zero);
      await onTablet.start();
      expect(onTablet.vouchedFor(onTablet.byId(maya.keys.id)!), isFalse);
      await onTablet.syncVouches(ask: true);
      await pumpEventQueue();
      expect(onTablet.vouchedFor(onTablet.byId(maya.keys.id)!), isTrue);
      // An answer asks nothing, so nobody goes on answering.
      final before = phone.mine.length + mac.mine.length + tablet.mine.length;
      await pumpEventQueue();
      expect(phone.mine.length + mac.mine.length + tablet.mine.length, before);
      for (final x in [...b.values, onMac, onTablet]) {
        x.dispose();
      }
    });

    test('only this account\'s own signed words are taken, about friends, from its own devices', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya'), theo = VouchPort(w, 'theo'), mallory = VouchPort(w, 'mallory');
      final phone = _Device(w, 'sam');
      final b = await makeFriends([(maya, phone), (mallory, phone)]);
      final sam = b[phone]!;
      final t = DateTime.now().millisecondsSinceEpoch;
      Vouch word(NetKeys by, VouchPort about, {String? as}) => Vouch(by: as ?? by.id, forId: about.keys.id, on: true, t: t, sig: NetCrypto.sign(by, Vouch.signedBytes(by: as ?? by.id, forId: about.keys.id, forKey: about.key, on: true, t: t)));
      // A friend sends the kind with a word of Sam's own making: it isn't from Sam's devices.
      final real = word(phone.keys, maya);
      mallory.deliver(phone, Envelope(kind: Buddies.ownKind, body: {'v': [real.toJson()], 'q': 1}));
      await pumpEventQueue();
      expect(sam.vouchedFor(sam.byId(maya.keys.id)!), isFalse);
      expect(phone.mine, isEmpty, reason: 'and nobody else is told what Sam gave');
      // From Sam's own name, but signed by someone else in Sam's name; and a true word about someone who isn't a friend.
      phone.deliver(phone, Envelope(kind: Buddies.ownKind, body: {'v': [word(mallory.keys, maya, as: phone.keys.id).toJson(), word(phone.keys, theo).toJson(), 'x', {'b': 1}]}));
      await pumpEventQueue();
      expect(sam.vouchedFor(sam.byId(maya.keys.id)!), isFalse);
      expect(sam.vouches.given, isEmpty);
      // The true word, from Sam's own devices: taken.
      phone.deliver(phone, Envelope(kind: Buddies.ownKind, body: {'v': [real.toJson()]}));
      await pumpEventQueue();
      expect(sam.vouchedFor(sam.byId(maya.keys.id)!), isTrue);
      for (final x in b.values) {
        x.dispose();
      }
    });
  });
}

/// One device of an account that has others: what it tells them reaches each as from the account itself.
class _Device extends VouchPort implements BuddiesMine {
  _Device(super.world, super.name, {super.keys});
  List<_Device> others = [];
  final mine = <Envelope>[];

  @override
  Future<bool> sendMine(Envelope envelope) async {
    mine.add(envelope);
    for (final o in others) {
      deliver(o, envelope);
    }
    return true;
  }
}
