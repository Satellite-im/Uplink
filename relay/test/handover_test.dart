@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/ws_door.dart';
import 'package:test/test.dart';

import 'fed_support.dart' show someBytes, unhex;
import 'slow_client.dart';
import 'wire_budget_test.dart' show memSignIn, hex;

/// What the hub keeps, handed over a piece at a time as a device takes it, across what really happens to phones: a slow
/// link, a phone put away, a connection replaced by the same device's next one, something said live meanwhile. Turned
/// into tests from the third review's probes (2026-11-23).

/// [count] messages of [size] bytes kept in [room], each with its index first.
Future<void> keepIndexed(Hub hub, String room, String token, int count, int size) async {
  final mine = await memSignIn(hub);
  mine.add('{"join":"$room","token":"$token"}');
  await pumpEventQueue();
  for (var i = 0; i < count; i++) {
    mine.add(Uint8List.fromList([Hub.toRoomKept, ...unhex(room), ...indexed(i, size)]));
  }
  await pumpEventQueue();
  expect(hub.keptIn(room), count);
  await mine.close();
}

/// [count] packets of [size] bytes held for [to], each with its index first.
Future<void> holdIndexed(Hub hub, String to, int count, int size, {int from = 0}) async {
  final bob = await memSignIn(hub);
  for (var i = from; i < from + count; i++) {
    bob.add(Uint8List.fromList([Hub.toPeer, 0, 0, i >> 8, i & 0xff, ...unhex(to), ...indexed(i, size)]));
  }
  await pumpEventQueue();
  await bob.close();
}

String hexOf(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// Room frames as the app reads them: `[2][room 16][from 16][payload]`; and packets: `[1][from 16][payload]`.
List<int> roomIndexes(Slow s, String room) => [for (final f in s.frames) if (f[0] == Hub.toRoom && hexOf(f.sublist(1, 17)) == room) indexOf(f.sublist(33))];
List<int> peerIndexes(Slow s) => [for (final f in s.frames) if (f[0] == Hub.toPeer) indexOf(f.sublist(17))];

/// A relay on this machine whose errors, wherever they happen in it, are kept for the test to look at.
Future<({Hub hub, int port, List<String> errors})> relayWith(WireBudget wire) async {
  final errors = <String>[];
  late final Hub hub;
  late final Relay relay;
  late final int port;
  await runZonedGuarded(() async {
    hub = Hub(wire: wire);
    relay = Relay(hub: hub, wire: wire);
    port = await relay.start(port: 0);
  }, (e, s) => errors.add('$e'.split('\n').first));
  addTearDown(relay.stop);
  return (hub: hub, port: port, errors: errors);
}

/// A socket for [GuardedSocket] that only counts how often it was destroyed.
class _Counted extends Stream<Uint8List> implements Socket {
  int destroyed = 0;
  final _done = Completer<void>();
  @override
  Future get done => _done.future;
  @override
  void destroy() => destroyed++;
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) => const Stream<Uint8List>.empty().listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connection in memory that goes the moment it is written to, its going heard at once (as a socket destroyed under
/// a write could be): what a loop over a room's members must not be thrown by.
class _GoesWhenWritten implements HubSocket {
  _GoesWhenWritten();
  final _in = StreamController<Object?>(sync: true);
  final _out = StreamController<Object?>();
  bool armed = false, _open = true;
  int frames = 0;
  @override
  Stream<Object?> get incoming => _in.stream;
  Stream<Object?> get said => _out.stream;
  void say(Object data) => _in.add(data);
  @override
  void add(Object data) {
    if (!_open) return;
    if (data is List<int>) frames++;
    _out.add(data);
    if (armed && data is List<int>) {
      _open = false;
      _in.close();
    }
  }

  @override
  bool get isOpen => _open;
  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    if (!_in.isClosed) await _in.close();
  }
}

void main() {
  test('a phone reading slowly joins two full rooms with 150 packets held, is put away, comes back: nothing ended, each once, in order', () async {
    final wire = WireBudget();
    final r = await relayWith(wire);
    final rooms = [for (var i = 0; i < 2; i++) (hex(16), hex(32))];
    for (final (room, token) in rooms) {
      await keepIndexed(r.hub, room, token, 300, 60 << 10);
    }
    final me = someBytes(32);
    await holdIndexed(r.hub, idOf(me), 150, 6000);
    final phone = await Slow.open(r.port, rate: 400 << 10, name: 'phone', rcvbuf: 64 << 10);
    expect((await phone.signIn(me, device: 'p1'))['held'], 150);
    for (final (room, token) in rooms) {
      phone.sendText({'join': room, 'token': token});
    }
    var most = 0;
    final watch = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (wire.used > most) most = wire.used;
    });
    await Future<void>.delayed(const Duration(seconds: 4));
    phone.away();
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(phone.isClosed, isFalse, reason: 'not ended while put away');
    phone.back();
    phone.rate = 0;
    expect(await phone.until(() => phone.frames.length >= 750 || phone.isClosed, within: const Duration(minutes: 2)), isTrue);
    watch.cancel();
    expect([phone.isClosed, wire.ended], [false, 0]);
    expect(peerIndexes(phone), [for (var i = 0; i < 150; i++) i], reason: 'held: once each, in order');
    for (final (room, _) in rooms) {
      expect(roomIndexes(phone, room), [for (var i = 0; i < 300; i++) i], reason: 'kept: once each, in order');
    }
    expect(most, lessThan(2 << 20), reason: 'a piece at a time: never more than a little waiting');
    expect(r.errors, isEmpty);
    phone.cut();
  });

  test('a phone replaced by its own next connection while it reads what was held: everything once, nothing thrown', () async {
    final wire = WireBudget();
    final r = await relayWith(wire);
    final me = someBytes(32), id = idOf(me);
    await holdIndexed(r.hub, id, 150, 6000);
    final r1 = await Slow.open(r.port, rate: 30 << 10, name: 'r1', rcvbuf: 32 << 10);
    expect((await r1.signIn(me, device: 'p1'))['held'], 150);
    await r1.until(() => peerIndexes(r1).length >= 25);
    // The same device again (the phone's network changed): the old connection is closed, and it goes on reading.
    final r2 = await Slow.open(r.port, name: 'r2');
    final told = (await r2.signIn(me, device: 'p1'))['held'] as int;
    await r2.until(() => peerIndexes(r2).length >= told);
    await r1.until(() => r1.isClosed, within: const Duration(seconds: 60));
    final both = [...peerIndexes(r1), ...peerIndexes(r2)];
    expect(both.toSet().length, both.length, reason: 'no packet twice');
    expect(both.toSet(), {for (var i = 0; i < 150; i++) i}, reason: 'every packet once');
    expect(r.hub.heldFor(id), 0);
    expect(r.errors, isEmpty, reason: 'nothing written to the closed connection');
    r2.cut();
  });

  test('what a replaced connection wasn\'t yet handed is kept again before its replacement takes what is held: it gets it all', () async {
    final clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 64 << 10, now: () => clock);
    final r = await relayWith(wire);
    final me = someBytes(32), id = idOf(me);
    await holdIndexed(r.hub, id, 150, 6000);
    // Forty connections each holding a little of a message (none stalled, as the clock stands still) fill the budget,
    // so the hand-over waits: nothing of it is written.
    final fillers = <Slow>[];
    for (var i = 0; i < 45; i++) {
      final f = await Slow.open(r.port, name: 'f$i');
      f.socket.add([0x81, 0x80 | 126, 0x07, 0xd0, 0, 0, 0, 0, ...List.filled(1500, 0x20)]);
      fillers.add(f);
    }
    expect(await fillers.first.until(() => wire.used >= wire.most), isTrue, reason: 'the budget never filled');
    final r1 = await Slow.open(r.port, name: 'r1');
    expect((await r1.signIn(me, device: 'p1'))['held'], 150);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(peerIndexes(r1), isEmpty, reason: 'no room: it waits');
    final r2 = await Slow.open(r.port, name: 'r2');
    expect((await r2.signIn(me, device: 'p1'))['held'], 150, reason: 'all of it kept again when the first was closed, before the second took it');
    for (final f in fillers) {
      f.cut();
    }
    expect(await r2.until(() => peerIndexes(r2).length >= 150), isTrue);
    expect(peerIndexes(r2), [for (var i = 0; i < 150; i++) i]);
    expect(peerIndexes(r1), isEmpty);
    expect(r.errors, isEmpty);
    r2.cut();
  });

  test('a room\'s kept messages to a connection replaced while it still reads: nothing more is written to the old one after its close', () async {
    final wire = WireBudget();
    final r = await relayWith(wire);
    final room = hex(16), token = hex(32);
    await keepIndexed(r.hub, room, token, 300, 60 << 10);
    final me = someBytes(32);
    final r1 = await Slow.open(r.port, rate: 600 << 10, name: 'r1', rcvbuf: 32 << 10);
    await r1.signIn(me, device: 'p1');
    r1.sendText({'join': room, 'token': token});
    await r1.until(() => roomIndexes(r1, room).length >= 40);
    final r2 = await Slow.open(r.port, name: 'r2');
    await r2.signIn(me, device: 'p1');
    r2.sendText({'join': room, 'token': token});
    expect(await r2.until(() => roomIndexes(r2, room).length >= 300), isTrue);
    await r1.until(() => r1.isClosed, within: const Duration(seconds: 90));
    final got1 = roomIndexes(r1, room);
    expect([for (var i = 1; i < got1.length; i++) if (got1[i] != got1[i - 1] + 1) i], isEmpty, reason: 'the old one\'s, in order, without a gap');
    expect(roomIndexes(r2, room), [for (var i = 0; i < 300; i++) i]);
    expect(r.errors, isEmpty, reason: 'nothing written to the closed connection ("StreamSink is closed")');
    r2.cut();
  });

  test('something said live during a room\'s hand-over comes after what was kept, not among it (a deletion after the message it deletes)', () async {
    final wire = WireBudget();
    final r = await relayWith(wire);
    final room = hex(16), token = hex(32);
    await keepIndexed(r.hub, room, token, 300, 60 << 10);
    final poster = await Slow.open(r.port, name: 'poster');
    await poster.signIn(someBytes(32), device: 'x');
    poster.sendText({'join': room, 'token': token});
    final phone = await Slow.open(r.port, rate: 500 << 10, name: 'phone', rcvbuf: 32 << 10);
    await phone.signIn(someBytes(32), device: 'p');
    phone.sendText({'join': room, 'token': token});
    await phone.until(() => roomIndexes(phone, room).isNotEmpty);
    poster.sendBinary([Hub.toRoomKept, ...unhex(room), ...indexed(5000, 100)]);
    poster.sendBinary([Hub.toRoom, ...unhex(room), ...indexed(5001, 100)]);
    expect(await phone.until(() => roomIndexes(phone, room).length >= 302, within: const Duration(seconds: 90)), isTrue);
    expect(roomIndexes(phone, room), [for (var i = 0; i < 300; i++) i, 5000, 5001]);
    expect(r.errors, isEmpty);
    phone.cut();
    poster.cut();
  });

  test('a member ended by the budget in the middle of a room\'s broadcast: the loop runs on, and the members after it get every packet', () async {
    var clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 4 << 20, now: () => clock);
    final r = await relayWith(wire);
    final room = hex(16), token = hex(32);
    Future<Slow> member(String name, {int? rcvbuf}) async {
      final s = await Slow.open(r.port, name: name, rcvbuf: rcvbuf);
      await s.signIn(someBytes(32), device: name);
      s.sendText({'join': room, 'token': token});
      await s.until(() => s.texts.any((m) => m['room'] == room));
      return s;
    }

    final a = await member('A'), b = await member('B', rcvbuf: 16 << 10), c = await member('C');
    // B stops reading: what A says (a packet every few milliseconds, which C reads as it comes) waits for B at the door,
    // past the 4 MB for everyone; the clock stands still, so nobody is stalled yet.
    b.away();
    for (var i = 0; i < 160; i++) {
      a.sendBinary([Hub.toRoom, ...unhex(room), ...indexed(i, 60 << 10)]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(await c.until(() => roomIndexes(c, room).length >= 160, within: const Duration(seconds: 60)), isTrue);
    expect(wire.ended, 0);
    // Three seconds on B is stalled, and the next packet's broadcast has the budget end it, in the middle of the loop.
    clock = clock.add(const Duration(seconds: 3));
    a.sendBinary([Hub.toRoom, ...unhex(room), ...indexed(1000, 60 << 10)]);
    expect(await c.until(() => roomIndexes(c, room).contains(1000)), isTrue, reason: 'C, after B in the room, got the packet');
    expect(roomIndexes(c, room), [for (var i = 0; i < 160; i++) i, 1000]);
    expect(wire.ended, 1);
    b.back();
    expect(await b.until(() => b.isClosed, within: const Duration(seconds: 10)), isTrue, reason: 'B was ended');
    expect(r.errors, isEmpty, reason: 'the room\'s list of members was not changed under its loop');
    a.cut();
    c.cut();
  });

  test('a connection the budget ends is told at once, and its socket destroyed a moment after, never in the middle of what was writing', () async {
    var clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 1 << 20, now: () => clock);
    final raw = _Counted();
    final stuck = GuardedSocket(raw, FrameGuard(most: 1 << 20), budget: wire);
    stuck.hold.incoming(900 << 10);
    clock = clock.add(const Duration(seconds: 3));
    // Stalled three seconds, it is the one that goes when another's write takes everyone past the budget.
    final writer = wire.open(() {});
    expect(writer.queued(300 << 10), isTrue);
    expect([stuck.hold.gone, raw.destroyed], [true, 0], reason: 'ended, and its socket not yet destroyed: not inside the write');
    await pumpEventQueue();
    expect(raw.destroyed, 1, reason: 'destroyed a moment after');
  });

  test('a member that goes in the middle of a room\'s broadcast, its going heard at once: the loop runs on over the rest', () async {
    final hub = Hub();
    final room = hex(16), token = hex(32);
    Future<_GoesWhenWritten> member() async {
      final m = _GoesWhenWritten();
      final hello = Completer<Map>();
      m.said.listen((d) {
        if (d is String && !hello.isCompleted) hello.complete(jsonDecode(d) as Map);
      });
      hub.attach(m);
      final scalar = someBytes(32), key = P256.publicOf(scalar);
      final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...unhex((await hello.future)['hello'] as String)], someBytes(32));
      m.say(jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig)}));
      await pumpEventQueue();
      m.say(jsonEncode({'join': room, 'token': token}));
      await pumpEventQueue();
      return m;
    }

    final sender = await member(), goes = await member(), after = await member();
    goes.armed = true;
    // (Thrown in the hub's loop, a ConcurrentModificationError would fail this test as it happened.)
    sender.say(Uint8List.fromList([Hub.toRoom, ...unhex(room), 1, 2, 3]));
    await pumpEventQueue();
    expect([goes.frames, after.frames], [1, 1], reason: 'the member after the one that went got the packet');
    expect(goes.isOpen, isFalse);
  });
}
