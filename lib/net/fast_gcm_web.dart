import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-GCM in a browser (lib/net/fast_gcm.dart): pointycastle's GCMBlockCipher, which works a byte at a time and so
/// gives the same bytes whatever an integer is. Everything about it that a caller can see is fast_gcm_64.dart's: a
/// 96-bit nonce and a 128-bit tag, the tag after the sealed bytes; what comes back is a list of its own, exactly as
/// long as what is in it; and the same things are refused in the same way.
///
/// It is as slow as pointycastle's GCM is (the reason for the other half: a megabyte or two a second), which a
/// message never notices and a big file will. Plain Dart: test/fast_gcm_test.dart runs it on a computer.
class FastGcm {
  FastGcm(List<int> key) : _key = Uint8List.fromList(key) {
    // A key that is no AES key is refused here, where the other half refuses it, not at the first use.
    AESEngine().init(true, KeyParameter(_key));
  }

  /// A copy, as the other half's key schedule is: the caller's list changing afterwards changes nothing.
  final Uint8List _key;

  /// pointycastle's cipher, set to seal or to open with [nonce] and [aad] and a 128-bit tag.
  GCMBlockCipher _gcm(bool sealing, Uint8List nonce, Uint8List aad) {
    if (nonce.length != 12) throw ArgumentError('a 96-bit nonce');
    return GCMBlockCipher(AESEngine())..init(sealing, AEADParameters(KeyParameter(_key), 128, nonce, aad));
  }

  /// [plain] sealed: its bytes then the 16-byte tag.
  Uint8List seal(Uint8List nonce, Uint8List aad, Uint8List plain) {
    final gcm = _gcm(true, nonce, aad);
    // pointycastle's own `process` hands back a view of a longer buffer; written here, it is exactly this long.
    final out = Uint8List(plain.length + 16);
    gcm.doFinal(out, gcm.processBytes(plain, 0, plain.length, out, 0));
    return out;
  }

  /// [sealed] (its bytes then the tag) opened; null where the tag doesn't match.
  Uint8List? open(Uint8List nonce, Uint8List aad, Uint8List sealed) {
    if (sealed.length < 16) return null;
    final gcm = _gcm(false, nonce, aad);
    final out = Uint8List(sealed.length - 16);
    try {
      gcm.doFinal(out, gcm.processBytes(sealed, 0, sealed.length, out, 0));
    } on InvalidCipherTextException {
      return null;
    }
    return out;
  }
}
