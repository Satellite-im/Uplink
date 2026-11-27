import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_ffi.dart';

/// The real node (lib/net/p2p/node_ffi.dart over native/p2p) held to lib/net/p2p/node.dart by the sentences the
/// stand-in is held to (test/fake_p2p_test.dart, which the direct route's tests run on): the same groups and the
/// same tests by name, with two and three `IrohNode`s on this machine's loopback address where the stand-in has a
/// mesh in memory. So what the route was built on and what it will run on are held to one page.
///
/// What a real network cannot stage here is left out, and each test says what: a link helper (the library's own
/// tests run one: `cargo test` in native/p2p), a router that lets nothing in, a path that is cut or slow, a core
/// that fails by itself.
///
/// Where the real node is not the stand-in, the test says so too:
/// - a start that fails throws, as well as leaving the node down saying why;
/// - a node keeps its port across a stop and a start, so it is found again where it was (the stand-in has a new
///   address each time);
/// - a stream that comes with nobody listening to `opened` is closed at once (the stand-in keeps it);
/// - a node allowed other channels than before has its streams on the channels it lost closed;
/// - with nothing known of where a node is, an open fails at once, not when its wait is over.
///
/// Skipped where the library is not built: `sh tool/build-p2p.sh mac`.

const _ch = P2pChannel.packets;

Uint8List _key(int n) => Uint8List.fromList(List.filled(32, n));
P2pConfig _config(int n) => P2pConfig(secret: _key(n));

/// Waits for [ok], however long the machine takes (half a minute at most), not for a length of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 6000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// A node, let go of when the test is over. Someone listens for the streams it is opened: one nobody is there to
/// take is closed at once.
IrohNode _node() {
  final node = IrohNode.make()!;
  addTearDown(node.dispose);
  node.opened.listen((_) {});
  return node;
}

Future<IrohNode> _up(int n) async {
  final node = _node();
  await node.start(_config(n));
  expect(node.state.value, P2pState.up, reason: node.problem);
  return node;
}

/// Two nodes up, each letting the other in on the packets channel.
Future<(IrohNode, IrohNode)> _two(int n, int m) async {
  final a = await _up(n), b = await _up(m);
  a.allow(b.nodeId!, {_ch});
  b.allow(a.nodeId!, {_ch});
  return (a, b);
}

final _ipv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+:(\d+)$');

/// Where [node] is, as another node on this machine dials it: the IPv4 address it says, as it says it (this
/// machine's own address on its network: a node dials no loopback address a hint names).
Future<Whereabouts> _here(IrohNode node) async {
  await _until(() => node.whereabouts.value?.addresses.any(_ipv4.hasMatch) ?? false, 'it never said where it is');
  return Whereabouts(addresses: [node.whereabouts.value!.addresses.firstWhere(_ipv4.hasMatch)]);
}

/// What a stream brings, and whether it is done.
class _Heard {
  _Heard(P2pStream s) {
    s.frames.listen(frames.add, onDone: () => done = true);
  }
  final frames = <Uint8List>[];
  bool done = false;
}

Matcher get _refused => throwsA(isA<P2pError>());
Matcher _saying(String words) => throwsA(isA<P2pError>().having((e) => e.message, 'message', contains(words)));

void main() {
  final skip = IrohNode.available ? false : 'The direct network\'s core is not built here: sh tool/build-p2p.sh mac';
  const patient = Timeout(Duration(minutes: 3));

  group('a node', () {
    test('has no node id until it has started once, but says what a key makes without starting anything', () async {
      final n = _node();
      expect(n.nodeId, isNull);
      expect(n.state.value, P2pState.off);
      expect(n.whereabouts.value, isNull);
      final id = await n.idOf(_key(101));
      expect(isNodeId(id), isTrue);
      expect(await n.idOf(_key(101)), id, reason: 'the same key, the same id');
      expect(await n.idOf(_key(102)), isNot(id));
      expect([n.state.value, n.nodeId], [P2pState.off, null], reason: 'nothing was started for it');
      await n.start(_config(101));
      expect(n.nodeId, id);
      await n.stop();
      expect(n.nodeId, id, reason: 'kept once it has started');
    }, skip: skip, timeout: patient);

    test('goes from off through starting to up, with where it can be found; a start that fails leaves it down, saying why', () async {
      final n = _node();
      final states = <P2pState>[];
      n.state.addListener(() => states.add(n.state.value));
      final before = DateTime.now().millisecondsSinceEpoch;
      await n.start(_config(103));
      expect(states, [P2pState.starting, P2pState.up]);
      expect(n.problem, isNull);
      await _until(() => n.whereabouts.value != null, 'it never said where it is');
      final where = n.whereabouts.value!;
      expect(where.helper, isNull, reason: 'it was given no link helper');
      expect(where.addresses, isNotEmpty);
      expect(where.at, greaterThanOrEqualTo(before));
      await n.stop();
      expect([n.state.value, n.whereabouts.value, n.problem], [P2pState.off, null, null]);
      // The real node throws as well (the stand-in only leaves it down): here it is the library that could not.
      await expectLater(n.start(P2pConfig(secret: _key(103), helpers: const ['https://not a name'])), _saying('https://not a name'));
      expect([n.state.value, n.whereabouts.value], [P2pState.down, null]);
      expect(n.problem, contains('https://not a name'));
      // And started again once it can be.
      await n.start(_config(103));
      expect([n.state.value, n.problem], [P2pState.up, null]);
      // (One that stops by itself is a bug in the library caught: nothing here can stage it.)
    }, skip: skip, timeout: patient);

    test('a start that takes a while is waited for once, and is called off by a stop', () async {
      final n = _node(), other = await _up(105);
      final states = <P2pState>[];
      n.state.addListener(() => states.add(n.state.value));
      final first = n.start(_config(104)), second = n.start(_config(104));
      expect(identical(first, second), isTrue, reason: 'the same start, asked for twice');
      expect(n.state.value, P2pState.starting);
      await Future.wait([first, second]);
      expect(states, [P2pState.starting, P2pState.up]);
      n.allow(other.nodeId!, {_ch});
      final there = await _here(n);
      await n.stop();
      states.clear();
      // Started, and stopped before the library has answered the start: off at once, and it never shows as up.
      final calledOff = n.start(_config(104));
      final stopped = n.stop();
      expect([n.state.value, n.whereabouts.value], [P2pState.off, null]);
      await calledOff;
      await stopped;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(states, [P2pState.starting, P2pState.off], reason: 'stopped while starting: it does not come up after');
      // Nor is a node left running in the library: nothing answers where it would be (it keeps its port, and
      // would let this one in).
      await expectLater(other.open(n.nodeId!, _ch, hint: there, timeout: const Duration(seconds: 1)), _refused);
      await n.start(_config(104));
      expect(n.state.value, P2pState.up);
      expect((await other.open(n.nodeId!, _ch, hint: there)).nodeId, n.nodeId);
    }, skip: skip, timeout: patient);

    test('started again with the same config it does nothing; with another it is stopped and started, and who was allowed is kept', () async {
      final (a, b) = await _two(106, 107);
      final heard = _Heard(await a.open(b.nodeId!, _ch, hint: await _here(b)));
      final states = <P2pState>[];
      b.state.addListener(() => states.add(b.state.value));
      await b.start(_config(107));
      expect([states, heard.done], [<P2pState>[], false], reason: 'up already, the same config');
      // Another config with the same key: a link helper named where nothing answers, on this machine (so nothing
      // leaves it). The stand-in is on its helper at once; a real node says so only when it is, which here is never.
      await b.start(P2pConfig(secret: _key(107), helpers: const ['https://127.0.0.1:9']));
      expect(states, [P2pState.off, P2pState.starting, P2pState.up]);
      await _until(() => heard.done, 'stopping did not close every stream');
      // Kept across the stop and the start: let in still.
      expect((await a.open(b.nodeId!, _ch, hint: await _here(b))).nodeId, b.nodeId);
    }, skip: skip, timeout: patient);

    test('stopped, every stream closes and nothing can dial it; a node that is not up can dial nothing', () async {
      final (a, b) = await _two(108, 109);
      final there = await _here(b), back = await _here(a);
      final out = _Heard(await a.open(b.nodeId!, _ch, hint: there));
      final home = _Heard(await b.open(a.nodeId!, _ch, hint: back));
      await b.stop();
      await _until(() => out.done && home.done, 'stopping did not close every stream');
      await expectLater(a.open(b.nodeId!, _ch, hint: there, timeout: const Duration(seconds: 1)), _refused, reason: 'nothing answers where it was');
      await expectLater(b.open(a.nodeId!, _ch, hint: back), _saying('not up'));
    }, skip: skip, timeout: patient);

    test('is told when the network changed', () async {
      final n = _node();
      n.networkChanged();
      await n.start(_config(110));
      n.networkChanged();
      n.networkChanged();
      expect(n.state.value, P2pState.up);
    }, skip: skip, timeout: patient);
  });

  group('who may connect', () {
    test('a node never allowed is turned away; allowed, it is let in on those channels and no others', () async {
      final a = await _up(111), b = await _up(112);
      final opened = <P2pStream>[];
      b.opened.listen(opened.add);
      final there = await _here(b);
      // P2pError does not say by its kind why; its words do: turned away is not "could not be reached".
      await expectLater(a.open(b.nodeId!, _ch, hint: there), _saying('not allowed'));
      b.allow(a.nodeId!, {P2pChannel.hub});
      await expectLater(a.open(b.nodeId!, _ch, hint: there), _saying('channel'), reason: 'let in on another channel only');
      final hub = await a.open(b.nodeId!, P2pChannel.hub, hint: there);
      expect(hub.channel, P2pChannel.hub);
      // In place of what it was allowed before. (The real node also closes the stream on the channel it lost.)
      final lost = _Heard(hub);
      b.allow(a.nodeId!, {_ch});
      await expectLater(a.open(b.nodeId!, P2pChannel.hub), _refused);
      final s = await a.open(b.nodeId!, _ch);
      await _until(() => opened.length == 2 && lost.done, 'the stream was never handed over, or the one it lost never closed');
      expect(opened.map((o) => o.channel), [P2pChannel.hub, _ch], reason: 'only what was let in is handed over');
      expect([s.incoming, s.nodeId, opened.last.incoming, opened.last.nodeId], [false, b.nodeId, true, a.nodeId]);
      // Letting someone in is not being let in by them.
      await expectLater(b.open(a.nodeId!, _ch, hint: await _here(a)), _refused);
    }, skip: skip, timeout: patient);

    test('disallowed, every stream with that node closes, whichever end opened it, and it is turned away after', () async {
      final (a, b) = await _two(113, 114);
      final c = await _up(115);
      b.allow(c.nodeId!, {_ch});
      final there = await _here(b);
      final fromA = _Heard(await a.open(b.nodeId!, _ch, hint: there));
      final toA = _Heard(await b.open(a.nodeId!, _ch, hint: await _here(a)));
      final fromC = _Heard(await c.open(b.nodeId!, _ch, hint: there));
      b.disallow(a.nodeId!);
      await _until(() => fromA.done && toA.done, 'its streams were never closed');
      expect(fromC.done, isFalse, reason: 'the other node\'s stream is left');
      await expectLater(a.open(b.nodeId!, _ch, hint: there), _saying('not allowed'));
    }, skip: skip, timeout: patient);

    test('a channel open to all takes anyone, and none is to begin with', () async {
      final host = await _up(116), stranger = await _up(117);
      final there = await _here(host);
      await expectLater(stranger.open(host.nodeId!, P2pChannel.hub, hint: there), _refused);
      host.openToAll({P2pChannel.hub});
      expect((await stranger.open(host.nodeId!, P2pChannel.hub, hint: there)).channel, P2pChannel.hub);
      await expectLater(stranger.open(host.nodeId!, _ch, hint: there), _refused, reason: 'the other channels are not');
      host.openToAll({});
      await expectLater(stranger.open(host.nodeId!, P2pChannel.hub, hint: there), _refused);
    }, skip: skip, timeout: patient);
  });

  group('a stream', () {
    test('carries whole frames in the order they were sent, both ways, each end its own copy', () async {
      final (a, b) = await _two(118, 119);
      final theirs = b.opened.first;
      final s = await a.open(b.nodeId!, _ch, hint: await _here(b));
      final t = await theirs;
      final atB = _Heard(t), atA = _Heard(s);
      final big = Uint8List(P2pNode.maxFrame)..[0] = 9;
      final sent = Uint8List.fromList([1, 2, 3]);
      await s.add(sent);
      await s.add(Uint8List(0));
      await s.add(big);
      await t.add(Uint8List.fromList([4]));
      sent[0] = 99;
      await _until(() => atB.frames.length == 3 && atA.frames.length == 1, 'the frames never came');
      expect(atB.frames.map((f) => f.length), [3, 0, P2pNode.maxFrame]);
      expect(atB.frames.first, [1, 2, 3], reason: 'not the sender\'s own list');
      expect(atB.frames.last.first, 9);
      expect(atA.frames, [
        [4],
      ]);
      await expectLater(s.add(Uint8List(P2pNode.maxFrame + 1)), _refused, reason: 'longer than a frame may be');
      await s.add(Uint8List.fromList([5]));
      await _until(() => atB.frames.length == 4, 'the stream did not go on after a frame that was too long to send');
      expect(atB.frames.last, [5]);
    }, skip: skip, timeout: patient);

    test('closed by either end, the other end\'s frames are done after what was already sent, and nothing more can be said', () async {
      final (a, b) = await _two(120, 121);
      final theirs = b.opened.first;
      final s = await a.open(b.nodeId!, _ch, hint: await _here(b));
      final t = await theirs;
      final atB = _Heard(t), atA = _Heard(s);
      await s.add(Uint8List.fromList([7]));
      await s.close();
      await s.close();
      await _until(() => atB.done && atA.done, 'the close was never seen');
      expect(atB.frames, [
        [7],
      ]);
      await expectLater(s.add(Uint8List.fromList([8])), _refused);
      await expectLater(t.add(Uint8List.fromList([8])), _refused);
      await t.close();
    }, skip: skip, timeout: patient);
  });

  group('finding each other', () {
    test('by where it last said it is, and after that by what is already known of it; nothing is found untold', () async {
      final (a, b) = await _two(122, 123);
      // There is no directory to look in. (Said at once here; the stand-in waits out the dial's time.)
      await expectLater(a.open(b.nodeId!, _ch, timeout: const Duration(seconds: 20)), _saying('Nothing is known')).timeout(const Duration(seconds: 10));
      final s = await a.open(b.nodeId!, _ch, hint: await _here(b));
      await s.close();
      expect((await a.open(b.nodeId!, _ch)).nodeId, b.nodeId, reason: 'known from the link before');
      expect((await b.open(a.nodeId!, _ch)).nodeId, a.nodeId, reason: 'and the one dialled knows who dialled it');
      // Stopped and started, it knows nothing of anyone again.
      await a.stop();
      await a.start(_config(122));
      await expectLater(a.open(b.nodeId!, _ch), _saying('Nothing is known'));
    }, skip: skip, timeout: patient);

    // The stand-in: 'a node has a new address each time it starts: a dial by the old one waits out its time, by the
    // clock, and fails'. The real node is the other way about, on purpose.
    test('a node keeps its address across a stop and a start: a dial by the old one finds it', () async {
      final (a, b) = await _two(124, 125);
      final old = await _here(b);
      await b.stop();
      await expectLater(a.open(b.nodeId!, _ch, hint: old, timeout: const Duration(seconds: 1)), _refused, reason: 'stopped: nobody is there');
      await b.start(_config(125));
      expect((await _here(b)).addresses, old.addresses);
      expect((await a.open(b.nodeId!, _ch, hint: old)).nodeId, b.nodeId);
      // (Moved to another network, a new address and its links gone: no second network here to move to.)
    }, skip: skip, timeout: patient);

    test('a dial keeps trying until its time is up: a node that comes up meanwhile, where it was said to be, is found', () async {
      final (a, b) = await _two(126, 127);
      final there = await _here(b);
      await b.stop();
      P2pStream? got;
      Object? failed;
      unawaited(a.open(b.nodeId!, _ch, hint: there, timeout: const Duration(seconds: 30)).then<void>((s) => got = s, onError: (Object e) => failed = e));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect([got, failed], [null, null], reason: 'still trying');
      await b.start(_config(127));
      await _until(() => got != null || failed != null, 'the dial neither found it nor gave up');
      expect(failed, isNull);
      expect(got!.nodeId, b.nodeId);
    }, skip: skip, timeout: patient);

    // Not staged here: 'unreachable, cut off from one other, or slow, as the test says' (a mesh a test can cut),
    // 'a node nothing can dial in to still dials out' (a router; that the link it made carries both ways is the
    // second half of the first test in this group), and 'through a link helper only where no straight path can be'
    // (a link helper: native/p2p's own tests run one, with a node that goes only through it).

    test('on one network the path is straight', () async {
      final (a, b) = await _two(128, 129);
      final paths = <String>[];
      a.paths.listen((p) => paths.add('${p.kind.name} to ${p.nodeId == b.nodeId ? 'b' : '?'}'));
      expect(a.pathTo(b.nodeId!), isNull, reason: 'no link yet');
      await a.open(b.nodeId!, _ch, hint: await _here(b));
      await _until(() => a.pathTo(b.nodeId!)?.kind == P2pPathKind.direct && b.pathTo(a.nodeId!)?.kind == P2pPathKind.direct, 'the path never said straight');
      await _until(() => a.pathTo(b.nodeId!)?.rttMs != null, 'no round trip was measured');
      // The link gone (the other end stopped): no path, and said so.
      await b.stop();
      await _until(() => a.pathTo(b.nodeId!) == null, 'the path was never said to be gone');
      expect(paths.toSet(), {'direct to b', 'none to b'});
      expect(paths.last, 'none to b');
      // (Only through link helpers, and a router that lets nothing in: a link helper again.)
    }, skip: skip, timeout: patient);
  });
}
