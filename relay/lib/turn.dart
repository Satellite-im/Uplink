import 'dart:convert';
import 'dart:typed_data';

/// The media relay a call falls back on when two devices can't reach each other directly (Matt, 2026-11-21:
/// "Sometimes calls are not negotiating in voice chats and I can't connect to another person, if p2p fails please
/// connect over voice through the relay").
///
/// A call's sound and picture go device to device (WebRTC, lib/voice/rtc.dart in the app). Where both sit behind
/// routers that won't let a stranger's packets in (a phone on a mobile network, a strict office or hotel network), no
/// direct path exists and the call never connects. A TURN server (coturn, on the box beside this relay) passes the
/// packets between them instead. What it passes is still WebRTC's own encryption (DTLS-SRTP), keyed between the two
/// devices: it can't hear or see the call.
///
/// The TURN server and this hub share one secret (`GHOST_TURN_SECRET`, coturn's `static-auth-secret`), and the hub
/// hands whoever joins a room a username and password made from it that work for [ttl] and then stop: coturn's
/// "REST API" credentials (username `<expiry>:<id>`, password the base64 HMAC-SHA1 of the username under the secret).
/// Only a device that joined a room is given them, and nothing about the room goes into them. Without the secret
/// nothing is handed out and calls are direct only, as before.
class TurnConfig {
  const TurnConfig({this.secret = '', this.urls = const [], this.ttl = const Duration(hours: 24)});

  /// coturn's static-auth-secret; empty: no relay for calls.
  final String secret;

  /// Where the TURN server is, as WebRTC names it: `turn:gogho.st:3478?transport=udp`, `turns:gogho.st:5349?transport=tcp`.
  final List<String> urls;

  /// How long a username and password work for: a call already connected through the relay keeps going past it only
  /// until the server asks it to sign in again, so a day.
  final Duration ttl;

  /// Whether a media relay is handed out at all: there is a secret, and an address for it.
  bool get on => secret.isNotEmpty && urls.isNotEmpty;

  /// `GHOST_TURN_SECRET`, `GHOST_TURN_URLS` (comma-separated) and `GHOST_TURN_TTL` (seconds), from the relay's
  /// environment file (tool/deploy-relay.mjs --env).
  factory TurnConfig.fromEnvironment(Map<String, String> env) {
    final ttl = int.tryParse((env['GHOST_TURN_TTL'] ?? '').trim());
    return TurnConfig(
      secret: (env['GHOST_TURN_SECRET'] ?? '').trim(),
      urls: [for (final u in (env['GHOST_TURN_URLS'] ?? '').split(',')) if (u.trim().isNotEmpty) u.trim()],
      ttl: ttl != null && ttl > 60 ? Duration(seconds: ttl) : const Duration(hours: 24),
    );
  }

  /// The TURN server as an RTCIceServer entry for [id] (an install's id), good until [now] plus [ttl]; null when off.
  Map<String, Object>? serverFor(String id, DateTime now) {
    if (!on) return null;
    final expiry = now.add(ttl).millisecondsSinceEpoch ~/ 1000;
    // coturn takes the part before the colon as the expiry and the rest as a name it only logs: a short one.
    final user = '$expiry:${id.length > 16 ? id.substring(0, 16) : id}';
    return {'urls': urls, 'username': user, 'credential': base64Encode(hmacSha1(utf8.encode(secret), utf8.encode(user)))};
  }
}

/// HMAC (RFC 2104) over SHA-1, which coturn's REST credentials are made with.
Uint8List hmacSha1(List<int> key, List<int> message) {
  const block = 64;
  // A key longer than a block is hashed first; then it is padded with zeros to a block, and XORed with 0x36 for the
  // inner hash and 0x5c for the outer.
  var k = key.length > block ? sha1(key) : Uint8List.fromList(key);
  final padded = Uint8List(block)..setRange(0, k.length, k);
  final inner = Uint8List(block), outer = Uint8List(block);
  for (var i = 0; i < block; i++) {
    inner[i] = padded[i] ^ 0x36;
    outer[i] = padded[i] ^ 0x5c;
  }
  return sha1([...outer, ...sha1([...inner, ...message])]);
}

/// SHA-1 (FIPS 180-4). The relay uses Dart's own library and nothing fetched (pubspec.yaml), and dart:io keeps its
/// own SHA-1 to itself. Used here only inside an HMAC, where SHA-1's collisions don't matter.
Uint8List sha1(List<int> data) {
  final bitLen = data.length * 8;
  final padLen = ((data.length + 8) ~/ 64 + 1) * 64;
  final msg = Uint8List(padLen)..setRange(0, data.length, data);
  msg[data.length] = 0x80;
  final bd = ByteData.sublistView(msg);
  bd.setUint32(padLen - 8, (bitLen ~/ 0x100000000) & 0xffffffff);
  bd.setUint32(padLen - 4, bitLen & 0xffffffff);
  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
  final w = List<int>.filled(80, 0);
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;
  for (var off = 0; off < padLen; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(off + i * 4);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final t = (rotl(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = t;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  final out = ByteData(20);
  for (final (i, h) in [h0, h1, h2, h3, h4].indexed) {
    out.setUint32(i * 4, h);
  }
  return out.buffer.asUint8List();
}
