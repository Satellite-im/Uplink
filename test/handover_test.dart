import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/account/handover.dart';
import 'package:ghost_messaging/account/handover_hub.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

import 'support/hub_pair.dart';

/// Signing in on a new device by scanning its code with a phone (GMFB-45; lib/account/handover.dart): the two ends in
/// memory, with a relay between them that can look at, change, drop and say again whatever passes, as the hub's rooms
/// would let whoever runs the relay do.

/// A relay's rooms: the first to name one sets its token, and what one says goes to the others in it.
class Rooms {
  final _tokens = <String, String>{};
  final _in = <String, List<End>>{};

  /// Everything said in any room, as the relay saw it.
  final seen = <Uint8List>[];

  /// What the relay does with a packet on its way: the packet to pass on (itself, or another), or null to drop it.
  Uint8List? Function(End from, Uint8List packet)? meddle;

  int membersOf(String room) => _in[room]?.length ?? 0;
  bool get empty => _in.values.every((m) => m.isEmpty);

  /// Says [packet] to everyone in [room] but [from], as the relay does.
  void pass(String room, End? from, Uint8List packet) {
    for (final e in [...?_in[room]]) {
      if (!identical(e, from)) scheduleMicrotask(() => e._heard.add(packet));
    }
  }
}

class End implements HandoverRoom {
  End(this.rooms, {this.down = false});
  final Rooms rooms;

  /// The relay can't be reached.
  final bool down;
  String? room;
  final _heard = StreamController<Uint8List>.broadcast();

  @override
  Future<void> join(String name, String token) async {
    if (down) throw StateError('no relay');
    if ((rooms._tokens[name] ??= token) != token) throw StateError('refused');
    rooms._in.putIfAbsent(name, () => []).add(this);
    room = name;
  }

  @override
  void say(Uint8List packet) {
    final r = room;
    if (r == null) throw StateError('not in a room');
    rooms.seen.add(packet);
    final meddle = rooms.meddle;
    final out = meddle == null ? packet : meddle(this, packet);
    if (out != null) rooms.pass(r, this, out);
  }

  @override
  Stream<Uint8List> get heard => _heard.stream;

  @override
  void leave() {
    rooms._in[room]?.remove(this);
    room = null;
  }
}

/// Lets what was said arrive.
Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const relay = 'wss://relay.test/hub';

void main() {
  late Rooms rooms;
  late DateTime clock;
  late List<List<String>> got;
  DateTime now() => clock;

  setUp(() {
    rooms = Rooms();
    clock = DateTime(2026, 11, 23, 12);
    got = [];
  });

  HandoverNewDevice newDevice() => HandoverNewDevice(room: End(rooms), relay: relay, onWords: got.add, now: now);
  HandoverPhone phoneFor(HandoverNewDevice d, {String? on = relay}) => HandoverPhone(room: End(rooms), code: HandoverCode.parse(d.codeText!)!, relay: on, now: now);

  test('the code holds a key, a secret and the relay, and nothing else; what is not one is not read', () {
    final keys = NetKeys.generate();
    final code = HandoverCode(key: keys.public, secret: NetCrypto.randomBytes(32), relay: relay);
    final back = HandoverCode.parse(' ${code.text}\n')!;
    expect(back.key, keys.public);
    expect(back.secret, code.secret);
    expect(back.relay, relay);
    expect(back.room, code.room);
    expect(back.room.length, 32);
    expect(back.token.length, 64);
    expect(HandoverCode.isOne(code.text), isTrue);
    expect(HandoverCode.isOne('GHOSTPAIR1:abc'), isFalse);
    expect(HandoverCode.parse('GHOSTPAIR1:abc'), isNull);
    expect(HandoverCode.parse('GHOSTSIGNIN1:abc:$relay'), isNull);
    // A key that is no point on the curve.
    final bad = HandoverCode(key: Uint8List(33)..[0] = 5, secret: code.secret, relay: relay);
    expect(HandoverCode.parse(bad.text), isNull);
    expect(HandoverCode.sameRelay('wss://Relay.test/hub/', relay), isTrue);
    expect(HandoverCode.sameRelay('wss://other.test/hub', relay), isFalse);
  });

  test('scanned, compared and approved: the same six digits on both, and the words arrive once', () async {
    final words = AccountCrypto.newWords();
    final device = newDevice();
    await device.start();
    expect(device.phase, HandoverPhase.waiting);
    expect(device.digits, isNull);

    final phone = phoneFor(device);
    await phone.start();
    // Before the new device has answered, nothing can be approved.
    expect(phone.ready, isFalse);
    expect(phone.approve(words), isFalse);
    await settle();
    expect(device.phase, HandoverPhase.compare);
    expect(phone.phase, HandoverPhase.compare);
    expect(phone.ready, isTrue);
    expect(device.digits, matches(RegExp(r'^\d{6}$')));
    expect(phone.digits, device.digits);

    expect(phone.approve(words), isTrue);
    expect(phone.phase, HandoverPhase.sent);
    await settle();
    expect(got, [words]);
    expect(device.phase, HandoverPhase.done);
    expect(phone.phase, HandoverPhase.done);
    // Both have left, and the new device's code is gone.
    expect(rooms.empty, isTrue);
    expect(device.codeText, isNull);
    expect(device.digits, isNull);

    // Nothing the relay carried holds a word in the clear, and the room's own seal is not enough to read them.
    for (final p in rooms.seen) {
      expect(utf8.decode(p, allowMalformed: true).contains(words.first), isFalse);
    }
  });

  test('used twice: a second approval sends nothing, and the words said again are taken by nobody', () async {
    final words = AccountCrypto.newWords();
    final device = newDevice();
    await device.start();
    final shown = device.codeText!;
    final room = HandoverCode.parse(shown)!.room;
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    expect(phone.approve(words), isTrue);
    final sent = rooms.seen.length;
    expect(phone.approve(words), isFalse);
    expect(rooms.seen.length, sent);
    await settle();
    expect(got.length, 1);

    // The relay says the sealed words again, to whoever is in the room: nobody is.
    final replay = rooms.seen[sent - 1];
    rooms.pass(room, null, replay);
    await settle();
    expect(got.length, 1);

    // A phone that reads the same code afterwards gets no answer, so it has nothing to approve.
    final late = HandoverPhone(room: End(rooms), code: HandoverCode.parse(shown)!, relay: relay, now: now);
    await late.start();
    await settle();
    expect(late.ready, isFalse);
    expect(late.approve(words), isFalse);
    late.close();
  });

  test('a relay in the middle that swaps the phone\'s key: different digits, no proof, nothing handed over', () async {
    final words = AccountCrypto.newWords();
    final device = newDevice();
    await device.start();
    final code = HandoverCode.parse(device.codeText!)!;
    // The worst case: whoever is in the middle has also seen the code, so it can open the room's seal and seal again.
    final thief = NetKeys.generate();
    rooms.meddle = (from, packet) {
      final m = jsonDecode(utf8.decode(NetCrypto.open(code.roomKey, packet)!)) as Map;
      if (m['t'] == 'hello') return NetCrypto.seal(code.roomKey, utf8.encode(jsonEncode({'t': 'hello', 'k': base64Encode(thief.public)})));
      return packet;
    };
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    // The new device shows digits made with the thief's key; the phone's are made with its own.
    expect(device.phase, HandoverPhase.compare);
    expect(device.digits, isNot(phone.digits));
    // And the new device's proof is of another key than the phone's, so the phone never offers the yes at all.
    expect(phone.ready, isFalse);
    expect(phone.phase, HandoverPhase.waiting);
    expect(phone.approve(words), isFalse);
    await settle();
    expect(got, isEmpty);
  });

  test('a swapped key in the code itself gives the phone other digits than the new device shows', () async {
    final device = newDevice();
    await device.start();
    final real = HandoverCode.parse(device.codeText!)!;
    // The phone is shown a code with someone else's key in the real one's place (same secret, same room).
    final thief = NetKeys.generate();
    final swapped = HandoverCode(key: thief.public, secret: Uint8List.fromList(real.secret), relay: relay);
    final phone = HandoverPhone(room: End(rooms), code: swapped, relay: relay, now: now);
    await phone.start();
    await settle();
    expect(device.phase, HandoverPhase.compare);
    expect(phone.digits, isNot(device.digits));
    // The real device's proof is not of the key the phone made, so the phone waits and can approve nothing.
    expect(phone.ready, isFalse);
    expect(phone.approve(AccountCrypto.newWords()), isFalse);
  });

  test('words changed on the way, or sealed with another key, are refused and end the code', () async {
    final words = AccountCrypto.newWords();
    final device = newDevice();
    await device.start();
    final code = HandoverCode.parse(device.codeText!)!;
    rooms.meddle = (from, packet) {
      final m = jsonDecode(utf8.decode(NetCrypto.open(code.roomKey, packet)!)) as Map;
      if (m['t'] != 'words') return packet;
      final c = base64Decode(m['c'] as String);
      c[c.length - 1] ^= 1;
      return NetCrypto.seal(code.roomKey, utf8.encode(jsonEncode({'t': 'words', 'c': base64Encode(c)})));
    };
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    expect(phone.approve(words), isTrue);
    await settle();
    expect(got, isEmpty);
    expect(device.phase, HandoverPhase.failed);
    expect(device.codeText, isNull);
  });

  test('words that are not recovery words are not taken', () async {
    final device = newDevice();
    await device.start();
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    expect(phone.approve(['not', 'the', 'words']), isTrue);
    await settle();
    expect(got, isEmpty);
    expect(device.phase, HandoverPhase.failed);
  });

  test('what was not sealed by someone who read the code is let go', () async {
    final device = newDevice();
    await device.start();
    final room = HandoverCode.parse(device.codeText!)!.room;
    rooms.pass(room, null, Uint8List.fromList(List.filled(64, 7)));
    rooms.pass(room, null, NetCrypto.seal(NetCrypto.randomBytes(32), utf8.encode('{"t":"hello","k":"AAAA"}')));
    await settle();
    expect(device.phase, HandoverPhase.waiting);
  });

  test('two phones answer one code: neither is given anything', () async {
    final device = newDevice();
    await device.start();
    final one = phoneFor(device), two = phoneFor(device);
    await one.start();
    await settle();
    expect(device.phase, HandoverPhase.compare);
    await two.start();
    await settle();
    expect(device.phase, HandoverPhase.failed);
    expect(one.approve(AccountCrypto.newWords()), isTrue);
    await settle();
    expect(got, isEmpty);
  });

  test('expired: after two minutes the new device takes nothing and the phone sends nothing', () async {
    final words = AccountCrypto.newWords();
    final device = newDevice();
    await device.start();
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    expect(phone.ready, isTrue);
    clock = clock.add(Handover.lifetime);
    // The phone's side: too late to send.
    expect(phone.approve(words), isFalse);
    expect(phone.phase, HandoverPhase.expired);
    // The new device's side, by its clock.
    device.tick();
    expect(device.phase, HandoverPhase.expired);
    expect(device.codeText, isNull);
    expect(rooms.empty, isTrue);
    expect(got, isEmpty);
  });

  test('expired on the new device alone: words that come late are not taken', () async {
    final words = AccountCrypto.newWords();
    var deviceClock = DateTime(2026, 11, 23, 12);
    final device = HandoverNewDevice(room: End(rooms), relay: relay, onWords: got.add, now: () => deviceClock);
    await device.start();
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    deviceClock = deviceClock.add(Handover.lifetime);
    expect(phone.approve(words), isTrue);
    await settle();
    expect(got, isEmpty);
    expect(device.phase, HandoverPhase.expired);
  });

  test('the phone says no: the new device is told, and nothing is sent', () async {
    final device = newDevice();
    await device.start();
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    phone.refuse();
    await settle();
    expect(phone.phase, HandoverPhase.refused);
    expect(device.phase, HandoverPhase.refused);
    expect(phone.approve(AccountCrypto.newWords()), isFalse);
    expect(got, isEmpty);
  });

  test('the new device\'s screen is left: its code is gone and the phone is told', () async {
    final device = newDevice();
    await device.start();
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    device.close();
    expect(device.codeText, isNull);
    expect(device.digits, isNull);
    await settle();
    expect(phone.phase, HandoverPhase.refused);
    expect(phone.approve(AccountCrypto.newWords()), isFalse);
  });

  test('the phone says who it is again until the new device answers', () async {
    final device = newDevice();
    await device.start();
    var dropped = 0;
    rooms.meddle = (from, packet) => dropped++ == 0 ? null : packet;
    final phone = phoneFor(device);
    await phone.start();
    await settle();
    expect(phone.ready, isFalse);
    clock = clock.add(Handover.helloEvery);
    phone.tick();
    await settle();
    expect(phone.ready, isTrue);
    expect(phone.digits, device.digits);
  });

  test('a new device on another relay, or no relay at all', () async {
    final device = newDevice();
    await device.start();
    final elsewhere = phoneFor(device, on: 'wss://other.test/hub');
    await elsewhere.start();
    expect(elsewhere.phase, HandoverPhase.unreachable);
    expect(elsewhere.otherRelay, relay);

    final offline = HandoverNewDevice(room: End(rooms, down: true), relay: relay, onWords: got.add, now: now);
    await offline.start();
    expect(offline.phase, HandoverPhase.unreachable);
    expect(offline.codeText, isNull);
  });

  // The relay as it is (relay/lib/hub.dart, in this process through memory): nothing but its rooms is asked of it.
  test('through the relay\'s own hub: two installs that know nothing of each other meet in the code\'s room', () async {
    final memory = MemoryHub();
    HubCarrier route() => HubCarrier(url: memory.url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 20), dial: memory.dial);
    final a = route(), b = route();
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    Future<void> until(bool Function() ok, String what) async {
      for (var i = 0; i < 400 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(ok(), isTrue, reason: what);
    }

    await a.start();
    await b.start();
    await until(() => a.state.value == CarrierState.up && b.state.value == CarrierState.up, 'they never signed in');

    final words = AccountCrypto.newWords();
    final device = HandoverNewDevice(room: HubHandoverRoom(hub: () => a), relay: memory.url, onWords: got.add);
    await device.start();
    expect(device.phase, HandoverPhase.waiting);
    final phone = HandoverPhone(room: HubHandoverRoom(hub: () => b), code: HandoverCode.parse(device.codeText!)!, relay: memory.url);
    await phone.start();
    await until(() => phone.ready, 'the new device never answered');
    expect(phone.digits, device.digits);
    expect(memory.hub.rooms, 1);
    expect(phone.approve(words), isTrue);
    await until(() => phone.phase == HandoverPhase.done, 'the words never came');
    expect(got, [words]);
    // Both left: the relay has no room, and kept nothing of it.
    await until(() => memory.hub.rooms == 0, 'the room was never left');
  });
}
