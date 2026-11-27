import 'dart:convert';
import 'dart:typed_data';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// Relays that talk to each other (lib/federation.dart; docs/OPEN_NETWORK.md, section 4): real hubs with real
/// federation, linked through memory (fed_support.dart), under a clock that only a test moves.
void main() {
  late FakeNet net;
  late TestRelay a, b;
  late Install alice, bob;
  setUp(() => net = FakeNet());

  /// Alice on relay a and Bob on relay b, each having given their own relay their record, and Alice's relay told
  /// where Bob lives, as her app tells it of a friend. [makeA] and [makeB] make the relays where a test wants its own.
  Future<void> friends({bool bobHere = true, TestRelay Function()? makeA, TestRelay Function()? makeB, bool aliceGives = true}) async {
    a = makeA?.call() ?? TestRelay(net, 'a.test', seed: 1);
    b = makeB?.call() ?? TestRelay(net, 'b.test', seed: 2);
    alice = Install();
    bob = Install();
    await alice.signIn(a);
    await bob.signIn(b);
    if (aliceGives) await alice.giveHome(a);
    final bobs = await bob.giveHome(b);
    alice.say({'dir': 'home', 'rec': bobs});
    await pumpEventQueue();
    if (!bobHere) {
      bob.leave();
      await pumpEventQueue();
    }
    alice.said.clear();
    bob.said.clear();
  }

  /// What crossed the link a dialled to b: what a said, and what b said back.
  List<Object> aSaid() => net.made[b.url]!.last.other.heard;
  List<Object> bSaid() => net.made[b.url]!.last.heard;

  group('two relays, linked', () {
    test('a packet for someone on the other relay is handed to them there, live, and the sender is told so', () async {
      await friends();
      expect(net.dialled, isEmpty, reason: 'no link until one is needed');
      final n = alice.send(bob.id, [7, 7, 7]);
      await net.settle();
      expect(bob.frames.single, handed(alice.id, [7, 7, 7]), reason: 'stamped with who sent it, as the other relay vouched');
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true}, reason: 'taken: whether Bob is connected is not told across relays');
      expect(net.dialled, [b.url, a.url], reason: 'a dialled b; b dialled the address a claims, to see its key there');
      expect([a.fed.links, b.fed.links], [1, 1]);
      expect(a.hub.heldFor(bob.id), 0, reason: 'nothing of it is kept on the sender\'s relay');
      // What crossed: Alice's record, so b can see a speaks for her, then the packet as a [5].
      expect(aSaid()[1], {'fed': 'home', 'rec': containsPair('a', alice.id)});
      expect(aSaid()[2], [Federation.toRelay, 0, 0, 0, 1, ...unhex(bob.id), ...unhex(alice.id), 7, 7, 7]);
      expect(bSaid().last, {'ack': 1});
      // And back: over a link b dialled itself, never over the one a made (what is for an address goes only over a
      // link this relay dialled there). a's address is believed already: b's own dial is the only one more.
      bob.say({'dir': 'home', 'rec': alice.record([a.url], n: 1)});
      await pumpEventQueue();
      final m = bob.send(alice.id, [8]);
      await net.settle();
      expect(alice.frames.single, handed(bob.id, [8]));
      expect(bob.answerTo(m), {'ack': m, 'here': false, 'fed': true});
      expect(net.dialled, [b.url, a.url, a.url], reason: 'b dialled a for its own link; a had seen b\'s key at b.test a moment ago');
      expect([a.fed.links, b.fed.links], [2, 2]);
    });

    test('for someone away it is kept at their relay, the sender told it is kept, and handed over when they come', () async {
      await friends(bobHere: false);
      final n = alice.send(bob.id, [1, 2, 3]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(b.hub.heldFor(bob.id), 1, reason: 'kept where Bob lives');
      expect([a.hub.heldFor(bob.id), a.fed.waiting], [0, 0], reason: 'and nowhere on the sender\'s relay');
      expect(await bob.signIn(b), {'ok': true, 'held': 1});
      await pumpEventQueue();
      expect(bob.frames.single, handed(alice.id, [1, 2, 3]));
      expect(b.hub.heldFor(bob.id), 0);
    });

    test('with every device of theirs: each one here is handed it', () async {
      await friends();
      final phone = bob.socket, phoneFrames = List.of(bob.frames);
      await bob.signIn(b, device: 'computer');
      expect(phone.isOpen, isTrue);
      alice.send(bob.id, [4]);
      await net.settle();
      expect(bob.frames.sublist(phoneFrames.length), [handed(alice.id, [4]), handed(alice.id, [4])], reason: 'once to each device');
      expect(phone.heard.whereType<List<int>>().last, handed(alice.id, [4]), reason: 'the first device was handed it too');
    });

    test('their mailbox is as full for another relay as for anyone: the same limits, and the sender told there is no room', () async {
      await friends(bobHere: false);
      final sent = [for (var i = 0; i < Hub.mailboxFrames + 1; i++) alice.send(bob.id, [i & 0xff])];
      await net.settle();
      await net.settle();
      expect(b.hub.heldFor(bob.id), Hub.mailboxFrames);
      expect(alice.answerTo(sent[Hub.mailboxFrames - 1]), {'ack': sent[Hub.mailboxFrames - 1], 'here': false, 'fed': true});
      expect(alice.answerTo(sent.last), {'nak': sent.last, 'err': 'full'});
      expect(a.fed.waiting, 0);
    });

    test('a packet too big for the hub is too big for a link', () async {
      await friends();
      final h = HandRelay();
      await h.link(b);
      final pat = Install();
      h.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${h.id}'])});
      final n = h.send(bob.id, pat.id, List.filled(Hub.maxPacket + 33, 1));
      final m = h.send(bob.id, pat.id, List.filled(Hub.maxPacket + 32, 1));
      await pumpEventQueue();
      expect(h.answerTo(n), {'nak': n, 'err': 'big'});
      expect(h.answerTo(m), {'ack': m});
      // A frame far past what any packet can be: the link is closed, and nothing more is read from that relay.
      h.socket.add(Uint8List.fromList([Federation.toRelay, 0, 0, 0, 9, ...unhex(bob.id), ...unhex(pat.id), ...List.filled(Hub.maxPacket + 300, 1)]));
      await pumpEventQueue();
      expect([h.socket.isOpen, b.fed.linkedWith(h.id), h.answerTo(9)], [false, false, isNull]);
      // And words far longer than anything a link says.
      final talker = HandRelay();
      await talker.link(b);
      talker.socket.add(jsonEncode({'fed': 'home', 'rec': 'x' * 70000}));
      await pumpEventQueue();
      expect([talker.socket.isOpen, b.fed.linkedWith(talker.id)], [false, false]);
    });

    test('a link nothing has crossed for ten minutes is closed, and opened again when next needed', () async {
      await friends();
      alice.send(bob.id, [1]);
      await net.settle();
      expect([a.fed.links, b.fed.links], [1, 1]);
      await net.pass(const Duration(minutes: 9, seconds: 59));
      expect([a.fed.links, b.fed.links], [1, 1]);
      await net.pass(const Duration(seconds: 1));
      await net.settle();
      expect([a.fed.links, b.fed.links], [0, 0]);
      final dials = net.dialled.length;
      final n = alice.send(bob.id, [2]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(net.dialled.length, dials + 1, reason: 'dialled again; the address a claims is still believed');
      // Used, it stays: a packet every nine minutes keeps it for half an hour.
      for (var i = 0; i < 3; i++) {
        await net.pass(const Duration(minutes: 9));
        alice.send(bob.id, [3]);
        await net.settle();
      }
      expect([a.fed.links, net.dialled.length], [1, dials + 1]);
    });

    test('what an account sends its own name never leaves its relay', () async {
      await friends();
      // Alice's own record names another relay (a device of hers moved there), and she is here.
      alice.say({'dir': 'home', 'rec': alice.record([b.url])});
      await pumpEventQueue();
      final n = alice.send(alice.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false});
      expect([a.hub.heldFor(alice.id), net.dialled], [1, isEmpty]);
    });
  });

  group('the other relay cannot be reached', () {
    /// a has linked with b once (a packet went), and then b went: what is for b waits as for a relay that is only
    /// away. (One never linked with is another matter: below.)
    Future<void> thenDown() async {
      alice.send(bob.id, [0]);
      await net.settle();
      expect(bob.frames.single, handed(alice.id, [0]));
      net.down.add(b.url);
      net.cut(b.url);
      await net.settle();
      alice.said.clear();
      bob.frames.clear();
      net.dialled.clear();
    }

    test('a packet waits here, its sender is told it is kept, and it goes on when the relay is back', () async {
      await friends();
      await thenDown();
      final n = alice.send(bob.id, [5]);
      await pumpEventQueue();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true, 'waiting': true}, reason: 'kept here, waiting for their relay: said so');
      expect([a.fed.waitingFor(b.url), a.hub.heldFor(bob.id)], [1, 0], reason: 'kept for that relay, not in a mailbox here');
      // Tried again later, later each time: after 5 seconds, then 10, then 20.
      expect(net.dialled, [b.url]);
      await net.pass(const Duration(seconds: 4));
      expect(net.dialled, hasLength(1));
      await net.pass(const Duration(seconds: 1));
      expect(net.dialled, hasLength(2));
      await net.pass(const Duration(seconds: 9));
      expect(net.dialled, hasLength(2));
      await net.pass(const Duration(seconds: 1));
      expect(net.dialled, hasLength(3));
      net.down.remove(b.url);
      await net.pass(const Duration(seconds: 19));
      expect(bob.frames, isEmpty);
      await net.pass(const Duration(seconds: 1));
      await net.settle();
      expect(bob.frames.single, handed(alice.id, [5]));
      expect([a.fed.waiting, a.fed.waitingFor(b.url)], [0, 0]);
      expect(alice.said, hasLength(1), reason: 'told once, when it was kept');
    });

    test('an address never once linked with is tried a minute or two and then given up: nothing said to be kept, then told it can\'t be reached', () async {
      await friends();
      net.down.add(b.url);
      final n = alice.send(bob.id, [5]);
      await pumpEventQueue();
      expect(alice.answerTo(n), isNull, reason: 'not said to be kept: it may never go');
      expect(a.fed.waitingFor(b.url), 1);
      // Tried at once, then after 5, 15 and 35 seconds: the fourth time it is given up on.
      await net.pass(const Duration(seconds: 5));
      await net.pass(const Duration(seconds: 10));
      expect(alice.answerTo(n), isNull);
      await net.pass(const Duration(seconds: 20));
      expect(net.dialled, hasLength(4));
      expect(alice.answerTo(n), {'nak': n, 'err': 'far'});
      expect([a.fed.waiting, a.fed.waitingFor(b.url)], [0, 0], reason: 'not kept for seven days');
      // And not dialled again for ten minutes: what is sent meanwhile is told so at once.
      final m = alice.send(bob.id, [6]);
      await net.pass(const Duration(minutes: 9));
      expect(alice.answerTo(m), {'nak': m, 'err': 'far'});
      expect(net.dialled, hasLength(4));
      await net.pass(const Duration(minutes: 1, seconds: 1));
      net.down.remove(b.url);
      final k = alice.send(bob.id, [7]);
      await net.settle();
      expect(alice.answerTo(k), {'ack': k, 'here': false, 'fed': true});
      expect(bob.frames.single, handed(alice.id, [7]));
    });

    test('backoff: five seconds, twice as long each time, ten minutes at most', () {
      expect([for (var f = 1; f <= 9; f++) Federation.backoff(f).inSeconds], [5, 10, 20, 40, 80, 160, 320, 600, 600]);
      expect(Federation.backoff(60).inSeconds, 600);
    });

    test('a link that drops while a packet is on it: the packet waits and goes by the next link', () async {
      await friends();
      // The first link a makes is to a hub played by hand, which takes the packet and drops the link unanswered.
      final played = HandRelay();
      final got = <List<int>>[];
      net.hand[b.url] = (s) {
        s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': played.id, 'key': base64Encode(played.key)}}));
        s.incoming.listen((d) {
          if (d is List<int>) {
            got.add(d);
            s.drop();
            return;
          }
          final m = jsonDecode(d as String) as Map;
          if (m['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': played.id, 'key': base64Encode(played.key), 'sig': base64Encode(P256.sign(played.scalar, Federation.answerBytes(c: unhex(m['c'] as String), dialler: m['id'] as String, answerer: played.id, dialled: b.url), someBytes(32)))}));
        });
      };
      final n = alice.send(bob.id, [2]);
      await pumpEventQueue();
      expect([got, bob.frames, a.fed.waitingFor(b.url)], [hasLength(1), isEmpty, 1], reason: 'sent, unanswered, and still waiting here');
      // The real relay answers at that address from now on.
      net.hand.remove(b.url);
      await net.settle();
      await net.settle();
      expect(bob.frames.single, handed(alice.id, [2]));
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(a.fed.waiting, 0);
    });

    test('what waits for one relay is at most so many packets', () async {
      await friends(makeA: () => TestRelay(net, 'a.test', queuePackets: 3));
      await thenDown();
      final sent = [for (var i = 0; i < 4; i++) alice.send(bob.id, [i])];
      await pumpEventQueue();
      expect([for (final n in sent.take(3)) alice.answerTo(n)], everyElement(containsPair('here', false)));
      expect(alice.answerTo(sent.last), {'nak': sent.last, 'err': 'full'});
      expect(a.fed.waitingFor(b.url), 3);
      net.down.remove(b.url);
      await net.pass(const Duration(seconds: 5));
      await net.settle();
      expect(bob.frames, [for (var i = 0; i < 3; i++) handed(alice.id, [i])], reason: 'in the order they were sent');
    });

    test('and at most so many bytes, each packet counted with what holding one costs besides its bytes', () async {
      await friends(makeA: () => TestRelay(net, 'a.test', queueBytes: 500));
      await thenDown();
      // 100 bytes and 384 more each: one fits in 500, two do not.
      expect(Federation.perPacket, 384);
      final first = alice.send(bob.id, List.filled(100, 1)), second = alice.send(bob.id, List.filled(100, 2));
      await pumpEventQueue();
      expect(alice.answerTo(first), containsPair('here', false));
      expect(alice.answerTo(second), {'nak': second, 'err': 'full'});
    });

    test('and for every relay together at most so many bytes', () async {
      await friends(makeA: () => TestRelay(net, 'a.test', queuedBytes: 1000));
      final c = TestRelay(net, 'c.test', seed: 3);
      final carol = Install();
      alice.say({'dir': 'home', 'rec': carol.record([c.url])});
      await pumpEventQueue();
      await thenDown();
      net.down.add(c.url);
      final sent = [alice.send(bob.id, List.filled(100, 1)), alice.send(bob.id, List.filled(100, 2)), alice.send(carol.id, List.filled(100, 3))];
      await pumpEventQueue();
      expect([for (final n in sent) alice.answerTo(n)?['err']], [null, null, 'full']);
      expect(a.fed.waiting, 2 * (100 + Federation.perPacket));
    });

    test('what waits never stops what can go now: with the room for waiting used up, a packet for a relay that is linked still goes', () async {
      await friends(makeA: () => TestRelay(net, 'a.test', queuedBytes: 1000));
      final c = TestRelay(net, 'c.test', seed: 3);
      final carol = Install();
      await carol.signIn(c);
      alice.say({'dir': 'home', 'rec': await carol.giveHome(c)});
      await pumpEventQueue();
      alice.send(carol.id, [0]);
      await net.settle();
      expect(a.fed.linkedWith(c.id), isTrue);
      await thenDown();
      final waits = [alice.send(bob.id, List.filled(100, 1)), alice.send(bob.id, List.filled(100, 2)), alice.send(bob.id, List.filled(100, 3))];
      await pumpEventQueue();
      expect([for (final n in waits) alice.answerTo(n)?['err']], [null, null, 'full']);
      final live = alice.send(carol.id, List.filled(100, 4));
      await net.settle();
      expect(alice.answerTo(live), {'ack': live, 'here': false, 'fed': true});
      expect(carol.frames.last, handed(alice.id, List.filled(100, 4)));
    });

    test('and for no more relays than its most', () async {
      await friends(makeA: () => TestRelay(net, 'a.test', maxPeers: 2));
      final others = [for (var i = 0; i < 2; i++) Install()];
      for (var i = 0; i < 2; i++) {
        alice.say({'dir': 'home', 'rec': others[i].record(['wss://down$i.test/hub'])});
      }
      await pumpEventQueue();
      net.down.add(b.url);
      final sent = [alice.send(bob.id, [1]), alice.send(others[0].id, [2]), alice.send(others[1].id, [3])];
      await pumpEventQueue();
      expect([for (final n in sent) alice.answerTo(n)?['err']], [null, null, 'full']);
    });

    test('after seven days what still waits is let go', () async {
      await friends();
      await thenDown();
      alice.send(bob.id, [5]);
      await pumpEventQueue();
      await net.pass(const Duration(days: 6, hours: 23));
      expect(a.fed.waitingFor(b.url), 1);
      await net.pass(const Duration(hours: 1));
      expect([a.fed.waitingFor(b.url), a.fed.waiting], [0, 0]);
      net.down.remove(b.url);
      await net.pass(const Duration(minutes: 10));
      await net.settle();
      expect(bob.frames, isEmpty);
    });

    test('a relay that takes a packet and never answers: the sender is told it is kept, the link is made again, and it goes', () async {
      await friends();
      // b's hub is played by hand from here on: it links, and swallows what it is sent.
      net.hubs.remove(b.url);
      final real = HandRelay();
      var swallow = true;
      final got = <List<int>>[];
      net.hand[b.url] = (s) {
        s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': real.id, 'key': base64Encode(real.key)}}));
        s.incoming.listen((d) {
          if (d is List<int>) {
            got.add(d);
            if (!swallow) s.add(jsonEncode({'ack': ByteData.sublistView(Uint8List.fromList(d.sublist(1, 5))).getUint32(0), 'here': true}));
            return;
          }
          final m = jsonDecode(d as String) as Map;
          if (m['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: unhex(m['c'] as String), dialler: m['id'] as String, answerer: real.id, dialled: b.url), someBytes(32)))}));
        });
      };
      final n = alice.send(bob.id, [5]);
      await net.settle();
      expect([got, alice.answerTo(n)], [hasLength(1), isNull], reason: 'sent, and not yet answered');
      await net.pass(Federation.answerWithin);
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true, 'waiting': true}, reason: 'told it is kept, in good time for the app');
      expect(a.fed.waiting, greaterThan(0));
      final first = net.made[b.url]!.last;
      swallow = false;
      await net.pass(Federation.stuckAfter - Federation.answerWithin - const Duration(seconds: 1));
      expect(first.isOpen, isTrue);
      await net.pass(const Duration(seconds: 1));
      await net.settle();
      expect(first.isOpen, isFalse, reason: 'the link that never answered is closed');
      expect([got, a.fed.waiting, a.fed.links], [hasLength(2), 0, 1], reason: 'sent again by a new link, and answered');
      expect(alice.said, hasLength(1));
    });
  });

  group('a relay speaks only for its own people', () {
    test('a relay that puts someone else\'s name on a packet is refused, with or without her record', () async {
      await friends();
      final mallory = HandRelay();
      expect((await mallory.link(b))['ok'], isTrue);
      var n = mallory.send(bob.id, alice.id, [6, 6, 6]);
      await pumpEventQueue();
      expect(mallory.answerTo(n), {'nak': n, 'err': 'home'}, reason: 'no record of Alice\'s is held that names this relay');
      // Alice's real record, which names a.test: given, and still not this relay's to speak for.
      mallory.say({'fed': 'home', 'rec': alice.record([a.url], n: 1)});
      n = mallory.send(bob.id, alice.id, [6, 6, 6]);
      await pumpEventQueue();
      expect(mallory.answerTo(n), {'nak': n, 'err': 'home'});
      // A record that does name it, signed by someone else in her name.
      mallory.say({'fed': 'home', 'rec': homeRecord(alice.scalar, ['ghost-relay://${mallory.id}'], n: 9, signWith: someBytes(32))});
      n = mallory.send(bob.id, alice.id, [6, 6, 6]);
      await pumpEventQueue();
      expect(mallory.answerTo(n), {'nak': n, 'err': 'home'});
      expect([bob.frames, b.hub.heldFor(bob.id)], [isEmpty, 0]);
      // For someone whose own record names it, it does speak.
      final pat = Install();
      mallory.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${mallory.id}'])});
      n = mallory.send(bob.id, pat.id, [1]);
      await pumpEventQueue();
      expect(mallory.answerTo(n), {'ack': n});
      expect(bob.frames.single, handed(pat.id, [1]));
    });

    test('nor by claiming the address her relay is at: the key seen there is not its own', () async {
      await friends();
      final mallory = HandRelay();
      expect(await mallory.link(b, url: a.url), {'ok': false, 'err': 'address'});
    });

    test('a relay at an address speaks for those whose record names that address, and for nobody on another', () async {
      await friends();
      final m = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(m.scalar));
      expect((await m.link(b, url: c.url))['ok'], isTrue);
      final carol = Install();
      m.say({'fed': 'home', 'rec': carol.record([c.url])});
      m.say({'fed': 'home', 'rec': alice.record([a.url], n: 1)});
      final mine = m.send(bob.id, carol.id, [1]), hers = m.send(bob.id, alice.id, [2]);
      await pumpEventQueue();
      expect(m.answerTo(mine), {'ack': mine});
      expect(m.answerTo(hers), {'nak': hers, 'err': 'home'});
      expect(bob.frames.single, handed(carol.id, [1]));
    });

    test('refused for want of a record, the sending relay gives it and tries once more', () async {
      await friends(makeB: () => TestRelay(net, 'b.test', seed: 2, maxOthers: 1));
      final carla = Install();
      await carla.signIn(a);
      await carla.giveHome(a);
      carla.say({'dir': 'home', 'rec': bob.record([b.url], n: 1)});
      await pumpEventQueue();
      alice.send(bob.id, [1]);
      await net.settle();
      carla.send(bob.id, [2]);
      await net.settle();
      // b holds one other's record at most, and it is Carla's now. Alice's next packet is refused for want of hers.
      final before = bSaid().length;
      final n = alice.send(bob.id, [3]);
      await net.settle();
      expect(bSaid().sublist(before), [{'nak': 3, 'err': 'home'}, {'ack': 4}]);
      expect(aSaid().whereType<Map>().where((m) => m['fed'] == 'home' && (m['rec'] as Map)['a'] == alice.id), hasLength(2), reason: 'her record, said a second time');
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(bob.frames.last, handed(alice.id, [3]));
    });

    test('from someone whose record this relay doesn\'t hold, a packet is refused at once (home), and nothing is dialled for it', () async {
      await friends(aliceGives: false);
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'nak': n, 'err': 'home'}, reason: 'no relay would take it from this one: said now, not after it waited for nothing');
      expect([net.dialled, a.fed.waiting, bob.frames], [isEmpty, 0, isEmpty]);
      // Her app gives it (as it does at every sign-in) and sends again: it goes.
      await alice.giveHome(a);
      alice.said.clear();
      final m = alice.send(bob.id, [2]);
      await net.settle();
      expect(alice.answerTo(m), {'ack': m, 'here': false, 'fed': true});
      expect(bob.frames.single, handed(alice.id, [2]));
    });

    test('a record that names another relay does not make this one hers: refused at once, and nothing crosses', () async {
      await friends(aliceGives: false);
      // Alice's record, as her relay holds it, names c.test: she moved, and a device of hers is still signed in here.
      alice.say({'dir': 'home', 'rec': alice.record(['wss://c.test/hub'])});
      await pumpEventQueue();
      alice.said.clear();
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'nak': n, 'err': 'home'});
      expect([net.dialled, bob.frames, a.fed.waiting], [isEmpty, isEmpty, 0]);
    });
  });

  group('where nothing says someone lives elsewhere', () {
    test('a packet for someone with no record is kept here, as it always was, and nothing is dialled', () async {
      await friends();
      final zed = Install();
      final n = alice.send(zed.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false}, reason: 'the answer a hub always gave: nothing says it crossed');
      expect([a.hub.heldFor(zed.id), net.dialled, a.fed.waiting], [1, isEmpty, 0]);
    });

    test('a record that names this relay: here, as before', () async {
      await friends();
      final carla = Install();
      alice.say({'dir': 'home', 'rec': carla.record([a.url])});
      await pumpEventQueue();
      final n = alice.send(carla.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false});
      expect([a.hub.heldFor(carla.id), net.dialled], [1, isEmpty]);
    });

    test('someone connected here is handed it here, whatever their record says', () async {
      await friends();
      final carla = Install();
      await carla.signIn(a);
      alice.say({'dir': 'home', 'rec': carla.record([b.url])});
      await pumpEventQueue();
      final n = alice.send(carla.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': true});
      expect([carla.frames.single, net.dialled], [handed(alice.id, [1]), isEmpty]);
    });

    test('a record whose addresses this relay can\'t pass to: the sender is told, and nothing is kept as though they were here', () async {
      await friends();
      final odd = Install();
      for (final addresses in [
        ['ghost-relay://${'ab' * 16}?n=xyz'], // hosted, with no relay it stays linked to
        ['gopher://b.test/hub'], // not an address at all
        ['ws://b.test/hub'], // plain, which is not dialled
        ['wss://b.test:8443/hub'], // a port that is not dialled
        ['wss://b.test/elsewhere'], // not a hub's address
      ]) {
        alice.say({'dir': 'home', 'rec': odd.record(addresses)});
        await pumpEventQueue();
        final n = alice.send(odd.id, [1]);
        await net.settle();
        expect(alice.answerTo(n), {'nak': n, 'err': 'far'}, reason: '$addresses');
      }
      expect([net.dialled, a.hub.heldFor(odd.id), a.fed.waiting], [isEmpty, 0, 0]);
      // The first address it can pass to is the one used (and b keeps it for them: they have signed in there).
      await odd.signIn(b);
      odd.leave();
      alice.say({'dir': 'home', 'rec': odd.record(['gopher://x.test/hub', b.url])});
      await pumpEventQueue();
      final n = alice.send(odd.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(b.hub.heldFor(odd.id), 1);
    });
  });

  group('one hop', () {
    test('what another relay passed here is never passed to a third: that relay is told where they live, and nothing is dialled', () async {
      await friends();
      final c = TestRelay(net, 'c.test', seed: 3);
      final dave = Install();
      bob.say({'dir': 'home', 'rec': dave.record([c.url])});
      await pumpEventQueue();
      final h = HandRelay();
      await h.link(b);
      final pat = Install();
      h.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${h.id}'])});
      final n = h.send(dave.id, pat.id, [1]);
      await net.settle();
      expect(h.said, [{'fed': 'home', 'rec': containsPair('a', dave.id)}, {'nak': n, 'err': 'moved'}]);
      expect([net.dialled, b.fed.linkedWith(c.id), b.hub.heldFor(dave.id), c.hub.heldFor(dave.id)], [isEmpty, false, 0, 0]);
    });

    test('someone who moved: the relay they left says where they live now, and the sender\'s relay takes it there itself', () async {
      await friends();
      final c = TestRelay(net, 'c.test', seed: 3);
      final dave = Install();
      // Dave lived on b (record 1), and moved to c (record 2). Alice's relay only knows the first.
      final old = dave.record([b.url]), now = dave.record([c.url]);
      alice.say({'dir': 'home', 'rec': old});
      await dave.signIn(b);
      dave.say({'dir': 'home', 'rec': now});
      await pumpEventQueue();
      dave.leave();
      await dave.signIn(c);
      dave.say({'dir': 'home', 'rec': now});
      await pumpEventQueue();
      final n = alice.send(dave.id, [4]);
      await net.settle();
      await net.settle();
      expect(dave.frames.single, handed(alice.id, [4]));
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(bSaid().whereType<Map>().toList().sublist(2), [{'fed': 'home', 'rec': containsPair('n', 2)}, {'nak': 1, 'err': 'moved'}]);
      expect([b.fed.linkedWith(c.id), c.fed.linkedWith(b.id), a.fed.linkedWith(c.id)], [false, false, true], reason: 'b never linked with c: a went there itself');
      expect(a.fed.homes.of(dave.id)!.n, 2, reason: 'and a holds the newer record from now on');
      // The next goes straight to c.
      final before = aSaid().length;
      alice.send(dave.id, [5]);
      await net.settle();
      expect(aSaid().length, before);
      expect(dave.frames.last, handed(alice.id, [5]));
    });

    test('the relay they left holds an older record than the sender\'s: it is given the newer, and takes the packet', () async {
      await friends();
      final dave = Install();
      // b thinks Dave lives on c (record 1); he has since come to b (record 2), which only Alice's relay has heard.
      bob.say({'dir': 'home', 'rec': dave.record(['wss://c.test/hub'])});
      alice.say({'dir': 'home', 'rec': dave.record([b.url])});
      await dave.signIn(b);
      dave.leave();
      await pumpEventQueue();
      final n = alice.send(dave.id, [4]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect([b.hub.heldFor(dave.id), b.fed.homes.of(dave.id)!.n], [1, 2]);
      expect(net.dialled, isNot(contains('wss://c.test/hub')));
    });
  });
}
