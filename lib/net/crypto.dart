import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'fast_gcm.dart';

/// A key pair on P-256: who an install is to the others it talks to (lib/net). On a phone the app's own pair is
/// the one its encryption already has (android/.../E2e.kt), kept by Android; this is the same thing in Dart, for
/// a computer, for the tests, and for checking the two agree.
class NetKeys {
  NetKeys._(this._private, this.public);
  final ECPrivateKey _private;

  /// The public half as 33 bytes: 02 or 03 for y's parity, then x. What E2eCrypto.publicBytes makes.
  final Uint8List public;

  /// The name the others know this install by (NetCrypto.idOf).
  String get id => NetCrypto.idOf(public);

  /// The private half's 32 bytes, to keep somewhere safe.
  Uint8List get scalar => NetCrypto.unhex(_private.d!.toRadixString(16).padLeft(64, '0'));

  /// A new pair; and the pair whose private half is [scalar] (32 bytes).
  static NetKeys generate() {
    final gen = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(NetCrypto.curve), NetCrypto.random));
    final pair = gen.generateKeyPair();
    return NetKeys._(pair.privateKey, pair.publicKey.Q!.getEncoded(true));
  }

  static NetKeys fromScalar(List<int> scalar) {
    final d = BigInt.parse(NetCrypto.hex(scalar), radix: 16);
    return NetKeys._(ECPrivateKey(d, NetCrypto.curve), (NetCrypto.curve.G * d)!.getEncoded(true));
  }
}

/// The cryptography of the app's routes (lib/net): names from keys, the key two installs share, sealing a packet
/// with it, and signing to a hub. It agrees with android/.../E2eCrypto.kt, so a phone's Kotlin and a computer's
/// Dart make the same key from the same two key pairs (test/net_test.dart holds a made pair to the same bytes).
class NetCrypto {
  // The curve (P-256); what every packet sealed here is bound to; and the info a conversation key is made with.
  static final ECDomainParameters curve = ECCurve_secp256r1();
  static final Uint8List _aad = Uint8List.fromList(utf8.encode('ghost-net-v1'));
  static final Uint8List _info = Uint8List.fromList(utf8.encode('ghost-messaging e2e v1'));

  /// The app's secure random: Fortuna, seeded once from the system's.
  static final SecureRandom random = () {
    final seed = Random.secure();
    return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
  }();

  // Random bytes; bytes as lower-case hex, and back ([unhex] takes capitals too, drops an odd last letter, and
  // throws on anything not hex); SHA-256.
  static Uint8List randomBytes(int n) => random.nextBytes(n);
  static String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static Uint8List unhex(String text) => Uint8List.fromList([for (var i = 0; i + 1 < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);
  static Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));

  /// HMAC-SHA256 of [data] under [key].
  static Uint8List hmac(List<int> key, List<int> data) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)));
    return mac.process(Uint8List.fromList(data));
  }

  /// The name an install is known by: the first 16 bytes of the SHA-256 of its public key, in hex. Nothing of the
  /// key can be worked back from it, and a hub or a stranger learns no number or name from it.
  static String idOf(List<int> publicKey) => hex(sha256(publicKey).sublist(0, 16));

  /// [a] and [b] joined, the lower first, so both ends make the same salt whichever is theirs.
  static Uint8List _ordered(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return Uint8List.fromList(a[i] < b[i] ? [...a, ...b] : [...b, ...a]);
    }
    return Uint8List.fromList([...a, ...b]);
  }

  /// The key the holder of [mine] and the holder of [theirs] (33 bytes) both arrive at, as E2eCrypto.conversationKey
  /// makes it: ECDH, then HKDF-SHA256 salted with both public keys in a fixed order. Null when [theirs] is no key.
  static Uint8List? conversationKey(NetKeys mine, List<int> theirs) {
    final shared = agree(mine, theirs);
    if (shared == null) return null;
    final prk = hmac(_ordered(mine.public, theirs), shared);
    return hmac(prk, [..._info, 1]);
  }

  /// Plain ECDH on P-256: the 32-byte x of [mine]'s private half times [theirs] (33 bytes, compressed). Null when
  /// [theirs] is no point on the curve. What [conversationKey] stands on, and forward secrecy's one-off keys
  /// (lib/net/forward_secrecy.dart); never a key on its own, always through [hkdf] first.
  static Uint8List? agree(NetKeys mine, List<int> theirs) {
    if (theirs.length != 33 || (theirs[0] != 2 && theirs[0] != 3)) return null;
    try {
      final point = curve.curve.decodePoint(theirs);
      if (point == null || point.isInfinity) return null;
      final s = (ECDHBasicAgreement()..init(mine._private)).calculateAgreement(ECPublicKey(point, curve));
      return unhex(s.toRadixString(16).padLeft(64, '0'));
    } catch (_) {
      return null;
    }
  }

  /// HKDF-SHA256 (RFC 5869) for one 32-byte key: extract with [salt], expand with [info].
  static Uint8List hkdf({required List<int> salt, required List<int> ikm, required List<int> info}) => hmac(hmac(salt, ikm), [...info, 1]);

  /// A key for one purpose made from another: a pair's key for the routes from its conversation key ('pair'), a
  /// room's name and token from its key ('room name', 'room token'). The same words on both ends give the same key.
  static Uint8List derive(List<int> key, String label) => hmac(key, [...utf8.encode('ghost-net $label'), 1]);

  /// What two installs seal the routes' packets with: made from their conversation key and never used for texts.
  static Uint8List netKey(List<int> conversationKey) => derive(conversationKey, 'pair');

  /// [clear] sealed with [key]: twelve random bytes, then AES-256-GCM's output and its tag.
  static Uint8List seal(List<int> key, List<int> clear) {
    final nonce = randomBytes(12);
    // FastGcm: pointycastle's GCM bytes, about ten times faster (lib/net/fast_gcm.dart).
    return Uint8List.fromList([...nonce, ...FastGcm(key).seal(nonce, _aad, Uint8List.fromList(clear))]);
  }

  /// What was sealed, or null when [sealed] was changed, cut short, or made under another key.
  static Uint8List? open(List<int> key, List<int> sealed) {
    if (sealed.length < 12 + 16) return null;
    try {
      return FastGcm(key).open(Uint8List.fromList(sealed.sublist(0, 12)), _aad, Uint8List.fromList(sealed.sublist(12)));
    } catch (_) {
      return null;
    }
  }

  /// [n] as 32 bytes, big-endian.
  static Uint8List _fixed(BigInt n) => unhex(n.toRadixString(16).padLeft(64, '0'));

  /// [mine]'s signature over [message] (hashed with SHA-256): r then s, 64 bytes.
  static Uint8List sign(NetKeys mine, List<int> message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))..init(true, PrivateKeyParameter<ECPrivateKey>(mine._private));
    final sig = signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
    return Uint8List.fromList([..._fixed(sig.r), ..._fixed(sig.s)]);
  }

  /// [verify], with the answer remembered for the same key, message and signature (it can be no other): for what is
  /// asked again and again of the same grant while a screen is drawn, a role's or an admin's. A check is several
  /// milliseconds of arithmetic in Dart, and was made anew for every message row at every build
  /// (docs/performance-audit.md, finding 7). The newest [_mostChecks] answers are kept.
  static bool verifyOnce(List<int> publicKey, List<int> message, List<int> signature) {
    final key = '${String.fromCharCodes(publicKey)}\u0000${String.fromCharCodes(signature)}\u0000${String.fromCharCodes(message)}';
    final had = _checks[key];
    if (had != null) return had;
    if (_checks.length >= _mostChecks) _checks.remove(_checks.keys.first);
    return _checks[key] = verify(publicKey, message, signature);
  }

  static const _mostChecks = 2048;
  static final Map<String, bool> _checks = {};

  /// How many signatures have been checked in full, for a test that counts them.
  static int verifications = 0;

  /// Whether [signature] is the holder of [publicKey]'s over [message].
  static bool verify(List<int> publicKey, List<int> message, List<int> signature) {
    verifications++;
    if (signature.length != 64 || publicKey.length != 33) return false;
    try {
      final point = curve.curve.decodePoint(publicKey);
      if (point == null || point.isInfinity) return false;
      final verifier = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(point, curve)));
      final r = BigInt.parse(hex(signature.sublist(0, 32)), radix: 16);
      final s = BigInt.parse(hex(signature.sublist(32)), radix: 16);
      return verifier.verifySignature(Uint8List.fromList(message), ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }
}
