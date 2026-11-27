import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/home_record.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';

import 'support/hub_pair.dart';
import 'support/relay_app.dart';
import 'support/relay_net.dart';

/// Two people whose apps use different relays, friends (docs/OPEN_NETWORK.md, section 4; Matt, 2026-11-22: "I'd like
/// the relays to be able to talk to each other"). Each install here is the app's own code from the hub's route up:
/// a HubCarrier signed in to its relay, the switchboard that seals and opens, the home keeping (lib/net/homes.dart)
/// and friends by username (lib/friends/buddies.dart). The relays are real hubs with real federation, in memory
/// (test/support/relay_net.dart). Only the phone's own side is stood in for: the list it keeps and the keys it makes.

extension on RelayApp {
  Buddy get friend => buddies.friends.single;

  /// Writes [words] to [to] and waits for [to]'s app to say it has them: across relays the relay only says it was
  /// taken (whether they are connected is not said), so the friend's answer is what says it arrived.
  Future<Delivery> writeAnswered(RelayApp to, String words) async {
    final d = await write(to, words);
    expect(d.sent, isTrue);
    await until(() => d.acked || acked.contains(d.id), 'the answer to "$words" never came back');
    return d;
  }
}

void main() {
  late RelayNet net;
  late MemoryHub a, b;
  final apps = <RelayApp>[];

  Future<RelayApp> app(String name, MemoryHub relay) async {
    final x = RelayApp(net, name, relay);
    apps.add(x);
    await x.start();
    return x;
  }

  setUp(() {
    net = RelayNet();
    a = net.relay('a.test');
    b = net.relay('b.test');
  });
  tearDown(() async {
    for (final x in apps) {
      await x.stop();
    }
    apps.clear();
  });

  /// Alex on relay a and Maya on relay b, friends: he added her as maya@b.test, and she said yes.
  Future<(RelayApp, RelayApp)> friends() async {
    final alex = await app('alex', a), maya = await app('maya', b);
    await alex.buddies.add('maya@b.test');
    await until(() => maya.buddies.requests.isNotEmpty, 'the request never reached Maya');
    await maya.buddies.accept(maya.buddies.requests.single);
    await until(() => alex.buddies.friends.isNotEmpty, 'her yes never reached Alex');
    await until(() => maya.friend.home != null && alex.friend.homeCount > 0, 'they never heard where each other lives');
    return (alex, maya);
  }

  test('each install gives its relay its own home record as it signs in, naming the relay as it names itself', () async {
    final alex = await app('alex', a);
    // Its count is never below the seconds since 1970 (lib/net/homes.dart).
    final n = alex.homes.mine!.n;
    expect(alex.homes.mine!.toJson(), {'v': 1, 'a': alex.id, 'k': base64Encode(alex.keys.public), 'h': ['wss://a.test/hub'], 'n': greaterThanOrEqualTo(DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60), 't': isA<int>(), 's': isA<String>()});
    await until(() => net.feds[a.url]!.homes.isOwn(alex.id), 'the relay never kept it');
    expect(alex.choices['net_home_n'], '$n');
    expect(HomeRecord.check(jsonDecode(alex.choices['net_home']!), forId: alex.id)!.n, n);
    expect([alex.homes.relayTalks, alex.hub.relay!.url, alex.hub.relay!.id], [true, 'wss://a.test/hub', net.feds[a.url]!.id]);
    // Signing in again gives the same record, and makes no new one.
    await alex.away();
    await alex.back();
    await pumpEventQueue();
    expect([alex.homes.mine!.n, net.feds[a.url]!.homes.of(alex.id)!.n], [n, n]);
  });

  test('two installs on two relays become friends by name@relay, and write to each other both ways', () async {
    final (alex, maya) = await friends();
    // Each is kept by the other as name@relay, with a home record that is the other's own.
    expect([alex.friend.username, alex.friend.id, alex.friend.homeHost], ['maya@b.test', maya.id, 'b.test']);
    expect([maya.friend.username, maya.friend.id, maya.friend.homeHost], ['alex@a.test', alex.id, 'a.test']);
    expect([alex.buddies.relayOf(alex.friend), maya.buddies.relayOf(maya.friend), alex.buddies.elsewhere(alex.friend)], ['b.test', 'a.test', true]);
    expect(HomeRecord.check(alex.friend.home, forId: maya.id, forKey: base64Encode(maya.keys.public)), isNotNull);
    expect(jsonDecode(alex.list), [containsPair('h', maya.homes.mine!.toJson())], reason: 'kept with the friend, where the phone keeps the list');
    expect(alex.buddies.unreached(alex.friend), isFalse);
    // The relays linked, once, and each holds the other's record.
    expect(net.dialled, ['wss://b.test/hub', 'wss://a.test/hub', 'wss://a.test/hub'], reason: 'a dialled b; b looked at the address a claims, then dialled it for a link of its own (what is for an address goes only over a link a relay dialled itself)');
    expect([net.feds[a.url]!.homes.of(maya.id)!.n, net.feds[b.url]!.homes.of(alex.id)!.n], [maya.homes.mine!.n, alex.homes.mine!.n]);

    final there = await alex.write(maya, 'hello from a');
    expect([there.sent, there.via, there.handed], [true, 'hub', Handed.held], reason: 'taken by her relay: whether she is connected is not said across relays');
    await until(() => alex.acked.contains(there.id) || there.acked, 'her answer never came back');
    // Each told the other where they live as they became friends, with a sealed envelope of its own, and each knows
    // the other holds it because the other said so (`has`), not because it went.
    Map told(RelayApp x) => jsonDecode(x.choices['buddies_home_told2:${x.id}']!) as Map;
    expect([told(alex)['told'], told(maya)['told']], [{maya.id: alex.homes.mine!.n}, {alex.id: maya.homes.mine!.n}]);
    expect(alex.choices.containsKey('buddies_home_told'), isFalse, reason: 'the key of the build before, which counted what merely went, is not written');
    expect(alex.hub.passedOn(maya.id), isTrue);
    final back = await maya.write(alex, 'hello from b');
    expect(back.handed, Handed.held);
    await until(() => maya.acked.contains(back.id) || back.acked, 'his answer never came back');
    expect(maya.texts, [(from: alex.id, text: 'hello from a')]);
    expect(alex.texts, [(from: maya.id, text: 'hello from b')]);
    expect([a.hub.holding, b.hub.holding], [0, 0], reason: 'nothing of it is left on either relay');
  });

  test('with one of them away it is kept at their relay, and theirs when they come back', () async {
    final (alex, maya) = await friends();
    await maya.away();
    final kept = await alex.write(maya, 'for later');
    expect([kept.sent, kept.handed, kept.acked], [true, Handed.held, false], reason: 'kept for her, as her own relay would say of anyone on it');
    expect([b.hub.heldFor(maya.id), a.hub.heldFor(maya.id)], [1, 0], reason: 'at her relay, not at his');
    await maya.back();
    await until(() => maya.texts.isNotEmpty, 'what was kept never reached her');
    expect(maya.texts.single.text, 'for later');
    await until(() => alex.acked.contains(kept.id), 'her answer never came back across');
    // And the other way: he is away, she writes.
    await alex.away();
    final other = await maya.write(alex, 'and you');
    expect(other.handed, Handed.held);
    expect(a.hub.heldFor(alex.id), 1);
    await alex.back();
    await until(() => alex.texts.isNotEmpty, 'what was kept never reached him');
    expect(alex.texts.single.text, 'and you');
  });

  test('the relay starts again and has forgotten where friends live: the app says so again as it signs in, and what is written still crosses', () async {
    final (alex, maya) = await friends();
    final again = net.restart('a.test');
    expect(net.feds[a.url]!.homes.of(maya.id), isNull, reason: 'the relay holds nothing of her now');
    await until(() => again.hub.connected == 1 && alex.hub.state.value == CarrierState.up, 'Alex never signed in to the relay that started again');
    // At his sign-in: his own record, and hers, before anything else.
    await until(() => net.feds[a.url]!.homes.of(maya.id) != null, 'the relay was not told where she lives');
    expect([net.feds[a.url]!.homes.isOwn(alex.id), net.feds[a.url]!.homes.of(maya.id)!.h], [true, ['wss://b.test/hub']]);
    final sent = await alex.write(maya, 'still here');
    expect([sent.handed, a.hub.heldFor(maya.id), again.hub.heldFor(maya.id)], [Handed.held, 0, 0]);
    await until(() => alex.acked.contains(sent.id) || sent.acked, 'her answer never came back');
    expect(maya.texts.single.text, 'still here');
  });

  test('a relay that no longer holds a friend\'s record (it keeps only so many) is told again when it only keeps a packet for them', () async {
    // Alex's relay holds one record of people on other relays, no more.
    net = RelayNet();
    a = net.relay('a.test', maxOthers: 1);
    b = net.relay('b.test');
    final c = net.relay('c.test');
    final alex = await app('alex', a), maya = await app('maya', b), zoe = await app('zoe', c);
    for (final (who, at) in [(maya, 'maya@b.test'), (zoe, 'zoe@c.test')]) {
      await alex.buddies.add(at);
      await until(() => who.buddies.requests.isNotEmpty, 'the request never arrived');
      await who.buddies.accept(who.buddies.requests.single);
      await until(() => alex.buddies.byId(who.id)?.state == 'yes', 'they never became friends');
    }
    // Something is written to Zoe, so hers is the one record the relay holds; Maya's is the one let go.
    await alex.writeAnswered(zoe, 'hello');
    await until(() => net.feds[a.url]!.homes.of(maya.id) == null || net.feds[a.url]!.homes.of(zoe.id) != null, 'the relay never settled');
    if (net.feds[a.url]!.homes.of(maya.id) != null) {
      // (Whichever it kept, the other is the one tried: the two are the same case.)
      expect(net.feds[a.url]!.homes.of(zoe.id), isNull);
    }
    final gone = net.feds[a.url]!.homes.of(maya.id) == null ? maya : zoe;
    final first = await alex.write(gone, 'are you there');
    expect([first.handed, alex.hub.passedOn(gone.id)], [Handed.held, false], reason: 'the relay kept it here: it did not know where they live');
    // The app heard that, and said their record again: the next is passed on.
    await until(() => net.feds[a.url]!.homes.of(gone.id) != null, 'the relay was not told again');
    final second = await alex.write(gone, 'now');
    expect(alex.hub.passedOn(gone.id), isTrue);
    await until(() => alex.acked.contains(second.id) || second.acked, 'the answer never came back');
    expect(gone.texts.map((t) => t.text), contains('now'));
  });

  test('a friend\'s forged or older record is ignored, and a newer one of their own is taken', () async {
    final (alex, maya) = await friends();
    final held = Map.of(maya.friend.home!);
    Future<void> say(Object? rec) async {
      await alex.board!.send(alex.byId(maya.id)!, Envelope(kind: 'home', body: {'rec': rec}), only: const {'hub'});
      await pumpEventQueue();
    }

    final mallory = KeysSigner(NetKeys.generate());
    // Someone else's record, however good.
    await say((await HomeRecord.make(mallory, addresses: ['wss://evil.test/hub'], count: 9)).toJson());
    expect(maya.friend.home, held);
    // Alex's name on a record another key signed.
    final forged = (await HomeRecord.make(mallory, addresses: ['wss://evil.test/hub'], count: 9)).toJson()
      ..['a'] = alex.id
      ..['k'] = base64Encode(alex.keys.public);
    await say(forged);
    expect(maya.friend.home, held);
    // His own record, changed after he signed it.
    await say({...alex.homes.mine!.toJson(), 'h': ['wss://evil.test/hub'], 'n': 5});
    expect(maya.friend.home, held);
    // His own, with the same count as the one she holds made earlier, and one older.
    final n = alex.homes.mine!.n;
    await say((await HomeRecord.make(alex.signer, addresses: ['wss://same.test/hub'], count: n, now: DateTime.fromMillisecondsSinceEpoch(held['t']! as int).subtract(const Duration(seconds: 1)))).toJson());
    await say((await HomeRecord.make(alex.signer, addresses: ['wss://same.test/hub'], count: n - 1)).toJson());
    expect(maya.friend.home, held);
    // Not a record at all.
    await say('here');
    await say(null);
    expect(maya.friend.home, held);
    expect(net.feds[b.url]!.homes.of(alex.id)!.h, ['wss://a.test/hub'], reason: 'and her relay was given none of them');
    // A newer one of his own is taken, and her relay is given it.
    final newer = (await HomeRecord.make(alex.signer, addresses: ['wss://c.test/hub'], count: n + 1)).toJson();
    await say(newer);
    await until(() => maya.friend.homeCount == n + 1, 'his newer record was not taken');
    expect(maya.friend.home, newer);
    await until(() => net.feds[b.url]!.homes.of(alex.id)!.n == n + 1, 'her relay was not given it');
    // Then the older one again changes nothing.
    await say(held);
    expect(maya.friend.homeCount, n + 1);
  });

  test('moving to another relay: a new record with the next count, given to the relay left and the new one, and friends follow it', () async {
    final (alex, maya) = await friends();
    final c = net.relay('c.test');
    final was = maya.homes.mine!.n;
    await maya.moveTo(c);
    final now = maya.homes.mine!.n;
    expect([now, maya.homes.mine!.h], [greaterThan(was), ['wss://c.test/hub']]);
    await until(() => net.feds[c.url]!.homes.isOwn(maya.id), 'the new relay was not given it');
    expect(net.feds[b.url]!.homes.of(maya.id)!.n, now, reason: 'the relay she left holds the new record (she waited for its answer before leaving): it knows she lives elsewhere now');
    // Alex has not heard yet: what he writes still goes to the relay she left, which says where she lives now, and
    // his relay takes it there itself.
    expect(alex.friend.homeCount, was);
    final first = await alex.write(maya, 'are you there');
    expect(first.sent, isTrue);
    await until(() => alex.acked.contains(first.id) || first.acked, 'her answer never came back');
    await until(() => maya.texts.isNotEmpty, 'it never followed her');
    expect(net.feds[a.url]!.homes.of(maya.id)!.n, now, reason: 'his relay learnt it from the relay she left');
    expect(net.feds[b.url]!.linkedWith(net.feds[c.url]!.id), isFalse, reason: 'the relay she left never passed it on itself');
    // Friends are told a few at a time: nobody yet, then Alex when his turn comes.
    expect(maya.buddies.waitingToHear, 1);
    expect(await maya.buddies.tellNext(), isTrue);
    await until(() => alex.friend.homeCount == now, 'he was never told');
    expect([alex.friend.homeHost, alex.buddies.relayOf(alex.friend), maya.buddies.waitingToHear], ['c.test', 'c.test', 0]);
    expect(await maya.buddies.tellNext(), isFalse);
    // And back to her from there, and to him.
    await alex.writeAnswered(maya, 'found you');
    await maya.writeAnswered(alex, 'here');
    expect(maya.texts.map((t) => t.text), ['are you there', 'found you']);
  });

  test('a record asked for while a move is under way, or just after it on the relay being left, doesn\'t take the move back', () async {
    final alex = await app('alex', a);
    // The connection came back during the move, say, or anything else asked for a record meanwhile: it waits for the
    // move, and runs while the app is still on the relay it is leaving.
    final moving = alex.homes.moveTo(b.url);
    final during = alex.homes.ensure();
    await moving;
    await during;
    await alex.homes.ensure();
    expect(alex.homes.mine!.h, ['wss://b.test/hub'], reason: 'the record still names where the account is going');
    expect(net.feds[a.url]!.homes.of(alex.id)!.h, ['wss://b.test/hub'], reason: 'and the relay being left believes it');
  });

  test('friends are told a changed record one at a time, not all at once, and each only once', () async {
    final maya = await app('maya', b);
    final others = <RelayApp>[];
    for (final n in ['alex', 'bert', 'cara']) {
      final x = await app(n, a);
      others.add(x);
      await x.buddies.add('maya@b.test');
    }
    await until(() => maya.buddies.requests.length == 3, 'the requests never reached Maya');
    for (final r in maya.buddies.requests.toList()) {
      await maya.buddies.accept(r);
    }
    await until(() => others.every((x) => x.buddies.friends.isNotEmpty && x.friend.homeCount == maya.homes.mine!.n), 'they never became friends');
    expect(maya.buddies.waitingToHear, 0, reason: 'each was told as they became friends');
    await maya.moveTo(net.relay('c.test'));
    await pumpEventQueue();
    final now = maya.homes.mine!.n;
    expect(maya.buddies.waitingToHear, 3);
    expect(others.where((x) => x.friend.homeCount == now), isEmpty, reason: 'nobody is told the moment it changes');
    for (var told = 1; told <= 3; told++) {
      expect(await maya.buddies.tellNext(), isTrue);
      await until(() => others.where((x) => x.friend.homeCount == now).length == told, 'friend $told was not told');
      await pumpEventQueue();
      expect(others.where((x) => x.friend.homeCount == now), hasLength(told), reason: 'one more, and no more than one');
    }
    expect([await maya.buddies.tellNext(), maya.buddies.waitingToHear], [false, 0]);
    expect((jsonDecode(maya.choices['buddies_home_told2:${maya.id}']!) as Map)['sent'], {for (final x in others) x.id: now}, reason: 'what was sent each is kept, so it is not sent again');
    // The app is opened again: its friends, read back, have all heard this record, and nobody is told twice.
    final again = Buddies(maya, spread: const Duration(hours: 1));
    addTearDown(again.dispose);
    await again.start();
    expect([again.friends.length, again.waitingToHear, await again.tellNext()], [3, 0, false]);
  });

  test('an install whose record names another relay than the one it signs in to (a move cut short) makes the next one there', () async {
    final alex = await app('alex', a);
    final first = alex.homes.mine!.n;
    expect(alex.homes.mine!.h, ['wss://a.test/hub']);
    await alex.away();
    // Opened again on relay b, with what it kept: the record still names a.
    final moved = RelayApp(net, 'alex', b, keys: alex.keys, kept: alex.choices);
    apps.add(moved);
    expect(moved.homes.mine!.h, ['wss://a.test/hub'], reason: 'what it kept is read back');
    expect(moved.hub.onSignIn!(), isEmpty, reason: 'a record that names another relay is not said to this one as its own');
    await moved.start();
    final next = moved.homes.mine!.n;
    expect([next, moved.homes.mine!.h, moved.choices['net_home_n']], [greaterThan(first), ['wss://b.test/hub'], '$next']);
    await until(() => net.feds[b.url]!.homes.of(alex.id)?.n == next, 'the relay it is on now was not given it');
    expect(net.feds[b.url]!.homes.isOwn(alex.id), isTrue);
    // The old record was never said to the new relay as though it were this one's.
    expect(net.feds[b.url]!.homes.of(alex.id)!.h, ['wss://b.test/hub']);
  });

  test('another device of the account made a newer record: it is checked and taken, and the next this one makes is newer still', () async {
    final alex = await app('alex', a);
    final n = alex.homes.mine!.n;
    expect(alex.homes.count, n);
    // The account's other device (it holds the same key) gave the relay a record five counts on.
    final theirs = await HomeRecord.make(alex.signer, addresses: ['wss://a.test/hub'], count: n + 5);
    alex.hub.sayHandles({'dir': 'home', 'rec': theirs.toJson()});
    // The relay's word ("n") is not the count: the record is asked back, and taken as it is this account's.
    await until(() => alex.homes.count == n + 5, 'the newer record of its own was not taken up');
    expect([alex.homes.mine!.toJson(), alex.choices['net_home_n']], [theirs.toJson(), '${n + 5}']);
    await alex.moveTo(b);
    final moved = alex.homes.mine!.n;
    expect([moved, alex.homes.mine!.h], [greaterThan(n + 5), ['wss://b.test/hub']]);
    await until(() => net.feds[b.url]!.homes.of(alex.id)?.n == moved, 'the new relay was not given it');
  });

  test('a relay too busy to check a record just now is given it again in a while', () async {
    var clock = DateTime.now();
    net = RelayNet(now: () => clock);
    a = net.relay('a.test', checksASecond: 1);
    final alex = RelayApp(net, 'alex', a, busyAgain: const Duration(milliseconds: 10));
    apps.add(alex);
    // Two friends' records, known before it signs in: with its own that is three to check, and the relay checks one.
    final one = KeysSigner(NetKeys.generate()), two = KeysSigner(NetKeys.generate());
    final recs = [for (final s in [one, two]) (await HomeRecord.make(s, addresses: ['wss://b.test/hub'], count: 1, now: clock)).toJson()];
    final said = <Map<String, dynamic>>[];
    alex.hub.homes.listen(said.add);
    recs.forEach(alex.homes.give);
    await alex.hub.start();
    await until(() => alex.hub.state.value == CarrierState.up && said.any((m) => m['err'] == 'busy'), 'the relay was never too busy');
    expect(net.feds[a.url]!.homes.others, lessThan(2));
    // A second later the relay has room again, and what it turned away is given again by itself.
    clock = clock.add(const Duration(seconds: 2));
    await until(() => net.feds[a.url]!.homes.others == 2, 'the records turned away were never given again');
    expect([for (final s in [one, two]) net.feds[a.url]!.homes.of(s.id)?.n], [1, 1]);
  });

  // The tests below are ones the review of relays that talk found missing (2026-11-23).
  test('a record the relay stays too busy for is left after five tries, and the next is counted afresh, not left at once', () async {
    final clock = DateTime.now();
    net = RelayNet(now: () => clock);
    a = net.relay('a.test', checksASecond: 1);
    final alex = RelayApp(net, 'alex', a, busyAgain: const Duration(milliseconds: 10));
    apps.add(alex);
    final friend = KeysSigner(NetKeys.generate());
    final said = <Map<String, dynamic>>[];
    alex.hub.homes.listen(said.add);
    int busy() => said.where((m) => m['a'] == friend.id && m['err'] == 'busy').length;
    await alex.hub.start();
    await until(() => net.feds[a.url]!.homes.isOwn(alex.id), 'its own record was never taken');
    // The relay's clock stands still, and this second's one check went on alex's own record: a friend's is turned away,
    // given again five times, and left (it is given again at the next sign-in).
    alex.homes.give((await HomeRecord.make(friend, addresses: ['wss://b.test/hub'], count: 1, now: clock)).toJson());
    await until(() => busy() == 6, 'given again ${busy() - 1} times, not five');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(busy(), 6, reason: 'and no more');
    // A newer one of theirs is turned away too: given again five times as well.
    said.clear();
    alex.homes.give((await HomeRecord.make(friend, addresses: ['wss://b.test/hub'], count: 2, now: clock)).toJson());
    await until(() => busy() == 6, 'given again ${busy() - 1} times, not five: the count of tries was never started again');
  });

  test('a move the relay being left is too busy to check: it is given the record again, and takes it, before it is left', () async {
    var clock = DateTime.now();
    net = RelayNet(now: () => clock);
    a = net.relay('a.test');
    b = net.relay('b.test', checksASecond: 1);
    final maya = RelayApp(net, 'maya', b, busyAgain: const Duration(milliseconds: 100), now: () => clock);
    apps.add(maya);
    await maya.start();
    await until(() => net.feds[b.url]!.homes.isOwn(maya.id), 'her relay never took her record');
    final said = <Map<String, dynamic>>[];
    maya.hub.homes.listen(said.add);
    // Her record took this second's one check at b: the move's is turned away at first, and a second on there is room.
    final moving = maya.moveTo(a);
    await until(() => said.any((m) => m['a'] == maya.id && m['err'] == 'busy'), 'the relay she is leaving was never too busy');
    clock = clock.add(const Duration(seconds: 2));
    await moving;
    final now = maya.homes.mine!.n;
    expect(maya.homes.mine!.h, ['wss://a.test/hub']);
    expect(net.feds[b.url]!.homes.of(maya.id)!.n, now, reason: 'the relay she left holds the new record, so it knows she lives elsewhere now');
  });

  test('a phone restored with the account\'s key and nothing else makes a record newer than any the account made, and it is taken', () async {
    var clock = DateTime.now();
    net = RelayNet(now: () => clock);
    a = net.relay('a.test');
    b = net.relay('b.test');
    final alex = RelayApp(net, 'alex', a, now: () => clock);
    apps.add(alex);
    await alex.start();
    await alex.moveTo(b);
    final moved = alex.homes.mine!.n;
    await until(() => net.feds[a.url]!.homes.of(alex.id)?.n == moved, 'the relay he left was never given the move');
    await alex.away();
    // A day on, the phone is restored from a backup that holds the account's key and none of the app's choices (the
    // count used last among them), and it signs in to relay a again.
    clock = clock.add(const Duration(days: 1));
    final restored = RelayApp(net, 'alex', a, keys: alex.keys, now: () => clock);
    apps.add(restored);
    await restored.start();
    final n = restored.homes.mine!.n;
    expect([n, restored.homes.mine!.h], [greaterThan(moved), ['wss://a.test/hub']]);
    await until(() => net.feds[a.url]!.homes.of(alex.id)?.n == n, 'relay a went on believing the record that names b');
    expect(net.feds[a.url]!.homes.isOwn(alex.id), isTrue);
  });

  test('another account signed in on the same phone keeps what it told its friends apart: it doesn\'t take the first one\'s for its own', () async {
    final mo = await app('morgan', a), alex = await app('alex', a);
    await mo.buddies.add('alex');
    await until(() => alex.buddies.requests.isNotEmpty, 'the request never reached Alex');
    await alex.buddies.accept(alex.buddies.requests.single);
    await until(() => mo.buddies.friends.isNotEmpty, 'his yes never reached Morgan');
    expect(mo.buddies.waitingToHear, 0, reason: 'a friend on the relay Morgan is on needs no record of his');
    await mo.hub.stop();
    // Maya uses the phone on relay b: what she has told her friends is of a record that names b.
    final maya = await app('maya', b);
    await maya.away();
    // Morgan signs in on that phone, with what it kept and his friends list.
    final again = RelayApp(net, 'morgan', a, keys: mo.keys, kept: maya.choices)..list = mo.list;
    apps.add(again);
    await again.start();
    await until(() => again.homes.mine != null && again.buddies.friends.isNotEmpty, 'Morgan never came back');
    await pumpEventQueue();
    expect(again.buddies.waitingToHear, 0, reason: 'what Maya told her friends is not his: he has not moved, and Alex is on his relay');
    expect((jsonDecode(again.choices['buddies_home_told2:${maya.id}']!) as Map)['where'], ['wss://b.test/hub'], reason: 'and hers is kept as it was');
  });

  test('a friends list handed over whole (a phone\'s and its computer\'s, put together) says where each lives to the relay', () async {
    final alex = await app('alex', a);
    final maya = KeysSigner(NetKeys.generate());
    final rec = (await HomeRecord.make(maya, addresses: ['wss://b.test/hub'], count: 3)).toJson();
    await alex.buddies.takeAll(jsonEncode([Buddy(username: 'maya@b.test', id: maya.id, key: base64Encode(maya.publicKey), state: 'yes', home: rec).toJson()]));
    expect(alex.buddies.friends.single.home, rec);
    await until(() => net.feds[a.url]!.homes.of(maya.id)?.n == 3, 'the relay was not told where she lives');
  });

  test('a name on one\'s own relay written in full is someone here: added as plain @name', () async {
    final alex = await app('alex', a), anna = await app('anna', a);
    final asked = await alex.buddies.add('@anna@a.test');
    expect([asked.username, asked.id], ['anna', anna.id]);
    await until(() => anna.buddies.requests.isNotEmpty, 'the request never reached Anna');
    expect(anna.buddies.requests.single.username, 'alex');
    expect(net.dialled, isEmpty);
    expect([alex.buddies.elsewhere(asked), alex.buddies.relayOf(asked)], [false, '']);
  });

  test('looking someone up as it is typed: nobody, yourself, someone here; a name on another relay is asked of nobody until Add', () async {
    final alex = await app('alex', a);
    await app('maya', b);
    expect(await alex.buddies.lookup('maya@b.test'), BuddyLookup.elsewhere);
    expect(await alex.buddies.lookup('@Maya@B.test'), BuddyLookup.elsewhere);
    expect(await alex.buddies.lookup('nobody@b.test'), BuddyLookup.elsewhere);
    expect(await alex.buddies.lookup('maya@b.t'), BuddyLookup.elsewhere, reason: 'a host half typed is another server: not asked either');
    expect([net.asked, net.dialled], [isEmpty, isEmpty], reason: 'nothing was asked of any relay as names were typed');
    // A host this app wouldn't dial is nobody's: an address on its own network, another port, a name kept for one.
    for (final host in ['192.168.1.1', '10.0.0.5', 'b.test:22', 'metadata.google.internal', 'printer.local']) {
      expect(await alex.buddies.lookup('maya@$host'), BuddyLookup.nobody, reason: host);
    }
    expect(await alex.buddies.lookup('alex@a.test'), BuddyLookup.you);
    expect(await alex.buddies.lookup('alex'), BuddyLookup.you);
    expect(await alex.buddies.lookup('maya'), BuddyLookup.nobody, reason: 'there is no maya on his own relay');
    expect(await alex.buddies.lookup('maya@not a host'), BuddyLookup.nobody);
    expect(Buddies.goodAddress('maya@b.test'), isTrue);
    expect(Buddies.goodAddress('@maya'), isTrue);
    expect(Buddies.goodAddress('maya@'), isFalse);
    expect(Buddies.goodAddress('ma@b.test'), isFalse);
  });

  test('names asked after at once are each answered with their own: another name, or the same name on another relay', () async {
    final c = net.relay('c.test');
    final alex = await app('alex', a), mayaB = await app('maya', b), mayaC = await app('maya', c);
    final found = await Future.wait([alex.homes.whois('maya', 'b.test'), alex.homes.whois('nobody', 'b.test'), alex.homes.whois('maya', 'c.test'), alex.homes.whois('maya', 'b.test')]);
    expect([for (final f in found) f?.id], [mayaB.id, null, mayaC.id, mayaB.id]);
    expect([found[0]!.home!.h, found[2]!.home!.h], [['wss://b.test/hub'], ['wss://c.test/hub']]);
    expect(net.asked, isEmpty, reason: 'all through his own relay');
  });

  test('nobody has the name there, it is oneself, or their relay can\'t be reached: said in words', () async {
    final alex = await app('alex', a);
    await expectLater(alex.buddies.add('nobody@b.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', 'Nobody has the username @nobody on b.test.')));
    await expectLater(alex.buddies.add('alex@a.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', 'That\'s you.')));
    await expectLater(alex.buddies.add('maya@'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('maya@relay.example'))));
    await expectLater(alex.buddies.add('maya@nowhere.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', 'That relay couldn\'t be reached.')));
    expect(alex.buddies.all, isEmpty);
  });

  test('someone on another relay with no home record can\'t be reached, and the app says so', () async {
    final alex = await app('alex', a);
    // An app from before relays talked: it signs in to b and claims a username, and never says where it lives.
    final old = NetKeys.generate();
    final route = HubCarrier(url: b.url, signer: KeysSigner(old), dial: b.dial);
    addTearDown(route.stop);
    await route.start();
    await until(() => route.state.value == CarrierState.up, 'the old app never signed in');
    final claimed = route.handles.firstWhere((m) => m['dir'] == 'claim');
    route.sayHandles({'dir': 'claim', 'name': 'oldie'});
    await claimed;
    await expectLater(alex.buddies.add('oldie@b.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', '@oldie@b.test can\'t be reached from another relay yet. They need a newer version of Uplink.')));
    expect(alex.buddies.all, isEmpty, reason: 'nobody is kept who can\'t be written to');
  });

  test('someone on a relay that doesn\'t pass messages to other relays is said to be there, not to need a newer version', () async {
    // Found in the review of relays that talk (2026-11-23): asked of that relay itself, the app never read its hello,
    // and said of everyone there that they needed a newer version of the app.
    final quiet = net.relay('quiet.test', mode: FedMode.off), island = net.relay('island.test', mode: FedMode.off);
    final alex = await app('alex', quiet);
    await app('ivy', island);
    await expectLater(alex.buddies.add('ivy@island.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', '@ivy is on island.test, which doesn\'t pass messages to other relays.')));
    expect(net.asked, ['wss://island.test/hub'], reason: 'asked of that relay itself, as alex\'s own doesn\'t talk to others');
  });

  group('where the app\'s own relay doesn\'t talk to others', () {
    test('the app asks the other relay itself, keeps the friend, and says the request can\'t be passed on yet', () async {
      final island = net.relay('island.test', mode: FedMode.off);
      final alex = await app('alex', island), maya = await app('maya', b);
      expect([alex.homes.relayTalks, alex.hub.relay, alex.homes.mine!.h], [false, isNull, ['wss://island.test/hub']], reason: 'with it off, a relay says nothing of itself');
      final asked = await alex.buddies.add('maya@b.test');
      expect(net.asked, ['wss://b.test/hub'], reason: 'the app dialled her relay itself, once');
      expect(net.dialled, isEmpty, reason: 'and his relay dialled nobody');
      expect([asked.username, asked.id, asked.state, asked.homeHost], ['maya@b.test', maya.id, 'asked', 'b.test']);
      expect(HomeRecord.check(asked.home, forId: maya.id), isNotNull, reason: 'her record came from her relay, and is her own');
      // His relay kept the request as it keeps anything for someone away: it went nowhere, and the app knows.
      expect(alex.buddies.unreached(asked), isTrue);
      expect([island.hub.heldFor(maya.id), maya.buddies.requests], [1, isEmpty]);
      // Nobody at b was told he came while he asked, and the short connection is closed.
      await pumpEventQueue();
      expect(b.hub.connected, 1);
    });

    test('its own name written in full asks nobody else: someone on it is looked up on it, and its connection is left alone', () async {
      final island = net.relay('island.test', mode: FedMode.off);
      final alex = await app('alex', island), anna = await app('anna', island);
      final first = island.pairs.first;
      final asked = await alex.buddies.add('anna@island.test');
      expect([asked.username, asked.id], ['anna', anna.id]);
      expect([net.asked, net.dialled], [isEmpty, isEmpty], reason: 'the app did not dial its own relay as though it were another');
      expect([first.isOpen, alex.hub.state.value], [true, CarrierState.up], reason: 'and its own connection was not taken from it');
      expect(await alex.buddies.lookup('anna@island.test'), BuddyLookup.someone);
      expect(net.asked, isEmpty);
    });

    test('and a relay from before, which says nothing of itself: the same, and nothing breaks', () async {
      // One that keeps usernames and says nothing to `home`, and one with no usernames, which answers that there are none.
      for (final (host, handles) in [('old.test', true), ('older.test', false)]) {
        final old = net.relay(host, federation: false, handles: handles);
        final maya = apps.where((x) => x.name == 'maya' && identical(x.relay, b)).firstOrNull ?? await app('maya', b);
        // Someone else has the same username on the old relay: she is not the one asked after.
        final other = await app('maya', old);
        final alex = await app('alex', old);
        expect(other.id, isNot(maya.id));
        expect([alex.hub.relay, alex.homes.relayTalks, alex.claimedName], [isNull, false, handles], reason: host);
        expect(alex.homes.mine!.h, ['wss://$host/hub'], reason: 'its record names the address it dialled');
        // The route is up and carries what it always carried: a packet to someone on the same relay.
        final anna = await app('anna${handles ? '' : 'b'}', old);
        if (handles) {
          await alex.buddies.add(anna.name);
          await until(() => anna.buddies.requests.isNotEmpty, 'a request on the old relay never arrived');
          await anna.buddies.accept(anna.buddies.requests.single);
          await until(() => alex.buddies.friends.isNotEmpty, 'her yes never arrived');
          expect((await alex.write(anna, 'as ever')).acked, isTrue);
          expect(alex.buddies.elsewhere(alex.friend), isFalse);
          // Someone on another relay is found by asking that relay; the request waits.
          final asked = await alex.buddies.add('maya@b.test');
          expect([asked.id, asked.username, alex.buddies.unreached(asked)], [maya.id, 'maya@b.test', true], reason: 'the Maya on b, not the one this relay answers "maya" with');
          expect((await alex.buddies.add('maya')).id, other.id, reason: 'and plain @maya is the one here');
        } else {
          // With no usernames on his own relay he has none to add anyone by; the route itself still carries.
          expect(await alex.hub.send(Peer(id: anna.id), Uint8List.fromList([1, 2, 3])), Handed.passed);
          expect((await alex.homes.whois('maya', 'b.test'))!.id, maya.id, reason: 'and the other relay can still be asked');
        }
        expect(alex.hub.state.value, CarrierState.up);
      }
    });

    test('asking another relay itself signs in there as nobody: not this account\'s key, not its device, and nothing kept for it is taken', () async {
      final island = net.relay('island.test', mode: FedMode.off);
      final alex = await app('alex', island);
      await app('maya', b);
      // Something for Alex is kept at b (sent there before anyone knew where he lives).
      final stranger = HubCarrier(url: b.url, signer: KeysSigner(NetKeys.generate()), dial: b.dial);
      addTearDown(stranger.stop);
      await stranger.start();
      await until(() => stranger.state.value == CarrierState.up, 'never signed in');
      expect(await stranger.send(Peer(id: alex.id), Uint8List.fromList([4, 5, 6])), Handed.held);
      expect((await alex.homes.whois('maya', 'b.test'))!.id, isNotEmpty);
      await pumpEventQueue();
      expect(b.hub.heldFor(alex.id), 1, reason: 'still kept at b: the lookup was not signed in as Alex, so nothing of his was handed over');
      expect(net.asked, ['wss://b.test/hub']);
    });

    test('the other relay refuses this one: that is the answer, and the app asks nobody behind its relay\'s back', () async {
      final closed = net.relay('closed.test', block: {'a.test'});
      final alex = await app('alex', a), zoe = await app('zoe', closed);
      // His relay was refused there: that is the answer, and the app doesn't go around his relay to ask itself.
      await expectLater(alex.buddies.add('zoe@closed.test'), throwsA(isA<MeError>().having((e) => e.message, 'message', 'closed.test doesn\'t take messages from your relay.')));
      expect([net.asked, alex.buddies.all, zoe.buddies.requests], [isEmpty, isEmpty, isEmpty]);
    });
  });

  test('a hub that says it is another relay than the one dialled: the record names what the relay says', () async {
    // The relay at a.test is also reached by an older name; an app that dials the older name is told the newer one.
    final alias = MemoryHub(a.hub, 'wss://old-name.test/hub');
    final alex = RelayApp(net, 'alex', alias);
    apps.add(alex);
    await alex.start();
    expect(alex.homes.mine!.h, ['wss://a.test/hub']);
    expect([alex.homes.here, alex.homes.isHere('a.test'), alex.homes.isHere('old-name.test'), alex.homes.isHere('b.test')], ['wss://a.test/hub', true, true, false]);
  });

  test('a relay hosted from an app names itself and the relay it stays linked to: the record says so', () async {
    final fed = Federation(config: const FedConfig(mode: FedMode.open, via: 'wss://b.test/hub'), dial: net.fedDial);
    final hosted = MemoryHub(Hub(federation: fed), 'ws://192.168.1.20:8787/hub');
    final alex = RelayApp(net, 'alex', hosted);
    apps.add(alex);
    await alex.start();
    expect(alex.homes.mine!.h, ['ghost-relay://${fed.id}?via=wss%3A%2F%2Fb.test%2Fhub']);
    expect(alex.homes.mine!.relayHost, 'b.test');
    expect(alex.homes.livesHere(alex.homes.mine!), isTrue);
  });
}
