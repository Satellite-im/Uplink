import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/flac.dart';
import 'package:ghost_messaging/voice/spotify_lossless.dart';

import 'support/lossless_stand_ins.dart';

/// The music's chunks as native/voicefx/music_pack.c makes them (test/support/music_chunks.bin, written by
/// native/voicefx/test/run_pack.sh fixture), read in Dart (lib/voice/flac.dart, lib/voice/spotify_lossless.dart).
void main() {
  final chunks = musicChunks();

  test('every kind of sound comes back bit for bit', () {
    expect(chunks, hasLength(13));
    for (final (i, c) in chunks.indexed) {
      final read = MusicChunk.read(c.packed)!;
      expect(read.frames, c.pcm.length ~/ 2, reason: '$i');
      expect(read.at, i * 0x1234567 + (i == 12 ? 0x100000000 : 0), reason: 'the number runs past 32 bits');
      expect(read.samples(), c.pcm, reason: 'kind $i');
    }
    // Packed it is smaller, where it is like music.
    expect(chunks[6].packed.length, lessThan(chunks[6].pcm.length * 2 * 0.75));
  });

  test('a byte changed anywhere, or a part missing, is refused and never thrown', () {
    for (final c in chunks) {
      for (var i = 0; i < c.packed.length; i += c.packed.length ~/ 61 + 1) {
        final broken = Uint8List.fromList(c.packed)..[i] ^= 1 << (i & 7);
        final read = MusicChunk.read(broken);
        // Its number may be changed and read: anything else is noticed.
        if (i >= 4 && i < 10) continue;
        expect(read?.samples(), isNull, reason: 'byte $i of ${c.packed.length}');
      }
      for (var n = 0; n < c.packed.length; n += c.packed.length ~/ 17 + 1) {
        expect(MusicChunk.read(Uint8List.sublistView(c.packed, 0, n))?.samples(), isNull);
      }
      expect(MusicChunk.read(Uint8List.fromList([...c.packed, 0])), isNull);
    }
  });

  test('noise for a chunk is refused, and quickly', () {
    final r = Random(7);
    final clock = Stopwatch()..start();
    for (var i = 0; i < 3000; i++) {
      final len = r.nextInt(6000);
      final bytes = Uint8List.fromList([for (var k = 0; k < len; k++) r.nextInt(256)]);
      expect(Flac.read(bytes, 16 + r.nextInt(5000)), isNull);
      // With a head that is right and a payload that is not.
      final b = Uint8List.fromList([1, 1, 128, 7, 0, 0, 0, 0, 0, 0, len & 0xff, len >> 8, ...bytes]);
      expect(MusicChunk.read(b)?.samples(), isNull);
    }
    expect(clock.elapsed, lessThan(const Duration(seconds: 20)));
  });

  test('the head: what is not this version, not a whole chunk, or not a size there may be, is not a chunk', () {
    final good = plainChunk(0, Int16List(1920 * 2));
    expect(MusicChunk.read(good)!.samples(), Int16List(1920 * 2));
    Uint8List but(int i, int v) => Uint8List.fromList(good)..[i] = v;
    expect(MusicChunk.read(but(0, 2)), isNull);
    expect(MusicChunk.version(but(0, 2)), 2);
    expect(MusicChunk.read(but(1, 2)), isNull, reason: 'a flag not known');
    expect(MusicChunk.read(but(1, 1))!.samples(), isNull, reason: 'it is not FLAC');
    expect(MusicChunk.read(but(2, 0)), isNull, reason: 'plain samples of another length');
    expect(MusicChunk.read(but(3, 0xff)), isNull, reason: 'more frames than there may be');
    expect(MusicChunk.read(but(10, 1)), isNull);
    expect(MusicChunk.read(Uint8List(0)), isNull);
    expect(MusicChunk.read(Uint8List(MusicChunk.most + 1)..[0] = 1), isNull);
    expect(MusicChunk.version(Uint8List(0)), isNull);
    // Silence is 17 bytes and 1920 frames; that is as far as a little can become a lot.
    expect(File('test/support/music_chunks.bin').lengthSync(), lessThan(60000));
  });
}
