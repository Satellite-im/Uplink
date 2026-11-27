import 'dart:convert';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// The hello between two relays (lib/federation.dart; docs/OPEN_NETWORK.md, section 4): both prove their keys, and
/// every way a link is refused. One side is a real relay; the other is played by hand, so it can say what a relay
/// that keeps the rules never would.
void main() {
  late FakeNet net;
  setUp(() => net = FakeNet());

  group('a relay dials this one', () {
    test('both prove their keys: its hello over this hub\'s number and both names, the answer over its number and both names', () async {
      final b = TestRelay(net, 'b.test');
      final h = HandRelay();
      final answer = await h.link(b);
      expect(answer, {'ok': true, 'fed': 1, 'id': b.id, 'key': base64Encode(b.fed.key), 'sig': isA<String>()});
      expect(h.answerProven, isTrue, reason: 'signed by the key the hub\'s hello named, over this relay\'s number and both names');
      expect(h.hello['relay'], {'id': b.id, 'key': base64Encode(b.fed.key), 'url': b.url, 'fed': true});
      expect(b.fed.linkedWith(h.id), isTrue);
      expect(net.dialled, isEmpty, reason: 'it claimed no address, so none was dialled');
      // What crosses it is answered: a ping, as a link kept open says.
      h.say({'ping': 4});
      await pumpEventQueue();
      expect(h.said.last, {'pong': 4});
    });

    test('a hello not signed by the key it names is refused', () async {
      final b = TestRelay(net, 'b.test');
      final h = HandRelay();
      expect(await h.link(b, signWith: someBytes(32)), {'ok': false, 'err': 'bad hello'});
      expect([h.socket.isOpen, b.fed.links], [false, 0]);
      // A name that is not the key's.
      expect(await HandRelay().link(b, sayId: 'ab' * 16), {'ok': false, 'err': 'bad hello'});
      // Signed for another relay's name: a hello made for one relay is no use at another.
      expect(await HandRelay().link(b, signedFor: 'cd' * 16), {'ok': false, 'err': 'bad hello'});
      // Signed over another number: one heard before can't be said again.
      expect(await HandRelay().link(b, signedNonce: someBytes(32)), {'ok': false, 'err': 'bad hello'});
      // Signed over another address than the one it claims.
      final c = TestRelay(net, 'c.test', seed: 3);
      expect(await HandRelay().link(b, url: c.url, signedUrl: 'wss://other.test/hub'), {'ok': false, 'err': 'bad hello'});
      expect(b.fed.links, 0);
      expect(net.dialled, isEmpty, reason: 'nothing is dialled for a hello that proves nothing');
    });

    test('what one relay signs as its answer is no use as a hello: the two are signed over different words', () async {
      final b = TestRelay(net, 'b.test'), x = TestRelay(net, 'x.test', seed: 4);
      // Mallory opens a hub connection to x to learn the number x wants signed, then dials b with that number as her
      // own, so that b signs it in its answer; then says b's answer to x as though it were b's hello.
      final atX = HandRelay(scalar: someBytes(32));
      final mallory = HandRelay();
      final (mine, theirs) = MemSocket.pair();
      final hellos = <Map>[];
      mine.incoming.listen((d) => hellos.add(jsonDecode(d as String) as Map));
      x.hub.attach(theirs);
      await pumpEventQueue();
      final wanted = unhex(hellos.single['hello'] as String);
      // b's answer to Mallory, over a number of her choosing: x's.
      final (m2, t2) = MemSocket.pair();
      final heard = <Map>[];
      m2.incoming.listen((d) => heard.add(jsonDecode(d as String) as Map));
      b.hub.attach(t2);
      await pumpEventQueue();
      final sig = P256.sign(mallory.scalar, Federation.dialBytes(nonce: unhex(heard.single['hello'] as String), dialler: mallory.id, answerer: b.id, c: wanted, dialled: b.url, url: ''), someBytes(32));
      m2.add(jsonEncode({'fed': 1, 'id': mallory.id, 'key': base64Encode(mallory.key), 'sig': base64Encode(sig), 'c': [for (final v in wanted) v.toRadixString(16).padLeft(2, '0')].join()}));
      await pumpEventQueue();
      expect(heard.last['ok'], isTrue);
      // Said to x as b's own hello: refused.
      mine.add(jsonEncode({'fed': 1, 'id': b.id, 'key': base64Encode(b.fed.key), 'sig': heard.last['sig'], 'c': 'ee' * 32}));
      await pumpEventQueue();
      expect(hellos.last, {'ok': false, 'err': 'bad hello'});
      expect(x.fed.linkedWith(b.id), isFalse);
      expect(atX.id, isNot(b.id));
    });

    test('federation off: a relay\'s hello is answered as a hub from before answers one it can\'t read, and its own hello names no relay', () async {
      final b = TestRelay(net, 'b.test', mode: FedMode.off);
      final h = HandRelay();
      expect(await h.link(b), {'ok': false, 'err': 'bad hello'});
      expect([h.socket.isOpen, h.socket.other.code, h.socket.other.reason, b.fed.links], [false, 4400, 'bad hello', 0]);
      expect(h.hello, {'hello': isA<String>(), 'peek': true, 'react': true}, reason: 'off, it has no key, and its hello is the one it always said');
    });

    test('a hub with no federation at all answers a relay\'s hello as it always answered one it could not read', () async {
      final b = TestRelay(net, 'b.test', fed: false);
      final h = HandRelay();
      expect(await h.link(b), {'ok': false, 'err': 'bad hello'});
      expect([h.socket.isOpen, h.socket.other.code, h.socket.other.reason], [false, 4400, 'bad hello']);
      expect(h.hello, {'hello': isA<String>(), 'peek': true, 'react': true}, reason: 'and its hello is the one it always said');
    });

    test('blocked, by its name or by the host it claims', () async {
      final h = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(h.scalar));
      expect(c.id, h.id, reason: 'the relay at c.test has the key the hand plays');
      final byName = TestRelay(net, 'b.test', block: {h.id});
      expect(await h.link(byName), {'ok': false, 'err': 'blocked'});
      final byHost = TestRelay(net, 'd.test', seed: 5, block: {'c.test'});
      expect(await h.link(byHost, url: c.url), {'ok': false, 'err': 'blocked'});
      expect(net.dialled, isEmpty, reason: 'a blocked host is not so much as dialled');
      // The same relay with no address claimed is not that host: it links, and speaks for nobody at c.test.
      expect((await h.link(byHost))['ok'], isTrue);
    });

    test('with a list, only the relays on it: by name, or by a host this relay has seen their key at', () async {
      final h = HandRelay(), other = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(h.scalar));
      final byName = TestRelay(net, 'b.test', mode: FedMode.list, allow: {h.id});
      expect((await h.link(byName))['ok'], isTrue);
      expect(await other.link(byName), {'ok': false, 'err': 'not listed'});
      final byHost = TestRelay(net, 'd.test', seed: 5, mode: FedMode.list, allow: {'c.test'});
      expect((await h.link(byHost, url: c.url))['ok'], isTrue);
      expect(net.dialled, [c.url], reason: 'the address was dialled, and showed the same key');
      expect(await h.link(byHost), {'ok': false, 'err': 'not listed'}, reason: 'without the address it is nobody on the list');
      // Someone else claiming the listed host shows another key there.
      expect(await other.link(byHost, url: c.url), {'ok': false, 'err': 'address'});
      // With the list empty, nobody.
      final nobody = TestRelay(net, 'e.test', seed: 6, mode: FedMode.list);
      expect(await h.link(nobody), {'ok': false, 'err': 'not listed'});
    });

    test('an address it claims is believed only where this relay dials it and sees the same key', () async {
      final b = TestRelay(net, 'b.test');
      final h = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3);
      // c.test is a real relay, with another key.
      expect(await h.link(b, url: c.url), {'ok': false, 'err': 'address'});
      expect(net.dialled, [c.url]);
      expect(b.fed.links, 0);
      // An address where nothing answers.
      expect(await HandRelay().link(b, url: 'wss://nowhere.test/hub'), {'ok': false, 'err': 'address'});
      // An address where something answers that is not a relay's hub.
      net.hand['wss://web.test/hub'] = (s) => s.add('<html>');
      expect(await HandRelay().link(b, url: 'wss://web.test/hub'), {'ok': false, 'err': 'address'});
      // What is not a hub's address as relays write them is not dialled at all.
      final before = net.dialled.length;
      for (final bad in ['https://c.test/hub', 'wss://c.test/hub/', 'wss://C.test/hub', 'wss://c.test:443/hub', 'wss://c.test/hub?x=1', 'ws://c.test/hub', 'wss://c.test:8443/hub', 'wss://c.test/elsewhere', 'wss://user@c.test/hub']) {
        expect(await HandRelay().link(b, url: bad), {'ok': false, 'err': 'bad address'}, reason: bad);
      }
      expect(net.dialled.length, before);
    });

    test('the key seen at an address is remembered for an hour, then looked at again', () async {
      final h = HandRelay();
      final c = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(h.scalar));
      final b = TestRelay(net, 'b.test');
      expect((await h.link(b, url: c.url))['ok'], isTrue);
      expect((await h.link(b, url: c.url))['ok'], isTrue);
      expect(net.dialled, [c.url], reason: 'dialled once');
      await net.pass(const Duration(minutes: 59));
      expect((await h.link(b, url: c.url))['ok'], isTrue);
      expect(net.dialled, [c.url]);
      await net.pass(const Duration(minutes: 2));
      expect((await h.link(b, url: c.url))['ok'], isTrue);
      expect(net.dialled, [c.url, c.url], reason: 'an hour on, it is dialled again');
      expect(Federation.believedFor, const Duration(hours: 1));
    });

    test('a relay whose key has changed is seen with its new one after a few minutes, not refused for a day', () async {
      final old = HandRelay(), now = HandRelay();
      final b = TestRelay(net, 'b.test');
      TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(old.scalar));
      expect((await old.link(b, url: 'wss://c.test/hub'))['ok'], isTrue);
      // c.test is given a new key (its keeper lost the old one).
      final again = TestRelay(net, 'c.test', seed: 3, dataDir: folderWithKey(now.scalar));
      expect(again.id, now.id);
      expect(await now.link(b, url: again.url), {'ok': false, 'err': 'address'}, reason: 'the key seen there a moment ago is still believed');
      await net.pass(const Duration(minutes: 6));
      expect((await now.link(b, url: again.url))['ok'], isTrue);
      expect(await old.link(b, url: again.url), {'ok': false, 'err': 'address'});
    });

    test('no more hellos a minute than it will check', () async {
      final b = TestRelay(net, 'b.test', hellosAMinute: 3);
      for (var i = 0; i < 3; i++) {
        expect((await HandRelay().link(b))['ok'], isTrue);
      }
      expect(await HandRelay().link(b), {'ok': false, 'err': 'busy'});
      await net.pass(const Duration(minutes: 1));
      expect((await HandRelay().link(b))['ok'], isTrue);
    });

    test('no more links than its most: the one used longest ago makes room, and a link in use is never the one', () async {
      final b = TestRelay(net, 'b.test', maxLinks: 2);
      final first = HandRelay(), second = HandRelay(), third = HandRelay();
      await first.link(b);
      await net.pass(const Duration(seconds: 1));
      await second.link(b);
      await net.pass(const Duration(seconds: 1));
      first.say({'ping': 1}); // not a use: only a packet or a name asked after is
      expect((await third.link(b))['ok'], isTrue);
      await pumpEventQueue();
      expect([first.socket.isOpen, second.socket.isOpen, third.socket.isOpen], [false, true, true]);
      expect(b.fed.links, 2);
    });

    test('a hello that never finishes is let go: nothing is held open for a relay that says nothing more', () async {
      final b = TestRelay(net, 'b.test');
      // It claims an address at which a hub answers nothing at all.
      MemSocket? held;
      net.hand['wss://slow.test/hub'] = (s) => held = s;
      final h = HandRelay();
      final answer = h.link(b, url: 'wss://slow.test/hub');
      await pumpEventQueue();
      expect(held!.isOpen, isTrue);
      await net.pass(Federation.helloWithin);
      expect(await answer, {'ok': false, 'err': 'address'});
      expect(held!.isOpen, isFalse, reason: 'the look at that address was closed');
    });
  });

  group('this relay dials one', () {
    /// Alice on a real relay, sending to someone whose record names [url]: what makes the relay dial there.
    Future<({TestRelay a, Install alice, Install them, int n})> sendTo(String url) async {
      final a = TestRelay(net, 'a.test');
      final alice = Install(), them = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      alice.say({'dir': 'home', 'rec': them.record([url])});
      await pumpEventQueue();
      alice.said.clear();
      final n = alice.send(them.id, [1]);
      await net.settle();
      return (a: a, alice: alice, them: them, n: n);
    }

    /// A hub played by hand at [url]: says [hello], and answers this relay's hello with whatever [answer] makes of it.
    void play(String url, Map<String, Object?> hello, [Map<String, Object?>? Function(Map said)? answer]) {
      net.hand[url] = (s) {
        s.add(jsonEncode(hello));
        s.incoming.listen((d) {
          final m = d is String ? jsonDecode(d) as Map : null;
          if (m == null || m['fed'] != 1) return;
          final back = answer?.call(m);
          if (back != null) s.add(jsonEncode(back));
        });
      };
    }

    test('a hub from before, which names no relay, is not said hello to; the sender is told their relay can\'t be reached from here', () async {
      play('wss://old.test/hub', {'hello': 'ab' * 32, 'peek': true, 'react': true});
      final r = await sendTo('wss://old.test/hub');
      expect(net.made['wss://old.test/hub']!.single.heard, [isA<Map>()], reason: 'the hub\'s own hello came');
      expect(net.made['wss://old.test/hub']!.single.other.heard, isEmpty, reason: 'and this relay said nothing to it');
      expect(r.alice.answerTo(r.n), {'nak': r.n, 'err': 'far'});
      expect([r.a.fed.links, r.a.fed.waiting], [0, 0]);
      // And it is not dialled again for ten minutes: what is sent meanwhile is refused at once.
      final again = r.alice.send(r.them.id, [2]);
      await net.pass(const Duration(minutes: 9));
      expect(r.alice.answerTo(again), {'nak': again, 'err': 'far'});
      expect(net.dialled, hasLength(1));
      await net.pass(const Duration(minutes: 2));
      r.alice.send(r.them.id, [3]);
      await net.settle();
      expect(net.dialled, hasLength(2));
    });

    test('a relay that does not prove its key is not linked with', () async {
      final real = HandRelay(), liar = HandRelay();
      // It names a key in its hello, and answers signed by another.
      play('wss://liar.test/hub', {
        'hello': 'ab' * 32,
        'relay': {'id': real.id, 'key': base64Encode(real.key)},
      }, (said) => {'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(liar.scalar, Federation.answerBytes(c: unhex(said['c'] as String), dialler: said['id'] as String, answerer: real.id, dialled: 'wss://liar.test/hub'), someBytes(32)))});
      final r = await sendTo('wss://liar.test/hub');
      expect(r.a.fed.links, 0);
      expect(r.alice.answerTo(r.n), {'nak': r.n, 'err': 'far'});
      expect(net.made['wss://liar.test/hub']!.single.isOpen, isFalse);
    });

    test('an answer signed over another number, or for another relay, is not taken', () async {
      final real = HandRelay();
      var how = 0;
      play('wss://replay.test/hub', {
        'hello': 'ab' * 32,
        'relay': {'id': real.id, 'key': base64Encode(real.key)},
      }, (said) {
        final c = how == 0 ? someBytes(32) : unhex(said['c'] as String);
        final dialler = how == 1 ? 'cd' * 16 : said['id'] as String;
        return {'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: c, dialler: dialler, answerer: real.id, dialled: 'wss://replay.test/hub'), someBytes(32)))};
      });
      final r = await sendTo('wss://replay.test/hub');
      expect(r.a.fed.links, 0);
      how = 1;
      await net.pass(const Duration(minutes: 11));
      r.alice.send(r.them.id, [2]);
      await net.settle();
      expect(net.dialled, hasLength(2));
      expect(r.a.fed.links, 0);
      // The same relay, answering rightly, is linked with.
      how = 2;
      await net.pass(const Duration(minutes: 11));
      r.alice.send(r.them.id, [3]);
      await net.settle();
      expect(r.a.fed.links, 1);
    });

    test('a relay that answers no is not linked with, and what was for it is refused, not kept', () async {
      final b = TestRelay(net, 'b.test', seed: 2, mode: FedMode.off);
      final r = await sendTo(b.url);
      expect(r.alice.answerTo(r.n), {'nak': r.n, 'err': 'far'});
      expect([r.a.fed.links, r.a.fed.waiting, r.a.hub.heldFor(r.them.id)], [0, 0, 0]);
    });

    test('a relay this one may not link with is never dialled: blocked, or not on its list', () async {
      final b = TestRelay(net, 'b.test', seed: 2);
      final a = TestRelay(net, 'a.test', block: {'b.test'});
      final alice = Install(), bob = Install();
      await alice.signIn(a);
      alice.say({'dir': 'home', 'rec': bob.record([b.url])});
      await pumpEventQueue();
      final n = alice.send(bob.id, [1]);
      await net.settle();
      expect(alice.answerTo(n), {'nak': n, 'err': 'far'});
      expect(net.dialled, isEmpty);
      // Blocked by its name: dialled, since a name is only learnt there, and left at once.
      final byName = TestRelay(net, 'c.test', seed: 3, block: {b.id});
      final carol = Install();
      await carol.signIn(byName);
      await carol.giveHome(byName);
      carol.say({'dir': 'home', 'rec': bob.record([b.url], n: 1)});
      await pumpEventQueue();
      final m = carol.send(bob.id, [1]);
      await net.settle();
      expect(carol.answerTo(m), {'nak': m, 'err': 'far'});
      expect([net.dialled, byName.fed.links, b.fed.links], [[b.url], 0, 0]);
      // With a list that b.test is not on.
      final listed = TestRelay(net, 'd.test', seed: 4, mode: FedMode.list, allow: {'e.test'});
      final dan = Install();
      await dan.signIn(listed);
      await dan.giveHome(listed);
      dan.say({'dir': 'home', 'rec': bob.record([b.url], n: 1)});
      await pumpEventQueue();
      final k = dan.send(bob.id, [1]);
      await net.settle();
      expect(dan.answerTo(k), {'nak': k, 'err': 'far'});
      expect(net.dialled, [b.url]);
    });

    test('an address that turns out to be this relay itself: remembered, and what was for it is kept here as for anyone here', () async {
      final a = TestRelay(net, 'a.test');
      net.hubs['wss://old-name.test/hub'] = a.hub;
      final alice = Install(), carol = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      alice.say({'dir': 'home', 'rec': carol.record(['wss://old-name.test/hub'])});
      await pumpEventQueue();
      alice.said.clear();
      final n = alice.send(carol.id, [9]);
      await net.settle();
      expect(net.dialled, ['wss://old-name.test/hub']);
      expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
      expect([a.hub.heldFor(carol.id), a.fed.links, a.fed.waiting], [1, 0, 0]);
      // From then on it is an ordinary packet for someone here: nothing is dialled.
      final m = alice.send(carol.id, [10]);
      await net.settle();
      expect(alice.answerTo(m), {'ack': m, 'here': false});
      expect(net.dialled, hasLength(1));
      expect(await carol.signIn(a), {'ok': true, 'held': 2});
    });

    test('no more addresses are remembered as this relay\'s own than its most: the one found longest ago is looked at again', () async {
      final a = TestRelay(net, 'a.test');
      final alice = Install();
      await alice.signIn(a);
      await alice.giveHome(a);
      final people = [for (var i = 0; i < 258; i++) Install()];
      for (var i = 0; i < 258; i++) {
        net.hubs['wss://alias$i.test/hub'] = a.hub;
        alice.say({'dir': 'home', 'rec': people[i].record(['wss://alias$i.test/hub'])});
        // (A hundred a second: one install has a quarter of each second's checks.)
        if (i % 100 == 99) await net.pass(const Duration(seconds: 1));
      }
      await pumpEventQueue();
      // Each is dialled once and found to be this relay; 257 of them, one more than it remembers.
      for (var i = 0; i < 257; i++) {
        alice.send(people[i].id, [1]);
        await pumpEventQueue();
      }
      expect(net.dialled, hasLength(257));
      // The newest is remembered: nothing is dialled for it again. The first has been let go: it is dialled again.
      alice.send(people[256].id, [2]);
      await pumpEventQueue();
      expect(net.dialled, hasLength(257));
      alice.send(people[0].id, [2]);
      await pumpEventQueue();
      expect(net.dialled.last, 'wss://alias0.test/hub');
      expect(net.dialled, hasLength(258));
      expect(a.hub.heldFor(people[0].id), 2, reason: 'and it is still kept here, as for anyone here');
    });
  });
}
