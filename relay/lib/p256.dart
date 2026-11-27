import 'sha256.dart';

/// P-256 (secp256r1) signatures with Dart's own BigInt and nothing else, for the hub (hub.dart): it checks that
/// whoever connects under a name holds the private key that name was made from. The apps sign with their own
/// libraries (Android's keystore classes on the phone, pointycastle in Dart); this only has to agree with them, and
/// test/p256_test.dart holds it to that.
///
/// A public key is 33 bytes, as the apps send them: 02 or 03 for y's parity, then x. A signature is 64 bytes: r,
/// then s. Not constant-time: it handles nothing secret but in [sign], which the tests use and, since relays talk to
/// each other, the relay's own key (federation.dart: one signature for each link made, and links are counted).
class P256 {
  /// The curve: the field's prime [p], the group's order [n], b of y² = x³ − 3x + b, and the base point.
  static final BigInt p = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
  static final BigInt n = BigInt.parse('ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551', radix: 16);
  static final BigInt _b = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);
  static final BigInt _gx = BigInt.parse('6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296', radix: 16);
  static final BigInt _gy = BigInt.parse('4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5', radix: 16);
  static final BigInt _three = BigInt.from(3);

  // Big-endian bytes as a number, and a number as 32 big-endian bytes.
  static BigInt _int(List<int> bytes) => bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b & 0xff));

  static List<int> _bytes(BigInt v) => [for (var i = 31; i >= 0; i--) ((v >> (8 * i)) & BigInt.from(0xff)).toInt()];

  // A point as (X, Y, Z) with x = X/Z², y = Y/Z³; Z of nothing is the point at infinity.
  static List<BigInt> _double(List<BigInt> a) {
    final x = a[0], y = a[1], z = a[2];
    if (z == BigInt.zero || y == BigInt.zero) return [BigInt.one, BigInt.one, BigInt.zero];
    final delta = z * z % p;
    final gamma = y * y % p;
    final beta = x * gamma % p;
    final alpha = _three * (x - delta) * (x + delta) % p;
    final x3 = (alpha * alpha - BigInt.from(8) * beta) % p;
    final z3 = ((y + z) * (y + z) - gamma - delta) % p;
    final y3 = (alpha * (BigInt.from(4) * beta - x3) - BigInt.from(8) * gamma * gamma) % p;
    return [x3, y3, z3];
  }

  // The sum of two points; the same point twice is doubled, a point and its opposite is the point at infinity.
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

  // [point] added to itself [k] times, by doubling and adding from k's highest bit down.
  static List<BigInt> _times(List<BigInt> point, BigInt k) {
    var out = [BigInt.one, BigInt.one, BigInt.zero];
    for (var i = k.bitLength - 1; i >= 0; i--) {
      out = _double(out);
      if ((k >> i) & BigInt.one == BigInt.one) out = _add(out, point);
    }
    return out;
  }

  /// The point's own x and y, or null for the point at infinity.
  static (BigInt, BigInt)? _affine(List<BigInt> a) {
    if (a[2] == BigInt.zero) return null;
    final zi = a[2].modInverse(p);
    final zi2 = zi * zi % p;
    return (a[0] * zi2 % p, a[1] * zi2 * zi % p);
  }

  /// The point those 33 bytes name, or null when they are not one on the curve.
  static List<BigInt>? _point(List<int> key) {
    if (key.length != 33 || (key[0] != 2 && key[0] != 3)) return null;
    final x = _int(key.sublist(1));
    if (x >= p) return null;
    final rhs = (x * x * x - _three * x + _b) % p;
    // p is 3 mod 4, so a square root is rhs^((p+1)/4).
    var y = rhs.modPow((p + BigInt.one) >> 2, p);
    if (y * y % p != rhs) return null;
    if (y.isOdd != (key[0] == 3)) y = p - y;
    return [x, y, BigInt.one];
  }

  /// Whether [key] is a public key: 33 bytes naming a point on the curve.
  static bool isKey(List<int> key) => _point(key) != null;

  /// Whether [signature] (r then s, 64 bytes) is the holder of [key]'s over [message] (hashed here with SHA-256).
  static bool verify(List<int> key, List<int> message, List<int> signature) {
    final q = _point(key);
    if (q == null || signature.length != 64) return false;
    final r = _int(signature.sublist(0, 32));
    final s = _int(signature.sublist(32));
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return false;
    final z = _int(sha256(message));
    final w = s.modInverse(n);
    final at = _affine(_add(_times([_gx, _gy, BigInt.one], z * w % n), _times(q, r * w % n)));
    return at != null && at.$1 % n == r;
  }

  /// The public key of the private key [scalar] (32 bytes): for the tests, which need someone to connect as.
  static List<int> publicOf(List<int> scalar) {
    final at = _affine(_times([_gx, _gy, BigInt.one], _int(scalar)))!;
    return [at.$2.isOdd ? 3 : 2, ..._bytes(at.$1)];
  }

  /// A signature over [message] with the private key [scalar], using [nonce] (32 bytes, never used twice with one
  /// key) as its secret number: for the tests, and for the relay's own key (federation.dart).
  ///
  /// The secret number is multiplied in as itself plus the curve's order, once or twice, whichever is one bit longer
  /// than the order: the same point, in the same number of steps whatever the number is, so how long a signature takes
  /// does not say how long its secret number was. It is still not constant-time arithmetic.
  static List<int> sign(List<int> scalar, List<int> message, List<int> nonce) {
    final d = _int(scalar);
    final k = _int(nonce) % n;
    if (k == BigInt.zero) throw ArgumentError('a secret number of nothing');
    var steps = k + n;
    if (steps.bitLength <= n.bitLength) steps += n;
    final r = _affine(_times([_gx, _gy, BigInt.one], steps))!.$1 % n;
    final s = k.modInverse(n) * (_int(sha256(message)) + r * d) % n;
    if (r == BigInt.zero || s == BigInt.zero) throw ArgumentError('a secret number that signs nothing');
    return [..._bytes(r), ..._bytes(s)];
  }
}
