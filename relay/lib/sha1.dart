import 'dart:typed_data';

/// SHA-1 (FIPS 180-4), written out so the relay has no dependency. It is here for one thing, which is no use of SHA-1
/// for safety: a WebSocket's handshake (RFC 6455, section 4.2.2) answers the key it is asked with by the SHA-1 of it,
/// and the relay makes that answer itself now (ws_door.dart). Held to the standard's examples and RFC 6455's own in
/// test/ws_door_test.dart.
Uint8List sha1(List<int> message) {
  const mask = 0xffffffff;
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & mask;

  final length = message.length;
  final padded = Uint8List(((length + 9 + 63) ~/ 64) * 64)..setRange(0, length, message);
  padded[length] = 0x80;
  final bits = length * 8;
  final view = ByteData.sublistView(padded)
    // The length in bits, eight bytes big end first, as two halves (no 64-bit arithmetic is needed for it).
    ..setUint32(padded.length - 8, (bits ~/ 0x100000000) & mask)
    ..setUint32(padded.length - 4, bits & mask);

  var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
  final w = Uint32List(80);
  for (var at = 0; at < padded.length; at += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(at + i * 4);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      final int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & mask) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final t = (rotl(a, 5) + f + e + k + w[i]) & mask;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = t;
    }
    h0 = (h0 + a) & mask;
    h1 = (h1 + b) & mask;
    h2 = (h2 + c) & mask;
    h3 = (h3 + d) & mask;
    h4 = (h4 + e) & mask;
  }
  final out = Uint8List(20);
  ByteData.sublistView(out)
    ..setUint32(0, h0)
    ..setUint32(4, h1)
    ..setUint32(8, h2)
    ..setUint32(12, h3)
    ..setUint32(16, h4);
  return out;
}
