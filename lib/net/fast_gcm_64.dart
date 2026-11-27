import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-256-GCM, the same bytes as pointycastle's GCMBlockCipher, about ten times faster (Matt, 2026-11-18, of
/// uploading to a circle being slow). pointycastle's GHASH ran at under 2 MB/s and made every file sealed for a Files
/// space (lib/net/file_seal.dart) go up and come down at that speed, whatever the connection; its AES alone runs
/// at over 25 MB/s. Here GHASH is the 4-bit table method (Shoup's, as mbedTLS and most C libraries have it) on two
/// 64-bit halves, and the counter mode drives pointycastle's AES block by block.
///
/// Only what Files needs: a 96-bit nonce and a 128-bit tag, the tag after the sealed bytes. test/fast_gcm_test.dart
/// checks it byte for byte against pointycastle.
class FastGcm {
  FastGcm(List<int> key) : _aes = AESEngine()..init(true, KeyParameter(key is Uint8List ? key : Uint8List.fromList(key))) {
    final h = Uint8List(16);
    _aes.processBlock(Uint8List(16), 0, h, 0);
    _table(_u64(h, 0), _u64(h, 8));
  }

  final AESEngine _aes;

  /// The hash key H times each 4-bit value, as low and high 64-bit halves ([_table]).
  final _hl = List<int>.filled(16, 0), _hh = List<int>.filled(16, 0);

  /// What shifting four bits off the end folds back in, for each value of those bits (the field's reduction).
  static const _last4 = [0x0000, 0x1c20, 0x3840, 0x2460, 0x7080, 0x6ca0, 0x48c0, 0x54e0, 0xe100, 0xfd20, 0xd940, 0xc560, 0x9180, 0x8da0, 0xa9c0, 0xb5e0];

  /// The eight bytes of [b] at [at] as one number, big-endian; [_put64] writes one back.
  static int _u64(Uint8List b, int at) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[at + i];
    }
    return v;
  }

  static void _put64(Uint8List b, int at, int v) {
    for (var i = 7; i >= 0; i--) {
      b[at + i] = v & 0xff;
      v >>>= 8;
    }
  }

  /// Fills the table from the hash key's two halves: the powers of two by halving in the field, the rest by xor.
  void _table(int vh, int vl) {
    _hl[8] = vl;
    _hh[8] = vh;
    for (var i = 4; i > 0; i >>= 1) {
      final t = (vl & 1) != 0 ? 0xe100000000000000 : 0;
      vl = (vh << 63) | (vl >>> 1);
      vh = (vh >>> 1) ^ t;
      _hl[i] = vl;
      _hh[i] = vh;
    }
    for (var i = 2; i <= 8; i *= 2) {
      for (var j = 1; j < i; j++) {
        _hh[i + j] = _hh[i] ^ _hh[j];
        _hl[i + j] = _hl[i] ^ _hl[j];
      }
    }
  }

  // The running hash, as two halves.
  int _zh = 0, _zl = 0;

  /// Folds the 16 bytes at [x] (zero past [n]) into the hash: Y = (Y xor X) * H.
  void _fold(Uint8List x, int at, int n) {
    var xh = 0, xl = 0;
    if (n == 16) {
      for (var i = 0; i < 8; i++) {
        xh = (xh << 8) | x[at + i];
      }
      for (var i = 8; i < 16; i++) {
        xl = (xl << 8) | x[at + i];
      }
    } else {
      for (var i = 0; i < 16; i++) {
        final v = i < n ? x[at + i] : 0;
        if (i < 8) {
          xh = (xh << 8) | v;
        } else {
          xl = (xl << 8) | v;
        }
      }
    }
    final yh = _zh ^ xh, yl = _zl ^ xl;
    final hh = _hh, hl = _hl;
    // Byte 15 is yl's lowest; byte i is (i < 8 ? yh : yl) shifted down by 8 * (7 - i % 8).
    var lo = yl & 0xf;
    var zh = hh[lo], zl = hl[lo];
    for (var i = 15; i >= 0; i--) {
      final b = ((i < 8 ? yh : yl) >>> (8 * (7 - (i & 7)))) & 0xff;
      lo = b & 0xf;
      final hi = b >> 4;
      if (i != 15) {
        final rem = zl & 0xf;
        zl = (zh << 60) | (zl >>> 4);
        zh = (zh >>> 4) ^ (_last4[rem] << 48) ^ hh[lo];
        zl ^= hl[lo];
      }
      final rem = zl & 0xf;
      zl = (zh << 60) | (zl >>> 4);
      zh = (zh >>> 4) ^ (_last4[rem] << 48) ^ hh[hi];
      zl ^= hl[hi];
    }
    _zh = zh;
    _zl = zl;
  }

  /// Folds [length] bytes of [data] from [from] into the hash, sixteen at a time, the last block padded with zeros.
  void _hash(Uint8List data, int from, int length) {
    var at = from;
    final end = from + length;
    while (at < end) {
      final n = end - at < 16 ? end - at : 16;
      _fold(data, at, n);
      at += n;
    }
  }

  /// Runs the counter from J0 + 1 over [input] into [out] (encrypting or decrypting alike).
  void _ctr(Uint8List j0, Uint8List input, int length, Uint8List out) {
    final counter = Uint8List.fromList(j0);
    final ks = Uint8List(16);
    var c = (counter[12] << 24) | (counter[13] << 16) | (counter[14] << 8) | counter[15];
    for (var at = 0; at < length; at += 16) {
      c = (c + 1) & 0xffffffff;
      counter[12] = c >>> 24;
      counter[13] = (c >>> 16) & 0xff;
      counter[14] = (c >>> 8) & 0xff;
      counter[15] = c & 0xff;
      _aes.processBlock(counter, 0, ks, 0);
      final n = length - at < 16 ? length - at : 16;
      for (var i = 0; i < n; i++) {
        out[at + i] = input[at + i] ^ ks[i];
      }
    }
  }

  /// The 16-byte tag: the hash of [aad], the sealed bytes and both their lengths in bits, xored with J0 encrypted.
  Uint8List _tag(Uint8List j0, Uint8List aad, Uint8List cipher, int cipherLength) {
    _zh = 0;
    _zl = 0;
    _hash(aad, 0, aad.length);
    _hash(cipher, 0, cipherLength);
    final lens = Uint8List(16);
    _put64(lens, 0, aad.length * 8);
    _put64(lens, 8, cipherLength * 8);
    _fold(lens, 0, 16);
    final s = Uint8List(16);
    _put64(s, 0, _zh);
    _put64(s, 8, _zl);
    final ek = Uint8List(16);
    _aes.processBlock(j0, 0, ek, 0);
    for (var i = 0; i < 16; i++) {
      s[i] ^= ek[i];
    }
    return s;
  }

  /// The first counter block for a 96-bit [nonce]: the nonce, then the number 1 in four bytes.
  static Uint8List _j0(Uint8List nonce) {
    if (nonce.length != 12) throw ArgumentError('a 96-bit nonce');
    return Uint8List(16)
      ..setRange(0, 12, nonce)
      ..[15] = 1;
  }

  /// [plain] sealed: its bytes then the 16-byte tag.
  Uint8List seal(Uint8List nonce, Uint8List aad, Uint8List plain) {
    final j0 = _j0(nonce);
    final out = Uint8List(plain.length + 16);
    _ctr(j0, plain, plain.length, out);
    out.setRange(plain.length, plain.length + 16, _tag(j0, aad, out, plain.length));
    return out;
  }

  /// [sealed] (its bytes then the tag) opened; null where the tag doesn't match.
  Uint8List? open(Uint8List nonce, Uint8List aad, Uint8List sealed) {
    if (sealed.length < 16) return null;
    final j0 = _j0(nonce);
    final n = sealed.length - 16;
    final tag = _tag(j0, aad, sealed, n);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ sealed[n + i];
    }
    if (diff != 0) return null;
    final out = Uint8List(n);
    _ctr(j0, sealed, n, out);
    return out;
  }
}
