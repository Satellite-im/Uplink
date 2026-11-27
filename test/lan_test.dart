import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/lan/lan_carrier.dart';
import 'package:ghost_messaging/net/lan/lan_ground_io.dart';
import 'package:ghost_messaging/net/lan/lan_wire.dart';
import 'package:ghost_messaging/net/lan/lan_words.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';

import 'support/fake_lan.dart';

/// The local network route (lib/net/lan; GMFB-24: "A LAN route: two devices on the same network find each other (mDNS
/// or similar) and exchange sealed packets directly"): what a beacon says and to whom, who links with whom and how each
/// end proves whose it is, what the network itself sees, and the route under the switchboard. On a network in memory
/// (test/support/fake_lan.dart), and once over this machine's own sockets.

/// Waits for [ok], however long the machine takes (five seconds at most), not for a length of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// Lets what is under way finish: a beacon heard, a knock answered.
Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await pumpEventQueue(times: 30);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Whether [bytes] holds [part] anywhere.
bool _holds(List<int> bytes, List<int> part) {
  outer:
  for (var i = 0; i + part.length <= bytes.length; i++) {
    for (var j = 0; j < part.length; j++) {
      if (bytes[i + j] != part[j]) continue outer;
    }
    return true;
  }
  return false;
}

const _quick = LanPolicy(
  beatEvery: Duration(hours: 1),
  sweepEvery: Duration(hours: 1),
  yieldFor: Duration(milliseconds: 30),
  proveFor: Duration(milliseconds: 400),
  dialFor: Duration(milliseconds: 400),
  redialAfter: Duration(milliseconds: 1),
  sleepsAway: false,
);

void main() {
  final ann = NetKeys.generate(), ben = NetKeys.generate(), cat = NetKeys.generate();
  Uint8List pair(NetKeys a, NetKeys b) => NetCrypto.netKey(NetCrypto.conversationKey(a, b.public)!);
  final annBen = pair(ann, ben);
  final annsOwn = NetCrypto.randomBytes(32);

  late FakeLan lan;
  late DateTime clock;
  final made = <LanCarrier>[];
  var seed = 0;

  /// A device of [who] at [address], which says it is here to [people] and links with them.
  LanCarrier device(NetKeys who, String address, List<Peer> Function() people, {LanPolicy policy = _quick, int? run}) {
    final c = LanCarrier(me: who.id, ground: lan.join(address), people: people, policy: policy, now: () => clock, random: Random(run ?? ++seed));
    made.add(c);
    return c;
  }

  setUp(() {
    lan = FakeLan();
    clock = DateTime.utc(2026, 11, 26, 12);
    seed = 0;
  });
  tearDown(() async {
    for (final c in made) {
      await c.dispose();
    }
    made.clear();
  });

  group('the words', () {
    test('a beacon is read back as it was said, and anything else is no beacon', () {
      final b = LanBeacon(instance: Uint8List.fromList(List.generate(8, (i) => i + 1)), port: 40123, bucket: LanWords.bucketOf(clock.millisecondsSinceEpoch), marks: [for (var i = 0; i < 8; i++) Uint8List.fromList(List.filled(8, i))]);
      final bytes = b.encode();
      final back = LanBeacon.decode(bytes)!;
      expect([back.instance, back.port, back.bucket, back.marks], [b.instance, 40123, b.bucket, b.marks]);
      expect(LanBeacon.decode(Uint8List.fromList([...bytes, 0])), isNull, reason: 'longer than it says');
      expect(LanBeacon.decode(Uint8List.sublistView(bytes, 0, bytes.length - 1)), isNull, reason: 'cut short');
      expect(LanBeacon.decode(Uint8List.fromList([0x47, 0x4c, 2, ...bytes.sublist(3)])), isNull, reason: 'another version');
      expect(LanBeacon.decode(Uint8List(4)), isNull);
      final noPort = Uint8List.fromList(bytes)
        ..[11] = 0
        ..[12] = 0;
      expect(LanBeacon.decode(noPort), isNull, reason: 'a door at no port');
    });

    test('a mark is for one direction, one ten minutes, one run, one port and one address, and nobody without the key makes it', () {
      final key = LanWords.keyOf(annBen);
      final run = List.generate(8, (i) => i);
      Uint8List mark({List<int>? k, String? from, String? to, int bucket = 100, List<int>? instance, int port = 4000, String address = '192.168.1.10'}) =>
          LanWords.mark(k ?? key, from: from ?? ann.id, to: to ?? ben.id, bucket: bucket, instance: instance ?? run, port: port, address: address)!;
      final m = mark();
      expect(m, hasLength(8));
      expect(mark(), m, reason: 'the same from the same');
      for (final other in [mark(from: ben.id, to: ann.id), mark(bucket: 101), mark(instance: List.filled(8, 9)), mark(port: 4001), mark(k: LanWords.keyOf(pair(ann, cat))), mark(to: cat.id), mark(address: '192.168.1.66')]) {
        expect(other, isNot(m));
      }
      expect(LanWords.keyOf(annBen), isNot(annBen), reason: 'never the key packets are sealed with itself');
      // Said from nowhere a mark can be made for: no mark.
      for (final not in ['fe80::1', '', '1.2.3', '1.2.3.256', 'a.b.c.d']) {
        expect(LanWords.mark(key, from: ann.id, to: ben.id, bucket: 100, instance: run, port: 4000, address: not), isNull, reason: not);
      }
      // Noise: the same for its ten minutes, another for the next, for another address and for another place among them.
      final secret = List.filled(32, 7);
      final n = LanWords.noise(secret, bucket: 100, address: '192.168.1.10', slot: 0);
      expect([n.length, LanWords.noise(secret, bucket: 100, address: '192.168.1.10', slot: 0)], [8, n]);
      for (final other in [LanWords.noise(secret, bucket: 101, address: '192.168.1.10', slot: 0), LanWords.noise(secret, bucket: 100, address: '192.168.1.11', slot: 0), LanWords.noise(secret, bucket: 100, address: '192.168.1.10', slot: 1), LanWords.noise(List.filled(32, 8), bucket: 100, address: '192.168.1.10', slot: 0)]) {
        expect(other, isNot(n));
      }
      expect([for (final people in [0, 1, 8, 9, 16, 17, 100, 160, 161, 5000]) LanBeacon.sizeFor(people)], [8, 8, 8, 16, 16, 32, 128, 160, 160, 160]);
    });

    test('frames come whole however the bytes are cut, and a length too long ends it', () {
      final a = Uint8List.fromList(List.generate(300, (i) => i % 251)), b = Uint8List(0), c = Uint8List.fromList([7]);
      final stream = [...LanFramer.wrap(a), ...LanFramer.wrap(b), ...LanFramer.wrap(c)];
      for (final cut in [1, 3, 4, 5, 64, stream.length]) {
        final f = LanFramer();
        final got = <Uint8List>[];
        for (var i = 0; i < stream.length; i += cut) {
          got.addAll(f.add(stream.sublist(i, min(i + cut, stream.length))));
        }
        expect(got, [a, b, c], reason: 'cut every $cut');
        expect(f.broken, isFalse);
      }
      final f = LanFramer();
      expect(f.add([0, 2, 0, 0, 1, 2, 3]), isEmpty);
      expect(f.broken, isTrue, reason: '128 KB is longer than a frame may be');
      expect(f.add(LanFramer.wrap(c)), isEmpty, reason: 'nothing more is taken');
    });

    test('only a private network\'s addresses count as the local network, and two are one network by their first two numbers', () {
      expect([sameNet('192.168.1.10', '192.168.7.20'), sameNet('10.0.5.1', '10.0.9.9'), sameNet('172.20.1.1', '172.20.200.3')], [true, true, true]);
      expect([sameNet('10.0.5.1', '10.1.5.1'), sameNet('192.168.1.10', '10.168.1.10'), sameNet('8.8.8.8', '8.8.4.4'), sameNet('192.168.1.10', '')], [false, false, false, false]);
      for (final yes in ['10.0.0.7', '192.168.1.20', '172.16.0.1', '172.31.255.254']) {
        expect(isLanAddress(yes), isTrue, reason: yes);
      }
      for (final no in ['8.8.8.8', '127.0.0.1', '169.254.169.254', '172.32.0.1', '100.64.0.1', '192.169.1.1', 'fe80::1', '10.0.0', '10.0.0.256', '']) {
        expect(isLanAddress(no), isFalse, reason: no);
      }
    });
  });

  group('two friends on one network', () {
    late LanCarrier a, b;
    final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);

    Future<void> meet() async {
      a = device(ann, '192.168.1.10', () => [benPeer]);
      b = device(ben, '192.168.1.11', () => [annPeer]);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'each is linked to the other');
    }

    test('find each other by their beacons, link, and carry packets both ways', () async {
      await meet();
      expect([a.state.value, b.state.value], [CarrierState.up, CarrierState.up]);
      expect([a.seen, b.seen], [1, 1]);
      expect([a.links.single.peer, a.links.single.address], [ben.id, '192.168.1.11']);
      expect([b.links.single.peer, b.links.single.address], [ann.id, '192.168.1.10']);
      expect([a.reaches(benPeer), a.linked(benPeer), a.linkedToSomeone], [true, true, true]);
      final atB = <Arrived>[], atA = <Arrived>[];
      b.arrived.listen(atB.add);
      a.arrived.listen(atA.add);
      final packet = Uint8List.fromList(List.generate(2000, (i) => (i * 7) % 256));
      expect(await a.send(benPeer, packet), Handed.passed);
      await _until(() => atB.length == 1, 'it came');
      expect([atB.single.carrier, atB.single.from, atB.single.bytes], ['lan', ann.id, packet], reason: 'vouched for as Ann\'s: the link proved it');
      // Back on the link it came by, as an answer goes.
      expect(await b.sendOn(annPeer, atB.single.line, Uint8List.fromList([1, 2, 3])), Handed.passed);
      await _until(() => atA.length == 1, 'the answer came');
      expect([atA.single.from, atA.single.bytes], [ben.id, [1, 2, 3]]);
      // The longest packet goes; one longer is refused.
      expect(await a.send(benPeer, Uint8List(LanCarrier.maxPacket)), Handed.passed);
      await _until(() => atB.length == 2, 'the longest came');
      await expectLater(a.send(benPeer, Uint8List(LanCarrier.maxPacket + 1)), throwsA(isA<CarrierError>()));
    });

    test('whichever of the two hears the other links: a network that passes one\'s broadcasts and not the other\'s', () async {
      for (final hears in ['192.168.1.10', '192.168.1.11']) {
        lan = FakeLan();
        // Only [hears] hears anything said to everyone.
        lan.deafTo.add(hears == '192.168.1.10' ? '192.168.1.11' : '192.168.1.10');
        a = device(ann, '192.168.1.10', () => [benPeer], run: 1);
        b = device(ben, '192.168.1.11', () => [annPeer], run: 2);
        await a.start();
        await b.start();
        // Each says it is here again, as it does every few seconds, now that both are up.
        await a.beat();
        await b.beat();
        await _until(() => a.links.length == 1 && b.links.length == 1, 'linked though only $hears hears');
        await a.dispose();
        await b.dispose();
      }
    });

    test('the network sees no name, no account and no packet: marks that mean nothing to it, then sealed frames', () async {
      await meet();
      final packet = Uint8List.fromList(List.generate(600, (i) => 0xA0 + i % 7));
      final atB = <Arrived>[];
      b.arrived.listen(atB.add);
      await a.send(benPeer, packet);
      await _until(() => atB.isNotEmpty, 'it came');
      final said = [...lan.beacons.map((x) => x.bytes), ...lan.frames];
      expect(said.length, greaterThan(4));
      for (final x in said) {
        for (final secret in [NetCrypto.unhex(ann.id), NetCrypto.unhex(ben.id), packet.sublist(0, 32), annBen, LanWords.keyOf(annBen)]) {
          expect(_holds(x, secret), isFalse);
        }
      }
      // A beacon carries noise beside its one real mark, eight in all, in the order of their bytes.
      final beacon = LanBeacon.decode(lan.beacons.first.bytes)!;
      expect(beacon.marks, hasLength(8));
      final hexes = [for (final m in beacon.marks) NetCrypto.hex(m)];
      expect(hexes, [...hexes]..sort());
      // And two beacons from one run, ten minutes apart, share no mark.
      final before = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!;
      clock = clock.add(const Duration(minutes: 11));
      await a.beat();
      final after = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!;
      expect(after.bucket, isNot(before.bucket));
      final was = {for (final m in before.marks) NetCrypto.hex(m)};
      expect(after.marks.any((m) => was.contains(NetCrypto.hex(m))), isFalse);
    });

    test('a frame said twice, out of turn or changed ends the link, and nothing of it is passed on', () async {
      await meet();
      final atB = <Arrived>[];
      b.arrived.listen(atB.add);
      await a.send(benPeer, Uint8List.fromList([9, 9, 9]));
      await _until(() => atB.length == 1, 'the first came');
      // The wire's two ends: the one Ann's device sends on, and Ben's, which hears it.
      final (x, y) = lan.wires.last;
      final annsEnd = x.sent.any((f) => f.isNotEmpty && f[0] == 4) && x.address == '192.168.1.11' ? x : y;
      final bensEnd = identical(annsEnd, x) ? y : x;
      final sealed = annsEnd.sent.lastWhere((f) => f[0] == 4);
      // Someone on the wire says it to Ben's device again.
      bensEnd.arrive(sealed);
      await _until(() => b.links.isEmpty, 'the link was closed');
      expect(atB, hasLength(1), reason: 'not passed on twice');
    });

    test('a link with nothing heard on it is closed, a quiet one is kept by a word, and a device gone is forgotten', () async {
      await meet();
      final before = lan.frames.length;
      clock = clock.add(const Duration(seconds: 25));
      a.sweep();
      b.sweep();
      await _settle();
      expect(lan.frames.length, before + 2, reason: 'each said a word to keep the link');
      expect([a.links.length, b.links.length], [1, 1]);
      // Ben's device goes without a word (its wires are left as they are: the fake network closes nothing by itself).
      clock = clock.add(const Duration(seconds: 61));
      a.sweep();
      await _settle();
      expect(a.links, isEmpty, reason: 'nothing heard for a minute');
      expect(a.seen, 0, reason: 'not heard from in thirty seconds, and no link');
      expect(a.reaches(benPeer), isFalse);
    });

    test('stopped, it closes everything and says nothing; started again it is a new run', () async {
      await meet();
      final first = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.10').bytes)!.instance;
      await a.stop();
      await _settle();
      expect([a.state.value, a.links, a.seen], [CarrierState.off, isEmpty, 0]);
      await _until(() => b.links.isEmpty, 'the other end saw it go');
      final said = lan.beacons.length;
      await a.beat();
      expect(lan.beacons.length, said, reason: 'nothing said while off');
      await a.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked again');
      final again = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!.instance;
      expect(again, isNot(first));
    });
  });

  group('who links with whom', () {
    test('a stranger on the network finds nobody, is found by nobody, and its knock is closed without a word', () async {
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final a = device(ann, '192.168.1.10', () => [benPeer]);
      final b = device(ben, '192.168.1.11', () => [annPeer]);
      // Cat has the app and is friends with neither: she marks a friend of her own.
      final c = device(cat, '192.168.1.12', () => [Peer(id: NetKeys.generate().id, key: NetCrypto.randomBytes(32))]);
      await a.start();
      await b.start();
      await c.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'the two friends link');
      await _settle();
      expect([c.seen, c.links], [0, isEmpty]);
      expect(a.links.map((l) => l.peer), [ben.id]);
      // She connects to Ann's door all the same, with a knock made from a key of her own.
      final door = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.10').bytes)!;
      final hers = lan.join('192.168.1.13');
      final wire = await hers.dial('192.168.1.10', door.port) as FakeLanWire;
      final heard = <Uint8List>[];
      final done = Completer<void>();
      wire.frames.listen(heard.add, onDone: done.complete);
      final nonce = List.filled(16, 3), run = List.filled(8, 4);
      final bucket = LanWords.bucketOf(clock.millisecondsSinceEpoch);
      wire.send(Uint8List.fromList([1, ...run, ...nonce, (bucket >> 24) & 0xff, (bucket >> 16) & 0xff, (bucket >> 8) & 0xff, bucket & 0xff, ...LanWords.knock(NetCrypto.randomBytes(32), from: ben.id, to: ann.id, dialer: run, listener: door.instance, nonce: nonce, bucket: bucket)]));
      await done.future.timeout(const Duration(seconds: 5));
      expect(heard, isEmpty, reason: 'closed without a word: not even that a knock was wrong');
      expect(a.links.map((l) => l.peer), [ben.id]);
    });

    test('a knock replayed from another address, to another run, or in another ten minutes opens nothing', () async {
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final a = device(ann, '192.168.1.10', () => [benPeer], run: 1);
      final b = device(ben, '192.168.1.11', () => [annPeer], run: 2);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      // What the one who connected said first, as someone on the network took it down.
      final knock = lan.frames.firstWhere((f) => f[0] == 1);
      final dialed = lan.wires.first.$1.address;
      final door = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == dialed).bytes)!;
      final other = lan.join('192.168.1.66');
      final wire = await other.dial(dialed, door.port) as FakeLanWire;
      final heard = <Uint8List>[];
      wire.frames.listen(heard.add);
      wire.send(knock);
      // It is answered (the knock is real), and the answer is no use: the proof it asks for needs the key.
      await _until(() => heard.isNotEmpty, 'the knock was answered');
      expect(heard, hasLength(1));
      expect(heard.single[0], 2);
      wire.send(Uint8List.fromList([3, ...List.filled(32, 0)]));
      await _until(() => wire.closed, 'closed on a proof that is not one');
      final target = dialed == '192.168.1.10' ? a : b;
      expect(target.links, hasLength(1), reason: 'only the real link');
      // The same knock eleven minutes on: not answered at all.
      clock = clock.add(const Duration(minutes: 21));
      final late = await other.dial(dialed, door.port) as FakeLanWire;
      final lateHeard = <Uint8List>[];
      late.frames.listen(lateHeard.add);
      late.send(knock);
      await _until(() => late.closed, 'closed');
      expect(lateHeard, isEmpty);
    });

    test('two devices of one account don\'t take each other for the friend whose key they both hold', () async {
      final benPeer = Peer(id: ben.id, key: annBen);
      // Both are Ann's, both friends with Ben, and neither was given the account's own key.
      final one = device(ann, '192.168.1.10', () => [benPeer]);
      final two = device(ann, '192.168.1.14', () => [benPeer]);
      await one.start();
      await two.start();
      await one.beat();
      await two.beat();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();
      expect([one.seen, two.seen, one.links, two.links], [0, 0, isEmpty, isEmpty]);
    });

    test('an account\'s own devices link under its own key, and what one sends its own name reaches the other', () async {
      final own = Peer(id: ann.id, key: annsOwn);
      final phone = device(ann, '192.168.1.10', () => [own]);
      final mac = device(ann, '192.168.1.14', () => [own]);
      await phone.start();
      await mac.start();
      await _until(() => phone.links.length == 1 && mac.links.length == 1, 'linked');
      expect([phone.links.single.peer, phone.linkedToSomeone], [ann.id, false], reason: 'its own device is nobody else');
      final atMac = <Arrived>[];
      mac.arrived.listen(atMac.add);
      await phone.send(own, Uint8List.fromList([5, 5]));
      await _until(() => atMac.length == 1, 'the copy came');
      expect([atMac.single.from, atMac.single.bytes], [ann.id, [5, 5]]);
    });

    test('Invisible says it is here to its own devices alone, and lets go of every link to anyone else', () async {
      final own = Peer(id: ann.id, key: annsOwn), annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final phone = device(ann, '192.168.1.10', () => [benPeer, own]);
      final mac = device(ann, '192.168.1.14', () => [benPeer, own]);
      final b = device(ben, '192.168.1.11', () => [annPeer]);
      await phone.start();
      await mac.start();
      await b.start();
      await _until(() => phone.links.length == 2 && b.links.length == 2, 'the phone is linked to its Mac and to Ben');
      phone.setMode('invisible');
      await _until(() => phone.links.length == 1 && phone.links.single.peer == ann.id, 'only its own device is left');
      await _until(() => b.links.length == 1, 'Ben\'s device saw the phone go');
      // Ben's device still hears the phone's beacon, and nothing in it is for him now.
      clock = clock.add(const Duration(seconds: 31));
      b.sweep();
      await phone.beat();
      await b.beat();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();
      expect(b.links.map((l) => l.address), ['192.168.1.14'], reason: 'the Mac, which is not Invisible, and not the phone');
      expect(phone.reaches(benPeer), isFalse);
      // Shown again, they find each other again.
      phone.setMode('online');
      await _until(() => phone.links.length == 2 && b.links.length == 2, 'linked again');
    });

    test('someone who is a friend no longer is let go of, and no longer marked', () async {
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      var friends = [benPeer];
      final a = device(ann, '192.168.1.10', () => friends);
      final b = device(ben, '192.168.1.11', () => [annPeer]);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      friends = [];
      a.refresh();
      await _until(() => a.links.isEmpty && b.links.isEmpty, 'let go');
      await b.beat();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();
      expect([a.seen, a.links, b.links], [0, isEmpty, isEmpty], reason: 'Ben\'s knock, if he makes one, is nobody\'s to Ann\'s device now');
    });

    test('only a home or office network is heard or answered: the same beacon from an address on the internet is nothing', () async {
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final a = LanCarrier(me: ann.id, ground: lan.join('192.168.1.10'), people: () => [benPeer], policy: _quick, now: () => clock, random: Random(1));
      final b = LanCarrier(me: ben.id, ground: lan.join('203.0.113.9'), people: () => [annPeer], policy: _quick, now: () => clock, random: Random(2));
      made.addAll([a, b]);
      await a.start();
      await b.start();
      await a.beat();
      await b.beat();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();
      expect([a.seen, a.links], [0, isEmpty], reason: 'Ann\'s device hears nothing from 203.0.113.9 and takes no connection from it');
    });
  });

  group('how it stands', () {
    test('a port it can\'t have is said, and tried again; a network it can\'t speak on is said, and clears when it can', () async {
      final benPeer = Peer(id: ben.id, key: annBen);
      final ground = lan.join('192.168.1.10')..noAir = true;
      final a = LanCarrier(me: ann.id, ground: ground, people: () => [benPeer], policy: _quick, now: () => clock, random: Random(1));
      made.add(a);
      await a.start();
      expect(a.state.value, CarrierState.down);
      expect(a.problem, contains('can\'t be used on this device now'));
      expect(a.reaches(benPeer), isFalse);
      ground.noAir = false;
      await _until(() => a.state.value == CarrierState.up, 'tried again by itself');
      expect(a.problem, isNull);
      ground.mute = true;
      await a.beat();
      expect(a.state.value, CarrierState.down);
      expect(a.problem, contains('Nothing can be said on the local network now'));
      ground.mute = false;
      await a.beat();
      expect([a.state.value, a.problem], [CarrierState.up, null]);
      // A device that can't say its own beacon, and is heard and connected to all the same, carries: it is not down
      // while a link is open, and is again once the link has gone.
      ground.mute = true;
      await a.beat();
      expect(a.state.value, CarrierState.down);
      final b = device(ben, '192.168.1.11', () => [Peer(id: ann.id, key: annBen)]);
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked: hers heard his');
      expect([a.state.value, a.problem], [CarrierState.up, null]);
      await a.beat();
      expect([a.state.value, a.problem], [CarrierState.up, null], reason: 'still, with its next beacon unsaid');
      await b.stop();
      await _until(() => a.links.isEmpty, 'his is gone');
      await a.beat();
      expect(a.state.value, CarrierState.down);
    });

    test('a phone\'s closes everything while the app is put away and opens again as it comes back; a computer\'s stays', () async {
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final phone = device(ann, '192.168.1.10', () => [benPeer], policy: const LanPolicy(beatEvery: Duration(hours: 1), sweepEvery: Duration(hours: 1), yieldFor: Duration(milliseconds: 30)));
      final desk = device(ben, '192.168.1.11', () => [annPeer]);
      await phone.start();
      await desk.start();
      await _until(() => phone.links.length == 1 && desk.links.length == 1, 'linked');
      phone.setAway(true);
      await _until(() => phone.links.isEmpty && desk.links.isEmpty, 'closed');
      final said = lan.beacons.where((x) => x.from == '192.168.1.10').length;
      await phone.beat();
      expect(lan.beacons.where((x) => x.from == '192.168.1.10').length, said, reason: 'nothing said while put away');
      expect(phone.state.value, CarrierState.connecting, reason: 'wanted, and waiting for the app');
      desk.setAway(true);
      await desk.beat();
      expect(desk.state.value, CarrierState.up, reason: 'a computer\'s is never put away');
      phone.setAway(false);
      await _until(() => phone.links.length == 1 && desk.links.length == 1, 'linked again');
    });

    test('more people than a beacon holds: one lot of them for each ten minutes, the same all through it, and everyone in turn', () async {
      final many = [for (var i = 0; i < 200; i++) Peer(id: NetCrypto.hex(NetCrypto.randomBytes(16)), key: NetCrypto.randomBytes(32))];
      final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
      final a = device(ann, '192.168.1.10', () => [...many, benPeer], run: 9);
      // Only Ann's beacons are heard: whether Ben's device finds hers is whether her beacon names him.
      lan.deafTo.add('192.168.1.10');
      final b = device(ben, '192.168.1.11', () => [annPeer], run: 1);
      await a.start();
      await b.start();
      await _settle();
      Set<String> marksNow() => {for (final m in LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!.marks) NetCrypto.hex(m)};
      final first = marksNow();
      expect(first, hasLength(LanBeacon.mostMarks));
      await a.beat();
      expect(marksNow(), first, reason: 'the same lot all through the ten minutes: what stays from one beacon to the next says nothing of who is real');
      // Ben is named in this ten minutes or the next: 201 people, 160 to a lot.
      for (var i = 0; i < 2 && b.links.isEmpty; i++) {
        await _settle();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (b.links.isNotEmpty) break;
        clock = clock.add(const Duration(minutes: 10));
        await a.beat();
        await b.beat();
      }
      await _until(() => b.links.length == 1, 'found within two lots');
    });
  });

  group('under the switchboard', () {
    final book = <String, Map<String, Peer>>{};
    Switchboard board(NetKeys who, List<Carrier> routes) => Switchboard(me: who.id, peers: _Book(book[who.id]!), carriers: routes);

    test('with no other route, what is sent goes by the local network and is answered; which route carried it is kept', () async {
      book[ann.id] = {ben.id: Peer(id: ben.id, key: annBen, name: 'Ben')};
      book[ben.id] = {ann.id: Peer(id: ann.id, key: annBen, name: 'Ann')};
      final a = device(ann, '192.168.1.10', () => book[ann.id]!.values.toList());
      final b = device(ben, '192.168.1.11', () => book[ben.id]!.values.toList());
      final ab = board(ann, [a]), bb = board(ben, [b]);
      await ab.start();
      await bb.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      final got = <Received>[];
      bb.received.listen(got.add);
      final d = await ab.send(book[ann.id]![ben.id]!, Envelope(kind: 'text', body: {'w': 'are you on the wifi?'}));
      expect([d.via, d.handed, d.acked], ['lan', Handed.passed, true]);
      expect(got.single.via, 'lan');
      expect(got.single.envelope.body['w'], 'are you on the wifi?');
      expect(ab.used[ben.id]!.sentBy, 'lan');
      expect(bb.used[ann.id]!.cameBy, 'lan');
      await ab.dispose();
      await bb.dispose();
    });

    test('where the relay only kept it and they are on this network, it goes by the link too, and nothing is dialled for someone who is not', () async {
      book[ann.id] = {ben.id: Peer(id: ben.id, key: annBen), cat.id: Peer(id: cat.id, key: pair(ann, cat))};
      book[ben.id] = {ann.id: Peer(id: ann.id, key: annBen)};
      final a = device(ann, '192.168.1.10', () => book[ann.id]!.values.toList());
      final b = device(ben, '192.168.1.11', () => book[ben.id]!.values.toList());
      final hub = _Keeps();
      final ab = board(ann, [hub, a]), bb = board(ben, [b]);
      await ab.start();
      await bb.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      final got = <Received>[];
      bb.received.listen(got.add);
      final d = await ab.send(book[ann.id]![ben.id]!, Envelope(kind: 'text', body: {'w': 'kept, and here'}));
      expect([d.via, d.handed], ['hub', Handed.held], reason: 'the relay kept it: that is what the sender is told');
      expect(d.tried, ['hub', 'lan']);
      await _until(() => got.length == 1, 'and it came by the link meanwhile');
      expect(got.single.via, 'lan');
      // Cat is on no network of Ann's: kept by the relay, and nothing more.
      final wires = lan.wires.length;
      final c = await ab.send(book[ann.id]![cat.id]!, Envelope(kind: 'text', body: {'w': 'later'}));
      expect([c.via, c.handed, c.tried], ['hub', Handed.held, ['hub']]);
      expect(lan.wires.length, wires);
      await ab.dispose();
      await bb.dispose();
    });
  });

  test('over this machine\'s own sockets: two copies find each other, link and carry a packet', () async {
    final loop = InternetAddress.loopbackIPv4;
    // Two ports nobody holds, found by asking for them.
    Future<int> free() async {
      final s = await RawDatagramSocket.bind(loop, 0);
      final p = s.port;
      s.close();
      return p;
    }

    final pa = await free(), pb = await free();
    final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
    const policy = LanPolicy(beatEvery: Duration(milliseconds: 100), yieldFor: Duration(milliseconds: 100), sleepsAway: false);
    final a = LanCarrier(me: ann.id, ground: LanSockets(port: pa, sayPort: pb, bind: loop, beaconTo: [loop], local: const ['127.0.0.1']), people: () => [benPeer], policy: policy, allowed: (x) => x == '127.0.0.1');
    final b = LanCarrier(me: ben.id, ground: LanSockets(port: pb, sayPort: pa, bind: loop, beaconTo: [loop], local: const ['127.0.0.1']), people: () => [annPeer], policy: policy, allowed: (x) => x == '127.0.0.1');
    made.addAll([a, b]);
    await a.start();
    await b.start();
    expect([a.state.value, b.state.value], [CarrierState.up, CarrierState.up], reason: '${a.problem} ${b.problem}');
    await _until(() => a.links.length == 1 && b.links.length == 1, 'linked over UDP and TCP on this machine');
    final atB = <Arrived>[];
    b.arrived.listen(atB.add);
    final packet = Uint8List.fromList(List.generate(LanCarrier.maxPacket, (i) => (i * 31) % 256));
    expect(await a.send(benPeer, packet), Handed.passed);
    await _until(() => atB.length == 1, 'the longest packet came whole');
    expect(listEquals(atB.single.bytes, packet), isTrue);
    expect(atB.single.from, ann.id);
    await a.stop();
    await _until(() => b.links.isEmpty, 'the other end saw the connection close');
  });
}

class _Book implements PeerBook {
  _Book(this.peers);
  final Map<String, Peer> peers;
  @override
  Peer? byId(String id) => peers[id];
}

/// A relay that is up and reaches everyone, and only ever keeps what it is given: they are all away from it.
class _Keeps implements Carrier {
  @override
  String get id => 'hub';
  @override
  String get name => 'Relay server';
  @override
  String get about => '';
  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: 60 * 1024, ackWait: Duration(milliseconds: 100));
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;
  @override
  Stream<Arrived> get arrived => const Stream.empty();
  @override
  Future<void> start() async => state.value = CarrierState.up;
  @override
  Future<void> stop() async => state.value = CarrierState.off;
  @override
  bool reaches(Peer peer) => true;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async => Handed.held;
}
