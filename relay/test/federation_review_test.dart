import 'dart:async';
import 'dart:convert';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// What the security review of relays that talk found (2026-11-22), each as a test that fails without its fix: a hello
/// passed on word for word, every shared allowance one party could use up for nothing, a relay made a forwarder for
/// strangers, and the rest. Most run at the limits the relay ships with ([TestRelay] `shipped`), where the other tests
/// are generous with what they are not about.
void main() {
  late FakeNet net;
  setUp(() => net = FakeNet());

  group('a hello passed on word for word', () {
    /// Mallory runs a hub at wss://m.test/hub. When relay D dials it she dials [a]'s hub herself and passes every word of
    /// the two hellos across, changing nothing (or adding `stay`, with [addStay]). What [a] says back is in `heardByA`.
    ({List<Object> heardByA, List<Object> heardByD}) mallory(TestRelay a, {bool addStay = false}) {
      final heardByA = <Object>[], heardByD = <Object>[];
      net.hand['wss://m.test/hub'] = (dSide) {
        final (mine, theirs) = MemSocket.pair();
        mine.incoming.listen((data) {
          heardByA.add(data as Object);
          dSide.add(data);
        });
        dSide.incoming.listen((data) {
          var out = data as Object;
          heardByD.add(out);
          if (addStay && out is String) {
            final m = jsonDecode(out) as Map;
            if (m['fed'] == 1) out = jsonEncode({...m, 'stay': true});
          }
          mine.add(out);
        });
        a.hub.attach(theirs);
      };
      return (heardByA: heardByA, heardByD: heardByD);
    }

    test('in the middle of a dial, Mallory gets no link at either end: the dialler signed the address it dialled, and it is not the other relay\'s', () async {
      final a = TestRelay(net, 'a.test', seed: 1), d = TestRelay(net, 'd.test', seed: 2);
      final eve = Install();
      await eve.signIn(d);
      final m = mallory(a);
      // Eve, anyone signed in to D, asks after a name "at m.test": D dials Mallory's hub.
      eve.say({'dir': 'whois', 'name': 'anyone', 'at': 'm.test'});
      await net.settle();
      await net.settle();
      expect([a.fed.linkedWith(d.id), d.fed.linkedWith(a.id)], [false, false]);
      expect(m.heardByA.whereType<String>().map((s) => jsonDecode(s)), anyElement(equals({'ok': false, 'err': 'bad hello'})), reason: 'A refused D\'s hello: signed for wss://m.test/hub, not for its own address');
      expect(net.dialled, ['wss://m.test/hub'], reason: 'A never so much as looked at the address D claims: the signature failed first');
      expect(eve.said.last, {'dir': 'whois', 'name': 'anyone', 'at': 'm.test', 'none': true, 'why': 'refused'});
      // And Alice's people and Bob's are never handed anything through her.
      expect(a.fed.links + d.fed.links, 0);
    });

    test('with a list on both sides, the same: a relay one of them lists can\'t pass on a hello between them', () async {
      final a = TestRelay(net, 'a.test', seed: 1, mode: FedMode.list, allow: {'d.test'});
      final d = TestRelay(net, 'd.test', seed: 2, mode: FedMode.list, allow: {'a.test', 'm.test'});
      mallory(a);
      final eve = Install();
      await eve.signIn(d);
      eve.say({'dir': 'whois', 'name': 'anyone', 'at': 'm.test'});
      await net.settle();
      await net.settle();
      expect(a.fed.linkedWith(d.id), isFalse);
    });

    test('stay is signed: added on the way, the hello is refused; signed, it is a standing link only where this relay lets relays stay', () async {
      final v = TestRelay(net, 'v.test', seed: 1);
      expect(await HandRelay().link(v, stay: true, signedStay: false), {'ok': false, 'err': 'bad hello'});
      expect(v.fed.links, 0);
      // Mallory adding it to a relayed hello: refused for the address, and for the stay.
      final h = TestRelay(net, 'h.test', seed: 3, public: false);
      final eve = Install();
      await eve.signIn(h);
      mallory(v, addStay: true);
      eve.say({'dir': 'whois', 'name': 'anyone', 'at': 'm.test'});
      await net.settle();
      await net.settle();
      expect(v.fed.linkedWith(h.id), isFalse);
    });

    test('a hello signed for another address than this relay\'s own is refused, and a relay with no address takes none', () async {
      final b = TestRelay(net, 'b.test');
      expect(await HandRelay().link(b, signedDialled: 'wss://other.test/hub'), {'ok': false, 'err': 'bad hello'});
      expect(await HandRelay().link(b, signedDialled: 'wss://b.test:443/hub'), {'ok': false, 'err': 'bad hello'}, reason: 'its own address, written as relays write them, and no other way');
      expect((await HandRelay().link(b))['ok'], isTrue);
      // A relay with no address of its own: nobody can have dialled it at one, and no relay's hello is taken.
      final quiet = TestRelay(net, 'q.test', seed: 4, public: false);
      net.hubs[quiet.url] = quiet.hub;
      expect(await HandRelay().link(quiet), {'ok': false, 'err': 'no address'});
      expect(quiet.fed.links, 0);
    });

    test('the dialler takes an answer only where it was signed for the address it dialled', () async {
      final a = TestRelay(net, 'a.test');
      final alice = Install(), them = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      alice.say({'dir': 'home', 'rec': them.record(['wss://x.test/hub'])});
      await pumpEventQueue();
      final real = HandRelay();
      var dialled = 'wss://elsewhere.test/hub';
      net.hand['wss://x.test/hub'] = (s) {
        s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': real.id, 'key': base64Encode(real.key)}}));
        s.incoming.listen((d) {
          final m = d is String ? jsonDecode(d) as Map : null;
          if (m?['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: unhex(m!['c'] as String), dialler: m['id'] as String, answerer: real.id, dialled: dialled), someBytes(32)))}));
        });
      };
      alice.send(them.id, [1]);
      await net.settle();
      expect(a.fed.links, 0, reason: 'an answer made for another address is no use here');
      dialled = 'wss://x.test/hub';
      await net.pass(const Duration(minutes: 11));
      alice.send(them.id, [2]);
      await net.settle();
      expect(a.fed.links, 1, reason: 'made for this one, it is taken');
    });

    test('what is for an address goes only over a link this relay dialled there itself, never over one that came in claiming it', () async {
      final a = TestRelay(net, 'a.test', seed: 1);
      // H holds the key c.test shows (the real relay at c.test is H's own), and links into a claiming c.test.
      final h = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(h.scalar));
      expect((await h.link(a, url: c.url))['ok'], isTrue);
      final alice = Install(), carol = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await carol.signIn(c);
      final carols = await carol.giveHome(c);
      carol.leave();
      alice.say({'dir': 'home', 'rec': carols});
      alice.say({'dir': 'whois', 'name': 'carol', 'at': 'c.test'});
      await pumpEventQueue();
      final n = alice.send(carol.id, [7]);
      await net.settle();
      await net.settle();
      expect(h.frames, isEmpty, reason: 'nothing for c.test\'s people went over the link that came in claiming it');
      expect(h.said.where((m) => m['fed'] == 'whois'), isEmpty, reason: 'nor a name asked of c.test');
      expect(net.dialled.where((u) => u == c.url).length, 2, reason: 'a looked at c.test for H\'s hello, then dialled it for its own link');
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(c.hub.heldFor(carol.id), 1);
    });

    test('a hub that only says this relay\'s own name and key is not taken to be this relay: only its own number coming back says that', () async {
      final a = TestRelay(net, 'a.test', seed: 1);
      final alice = Install(), eve = Install();
      await alice.signIn(a);
      await alice.claim('alice');
      await eve.signIn(a);
      // m.test proves nothing: it repeats what a's own hub says to anyone, with a number of its own.
      net.hand['wss://m.test/hub'] = (s) => s.add(jsonEncode({'hello': 'ab' * 32, 'relay': a.fed.card}));
      eve.say({'dir': 'whois', 'name': 'alice', 'at': 'm.test'});
      await net.settle();
      await net.settle();
      expect(eve.said.last, {'dir': 'whois', 'name': 'alice', 'at': 'm.test', 'none': true, 'why': 'refused'});
      // Its own hub, reached by another name, is: the number it made up came back.
      net.hubs['wss://alias.test/hub'] = a.hub;
      eve.say({'dir': 'whois', 'name': 'alice', 'at': 'alias.test'});
      await net.settle();
      await net.settle();
      expect(eve.said.last, containsPair('id', alice.id));
    });
  });

  group('no shared allowance can be used up by one party for nothing', () {
    test('records: what is not one is refused before anything is counted, and one install has a quarter of any second\'s checks', () async {
      final a = TestRelay(net, 'a.test', shipped: true);
      expect([a.fed.checksASecond, a.fed.checksAnHour], [20, 600]);
      final eve = Install(), alice = Install();
      await eve.signIn(a);
      await alice.signIn(a);
      for (var second = 0; second < 4; second++) {
        for (var i = 0; i < 20; i++) {
          eve.say({'dir': 'home', 'rec': <String, Object>{}});
        }
        // And twenty friends' records that are records: she has five of the second's twenty checks.
        final hers = [for (var i = 0; i < 20; i++) Install().record(['wss://b.test/hub'])];
        eve.said.clear();
        for (final r in hers) {
          eve.say({'dir': 'home', 'rec': r});
        }
        await pumpEventQueue();
        expect(eve.said.where((m) => m['ok'] == true), hasLength(5), reason: 'second $second');
        alice.say({'dir': 'home', 'rec': alice.record([a.url], n: second + 1)});
        await pumpEventQueue();
        expect(alice.said.last, {'dir': 'home', 'a': alice.id, 'ok': true, 'n': second + 1}, reason: 'second $second: Alice\'s own is checked');
        await net.pass(const Duration(seconds: 1));
      }
    });

    test('a packet from someone whose record is not held is refused at once: nothing waits for it, and nobody else is told full', () async {
      final a = TestRelay(net, 'a.test', seed: 1, shipped: true), b = TestRelay(net, 'b.test', seed: 2, shipped: true);
      final alice = Install(), bob = Install(), eve = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await bob.signIn(b);
      final bobs = await bob.giveHome(b);
      alice.say({'dir': 'home', 'rec': bobs});
      await eve.signIn(a);
      eve.say({'dir': 'home', 'rec': bobs}); // a friend's record; her own she never gives
      await pumpEventQueue();
      final sent = [for (var i = 0; i < 2000; i++) eve.send(bob.id, [0])];
      await net.settle();
      expect(sent.map(eve.answerTo).where((m) => m?['err'] == 'home'), hasLength(2000));
      expect([a.fed.waitingFor(b.url), a.fed.waiting, net.dialled], [0, 0, isEmpty]);
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(bob.frames.single, handed(alice.id, [1]));
    });

    test('what waits: a mailbox\'s worth for one recipient, and for one sender, whoever they are', () async {
      final a = TestRelay(net, 'a.test', seed: 1, shipped: true), b = TestRelay(net, 'b.test', seed: 2, shipped: true);
      final alice = Install(), bob = Install(), carol = Install(), eve = Install();
      for (final (who, at) in [(alice, a), (eve, a), (bob, b), (carol, b)]) {
        await who.signIn(at);
        await who.giveHome(at);
      }
      final bobs = b.fed.homes.of(bob.id)!.toJson(), carols = b.fed.homes.of(carol.id)!.toJson();
      for (final who in [alice, eve]) {
        who.say({'dir': 'home', 'rec': bobs});
        who.say({'dir': 'home', 'rec': carols});
      }
      // Linked once, then b goes away: what is for it waits.
      alice.send(bob.id, [0]);
      await net.settle();
      net.down.add(b.url);
      net.cut(b.url);
      await net.settle();
      final toBob = [for (var i = 0; i < 201; i++) eve.send(bob.id, [1])];
      await net.settle();
      expect(eve.answerTo(toBob.last), {'nak': toBob.last, 'err': 'full'}, reason: 'Bob\'s mailbox at b holds 200: no more waits for him');
      expect(a.fed.waitingFor(b.url), Hub.mailboxFrames);
      // Eve has her mailbox\'s worth waiting: nothing more of hers, for anyone.
      final toCarol = eve.send(carol.id, [2]);
      await net.settle();
      expect(eve.answerTo(toCarol), {'nak': toCarol, 'err': 'busy'});
      // Alice still has hers, for Carol.
      final n = alice.send(carol.id, [3]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true, 'waiting': true});
      expect(a.fed.waitingFor(b.url), Hub.mailboxFrames + 1);
    });

    test('relays waited on: one install makes this one dial eight new relays an hour at most, and an address never linked with is given up in a minute', () async {
      final a = TestRelay(net, 'a.test', seed: 1, shipped: true), b = TestRelay(net, 'b.test', seed: 2, shipped: true);
      final alice = Install(), bob = Install(), eve = Install(), maya = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await bob.signIn(b);
      await maya.signIn(b);
      await maya.claim('maya');
      alice.say({'dir': 'home', 'rec': await bob.giveHome(b)});
      await eve.signIn(a);
      await eve.giveHome(a);
      final ghosts = [for (var i = 0; i < 20; i++) Install()];
      final sent = <int>[];
      for (var i = 0; i < 20; i++) {
        eve.say({'dir': 'home', 'rec': ghosts[i].record(['wss://dead$i.test/hub'])});
        // (Four a second: an install has five of each second's record checks.)
        await net.pass(const Duration(milliseconds: 250));
        sent.add(eve.send(ghosts[i].id, [0]));
      }
      await net.settle();
      expect(sent.skip(8).map(eve.answerTo).map((m) => m?['err']).toSet(), {'busy'}, reason: 'past eight new relays this hour');
      expect(net.dialled.where((u) => u.contains('dead')), hasLength(8));
      final n = alice.send(bob.id, [1]);
      alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
      await net.settle();
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(alice.said.lastWhere((m) => m['dir'] == 'whois'), containsPair('id', maya.id));
      // Nothing answers at the eight: given up after four tries, and not dialled again for ten minutes.
      for (var s = 0; s < 40; s++) {
        await net.pass(const Duration(seconds: 1));
      }
      expect(sent.take(8).map(eve.answerTo).map((m) => m?['err']).toSet(), {'far'});
      final dials = net.dialled.length;
      for (var s = 0; s < 9; s++) {
        await net.pass(const Duration(minutes: 1));
      }
      expect(net.dialled.length, dials, reason: 'not seven days of dialling them again');
      expect(a.fed.waiting, 0);
    });

    test('hellos: one that proves nothing is not counted, so words from anyone at all can\'t keep relays out', () async {
      final b = TestRelay(net, 'b.test', shipped: true);
      for (var i = 0; i < 60; i++) {
        final (mine, theirs) = MemSocket.pair();
        mine.incoming.listen((_) {});
        b.hub.attach(theirs);
        await pumpEventQueue();
        mine.add(i.isEven ? '{"fed":1}' : jsonEncode({'fed': 1, 'id': 'ab' * 16, 'key': base64Encode(List.filled(33, 2)), 'sig': base64Encode(List.filled(64, 1)), 'c': 'cd' * 32}));
      }
      await pumpEventQueue();
      expect((await HandRelay().link(b))['ok'], isTrue);
    });

    test('hellos that claim addresses: looks are their own dials, ten a minute, an address that showed nothing is not looked at again for ten minutes, and this relay\'s own dials and known relays are untouched', () async {
      final b = TestRelay(net, 'b.test', seed: 2, shipped: true);
      final answers = [for (var i = 0; i < 30; i++) await HandRelay().link(b, url: 'wss://nobody$i.test/hub')];
      expect(answers.take(10).map((m) => m['err']).toSet(), {'address'});
      expect(answers.skip(10).map((m) => m['err']).toSet(), {'busy'});
      expect(net.dialled, hasLength(10));
      await net.pass(const Duration(minutes: 1));
      expect(await HandRelay().link(b, url: 'wss://nobody0.test/hub'), {'ok': false, 'err': 'address'});
      expect(net.dialled, hasLength(10), reason: 'remembered: not dialled again');
      // b's own dials are its own: someone there writes to someone on c.
      final h = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(h.scalar));
      final bea = Install(), cy = Install();
      await bea.signIn(b);
      await bea.giveHome(b);
      await cy.signIn(c);
      bea.say({'dir': 'home', 'rec': await cy.giveHome(c)});
      await pumpEventQueue();
      final n = bea.send(cy.id, [1]);
      await net.settle();
      expect(bea.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      // Strangers have used their hellos this minute; a relay whose key b has just seen at its address has its own.
      for (var i = 0; i < 30; i++) {
        await HandRelay().link(b);
      }
      expect(await HandRelay().link(b), {'ok': false, 'err': 'busy'});
      expect((await h.link(b, url: c.url))['ok'], isTrue);
    });

    test('bytes: one install has an eighth of a day\'s, so it can\'t use up what its relay may send another', () async {
      final a = TestRelay(net, 'a.test', seed: 1, bytesADay: 300000), b = TestRelay(net, 'b.test', seed: 2, bytesADay: 300000);
      final alice = Install(), bob = Install(), eve = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await eve.signIn(a);
      await eve.giveHome(a);
      await bob.signIn(b);
      final bobs = await bob.giveHome(b);
      alice.say({'dir': 'home', 'rec': bobs});
      eve.say({'dir': 'home', 'rec': bobs});
      await pumpEventQueue();
      final hers = [for (var i = 0; i < 4; i++) eve.send(bob.id, List.filled(10000, 7))];
      await net.settle();
      expect(hers.map(eve.answerTo).map((m) => m?['err']), [null, null, null, 'busy'], reason: '37,500 of 300,000 is hers: three of 10,384 as counted');
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect(bob.frames.last, handed(alice.id, [1]));
    });

    test('record checks: a relay at an address this one has checked has ten times an install\'s; past them its packets are answered busy and go later, not refused', () async {
      final a = TestRelay(net, 'a.test', seed: 1, checksAnHour: 100000), b = TestRelay(net, 'b.test', seed: 2, checksAnHour: 1);
      final bob = Install();
      await bob.signIn(b);
      final bobs = await bob.giveHome(b);
      final senders = [for (var i = 0; i < 11; i++) Install()];
      final sent = <int>[];
      for (final s in senders) {
        await s.signIn(a);
        await s.giveHome(a);
        s.say({'dir': 'home', 'rec': bobs});
        await pumpEventQueue();
        s.said.clear();
        sent.add(s.send(bob.id, [1]));
        await net.settle();
        await net.settle();
      }
      expect([for (var i = 0; i < 10; i++) senders[i].answerTo(sent[i])], everyElement(containsPair('fed', true)), reason: 'ten checks an hour for a: one install\'s would have been one');
      expect(bob.frames, hasLength(10));
      // The eleventh: b is too busy to check her record, says so, and a sends it again in a while.
      await net.pass(Federation.answerWithin);
      expect(senders[10].answerTo(sent[10]), {'ack': sent[10], 'here': false, 'fed': true, 'waiting': true}, reason: 'told it is kept, not refused');
      for (var m = 0; m < 70; m++) {
        await net.pass(const Duration(minutes: 1));
      }
      expect(bob.frames, hasLength(11), reason: 'an hour on, b had a check for it');
    });

    test('what other relays have this one keep is a quarter of the room, whether their relay is linked or not', () async {
      final v = TestRelay(net, 'v.test', seed: 1, queuedBytes: 4000, standingOpen: true);
      final m = HandRelay(), r = HandRelay();
      expect((await m.link(v))['ok'], isTrue);
      expect((await r.link(v, stay: true))['ok'], isTrue);
      final pat = Install(), ghost = Install();
      m.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${m.id}'])});
      m.say({'fed': 'home', 'rec': ghost.record(['ghost-relay://${r.id}?via=${Uri.encodeQueryComponent(v.url)}'])});
      // r is linked and answers nothing. 484 bytes each as counted: two fit in a quarter of 4,000.
      final sent = [for (var i = 0; i < 8; i++) m.send(ghost.id, pat.id, List.filled(100, 1), relay: r.id)];
      await pumpEventQueue();
      expect(sent.map(m.answerTo).map((x) => x?['err']), [null, null, 'full', 'full', 'full', 'full', 'full', 'full']);
      r.socket.drop();
      await net.settle();
      expect(v.fed.waiting, 2 * (100 + Federation.perPacket));
      // Someone signed in to v, writing to a relay that is down: there is room.
      final zoe = Install(), dan = Install();
      await zoe.signIn(v);
      await zoe.giveHome(v);
      zoe.say({'dir': 'home', 'rec': dan.record(['wss://down.test/hub'])});
      await pumpEventQueue();
      final n = zoe.send(dan.id, [1]);
      await pumpEventQueue();
      expect(zoe.answerTo(n)?['err'], isNull);
      expect(v.fed.waitingFor('wss://down.test/hub'), 1);
    });

    test('a linked relay\'s packets are kept only for names that have signed in here: a name it made up gets nothing', () async {
      final b = TestRelay(net, 'b.test', seed: 2, heldBytes: 20000);
      final h = HandRelay();
      await h.link(b);
      final pat = Install();
      h.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${h.id}'])});
      final sent = [for (var i = 0; i < 4; i++) h.send(Install().id, pat.id, List.filled(6600, 1))];
      await pumpEventQueue();
      expect(sent.map(h.answerTo).map((m) => m?['err']).toSet(), {'to'});
      expect(b.hub.holding, 0);
      // For someone who has signed in here, it is kept as ever.
      final carol = Install();
      await carol.signIn(b);
      carol.leave();
      await pumpEventQueue();
      final n = h.send(carol.id, pat.id, List.filled(200, 3));
      await pumpEventQueue();
      expect(h.answerTo(n), {'ack': n});
      expect(b.hub.heldFor(carol.id), 1);
    });

    test('told over its limit, a relay is left alone longer each time and sent one packet to see: not the whole window every fifteen seconds', () async {
      final a = TestRelay(net, 'a.test', seed: 1), b = TestRelay(net, 'b.test', seed: 2, bytesADay: 300000);
      final alice = Install(), bob = Install(), eve = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await bob.signIn(b);
      final bobs = await bob.giveHome(b);
      await eve.signIn(a);
      await eve.giveHome(a);
      eve.say({'dir': 'home', 'rec': bobs});
      await pumpEventQueue();
      for (var i = 0; i < 9; i++) {
        eve.send(bob.id, List.filled(60000, 7));
        await net.settle();
      }
      final crossed = net.made[b.url]!.last.other.heard;
      final before = crossed.whereType<List<int>>().fold<int>(0, (s, f) => s + f.length);
      for (var s = 0; s < 600; s++) {
        await net.pass(const Duration(seconds: 1));
      }
      final after = crossed.whereType<List<int>>().fold<int>(0, (s, f) => s + f.length);
      expect(after - before, lessThan(6 * 60100), reason: 'one packet at 15 s, 45 s, 105 s, 225 s, 465 s: not forty windows');
      expect(Federation.pauseAfter(1), const Duration(seconds: 15));
      expect(Federation.pauseAfter(20), const Duration(hours: 1));
    });
  });

  group('standing links', () {
    test('off unless this relay\'s keeper lets relays stay: a relay with no address that asks to stay is linked, and is no way through to anyone', () async {
      final v = TestRelay(net, 'v.test', seed: 1), d = TestRelay(net, 'd.test', seed: 2);
      final r = TestRelay(net, 'r.test', seed: 3, public: false, via: v.url);
      final xena = Install(), zed = Install(), yuri = Install();
      await xena.signIn(r);
      await zed.signIn(v);
      await yuri.signIn(d);
      final xenas = xena.record(['ghost-relay://${r.id}?n=abc&via=${Uri.encodeQueryComponent(v.url)}']);
      xena.say({'dir': 'home', 'rec': xenas});
      await zed.giveHome(v);
      final yuris = await yuri.giveHome(d);
      await net.settle();
      expect([r.fed.linkedWith(v.id), v.fed.linkedWith(r.id)], [true, true]);
      // Zed on v writes to Xena on r: v won't pass it to a relay that may not stay.
      zed.say({'dir': 'home', 'rec': xenas});
      await net.settle();
      final n = zed.send(xena.id, [1]);
      await net.settle();
      expect(zed.answerTo(n), {'nak': n, 'err': 'far'});
      // Xena writes to Yuri on d: v passes nothing of hers on under its name.
      xena.say({'dir': 'home', 'rec': yuris});
      await net.settle();
      final m = xena.send(yuri.id, [2]);
      await net.settle();
      await net.settle();
      expect(yuri.frames, isEmpty);
      expect(xena.answerTo(m)?['err'], isNotNull);
      expect(net.dialled.where((u) => u == d.url), isEmpty, reason: 'v never dialled d for her');
      expect(xena.frames, isEmpty);
    });

    test('sent again after "moved", a standing relay\'s packet goes no further than its person\'s relay: never a third link', () async {
      final v = TestRelay(net, 'v.test', seed: 1, standingOpen: true), t = TestRelay(net, 't.test', seed: 2), w = TestRelay(net, 'w.test', seed: 4);
      final h = HandRelay();
      expect((await h.link(v, stay: true))['ok'], isTrue);
      final pat = Install(), dave = Install(), tina = Install();
      h.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${h.id}?via=${Uri.encodeQueryComponent(v.url)}'])});
      // v thinks Dave lives on t (record 1); t knows he moved to a relay hosted behind w (record 2).
      final old = dave.record([t.url]);
      final now = dave.record(['ghost-relay://${'ab' * 16}?via=${Uri.encodeQueryComponent(w.url)}']);
      h.say({'fed': 'home', 'rec': old});
      await tina.signIn(t);
      await tina.giveHome(t);
      tina.say({'dir': 'home', 'rec': now});
      await dave.signIn(t);
      dave.leave();
      await pumpEventQueue();
      final n = h.send(dave.id, pat.id, [5]);
      for (var i = 0; i < 6; i++) {
        await net.settle();
      }
      expect(net.dialled, isNot(contains(w.url)), reason: 'h -> v -> (t said moved) -> w would be a third link');
      expect(h.answerTo(n), {'nak': n, 'err': 'refused'});
    });
  });

  group('the rest', () {
    test('a record that has ended is refused, even where the newer one is no longer held: a relay someone left can\'t speak for them again with it', () async {
      final a = TestRelay(net, 'a.test', seed: 1, maxOthers: 1);
      final alice = Install(), dave = Install(), other = Install();
      await alice.signIn(a);
      // Dave lived on left.test 31 days ago (record 1), and moved since (record 2).
      final old = dave.record(['wss://left.test/hub'], n: 1, at: net.clock.subtract(const Duration(days: 31)));
      final now = dave.record(['wss://b.test/hub'], n: 2);
      alice.say({'dir': 'home', 'rec': now});
      await pumpEventQueue();
      // The store of others' lets go of Dave's (as it does at its cap, or when the relay starts again).
      alice.say({'dir': 'home', 'rec': other.record(['wss://b.test/hub'])});
      await pumpEventQueue();
      expect(a.fed.homes.of(dave.id), isNull);
      final eve = Install();
      await eve.signIn(a);
      eve.say({'dir': 'home', 'rec': old});
      await pumpEventQueue();
      expect(eve.said.last, {'dir': 'home', 'a': dave.id, 'ok': false, 'err': 'old'});
      expect(a.fed.homes.of(dave.id), isNull);
    });

    test('stopped, a dial already under way never becomes a link, and nothing more is dialled', () async {
      final a = TestRelay(net, 'a.test', seed: 1), b = TestRelay(net, 'b.test', seed: 2);
      final alice = Install(), bob = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      await bob.signIn(b);
      alice.say({'dir': 'home', 'rec': await bob.giveHome(b)});
      await pumpEventQueue();
      // The dial is under way when the relay stops.
      net.held[b.url] = Completer<void>();
      alice.send(bob.id, [1]);
      await pumpEventQueue();
      expect(net.dialled, [b.url]);
      a.fed.stop();
      net.held.remove(b.url)!.complete();
      await net.settle();
      await net.settle();
      expect([a.fed.links, b.fed.linkedWith(a.id)], [0, false]);
      expect(net.made[b.url]!.single.isOpen, isFalse, reason: 'what was made is let go');
      final dials = net.dialled.length;
      await net.pass(const Duration(minutes: 1));
      expect(net.dialled.length, dials);
    });

    test('pings on a link: answered where small, sixty a minute', () async {
      final b = TestRelay(net, 'b.test', seed: 2);
      final h = HandRelay();
      await h.link(b);
      for (var i = 0; i < 100; i++) {
        h.say({'ping': 'x' * 8000});
      }
      await pumpEventQueue();
      expect(h.said, isEmpty, reason: 'one of 8,000 characters is no ping');
      for (var i = 0; i < 100; i++) {
        h.say({'ping': i});
      }
      await pumpEventQueue();
      expect(h.said, hasLength(60));
      await net.pass(const Duration(minutes: 1));
      h.say({'ping': 'again'});
      await pumpEventQueue();
      expect(h.said.last, {'pong': 'again'});
    });

    test('with a list, a relay listed by its name alone can be sent to: its address is dialled to learn its name', () async {
      final b = TestRelay(net, 'b.test', seed: 2);
      final a = TestRelay(net, 'a.test', seed: 1, mode: FedMode.list, allow: {b.id});
      final alice = Install(), bob = Install();
      await alice.signIn(a);
      final alices = await alice.giveHome(a);
      await bob.signIn(b);
      final bobs = await bob.giveHome(b);
      alice.say({'dir': 'home', 'rec': bobs});
      bob.say({'dir': 'home', 'rec': alices});
      await pumpEventQueue();
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      final m = bob.send(alice.id, [2]);
      await net.settle();
      expect(bob.answerTo(m), {'ack': m, 'here': false, 'fed': true});
      // One not on the list is dialled to learn its name, and left at once.
      final c = TestRelay(net, 'c.test', seed: 3);
      final carol = Install();
      await carol.signIn(c);
      alice.say({'dir': 'home', 'rec': await carol.giveHome(c)});
      await pumpEventQueue();
      final k = alice.send(carol.id, [3]);
      await net.settle();
      expect(alice.answerTo(k), {'nak': k, 'err': 'far'});
      expect(a.fed.linkedWith(c.id), isFalse);
    });
  });
}
