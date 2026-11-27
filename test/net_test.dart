import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/sms_carrier.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';

/// The app's routes (lib/net): the cryptography, a packet in pieces, the switchboard's choosing, and two installs
/// talking through the real hub (relay/lib/hub.dart) on this machine.

/// A route made of nothing: what one end sends, the other end's twin is handed. It can be told to lose things, to
/// keep them, to be down, and it counts what it carried.
class FakeCarrier implements Carrier {
  FakeCarrier(this.id, {this.traits = const CarrierTraits(maxPacket: 4096, ackWait: Duration(milliseconds: 200)), bool up = true})
      : state = ValueNotifier(up ? CarrierState.up : CarrierState.down);
  @override
  final String id;
  @override
  String get name => id;
  @override
  String get about => '';
  @override
  final CarrierTraits traits;
  @override
  final ValueNotifier<CarrierState> state;
  @override
  String? problem;
  FakeCarrier? twin;
  bool lose = false;
  bool hold = false;
  bool fail = false;
  bool Function(Peer)? reach;
  final carried = <Uint8List>[];
  final _arrived = StreamController<Arrived>.broadcast();
  @override
  Stream<Arrived> get arrived => _arrived.stream;
  @override
  Future<void> start() async => state.value = CarrierState.up;
  @override
  Future<void> stop() async => state.value = CarrierState.off;
  @override
  bool reaches(Peer peer) => reach?.call(peer) ?? true;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    if (fail) throw CarrierError('it broke');
    carried.add(packet);
    if (hold) return Handed.held;
    if (!lose) twin?.take(packet);
    return Handed.passed;
  }

  /// [packet] comes by this route.
  void take(Uint8List packet) => _arrived.add(Arrived(id, packet, address: 'the-other-number'));

  static (FakeCarrier, FakeCarrier) pair(String id, {CarrierTraits traits = const CarrierTraits(maxPacket: 4096, ackWait: Duration(milliseconds: 200))}) {
    final a = FakeCarrier(id, traits: traits), b = FakeCarrier(id, traits: traits);
    a.twin = b;
    b.twin = a;
    return (a, b);
  }
}

/// A route that holds links of its own, as the direct route does: [open] says one to the other end is open now.
/// What went by the route's own send (which may dial) and what went by an open link alone are told apart.
class LinkCarrier extends FakeCarrier implements LiveLinks {
  LinkCarrier(super.id);
  bool open = false;
  final byLink = <Uint8List>[];

  /// What went back on the link something came by: answers.
  final byLine = <Uint8List>[];
  @override
  bool linked(Peer peer) => open;
  @override
  bool get linkedToSomeone => open;
  @override
  Future<Handed> sendLinked(Peer peer, Uint8List packet) async {
    if (this.fail || !open) throw CarrierError('it broke');
    byLink.add(packet);
    twin?.take(packet);
    return Handed.passed;
  }

  /// What comes by this route comes on a link, which an answer goes back on.
  @override
  void take(Uint8List packet) => _arrived.add(Arrived(id, packet, address: 'the-other-number', line: 'the link'));

  @override
  Future<Handed> sendOn(Peer peer, Object? line, Uint8List packet) async {
    if (this.fail) throw CarrierError('it broke');
    if (line != 'the link') return sendLinked(peer, packet);
    byLine.add(packet);
    twin?.take(packet);
    return Handed.passed;
  }

  static (LinkCarrier, LinkCarrier) pair(String id) {
    final a = LinkCarrier(id), b = LinkCarrier(id);
    a.twin = b;
    b.twin = a;
    return (a, b);
  }
}

class Book implements PeerBook {
  final Map<String, Peer> all = {};
  @override
  Peer? byId(String id) => all[id];
}

/// A phone's data texts stood in for: always able to send, and where each went.
class _Texts implements SmsBridge {
  final to = <String>[];
  @override
  Future<bool> available() async => true;
  @override
  Future<void> send(String address, Uint8List bytes) async => to.add(address);
  @override
  Stream<({String address, Uint8List bytes})> get incoming => const Stream.empty();
}

/// Two installs that have exchanged keys, each with a switchboard over the routes given.
class Two {
  Two(List<(FakeCarrier, FakeCarrier)> routes) {
    final key = NetCrypto.netKey(NetCrypto.conversationKey(a, b.public)!);
    expect(NetCrypto.netKey(NetCrypto.conversationKey(b, a.public)!), key, reason: 'both arrive at one key');
    toB = Peer(id: b.id, key: key, address: '+15550000002', name: 'B');
    toA = Peer(id: a.id, key: key, address: '+15550000001', name: 'A');
    final bookA = Book()..all[b.id] = toB, bookB = Book()..all[a.id] = toA;
    left = Switchboard(me: a.id, peers: bookA, carriers: [for (final r in routes) r.$1]);
    right = Switchboard(me: b.id, peers: bookB, carriers: [for (final r in routes) r.$2]);
    right.received.listen(got.add);
  }
  final a = NetKeys.generate(), b = NetKeys.generate();
  late final Peer toA, toB;
  late final Switchboard left, right;
  final got = <Received>[];
}

Future<void> _tick([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('cryptography', () {
    test('a fixed pair of keys makes the key the phone\'s Kotlin makes (NetCryptoTest.kt holds the same bytes)', () {
      final a = NetKeys.fromScalar(List.generate(32, (i) => i + 1));
      final b = NetKeys.fromScalar(List.generate(32, (i) => 0xa0 + i));
      expect(NetCrypto.hex(a.public), '02515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f');
      expect(NetCrypto.hex(b.public), '020d0918a04198474605615b6df90fdcb34791fb3ecb822f4b26eb6e4fc4511b9d');
      expect(a.id, 'd284f0626fd0836ce4b1731793fa6905');
      final conversation = NetCrypto.conversationKey(a, b.public)!;
      expect(NetCrypto.hex(conversation), 'c6e3cd9e9784467bdff6aafce3d2c1864597a24c4cf9f78e0634b9b6aa8fa5d4');
      expect(NetCrypto.conversationKey(b, a.public), conversation, reason: 'both arrive at one key');
      expect(NetCrypto.hex(NetCrypto.netKey(conversation)), 'd150804ceef8aff0a7bf0a5c383fa178430f5d7bc5e81f8f79851bf26d283c57');
    });

    test('sealed is opened by the same key and by no other, and not once changed', () {
      final key = NetCrypto.randomBytes(32);
      final sealed = NetCrypto.seal(key, utf8.encode('see you at 7'));
      expect(utf8.decode(NetCrypto.open(key, sealed)!), 'see you at 7');
      expect(NetCrypto.open(NetCrypto.randomBytes(32), sealed), isNull);
      expect(NetCrypto.open(key, Uint8List.fromList(sealed)..[20] ^= 1), isNull);
      expect(NetCrypto.open(key, sealed.sublist(0, 20)), isNull);
      expect(NetCrypto.seal(key, utf8.encode('see you at 7')), isNot(sealed), reason: 'sealed twice, it is not the same bytes twice');
    });

    test('a signature made here is taken by the hub\'s own check, and the other way', () {
      final keys = NetKeys.generate();
      final message = utf8.encode('${Hub.greeting}abc');
      final sig = NetCrypto.sign(keys, message);
      expect(NetCrypto.verify(keys.public, message, sig), isTrue);
      expect(P256.verify(keys.public, message, sig), isTrue, reason: 'the hub checks with its own arithmetic');
      expect(P256.verify(keys.public, utf8.encode('other words'), sig), isFalse);
      final theirs = P256.sign(keys.scalar, message, NetCrypto.randomBytes(32));
      expect(NetCrypto.verify(keys.public, message, theirs), isTrue);
      expect(hexOfList(P256.publicOf(keys.scalar)), NetCrypto.hex(keys.public));
      expect(Hub.nameOf(keys.public), keys.id);
    });
  });

  group('a packet', () {
    test('an envelope goes into bytes and comes back', () {
      final e = Envelope(kind: 'call', body: {'o': 'ring', 'c': 'ab12'}, ack: false);
      final back = Envelope.decode(e.encode())!;
      expect([back.id, back.kind, back.body, back.at, back.ack], [e.id, 'call', {'o': 'ring', 'c': 'ab12'}, e.at, false]);
      expect(Envelope.decode(utf8.encode('not json')), isNull);
    });

    test('a ringing call, sealed, fits one data text', () {
      final from = NetKeys.generate().id;
      // A call's ring: the envelope's own name is the call's.
      final e = Envelope(kind: 'call', body: {'o': 'ring', 'm': 'a'});
      final packet = Packet.wrap(from: from, sealed: true, payload: NetCrypto.seal(NetCrypto.randomBytes(32), e.encode()));
      expect(packet.length, lessThanOrEqualTo(SmsCarrier.perText), reason: '${packet.length} bytes');
    });

    test('one too long for a route crosses in pieces, in any order, and is whole again', () {
      final from = NetKeys.generate().id;
      final payload = NetCrypto.randomBytes(500);
      final packet = Packet.wrap(from: from, sealed: true, payload: payload);
      final pieces = Packet.split(packet, 133, maxParts: 6)!;
      expect(pieces.length, 5);
      expect(pieces.every((p) => p.length <= 133), isTrue);
      final joiner = PartJoiner();
      Packet? whole;
      for (final p in pieces.reversed) {
        expect(whole, isNull);
        whole = joiner.add(Packet.parse(p)!);
      }
      expect(whole!.payload, payload);
      expect([whole.from, whole.sealed, whole.isPart], [from, true, false]);
      expect(Packet.split(packet, 133, maxParts: 4), isNull, reason: 'more pieces than the route will carry');
      expect(Packet.split(Packet.wrap(from: from, sealed: false, payload: [1, 2, 3]), 133)!.single.length, 20);
    });

    test('pieces of a packet that never finishes are forgotten', () {
      var now = DateTime(2026, 11, 14, 12);
      final joiner = PartJoiner(now: () => now, maxOpen: 2);
      final from = NetKeys.generate().id;
      final pieces = Packet.split(Packet.wrap(from: from, sealed: true, payload: NetCrypto.randomBytes(300)), 133)!;
      expect(joiner.add(Packet.parse(pieces[0])!), isNull);
      now = now.add(const Duration(minutes: 11));
      for (final p in pieces.skip(1)) {
        expect(joiner.add(Packet.parse(p)!), isNull, reason: 'its first piece was dropped ten minutes on');
      }
    });

    // Found in review, 2026-11-23: the SMS route took any address that wasn't empty, a friend by username's "@maya"
    // among them, and Android failed the data text without a word, so it read as passed on.
    test('a data text goes only to a phone number: never a username, a stand-in, or a sender\'s name', () async {
      for (final a in ['+1 (555) 000-2222', '5550002222', '+15550002222', '555.000.2222']) {
        expect(SmsCarrier.isNumber(a), isTrue, reason: a);
      }
      for (final a in ['@maya', '@ben.5550002222', '', 'AMAZON', 'gghhiijjkkllmmnnooppaabbccddeeff@member.ghost-sms.com', '12345', 'x5550002222']) {
        expect(SmsCarrier.isNumber(a), isFalse, reason: a);
      }
      final bridge = _Texts();
      final sms = SmsCarrier(bridge);
      await sms.start();
      expect(sms.reaches(const Peer(id: 'x', address: '@maya')), isFalse);
      expect(sms.reaches(const Peer(id: 'x', address: '')), isFalse);
      expect(sms.reaches(const Peer(id: 'x', address: '+15550002222')), isTrue);
      await expectLater(sms.send(const Peer(id: 'x', address: '@maya'), Uint8List(10)), throwsA(isA<CarrierError>()));
      await sms.send(const Peer(id: 'x', address: '+15550002222'), Uint8List(10));
      expect(bridge.to, ['+15550002222']);
      await sms.stop();
    });
  });

  group('the switchboard', () {
    // The relay comes first, the direct route after it (docs/OPEN_NETWORK.md; Matt, 2026-11-22: "the relay as a primary
    // source but have p2p as a secondary back up").
    test('where the person has not said, the relay is tried first, then the direct route, the local network and SMS', () {
      final sms = FakeCarrier.pair('sms'), lan = FakeCarrier.pair('lan'), p2p = FakeCarrier.pair('p2p'), hub = FakeCarrier.pair('hub'), new_ = FakeCarrier.pair('later');
      final two = Two([new_, sms, lan, p2p, hub]);
      expect(two.left.order, ['hub', 'p2p', 'lan', 'sms']);
      expect(two.left.carriers.map((c) => c.id), ['hub', 'p2p', 'lan', 'sms', 'later'], reason: 'one not named comes after those that are');
      expect(two.left.routes(two.toB).map((c) => c.id), ['hub', 'p2p', 'lan', 'sms', 'later']);
    });

    test('sends by the first route in the person\'s order, sealed, and is told it arrived', () async {
      final lan = FakeCarrier.pair('lan'), hub = FakeCarrier.pair('hub');
      final two = Two([lan, hub]);
      final d = await two.left.send(two.toB, Envelope(kind: 'text', body: {'t': 'hello'}));
      expect([d.via, d.acked], ['hub', true]);
      expect(two.got.single.envelope.body['t'], 'hello');
      expect(two.got.single.via, 'hub');
      expect(lan.$1.carried, isEmpty);
      expect(utf8.decode(hub.$1.carried.single, allowMalformed: true).contains('hello'), isFalse, reason: 'what the route carried is sealed');
      two.left.order = ['lan', 'hub'];
      expect((await two.left.send(two.toB, Envelope(kind: 'text'))).via, 'lan');
    });

    test('with no answer on one route the next is tried, and the other end passes it on once', () async {
      final lan = FakeCarrier.pair('lan'), hub = FakeCarrier.pair('hub');
      final two = Two([lan, hub]);
      // The relay takes it and the answer is lost on the way back: sent again over the local network.
      hub.$2.lose = true;
      final d = await two.left.send(two.toB, Envelope(kind: 'text', body: {'t': 'once'}));
      expect([d.via, d.acked], ['lan', true]);
      expect(d.tried, ['hub', 'lan']);
      await _tick();
      expect(two.got.length, 1, reason: 'it came twice and was passed on once');
    });

    test('a route that is off, down, broken or cannot reach them is passed over', () async {
      final lan = FakeCarrier.pair('lan'), p2p = FakeCarrier.pair('p2p'), hub = FakeCarrier.pair('hub');
      final two = Two([lan, p2p, hub]);
      await two.left.setOn('hub', false);
      p2p.$1.fail = true;
      var d = await two.left.send(two.toB, Envelope(kind: 'text'));
      expect(d.via, 'lan');
      expect(d.tried, ['p2p: it broke', 'lan']);
      await two.left.setOn('hub', true);
      hub.$1.reach = (_) => false;
      p2p.$1.state.value = CarrierState.down;
      d = await two.left.send(two.toB, Envelope(kind: 'text'));
      expect(d.via, 'lan');
      lan.$1.state.value = CarrierState.down;
      d = await two.left.send(two.toB, Envelope(kind: 'text'));
      expect(d.sent, isFalse);
      expect(d.tried.single, 'no route reaches them now');
    });

    test('a route that costs money carries only what may cost money', () async {
      const text = CarrierTraits(maxPacket: 133, maxParts: 6, metered: true, live: false, wakes: true);
      final sms = FakeCarrier.pair('sms', traits: text);
      final two = Two([sms]);
      expect((await two.left.send(two.toB, Envelope(kind: 'typing', ack: false))).sent, isFalse);
      final d = await two.left.send(two.toB, Envelope(kind: 'text', body: {'t': 'x' * 200}), metered: true);
      expect([d.via, d.acked], ['sms', false]);
      expect(sms.$1.carried.length, greaterThan(1), reason: 'too long for one text, it went in pieces');
      await _tick();
      expect(two.got.single.envelope.body['t'], 'x' * 200);
      // No answer goes back by a route that costs money.
      expect(sms.$2.carried, isEmpty);
    });

    test('kept for someone who is away is enough, unless it is urgent: then the route that wakes them is tried too', () async {
      const text = CarrierTraits(maxPacket: 133, maxParts: 6, metered: true, live: false, wakes: true);
      final hub = FakeCarrier.pair('hub'), sms = FakeCarrier.pair('sms', traits: text);
      final two = Two([hub, sms]);
      hub.$1.hold = true;
      var d = await two.left.send(two.toB, Envelope(kind: 'text'), metered: true);
      expect([d.via, d.handed], ['hub', Handed.held]);
      expect(sms.$1.carried, isEmpty);
      d = await two.left.send(two.toB, Envelope(kind: 'call', body: {'o': 'ring'}), metered: true, urgent: true);
      expect(d.tried, ['hub', 'sms']);
      await _tick();
      expect(two.got.single.envelope.kind, 'call');
      expect(two.got.single.via, 'sms');
    });

    // docs/OPEN_NETWORK.md, "The switchboard": "When the hub only kept something (they are not connected to it) and a
    // direct stream to one of their devices is open, it goes by that too, without waiting."
    test('kept by the relay, with a link to their device open right now: it goes by the link too, once, unwaited, and is taken once', () async {
      final hub = FakeCarrier.pair('hub'), direct = LinkCarrier.pair('p2p');
      final two = Two([hub, direct]);
      // The relay keeps it now and hands it over later, as it does for someone who comes back.
      hub.$1.hold = true;
      direct.$1.open = true;
      final acked = <String>[];
      two.left.acked.listen(acked.add);
      final e = Envelope(kind: 'text', body: {'t': 'both ways'});
      final d = await two.left.send(two.toB, e);
      expect([d.via, d.handed, d.acked], ['hub', Handed.held, false], reason: 'what the relay said is still the answer: the link was not waited for');
      expect(d.tried, ['hub', 'p2p']);
      await _tick();
      expect(direct.$1.byLink, hasLength(1), reason: 'once, by the open link');
      expect(direct.$1.carried, isEmpty, reason: 'never by the route\'s own send, which would dial');
      expect(two.got.single.envelope.body['t'], 'both ways');
      expect(two.got.single.via, 'p2p');
      expect(acked, [e.id], reason: 'answered over the link');
      // They come back to the relay and are handed what it kept: the same envelope, answered again, passed on once.
      hub.$2.take(hub.$1.carried.single);
      await _tick();
      expect(two.got, hasLength(1));
      expect(hub.$2.carried, hasLength(1), reason: 'the second copy is answered too, by the route it came by');
    });

    test('kept by the relay, with no link open: the route of links is asked nothing, so nothing is dialled or started', () async {
      final hub = FakeCarrier.pair('hub'), direct = LinkCarrier.pair('p2p');
      final two = Two([hub, direct]);
      hub.$1.hold = true;
      final d = await two.left.send(two.toB, Envelope(kind: 'text'));
      expect([d.via, d.handed], ['hub', Handed.held]);
      expect(d.tried, ['hub']);
      await _tick();
      expect([direct.$1.carried, direct.$1.byLink], [isEmpty, isEmpty]);
      // A link that is open is no reason to use it while the relay passes things on.
      hub.$1.hold = false;
      direct.$1.open = true;
      expect((await two.left.send(two.toB, Envelope(kind: 'text'))).via, 'hub');
      await _tick();
      expect([direct.$1.carried, direct.$1.byLink], [isEmpty, isEmpty]);
      // And with the relay away altogether, the route of links is a route like any other: it sends, dialling as it must.
      hub.$1.state.value = CarrierState.down;
      direct.$1.open = false;
      expect((await two.left.send(two.toB, Envelope(kind: 'text'))).via, 'p2p');
      expect([direct.$1.carried.length, direct.$1.byLink.length], [1, 0]);
    });

    test('kept by the relay and urgent: an open link carries it and is waited for; with none the route that wakes gets its turn at once', () async {
      const text = CarrierTraits(maxPacket: 133, maxParts: 6, metered: true, live: false, wakes: true);
      final hub = FakeCarrier.pair('hub'), direct = LinkCarrier.pair('p2p'), sms = FakeCarrier.pair('sms', traits: text);
      final two = Two([hub, direct, sms]);
      hub.$1.hold = true;
      // No link: nothing is dialled for someone who is away, and the text that wakes their phone goes without waiting.
      var d = await two.left.send(two.toB, Envelope(kind: 'call', body: {'o': 'ring'}), metered: true, urgent: true);
      expect(d.tried, ['hub', 'sms']);
      expect([direct.$1.carried, direct.$1.byLink], [isEmpty, isEmpty]);
      // A link open: the ring goes by it, is answered, and no text is spent.
      direct.$1.open = true;
      final texts = sms.$1.carried.length;
      d = await two.left.send(two.toB, Envelope(kind: 'call', body: {'o': 'ring'}), metered: true, urgent: true);
      expect([d.via, d.acked], ['p2p', true]);
      expect(d.tried, ['hub', 'p2p']);
      expect(direct.$1.byLink, hasLength(1));
      expect(direct.$1.carried, isEmpty);
      expect(sms.$1.carried.length, texts);
      // The link gone as it is used: said so, and the text goes.
      direct.$1.fail = true;
      d = await two.left.send(two.toB, Envelope(kind: 'call', body: {'o': 'ring'}), metered: true, urgent: true);
      expect(d.tried, ['hub', 'p2p: it broke', 'sms']);
    });

    test('nothing unsealed is taken from someone a key is held for, and nothing at all from a stranger but a greeting', () async {
      final hub = FakeCarrier.pair('hub');
      final two = Two([hub]);
      final strangers = <String>[];
      two.right.strangers.listen((s) => strangers.add('${s.envelope.kind} from ${s.from.substring(0, 4)} at ${s.address}'));
      // In the clear, from the name a key is held for: dropped.
      hub.$2._arrived.add(Arrived('hub', Packet.wrap(from: two.a.id, sealed: false, payload: Envelope(kind: 'text', body: {'t': 'forged'}).encode())));
      // From a name nobody knows: a greeting is shown to the app, anything else is not.
      final who = NetKeys.generate();
      hub.$2._arrived.add(Arrived('hub', Packet.wrap(from: who.id, sealed: false, payload: Envelope(kind: 'text').encode())));
      hub.$2._arrived.add(Arrived('hub', Packet.wrap(from: who.id, sealed: false, payload: Envelope(kind: 'hello', body: {'k': base64Encode(who.public)}).encode()), address: '+15559990000'));
      // Sealed under some other key.
      hub.$2._arrived.add(Arrived('hub', Packet.wrap(from: two.a.id, sealed: true, payload: NetCrypto.seal(NetCrypto.randomBytes(32), Envelope(kind: 'text').encode()))));
      await _tick();
      expect(two.got, isEmpty);
      expect(strangers, ['hello from ${who.id.substring(0, 4)} at +15559990000']);
      // And to send sealed with no key held is refused, not sent in the clear.
      final d = await two.left.send(Peer(id: who.id), Envelope(kind: 'text'));
      expect(d.sent, isFalse);
    });

    test('a route is taken out and another put in its place', () async {
      final hub = FakeCarrier.pair('hub');
      final two = Two([hub]);
      expect((await two.left.send(two.toB, Envelope(kind: 'text'))).via, 'hub');
      // The peer-to-peer route this is all made to make room for: same name of thing, different way.
      final p2p = FakeCarrier.pair('p2p');
      two.left.add(p2p.$1);
      two.right.add(p2p.$2);
      two.left.remove('hub');
      expect(two.left.carriers.map((c) => c.id), ['p2p']);
      final d = await two.left.send(two.toB, Envelope(kind: 'text', body: {'t': 'no server'}));
      expect([d.via, d.acked], ['p2p', true]);
      expect(two.got.last.via, 'p2p');
    });

    // GMFB-24: Settings › Routes shows which route each person is on, from what the switchboard saw.
    test('which route last carried something to each person and from them, and when: held in memory, bounded, and only for the sealed', () async {
      final hub = FakeCarrier.pair('hub'), sms = FakeCarrier.pair('sms');
      final two = Two([hub, sms]);
      expect([two.left.used, two.right.used], [isEmpty, isEmpty]);
      var told = 0;
      two.left.usedChanged.addListener(() => told++);
      expect((await two.left.send(two.toB, Envelope(kind: 'text'))).via, 'hub');
      await _tick();
      // A's text went by the relay, and B's answer came by it; B saw the same the other way.
      final ab = two.left.used[two.b.id]!, ba = two.right.used[two.a.id]!;
      expect([ab.sentBy, ab.cameBy, ba.sentBy, ba.cameBy], ['hub', 'hub', 'hub', 'hub']);
      expect(told, greaterThanOrEqualTo(2));
      // By SMS only: what went is said to have gone by it; what came last came by the relay still (no answer by SMS).
      await two.left.send(two.toB, Envelope(kind: 'text', ack: false), only: {'sms'}, metered: true);
      await _tick();
      final now = two.left.used[two.b.id]!;
      expect([now.sentBy, now.cameBy], ['sms', 'hub']);
      expect(now.sentAt!.isAfter(ab.sentAt!) || now.sentAt == ab.sentAt, isTrue);
      expect(two.right.used[two.a.id]!.cameBy, 'sms');
      // Nothing for what went in the clear to someone no key is held for, nor for anything that came from them.
      final stranger = NetKeys.generate();
      await two.left.send(Peer(id: stranger.id), Envelope(kind: 'hello', ack: false), sealed: false);
      hub.$1.take(Packet.wrap(from: stranger.id, sealed: false, payload: Envelope(kind: 'hello', ack: false).encode()));
      await _tick();
      expect(two.left.used.keys, [two.b.id]);
      // No more than so many people, the longest quiet let go first.
      final book = Book();
      final board = Switchboard(me: two.a.id, peers: book, carriers: [FakeCarrier('hub')]);
      final ids = [for (var i = 0; i <= Switchboard.mostUsed; i++) NetKeys.generate().id];
      for (final id in ids) {
        await board.send(Peer(id: id, key: NetCrypto.randomBytes(32)), Envelope(kind: 'text', ack: false));
      }
      expect(board.used.length, Switchboard.mostUsed);
      expect(board.used.containsKey(ids.first), isFalse);
      expect(board.used.containsKey(ids.last), isTrue);
    });
  });

  group('through the real hub', () {
    late Relay relay;
    late String url;
    setUp(() async {
      relay = Relay(hub: Hub());
      url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
    });
    tearDown(() => relay.stop());

    Future<void> up(HubCarrier c) async {
      await c.start();
      for (var i = 0; i < 200 && c.state.value != CarrierState.up; i++) {
        await _tick(10);
      }
      expect(c.state.value, CarrierState.up, reason: c.problem);
    }

    // Matt, 2026-11-18: a circle's members' messages seen on no device. A space asked for before the relay server was
    // connected (as the app starts) was never joined: nothing came from it and what was written went nowhere.
    test('a room asked for before the connection is up is joined once it is, and what is said there comes', () async {
      final keys = 'ab' * 16, token = 'cd' * 32;
      final early = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(hours: 1));
      final joined = early.join(keys, token);
      final other = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(hours: 1));
      await up(other);
      await other.join(keys, token);
      final heard = <List<int>>[];
      early.roomPackets.listen((p) => heard.add(p.bytes));
      await up(early);
      expect(await joined.timeout(const Duration(seconds: 5)), [other.signer.id]);
      other.sendRoom(keys, Uint8List.fromList([7, 7, 7]));
      // And what is kept reaches one who comes later.
      other.sendRoom(keys, Uint8List.fromList([9]), keep: true);
      for (var i = 0; i < 100 && heard.length < 2; i++) {
        await _tick(10);
      }
      expect(heard, [[7, 7, 7], [9]]);
      final late = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(hours: 1));
      final lateHeard = <List<int>>[];
      late.roomPackets.listen((p) => lateHeard.add(p.bytes));
      await up(late);
      await late.join(keys, token);
      for (var i = 0; i < 100 && lateHeard.isEmpty; i++) {
        await _tick(10);
      }
      expect(lateHeard, [[9]]);
      await early.stop();
      await other.stop();
      await late.stop();
    });

    // Matt, 2026-11-16: "Yes, fix delivery". Back on the screen after a while, the app makes the connection again
    // rather than trust one the phone may have let die; a short look away leaves it be; one that is down is tried now.
    test('nudged: made again after a long time away, left after a short one, tried at once when down', () async {
      final c = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(hours: 1));
      await up(c);
      var states = <CarrierState>[];
      void heard() => states.add(c.state.value);
      c.state.addListener(heard);
      c.nudge(away: const Duration(seconds: 5));
      await _tick(100);
      expect(states, isEmpty, reason: 'away a moment: the connection is trusted');
      c.nudge(away: const Duration(minutes: 3));
      for (var i = 0; i < 200 && c.state.value != CarrierState.up; i++) {
        await _tick(10);
      }
      await _tick(50);
      expect(states, contains(CarrierState.connecting), reason: 'away long enough for it to have died: made again');
      expect(c.state.value, CarrierState.up);
      // Down, with an hour to wait before the next try: a nudge tries now.
      await relay.stop();
      for (var i = 0; i < 200 && c.state.value == CarrierState.up; i++) {
        await _tick(10);
      }
      expect(c.state.value, CarrierState.down);
      final port = Uri.parse(url).port;
      relay = Relay(hub: Hub());
      await relay.start(port: port);
      states = [];
      c.nudge();
      for (var i = 0; i < 300 && c.state.value != CarrierState.up; i++) {
        await _tick(10);
      }
      expect(c.state.value, CarrierState.up, reason: 'tried now, not in an hour');
      c.state.removeListener(heard);
      await c.stop();
    });

    // Matt, 2026-11-17: "Do the server change in order to get presense sensing working ... for users who have signed up
    // for a username and are part of our own system".
    test('a friend watched is told when someone puts the app away, comes back to it, and leaves, and when they were last on', () async {
      final a = NetKeys.generate(), b = NetKeys.generate();
      final hubA = HubCarrier(url: url, signer: KeysSigner(a)), hubB = HubCarrier(url: url, signer: KeysSigner(b));
      await up(hubA);
      hubA.watch([b.id]);
      await up(hubB);
      await _tick(60);
      expect(hubA.here.value, {b.id});
      expect(hubA.away.value, isEmpty, reason: 'using the app');
      final ticks = hubA.presence.value;
      // Put away: still connected, no longer in use.
      hubB.awayNow = true;
      await _tick(60);
      expect(hubA.away.value, {b.id});
      expect(hubA.seen[b.id], isNotNull, reason: 'last in use when put away');
      expect(hubA.presence.value, greaterThan(ticks));
      // Back.
      hubB.awayNow = false;
      await _tick(60);
      expect(hubA.away.value, isEmpty);
      // Away again, then gone: last seen is when they put it away.
      hubB.awayNow = true;
      await _tick(60);
      final putAway = hubA.seen[b.id]!;
      await hubB.stop();
      await _tick(60);
      expect(hubA.here.value, isEmpty);
      expect(hubA.seen[b.id], putAway);
      expect(relay.hub!.seenOf(b.id), putAway.millisecondsSinceEpoch);
      // Someone watching afterwards is told when they were last on, at once.
      final c = NetKeys.generate();
      final hubC = HubCarrier(url: url, signer: KeysSigner(c));
      await up(hubC);
      hubC.watch([b.id]);
      await _tick(60);
      expect(hubC.seen[b.id], putAway);
      // And one away when they connect says so after signing in (an app opened in the background).
      final hubB2 = HubCarrier(url: url, signer: KeysSigner(b))..awayNow = true;
      await up(hubB2);
      await _tick(60);
      expect(hubC.here.value, {b.id});
      expect(hubC.away.value, {b.id});
      await hubB2.stop();
      await hubC.stop();
      await hubA.stop();
    });

    // GMFB-34: Online, Away, Busy or Invisible, chosen by the person.
    test('a chosen mode: away holds while in use, busy shows to watchers, invisible looks gone and comes in unseen', () async {
      final a = NetKeys.generate(), b = NetKeys.generate();
      final hubA = HubCarrier(url: url, signer: KeysSigner(a)), hubB = HubCarrier(url: url, signer: KeysSigner(b));
      await up(hubA);
      hubA.watch([b.id]);
      await up(hubB);
      await _tick(60);
      hubB.mode = 'away';
      await _tick(60);
      expect(hubA.away.value, {b.id}, reason: 'away though the app is in use');
      hubB.mode = 'busy';
      await _tick(60);
      expect(hubA.away.value, isEmpty);
      expect(hubA.busy.value, {b.id});
      hubB.mode = 'invisible';
      await _tick(60);
      expect(hubA.here.value, isEmpty, reason: 'looks gone');
      expect(hubA.busy.value, isEmpty);
      hubB.mode = 'online';
      await _tick(60);
      expect(hubA.here.value, {b.id});
      expect(hubA.away.value, isEmpty);
      expect(hubA.busy.value, isEmpty);
      await hubB.stop();
      // Signing in invisible: never seen to come.
      final hubB2 = HubCarrier(url: url, signer: KeysSigner(b))..mode = 'invisible';
      await up(hubB2);
      await _tick(60);
      expect(hubA.here.value, isEmpty);
      await hubB2.stop();
      await hubA.stop();
    });

    test('two installs find each other by name, and what one sends the other gets, sealed all the way', () async {
          final a = NetKeys.generate(), b = NetKeys.generate();
          final key = NetCrypto.netKey(NetCrypto.conversationKey(a, b.public)!);
          final hubA = HubCarrier(url: url, signer: KeysSigner(a)), hubB = HubCarrier(url: url, signer: KeysSigner(b));
          final left = Switchboard(me: a.id, peers: Book()..all[b.id] = Peer(id: b.id, key: key), carriers: [hubA]);
          final right = Switchboard(me: b.id, peers: Book()..all[a.id] = Peer(id: a.id, key: key), carriers: [hubB]);
          final got = <Received>[];
          right.received.listen(got.add);
          await up(hubA);
          // B is away: kept for them, and handed over when they come.
          hubA.watch([b.id]);
          var d = await left.send(Peer(id: b.id, key: key), Envelope(kind: 'text', body: {'t': 'are you there'}));
          expect([d.via, d.handed, d.acked], ['hub', Handed.held, false]);
          expect(relay.hub!.heldFor(b.id), 1);
          final acked = left.acked.first;
          await up(hubB);
          await acked.timeout(const Duration(seconds: 3));
          expect(got.single.envelope.body['t'], 'are you there');
          expect(relay.hub!.heldFor(b.id), 0);
          await _tick(50);
          expect(hubA.here.value, {b.id}, reason: 'A asked to be told when B came');
          // Both there: passed and answered at once.
          d = await left.send(Peer(id: b.id, key: key), Envelope(kind: 'text', body: {'t': 'good'}));
          expect([d.handed, d.acked], [Handed.passed, true]);
          expect(got.last.envelope.body['t'], 'good');
          await hubB.stop();
          await _tick(50);
          expect(hubA.here.value, isEmpty);
          await hubA.stop();
        });

    test('what is held for everyone together has a limit, and what was handed over no longer counts', () async {
      await relay.stop();
      // Room for two packets of a thousand bytes, each counted with what holding it costs (Hub.heldOverhead), not three.
      relay = Relay(hub: Hub(heldBytes: 2500 + 2 * Hub.heldOverhead));
      url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
      final a = NetKeys.generate(), b = NetKeys.generate(), c = NetKeys.generate();
      final hubA = HubCarrier(url: url, signer: KeysSigner(a));
      await up(hubA);
      final packet = Uint8List(1000);
      expect(await hubA.send(Peer(id: b.id), packet), Handed.held);
      expect(await hubA.send(Peer(id: c.id), packet), Handed.held);
      await expectLater(hubA.send(Peer(id: c.id), packet), throwsA(isA<CarrierError>()), reason: 'a third thousand bytes is over the limit');
      expect(relay.hub!.holding, greaterThan(2000));
      // B comes and is handed theirs: there is room again.
      final hubB = HubCarrier(url: url, signer: KeysSigner(b));
      final got = hubB.arrived.first;
      await up(hubB);
      await got.timeout(const Duration(seconds: 3));
      expect(relay.hub!.holding, lessThan(1100 + Hub.heldOverhead));
      expect(await hubA.send(Peer(id: c.id), packet), Handed.held);
      await hubA.stop();
      await hubB.stop();
    });

    test('a name is only its key holder\'s to connect under', () async {
          final real = NetKeys.generate(), thief = NetKeys.generate();
          final c = HubCarrier(url: url, signer: _Impostor(real, thief), retry: const Duration(hours: 1));
          await c.start();
          for (var i = 0; i < 100 && c.state.value != CarrierState.down; i++) {
            await _tick(10);
          }
          expect(c.state.value, CarrierState.down);
          expect(c.problem, contains('refused'));
          expect(relay.hub!.connected, 0);
          await c.stop();
        });

    test('a room is joined and left at any time by whoever holds its token, and each is told of the others', () async {
          final keys = [for (var i = 0; i < 3; i++) NetKeys.generate()];
          final hubs = [for (final k in keys) HubCarrier(url: url, signer: KeysSigner(k))];
          for (final h in hubs) {
            await up(h);
          }
          final roomKey = NetCrypto.randomBytes(32);
          final room = NetCrypto.hex(NetCrypto.derive(roomKey, 'room name').sublist(0, 16));
          final token = NetCrypto.hex(NetCrypto.derive(roomKey, 'room token'));
          final events = <String>[];
          hubs[0].roomEvents.listen((e) => events.add(e.came != null ? 'came ${keys.indexWhere((k) => k.id == e.came)}' : e.went != null ? 'went ${keys.indexWhere((k) => k.id == e.went)}' : 'in with ${e.members!.length}'));
          final heard = <String>[];
          hubs[0].roomPackets.listen((p) => heard.add('${keys.indexWhere((k) => k.id == p.from)}: ${utf8.decode(p.bytes)}'));
          expect(await hubs[0].join(room, token), isEmpty);
          expect(await hubs[1].join(room, token), [keys[0].id]);
          expect((await hubs[2].join(room, token)).toSet(), {keys[0].id, keys[1].id});
          hubs[1].sendRoom(room, Uint8List.fromList(utf8.encode('hello room')));
          hubs[1].leave(room);
          await _tick(80);
          expect(events, ['in with 0', 'came 1', 'came 2', 'went 1']);
          expect(heard, ['1: hello room']);
          // A wrong token is refused; someone not in the room is not heard in it.
          final outsider = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()));
          await up(outsider);
          await expectLater(outsider.join(room, 'f' * 64), throwsA(isA<CarrierError>()));
          expect(() => outsider.sendRoom(room, Uint8List(3)), throwsA(isA<CarrierError>()));
          // A connection that drops leaves its rooms.
          await hubs[2].stop();
          await _tick(80);
          expect(events.last, 'went 2');
          expect(relay.hub!.rooms, 1);
          hubs[0].leave(room);
          await _tick(80);
          expect(relay.hub!.rooms, 0, reason: 'a room nobody is in is forgotten');
          for (final h in [hubs[0], hubs[1], outsider]) {
            await h.stop();
          }
        });

    // Matt, 2026-11-14: "always open voice channels that you can jump in and out at any time and you can see who's
    // connected".
    test('a room is looked at without joining it: who is in it now and as they come and go; a wrong token sees nothing', () async {
          final keys = [for (var i = 0; i < 3; i++) NetKeys.generate()];
          final hubs = [for (final k in keys) HubCarrier(url: url, signer: KeysSigner(k))];
          for (final h in hubs) {
            await up(h);
          }
          final roomKey = NetCrypto.randomBytes(32);
          final room = NetCrypto.hex(NetCrypto.derive(roomKey, 'room name').sublist(0, 16));
          final token = NetCrypto.hex(NetCrypto.derive(roomKey, 'room token'));
          final seen = <List<int>>[];
          hubs[0].looks.listen((l) => seen.add([for (final m in l.members) keys.indexWhere((k) => k.id == m)]..sort()));
          hubs[0].look(room, token);
          await _tick(80);
          expect(seen.last, isEmpty, reason: 'nobody in it yet');
          await hubs[1].join(room, token);
          await _tick(80);
          expect(seen.last, [1]);
          await hubs[2].join(room, token);
          await _tick(80);
          expect(seen.last, [1, 2]);
          expect(hubs[0].looking[room]!.length, 2);
          hubs[1].leave(room);
          await _tick(80);
          expect(seen.last, [2]);
          // Looking is not being in it: nothing sent to the room reaches a looker.
          final heard = <String>[];
          hubs[0].roomPackets.listen((p) => heard.add('x'));
          hubs[2].sendRoom(room, Uint8List.fromList([1, 2, 3]));
          await _tick(80);
          expect(heard, isEmpty);
          // A wrong token is told nothing.
          final outsider = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()));
          await up(outsider);
          final peeked = <Object>[];
          outsider.looks.listen(peeked.add);
          outsider.look(room, 'f' * 64);
          await _tick(80);
          expect(peeked, isEmpty);
          hubs[0].unlook(room);
          for (final h in [...hubs, outsider]) {
            await h.stop();
          }
        });
  });
}

String hexOfList(List<int> bytes) => NetCrypto.hex(bytes);

/// Says it is one install and signs as another.
class _Impostor implements NetSigner {
  _Impostor(this.claimed, this.actual);
  final NetKeys claimed, actual;
  @override
  String get id => claimed.id;
  @override
  Uint8List get publicKey => claimed.public;
  @override
  Future<Uint8List> sign(List<int> message) async => NetCrypto.sign(actual, message);
}
