import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/ws_door.dart' show WireBudget;
import 'package:test/test.dart';

import 'fed_support.dart';

/// What a relay hosted from the app asks of the hub (the app's lib/relay_host; docs/OPEN_NETWORK.md, section 5), each an
/// option that does nothing unless it is set, so a relay on a server, gogho.st's, says and does exactly what it did:
///
/// - a pass phrase people must give to use it ([Hub.passKeyOf], [Hub.passProof]), salted with the relay's own, with the
///   wrong ones costing whoever gives them;
/// - a hello that says it runs in someone's app ([Hub.hosted]);
/// - less kept for rooms than a server keeps ([Hub.roomKeepBytes]);
/// - no word believed of whom a connection came through, with nobody in front of it ([Hub.trustsProxy]);
/// - and, on the relay it stays linked to, a word on whether it may stay, which the hosted one shows its keeper
///   ([Federation.viaLink]).

/// A connection's answers as a test reads them: the hello, then whatever came after, and how it was closed.
class _Signing {
  _Signing(this.hub, {this.from = '', bool own = false}) {
    final (mine, theirs) = MemSocket.pair();
    socket = mine;
    mine.incoming.listen((d) {
      if (d is! String) return;
      final m = jsonDecode(d) as Map;
      if (!hello.isCompleted) {
        hello.complete(m);
      } else {
        said.add(m);
        if (!answer.isCompleted) answer.complete(m);
      }
    });
    hub.attach(theirs, from: from, own: own);
  }

  final Hub hub;
  final String from;
  late final MemSocket socket;
  final hello = Completer<Map>();
  final answer = Completer<Map>();
  final said = <Map>[];

  /// Signs in as [who] (v1, as every hub takes without names), with `"pass"` where [pass] is given (hex), or a proof made
  /// from [phrase] for this connection's number and [proofFor]'s name (who's own by default). What the hub answered.
  Future<Map> signIn(Install who, {String? pass, String? phrase, Install? proofFor, bool peek = false}) async {
    final h = await hello.future;
    final nonce = unhex(h['hello'] as String);
    final sig = P256.sign(who.scalar, [...utf8.encode(Hub.greeting), ...nonce], someBytes(32));
    final proof = pass ?? (phrase == null ? null : _hex(Hub.passProof(Hub.passKeyOf(phrase, h['salt'] as String), nonce, (proofFor ?? who).id)));
    socket.add(jsonEncode({'id': who.id, 'key': base64Encode(who.key), 'sig': base64Encode(sig), 'pass': ?proof, if (peek) 'peek': true}));
    return withoutClock(await answer.future.timeout(const Duration(seconds: 5)));
  }
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

void main() {
  group('with none of it set', () {
    test('the hello and the sign-in are exactly as before: no pass, nothing said of being hosted, 256 MB kept for rooms', () async {
      final hub = Hub();
      final s = _Signing(hub);
      final h = await s.hello.future;
      expect(h.keys.toSet(), {'hello', 'peek', 'react'}, reason: 'a hub with no options says what it always said');
      expect(await s.signIn(Install()), {'ok': true, 'held': 0});
      expect([hub.asksPass, hub.hosted, hub.roomKeepBytes], [false, false, 256 * 1024 * 1024]);
      // A "pass" said to a hub that asks none is passed over, as anything it doesn't know is.
      final t = _Signing(hub);
      expect(await t.signIn(Install(), pass: 'ab' * 32), {'ok': true, 'held': 0});
    });
  });

  group('a pass phrase', () {
    const phrase = 'correct horse battery staple';

    test('the hello says one is asked for; none given is refused and said so, and the connection is closed', () async {
      final hub = Hub(pass: phrase);
      final s = _Signing(hub);
      final h = await s.hello.future;
      expect(h['pass'], true);
      expect(h['salt'], hub.passSalt);
      expect(await s.signIn(Install()), {'ok': false, 'err': 'This relay asks for a pass phrase.', 'pass': 'needed'});
      await pumpEventQueue();
      expect([s.socket.isOpen, s.socket.other.code], [false, 4401]);
      expect(hub.connected, 0);
    });

    test('the right one signs in; a wrong one is refused, said as wrong', () async {
      final hub = Hub(pass: phrase);
      expect(await _Signing(hub).signIn(Install(), phrase: phrase), {'ok': true, 'held': 0});
      expect(await _Signing(hub).signIn(Install(), phrase: 'correct horse battery stapler'), {'ok': false, 'err': 'That pass phrase isn\'t this relay\'s.', 'pass': 'wrong'});
      expect(await _Signing(hub).signIn(Install(), pass: 'not hex at all'), containsPair('pass', 'wrong'));
      expect(hub.connected, 1);
    });

    test('a proof is good for its own connection and its own install alone: another connection\'s, or one made for someone else, is wrong', () async {
      final hub = Hub(pass: phrase);
      final maya = Install(), alex = Install();
      // Made for one connection's number, given on another.
      final first = _Signing(hub);
      final nonce = unhex((await first.hello.future)['hello'] as String);
      final proof = _hex(Hub.passProof(Hub.passKeyOf(phrase, hub.passSalt), nonce, maya.id));
      expect(await first.signIn(maya, pass: proof), {'ok': true, 'held': 0});
      expect(await _Signing(hub).signIn(maya, pass: proof), containsPair('pass', 'wrong'), reason: 'seen once, it is worth nothing again');
      // Made for Maya's name, given by Alex.
      expect(await _Signing(hub).signIn(alex, phrase: phrase, proofFor: maya), containsPair('pass', 'wrong'));
    });

    test('a closed app\'s look needs it too', () async {
      final hub = Hub(pass: phrase);
      expect(await _Signing(hub).signIn(Install(), peek: true), containsPair('pass', 'needed'));
      expect(await _Signing(hub).signIn(Install(), phrase: phrase, peek: true), {'ok': true, 'held': 0, 'peek': true, 'here': false});
    });

    test('wrong ones cost their place: a few free, then each try waits, doubled each time; none given counts for nothing', () async {
      var t = DateTime.utc(2026, 11, 23, 9);
      final hub = Hub(now: () => t, pass: phrase, passGuessesFree: 3, passWaitFirst: const Duration(minutes: 1), passWaitMost: const Duration(minutes: 5));
      Future<Map> at(String place, {String? said}) => _Signing(hub, from: place).signIn(Install(), phrase: said);
      // An app not told the phrase yet tries again and again: that is no guess.
      for (var i = 0; i < 10; i++) {
        expect(await at('10.0.0.2'), containsPair('pass', 'needed'));
      }
      expect(await at('10.0.0.2', said: phrase), containsPair('ok', true));
      // Three wrong from one place are free; the fourth try waits a minute, the right phrase too.
      for (var i = 0; i < 3; i++) {
        expect(await at('10.0.0.3', said: 'guess $i'), containsPair('pass', 'wrong'));
      }
      expect(await at('10.0.0.3', said: phrase), {'ok': false, 'err': 'Too many wrong pass phrases lately. Try again in a while.', 'pass': 'busy', 'wait': 60});
      // Another place is not touched by it.
      expect(await at('10.0.0.4', said: phrase), containsPair('ok', true));
      t = t.add(const Duration(seconds: 61));
      expect(await at('10.0.0.3', said: 'guess 3'), containsPair('pass', 'wrong'), reason: 'a minute on, one more is looked at');
      expect(await at('10.0.0.3', said: phrase), containsPair('wait', 120), reason: 'and the next waits twice as long');
      t = t.add(const Duration(minutes: 2, seconds: 1));
      expect(await at('10.0.0.3', said: 'guess 4'), containsPair('pass', 'wrong'));
      t = t.add(const Duration(minutes: 4, seconds: 1));
      expect(await at('10.0.0.3', said: 'guess 5'), containsPair('pass', 'wrong'), reason: 'four minutes was enough');
      expect(await at('10.0.0.3', said: phrase), containsPair('wait', 300), reason: 'at most passWaitMost');
      t = t.add(const Duration(minutes: 66));
      expect(await at('10.0.0.3', said: phrase), containsPair('ok', true), reason: 'an hour after it might have tried again, it is forgotten');
    });

    test('strangers with new places each time can\'t shut out anyone who has used the relay, nor the keeper\'s own app: only newcomers wait', () async {
      // Over Direct a place is a node id, and node ids are free (found in review, 2026-11-23: with a count for everyone
      // of 200 an hour, ten made-up nodes shut everyone out, the keeper's own app in memory too).
      final t = DateTime.utc(2026, 11, 23, 9);
      final hub = Hub(now: () => t, pass: phrase, passGuessesFree: 5, passGuessesAll: 20);
      final maya = Install();
      expect(await _Signing(hub, from: 'p2p:maya').signIn(maya, phrase: phrase), containsPair('ok', true));
      expect(hub.passKnows(maya.id), isTrue);
      var wrong = 0;
      for (var node = 0; node < 10; node++) {
        for (var g = 0; g < 5; g++) {
          final m = await _Signing(hub, from: 'p2p:far-$node').signIn(Install(), phrase: 'guess $node.$g');
          if (m['pass'] == 'wrong') wrong++;
        }
      }
      expect(wrong, 20, reason: 'strangers together had their twenty this hour; the rest weren\'t looked at');
      expect(await _Signing(hub, from: 'p2p:far-99').signIn(Install(), phrase: phrase), containsPair('pass', 'busy'), reason: 'a newcomer, even with the right phrase, waits the hour out');
      expect(await _Signing(hub, from: 'p2p:maya-2').signIn(maya, phrase: phrase), containsPair('ok', true), reason: 'Maya has used it: still looked at');
      expect(await _Signing(hub, own: true).signIn(Install()), containsPair('ok', true), reason: 'the keeper\'s own app is never asked');
      // Someone claiming Maya's name without her key is no better off than a stranger.
      final fake = _Signing(hub, from: 'p2p:far-100');
      final h = await fake.hello.future;
      final nonce = unhex(h['hello'] as String);
      final other = Install();
      final sig = P256.sign(other.scalar, [...utf8.encode(Hub.greeting), ...nonce], someBytes(32));
      fake.socket.add(jsonEncode({'id': maya.id, 'key': base64Encode(maya.key), 'sig': base64Encode(sig), 'pass': _hex(Hub.passProof(Hub.passKeyOf('guess', hub.passSalt), nonce, maya.id))}));
      expect(await fake.answer.future, containsPair('pass', 'busy'));
    });

    test('those who have used it are kept in its folder, under their phrase: a new phrase starts it again', () async {
      final dir = await Directory.systemTemp.createTemp('hub-pass');
      addTearDown(() => dir.delete(recursive: true));
      final maya = Install();
      var hub = Hub(pass: phrase, passSalt: 'r1', dataDir: dir)..start();
      expect(await _Signing(hub).signIn(maya, phrase: phrase), containsPair('ok', true));
      hub.stop();
      hub = Hub(pass: phrase, passSalt: 'r1', dataDir: dir)..start();
      expect(hub.passKnows(maya.id), isTrue, reason: 'started again, it still knows her');
      hub.stop();
      hub = Hub(pass: '$phrase, changed', passSalt: 'r1', dataDir: dir)..start();
      expect(hub.passKnows(maya.id), isFalse, reason: 'a new phrase: nobody is known until they give it');
      hub.stop();
    });

    test('each relay salts with its own name: keys made for one relay\'s overheard sign-ins are no use against another', () async {
      // The review's probe (2026-11-23): with one salt for every relay, keys for a list of likely phrases made once
      // cracked any relay's overheard sign-in at one HMAC a phrase.
      final likely = ['password', 'hunter2', 'our wifi', 'letmein'];
      final table = {for (final p in likely) p: Hub.passKeyOf(p, 'one-relay')};
      final net = FakeNet();
      final v = TestRelay(net, 'v.test', seed: 5);
      final hub = Hub(pass: 'hunter2', federation: v.fed);
      expect(hub.passSalt, v.fed.id, reason: 'a relay with a name salts with it');
      expect(Hub(pass: 'x').passSalt, isNot(Hub(pass: 'x').passSalt), reason: 'one without, with its own random bytes');
      final s = _Signing(hub);
      final h = await s.hello.future;
      final nonce = unhex(h['hello'] as String);
      final who = Install();
      final proof = _hex(Hub.passProof(Hub.passKeyOf('hunter2', h['salt'] as String), nonce, who.id));
      final sig = P256.sign(who.scalar, [...utf8.encode(Hub.greeting), ...nonce], someBytes(32));
      s.socket.add(jsonEncode({'id': who.id, 'key': base64Encode(who.key), 'sig': base64Encode(sig), 'pass': proof}));
      expect(await s.answer.future, containsPair('ok', true));
      final found = [for (final e in table.entries) if (_hex(Hub.passProof(e.value, nonce, who.id)) == proof) e.key];
      expect(found, isEmpty, reason: 'the table made for another salt finds nothing');
      expect(_hex(Hub.passProof(Hub.passKeyOf('hunter2', v.fed.id), nonce, who.id)), proof, reason: 'only keys made for this relay\'s salt do');
    });

    test('with nothing in front of it, what a connection says it came through is not believed: one place stays one place', () async {
      // Over real sockets, from this machine: a relay hosted from the app has nobody in front of it, so anyone on its
      // network could name a new place in X-Forwarded-For with each try, and guess as many times as they liked.
      Future<Map> signInOver(int port, String forwarded, String said) async {
        final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub', headers: {'x-forwarded-for': forwarded});
        final answers = StreamIterator(ws);
        await answers.moveNext();
        final nonce = unhex((jsonDecode(answers.current as String) as Map)['hello'] as String);
        final who = Install();
        final sig = P256.sign(who.scalar, [...utf8.encode(Hub.greeting), ...nonce], someBytes(32));
        ws.add(jsonEncode({'id': who.id, 'key': base64Encode(who.key), 'sig': base64Encode(sig), 'pass': _hex(Hub.passProof(Hub.passKeyOf(said, (jsonDecode(answers.current as String) as Map)['salt'] as String), nonce, who.id))}));
        await answers.moveNext();
        final m = jsonDecode(answers.current as String) as Map;
        await ws.close();
        return m;
      }

      for (final trusts in [true, false]) {
        final hub = Hub(pass: phrase, passGuessesFree: 1, trustsProxy: trusts, wire: WireBudget());
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen(hub.accept);
        expect(await signInOver(server.port, '203.0.113.1', 'wrong'), containsPair('pass', 'wrong'));
        final second = await signInOver(server.port, '203.0.113.2', phrase);
        expect(second['ok'] == true, trusts, reason: trusts ? 'behind a proxy it is the proxy\'s word: another place' : 'nobody in front: still 127.0.0.1, which has had its one wrong guess');
        await server.close(force: true);
      }
    });

    test('another relay\'s hello is not asked for it: whether relays link is their keepers\' own choice', () async {
      final net = FakeNet();
      final v = TestRelay(net, 'v.test', seed: 1);
      final passHub = Hub(now: net.now, pass: phrase, federation: v.fed);
      net.hubs[v.url] = passHub;
      final r = TestRelay(net, 'r.test', seed: 3, public: false, via: v.url);
      await net.settle();
      expect(r.fed.linkedWith(v.id), isTrue);
      expect((net.made[v.url]!.first.heard.first as Map)['pass'], true, reason: 'the hub it dialled does ask apps for one');
    });

    test('the key is PBKDF2-HMAC-SHA256 over the phrase, salted with the words and the relay\'s salt, 20,000 rounds: the app makes the same', () {
      // RFC 7914's vector for PBKDF2-HMAC-SHA256 holds the arithmetic (P = "passwd", S = "salt", c = 1: its first 32
      // bytes); the app (test/relay_host_test.dart) is held to the same value for this phrase.
      expect(_hex(Hub.pbkdf2Sha256(utf8.encode('passwd'), utf8.encode('salt'), 1)), '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc');
      expect([Hub.passWords, Hub.passRounds], ['ghost-hub pass v2', 20000]);
      // Python's hashlib.pbkdf2_hmac('sha256', phrase, b'ghost-hub pass v2 ' + b'ab' * 16, 20000, 32) gives the same.
      expect(_hex(Hub.passKeyOf(phrase, 'ab' * 16)), '57127492378841a4077eb48b9242dd3ab2f4d818086d9e7b010dac4843bbb1b4');
      expect(Hub.passKeyOf(phrase, 'ab' * 16), isNot(Hub.passKeyOf('$phrase.', 'ab' * 16)));
      expect(Hub.passKeyOf(phrase, 'ab' * 16), isNot(Hub.passKeyOf(phrase, 'cd' * 16)));
    });
  });

  group('a hub hosted from the app', () {
    test('its hello proves it holds its key, for this connection and the place it was reached as (the third review, 2026-11-23)', () async {
      final net = FakeNet();
      final r = TestRelay(net, 'r.test', seed: 3, public: false, via: 'wss://v.test/hub');
      final hub = Hub(federation: r.fed, hosted: true);
      final node = 'cd' * 32;
      final (mine, theirs) = MemSocket.pair();
      final hello = Completer<Map>();
      mine.incoming.listen((d) => hello.isCompleted ? null : hello.complete(jsonDecode(d as String) as Map));
      hub.attach(theirs, reachedAs: node);
      final h = await hello.future;
      final sig = base64Decode(h['relaySig'] as String), nonce = unhex(h['hello'] as String);
      expect(P256.verify(r.fed.key, Federation.reachedMessage(nonce, node), sig), isTrue);
      expect(P256.verify(r.fed.key, Federation.reachedMessage(nonce, 'ef' * 32), sig), isFalse, reason: 'for that node alone');
      // Reached no particular way (a server's WebSocket), or with no key: nothing more is said.
      expect((await _Signing(hub).hello.future).containsKey('relaySig'), isFalse);
      final plain = Hub();
      final (m2, t2) = MemSocket.pair();
      final h2 = Completer<Map>();
      m2.incoming.listen((d) => h2.isCompleted ? null : h2.complete(jsonDecode(d as String) as Map));
      plain.attach(t2, reachedAs: node);
      expect((await h2.future).keys.toSet(), {'hello', 'peek', 'react'}, reason: 'gogho.st\'s hello as it was');
    });

    test('says so in its hello, and only where it is', () async {
      expect((await _Signing(Hub(hosted: true)).hello.future)['hosted'], true);
      expect((await _Signing(Hub()).hello.future).containsKey('hosted'), isFalse);
    });

    test('keeps no more for rooms than it is given, the oldest of the busiest room going first', () async {
      final hub = Hub(roomKeepBytes: 2000);
      final room = 'ab' * 16, token = 'cd' * 32;
      final a = _Signing(hub), b = _Signing(hub);
      final ana = Install(), ben = Install();
      await a.signIn(ana);
      await b.signIn(ben);
      for (final s in [a, b]) {
        s.socket.add(jsonEncode({'join': room, 'token': token}));
      }
      await pumpEventQueue();
      // Five kept packets of 600 bytes: 3,000 in all, past the 2,000 it keeps.
      for (var i = 0; i < 5; i++) {
        a.socket.add(Uint8List.fromList([Hub.toRoomKept, ...unhex(room), ...List.filled(600, i)]));
      }
      await pumpEventQueue();
      expect(hub.keptIn(room), 3, reason: 'each kept frame carries the room and who sent it: three fit in 2,000 bytes');
    });
  });

  group('the link a hosted relay keeps to its public one (viaLink)', () {
    test('a public relay with relays switched off answers no, and the hosted one says why and when it tries again', () async {
      final net = FakeNet();
      // gogho.st today: a hub with no federation at all.
      net.hubs['wss://v.test/hub'] = Hub(now: net.now);
      final r = TestRelay(net, 'r.test', seed: 3, public: false, via: 'wss://v.test/hub');
      expect(r.fed.viaLink, (linked: false, stays: false, why: null, next: null), reason: 'not dialled yet');
      await net.settle();
      final link = r.fed.viaLink!;
      expect([link.linked, link.stays, link.why], [false, false, 'not a relay that talks to others']);
      expect(link.next, net.clock.add(const Duration(seconds: 5)));
      // Nothing answers there at all: down.
      net.hubs.remove('wss://v.test/hub');
      await net.pass(const Duration(seconds: 6));
      expect(r.fed.viaLink!.why, 'down');
      // A relay with no via has nothing to say.
      expect(TestRelay(net, 'p.test', seed: 4).fed.viaLink, isNull);
    });

    test('linked, it says whether the public relay lets it stay: told so only where it does', () async {
      final net = FakeNet();
      final v = TestRelay(net, 'v.test', seed: 1);
      final r = TestRelay(net, 'r.test', seed: 3, public: false, via: v.url);
      await net.settle();
      expect(r.fed.viaLink, (linked: true, stays: false, why: null, next: null), reason: 'v talks to other relays, and keeps no standing links');
      final w = TestRelay(net, 'w.test', seed: 5, standingOpen: true);
      final s = TestRelay(net, 's.test', seed: 6, public: false, via: w.url);
      await net.settle();
      expect(s.fed.viaLink, (linked: true, stays: true, why: null, next: null));
      // What w answered: the yes, with "stay"; v's said nothing of it.
      final answers = [for (final url in [v.url, w.url]) net.made[url]!.first.heard.whereType<Map>().firstWhere((m) => m['ok'] == true)];
      expect([answers[0].containsKey('stay'), answers[1]['stay']], [false, true]);
    });

    test('its hello says it talks to other relays only while its link stays (the second review, 2026-11-23: always did)', () async {
      final net = FakeNet();
      net.hubs['wss://v.test/hub'] = Hub(now: net.now);
      final refused = TestRelay(net, 'r.test', seed: 3, public: false, via: 'wss://v.test/hub');
      await net.settle();
      expect(refused.fed.card!['fed'], false, reason: 'its public relay said no: nothing it says can reach another relay');
      final v = TestRelay(net, 'v2.test', seed: 1);
      final linked = TestRelay(net, 'l.test', seed: 4, public: false, via: v.url);
      await net.settle();
      expect([linked.fed.viaLink!.linked, linked.fed.card!['fed']], [true, false], reason: 'linked, but not let stay');
      final w = TestRelay(net, 'w.test', seed: 5, standingOpen: true);
      final stays = TestRelay(net, 's.test', seed: 6, public: false, via: w.url);
      await net.settle();
      expect(stays.fed.card!['fed'], true);
      expect(w.fed.card!['fed'], true, reason: 'a relay with its own address says so as ever');
    });
  });
}
