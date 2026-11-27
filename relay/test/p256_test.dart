import 'dart:convert';

import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

List<int> unhex(String text) => [for (var i = 0; i + 1 < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)];

void main() {
  // RFC 6979, A.2.5: P-256 with SHA-256, the message "sample".
  final scalar = unhex('c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721');
  const x = '60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6';
  final k = unhex('a6e3c57dd01abe90086538398355dd4c3b17aa873382b0f24d6129493d8aad60');
  const r = 'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716';
  const s = 'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8';

  test('the public key of a private key, as the apps send it', () {
    // y of this key is odd (…a903 7c29 ends 9299 → 03).
    expect(hexOf(P256.publicOf(scalar)), '03$x');
    expect(P256.isKey(P256.publicOf(scalar)), isTrue);
  });

  test('a signature is the one the standard gives, and is taken', () {
    final sig = P256.sign(scalar, utf8.encode('sample'), k);
    expect(hexOf(sig), '$r$s');
    expect(P256.verify(P256.publicOf(scalar), utf8.encode('sample'), sig), isTrue);
  });

  test('a signature over other words, by another key, or changed, is not', () {
    final key = P256.publicOf(scalar);
    final sig = P256.sign(scalar, utf8.encode('sample'), k);
    expect(P256.verify(key, utf8.encode('simple'), sig), isFalse);
    expect(P256.verify(P256.publicOf(unhex('11' * 32)), utf8.encode('sample'), sig), isFalse);
    expect(P256.verify(key, utf8.encode('sample'), [...sig.sublist(0, 63), sig[63] ^ 1]), isFalse);
    expect(P256.verify(key, utf8.encode('sample'), List.filled(64, 0)), isFalse);
    expect(P256.verify(key, utf8.encode('sample'), sig.sublist(0, 60)), isFalse);
  });

  test('what is not a key is not taken for one', () {
    expect(P256.isKey([4, ...List.filled(32, 1)]), isFalse);
    expect(P256.isKey(List.filled(32, 2)), isFalse);
    // An x with no point on the curve over it.
    expect(P256.isKey([2, ...List.filled(31, 0), 5]) || P256.isKey([2, ...List.filled(31, 0), 6]) || P256.isKey([2, ...List.filled(31, 0), 7]), isTrue);
    expect([for (var i = 0; i < 16; i++) P256.isKey([2, ...List.filled(31, 0), i])].contains(false), isTrue);
  });
}
