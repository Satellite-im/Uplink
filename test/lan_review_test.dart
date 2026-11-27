import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/lan/lan_carrier.dart';
import 'package:ghost_messaging/net/lan/lan_wire.dart';
import 'package:ghost_messaging/net/lan/lan_words.dart';

import 'support/fake_lan.dart';

/// What an independent review of the local network route found (2026-11-26, of the route as 0.12.41 shipped it,
/// switched off), each as the test that failed then: what a stranger on the network, and a friend whose device was
/// made to misbehave, could make the route believe, say or do. The handshake and the sealing held; what was around
/// them did not. Over real sockets: test/lan_sockets_test.dart.
///
/// Eve is a stranger: she holds no key, and uses only what was said to everyone and doors of her own. Mal is a real
/// friend of Ben's (he holds the key the two seal with) whose device means harm.

Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await pumpEventQueue(times: 30);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// Beacons and sweeps by hand, and everything else quick.
const _quick = LanPolicy(
  beatEvery: Duration(hours: 1),
  sweepEvery: Duration(hours: 1),
  yieldFor: Duration(milliseconds: 30),
  proveFor: Duration(milliseconds: 400),
  dialFor: Duration(milliseconds: 400),
  redialAfter: Duration(milliseconds: 1),
  sleepsAway: false,
);

/// The route's own times, but for beacons and sweeps.
const _real = LanPolicy(beatEvery: Duration(hours: 1), sweepEvery: Duration(hours: 1), sleepsAway: false);

List<int> _n32(int n) => [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

/// The name of the run a route given `Random(seed)` opens with (the first eight bytes it draws).
String _runOf(int seed) {
  final r = Random(seed);
  return NetCrypto.hex(List.generate(8, (_) => r.nextInt(256)));
}

Peer _someone() => Peer(id: NetCrypto.hex(NetCrypto.randomBytes(16)), key: NetCrypto.randomBytes(32));

/// The marks of the last beacon [address] said.
Set<String> _marks(FakeLan lan, String address) => {for (final m in LanBeacon.decode(lan.beacons.lastWhere((b) => b.from == address).bytes)!.marks) NetCrypto.hex(m)};

/// A door of the stranger's at [port] on her own address: doors are opened until one has that port (the network in
/// memory hands ports out in order from 40000, as it did to the device whose beacon is said again).
Future<void> _doorAt(FakeLanGround g, int port, void Function(LanWire) came) async {
  for (var i = 0; i < 64; i++) {
    final d = await g.door(came);
    if (d.port == port) return;
    await d.close();
  }
  fail('no door at $port');
}

/// Connects from [from] to the door at [address]:[port] and proves to be [me] to [them]'s device, as the route's own
/// dialler does, saying its run is [myRun]. The wire, once the other end has what it needs to hold the link.
Future<FakeLanWire> _link(FakeLanGround from, String address, int port, {required List<int> key, required String me, required String them, required List<int> myRun, required List<int> theirRun, required int bucket, required Random random}) async {
  final wire = await from.dial(address, port) as FakeLanWire;
  final frames = StreamIterator(wire.frames);
  final nonce = List.generate(16, (_) => random.nextInt(256));
  wire.send(Uint8List.fromList([1, ...myRun, ...nonce, ..._n32(bucket), ...LanWords.knock(key, from: me, to: them, dialer: myRun, listener: theirRun, nonce: nonce, bucket: bucket)]));
  expect(await frames.moveNext().timeout(const Duration(seconds: 2)), isTrue, reason: 'the knock was answered');
  final answer = frames.current;
  expect(answer[0], 2);
  final transcript = LanWords.transcript(dialerAccount: me, listenerAccount: them, dialer: myRun, listener: theirRun, dialerNonce: nonce, listenerNonce: answer.sublist(1, 17));
  wire.send(Uint8List.fromList([3, ...LanWords.proof(key, transcript, dialing: true)]));
  return wire;
}

/// A network that notes where the route connects to, and can hold a connection back for as long as the test says
/// ([hold]): a real one's take a moment to make too. Otherwise it is [inner].
class _Watched implements LanGround {
  _Watched(this.inner);
  final LanGround inner;
  final List<String> dialled = [];
  Completer<void>? hold;

  @override
  Future<List<String>> addresses() => inner.addresses();
  @override
  Future<LanAir> air(void Function(Uint8List bytes, String address) heard, {void Function()? lost}) => inner.air(heard, lost: lost);
  @override
  Future<LanDoor> door(void Function(LanWire wire) came) => inner.door(came);
  @override
  Future<LanWire> dial(String address, int port, {Duration timeout = const Duration(seconds: 3)}) async {
    dialled.add('$address:$port');
    await hold?.future;
    return inner.dial(address, port, timeout: timeout);
  }
}

void main() {
  final ann = NetKeys.generate(), ben = NetKeys.generate(), mal = NetKeys.generate();
  Uint8List pair(NetKeys a, NetKeys b) => NetCrypto.netKey(NetCrypto.conversationKey(a, b.public)!);
  final annBen = pair(ann, ben), malBen = pair(mal, ben);
  final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen), malPeer = Peer(id: mal.id, key: malBen);
  var clock = DateTime.utc(2026, 11, 26, 12, 1);
  int bucket() => LanWords.bucketOf(clock.millisecondsSinceEpoch);
  final made = <LanCarrier>[];

  LanCarrier device(NetKeys who, LanGround ground, List<Peer> Function() people, {required int seed, LanPolicy policy = _quick}) {
    final c = LanCarrier(me: who.id, ground: ground, people: people, policy: policy, now: () => clock, random: Random(seed));
    made.add(c);
    return c;
  }

  setUp(() => clock = DateTime.utc(2026, 11, 26, 12, 1));

  tearDown(() async {
    for (final c in made) {
      await c.dispose();
    }
    made.clear();
  });

  group('a beacon said again by someone else (finding 2)', () {
    test('a stranger who says a friend\'s beacon again from her own address is not taken for the friend, and is not connected to', () async {
      final lan = FakeLan();
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1);
      await a.start();
      await _settle();
      // What Ann's device said to everyone, as anyone on the network heard it. Then Ann goes home.
      final said = lan.beacons.lastWhere((b) => b.from == '192.168.1.10').bytes;
      await a.stop();

      // The stranger: no key, a door at the port the beacon names.
      final eve = lan.join('192.168.1.66');
      final cameToEve = <LanWire>[];
      final firstFrames = <Uint8List>[];
      await _doorAt(eve, LanBeacon.decode(said)!.port, (w) {
        cameToEve.add(w);
        w.frames.listen(firstFrames.add);
      });

      // Ben's device comes onto the network after Ann's has left, and hears only the stranger.
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
      await b.start();
      await _settle();
      expect([b.seen, b.reaches(annPeer)], [0, false], reason: 'Ann\'s device is not here');
      eve.say(said);
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _settle();

      final knocked = firstFrames.where((f) => f.length == 45 && f[0] == 1).length;
      expect(
        [b.seen, b.reaches(annPeer), cameToEve.map((w) => w.address).toList(), knocked],
        [0, false, isEmpty, 0],
        reason: 'Ben\'s device took the stranger at 192.168.1.66 for Ann\'s and connected to her with a knock: the stranger would know that the device at 192.168.1.11 is one of the people of the device that said that beacon',
      );
    });

    test('a stranger cannot put herself between two friends: each is linked at the other\'s own address', () async {
      // Ben's run has the lesser name, so it is Ben's device that would connect at once to wherever it believed Ann's is.
      const benSeed = 100;
      final annSeed = [for (var s = 1; s < 50; s++) s].firstWhere((s) => _runOf(s).compareTo(_runOf(benSeed)) > 0);

      final lan = FakeLan();
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: annSeed);
      await a.start();
      await _settle();
      final said = lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes;
      final annsDoor = LanBeacon.decode(said)!.port;

      // The stranger passes on whatever comes to her door to Ann's real door, and back: she holds no key and changes
      // nothing.
      final eve = lan.join('192.168.1.66');
      var piped = 0;
      await _doorAt(eve, annsDoor, (w) async {
        final out = await eve.dial('192.168.1.10', annsDoor);
        w.frames.listen((f) {
          piped++;
          out.send(f);
        }, onDone: out.close);
        out.frames.listen((f) {
          piped++;
          w.send(f);
        }, onDone: w.close);
      });

      // Ben's device joins; the stranger says Ann's beacon again before Ann's next one.
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: benSeed);
      await b.start();
      eve.say(said);
      await _until(() => a.links.length == 1 && b.links.length == 1, 'the two are linked');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final atA = <Arrived>[];
      a.arrived.listen(atA.add);
      await b.send(annPeer, Uint8List.fromList([7, 7, 7]));
      await _until(() => atA.length == 1, 'it came');
      expect(atA.single.from, ben.id);
      expect(
        [b.links.single.address, a.links.single.address, piped],
        ['192.168.1.10', '192.168.1.11', 0],
        reason: 'both ends were linked to 192.168.1.66 and every frame passed through the stranger, who could time, count, delay and drop them; Settings › Routes named her address as the friend\'s',
      );
    });

    test('a device that is linked, or was heard a moment ago, is not moved to wherever a beacon says it is now', () async {
      final lan = FakeLan();
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      // Mal is no friend of Ann's here, but suppose a second device of Ben's own account (it holds the key) says it is
      // Ann's run at another address: a mark only a holder of the key could make, for the address it is said from.
      final anns = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.10').bytes)!;
      final elsewhere = lan.join('192.168.1.77');
      final mark = LanWords.mark(LanWords.keyOf(annBen), from: ann.id, to: ben.id, bucket: bucket(), instance: anns.instance, port: 40123, address: '192.168.1.77')!;
      elsewhere.say(LanBeacon(instance: anns.instance, port: 40123, bucket: bucket(), marks: [mark]).encode());
      await _settle();
      expect([b.links.single.address, b.seen], ['192.168.1.10', 1], reason: 'where it is linked is where it is');
    });
  });

  group('what the marks say to a stranger (finding 3)', () {
    test('a stranger who hears two beacons cannot count the people a device marks', () async {
      final lan = FakeLan();
      // Three friends and the account's own devices: four real marks among eight.
      final people = [_someone(), _someone(), _someone(), Peer(id: ann.id, key: NetCrypto.randomBytes(32))];
      final a = device(ann, lan.join('192.168.1.10'), () => people, seed: 1, policy: _real);
      await a.start();
      await a.beat();
      final first = _marks(lan, '192.168.1.10');
      await a.beat();
      final second = _marks(lan, '192.168.1.10');
      expect([first.length, second.length], [8, 8]);
      expect(first.intersection(second).length, 8, reason: 'the marks in both beacons were exactly the real ones: the stranger had counted ${people.length} people');
      // The next ten minutes, every one of them is another: nothing to follow a device by from one to the next.
      clock = clock.add(const Duration(minutes: 10));
      await a.beat();
      expect(_marks(lan, '192.168.1.10').intersection(first), isEmpty);
    });

    test('a stranger cannot tell from the marks that the person went Invisible', () async {
      final lan = FakeLan();
      final people = [_someone(), _someone(), _someone(), Peer(id: ann.id, key: NetCrypto.randomBytes(32))];
      final a = device(ann, lan.join('192.168.1.10'), () => people, seed: 1, policy: _real);
      await a.start();
      Future<int> counted() async {
        await a.beat();
        final first = _marks(lan, '192.168.1.10');
        await a.beat();
        return first.intersection(_marks(lan, '192.168.1.10')).length;
      }

      final shown = await counted();
      final before = lan.beacons.length;
      a.setMode('invisible');
      await _settle();
      final hidden = await counted();
      expect(lan.beacons.length, greaterThan(before), reason: 'it says it is here still, to its own devices');
      expect([_marks(lan, '192.168.1.10').length, hidden], [8, shown], reason: 'shown, $shown marks stayed from one beacon to the next; Invisible, $hidden: the network saw the moment the person hid');
    });

    test('with more people than the first size of beacon holds, what is said in turn does not add up to the count', () async {
      final lan = FakeLan();
      final people = [for (var i = 0; i < 100; i++) _someone(), Peer(id: ann.id, key: NetCrypto.randomBytes(32))];
      final a = device(ann, lan.join('192.168.1.10'), () => people, seed: 1, policy: _real);
      await a.start();
      final seen = <String, int>{};
      for (var i = 0; i < 12; i++) {
        await a.beat();
        for (final m in _marks(lan, '192.168.1.10')) {
          seen[m] = (seen[m] ?? 0) + 1;
        }
      }
      // Every mark said more than once in one ten minutes was a real one.
      expect(seen.values.where((n) => n > 1).length, 128, reason: 'a minute of beacons gave the stranger the exact count: ${people.length}');
    });
  });

  group('limits that were shared, or were not there (findings 4 and 5)', () {
    test('one friend cannot close another friend\'s link by saying her run\'s name is his', () async {
      final lan = FakeLan();
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer, malPeer], seed: 2);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'Ann and Ben are linked');
      expect(b.linked(annPeer), isTrue);

      // What everyone on the network heard: Ann's run's name, and Ben's with his door's port.
      final annsRun = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.10').bytes)!.instance;
      final bens = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.11').bytes)!;

      // Mal's device connects to Ben's twice, proving to be Mal's (it is), and saying its run is Ann's.
      final mals = lan.join('192.168.1.13');
      final random = Random(9);
      for (var i = 0; i < 2; i++) {
        await _link(mals, '192.168.1.11', bens.port, key: LanWords.keyOf(malBen), me: mal.id, them: ben.id, myRun: annsRun, theirRun: bens.instance, bucket: bucket(), random: random);
        await _settle();
      }
      expect(
        [b.linked(annPeer), a.links.length, b.links.map((l) => l.peer == ann.id ? 'Ann' : 'Mal').toSet()],
        [true, 1, {'Ann', 'Mal'}],
        reason: 'Ben\'s device let go of its link to Ann\'s to make room for Mal\'s second: Ann\'s was "the oldest link with that run"',
      );
    });

    test('one friend\'s devices hold no more than a few links, however many runs they say they are', () async {
      final lan = FakeLan();
      final b = device(ben, lan.join('192.168.1.11'), () => [malPeer], seed: 2);
      await b.start();
      await _settle();
      final bens = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.11').bytes)!;
      final random = Random(9);
      // Twelve knocks a minute are taken from one address: so five addresses of the one device, as anyone on a network
      // can have.
      final held = <FakeLanWire>[];
      for (var address = 0; address < 5; address++) {
        final mals = lan.join('192.168.1.${60 + address}');
        for (var i = 0; i < LanCarrier.knocksAMinute; i++) {
          final run = List.generate(8, (_) => random.nextInt(256));
          held.add(await _link(mals, '192.168.1.11', bens.port, key: LanWords.keyOf(malBen), me: mal.id, them: ben.id, myRun: run, theirRun: bens.instance, bucket: bucket(), random: random));
          await _settle();
        }
      }
      await _settle();
      expect([held.where((w) => !w.closed).length, b.links.length], [LanCarrier.mostPerAccount, LanCarrier.mostPerAccount], reason: 'Ben\'s device held sixty proved links (a socket each) with one friend');
    });

    for (final flood in [false, true]) {
      test(flood ? 'a stranger\'s beacons cannot keep two friends from finding each other' : 'with no stranger, the same two find each other', () async {
        final lan = FakeLan();
        final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1);
        final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
        final eve = lan.join('192.168.1.66');
        final random = Random(5);
        // Each a beacon of a run nobody has, eight marks of nothing: no key, no connection.
        void junk(int n) {
          for (var i = 0; flood && i < n; i++) {
            eve.say(LanBeacon(
              instance: Uint8List.fromList(List.generate(8, (_) => random.nextInt(256))),
              port: 40000 + random.nextInt(1000),
              bucket: bucket(),
              marks: [for (var m = 0; m < 8; m++) Uint8List.fromList(List.generate(8, (_) => random.nextInt(256)))],
            ).encode());
          }
        }

        await a.start();
        junk(LanCarrier.runsAtOnce);
        await _settle();
        await b.start();
        junk(LanCarrier.runsAtOnce);
        await _settle();
        // Each says it is here again, three times, as it does every five seconds.
        for (var i = 0; i < 3; i++) {
          clock = clock.add(const Duration(seconds: 5));
          await a.beat();
          await b.beat();
          junk(LanCarrier.runsAtOnce);
          await _settle();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        expect([a.seen, b.seen, a.links.length, b.links.length], [1, 1, 1, 1], reason: 'the runs whose marks are looked at in a minute were all spent on the stranger\'s: neither friend\'s beacon was looked at');
      });
    }

    test('a device already found goes on being heard through any number of strangers\' beacons, from wherever they say they are', () async {
      final lan = FakeLan();
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
      await b.start();
      await _settle();
      // Ann's device, said by hand: a run and a door nothing answers at, so Ben's device can only go on hearing it (a
      // link, once made, is kept whatever is heard).
      final anns = lan.join('192.168.1.10');
      final run = Uint8List.fromList(List.generate(8, (i) => 0xF0 + i));
      void annSays() {
        final mark = LanWords.mark(LanWords.keyOf(annBen), from: ann.id, to: ben.id, bucket: bucket(), instance: run, port: 41000, address: '192.168.1.10')!;
        anns.say(LanBeacon(instance: run, port: 41000, bucket: bucket(), marks: [mark, for (var m = 0; m < 7; m++) NetCrypto.randomBytes(8)]).encode());
      }

      annSays();
      await _settle();
      expect([b.reaches(annPeer), b.seen, b.links], [true, 1, isEmpty], reason: 'found');
      final eve = lan.join('192.168.1.66');
      final random = Random(5);
      // A minute of it: each second a thousand beacons of new runs, each from another address on the network (a
      // datagram's sender writes what it likes), and every five seconds Ann's own.
      for (var second = 1; second <= 60; second++) {
        clock = clock.add(const Duration(seconds: 1));
        for (var i = 0; i < 1000; i++) {
          eve.say(
            LanBeacon(instance: Uint8List.fromList(List.generate(8, (_) => random.nextInt(256))), port: 40000 + random.nextInt(1000), bucket: bucket(), marks: [for (var m = 0; m < 8; m++) Uint8List.fromList(List.generate(8, (_) => random.nextInt(256)))]).encode(),
            from: '192.168.${random.nextInt(256)}.${1 + random.nextInt(250)}',
          );
        }
        if (second % 5 == 0) annSays();
        await pumpEventQueue(times: 5);
        if (second % 10 == 0) b.sweep();
      }
      expect([b.reaches(annPeer), b.seen, b.droppedBeacons > 0], [true, 1, true], reason: 'Ann\'s device, there all along, was lost among the strangers');
      // And gone quiet, it is forgotten as ever.
      clock = clock.add(const Duration(seconds: 31));
      b.sweep();
      expect([b.reaches(annPeer), b.seen], [false, 0]);
    });

    test('a friend\'s device cannot send this one connecting wherever it likes', () async {
      final lan = FakeLan();
      final notes = _Watched(lan.join('192.168.1.11'));
      final b = device(ben, notes, () => [malPeer], seed: 2);
      await b.start();
      await _settle();
      // Mal's device says beacons of runs that are nowhere, each with a real mark for Ben (it holds the key) made for
      // the address it is said from, a door's port of its choosing, and from an address of its choosing.
      final key = LanWords.keyOf(malBen);
      final random = Random(9);
      final wanted = <String>[];
      void say(String address, int port) {
        // A run whose name is greater than any of Ben's device's: Ben's connects at once.
        final run = [0xff, 0xff, ...List.generate(6, (_) => random.nextInt(256))];
        final mark = LanWords.mark(key, from: mal.id, to: ben.id, bucket: bucket(), instance: run, port: port, address: address)!;
        lan.join(address).say(LanBeacon(instance: Uint8List.fromList(run), port: port, bucket: bucket(), marks: [mark]).encode());
        wanted.add('$address:$port');
      }

      // Anywhere at all: other networks, and the one machine everyone on this one has (its router).
      for (var i = 0; i < 100; i++) {
        say(i.isEven ? '10.${random.nextInt(256)}.${random.nextInt(256)}.${1 + random.nextInt(250)}' : '192.168.1.1', [22, 80, 443, 445, 3389, 5900, 8080][i % 7] + i);
      }
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(notes.dialled.where((d) => !d.startsWith('192.168.')), isEmpty, reason: 'it connected to another network than its own');
      expect(wanted.where(notes.dialled.contains).length, lessThanOrEqualTo(LanCarrier.dialsAMinuteTo), reason: 'Ben\'s device connected wherever Mal\'s named, in under a second (e.g. ${notes.dialled.take(3).join(', ')}), and said a knock to whatever answered');

      // And every address of Ben's own network in turn, as fast as it likes.
      notes.dialled.clear();
      for (var i = 0; i < 400; i++) {
        say('192.168.${2 + i ~/ 200}.${1 + i % 200}', 8000 + i);
      }
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(notes.dialled.length, lessThanOrEqualTo(LanCarrier.dialsAtOnce), reason: 'a sweep of the whole network through this device\'s address');
      expect(b.seen, lessThanOrEqualTo(LanCarrier.mostSeenOf), reason: 'and a device kept for every one of them');
    });

    test('strangers who connect and say nothing cannot keep two friends from linking', () async {
      final lan = FakeLan();
      const policy = LanPolicy(beatEvery: Duration(hours: 1), sweepEvery: Duration(hours: 1), yieldFor: Duration(milliseconds: 30), proveFor: Duration(seconds: 5), dialFor: Duration(milliseconds: 400), redialAfter: Duration(milliseconds: 1), sleepsAway: false);
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1, policy: policy);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2, policy: policy);
      // Each alone on the network for a moment, so the stranger has heard where each one's door is.
      lan.deaf = true;
      await a.start();
      await b.start();
      await _settle();
      final anns = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.10').bytes)!, bens = LanBeacon.decode(lan.beacons.firstWhere((x) => x.from == '192.168.1.11').bytes)!;
      // Six addresses, four connections each to each door, with nothing said on any: more than a door holds for strangers.
      final held = <LanWire>[];
      for (var i = 0; i < 6; i++) {
        final eve = lan.join('192.168.1.${70 + i}');
        for (var n = 0; n < LanCarrier.mostProvingFrom; n++) {
          held.add(await eve.dial('192.168.1.10', anns.port));
          held.add(await eve.dial('192.168.1.11', bens.port));
        }
      }
      await _settle();
      lan.deaf = false;
      for (var i = 0; i < 3; i++) {
        clock = clock.add(const Duration(seconds: 5));
        await a.beat();
        await b.beat();
        await _settle();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      expect([a.seen, b.seen, a.links.length, b.links.length], [1, 1, 1, 1], reason: 'each found the other and neither could connect: every connection was closed at the door, which held sixteen of the stranger\'s');
    });

    // (testWidgets for its clock: time passes as the test says, and no faster.)
    testWidgets('a connection that says nothing is given a second, and no more', (tester) async {
      final lan = FakeLan();
      final a = LanCarrier(me: ann.id, ground: lan.join('192.168.1.10'), people: () => [benPeer], policy: _real, now: () => clock, random: Random(1));
      await a.start();
      await tester.pump();
      final anns = LanBeacon.decode(lan.beacons.last.bytes)!;
      final wire = await lan.join('192.168.1.66').dial('192.168.1.10', anns.port) as FakeLanWire;
      await tester.pump(const Duration(milliseconds: 900));
      expect(wire.closed, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(wire.closed, isTrue, reason: 'held for five seconds, and sixteen of them were all a door took');
      await a.dispose();
    });
  });

  group('stopped, Invisible, and a connection under way (findings 7, 8, 9 and 13)', () {
    test('stopped, a connection that had not yet proved whose it is is closed, and nothing more is said on it', () async {
      final lan = FakeLan();
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer], seed: 1, policy: _real);
      await a.start();
      await _settle();
      final anns = LanBeacon.decode(lan.beacons.last.bytes)!;
      // Ben's device has connected and not yet knocked when Ann switches the route off (or puts her phone's app away).
      final bens = lan.join('192.168.1.11');
      final wire = await bens.dial('192.168.1.10', anns.port) as FakeLanWire;
      final heard = <Uint8List>[];
      wire.frames.listen(heard.add);
      await _settle();
      await a.stop();
      await _settle();
      expect(a.state.value, CarrierState.off);
      final stillOpen = !wire.closed;
      // Its knock comes now, as real as any.
      final run = List.filled(8, 7), nonce = List.filled(16, 9);
      wire.send(Uint8List.fromList([1, ...run, ...nonce, ..._n32(bucket()), ...LanWords.knock(LanWords.keyOf(annBen), from: ben.id, to: ann.id, dialer: run, listener: anns.instance, nonce: nonce, bucket: bucket())]));
      await _settle();
      expect([stillOpen, heard.map((f) => f[0]).toList()], [false, isEmpty], reason: 'the route was off, the connection left open, and the knock that came on it answered with this device\'s proof: whoever knocked knew the device was still here and whose it was');
    });

    // testWidgets, because it fails a test that ends with a timer still waiting to run: that is the whole of what is
    // asked here.
    testWidgets('disposed, the route leaves no timer behind', (tester) async {
      final lan = FakeLan();
      final a = LanCarrier(me: ann.id, ground: lan.join('192.168.1.10'), people: () => [benPeer], policy: _real, now: () => clock, random: Random(1));
      await a.start();
      await tester.pump();
      expect(a.state.value, CarrierState.up);
      // A beacon of Ben's device, whose run has the lesser name: Ann's waits two seconds for it to connect first. (The
      // timer started for a device waited on was kept nowhere, and ran after the route was gone.)
      final run = Uint8List(8);
      final mark = LanWords.mark(LanWords.keyOf(annBen), from: ben.id, to: ann.id, bucket: bucket(), instance: run, port: 40000, address: '192.168.1.11')!;
      lan.join('192.168.1.11').say(LanBeacon(instance: run, port: 40000, bucket: bucket(), marks: [mark]).encode());
      await tester.pump();
      expect(a.seen, 1, reason: 'heard, and waited on');
      // And a connection that has come and not yet knocked, which has a second to.
      final wire = await lan.join('192.168.1.12').dial('192.168.1.10', LanBeacon.decode(lan.beacons.first.bytes)!.port) as FakeLanWire;
      await tester.pump();
      await a.dispose();
      await tester.pump();
      expect([wire.closed, a.state.value], [true, CarrierState.off]);
    });

    test('gone Invisible while a connection to a friend\'s device was being made, nothing is said to that device', () async {
      final lan = FakeLan();
      final slow = _Watched(lan.join('192.168.1.10'));
      const policy = LanPolicy(beatEvery: Duration(hours: 1), sweepEvery: Duration(hours: 1), yieldFor: Duration(milliseconds: 20), sleepsAway: false);
      final a = device(ann, slow, () => [benPeer], seed: 1, policy: policy);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2, policy: _real);
      // Only Ann's device hears the other (so it is hers that connects), and its connection takes a moment to make.
      lan.deafTo.add('192.168.1.11');
      slow.hold = Completer<void>();
      await a.start();
      await b.start();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(slow.dialled, hasLength(1), reason: 'Ann\'s device is connecting to Ben\'s');
      // She chooses Invisible; the connection is made a moment after.
      a.setMode('invisible');
      await _settle();
      final before = lan.frames.length;
      slow.hold!.complete();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _settle();
      final said = [for (final f in lan.frames.skip(before)) f[0]];
      expect(said, isEmpty, reason: 'Invisible, her device still said its knock (1) and then its proof (3) to Ben\'s device, which answered (2): frames said ${said.join(',')}');
      expect([a.links, b.links], [isEmpty, isEmpty]);
    });

    test('gone Invisible, and shown again, the device is no longer known by what its friends\' devices knew it by', () async {
      final lan = FakeLan();
      final own = Peer(id: ann.id, key: NetCrypto.randomBytes(32));
      final a = device(ann, lan.join('192.168.1.10'), () => [benPeer, own], seed: 1, policy: _real);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2, policy: _quick);
      await a.start();
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      final shown = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!;
      a.setMode('invisible');
      await _settle();
      await a.beat();
      final hidden = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!;
      expect(
        [NetCrypto.hex(hidden.instance) == NetCrypto.hex(shown.instance), hidden.port == shown.port],
        [false, false],
        reason: 'the beacon still said the same run and the same door: a friend\'s device that was linked a moment ago went on seeing her device say it was here, and could still connect to her door',
      );
      await _settle();
      expect([a.links, b.links], [isEmpty, isEmpty], reason: 'every link is let go');
      // Ben's device can't connect to the door it knew: it is gone. And what her device says now names nobody to his.
      expect(() => lan.join('192.168.1.12').dial('192.168.1.10', shown.port), throwsStateError);
      clock = clock.add(const Duration(seconds: 40));
      b.sweep();
      await b.beat();
      await a.beat();
      await _settle();
      expect([b.seen, b.reaches(annPeer)], [0, false], reason: 'to a friend\'s device she is not on the network');
      // Shown again: another new name, and found again.
      a.setMode('online');
      await _settle();
      final again = LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '192.168.1.10').bytes)!;
      expect({NetCrypto.hex(shown.instance), NetCrypto.hex(hidden.instance), NetCrypto.hex(again.instance)}, hasLength(3));
      await b.beat();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked again');
    });

    test('what reaches() said could be reached is carried once the connection being made is made', () async {
      final lan = FakeLan();
      final slow = _Watched(lan.join('192.168.1.10'));
      const policy = LanPolicy(beatEvery: Duration(hours: 1), sweepEvery: Duration(hours: 1), yieldFor: Duration(milliseconds: 20), sleepsAway: false);
      final a = device(ann, slow, () => [benPeer], seed: 1, policy: policy);
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2, policy: _real);
      lan.deafTo.add('192.168.1.11');
      slow.hold = Completer<void>();
      await a.start();
      await b.start();
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect([slow.dialled.length, a.reaches(benPeer), a.state.value], [1, true, CarrierState.up], reason: 'heard, being connected to, and "reached" as the switchboard asks');
      // The switchboard hands it a packet now; the connection is made 50 ms later.
      Object? outcome;
      final sending = a.send(benPeer, Uint8List.fromList([1, 2, 3])).then<void>((h) => outcome = h, onError: (Object e) => outcome = e);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      slow.hold!.complete();
      await sending;
      await _settle();
      expect([outcome, slow.dialled.length], [Handed.passed, 1], reason: 'refused at once ("$outcome") though a connection to the device was a moment from being made: the switchboard went on to the next route, which may be a text');
    });

    test('its name is new on another network, and every few hours while nothing is linked; never while something is', () async {
      final lan = FakeLan();
      final ground = lan.join('192.168.1.10');
      final a = device(ann, ground, () => [benPeer], seed: 1, policy: _real);
      await a.start();
      await _settle();
      String run() => NetCrypto.hex(LanBeacon.decode(lan.beacons.last.bytes)!.instance);
      final first = run();
      // The same network, looked at again (the app came back): the same name, said at once.
      final said = lan.beacons.length;
      a.networkChanged();
      await _settle();
      expect([lan.beacons.length, run()], [said + 1, first]);
      // Another network: another name, so the device is not known on the one by what it was on the other.
      ground.address = '10.0.0.5';
      a.networkChanged();
      await _settle();
      final second = run();
      expect([second == first, lan.beacons.last.from, a.state.value], [false, '10.0.0.5', CarrierState.up]);
      // Hours on, with nothing linked: another.
      clock = clock.add(const Duration(hours: 6, minutes: 1));
      a.sweep();
      await _settle();
      final third = run();
      expect({first, second, third}, hasLength(3));

      // Linked, it keeps the name the link was made under however long it runs.
      final b = device(ben, lan.join('10.0.0.6'), () => [annPeer], seed: 2);
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'linked');
      for (var hour = 0; hour < 13; hour++) {
        clock = clock.add(const Duration(minutes: 30));
        // Something said each way, so neither link is closed for silence.
        await a.send(benPeer, Uint8List.fromList([1]));
        await b.send(annPeer, Uint8List.fromList([2]));
        await _settle();
        a.sweep();
        b.sweep();
        await a.beat();
        await b.beat();
        await _settle();
      }
      expect([a.links.length, b.links.length, run() == third || NetCrypto.hex(LanBeacon.decode(lan.beacons.lastWhere((x) => x.from == '10.0.0.5').bytes)!.instance) == third], [1, 1, true]);
    });

    test('the air closed by the system is opened again, and the route hears as before', () async {
      final lan = FakeLan();
      final ground = lan.join('192.168.1.10');
      final a = device(ann, ground, () => [benPeer], seed: 1);
      await a.start();
      await _settle();
      expect([a.state.value, ground.airs], [CarrierState.up, 1]);
      ground.loseAir();
      await _settle();
      expect([a.state.value, ground.airs], [CarrierState.up, 2], reason: 'it said it was ready and heard nothing, until the route was switched off and on');
      final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
      await b.start();
      await _until(() => a.links.length == 1 && b.links.length == 1, 'found and linked after');
    });
  });

  test('a link that says more than a link may is closed, whatever it is saying (finding 6)', () async {
    final lan = FakeLan();
    final b = device(ben, lan.join('192.168.1.11'), () => [annPeer], seed: 2);
    await b.start();
    await _settle();
    final bens = LanBeacon.decode(lan.beacons.last.bytes)!;
    final key = LanWords.keyOf(annBen);
    final myRun = List.generate(8, (i) => 0xE0 + i);
    final anns = lan.join('192.168.1.10');
    // A friend's device links as the route's own dialler does, and keeps what it needs to seal as the link asks.
    final wire = await anns.dial('192.168.1.11', bens.port) as FakeLanWire;
    final frames = StreamIterator(wire.frames);
    final nonce = List.generate(16, (i) => i * 3);
    wire.send(Uint8List.fromList([1, ...myRun, ...nonce, ..._n32(bucket()), ...LanWords.knock(key, from: ann.id, to: ben.id, dialer: myRun, listener: bens.instance, nonce: nonce, bucket: bucket())]));
    expect(await frames.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    final transcript = LanWords.transcript(dialerAccount: ann.id, listenerAccount: ben.id, dialer: myRun, listener: bens.instance, dialerNonce: nonce, listenerNonce: frames.current.sublist(1, 17));
    wire.send(Uint8List.fromList([3, ...LanWords.proof(key, transcript, dialing: true)]));
    await _until(() => b.links.length == 1, 'linked');
    final seals = LanWords.sealKey(key, transcript, dialing: true);
    final atB = <Arrived>[];
    b.arrived.listen(atB.add);
    // Five thousand words that keep the link (kind 0), each sealed and counted as the link asks, all at once: what
    // passed no count at all, and was opened one after another for as long as they came.
    for (var i = 0; i < 5000; i++) {
      final clear = Uint8List(9);
      ByteData.sublistView(clear).setUint32(4, i);
      wire.send(Uint8List.fromList([4, ...NetCrypto.seal(seals, clear)]));
    }
    await _until(() => b.links.isEmpty, 'the link is closed');
    expect([wire.closed, b.dropped, atB], [true, 1, isEmpty], reason: 'held, and every frame opened');
    // The same device may link again, and what it says within what a link may bring is carried.
    final again = await _link(anns, '192.168.1.11', bens.port, key: key, me: ann.id, them: ben.id, myRun: myRun, theirRun: bens.instance, bucket: bucket(), random: Random(3));
    await _until(() => b.links.length == 1, 'linked again');
    expect(again.closed, isFalse);
  });
}
