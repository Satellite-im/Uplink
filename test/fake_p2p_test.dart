import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/p2p/node.dart';

import 'support/fake_p2p.dart';

/// The stand-in for the direct network's core (test/support/fake_p2p.dart) held to lib/net/p2p/node.dart, sentence by
/// sentence: the direct route's tests mean something only if the node they run on does what a node is said to do.

const _ch = P2pChannel.packets;
const _helper = 'https://link.example';

Uint8List _key(int n) => Uint8List.fromList(List.filled(32, n));
P2pConfig _config(int n, {List<String> helpers = const [], bool helpersOnly = false}) => P2pConfig(secret: _key(n), helpers: helpers, helpersOnly: helpersOnly);
Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

/// Two nodes up on one network, each letting the other in on the packets channel.
Future<(FakeP2pMesh, FakeP2pNode, FakeP2pNode)> _two() async {
  final mesh = FakeP2pMesh();
  final a = mesh.node(), b = mesh.node();
  await a.start(_config(1));
  await b.start(_config(2));
  a.allow(b.nodeId!, {_ch});
  b.allow(a.nodeId!, {_ch});
  return (mesh, a, b);
}

/// What a stream brings, and whether it is done.
class _Heard {
  _Heard(P2pStream s) {
    s.frames.listen(frames.add, onDone: () => done = true);
  }
  final frames = <Uint8List>[];
  bool done = false;
}

void main() {
  group('the clock', () {
    test('time moves only when it is moved, and each timer fires at its own moment, in order', () async {
      final clock = FakeClock(DateTime(2026, 11, 22, 12));
      final fired = <String>[];
      clock.timer(const Duration(seconds: 5), () => fired.add('five at ${clock.now().second}'));
      clock.timer(const Duration(seconds: 2), () {
        fired.add('two at ${clock.now().second}');
        // Set from within one: it has its own turn.
        clock.timer(const Duration(seconds: 1), () => fired.add('three at ${clock.now().second}'));
      });
      final dropped = clock.timer(const Duration(seconds: 4), () => fired.add('never'));
      expect(dropped.isActive, isTrue);
      dropped.cancel();
      expect(dropped.isActive, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fired, isEmpty, reason: 'real time passing fires nothing');
      await clock.pass(const Duration(seconds: 1));
      expect(fired, isEmpty);
      expect(clock.next, DateTime(2026, 11, 22, 12, 0, 2));
      await clock.pass(const Duration(seconds: 9));
      expect(fired, ['two at 2', 'three at 3', 'five at 5']);
      expect(clock.now(), DateTime(2026, 11, 22, 12, 0, 10));
      expect(clock.waiting, 0);
    });
  });

  group('a node', () {
    test('has no node id until it has started once, but says what a key makes without starting anything', () async {
      final mesh = FakeP2pMesh();
      final n = mesh.node();
      expect(n.nodeId, isNull);
      expect(n.state.value, P2pState.off);
      expect(n.whereabouts.value, isNull);
      final id = await n.idOf(_key(7));
      expect(isNodeId(id), isTrue);
      expect(await n.idOf(_key(7)), id, reason: 'the same key, the same id');
      expect(await n.idOf(_key(8)), isNot(id));
      expect([n.starts, n.state.value, n.nodeId], [0, P2pState.off, null], reason: 'nothing was started for it');
      await n.start(_config(7));
      expect(n.nodeId, id);
      await n.stop();
      expect(n.nodeId, id, reason: 'kept once it has started');
    });

    test('goes from off through starting to up, with where it can be found; a start that fails leaves it down, saying why', () async {
      final mesh = FakeP2pMesh();
      final n = mesh.node();
      final states = <P2pState>[];
      n.state.addListener(() => states.add(n.state.value));
      await n.start(_config(1));
      expect(states, [P2pState.starting, P2pState.up]);
      expect(n.problem, isNull);
      final where = n.whereabouts.value!;
      expect(where.helper, isNull, reason: 'it was given no link helper');
      expect(where.addresses, hasLength(1));
      expect(where.at, mesh.clock.ms);
      await n.stop();
      expect([n.state.value, n.whereabouts.value, n.problem], [P2pState.off, null, null]);
      n.failStarts = 'The port is taken';
      await n.start(_config(1));
      expect([n.state.value, n.problem, n.whereabouts.value], [P2pState.down, 'The port is taken', null]);
      // And started again once it can be.
      n.failStarts = null;
      await n.start(_config(1));
      expect([n.state.value, n.problem], [P2pState.up, null]);
      // One that stops by itself is down, and says why.
      n.fail('The network is gone');
      expect([n.state.value, n.problem], [P2pState.down, 'The network is gone']);
    });

    test('a start that takes a while is waited for once, and is called off by a stop', () async {
      final mesh = FakeP2pMesh();
      final n = mesh.node()..startTakes = const Duration(seconds: 2);
      var done = 0;
      unawaited(n.start(_config(1)).then((_) => done++));
      unawaited(n.start(_config(1)).then((_) => done++));
      await mesh.clock.pass(const Duration(seconds: 1));
      expect([n.state.value, n.starts, done], [P2pState.starting, 1, 0], reason: 'the same start, asked for twice');
      await mesh.clock.pass(const Duration(seconds: 1));
      expect([n.state.value, done], [P2pState.up, 2]);
      await n.stop();
      unawaited(n.start(_config(1)));
      await n.stop();
      await mesh.clock.pass(const Duration(seconds: 5));
      expect(n.state.value, P2pState.off, reason: 'stopped while starting: it does not come up after');
    });

    test('started again with the same config it does nothing; with another it is stopped and started, and who was allowed is kept', () async {
      final (mesh, a, b) = await _two();
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      final heard = _Heard(s);
      await b.start(_config(2));
      expect([b.starts, b.stops, heard.done], [1, 0, false], reason: 'up already, the same config');
      await b.start(_config(2, helpers: [_helper]));
      await mesh.clock.settle();
      expect([b.starts, b.stops], [2, 1]);
      expect(b.configs.last.helpers, [_helper]);
      expect(heard.done, isTrue, reason: 'stopping closed every stream');
      expect(b.whereabouts.value!.helper, _helper);
      expect(b.allowed, {a.nodeId: {_ch}}, reason: 'kept across the stop and the start');
      // Let in still, at its new address.
      final again = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      expect(again.nodeId, b.nodeId);
    });

    test('stopped, every stream closes and nothing can dial it; a node that is not up can dial nothing', () async {
      final (mesh, a, b) = await _two();
      final there = b.whereabouts.value;
      final out = _Heard(await a.open(b.nodeId!, _ch, hint: there));
      final back = _Heard(await b.open(a.nodeId!, _ch, hint: a.whereabouts.value));
      await b.stop();
      await mesh.clock.settle();
      expect([out.done, back.done, a.streams, b.streams], [true, true, 0, 0]);
      Object? thrown;
      final dial = a.open(b.nodeId!, _ch, hint: there).then<void>((_) {}, onError: (Object e) => thrown = e);
      await mesh.clock.pass(const Duration(seconds: 5));
      await dial;
      expect(thrown, isA<P2pError>(), reason: 'nothing answers where it was');
      await expectLater(b.open(a.nodeId!, _ch, hint: a.whereabouts.value), throwsA(isA<P2pError>()), reason: 'it is not up');
    });

    test('is told when the network changed', () async {
      final (_, a, _) = await _two();
      a.networkChanged();
      a.networkChanged();
      expect(a.networkChanges, 2);
    });
  });

  group('who may connect', () {
    test('a node never allowed is turned away; allowed, it is let in on those channels and no others', () async {
      final mesh = FakeP2pMesh();
      final a = mesh.node(), b = mesh.node();
      await a.start(_config(1));
      await b.start(_config(2));
      final opened = <P2pStream>[];
      b.opened.listen(opened.add);
      await expectLater(a.open(b.nodeId!, _ch, hint: b.whereabouts.value), throwsA(isA<P2pError>()));
      b.allow(a.nodeId!, {P2pChannel.hub});
      await expectLater(a.open(b.nodeId!, _ch, hint: b.whereabouts.value), throwsA(isA<P2pError>()), reason: 'let in on another channel only');
      final hub = await a.open(b.nodeId!, P2pChannel.hub, hint: b.whereabouts.value);
      expect(hub.channel, P2pChannel.hub);
      // In place of what it was allowed before.
      b.allow(a.nodeId!, {_ch});
      await expectLater(a.open(b.nodeId!, P2pChannel.hub), throwsA(isA<P2pError>()));
      final s = await a.open(b.nodeId!, _ch);
      await mesh.clock.settle();
      expect(opened.map((o) => o.channel), [P2pChannel.hub, _ch], reason: 'only what was let in is handed over');
      expect([s.incoming, s.nodeId, opened.last.incoming, opened.last.nodeId], [false, b.nodeId, true, a.nodeId]);
      // Letting someone in is not being let in by them.
      await expectLater(b.open(a.nodeId!, _ch, hint: a.whereabouts.value), throwsA(isA<P2pError>()));
    });

    test('disallowed, every stream with that node closes, whichever end opened it, and it is turned away after', () async {
      final (mesh, a, b) = await _two();
      final c = mesh.node();
      await c.start(_config(3));
      b.allow(c.nodeId!, {_ch});
      final fromA = _Heard(await a.open(b.nodeId!, _ch, hint: b.whereabouts.value));
      final toA = _Heard(await b.open(a.nodeId!, _ch, hint: a.whereabouts.value));
      final fromC = _Heard(await c.open(b.nodeId!, _ch, hint: b.whereabouts.value));
      b.disallow(a.nodeId!);
      await mesh.clock.settle();
      expect([fromA.done, toA.done, fromC.done], [true, true, false], reason: 'the other node\'s stream is left');
      await expectLater(a.open(b.nodeId!, _ch, hint: b.whereabouts.value), throwsA(isA<P2pError>()));
    });

    test('a channel open to all takes anyone, and none is to begin with', () async {
      final mesh = FakeP2pMesh();
      final host = mesh.node(), stranger = mesh.node();
      await host.start(_config(1));
      await stranger.start(_config(2));
      await expectLater(stranger.open(host.nodeId!, P2pChannel.hub, hint: host.whereabouts.value), throwsA(isA<P2pError>()));
      host.openToAll({P2pChannel.hub});
      expect((await stranger.open(host.nodeId!, P2pChannel.hub, hint: host.whereabouts.value)).channel, P2pChannel.hub);
      await expectLater(stranger.open(host.nodeId!, _ch, hint: host.whereabouts.value), throwsA(isA<P2pError>()), reason: 'the other channels are not');
      host.openToAll({});
      await expectLater(stranger.open(host.nodeId!, P2pChannel.hub, hint: host.whereabouts.value), throwsA(isA<P2pError>()));
    });
  });

  group('a stream', () {
    test('carries whole frames in the order they were sent, both ways, each end its own copy', () async {
      final (mesh, a, b) = await _two();
      final theirs = b.opened.first;
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      final t = await theirs;
      final atB = _Heard(t), atA = _Heard(s);
      final big = Uint8List(P2pNode.maxFrame)..[0] = 9;
      final sent = _bytes([1, 2, 3]);
      await s.add(sent);
      await s.add(Uint8List(0));
      await s.add(big);
      await t.add(_bytes([4]));
      sent[0] = 99;
      await mesh.clock.settle();
      expect(atB.frames.map((f) => f.length), [3, 0, P2pNode.maxFrame]);
      expect(atB.frames.first, [1, 2, 3], reason: 'not the sender\'s own list');
      expect(atB.frames.last.first, 9);
      expect(atA.frames, [[4]]);
      expect(mesh.frames, 4);
      await expectLater(s.add(Uint8List(P2pNode.maxFrame + 1)), throwsA(isA<P2pError>()), reason: 'longer than a frame may be');
      expect(atB.frames, hasLength(3));
    });

    test('closed by either end, the other end\'s frames are done after what was already sent, and nothing more can be said', () async {
      final (mesh, a, b) = await _two();
      final theirs = b.opened.first;
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      final t = await theirs;
      final atB = _Heard(t), atA = _Heard(s);
      await s.add(_bytes([7]));
      await s.close();
      await s.close();
      await mesh.clock.settle();
      expect([atB.frames, atB.done, atA.done], [[[7]], true, true]);
      await expectLater(s.add(_bytes([8])), throwsA(isA<P2pError>()));
      await expectLater(t.add(_bytes([8])), throwsA(isA<P2pError>()));
      await t.close();
      expect([a.streams, b.streams], [0, 0]);
    });
  });

  group('finding each other', () {
    test('by where it last said it is, and after that by what is already known of it; nothing is found untold', () async {
      final (mesh, a, b) = await _two();
      Object? thrown;
      final blind = a.open(b.nodeId!, _ch).then<void>((_) {}, onError: (Object e) => thrown = e);
      await mesh.clock.pass(const Duration(seconds: 5));
      await blind;
      expect(thrown, isA<P2pError>(), reason: 'there is no directory to look in');
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      expect(mesh.dials.last.hint, b.whereabouts.value);
      await s.close();
      expect((await a.open(b.nodeId!, _ch)).nodeId, b.nodeId, reason: 'known from the link before');
      expect((await b.open(a.nodeId!, _ch)).nodeId, a.nodeId, reason: 'and the one dialled knows who dialled it');
      expect(mesh.dialsTo(b.nodeId!), 3);
      expect(mesh.dialsTo(a.nodeId!), 1);
      // Stopped and started, it knows nothing of anyone again.
      await a.stop();
      await a.start(_config(1));
      thrown = null;
      final forgot = a.open(b.nodeId!, _ch).then<void>((_) {}, onError: (Object e) => thrown = e);
      await mesh.clock.pass(const Duration(seconds: 5));
      await forgot;
      expect(thrown, isA<P2pError>());
    });

    test('a node has a new address each time it starts: a dial by the old one waits out its time, by the clock, and fails', () async {
      final (mesh, a, b) = await _two();
      final old = b.whereabouts.value!;
      await b.stop();
      await b.start(_config(2));
      expect(b.whereabouts.value!.addresses, isNot(old.addresses));
      var failed = false, opened = false;
      unawaited(a.open(b.nodeId!, _ch, hint: old, timeout: const Duration(seconds: 3)).then((_) => opened = true, onError: (_) => failed = true));
      await mesh.clock.pass(const Duration(milliseconds: 2999));
      expect([failed, opened], [false, false], reason: 'still trying');
      await mesh.clock.pass(const Duration(milliseconds: 1));
      expect([failed, opened], [true, false]);
      // Moved to another network: a new address again, and its links gone.
      final s = _Heard(await a.open(b.nodeId!, _ch, hint: b.whereabouts.value));
      final before = b.whereabouts.value!;
      b.move('home');
      await mesh.clock.settle();
      expect(s.done, isTrue);
      expect(b.whereabouts.value!.addresses, isNot(before.addresses));
    });

    test('a dial keeps trying until its time is up: a node that comes up meanwhile, where it was said to be, is found', () async {
      final mesh = FakeP2pMesh();
      final a = mesh.node(), b = mesh.node();
      await a.start(_config(1));
      await b.start(_config(2));
      b.allow(a.nodeId!, {_ch});
      mesh.unreachable(b);
      P2pStream? got;
      unawaited(a.open(b.nodeId!, _ch, hint: b.whereabouts.value).then((s) => got = s));
      await mesh.clock.pass(const Duration(seconds: 2));
      expect(got, isNull);
      mesh.unreachable(b, false);
      await mesh.clock.settle();
      expect(got!.nodeId, b.nodeId);
    });

    test('unreachable, cut off from one other, or slow, as the test says', () async {
      final (mesh, a, b) = await _two();
      final c = mesh.node();
      await c.start(_config(3));
      c.allow(a.nodeId!, {_ch});
      b.allow(c.nodeId!, {_ch});
      Future<bool> reaches(FakeP2pNode from, FakeP2pNode to, {Duration within = const Duration(seconds: 5)}) async {
        bool? ok;
        unawaited(from.open(to.nodeId!, _ch, hint: to.whereabouts.value, timeout: within).then((s) {
          ok = true;
          s.close();
        }, onError: (_) => ok = false));
        await mesh.clock.pass(within);
        return ok!;
      }

      expect(await reaches(a, b), isTrue);
      // Its streams go with its network.
      final held = _Heard(await a.open(b.nodeId!, _ch, hint: b.whereabouts.value));
      mesh.unreachable(b);
      await mesh.clock.settle();
      expect(held.done, isTrue);
      expect(await reaches(a, b), isFalse);
      expect(await reaches(a, c), isTrue, reason: 'the others are as they were');
      mesh.unreachable(b, false);
      mesh.cut(a, b);
      expect(await reaches(a, b), isFalse);
      expect(await reaches(c, b), isTrue, reason: 'only those two are cut off from each other');
      mesh.cut(a, b, false);
      // Slow: a link takes two seconds to make. Within five it is made; within one it is not.
      mesh.slow(b, const Duration(seconds: 2));
      expect(await reaches(a, b, within: const Duration(seconds: 1)), isFalse);
      var linked = false;
      unawaited(a.open(b.nodeId!, _ch, hint: b.whereabouts.value).then((_) => linked = true));
      await mesh.clock.pass(const Duration(milliseconds: 1999));
      expect(linked, isFalse);
      await mesh.clock.pass(const Duration(milliseconds: 1));
      expect(linked, isTrue);
    });

    test('a node nothing can dial in to still dials out, and the link it made carries both ways', () async {
      final (mesh, a, b) = await _two();
      mesh.inbound(a, false);
      var failed = false;
      unawaited(b.open(a.nodeId!, _ch, hint: a.whereabouts.value).then<void>((_) {}, onError: (_) => failed = true));
      await mesh.clock.pass(const Duration(seconds: 5));
      expect(failed, isTrue, reason: 'nothing gets in');
      final theirs = b.opened.first;
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      final heard = _Heard(s);
      await (await theirs).add(_bytes([5]));
      await mesh.clock.settle();
      expect(heard.frames, [[5]]);
      // And over the link that is up, the other end opens a stream too.
      expect((await b.open(a.nodeId!, _ch)).nodeId, a.nodeId);
      mesh.inbound(a, true);
      await s.close();
    });

    test('through a link helper only where no straight path can be: the helper the other is on, which the one dialling was given and told of', () async {
      final mesh = FakeP2pMesh();
      final a = mesh.node(), b = mesh.node(network: 'elsewhere');
      await a.start(_config(1, helpers: [_helper]));
      await b.start(_config(2, helpers: [_helper]));
      b.allow(a.nodeId!, {_ch});
      final paths = <String>[];
      a.paths.listen((p) => paths.add('${p.kind.name} to ${p.nodeId == b.nodeId ? 'b' : '?'}'));
      expect(a.pathTo(b.nodeId!), isNull, reason: 'no link yet');
      final where = b.whereabouts.value!;
      expect(where.helper, _helper);
      // Another network: its address as it is can't be reached, the helper can.
      final s = await a.open(b.nodeId!, _ch, hint: where);
      await mesh.clock.settle();
      expect(a.pathTo(b.nodeId!)!.kind, P2pPathKind.helper);
      expect(b.pathTo(a.nodeId!)!.kind, P2pPathKind.helper);
      await s.close();
      await mesh.clock.settle();
      expect(a.pathTo(b.nodeId!), isNull);
      expect(paths, ['helper to b', 'none to b']);
      // Told only its address, with no helper named: nothing gets through.
      await a.stop();
      await a.start(_config(1, helpers: [_helper]));
      var failed = false;
      unawaited(a.open(b.nodeId!, _ch, hint: Whereabouts(addresses: where.addresses)).then<void>((_) {}, onError: (_) => failed = true));
      await mesh.clock.pass(const Duration(seconds: 5));
      expect(failed, isTrue);
      // The helper not answering: nothing either.
      mesh.helperDown(_helper);
      failed = false;
      unawaited(a.open(b.nodeId!, _ch, hint: where).then<void>((_) {}, onError: (_) => failed = true));
      await mesh.clock.pass(const Duration(seconds: 5));
      expect(failed, isTrue);
      mesh.helperDown(_helper, false);
      // One that was given no helper can't use the other's.
      final c = mesh.node();
      await c.start(_config(3));
      b.allow(c.nodeId!, {_ch});
      failed = false;
      unawaited(c.open(b.nodeId!, _ch, hint: where).then<void>((_) {}, onError: (_) => failed = true));
      await mesh.clock.pass(const Duration(seconds: 5));
      expect(failed, isTrue);
    });

    test('on one network the path is straight, unless either end lets none be: then the other sees no address of it', () async {
      final mesh = FakeP2pMesh();
      final a = mesh.node(), b = mesh.node();
      await a.start(_config(1, helpers: [_helper]));
      await b.start(_config(2, helpers: [_helper]));
      b.allow(a.nodeId!, {_ch});
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      expect(a.pathTo(b.nodeId!)!.kind, P2pPathKind.direct);
      expect(a.pathTo(b.nodeId!)!.rttMs, isNotNull);
      await s.close();
      // Only through link helpers: it tells no address, and the path made is the helper's.
      await a.start(_config(1, helpers: [_helper], helpersOnly: true));
      expect(a.whereabouts.value!.addresses, isEmpty);
      expect(a.whereabouts.value!.helper, _helper);
      await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      expect(a.pathTo(b.nodeId!)!.kind, P2pPathKind.helper);
      // A router that lets nothing in: the same, whatever the app chose.
      final c = mesh.node(), d = mesh.node();
      await c.start(_config(3, helpers: [_helper]));
      await d.start(_config(4, helpers: [_helper]));
      d.allow(c.nodeId!, {_ch});
      mesh.natted(d);
      await c.open(d.nodeId!, _ch, hint: d.whereabouts.value);
      expect(c.pathTo(d.nodeId!)!.kind, P2pPathKind.helper);
    });
  });

  group('a core that misbehaves, when a test says so', () {
    test('throws where it is told to, at once, and never answers where it is told to hang', () async {
      final (mesh, a, b) = await _two();
      final s = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      a.throws.addAll({'allow', 'disallow', 'openToAll', 'networkChanged', 'pathTo', 'add', 'close', 'start', 'stop', 'open', 'idOf'});
      expect(() => a.allow(b.nodeId!, {_ch}), throwsA(isA<P2pError>()));
      expect(() => a.disallow(b.nodeId!), throwsA(isA<P2pError>()));
      expect(() => a.openToAll({}), throwsA(isA<P2pError>()));
      expect(a.networkChanged, throwsA(isA<P2pError>()));
      expect(() => a.pathTo(b.nodeId!), throwsA(isA<P2pError>()));
      expect(() => s.add(_bytes([1])), throwsA(isA<P2pError>()), reason: 'thrown, not failed through the Future');
      expect(s.close, throwsA(isA<P2pError>()));
      expect(() => a.start(_config(1)), throwsA(isA<P2pError>()));
      expect(a.stop, throwsA(isA<P2pError>()));
      expect(() => a.open(b.nodeId!, _ch), throwsA(isA<P2pError>()));
      expect(() => a.idOf(_key(1)), throwsA(isA<P2pError>()));
      expect([a.now, a.calls['disallow'], a.allowed.keys], [P2pState.up, 1, [b.nodeId]], reason: 'nothing it was asked was done');
      // Its getters too.
      a.throws.addAll({'state', 'whereabouts', 'nodeId', 'problem', 'opened', 'paths'});
      expect(() => a.state, throwsA(isA<P2pError>()));
      expect(() => a.whereabouts, throwsA(isA<P2pError>()));
      expect(() => a.nodeId, throwsA(isA<P2pError>()));
      expect(() => a.problem, throwsA(isA<P2pError>()));
      expect(() => a.opened, throwsA(isA<P2pError>()));
      expect(() => a.paths, throwsA(isA<P2pError>()));
      a.throws.clear();
      // A frame that never goes, a close that never answers, a dial that never ends, a start that never ends.
      final theirs = b.opened.first;
      final t = await a.open(b.nodeId!, _ch, hint: b.whereabouts.value);
      final heard = _Heard(await theirs);
      a.hangsOn.addAll({'add', 'close', 'open'});
      var answered = false;
      unawaited(t.add(_bytes([7])).then((_) => answered = true));
      unawaited(t.close().then((_) => answered = true));
      unawaited(a.open(b.nodeId!, _ch).then((_) => answered = true, onError: (_) => answered = true));
      await mesh.clock.pass(const Duration(minutes: 1));
      expect([answered, heard.frames], [false, isEmpty]);
      final c = mesh.node()..hangsOn.add('start');
      unawaited(c.start(_config(3)).then((_) => answered = true));
      await mesh.clock.pass(const Duration(minutes: 1));
      expect([answered, c.now], [false, P2pState.starting]);
      // And the factory of a build whose core would not load.
      expect(FakeP2pMesh.broken(StateError('no library')), throwsA(isA<StateError>()));
    });
  });
}
