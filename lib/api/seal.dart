/// The API's remote link's keys and sealing (lib/api/remote.dart): everything from one secret of 32 random bytes,
/// made on the phone and shown in Settings › API as `ghostapi1:<64 hex digits>`. From it, as tool/ghost-api.mjs works
/// it out too: the relay channel the two ends meet on and its token (so only holders get in), and the AES-256-GCM key
/// every request and answer is sealed with (so the relay passes bytes it cannot read).
library;

import 'dart:convert';
import 'dart:typed_data';


import '../desktop/link/crypto.dart' show DeskCrypto;
import '../net/fast_gcm.dart';

/// What one secret makes: the channel, its token and the key, with sealing and opening under that key.
class ApiSeal {
  ApiSeal(List<int> secret)
      : channel = DeskCrypto.hex(DeskCrypto.hkdf(_salt, secret, 'relay channel').sublist(0, 16)),
        token = DeskCrypto.hex(DeskCrypto.hkdf(_salt, secret, 'relay token')),
        key = DeskCrypto.hkdf(_salt, secret, 'seal key');

  // HKDF's salt, what every sealed frame is bound to, and how a connection string starts.
  static final List<int> _salt = utf8.encode('ghost-api v1');
  static final Uint8List _aad = Uint8List.fromList(utf8.encode('ghost-api-v1'));
  static const prefix = 'ghostapi1:';

  /// The relay channel (32 hex digits) and its token (64), and the sealing key.
  final String channel;
  final String token;
  final Uint8List key;

  /// A new secret, as its connection string.
  static String newSecret() => '$prefix${DeskCrypto.hex(DeskCrypto.randomBytes(32))}';

  /// The secret in a connection string; null where it is not one.
  static Uint8List? secretOf(String connection) {
    final s = connection.trim();
    if (!s.startsWith(prefix)) return null;
    final h = s.substring(prefix.length);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) return null;
    return DeskCrypto.unhex(h);
  }

  /// [clear] sealed: a 12-byte nonce, then the cipher text with GCM's 16-byte tag at its end.
  Uint8List seal(List<int> clear) {
    final nonce = DeskCrypto.randomBytes(12);
    return DeskCrypto.concat([nonce, FastGcm(key).seal(nonce, _aad, Uint8List.fromList(clear))]);
  }

  /// [sealed] opened; null where it is not one sealed with this key.
  Uint8List? open(List<int> sealed) {
    if (sealed.length < 12 + 16) return null;
    try {
      return FastGcm(key).open(Uint8List.fromList(sealed.sublist(0, 12)), _aad, Uint8List.fromList(sealed.sublist(12)));
    } catch (_) {
      return null;
    }
  }
}
