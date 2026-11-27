import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_messaging/voice/music_sink.dart';

/// What native/voicefx/music_pack.c made of 13 kinds of sound, with the samples each came from.
List<({Uint8List packed, Int16List pcm})> musicChunks() {
  final all = File('test/support/music_chunks.bin').readAsBytesSync();
  final d = ByteData.sublistView(all);
  final out = <({Uint8List packed, Int16List pcm})>[];
  for (var at = 0; at < all.length;) {
    final n = d.getUint32(at, Endian.little), m = d.getUint32(at + 4, Endian.little);
    at += 8;
    out.add((packed: Uint8List.sublistView(all, at, at + n), pcm: Int16List.fromList([for (var i = 0; i < m ~/ 2; i++) d.getInt16(at + n + i * 2, Endian.little)])));
    at += n + m;
  }
  return out;
}

/// A chunk of plain samples, numbered from [at].
Uint8List plainChunk(int at, Int16List lr, {int version = 1}) {
  final b = ByteData(12 + lr.length * 2);
  b.setUint8(0, version);
  b.setUint16(2, lr.length ~/ 2, Endian.little);
  b.setUint32(4, at % 0x100000000, Endian.little);
  b.setUint16(8, at ~/ 0x100000000, Endian.little);
  b.setUint16(10, lr.length * 2, Endian.little);
  for (var i = 0; i < lr.length; i++) {
    b.setInt16(12 + i * 2, lr[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// A player that plays as fast as it is told to ([play]), and keeps what it was given.
class FakeSink implements MusicSink {
  final List<int> heard = [];
  int waiting = 0, dry = 0;
  bool opened = false, closed = false, silent = true, running = false, opens = true;
  double volume = 0;
  String device = '?';
  MusicWay where = const MusicWay(MusicTo.headphones, 48000);
  final List<String> log = [];

  @override
  Future<bool> open(String to) async {
    opened = opens;
    device = to;
    log.add('open $to');
    return opens;
  }

  @override
  Future<SinkNow> write(Uint8List pcm) async {
    heard.addAll(Int16List.sublistView(Uint8List.fromList(pcm)));
    waiting += pcm.length ~/ 4;
    running = true;
    return SinkNow(waiting, dry);
  }

  /// [frames] go by.
  void play(int frames) {
    if (!running) return;
    waiting -= frames;
    if (waiting < 0) {
      waiting = 0;
      dry++;
      running = false;
    }
  }

  @override
  Future<void> clear() async {
    waiting = 0;
    running = false;
    log.add('clear');
  }

  @override
  Future<void> set({required double volume, required bool silent}) async {
    this.volume = volume;
    this.silent = silent;
    log.add(silent ? 'silent' : 'heard');
  }

  @override
  Future<void> output(String to) async {
    device = to;
    log.add('output $to');
  }

  /// The speakers it was asked of.
  final List<String> asked = [];
  @override
  Future<MusicWay> way(String to) async {
    asked.add(to);
    return where;
  }

  @override
  Future<void> close() async {
    closed = true;
    running = false;
    log.add('close');
  }
}
