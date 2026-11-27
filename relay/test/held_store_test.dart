import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/held_store.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// What the hub holds for people away, and what rooms keep, kept on disk across a restart where its keeper switched it
/// on (GMFB-24; lib/held_store.dart, hub.dart's keepHeld): handed over once, never twice, never lost; a torn file read
/// up to the tear; the limits and holdFor kept as the hub starts; and with it off, the hub exactly as before.
void main() {
  late Directory tmp;
  var clock = DateTime.utc(2026, 11, 23, 12);
  DateTime now() => clock;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('held-store-');
    clock = DateTime.utc(2026, 11, 23, 12);
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  var seed = 0;
  Hub hubOn({int heldBytes = 96 << 20}) => Hub(now: now, random: Random(++seed), dataDir: tmp, keepHeld: true, heldBytes: heldBytes)..start();

  List<File> segmentsOf(Directory d) => [for (final f in Directory('${d.path}/held').listSync()) if (f is File && f.path.endsWith('.log')) f]..sort((a, b) => a.path.compareTo(b.path));

  test('a packet held for someone away is handed over after a clean restart, once, and the hub says it kept everything', () async {
    final a = Install(), b = Install();
    final one = hubOn();
    await a.signInTo(one);
    for (var i = 0; i < 3; i++) {
      a.send(b.id, [i, i, i]);
    }
    await pumpEventQueue();
    expect(one.heldFor(b.id), 3);
    final started = one.started;
    one.stop();

    clock = clock.add(const Duration(minutes: 5));
    final two = hubOn();
    expect(two.heldFor(b.id), 3);
    expect(two.started, started, reason: 'a clean stop with nothing in memory alone: what was kept before still is');
    expect(await b.signInTo(two), {'ok': true, 'held': 3});
    await pumpEventQueue();
    expect(b.frames, [for (var i = 0; i < 3; i++) handed(a.id, [i, i, i])]);
    expect(two.heldStore!.live, 0, reason: 'handed over is off the disk');
    b.leave();
    await pumpEventQueue();
    two.stop();

    final three = hubOn();
    b.frames.clear();
    expect(await b.signInTo(three), {'ok': true, 'held': 0}, reason: 'never handed over twice');
    three.stop();
  });

  test('a stop with packets waiting for another relay, which live in memory alone, says the start is now', () async {
    final net = FakeNet(clock);
    final a = TestRelay(net, 'a.test', seed: 1, hubData: tmp), b = TestRelay(net, 'b.test', seed: 2);
    a.hub.start();
    final alice = Install(), bob = Install();
    await alice.signIn(a);
    await bob.signIn(b);
    await alice.giveHome(a);
    alice.say({'dir': 'home', 'rec': await bob.giveHome(b)});
    await net.settle();
    alice.send(bob.id, [0]);
    await net.settle();
    expect(bob.frames.single, handed(alice.id, [0]));
    net.down.add(b.url);
    net.cut(b.url);
    await net.settle();
    alice.send(bob.id, [5]);
    await pumpEventQueue();
    expect(a.fed.waiting, greaterThan(0));
    a.hub.stop();
    clock = net.clock.add(const Duration(minutes: 1));
    final again = hubOn();
    expect(again.started, clock, reason: 'a packet that waited for another relay went with the restart');
    again.stop();
  });

  test('a crash keeps what was written: everything flushed is there, and the hub says it started now', () async {
    final a = Install(), b = Install();
    final one = hubOn();
    await a.signInTo(one);
    for (var i = 0; i < 3; i++) {
      a.send(b.id, [i]);
    }
    await pumpEventQueue();
    one.heldStore!.flushNow();
    // No stop: the process went.
    clock = clock.add(const Duration(seconds: 1));
    final two = hubOn();
    expect(two.started, clock, reason: 'after a crash something may have gone: the start is now');
    expect(two.heldFor(b.id), 3);
    expect(await b.signInTo(two), {'ok': true, 'held': 3});
    await pumpEventQueue();
    expect(b.frames, [for (var i = 0; i < 3; i++) handed(a.id, [i])]);
    two.heldStore!.flushNow();
    // A crash after the hand-over was written: not handed over again.
    final three = hubOn();
    expect(three.heldFor(b.id), 0);
    three.stop();
  });

  test('what was being handed to a connection that closed is held again and stays on the disk', () async {
    final a = Install(), b = Install(), c = Install();
    final one = hubOn();
    await a.signInTo(one);
    a.send(c.id, [7]);
    await pumpEventQueue();
    // To its own name from another device: kept for the others, never handed back to the device that sent it.
    a.send(a.id, [8]);
    await pumpEventQueue();
    one.stop();
    final two = hubOn();
    expect(two.heldFor(c.id), 1);
    expect(two.heldFor(a.id), 1);
    await b.signInTo(two);
    expect(two.heldStore!.live, 2);
    two.stop();
  });

  test('what a room keeps is there after a restart, for whoever joins with its token', () async {
    final a = Install(), b = Install();
    final room = 'ab' * 16, token = 'cd' * 32;
    final one = hubOn();
    await a.signInTo(one);
    a.say({'join': room, 'token': token});
    await pumpEventQueue();
    a.socket.add(Uint8List.fromList([Hub.toRoomKept, ...unhex(room), 5, 6]));
    a.socket.add(Uint8List.fromList([Hub.toRoomReaction, ...unhex(room), 9]));
    await pumpEventQueue();
    expect(one.keptIn(room), 2);
    one.stop();

    final two = hubOn();
    expect(two.keptIn(room), 2);
    final c = Install();
    await c.signInTo(two);
    c.say({'join': room, 'token': token});
    await pumpEventQueue();
    await b.signInTo(two);
    b.say({'join': room, 'token': 'ee' * 32});
    await pumpEventQueue();
    expect(b.frames, isEmpty, reason: 'a wrong token is handed nothing');
    expect(c.frames, [
      [Hub.toRoom, ...unhex(room), ...unhex(a.id), 5, 6],
      [Hub.toRoomReaction, ...unhex(room), ...unhex(a.id), 9],
    ]);
    expect(two.keptIn(room), 2, reason: 'a room keeps what it keeps after handing it over');
    two.stop();
  });

  test('the limits as they are now hold as the hub starts, and what they leave out is off the disk', () async {
    final a = Install(), b = Install();
    final one = hubOn();
    await a.signInTo(one);
    for (var i = 0; i < 10; i++) {
      a.send(b.id, List.filled(1000, i));
    }
    await pumpEventQueue();
    expect(one.heldFor(b.id), 10);
    one.stop();
    // Each frame is 1,017 bytes (1, who sent it, the packet), counted with what holding it costs: four fit in 6,000.
    final cost = 1017 + Hub.heldOverhead;
    final two = hubOn(heldBytes: 6000);
    expect(two.heldFor(b.id), 4);
    expect(two.holding, 4 * cost);
    expect(two.heldStore!.live, 4);
    expect(await b.signInTo(two), {'ok': true, 'held': 4});
    await pumpEventQueue();
    expect(b.frames, [for (var i = 0; i < 4; i++) handed(a.id, List.filled(1000, i))], reason: 'the oldest kept, as memory keeps them');
    two.stop();
  });

  test('nothing older than holdFor comes back, and the sweep takes it off the disk', () async {
    final a = Install(), b = Install(), c = Install();
    final one = hubOn();
    await a.signInTo(one);
    a.send(b.id, [1]);
    await pumpEventQueue();
    one.stop();
    clock = clock.add(Hub.holdFor + const Duration(minutes: 1));
    final two = hubOn();
    expect(two.heldFor(b.id), 0);
    expect(two.heldStore!.live, 0);
    await a.signInTo(two);
    a.send(c.id, [2]);
    await pumpEventQueue();
    expect(two.heldStore!.live, 1);
    clock = clock.add(Hub.holdFor + const Duration(minutes: 1));
    two.sweep();
    expect(two.heldStore!.live, 0);
    two.stop();
    final three = hubOn();
    expect(three.heldFor(c.id), 0);
    three.stop();
  });

  test('a file torn anywhere is read up to the tear, never fatal, and a flipped byte ends the read there', () {
    final dir = Directory('${tmp.path}/held');
    final store = HeldStore(dir, flushEvery: const Duration(hours: 1))..load();
    final seqs = <int>[];
    for (var i = 0; i < 20; i++) {
      seqs.add(store.addMail('ab' * 16, clock, i.isEven ? 'phone' : null, Uint8List.fromList(List.filled(50 + i, i))));
    }
    store.drop(seqs[3]);
    seqs.add(store.addKept('ro:${'cd' * 16}', 'ef' * 32, clock, Uint8List.fromList([1, 2, 3])));
    store.close();
    final whole = segmentsOf(tmp).single.readAsBytesSync();
    var last = -1;
    for (var cut = 0; cut <= whole.length; cut++) {
      final copy = Directory('${tmp.path}/cut')..createSync();
      File('${copy.path}/seg-00000001.log').writeAsBytesSync(whole.sublist(0, cut));
      final read = HeldStore(copy)..load();
      expect(read.live, greaterThanOrEqualTo(last < 0 ? 0 : last - 1), reason: 'a drop read can take one away, nothing more');
      last = read.live;
      read.close();
      copy.deleteSync(recursive: true);
    }
    expect(last, 20, reason: 'whole, every one but the one dropped');
    final back = HeldStore(dir);
    final items = back.load();
    expect(items.map((s) => s.seq), [...seqs.take(3), ...seqs.skip(4)]);
    expect(items.first.byDevice, 'phone');
    expect(items[1].byDevice, isNull);
    expect(items.last.room, 'ro:${'cd' * 16}');
    expect(items.last.hash, 'ef' * 32);
    expect(items.last.frame, [1, 2, 3]);
    back.close();
    // A byte flipped half way: what is before it stands.
    final bent = Uint8List.fromList(whole)..[whole.length ~/ 2] ^= 0x40;
    final copy = Directory('${tmp.path}/bent')..createSync();
    File('${copy.path}/seg-00000001.log').writeAsBytesSync(bent);
    final read = HeldStore(copy);
    final kept = read.load();
    expect(kept.length, inInclusiveRange(5, 15));
    expect(kept.map((s) => s.seq), seqs.take(kept.length), reason: 'the records before the flipped byte, in order');
  });

  test('the disk stays near what stands: old segments are written again and deleted, and everything still reads back', () async {
    final dir = Directory('${tmp.path}/held');
    final store = HeldStore(dir, segmentBytes: 16 << 10, slack: 32 << 10, flushEvery: const Duration(milliseconds: 1))..load();
    final standing = <int>{};
    final rnd = Random(3);
    for (var round = 0; round < 400; round++) {
      final s = store.addMail('ab' * 16, clock, null, Uint8List.fromList(List.filled(200 + rnd.nextInt(800), round & 0xff)));
      standing.add(s);
      // Most are handed over soon; a few stand a long time.
      if (round % 10 != 0) {
        store.drop(s);
        standing.remove(s);
      }
      // Written by the store's own timer, and compacted after it.
      await _until(() => store.idle);
    }
    expect(store.live, standing.length);
    expect(store.diskBytes, lessThanOrEqualTo(2 * store.liveBytes + (32 << 10) + (16 << 10) * 2), reason: 'bounded: about twice what stands, and the slack');
    store.close();
    final again = HeldStore(dir)..load();
    expect(again.live, standing.length);
    again.close();
  });

  test('a real relay killed at any moment, or stopped, keeps what it held', () async {
    final data = Directory('${tmp.path}/data')..createSync();
    Future<(Process, int)> run() async {
      final p = await Process.start(Platform.resolvedExecutable, ['run', 'bin/relay.dart', '--port', '0', '--data', data.path], environment: {'GHOST_HUB_KEEP_HELD': '1'});
      final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
      p.stderr.drain<void>();
      final line = await lines.firstWhere((l) => l.contains('listening on')).timeout(const Duration(seconds: 60));
      expect(line, contains('held for people away: kept on disk too'));
      lines.drain<void>();
      return (p, int.parse(RegExp(r':(\d+) \(').firstMatch(line)!.group(1)!));
    }

    final a = WsInstall(), b = WsInstall();
    var (relay, port) = await run();
    await a.connect('ws://127.0.0.1:$port/hub');
    for (var i = 0; i < 5; i++) {
      a.sendTo(b, [i]);
    }
    await a.acked();
    // Written by the store's own timer: waited for by the file, not a fixed time.
    int written() {
      var n = 0;
      for (final f in segmentsOf(data)) {
        HeldStore.replay(f.readAsBytesSync(), (seq, item, size) => n += item == null ? -1 : 1);
      }
      return n;
    }

    await _until(() => written() == 5, within: const Duration(seconds: 10));
    relay.kill(ProcessSignal.sigkill);
    await relay.exitCode;

    (relay, port) = await run();
    await a.connect('ws://127.0.0.1:$port/hub');
    for (var i = 5; i < 8; i++) {
      a.sendTo(b, [i]);
    }
    await a.acked();
    // Stopped at once: a stop writes what waits.
    relay.kill(ProcessSignal.sigterm);
    await relay.exitCode;

    (relay, port) = await run();
    final hello = await b.connect('ws://127.0.0.1:$port/hub');
    expect(hello['held'], 8);
    await _until(() => b.frames.length == 8, within: const Duration(seconds: 10));
    expect(b.frames, [for (var i = 0; i < 8; i++) handed(a.id, [i])]);
    relay.kill(ProcessSignal.sigterm);
    await relay.exitCode;
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('with keepHeld unset the hub says and hands over exactly what it did, and writes nothing', () async {
    Future<String> script(Hub hub) async {
      final a = Install(), b = Install(), c = Install(), d = Install();
      final heard = <Object>[];
      await a.signInTo(hub, device: 'phone');
      await b.signInTo(hub);
      a.send(b.id, [1, 2, 3]);
      a.send(c.id, [4]);
      a.send(a.id, [5]);
      await pumpEventQueue();
      await c.signInTo(hub);
      heard.add(c.signedIn);
      a.say({'join': 'ab' * 16, 'token': 'cd' * 32});
      b.say({'join': 'ab' * 16, 'token': 'cd' * 32});
      await pumpEventQueue();
      b.socket.add(Uint8List.fromList([Hub.toRoomKept, ...unhex('ab' * 16), 9, 9]));
      b.socket.add(Uint8List.fromList([Hub.toRoom, ...unhex('ab' * 16), 8]));
      await pumpEventQueue();
      for (var i = 0; i < Hub.mailboxFrames + 1; i++) {
        a.send(d.id, [i & 0xff]);
      }
      await pumpEventQueue();
      c.say({'join': 'ab' * 16, 'token': 'cd' * 32});
      await pumpEventQueue();
      await d.signInTo(hub);
      heard.add(d.signedIn);
      await pumpEventQueue();
      String hex(List<int> b) => [for (final v in b) v.toRadixString(16).padLeft(2, '0')].join();
      for (final (who, i) in [('a', a), ('b', b), ('c', c), ('d', d)]) {
        heard.add([who, i.said, i.frames.map(hex).toList()]);
      }
      heard.add([hub.holding, hub.connected, hub.rooms, hub.keptIn('ab' * 16)]);
      var text = jsonEncode(heard);
      for (final (who, i) in [('a', a), ('b', b), ('c', c), ('d', d)]) {
        text = text.replaceAll(i.id, '<$who>');
      }
      return text;
    }

    final plain = Hub(now: now, random: Random(1))..start();
    final before = await script(plain);
    plain.stop();
    final withData = Hub(now: now, random: Random(1), dataDir: tmp)..start();
    final unset = await script(withData);
    withData.stop();
    expect(unset, before);
    expect(Directory('${tmp.path}/held').existsSync(), isFalse, reason: 'nothing is made with it unset');
    expect(withData.heldStore, isNull);
    final on = hubOn();
    expect(await script(on), before, reason: 'and with it on, nothing said changes either');
    on.stop();
  });
}

/// Waits until [done], looking every few milliseconds: never a fixed wait.
Future<void> _until(bool Function() done, {Duration within = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('not done within $within');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// An install on a real WebSocket, for the relay run as a program.
class WsInstall {
  WsInstall() : scalar = someBytes(32) {
    key = P256.publicOf(scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;
  WebSocket? ws;
  final frames = <List<int>>[];
  final said = <Map>[];
  int _seq = 0;

  Future<Map> connect(String url) async {
    await ws?.close();
    frames.clear();
    said.clear();
    final socket = ws = await WebSocket.connect(url);
    final first = <Map>[];
    socket.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      first.length < 2 ? first.add(m) : said.add(m);
    });
    await _until(() => first.isNotEmpty, within: const Duration(seconds: 10));
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...unhex(first[0]['hello'] as String)], someBytes(32));
    socket.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig)}));
    await _until(() => first.length == 2, within: const Duration(seconds: 10));
    return first[1];
  }

  void sendTo(WsInstall to, List<int> packet) {
    ws!.add(Uint8List.fromList([Hub.toPeer, ...(ByteData(4)..setUint32(0, ++_seq)).buffer.asUint8List(), ...unhex(to.id), ...packet]));
  }

  /// Waits for the hub's answer to the last packet sent.
  Future<void> acked() => _until(() => said.any((m) => m['ack'] == _seq), within: const Duration(seconds: 10));
}
