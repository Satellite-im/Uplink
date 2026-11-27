import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/lan/lan_carrier.dart';
import 'package:ghost_messaging/net/lan/lan_ground_io.dart';
import 'package:ghost_messaging/net/lan/lan_wire.dart';
import 'package:ghost_messaging/net/lan/lan_words.dart';

/// The local network route over real sockets (lib/net/lan/lan_ground_io.dart), on this machine's loopback only: what
/// the review of 2026-11-26 found that a network in memory can't show (test/lan_review_test.dart has the rest). Each
/// of these failed against the route as 0.12.41 shipped it.
///
/// - **The air died at the first beacon that couldn't be sent** (finding 1). dart:io's send never throws for a network
///   error: it answers 0, reports the error on the socket's stream a moment later and closes the socket. The route
///   expected a throw, so after one beacon that could not be sent (a laptop awake before its Wi-Fi, a Mac's Local
///   Network switch not yet answered) it said it was ready and neither said nor heard anything again.
/// - **Floods stopped the app** (finding 6). The route's sockets are read on the app's own isolate, and dart:io hands
///   over what a socket holds for as long as it has more. Nothing ever stopped reading: whoever sent faster than the
///   device could look kept its isolate from getting back to anything else.
/// - **Errors nobody took** (finding 10): a connection reset the moment it was made threw inside the door's callback,
///   and one reset after something was said on it came out of the socket's `done` with nobody listening.

/// Waits, up to twenty seconds, for [ok]: never a fixed time, which a busy machine does not keep.
Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 4000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// How late this isolate may run a 10 ms timer while someone floods it, in ms: half a second, and whatever it is late
/// by with nothing coming at all on a machine as busy as this one is now (other tests run beside this one), three
/// times over. Before the route kept count, a flood held the isolate for as long as it lasted: seconds.
Future<int> _mayStall() async => 500 + 3 * await _longestStall(() => Future<void>.delayed(const Duration(milliseconds: 500)));

/// The longest time, in ms, between two firings of a 10 ms timer while [during] runs.
Future<int> _longestStall(Future<void> Function() during) async {
  final clock = Stopwatch()..start();
  var last = 0, longest = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final now = clock.elapsedMilliseconds;
    if (now - last > longest) longest = now - last;
    last = now;
  });
  await during();
  await Future<void>.delayed(const Duration(milliseconds: 30));
  timer.cancel();
  return longest;
}

/// In another isolate: says [beacon] to 127.0.0.1:[port] as fast as it will go, for [ms] milliseconds. How many went.
Future<int> _sayFast((int port, Uint8List beacon, int ms) a) => Isolate.run(() async {
      final loop = InternetAddress.loopbackIPv4;
      var socket = await RawDatagramSocket.bind(loop, 0);
      final clock = Stopwatch()..start();
      var sent = 0;
      while (clock.elapsedMilliseconds < a.$3) {
        var went = 0;
        for (var i = 0; i < 400; i++) {
          if (socket.send(a.$2, loop, a.$1) > 0) went++;
        }
        sent += went;
        // A send that failed closes the socket (dart:io): another is opened.
        await Future<void>.delayed(Duration.zero);
        if (went == 0) {
          socket.close();
          socket = await RawDatagramSocket.bind(loop, 0);
        }
      }
      socket.close();
      return sent;
    });

/// In another isolate: connects to the door at 127.0.0.1:[port], proves to be [me] to [them]'s device as the route's
/// own dialler does (it holds the pair's key: it is a friend's device), then says [count] frames on the link, each
/// sealed and counted as the link asks, of kind 0 ("a word to keep the link"), all at once, and holds the connection
/// open a few seconds more. How many it said.
Future<int> _friendFloods((int port, List<int> key, String me, String them, List<int> theirRun, int count) a) => Isolate.run(() async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, a.$1);
      socket.setOption(SocketOption.tcpNoDelay, true);
      unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      final framer = LanFramer();
      final frames = StreamIterator(socket.expand(framer.add).handleError((Object _) {}));
      final myRun = List.generate(8, (i) => 0xE0 + i), nonce = List.generate(16, (i) => i * 3);
      final bucket = LanWords.bucketOf(DateTime.now().millisecondsSinceEpoch);
      socket.add(LanFramer.wrap(Uint8List.fromList(
          [1, ...myRun, ...nonce, (bucket >> 24) & 0xff, (bucket >> 16) & 0xff, (bucket >> 8) & 0xff, bucket & 0xff, ...LanWords.knock(a.$2, from: a.$3, to: a.$4, dialer: myRun, listener: a.$5, nonce: nonce, bucket: bucket)])));
      if (!await frames.moveNext().timeout(const Duration(seconds: 5))) return -1;
      final answer = frames.current;
      final transcript = LanWords.transcript(dialerAccount: a.$3, listenerAccount: a.$4, dialer: myRun, listener: a.$5, dialerNonce: nonce, listenerNonce: answer.sublist(1, 17));
      socket.add(LanFramer.wrap(Uint8List.fromList([3, ...LanWords.proof(a.$2, transcript, dialing: true)])));
      final seals = LanWords.sealKey(a.$2, transcript, dialing: true);
      // Made beforehand, as a device that means harm would: said in one go.
      final all = BytesBuilder(copy: false);
      for (var i = 0; i < a.$6; i++) {
        final clear = Uint8List(9);
        ByteData.sublistView(clear).setUint32(4, i);
        all.add(LanFramer.wrap(Uint8List.fromList([4, ...NetCrypto.seal(seals, clear)])));
      }
      try {
        socket.add(all.takeBytes());
        await socket.flush().timeout(const Duration(seconds: 4));
      } catch (_) {
        // The other end closed the link while it was being said to: what the route is meant to do.
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      socket.destroy();
      return a.$6;
    });

/// SO_LINGER on with no time: closing sends a reset, as a device that means harm (or an app that was killed) does.
RawSocketOption _reset() {
  final b = ByteData(8)
    ..setInt32(0, 1, Endian.host)
    ..setInt32(4, 0, Endian.host);
  return Platform.isMacOS || Platform.isIOS ? RawSocketOption(0xffff, 0x0080, b.buffer.asUint8List()) : RawSocketOption(1, 13, b.buffer.asUint8List());
}

void main() {
  final ann = NetKeys.generate(), ben = NetKeys.generate();
  final annBen = NetCrypto.netKey(NetCrypto.conversationKey(ann, ben.public)!);
  final annPeer = Peer(id: ann.id, key: annBen), benPeer = Peer(id: ben.id, key: annBen);
  final loop = InternetAddress.loopbackIPv4;
  const here = ['127.0.0.1'];
  bool allowed(String x) => x == '127.0.0.1';

  Future<int> free() async {
    final s = await RawDatagramSocket.bind(loop, 0);
    final p = s.port;
    s.close();
    return p;
  }

  group('a beacon that can\'t be sent (finding 1)', () {
    const policy = LanPolicy(beatEvery: Duration(milliseconds: 100), yieldFor: Duration(milliseconds: 100), sleepsAway: false);

    /// Ann's device and Ben's on loopback; Ann's says its beacons to [annSaysTo], which the test may change. A beacon
    /// to 192.0.2.1 from a socket at loopback can't be sent (this Mac answers "Can't assign requested address", and
    /// nothing leaves the machine): the same path any failed send takes.
    Future<(LanCarrier, LanCarrier)> pairOf(List<InternetAddress> annSaysTo) async {
      final pa = await free(), pb = await free();
      final a = LanCarrier(me: ann.id, ground: LanSockets(port: pa, sayPort: pb, bind: loop, beaconTo: annSaysTo, local: here), people: () => [benPeer], policy: policy, allowed: allowed);
      final b = LanCarrier(me: ben.id, ground: LanSockets(port: pb, sayPort: pa, bind: loop, beaconTo: [loop], local: here), people: () => [annPeer], policy: policy, allowed: allowed);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      return (a, b);
    }

    Future<void> waitForLink(LanCarrier a, LanCarrier b) => _until(() => a.links.length == 1 && b.links.length == 1);

    test('with every beacon sent, the two link over loopback', () async {
      final (a, b) = await pairOf([loop]);
      await a.start();
      await b.start();
      await waitForLink(a, b);
      expect([a.state.value, a.links.length, b.links.length], [CarrierState.up, 1, 1]);
    });

    test('is said: the route is down, and says why', () async {
      final (a, _) = await pairOf([InternetAddress('192.0.2.1')]);
      await a.start();
      await _until(() => a.state.value == CarrierState.down);
      expect([a.state.value, a.problem], [CarrierState.down, contains('Nothing can be said on the local network now')], reason: 'nothing was said, and Settings › Routes said the route was Ready');
      // And it stays so, beacon after beacon that can't be sent.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(a.state.value, CarrierState.down);
    });

    test('and once the network is back, the route says and hears again', () async {
      final annSaysTo = <InternetAddress>[InternetAddress('192.0.2.1')];
      final (a, b) = await pairOf(annSaysTo);
      await a.start();
      await _until(() => a.state.value == CarrierState.down);
      expect(a.state.value, CarrierState.down);
      // The network is back: from here every beacon of Ann's goes where Ben's device listens, and Ben's device is here.
      annSaysTo
        ..clear()
        ..add(loop);
      await b.start();
      await waitForLink(a, b);
      await _until(() => a.state.value == CarrierState.up);
      expect(
        [a.state.value, a.problem, a.seen, b.seen, a.links.length, b.links.length],
        [CarrierState.up, isNull, 1, 1, 1, 1],
        reason: 'Ann\'s route said it was up, and in three seconds of beacons each way it neither said one nor heard one: its socket was closed by the first that failed',
      );
    });
  });

  group('floods (finding 6)', () {
    const policy = LanPolicy(beatEvery: Duration(milliseconds: 200), sleepsAway: false);

    test('a stranger\'s beacons, however fast they come, do not stop the app\'s isolate', () async {
      final port = await free(), other = await free();
      // Ben's device, with one friend. The stranger holds no key.
      final b = LanCarrier(me: ben.id, ground: LanSockets(port: port, sayPort: other, bind: loop, beaconTo: [loop], local: here), people: () => [annPeer], policy: policy, allowed: allowed);
      addTearDown(b.dispose);
      await b.start();
      expect(b.state.value, CarrierState.up);
      // One beacon of nothing, as long as a beacon may be, of the ten minutes it is now: said again and again.
      final beacon = LanBeacon(
        instance: Uint8List.fromList(List.generate(8, (i) => 0xA0 + i)),
        port: 4000,
        bucket: LanWords.bucketOf(DateTime.now().millisecondsSinceEpoch),
        marks: [for (var m = 0; m < LanBeacon.mostMarks; m++) NetCrypto.randomBytes(8)],
      ).encode();
      var sent = 0;
      final may = await _mayStall();
      final stall = await _longestStall(() async => sent = await _sayFast((port, beacon, 2000)));
      expect(sent, greaterThan(10000), reason: 'the stranger said them');
      expect(stall, lessThan(may), reason: 'while a stranger said $sent beacons in two seconds, this isolate ran nothing else for $stall ms at a stretch');
      expect(b.droppedBeacons, greaterThan(0), reason: 'most were dropped before anything was done with them');
      // And it still hears: Ann's device, started now, is found and linked.
      final a = LanCarrier(me: ann.id, ground: LanSockets(port: other, sayPort: port, bind: loop, beaconTo: [loop], local: here), people: () => [benPeer], policy: policy, allowed: allowed);
      addTearDown(a.dispose);
      await a.start();
      await _until(() => a.links.length == 1 && b.links.length == 1);
      expect([a.links.length, b.links.length], [1, 1]);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a friend\'s device, however much it says on a link, does not stop the app\'s isolate, and is held to what a link may bring', () async {
      final port = await free(), other = await free();
      final b = LanCarrier(me: ben.id, ground: LanSockets(port: port, sayPort: other, bind: loop, beaconTo: [loop], local: here), people: () => [annPeer], policy: policy, allowed: allowed);
      addTearDown(b.dispose);
      // What Ben's device says to everyone: its run and its door's port.
      final heard = Completer<LanBeacon>();
      final ear = await RawDatagramSocket.bind(loop, other);
      ear.listen((_) {
        final d = ear.receive();
        final beacon = d == null ? null : LanBeacon.decode(d.data);
        if (beacon != null && !heard.isCompleted) heard.complete(beacon);
      });
      await b.start();
      final bens = await heard.future.timeout(const Duration(seconds: 5));
      ear.close();
      var linked = false, linkedAtEnd = -1, said = 0;
      // 300,000 frames of 42 bytes: 12.6 MB, a second or two of an ordinary network.
      const count = 300000;
      final may = await _mayStall();
      final stall = await _longestStall(() async {
        final flood = _friendFloods((bens.port, LanWords.keyOf(annBen), ann.id, ben.id, bens.instance, count));
        // Ann's device is linked once it has proved itself; then it says its frames.
        for (var i = 0; i < 4000 && b.links.isEmpty && b.dropped == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (b.links.isNotEmpty) linked = true;
        }
        said = await flood;
        // Looked at once the friend's device has said everything and still holds its end open.
        linkedAtEnd = b.links.length;
      });
      expect(said, count, reason: 'the friend\'s device linked and said its frames');
      expect(
        [stall < may, linkedAtEnd, b.dropped],
        [true, 0, greaterThan(0)],
        reason: 'a friend\'s device said $count frames at once on one link (linked: $linked): this isolate ran nothing else for $stall ms at a stretch, '
            'the link was still held after ($linkedAtEnd), and nothing was counted as dropped (${b.dropped}): frames that are not packets passed no budget at all',
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('connections that are reset (finding 10)', () {
    test('one reset the moment it is made throws nothing in the door', () async {
      final errors = <Object>[];
      var came = 0, made = 0;
      late LanDoor door;
      await runZonedGuarded(() async {
        door = await LanSockets(bind: loop).door((w) {
          came++;
          unawaited(w.close());
        });
      }, (e, _) => errors.add(e));
      for (; made < 4000 && errors.isEmpty; made++) {
        final c = await RawSocket.connect(loop, door.port);
        c.setRawOption(_reset());
        await c.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await door.close();
      expect(errors, isEmpty, reason: 'after $made connections reset as they were made ($came reached the route), the door\'s own callback threw');
    });

    test('one the other end resets, after something was said on it, leaves no unhandled error', () async {
      // A door that refuses at once, as the route's does when it is over its limits: it destroys the connection without
      // reading what the other end has sent.
      final server = await ServerSocket.bind(loop, 0);
      server.listen((s) {
        s.setRawOption(_reset());
        s.destroy();
      });
      final errors = <Object>[];
      LanWire? wire;
      var done = false;
      await runZonedGuarded(() async {
        wire = await LanSockets(bind: loop).dial('127.0.0.1', server.port);
        // The knock, as the route says it the moment the connection is made.
        wire!.send(Uint8List(45));
        wire!.frames.listen((_) {}, onDone: () => done = true);
      }, (e, _) => errors.add(e));
      await _until(() => done);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await server.close();
      expect(done, isTrue, reason: 'the wire saw the connection close');
      expect(errors, isEmpty, reason: 'the wire closed itself as it should, and the same error came out of the socket\'s `done` with nobody listening');
    });
  });
}
