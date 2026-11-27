import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/held_store.dart';
import 'package:ghost_relay/hub.dart';

/// What keeping held packets on disk costs (hub.dart keepHeld, held_store.dart):
///
///     dart run tool/held_store_bench.dart
///
/// 1. Holding a packet for someone away (`Hub.deliver`, the path a packet from another relay or a connection takes
///    when nobody is here), with the store off and on: the time on the event loop per packet.
/// 2. Writing what waits (what the store's timer does every 200 ms): the time per megabyte.
/// 3. Reading it all back as the hub starts.
///
/// A packet to someone who is here is never written: its cost is the same either way, and not measured.
void main() {
  const size = 1024, people = 400, each = Hub.mailboxFrames;
  final rnd = Random(1);
  String id() => [for (var i = 0; i < 16; i++) rnd.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  final to = [for (var i = 0; i < people; i++) id()], from = id();
  final packet = Uint8List.fromList(List.generate(size, (i) => rnd.nextInt(256)));
  final n = people * each;

  double hold(Hub hub) {
    final sw = Stopwatch()..start();
    for (var r = 0; r < each; r++) {
      for (final t in to) {
        hub.deliver(t, from, packet);
      }
    }
    return sw.elapsedMicroseconds / n;
  }

  // Off and on in turn, five times each, the quickest of each kept: the machine's other work comes and goes.
  final dir = Directory.systemTemp.createTempSync('held-bench-');
  try {
    var perOff = double.infinity, perOn = double.infinity, flushMs = double.infinity, loadMs = double.infinity, mb = 0.0, items = 0;
    for (var round = 0; round < 5; round++) {
      final off = Hub(heldBytes: 1 << 30)..start();
      perOff = min(perOff, hold(off));
      off.stop();
      final data = Directory('${dir.path}/$round')..createSync();
      final on = Hub(heldBytes: 1 << 30, dataDir: data, keepHeld: true)..start();
      perOn = min(perOn, hold(on));
      final store = on.heldStore!;
      mb = store.diskBytes / (1 << 20);
      final sw = Stopwatch()..start();
      store.flushNow();
      flushMs = min(flushMs, sw.elapsedMicroseconds / 1000);
      on.stop();
      sw
        ..reset()
        ..start();
      final back = HeldStore(Directory('${data.path}/held'));
      items = back.load().length;
      loadMs = min(loadMs, sw.elapsedMicroseconds / 1000);
      back.close();
      data.deleteSync(recursive: true);
    }

    stdout.writeln('$n packets of $size bytes held for $people people:');
    stdout.writeln('  holding one, store off: ${perOff.toStringAsFixed(2)} µs; store on: ${perOn.toStringAsFixed(2)} µs (+${(perOn - perOff).toStringAsFixed(2)} µs)');
    stdout.writeln('  writing what waited (${mb.toStringAsFixed(1)} MB): ${flushMs.toStringAsFixed(1)} ms, ${(flushMs / mb).toStringAsFixed(2)} ms a MB');
    stdout.writeln('  reading $items back as the hub starts: ${loadMs.toStringAsFixed(0)} ms');
  } finally {
    dir.deleteSync(recursive: true);
  }
}
