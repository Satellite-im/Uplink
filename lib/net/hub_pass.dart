import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show HMac, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;

import '../aside.dart';
import 'crypto.dart';

/// A relay's pass phrase as the app shows it knows it (relay/lib/hub.dart: passKeyOf, passProof): a relay hosted from
/// someone's app may ask everyone who uses it for one (lib/relay_host). The phrase never leaves the device: what is
/// said is a proof for the one connection and the one install signing in, which is no use anywhere else. Seen on a
/// local network, a phrase can be tried against it as fast as [rounds] allows: so a long phrase is what stands in the
/// way, and the screens say so.
abstract final class HubPass {
  /// What the phrase is made into, as the relay makes it: PBKDF2-HMAC-SHA256 over [words], a space and the relay's own
  /// salt (said in its hello: `"salt"`), [rounds] rounds, 32 bytes (test/relay_host_test.dart holds the two to one
  /// value). Each relay salts with its own, so guesses made into keys for one are no use against another.
  static const words = 'ghost-hub pass v2';
  static const rounds = 20000;

  static final Map<String, Future<Uint8List>> _keys = {};

  /// Whether [salt] is one a relay may say: 1 to 64 lowercase letters and digits.
  static bool saltOk(Object? salt) => salt is String && RegExp(r'^[0-9a-z]{1,64}$').hasMatch(salt);

  /// The key [phrase] makes for the relay that salts with [salt], worked out aside the first time it is wanted this run
  /// (a tenth of a second or so), and kept in memory after: the last four asked for.
  static Future<Uint8List> keyOf(String phrase, String salt) {
    final which = '$salt\n$phrase';
    final had = _keys.remove(which);
    final key = had ?? runAside(() => keyNow(phrase, salt));
    _keys[which] = key;
    while (_keys.length > 4) {
      _keys.remove(_keys.keys.first);
    }
    return key;
  }

  /// [keyOf], worked out here and now.
  static Uint8List keyNow(String phrase, String salt) {
    final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode('$words $salt')), rounds, 32));
    return d.process(Uint8List.fromList(utf8.encode(phrase)));
  }

  /// What is said in the hello (`"pass"`, hex) to the hub that gave the number [nonce], by the install [id]: HMAC-SHA256
  /// under [key] over [words], a space, the number and the install's name.
  static String proof(List<int> key, List<int> nonce, String id) => NetCrypto.hex(NetCrypto.hmac(key, [...utf8.encode('$words '), ...nonce, ...NetCrypto.unhex(id)]));
}
