import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_factory.dart';
import 'package:ghost_messaging/net/p2p/node_ffi.dart';

/// The direct network's core from Dart (lib/net/p2p/node_ffi.dart; docs/OPEN_NETWORK.md, section 2): two and three
/// real nodes in this one process, the Rust library and all (native/p2p), linked over this machine's own loopback
/// address with no link helper. What a [P2pNode] promises is held to here through the library itself; the library's
/// own tests (`cargo test` in native/p2p) hold it to the rest: a link helper, a peer that speaks wrongly, what an idle
/// node costs.
///
/// Skipped where the library is not built: `sh tool/build-p2p.sh mac` builds it where these look
/// (build/p2p/mac/libghost_p2p.dylib), and GHOST_P2P_LIB names one anywhere else.

/// Waits for [ok], however long the machine takes (half a minute at most: other builds share it), not for a length
/// of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 6000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

P2pConfig _config(int n) => P2pConfig(secret: Uint8List.fromList(List.filled(32, n)));

/// A node, let go of when the test is over.
IrohNode _node() {
  final node = IrohNode.make()!;
  addTearDown(node.dispose);
  return node;
}

/// A node that is up, with the key [n] makes.
Future<IrohNode> _up(int n) async {
  final node = _node();
  await node.start(_config(n));
  expect(node.state.value, P2pState.up, reason: node.problem);
  return node;
}

final _ipv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+:(\d+)$');

/// Where [node] is, as another node on this machine dials it: the IPv4 address it says, as it says it (this
/// machine's own address on its network: a node dials no loopback address a hint names).
Future<Whereabouts> _here(IrohNode node) async {
  await _until(() => node.whereabouts.value?.addresses.any(_ipv4.hasMatch) ?? false, 'it never said where it is');
  return Whereabouts(addresses: [node.whereabouts.value!.addresses.firstWhere(_ipv4.hasMatch)]);
}

/// Everything a stream is handed, and whether it is done.
class _Heard {
  _Heard(P2pStream stream) {
    sub = stream.frames.listen(frames.add, onDone: () => done = true);
  }
  final frames = <Uint8List>[];
  late final StreamSubscription<Uint8List> sub;
  bool done = false;
}

/// The next stream another node opens to [node].
Future<P2pStream> _next(IrohNode node) => node.opened.first.timeout(const Duration(seconds: 30));

Matcher get _refused => throwsA(isA<P2pError>());
Matcher _saying(String words) => throwsA(isA<P2pError>().having((e) => e.message, 'message', contains(words)));

/// Whether nothing on this machine holds UDP [port] for IPv4 now.
Future<bool> _free(int port) async {
  try {
    (await RawDatagramSocket.bind(InternetAddress.anyIPv4, port)).close();
    return true;
  } on SocketException {
    return false;
  }
}

/// The port of the first IPv4 address in [addresses].
int _portOf(List<String> addresses) => int.parse(_ipv4.firstMatch(addresses.firstWhere(_ipv4.hasMatch))!.group(1)!);

/// An isolate of its own that starts a node (with the key [n] makes), lets [args]' node in, waits to hear where it is,
/// and ends with it still up: no stop, no dispose. It says where its node was as it ends. With `toPort`, the node is
/// left to be let go only by its port's closing (its finalizer is taken off).
Future<void> _leaveUp(List<Object?> args) async {
  final (done, n, allow, toPort) = (args[0]! as SendPort, args[1]! as int, args[2] as String?, args[3]! as bool);
  final node = IrohNode.make()!;
  await node.start(_config(n));
  if (allow != null) node.allow(allow, {P2pChannel.packets});
  while (!(node.whereabouts.value?.addresses.any(_ipv4.hasMatch) ?? false)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (toPort) node.debugLeaveToPort();
  Isolate.exit(done, [node.nodeId!, node.whereabouts.value!.addresses]);
}

/// An isolate of its own that is the first in it to open the core, makes a node, starts it, lets it go and ends.
Future<void> _useAndLeave(SendPort done) async {
  final node = IrohNode.make()!;
  await node.start(_config(91));
  node.dispose();
  Isolate.exit(done, true);
}

/// Where [key]'s 32 bytes are in [bytes], or -1.
int _find(Uint8List bytes, Uint8List key) {
  for (var i = 0; i + key.length <= bytes.length; i++) {
    var all = true;
    for (var j = 0; j < key.length && all; j++) {
      all = bytes[i + j] == key[j];
    }
    if (all) return i;
  }
  return -1;
}

void main() {
  final skip = IrohNode.available ? false : 'The direct network\'s core is not built here: sh tool/build-p2p.sh mac';
  const patient = Timeout(Duration(minutes: 3));

  test('the factory makes a node of the core, and a node id is worked out with nothing started', () async {
    final node = makeP2pNode();
    expect(node, isA<IrohNode>());
    addTearDown((node as IrohNode).dispose);
    expect(node.state.value, P2pState.off);
    expect(node.nodeId, isNull);
    expect(node.whereabouts.value, isNull);
    final id = await node.idOf(_config(1).secret);
    expect(isNodeId(id), isTrue);
    expect(await node.idOf(_config(1).secret), id);
    expect(await node.idOf(_config(2).secret), isNot(id));
    await expectLater(node.idOf(Uint8List(31)), _refused);
    // Not up: nothing opens.
    await expectLater(node.open(id, 0), _refused);
    // Started, it is the node its key makes.
    await node.start(_config(1));
    expect(node.state.value, P2pState.up);
    expect(node.nodeId, id);
  }, skip: skip, timeout: patient);

  test('frames go both ways, whole and in order: an empty one, the longest, a burst', () async {
    final a = await _up(11), b = await _up(12);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final coming = _next(b);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: await _here(b));
    final theirs = await coming;
    expect((ours.nodeId, ours.channel, ours.incoming), (b.nodeId, P2pChannel.packets, false));
    expect((theirs.nodeId, theirs.channel, theirs.incoming), (a.nodeId, P2pChannel.packets, true));
    final atA = _Heard(ours), atB = _Heard(theirs);

    final longest = Uint8List.fromList(List.generate(P2pNode.maxFrame, (i) => (i * 31) % 251));
    final sent = <Future<void>>[ours.add(Uint8List(0)), ours.add(longest)];
    for (var i = 0; i < 2000; i++) {
      sent.add(ours.add(Uint8List.fromList('small $i'.codeUnits)));
    }
    await Future.wait(sent);
    await _until(() => atB.frames.length == 2002, 'not everything arrived: ${atB.frames.length} of 2002');
    expect(atB.frames[0], isEmpty);
    expect(atB.frames[1], longest);
    for (var i = 0; i < 2000; i++) {
      expect(String.fromCharCodes(atB.frames[2 + i]), 'small $i');
    }
    // A frame is a list of its own: nothing of the library's bytes around it.
    expect(atB.frames[1].offsetInBytes, 0);
    expect(atB.frames[1].buffer.lengthInBytes, P2pNode.maxFrame);

    // The other way, on the same stream.
    await Future.wait([theirs.add(longest), theirs.add(Uint8List(0)), for (var i = 0; i < 500; i++) theirs.add(Uint8List.fromList([i >> 8, i & 255]))]);
    await _until(() => atA.frames.length == 502, 'not everything came back: ${atA.frames.length} of 502');
    expect(atA.frames[0], longest);
    expect(atA.frames[1], isEmpty);
    expect([for (final f in atA.frames.skip(2)) f[0] * 256 + f[1]], List.generate(500, (i) => i));

    // A frame past the longest is not sent at all, and the stream is none the worse.
    await expectLater(ours.add(Uint8List(P2pNode.maxFrame + 1)), _refused);

    // Closed by the one that opened it: what was sent just before still arrives, then the other end's frames are done.
    final last = ours.add(Uint8List.fromList('last'.codeUnits));
    await ours.close();
    await last;
    await ours.close();
    await _until(() => atB.done, 'the other end never saw the close');
    expect(String.fromCharCodes(atB.frames.last), 'last');
    expect(atB.frames.length, 2003);
    expect(atA.done, isTrue);
    await expectLater(ours.add(Uint8List(1)), _refused);
    await expectLater(theirs.add(Uint8List(1)), _refused);
    await theirs.close();
  }, skip: skip, timeout: patient);

  test('a node that was never allowed is turned away; one allowed a channel is refused another; a channel open to all takes anyone', () async {
    final a = await _up(21), b = await _up(22), stranger = await _up(23);
    final where = await _here(b);
    final taken = <P2pStream>[];
    b.opened.listen(taken.add);
    b.allow(a.nodeId!, {P2pChannel.packets});

    await expectLater(stranger.open(b.nodeId!, P2pChannel.packets, hint: where), _refused);
    await expectLater(a.open(b.nodeId!, P2pChannel.hub, hint: where), _refused);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
    await _until(() => taken.length == 1, 'the allowed stream never came');
    expect((taken.single.nodeId, taken.single.channel), (a.nodeId, P2pChannel.packets));

    // A relay hosted here takes hub connections from devices it never heard of, and nothing else from them.
    b.openToAll({P2pChannel.hub});
    final hub = await stranger.open(b.nodeId!, P2pChannel.hub, hint: where);
    await _until(() => taken.length == 2, 'the stream on the open channel never came');
    expect((taken.last.nodeId, taken.last.channel), (stranger.nodeId, P2pChannel.hub));
    await expectLater(stranger.open(b.nodeId!, P2pChannel.packets, hint: where), _refused);
    await expectLater(stranger.open(b.nodeId!, P2pChannel.relays, hint: where), _refused);

    // Open to nobody again: the stranger's stream ends, the allowed node's does not.
    final atStranger = _Heard(hub), atA = _Heard(ours);
    b.openToAll({});
    await _until(() => atStranger.done, 'the stream on a channel that is no longer open was left open');
    await ours.add(Uint8List.fromList([1]));
    expect(atA.done, isFalse);
  }, skip: skip, timeout: patient);

  test('disallow closes everything with that node, and it is turned away after', () async {
    final a = await _up(31), b = await _up(32);
    final where = await _here(b);
    a.allow(b.nodeId!, {P2pChannel.packets});
    b.allow(a.nodeId!, {P2pChannel.packets});
    final pathsAtB = <P2pPath>[];
    b.paths.listen(pathsAtB.add);
    var coming = _next(b);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
    final theirs = await coming;
    // And one the other way, over the link that is up: no hint needed.
    coming = _next(a);
    final back = await b.open(a.nodeId!, P2pChannel.packets);
    final backAtA = await coming;
    final heard = [_Heard(ours), _Heard(theirs), _Heard(back), _Heard(backAtA)];
    await _until(() => b.pathTo(a.nodeId!)?.kind == P2pPathKind.direct, 'the path never said straight');

    b.disallow(a.nodeId!);
    await _until(() => heard.every((h) => h.done), 'a stream was left open: ${[for (final h in heard) h.done]}');
    await _until(() => b.pathTo(a.nodeId!) == null && a.pathTo(b.nodeId!) == null, 'the link was left up');
    expect(pathsAtB.last.kind, P2pPathKind.none);
    expect(pathsAtB.last.nodeId, a.nodeId);
    await expectLater(a.open(b.nodeId!, P2pChannel.packets, hint: where), _refused);
    await expectLater(theirs.add(Uint8List(1)), _refused);
  }, skip: skip, timeout: patient);

  // The review of Direct's switch (2026-11-23): an open under way when its node was disallowed completed after, and
  // that node's frames were handed up. This side fails it as disallow returns, before anything the core says next;
  // the core closes its link and fails it too (native/p2p, src/tests.rs, an_open_under_way_when_its_node_is_disallowed).
  test('an open under way when its node is disallowed fails as disallow returns, and nothing of that node is handed up', () async {
    final a = await _up(106), b = await _up(107);
    a.allow(b.nodeId!, {P2pChannel.packets});
    b.allow(a.nodeId!, {P2pChannel.packets});
    final where = await _here(b);
    final atB = <P2pStream>[];
    b.opened.listen(atB.add);
    for (var round = 0; round < 3; round++) {
      Object? failed;
      final opening = a.open(b.nodeId!, P2pChannel.packets, hint: where, timeout: const Duration(seconds: 10));
      unawaited(opening.then<void>((s) => fail('round $round: the open came to a stream after the disallow'), onError: (Object e) => failed = e));
      a.disallow(b.nodeId!);
      // Microtasks only: whatever the core says comes later, by its port.
      await Future<void>.microtask(() {});
      expect(failed, isA<P2pError>(), reason: 'round $round: the open was still waiting once disallow had returned');
      // What the other end took of it, it sends on: nothing reaches a.
      for (final s in atB.toList()) {
        await s.add(Uint8List.fromList('from a node a disallowed'.codeUnits)).catchError((Object _) {});
      }
      await _until(() => a.pathTo(b.nodeId!) == null, 'round $round: a link to the disallowed node was left up');
      atB.clear();
      // Allowed again, an open goes.
      a.allow(b.nodeId!, {P2pChannel.packets});
      final coming = _next(b);
      final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
      final theirs = await coming;
      atB.remove(theirs);
      final heard = _Heard(ours);
      await theirs.add(Uint8List.fromList('allowed again'.codeUnits));
      await _until(() => heard.frames.isNotEmpty, 'round $round: nothing came once allowed again');
      await ours.close();
      await theirs.close();
      await heard.sub.cancel();
    }
  }, skip: skip, timeout: patient);

  test('stop then start is the same node, and works again and again; who was allowed is still allowed', () async {
    final a = await _up(41), b = await _up(42);
    final id = b.nodeId;
    b.allow(a.nodeId!, {P2pChannel.packets});
    final states = <P2pState>[];
    b.state.addListener(() => states.add(b.state.value));
    for (var round = 0; round < 3; round++) {
      final where = await _here(b);
      final coming = _next(b);
      final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
      final theirs = await coming;
      final atA = _Heard(ours), atB = _Heard(theirs);
      await ours.add(Uint8List.fromList([round]));
      await _until(() => atB.frames.length == 1, 'round $round: the frame never came');
      expect(atB.frames.single, [round]);
      await _until(() => a.pathTo(b.nodeId!)?.kind == P2pPathKind.direct, 'round $round: the path never said straight');
      expect(a.pathTo(b.nodeId!)!.rttMs, lessThan(1000));

      await b.stop();
      // Everything is closed by the time stop is done: its streams, where it was, its links.
      expect(b.state.value, P2pState.off);
      expect(b.whereabouts.value, isNull);
      expect(atB.done, isTrue);
      expect(b.pathTo(a.nodeId!), isNull);
      await expectLater(theirs.add(Uint8List(1)), _refused);
      await expectLater(b.open(a.nodeId!, P2pChannel.packets), _refused);
      await _until(() => atA.done && a.pathTo(b.nodeId!) == null, 'round $round: the other end never saw it go');
      await expectLater(a.open(b.nodeId!, P2pChannel.packets, hint: where, timeout: const Duration(seconds: 1)), _refused);

      await b.start(_config(42));
      expect(b.state.value, P2pState.up);
      expect(b.nodeId, id);
    }
    expect(states, [for (var i = 0; i < 3; i++) ...[P2pState.off, P2pState.starting, P2pState.up]]);
    // Started with what it is up with already: nothing happens.
    await b.start(_config(42));
    expect(states.length, 9);
    // With another key it is stopped and started: another node.
    await b.start(_config(43));
    expect(b.state.value, P2pState.up);
    expect(b.nodeId, isNot(id));
    expect(states.sublist(9), [P2pState.off, P2pState.starting, P2pState.up]);
    b.networkChanged();
  }, skip: skip, timeout: patient);

  test('a listener that pauses holds the sender back, and nothing is lost when it goes on', () async {
    final a = await _up(51), b = await _up(52);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final coming = _next(b);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: await _here(b));
    final theirs = await coming;
    final atB = _Heard(theirs);
    atB.sub.pause();
    // Three of the longest: the first is read and waits here for the listener; with it not taken there is no room for
    // the second, which is not read, and the sender is held where it is.
    final written = [false, false, false];
    final sent = [for (var i = 0; i < 3; i++) ours.add(Uint8List(P2pNode.maxFrame)..[0] = i).then((_) => written[i] = true)];
    await _until(() => written[0], 'the first frame was never sent');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(atB.frames, isEmpty);
    expect(written.sublist(1), [false, false], reason: 'frames went on being read with nobody taking them');
    atB.sub.resume();
    await Future.wait(sent);
    await _until(() => atB.frames.length == 3, 'a frame was lost: ${atB.frames.length} of 3');
    expect([for (final f in atB.frames) f[0]], [0, 1, 2]);
    expect(atB.frames.every((f) => f.length == P2pNode.maxFrame), isTrue);
  }, skip: skip, timeout: patient);

  test('more than a stream holds waiting closes it, and a stream nobody takes is closed', () async {
    final a = await _up(61), b = await _up(62);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final where = await _here(b);
    // Nobody at the far end listens for streams: the one that comes is closed there, and that is seen here.
    final unwanted = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
    final atUnwanted = _Heard(unwanted);
    await _until(() => atUnwanted.done, 'a stream nobody took was left open');

    // Taken, but its frames never listened to: they are not read past the first, the sender's queue fills, and the
    // sender's stream is closed rather than its queue grown.
    final coming = _next(b);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
    final theirs = await coming;
    final atA = _Heard(ours);
    Object? refusal;
    var queued = 0;
    for (; queued < 64 && refusal == null; queued++) {
      ours.add(Uint8List(P2pNode.maxFrame)).catchError((Object e) {
        refusal ??= e;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(refusal, isA<P2pError>(), reason: 'the queue took $queued frames of the longest and never filled');
    await _until(() => atA.done, 'the stream that overflowed was left open');
    await expectLater(ours.add(Uint8List(1)), _refused);
    // The far end, listening at last, is handed what had come before the end, and then the end.
    final atB = _Heard(theirs);
    await _until(() => atB.done, 'the far end never saw the end');
    expect(atB.frames.length, lessThanOrEqualTo(2));
  }, skip: skip, timeout: patient);


  // What the review of the core found (2026-11-23), each held to here.

  test('an isolate that ends with its node up leaves nothing of it running', () async {
    final port = ReceivePort();
    await Isolate.spawn(_leaveUp, <Object?>[port.sendPort, 81, null, false]);
    final said = await port.first as List;
    final udp = _portOf((said[1] as List).cast<String>());
    // Nothing was said to it since and nothing dials it: it is let go as the isolate ends (its finalizer), and its
    // socket is closed within moments.
    var free = false;
    for (var i = 0; i < 100 && !free; i++) {
      free = await _free(udp);
      if (!free) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(free, isTrue, reason: 'the node of an isolate that ended still holds its port $udp');
  }, skip: skip, timeout: patient);

  test('a node of an isolate that has gone, dialled, takes nothing down with it and is let go', () async {
    // The review's probe: a node left up by an isolate that exits, with its finalizer taken off, so that only what
    // the library does as it tries to tell a port that is gone stands between a caller and the process. (It was a
    // call into an isolate that had gone: "Callback invoked after it has been deleted", and the process aborted.)
    final port = ReceivePort();
    await Isolate.spawn(_leaveUp, <Object?>[port.sendPort, 82, await _node().idOf(_config(83).secret), true]);
    final said = await port.first as List;
    final (orphan, addresses) = (said[0] as String, (said[1] as List).cast<String>());
    final udp = _portOf(addresses);
    // Made once the other isolate has used the core and gone, as the review's probe did (a node made before would
    // have been let go by that isolate's first use, before the fix of the next test, and dialled nothing).
    final b = await _up(83);
    // It is dialled, by where it said it was, and a frame sent: what it would tell its isolate (the stream, the path)
    // goes nowhere, and the library lets it go.
    try {
      final s = await b.open(orphan, P2pChannel.packets, hint: Whereabouts(addresses: [addresses.firstWhere(_ipv4.hasMatch)]));
      await s.add(Uint8List.fromList([1, 2, 3]));
    } on P2pError {
      // Let go before it answered: as good.
    }
    var free = false;
    for (var i = 0; i < 100 && !free; i++) {
      free = await _free(udp);
      if (!free) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(free, isTrue, reason: 'a node whose isolate is gone, and was told so, still holds its port $udp');
    // And the process goes on, with its own node as it was.
    final c = await _up(84);
    c.allow(b.nodeId!, {P2pChannel.packets});
    expect((await b.open(c.nodeId!, P2pChannel.packets, hint: await _here(c))).nodeId, c.nodeId);
  }, skip: skip, timeout: patient);

  test('another isolate using the core leaves this one\'s nodes as they were', () async {
    // Each isolate is its own to the library (the port its events go to), not the Flutter engine it runs on, which
    // background isolates and the test runner have none of: the first use in another isolate let go of every node
    // this one had, while their IrohNode said they were up.
    final a = await _up(92), b = await _up(93);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final where = await _here(b);
    final port = ReceivePort();
    await Isolate.spawn(_useAndLeave, port.sendPort);
    expect(await port.first, isTrue);
    final coming = _next(b);
    final s = await a.open(b.nodeId!, P2pChannel.packets, hint: where);
    final t = await coming;
    final heard = _Heard(t);
    await s.add(Uint8List.fromList([7]));
    await _until(() => heard.frames.length == 1, 'the frame never came');
  }, skip: skip, timeout: patient);

  test('a release app opens the copy of the core it carries, and nothing its environment or its folder names', () {
    const mac = '/Applications/Uplink.app/Contents/MacOS/Uplink';
    expect(IrohNode.libraryPlaces(release: true, os: 'macos', program: mac, current: '/Users/someone', named: '/tmp/another.dylib'), [
      '/Applications/Uplink.app/Contents/Frameworks/libghost_p2p.dylib',
    ]);
    expect(IrohNode.libraryPlaces(release: false, os: 'macos', program: mac, current: '/Users/someone', named: '/tmp/another.dylib'), [
      '/tmp/another.dylib',
      '/Applications/Uplink.app/Contents/Frameworks/libghost_p2p.dylib',
      '/Users/someone/build/p2p/mac/libghost_p2p.dylib',
    ]);
    expect(IrohNode.libraryPlaces(release: true, os: 'android', program: '/system/bin/app_process64', current: '/', named: '/sdcard/x.so'), ['libghost_p2p.so']);
    expect(IrohNode.libraryPlaces(release: true, os: 'linux', program: '/opt/ghost/ghost', current: '/home/x', named: '/tmp/x.so'), ['/opt/ghost/lib/libghost_p2p.so']);
    expect(IrohNode.libraryPlaces(release: true, os: 'windows', program: r'C:\Uplink\ghost.exe', current: r'C:\Users\x', named: r'C:\x.dll'), [r'C:\Uplink\ghost_p2p.dll']);
  });

  test('no copy of the node key is left in what the core was handed', () async {
    final key = _config(95).secret;
    final node = _node();
    await node.start(_config(95));
    expect(node.state.value, P2pState.up);
    expect(_find(IrohNode.debugCommandBuffer, key), -1, reason: 'the START, node key and all, is still in the command buffer');
  }, skip: skip, timeout: patient);

  test('a hint is dialled only where it names another device: never this one\'s own loopback address', () async {
    final a = await _up(96), b = await _up(97);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final where = await _here(b);
    final port = _portOf(where.addresses);
    // b is there, on this machine's loopback address too: a hint that names only that, in any of its forms, is not
    // dialled, and says so at once.
    final asked = Stopwatch()..start();
    final loopback = Whereabouts(addresses: ['127.0.0.1:$port', '127.1.2.3:$port', '[::1]:$port', '[::ffff:127.0.0.1]:$port', '0.0.0.0:$port', '169.254.1.1:$port']);
    await expectLater(a.open(b.nodeId!, P2pChannel.packets, hint: loopback, timeout: const Duration(seconds: 20)), _saying('Nothing is known'));
    expect(asked.elapsed, lessThan(const Duration(seconds: 10)));
    // By the address it says, it is found.
    expect((await a.open(b.nodeId!, P2pChannel.packets, hint: where)).nodeId, b.nodeId);
  }, skip: skip, timeout: patient);

  test('a burst of small frames reaches the app in a few batches, and what was taken is said once a batch', () async {
    final a = await _up(98), b = await _up(99);
    b.allow(a.nodeId!, {P2pChannel.packets});
    final coming = _next(b);
    final ours = await a.open(b.nodeId!, P2pChannel.packets, hint: await _here(b));
    final atB = _Heard(await coming);
    final batches = IrohNode.debugBatches, takens = IrohNode.debugTakens;
    const many = 3000;
    await Future.wait([for (var i = 0; i < many; i++) ours.add(Uint8List.fromList([i >> 8, i & 255]))]);
    await _until(() => atB.frames.length == many, 'not every frame came: ${atB.frames.length} of $many');
    expect([for (final f in atB.frames) f[0] * 256 + f[1]], List.generate(many, (i) => i));
    // (Both ends are in this isolate: the sender's batches of SENT count too.)
    expect(IrohNode.debugBatches - batches, lessThan(many ~/ 4), reason: 'a batch for every frame, or nearly');
    expect(IrohNode.debugTakens - takens, lessThan(many ~/ 4), reason: 'a TAKEN for every frame, or nearly');
  }, skip: skip, timeout: patient);

  test('disallow ends every stream with that node before it returns, and allow and openToAll those they no longer let in', () async {
    // "Before it returns" is before anything more can come from the library: a message from it is handled in a turn
    // of its own, after every microtask, so what is looked at a few microtasks on is what the call itself did.
    Future<void> sameTurn() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.value();
      }
    }

    final a = await _up(100), b = await _up(101);
    a.allow(b.nodeId!, {P2pChannel.packets});
    b.allow(a.nodeId!, {P2pChannel.packets, P2pChannel.hub});
    final there = await _here(b);
    var coming = _next(b);
    final fromA = await a.open(b.nodeId!, P2pChannel.packets, hint: there);
    final atB = _Heard(await coming);
    coming = _next(a);
    final toA = _Heard(await b.open(a.nodeId!, P2pChannel.packets));
    await coming;
    coming = _next(b);
    await a.open(b.nodeId!, P2pChannel.hub, hint: there);
    final hubAtB = _Heard(await coming);
    // Fewer channels: the stream on the one it lost is over at once, as far as b can see; the other is not.
    b.allow(a.nodeId!, {P2pChannel.packets});
    await sameTurn();
    expect([hubAtB.done, atB.done, toA.done], [true, false, false], reason: 'allow with fewer channels left a stream on one it lost open');
    // Disallowed: every stream with it, whichever end opened it, is over when disallow returns.
    b.disallow(a.nodeId!);
    await sameTurn();
    expect([atB.done, toA.done], [true, true], reason: 'a stream with a node that was disallowed was still open when disallow returned');
    final heard = _Heard(fromA);
    await _until(() => heard.done, 'the other end never saw its stream closed');
    // A channel open to all, closed again: what it let in is over at once.
    final stranger = await _up(102);
    b.openToAll({P2pChannel.relays});
    coming = _next(b);
    await stranger.open(b.nodeId!, P2pChannel.relays, hint: there);
    final relayAtB = _Heard(await coming);
    b.openToAll({});
    await sameTurn();
    expect(relayAtB.done, isTrue, reason: 'a stream on a channel no longer open to all was still open');
  }, skip: skip, timeout: patient);

  test('a first start that cannot be made fails at once saying why, and a later one is made', () async {
    // As on a phone whose context could not be handed to the core: nothing of the library is made, the start throws
    // and the node is down with the reason, and a stop asked meanwhile is done. Started again once it can be, it is up.
    final node = _node();
    IrohNode.debugFailMaking = 'The phone would not say.';
    addTearDown(() => IrohNode.debugFailMaking = null);
    final asked = Stopwatch()..start();
    await expectLater(node.start(_config(103)), _saying('The phone would not say.'));
    expect(asked.elapsed, lessThan(const Duration(seconds: 5)));
    expect([node.state.value, node.problem], [P2pState.down, 'The phone would not say.']);
    final calledOff = node.start(_config(103));
    final stopped = node.stop();
    await stopped;
    await calledOff;
    expect(node.state.value, P2pState.off);
    IrohNode.debugFailMaking = null;
    await node.start(_config(103));
    expect([node.state.value, node.problem], [P2pState.up, null]);
  }, skip: skip, timeout: patient);

  test('an open ends by its timeout, whatever the core does', () async {
    // The core waits no less than 100 ms for anything; an open asked to wait less has ended all the same.
    final a = await _up(104), b = await _up(105);
    final there = _portOf((await _here(b)).addresses);
    await b.stop();
    final asked = Stopwatch()..start();
    await expectLater(a.open(b.nodeId!, P2pChannel.packets, hint: Whereabouts(addresses: [(await _here(a)).addresses.single.replaceFirst(RegExp(r':\d+$'), ':$there')]), timeout: const Duration(milliseconds: 10)), _refused);
    expect(asked.elapsed, lessThan(const Duration(milliseconds: 70)), reason: 'an open given 10 ms took ${asked.elapsed.inMilliseconds} ms');
    // And one given longer is answered by the core itself, in its time.
    final longer = Stopwatch()..start();
    await expectLater(a.open(b.nodeId!, P2pChannel.packets, hint: Whereabouts(addresses: [(await _here(a)).addresses.single.replaceFirst(RegExp(r':\d+$'), ':$there')]), timeout: const Duration(milliseconds: 600)), _refused);
    expect(longer.elapsed, lessThan(const Duration(milliseconds: 700)));
  }, skip: skip, timeout: patient);

  test('a node that cannot be started says why, and can be started rightly after', () async {
    final node = _node();
    // Thrown, and the node is left down saying the same: by this side's own look at what it was given, and (the
    // last of these) by the library's.
    Matcher saying(String words) => throwsA(isA<P2pError>().having((e) => e.message, 'message', contains(words)));
    await expectLater(node.start(P2pConfig(secret: Uint8List(5))), saying('32 bytes'));
    expect(node.state.value, P2pState.down);
    expect(node.problem, contains('32 bytes'));
    await expectLater(node.start(P2pConfig(secret: _config(71).secret, helpers: const ['http://not-https.example'])), saying('http://not-https.example'));
    expect(node.state.value, P2pState.down);
    expect(node.problem, contains('http://not-https.example'));
    await expectLater(node.start(P2pConfig(secret: _config(71).secret, helpersOnly: true)), saying('link helper'));
    expect(node.state.value, P2pState.down);
    expect(node.problem, contains('link helper'));
    await expectLater(node.start(P2pConfig(secret: _config(71).secret, helpers: const ['https://not a name'])), saying('https://not a name'));
    expect(node.state.value, P2pState.down);
    expect(node.problem, contains('https://not a name'));
    expect(node.whereabouts.value, isNull);
    await expectLater(node.open(await node.idOf(_config(72).secret), 0), _refused);
    await node.start(_config(71));
    expect(node.state.value, P2pState.up);
    expect(node.problem, isNull);
    // Nothing is known of where the other is, and a hint that is no hint is none: said at once, not after the wait.
    final other = await node.idOf(_config(72).secret);
    final asked = Stopwatch()..start();
    await expectLater(node.open(other, 0, timeout: const Duration(seconds: 20)), _refused);
    await expectLater(node.open(other, 0, hint: const Whereabouts(helper: 'https://someone-elses.example', addresses: ['nowhere', '0.0.0.0:1']), timeout: const Duration(seconds: 20)), _refused);
    expect(asked.elapsed, lessThan(const Duration(seconds: 10)));
    // Who may come in is never a throw, whatever it is given: an id that is no node id lets nobody in, a channel that
    // is no channel is none.
    expect(() => node.allow('not a node id', {0}), returnsNormally);
    expect(() => node.allow(other, {256, -1}), returnsNormally);
    expect(() => node.disallow('not a node id'), returnsNormally);
    expect(() => node.openToAll({300}), returnsNormally);
    node.dispose();
    await expectLater(node.start(_config(71)), _refused);
  }, skip: skip, timeout: patient);
}
