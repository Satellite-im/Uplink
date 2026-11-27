import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/ws_door.dart';
import 'package:test/test.dart';

import 'fed_support.dart' show MemSocket, someBytes, unhex;
import 'slow_client.dart';
import 'ws_door_test.dart' show frame;

/// What every connection together may hold in memory (lib/ws_door.dart, WireBudget). The first version ended a
/// connection for how much it was given at one moment, and the second review (2026-11-23) showed what that did: a phone
/// joining a room whose 200 kept messages of 48 KB were written in one go was ended though it read them as fast as they
/// came, and came back to be ended again; and strangers each holding a little made an honest phone the largest holder,
/// so the one ended. Now a connection is ended only for holding what it has stopped moving, and the hub hands over what
/// it keeps only as fast as the connection takes it. The doors here are real ones on this machine.

Future<void> until(bool Function() ok, String what, {int tries = 2000}) async {
  for (var i = 0; i < tries && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// A connection to [port]'s door at [path], upgraded by hand. Where [reads] is false, nothing is read after the
/// answer to the upgrade: everything the door sends it waits, first in the machine's own buffers, then at the door.
class Client {
  Client._(this.socket);
  final Socket socket;
  final closed = Completer<void>();

  static Future<Client> open(int port, String path, {bool reads = true}) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final c = Client._(s);
    final got = BytesBuilder();
    final head = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    sub = s.listen(
      (d) {
        if (head.isCompleted) return;
        got.add(d);
        if (latin1.decode(got.toBytes()).contains('\r\n\r\n')) {
          head.complete();
          if (!reads) sub.pause();
        }
      },
      onDone: () {
        if (!c.closed.isCompleted) c.closed.complete();
      },
      onError: (_) {
        if (!c.closed.isCompleted) c.closed.complete();
      },
    );
    unawaited(s.done.then((_) {}, onError: (_) {}));
    s.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    await s.flush();
    await head.future.timeout(const Duration(seconds: 10));
    return c;
  }

  /// Sends [batch] up to [times] times; how many went before writing failed (the door had ended the connection).
  Future<int> sendUntilRefused(List<int> batch, int times) async {
    for (var i = 0; i < times; i++) {
      try {
        socket.add(batch);
        await socket.flush();
      } catch (_) {
        return i;
      }
    }
    return times;
  }
}

/// An app signed in to the hub at [port] over a real WebSocket, as Dart's own client does: what it was handed.
class App {
  App._(this.ws);
  final WebSocket ws;
  final said = <Map>[];
  final frames = <Uint8List>[];
  final closed = Completer<int?>();

  static Future<App> signIn(int port, {List<int>? scalar}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub');
    final app = App._(ws);
    final hello = Completer<Map>(), answer = Completer<Map>();
    ws.listen(
      (d) {
        if (d is String) {
          final m = jsonDecode(d) as Map;
          if (!hello.isCompleted) return hello.complete(m);
          if (!answer.isCompleted) return answer.complete(m);
          app.said.add(m);
        } else {
          app.frames.add(d as Uint8List);
        }
      },
      onDone: () {
        if (!app.closed.isCompleted) app.closed.complete(ws.closeCode);
      },
    );
    final mine = scalar ?? someBytes(32), key = P256.publicOf(mine);
    final sig = P256.sign(mine, [...utf8.encode(Hub.greeting), ...unhex((await hello.future)['hello'] as String)], someBytes(32));
    ws.add(jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig)}));
    app.signedIn = await answer.future.timeout(const Duration(seconds: 5));
    expect(app.signedIn['ok'], isTrue);
    return app;
  }

  late final Map signedIn;

  void join(String room, String token) => ws.add(jsonEncode({'join': room, 'token': token}));
}

/// A connection to [hub] in memory, signed in as [scalar]'s key (a fresh one where none).
Future<MemSocket> memSignIn(Hub hub, {List<int>? scalar}) async {
  final (mine, theirs) = MemSocket.pair();
  final hello = Completer<Map>();
  mine.incoming.listen((d) {
    if (d is String && !hello.isCompleted) hello.complete(jsonDecode(d) as Map);
  });
  hub.attach(theirs);
  final s = scalar ?? someBytes(32), key = P256.publicOf(s);
  final sig = P256.sign(s, [...utf8.encode(Hub.greeting), ...unhex((await hello.future)['hello'] as String)], someBytes(32));
  mine.add(jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig)}));
  await pumpEventQueue();
  return mine;
}

/// Someone in [room] on [hub] over a connection in memory, who leaves [count] messages of [size] bytes kept there.
Future<void> keepIn(Hub hub, String room, String token, int count, int size) async {
  final mine = await memSignIn(hub);
  mine.add(jsonEncode({'join': room, 'token': token}));
  await pumpEventQueue();
  for (var i = 0; i < count; i++) {
    mine.add(Uint8List.fromList([Hub.toRoomKept, ...unhex(room), ...List.filled(size, i & 0xff)]));
  }
  await pumpEventQueue();
  expect(hub.keptIn(room), count);
  await mine.close();
}

String hex(int bytes) => [for (final b in someBytes(bytes)) b.toRadixString(16).padLeft(2, '0')].join();

void main() {
  group('the hub hands over what it keeps as fast as a device takes it', () {
    test('a room\'s 200 kept messages of 48 KB (9.6 MB) reach a phone joining it whole, and it is not ended for them', () async {
      final wire = WireBudget();
      final hub = Hub(wire: wire);
      final relay = Relay(hub: hub);
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      final room = hex(16), token = hex(32);
      await keepIn(hub, room, token, 200, 48 << 10);
      final phone = await App.signIn(port);
      phone.join(room, token);
      await until(() => phone.frames.length == 200 || phone.closed.isCompleted, 'the kept messages never all came', tries: 4000);
      expect([phone.frames.length, phone.closed.isCompleted, wire.ended], [200, false, 0]);
      await phone.ws.close();
    });

    test('three rooms of 3.5 MB joined at once all reach it', () async {
      final wire = WireBudget();
      final hub = Hub(wire: wire);
      final relay = Relay(hub: hub);
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      final rooms = [for (var i = 0; i < 3; i++) (hex(16), hex(32))];
      for (final (room, token) in rooms) {
        await keepIn(hub, room, token, 70, 50 << 10);
      }
      final phone = await App.signIn(port);
      for (final (room, token) in rooms) {
        phone.join(room, token);
      }
      await until(() => phone.frames.length == 210 || phone.closed.isCompleted, 'the kept messages never all came', tries: 4000);
      expect([phone.frames.length, phone.closed.isCompleted, wire.ended], [210, false, 0]);
      await phone.ws.close();
    });

    test('what is held for someone is handed over at sign-in the same way, in order; what wasn\'t written by the time the connection went is kept again', () async {
      final clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(most: 64 << 10, now: () => clock);
      final hub = Hub(wire: wire);
      final relay = Relay(hub: hub);
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      // Held for Maya while she is away: 150 packets of 6,000 bytes (a mailbox's megabyte), from Bob.
      final maya = someBytes(32), mayaId = Hub.nameOf(P256.publicOf(maya));
      final bob = await memSignIn(hub);
      void bobSends(int round) {
        for (var i = 0; i < 150; i++) {
          bob.add(Uint8List.fromList([Hub.toPeer, 0, 0, round, i + 1, ...unhex(mayaId), ...List.filled(6000, i)]));
        }
      }

      bobSends(0);
      await pumpEventQueue();
      expect(hub.heldFor(mayaId), 150);
      // She signs in and reads: every one, in order, though everyone together may hold only 64 KB.
      final phone = await App.signIn(port, scalar: maya);
      expect(phone.signedIn['held'], 150);
      await until(() => phone.frames.length == 150, 'what was held never all came');
      expect([for (final f in phone.frames) f[17]], [for (var i = 0; i < 150; i++) i], reason: 'in the order kept');
      expect([hub.heldFor(mayaId), wire.ended], [0, 0]);
      await phone.ws.close();
      await phone.closed.future;
      // Held for her again; strangers fill the budget (the clock stands still, so none of them is ended for it), and
      // her next connection is handed nothing before it goes: all of it is kept again.
      bobSends(1);
      await pumpEventQueue();
      final strangers = <Client>[];
      for (var i = 0; i < 5; i++) {
        final c = await Client.open(port, '/hub');
        c.socket.add(frame(1, List.filled(15000, 0x20), say: 16000));
        await c.socket.flush();
        strangers.add(c);
      }
      await until(() => wire.used > 64 << 10, 'the strangers never filled the budget');
      final again = await App.signIn(port, scalar: maya);
      expect(again.signedIn['held'], 150);
      await pumpEventQueue();
      expect(again.frames, isEmpty, reason: 'no room: it waits');
      expect(hub.heldFor(mayaId), 0);
      await again.ws.close();
      await again.closed.future;
      await until(() => hub.heldFor(mayaId) == 150, 'what it wasn\'t given was never kept again');
      for (final c in strangers) {
        c.socket.destroy();
      }
    });
  });

  group('a connection is ended for holding what it has stopped moving, never for a burst', () {
    test('a peer that floods pings, or pings in words, and never reads: once its answers pass a megabyte it is not read from, so they stop there', () async {
      final clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(now: () => clock);
      final relay = Relay(hub: Hub(wire: wire));
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      // Twenty megabytes of pings, written without waiting; and on another connection, signed in, pings in words of
      // 900 KB each, which the hub answers with as much.
      final deaf = await Client.open(port, '/hub', reads: false);
      final ping = frame(9, List.filled(125, 7));
      for (var i = 0; i < 160; i++) {
        deaf.socket.add([for (var k = 0; k < 1000; k++) ...ping]);
      }
      final talker = await Slow.open(port, name: 'talker');
      await talker.signIn(someBytes(32));
      talker.away();
      final words = '{"ping":"${'x' * 900000}"}';
      for (var i = 0; i < 20; i++) {
        talker.socket.add(frame(1, utf8.encode(words)));
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      var most = 0;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (wire.used > most) most = wire.used;
      }
      expect(most, lessThan(8 << 20), reason: 'two connections asking for answers they never read hold a few MB together, not the 20 and 18 they asked for');
      expect(wire.ended, 0, reason: 'nothing ended for it');
      deaf.socket.destroy();
      talker.cut();
    });

    test('a connection past its 8 MB for 10 seconds is ended, though it reads some of it all the while', () async {
      var clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(now: () => clock);
      final ended = <String>[];
      final h = wire.open(() => ended.add('h'));
      for (var second = 0; second < 12; second++) {
        h.queued(4 << 20);
        clock = clock.add(const Duration(seconds: 1));
        h.sent(WireBudget.outStep);
        wire.sweep();
      }
      expect(wire.ended, 1, reason: 'over 8 MB for 10 s, reading 64 KB a second');
      await pumpEventQueue();
      expect(ended, ['h']);
      // One that goes past and comes back under within the 10 seconds is not.
      final g = wire.open(() => ended.add('g'));
      g.queued(9 << 20);
      clock = clock.add(const Duration(seconds: 6));
      g.sent(2 << 20);
      clock = clock.add(const Duration(seconds: 6));
      wire.sweep();
      expect(wire.ended, 1);
      g.close();
    });

    test('66 strangers holding 15 KB each of an unfinished first message fill a 1 MB budget; an honest phone handed 80 KB is not the one ended', () async {
      var clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(most: 1 << 20, now: () => clock);
      final hub = Hub(wire: wire);
      final relay = Relay(hub: hub);
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      final room = hex(16), token = hex(32);
      await keepIn(hub, room, token, 2, 40 << 10);
      final strangers = <Client>[];
      for (var i = 0; i < 66; i++) {
        final c = await Client.open(port, '/hub');
        c.socket.add(frame(1, List.filled(15000, 0x20), say: 16000));
        await c.socket.flush();
        strangers.add(c);
      }
      await until(() => wire.used >= 66 * 15000, 'the strangers\' bytes never reached the door');
      clock = clock.add(const Duration(seconds: 5));
      final phone = await App.signIn(port);
      phone.join(room, token);
      await until(() => phone.frames.length == 2 || phone.closed.isCompleted, 'the phone never got what the room kept');
      expect([phone.frames.length, phone.closed.isCompleted], [2, false], reason: 'the honest phone is never the one ended');
      expect(wire.ended, greaterThan(0), reason: 'strangers stalled longest went to make room');
      for (final c in strangers) {
        c.socket.destroy();
      }
      await phone.ws.close();
    });

    test('a message coming in that stops growing ends its connection after a while, signed in or not; one that keeps coming does not', () async {
      var clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(now: () => clock);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final ws = await upgradeGuarded(request, most: 1 << 20, first: 1 << 20, budget: wire);
        ws?.listen((_) {}, onError: (_) {});
      });
      final stuck = await Client.open(server.port, '/'), moving = await Client.open(server.port, '/');
      stuck.socket.add(frame(2, List.filled(1000, 1), say: 900000));
      moving.socket.add(frame(2, List.filled(1000, 1), say: 900000));
      await stuck.socket.flush();
      await moving.socket.flush();
      await until(() => wire.used >= 2000, 'neither message reached the door');
      for (var step = 0; step < 3; step++) {
        clock = clock.add(const Duration(seconds: 8));
        moving.socket.add(List.filled(WireBudget.inStep, 1));
        await moving.socket.flush();
        await until(() => wire.used >= 2000 + (step + 1) * WireBudget.inStep || wire.ended > 0, 'the moving one\'s bytes never came');
        wire.sweep();
      }
      expect(wire.ended, 1, reason: '24 seconds without growing: past the 20 borne');
      await until(() => stuck.closed.isCompleted, 'the stuck one was never closed');
      expect(moving.closed.isCompleted, isFalse);
      stuck.socket.destroy();
      moving.socket.destroy();
    });

    test('a burst of 5 MB through a pairing to a reader is let through (as a link\'s window of 64 packets is)', () async {
      final clock = DateTime(2026, 11, 23, 12);
      final wire = WireBudget(now: () => clock);
      final relay = Relay(wire: wire);
      final port = await relay.start(port: 0);
      addTearDown(relay.stop);
      final channel = hex(16), auth = hex(32);
      final phone = await WebSocket.connect('ws://127.0.0.1:$port/$channel'), desk = await WebSocket.connect('ws://127.0.0.1:$port/$channel');
      final deskGot = <int>[];
      final deskReady = Completer<void>();
      desk.listen((d) {
        if (d is String) {
          if (!deskReady.isCompleted && (jsonDecode(d) as Map)['ok'] == true) deskReady.complete();
        } else {
          deskGot.add((d as List<int>).length);
        }
      });
      final phoneSaid = StreamIterator(phone);
      phone.add(jsonEncode({'auth': auth, 'role': 'phone', 'temp': true}));
      expect(await phoneSaid.moveNext(), isTrue);
      desk.add(jsonEncode({'auth': auth, 'role': 'desk', 'temp': true}));
      await deskReady.future.timeout(const Duration(seconds: 5));
      for (var i = 0; i < 5; i++) {
        phone.add(Uint8List(1 << 20));
      }
      await until(() => deskGot.length == 5, 'the frames never all crossed', tries: 4000);
      expect(wire.ended, 0, reason: 'a burst it reads ends nothing');
      await phone.close();
      await desk.close();
    });
  });

  test('the budget by itself, on its own clock', () async {
    var clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 4 << 20, eachOut: 2 << 20, now: () => clock);
    final ended = <String>[];
    WireHold hold(String name) => wire.open(() => ended.add(name));
    // Past its share: ended after 10 s past it, not before.
    final a = hold('a');
    expect(a.queued(3 << 20), isTrue);
    clock = clock.add(const Duration(seconds: 9));
    wire.sweep();
    expect(wire.ended, 0);
    clock = clock.add(const Duration(seconds: 1));
    wire.sweep();
    expect([wire.ended, ended], [1, ['a']], reason: 'counted, and told, at once (its socket destroys itself a moment after)');
    // Past everyone's: those stalled longest go first, then those past the big share (a megabyte here), the most first;
    // one moving and small never does.
    final b = hold('b'), c = hold('c'), d = hold('d'), e = hold('e'), small = hold('small');
    expect(b.incoming(1536 << 10), isTrue);
    clock = clock.add(const Duration(seconds: 5));
    expect(c.queued(1 << 20), isTrue);
    clock = clock.add(const Duration(seconds: 3));
    expect(d.queued(1640 << 10), isTrue, reason: 'past 4 MB: b, stalled 8 s, goes, and the rest fit');
    expect(wire.ended, 2);
    expect(e.queued(2 << 20), isTrue, reason: 'past again: c, stalled 3 s, goes');
    expect(wire.ended, 3);
    expect(small.queued(300 << 10), isTrue);
    expect(d.queued(200 << 10), isTrue, reason: 'past again, nobody stalled, nobody past the big share for two seconds: let through');
    expect(wire.ended, 3);
    clock = clock.add(const Duration(seconds: 2));
    wire.sweep();
    expect(wire.ended, 4, reason: 'two seconds on: e, past the big share and holding the most, goes');
    expect(ended, ['a', 'b', 'c', 'e']);
    expect(small.gone, isFalse);
    for (final x in [d, small]) {
      x.close();
    }
    // A message coming in that stops growing.
    final f = hold('f');
    f.incoming(1000);
    clock = clock.add(const Duration(seconds: 15));
    f.incoming(1000 + WireBudget.inStep);
    clock = clock.add(const Duration(seconds: 15));
    wire.sweep();
    expect(wire.ended, 4, reason: 'it grew by a step fifteen seconds ago');
    clock = clock.add(const Duration(seconds: 6));
    wire.sweep();
    expect(wire.ended, 5);
    // Room for a hand-over: called once what waits has gone down.
    final g = hold('g');
    g.queued(WireBudget.paceBelow);
    var called = 0;
    expect(g.hasRoom, isFalse);
    g.whenRoom(() => called++);
    g.sent(WireBudget.paceBelow);
    await pumpEventQueue();
    expect(called, 1);
    g.close();
    expect([wire.used, wire.holders], [0, 0]);
  });

  test('past everyone\'s budget, one reading slowly but always some, past the big share for two seconds, is ended: the budget is a ceiling', () async {
    var clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 2 << 20, now: () => clock);
    final slow = wire.open(() {}), honest = wire.open(() {});
    slow.queued(3 << 20);
    honest.queued(200 << 10);
    for (var step = 0; step < 3; step++) {
      clock = clock.add(const Duration(milliseconds: 500));
      slow.sent(WireBudget.outStep);
      honest.sent(100 << 10);
      honest.queued(100 << 10);
      wire.sweep();
    }
    expect(wire.ended, 0, reason: 'a second and a half: not yet');
    clock = clock.add(const Duration(milliseconds: 600));
    slow.sent(WireBudget.outStep);
    wire.sweep();
    expect([slow.gone, honest.gone], [true, false], reason: 'never stalled, but past a megabyte for two seconds while everyone is past the budget');
    honest.close();
  });

  test('hand-overs waiting: one waiting for its own connection is resumed by its own going down, never by looking at everyone; those waiting for the budget, in turn, while it has room', () async {
    final clock = DateTime(2026, 11, 23, 12);
    final wire = WireBudget(most: 1 << 20, now: () => clock);
    final own = wire.open(() {});
    own.queued(WireBudget.paceBelow);
    var ownGo = 0;
    own.whenRoom(() => ownGo++);
    expect(wire.waitingForRoom, 0, reason: 'it waits for its own connection, not for the budget');
    final filler = wire.open(() {});
    filler.incoming(1 << 20);
    final waiters = [for (var i = 0; i < 3; i++) wire.open(() {})];
    var went = 0;
    for (final w in waiters) {
      w.whenRoom(() => went++);
    }
    expect(wire.waitingForRoom, 3);
    own.sent(WireBudget.paceBelow);
    await pumpEventQueue();
    expect(ownGo, 0, reason: 'its connection took what it had, but the budget is full: it waits for the budget now');
    expect(wire.waitingForRoom, 4);
    filler.incoming(0);
    await pumpEventQueue();
    expect([went, ownGo, wire.waitingForRoom], [3, 1, 0]);
  });

  test('the budget\'s numbers are the relay\'s settings; one out of its range keeps the default, and is said', () {
    final problems = <String>[];
    final w = WireBudget.fromEnvironment({'GHOST_WIRE_MB': '96', 'GHOST_WIRE_EACH_MB': '16', 'GHOST_WIRE_STALL_S': '30', 'GHOST_WIRE_IN_STALL_S': 'soon'}, problems: problems);
    expect([w.most, w.eachOut, w.stallFor, w.inStallFor], [96 << 20, 16 << 20, const Duration(seconds: 30), const Duration(seconds: 20)]);
    expect(problems.single, contains('GHOST_WIRE_IN_STALL_S'));
    final d = WireBudget.fromEnvironment(const {});
    expect([d.most, d.eachOut, d.stallFor, d.inStallFor], [64 << 20, 8 << 20, const Duration(seconds: 10), const Duration(seconds: 20)]);
    final deploy = File('../tool/deploy-relay.mjs').readAsStringSync(), example = File('deploy/relay.env.example').readAsStringSync();
    for (final n in WireBudget.names) {
      expect(deploy, contains('$n:'), reason: '$n in the deploy script\'s known names');
      expect(example, contains(n), reason: '$n in relay.env.example');
    }
  });
}
