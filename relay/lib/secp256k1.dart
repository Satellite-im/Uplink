import 'dart:convert';

import 'keccak.dart';

/// secp256k1 with Dart's own BigInt and nothing else, for accounts.dart: who wrote to an account is whoever's signature
/// recovers to its address, as an Ethereum wallet's personal_sign does (EIP-191). The app signs with pointycastle
/// (lib/account/account_crypto.dart); test/account_crypto_test.dart in the app holds this to the same addresses. Like
/// p256.dart it handles nothing secret but in [sign], which is here for the tests, and so need not be constant-time.
class Secp256k1 {
  /// The curve y² = x³ + 7: the field's prime [p], the group's order [n], and the base point.
  static final BigInt p = BigInt.parse('fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f', radix: 16);
  static final BigInt n = BigInt.parse('fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141', radix: 16);
  static final BigInt _gx = BigInt.parse('79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798', radix: 16);
  static final BigInt _gy = BigInt.parse('483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8', radix: 16);
  static final BigInt _seven = BigInt.from(7);

  static BigInt _int(List<int> bytes) => bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b & 0xff));
  static List<int> _bytes(BigInt v) => [for (var i = 31; i >= 0; i--) ((v >> (8 * i)) & BigInt.from(0xff)).toInt()];

  // A point as (X, Y, Z) with x = X/Z², y = Y/Z³; Z of nothing is the point at infinity. a is 0 on this curve.
  static List<BigInt> _double(List<BigInt> a) {
    if (a[2] == BigInt.zero || a[1] == BigInt.zero) return [BigInt.one, BigInt.one, BigInt.zero];
    final xx = a[0] * a[0] % p;
    final yy = a[1] * a[1] % p;
    final yyyy = yy * yy % p;
    final d = BigInt.two * ((a[0] + yy) * (a[0] + yy) - xx - yyyy) % p;
    final e = BigInt.from(3) * xx % p;
    final x3 = (e * e - BigInt.two * d) % p;
    final y3 = (e * (d - x3) - BigInt.from(8) * yyyy) % p;
    final z3 = BigInt.two * a[1] * a[2] % p;
    return [x3, y3, z3];
  }

  // The sum of two points; then [_times], a point added to itself k times by doubling and adding; then [_affine], a
  // point's own x and y, or null for the point at infinity. As in p256.dart.
  static List<BigInt> _add(List<BigInt> a, List<BigInt> b) {
    if (a[2] == BigInt.zero) return b;
    if (b[2] == BigInt.zero) return a;
    final z1z1 = a[2] * a[2] % p;
    final z2z2 = b[2] * b[2] % p;
    final u1 = a[0] * z2z2 % p;
    final u2 = b[0] * z1z1 % p;
    final s1 = a[1] * b[2] * z2z2 % p;
    final s2 = b[1] * a[2] * z1z1 % p;
    final h = (u2 - u1) % p;
    final r = (s2 - s1) % p;
    if (h == BigInt.zero) return r == BigInt.zero ? _double(a) : [BigInt.one, BigInt.one, BigInt.zero];
    final hh = h * h % p;
    final hhh = h * hh % p;
    final v = u1 * hh % p;
    final x3 = (r * r - hhh - BigInt.two * v) % p;
    final y3 = (r * (v - x3) - s1 * hhh) % p;
    final z3 = a[2] * b[2] * h % p;
    return [x3, y3, z3];
  }

  static List<BigInt> _times(List<BigInt> point, BigInt k) {
    var out = [BigInt.one, BigInt.one, BigInt.zero];
    for (var i = k.bitLength - 1; i >= 0; i--) {
      out = _double(out);
      if ((k >> i) & BigInt.one == BigInt.one) out = _add(out, point);
    }
    return out;
  }

  static (BigInt, BigInt)? _affine(List<BigInt> a) {
    if (a[2] == BigInt.zero) return null;
    final zi = a[2].modInverse(p);
    final zi2 = zi * zi % p;
    return (a[0] * zi2 % p, a[1] * zi2 * zi % p);
  }

  static List<BigInt> get _g => [_gx, _gy, BigInt.one];

  /// Keccak-256 of EIP-191's personal-message form of [message]: what a wallet signs for personal_sign.
  static List<int> personalHash(List<int> message) => keccak256([...utf8.encode('\x19Ethereum Signed Message:\n${message.length}'), ...message]);

  /// The address (0x and 40 lower-case hex digits) of the key that made [signature] (r, s, v: 65 bytes, v 27/28 or
  /// 0/1) over [message]; null where it is not a signature. Signatures with a high s are refused, as Ethereum does,
  /// so each message has one signature per key.
  static String? signer(List<int> message, List<int> signature) {
    if (signature.length != 65) return null;
    final v = signature[64] >= 27 ? signature[64] - 27 : signature[64];
    if (v != 0 && v != 1) return null;
    final r = _int(signature.sublist(0, 32));
    final s = _int(signature.sublist(32, 64));
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s > n >> 1) return null;
    // R from its x (r) and y's parity (v); p is 3 mod 4, so a square root is rhs^((p+1)/4).
    final rhs = (r * r * r + _seven) % p;
    var y = rhs.modPow((p + BigInt.one) >> 2, p);
    if (y * y % p != rhs) return null;
    if (y.isOdd != (v == 1)) y = p - y;
    final e = _int(personalHash(message)) % n;
    final ri = r.modInverse(n);
    // Q = r⁻¹ (sR − eG)
    final q = _affine(_add(_times([r, y, BigInt.one], s * ri % n), _times(_g, (n - e) * ri % n)));
    if (q == null) return null;
    return addressOf([..._bytes(q.$1), ..._bytes(q.$2)]);
  }

  /// The address of a public key's 64 bytes (x then y): its Keccak-256's last 20, in lower-case hex.
  static String addressOf(List<int> xy) => '0x${keccak256(xy).sublist(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  /// The address of the private key [scalar] (32 bytes): for the tests.
  static String addressOfScalar(List<int> scalar) {
    final at = _affine(_times(_g, _int(scalar)))!;
    return addressOf([..._bytes(at.$1), ..._bytes(at.$2)]);
  }

  /// A personal_sign signature over [message] with [scalar], using [nonce] (32 bytes, never used twice with one key):
  /// for the tests, which need someone to write as.
  static List<int> sign(List<int> scalar, List<int> message, List<int> nonce) {
    final d = _int(scalar);
    final k = _int(nonce) % n;
    final big = _affine(_times(_g, k))!;
    final r = big.$1 % n;
    var s = k.modInverse(n) * (_int(personalHash(message)) % n + r * d) % n;
    var v = big.$2.isOdd ? 1 : 0;
    if (s > n >> 1) {
      s = n - s;
      v ^= 1;
    }
    return [..._bytes(r), ..._bytes(s), 27 + v];
  }
}
