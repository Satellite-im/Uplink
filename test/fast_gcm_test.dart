import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/fast_gcm.dart';
import 'package:ghost_messaging/net/fast_gcm_64.dart' as wide;
import 'package:ghost_messaging/net/fast_gcm_web.dart' as web;
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:pointycastle/export.dart';

/// One half of FastGcm (lib/net/fast_gcm.dart), as a test calls either.
typedef Gcm = ({Uint8List Function(Uint8List nonce, Uint8List aad, Uint8List plain) seal, Uint8List? Function(Uint8List nonce, Uint8List aad, Uint8List sealed) open});

/// The one a phone and a computer run, on two 64-bit halves.
Gcm wideGcm(List<int> key) {
  final g = wide.FastGcm(key);
  return (seal: g.seal, open: g.open);
}

/// The one a browser runs: plain Dart, so it runs here too.
Gcm webGcm(List<int> key) {
  final g = web.FastGcm(key);
  return (seal: g.seal, open: g.open);
}

Uint8List unhex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

/// FastGcm against pointycastle's GCM, byte for byte (Matt, 2026-11-18, of uploading to a circle being slow): every
/// file already sealed opens with it, and what it seals opens with the old code. And its two halves against each
/// other (Matt: "the full web client"): what a browser seals a phone opens, and the other way about.
void main() {
  final rnd = Random(42);
  Uint8List bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) rnd.nextInt(256)]);
  Uint8List pc(bool seal, Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data) =>
      (GCMBlockCipher(AESEngine())..init(seal, AEADParameters(KeyParameter(key), 128, nonce, aad))).process(data);

  // The two longest lengths are the 64-bit half's alone: the browser's half is written for JavaScript's numbers and is
  // slow here, where they took it five to seven seconds; 4096 bytes is 256 blocks of it already.
  for (final (half, gcm, long) in [('on 64-bit halves', wideGcm, const [65536, 262144]), ('the browser\'s half', webGcm, const <int>[])]) {
    group(half, () {
      test('the same sealed bytes as pointycastle, every length around a block, and it opens what pointycastle seals', () {
        for (final n in [0, 1, 15, 16, 17, 31, 32, 33, 100, 1000, 4095, 4096, ...long]) {
          for (final aadLen in [0, 13, 16, 41]) {
            final key = bytes(32), nonce = bytes(12), aad = bytes(aadLen), plain = bytes(n);
            final theirs = pc(true, key, nonce, aad, plain);
            final ours = gcm(key).seal(nonce, aad, plain);
            expect(ours, theirs, reason: 'length $n, aad $aadLen');
            expect(gcm(key).open(nonce, aad, theirs), plain);
            expect(pc(false, key, nonce, aad, ours), plain);
          }
        }
      });

      test('a changed byte, a wrong aad or a wrong key is refused', () {
        final key = bytes(32), nonce = bytes(12), aad = bytes(20), plain = bytes(5000);
        final sealed = gcm(key).seal(nonce, aad, plain);
        final bent = Uint8List.fromList(sealed)..[1234] ^= 1;
        expect(gcm(key).open(nonce, aad, bent), isNull);
        expect(gcm(key).open(nonce, bytes(20), sealed), isNull);
        expect(gcm(bytes(32)).open(nonce, aad, sealed), isNull);
        expect(gcm(key).open(nonce, aad, Uint8List.sublistView(sealed, 0, sealed.length - 1)), isNull);
      });

      // The GCM paper's own test cases for a 256-bit key and a 96-bit nonce (McGrew and Viega, cases 13, 14 and 16):
      // answers from outside this code, which either half gives wherever it is run.
      test('the GCM paper\'s answers', () {
        final zero = Uint8List(32), nonce = Uint8List(12), none = Uint8List(0);
        expect(gcm(zero).seal(nonce, none, none), unhex('530f8afbc74536b9a963b4f1c4cb738b'));
        expect(gcm(zero).seal(nonce, none, Uint8List(16)), unhex('cea7403d4d606b6e074ec5d3baf39d18' 'd0d1c8a799996bf0265b98b5d48ab919'));
        final key = unhex('feffe9928665731c6d6a8f9467308308' 'feffe9928665731c6d6a8f9467308308');
        final plain = unhex('d9313225f88406e5a55909c5aff5269a' '86a7a9531534f7da2e4c303d8a318a72' '1c3c0c95956809532fcf0e2449a6b525' 'b16aedf5aa0de657ba637b39');
        final aad = unhex('feedfacedeadbeeffeedfacedeadbeef' 'abaddad2'), iv = unhex('cafebabefacedbaddecaf888');
        final sealed = unhex('522dc1f099567d07f47f37a32a84427d' '643a8cdcbfe5c0c97598a2bd2555d1aa' '8cb08e48590dbb3da7b08b1056828838' 'c5f61e6393ba7a0abcc9f662' '76fc6ece0f4e1768cddf8853bb2d551b');
        expect(gcm(key).seal(iv, aad, plain), sealed);
        expect(gcm(key).open(iv, aad, sealed), plain);
      });

      test('what comes back is a list of its own, exactly as long as what is in it', () {
        final key = bytes(32), nonce = bytes(12), aad = bytes(7);
        for (final n in [0, 5, 16, 40]) {
          final plain = bytes(n);
          final kept = Uint8List.fromList(plain);
          final sealed = gcm(key).seal(nonce, aad, plain);
          expect(sealed.length, n + 16);
          expect(sealed.offsetInBytes, 0);
          expect(sealed.buffer.lengthInBytes, n + 16);
          final opened = gcm(key).open(nonce, aad, sealed)!;
          expect(opened.length, n);
          expect(opened.offsetInBytes, 0);
          expect(opened.buffer.lengthInBytes, n);
          // And what went in is as it was.
          expect(plain, kept);
          // A view into the middle of a longer list is read where it starts.
          final within = Uint8List(n + 50)..setRange(9, 9 + n, plain);
          expect(gcm(key).seal(nonce, aad, Uint8List.sublistView(within, 9, 9 + n)), sealed);
          final sealedWithin = Uint8List(n + 80)..setRange(33, 33 + n + 16, sealed);
          expect(gcm(key).open(nonce, aad, Uint8List.sublistView(sealedWithin, 33, 33 + n + 16)), plain);
        }
      });

      test('a key that is no AES key and a nonce that is not 96 bits are refused the same way', () {
        for (final n in [0, 1, 15, 17, 31, 33, 64]) {
          expect(() => gcm(bytes(n)), throwsArgumentError, reason: 'a key of $n bytes');
        }
        final g = gcm(bytes(32));
        for (final n in [0, 8, 11, 13, 16]) {
          expect(() => g.seal(bytes(n), bytes(3), bytes(40)), throwsArgumentError, reason: 'sealing with a nonce of $n bytes');
          expect(() => g.open(bytes(n), bytes(3), bytes(40)), throwsArgumentError, reason: 'opening with a nonce of $n bytes');
          // Too short to hold a tag is refused before the nonce is looked at.
          expect(g.open(bytes(n), bytes(3), bytes(15)), isNull);
        }
        expect(g.open(bytes(12), bytes(3), bytes(0)), isNull);
        expect(g.open(bytes(12), bytes(3), bytes(15)), isNull);
        expect(g.open(bytes(12), bytes(3), bytes(16)), isNull);
      });

      test('a key changed after it was given changes nothing', () {
        final key = bytes(32), nonce = bytes(12), aad = bytes(4), plain = bytes(100);
        final expected = pc(true, key, nonce, aad, plain);
        final given = Uint8List.fromList(key);
        final g = gcm(given);
        given.fillRange(0, 32, 0);
        expect(g.seal(nonce, aad, plain), expected);
        expect(g.open(nonce, aad, expected), plain);
        // And one made from a plain list of numbers, as some callers hand it over.
        expect(gcm(key.toList()).seal(nonce, aad, plain), expected);
      });
    });
  }

  // The two halves side by side over keys of every AES length, and lengths picked so that many fall on or beside a
  // block's edge: what one seals is the other's bytes, each opens the other's, and each refuses what the other does.
  test('the two halves give the same bytes for four hundred keys, nonces, additional data and lengths', () {
    final r = Random(20261122);
    Uint8List some(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) r.nextInt(256)]);
    var blockEdges = 0;
    for (var i = 0; i < 400; i++) {
      final key = some(const [16, 24, 32][r.nextInt(3)]), nonce = some(12);
      final aad = some(switch (r.nextInt(4)) { 0 => 0, 1 => r.nextInt(17), 2 => 16 * r.nextInt(5), _ => r.nextInt(200) });
      final n = switch (r.nextInt(5)) { 0 => r.nextInt(4), 1 => 16 * r.nextInt(20), 2 => 16 * r.nextInt(20) + (r.nextBool() ? 1 : 15), 3 => r.nextInt(600), _ => r.nextInt(5000) };
      if (n % 16 == 0) blockEdges++;
      final plain = some(n);
      final why = 'case $i: a ${key.length * 8}-bit key, ${aad.length} bytes of additional data, $n bytes';
      final a = wideGcm(key).seal(nonce, aad, plain), b = webGcm(key).seal(nonce, aad, plain);
      expect(b, a, reason: why);
      expect(webGcm(key).open(nonce, aad, a), plain, reason: why);
      expect(wideGcm(key).open(nonce, aad, b), plain, reason: why);
      // One bit changed anywhere (the sealed bytes, or the tag): neither opens it.
      final bent = Uint8List.fromList(a)..[r.nextInt(a.length)] ^= 1 << r.nextInt(8);
      expect(wideGcm(key).open(nonce, aad, bent), isNull, reason: why);
      expect(webGcm(key).open(nonce, aad, bent), isNull, reason: why);
      // Cut short, or with a byte more: neither opens it.
      final cut = Uint8List.sublistView(a, 0, a.length - 1 - r.nextInt(min(a.length, 20)));
      expect(wideGcm(key).open(nonce, aad, cut), isNull, reason: why);
      expect(webGcm(key).open(nonce, aad, cut), isNull, reason: why);
      final more = Uint8List.fromList([...a, r.nextInt(256)]);
      expect(wideGcm(key).open(nonce, aad, more), isNull, reason: why);
      expect(webGcm(key).open(nonce, aad, more), isNull, reason: why);
      // Other additional data, or another nonce: neither opens it.
      final otherAad = Uint8List.fromList([...aad, 0]);
      expect(wideGcm(key).open(nonce, otherAad, a), isNull, reason: why);
      expect(webGcm(key).open(nonce, otherAad, a), isNull, reason: why);
      final otherNonce = Uint8List.fromList(nonce)..[r.nextInt(12)] ^= 0x80;
      expect(wideGcm(key).open(otherNonce, aad, a), isNull, reason: why);
      expect(webGcm(key).open(otherNonce, aad, a), isNull, reason: why);
    }
    // The picking did reach the lengths that matter.
    expect(blockEdges, greaterThan(60));
  });

  test('where this runs, FastGcm is the half on 64-bit integers', () {
    expect(FastGcm(Uint8List(32)), isA<wide.FastGcm>());
  });

  test('a Files run seals and opens as before', () {
    final key = bytes(32), prefix = bytes(8), id = 'ab' * 16;
    final size = FileSeal.chunk * 2 + 777;
    final plain = bytes(size);
    final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, plain: plain));
    expect(sealed.length, FileSeal.sealedSize(size));
    expect(FileSeal.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, sealed: sealed)), plain);
  });
}
