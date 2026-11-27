import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/turn.dart';
import 'package:test/test.dart';

/// The media relay calls fall back on (turn.dart; Matt, 2026-11-21: "if p2p fails please connect over voice through the
/// relay"): coturn's REST credentials, handed out with a room joined.

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
final _rnd = Random(11);
List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// Signs in to [url]; the room answer for [room].
Future<Map> _joinAnswer(String url, String room) async {
  final scalar = _bytes(32);
  final key = P256.publicOf(scalar);
  final id = Hub.nameOf(key);
  final ws = await WebSocket.connect(url);
  final said = StreamController<Map>();
  ws.listen((d) {
    if (d is String) said.add(jsonDecode(d) as Map);
  });
  final q = StreamIterator(said.stream);
  await q.moveNext();
  final nonce = _unhex(q.current['hello'] as String);
  ws.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], _bytes(32)))}));
  await q.moveNext();
  ws.add(jsonEncode({'join': room, 'token': 'ef' * 32}));
  while (await q.moveNext().timeout(const Duration(seconds: 5))) {
    if (q.current['room'] == room && q.current.containsKey('ok')) break;
  }
  await ws.close();
  return q.current;
}

void main() {
  test('SHA-1 and HMAC-SHA1 match the published vectors', () {
    expect(_hex(sha1(utf8.encode('abc'))), 'a9993e364706816aba3e25717850c26c9cd0d89d');
    expect(_hex(sha1(const [])), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    expect(_hex(sha1(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))), '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
    expect(_hex(sha1(List.filled(1000000, 0x61))), '34aa973cd4c4daa4f61eeb2bdbad27316534016f');
    // RFC 2202, cases 1 and 6 (a key longer than a block).
    expect(_hex(hmacSha1(List.filled(20, 0x0b), utf8.encode('Hi There'))), 'b617318655057264e28bc0b6fb378c8ef146be00');
    expect(_hex(hmacSha1(List.filled(80, 0xaa), utf8.encode('Test Using Larger Than Block-Size Key - Hash Key First'))), 'aa4ae5e15272d00e95705637ce8a3b55ed402112');
  });

  test("a username and password as coturn's use-auth-secret checks them, good for the time set", () {
    const c = TurnConfig(secret: 'north-wind', urls: ['turn:gogho.st:3478?transport=udp'], ttl: Duration(hours: 2));
    final now = DateTime.utc(2026, 11, 21, 12);
    final s = c.serverFor('0123456789abcdef0123', now)!;
    final user = s['username'] as String;
    expect(user, '${now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000}:0123456789abcdef');
    expect(s['credential'], base64Encode(hmacSha1(utf8.encode('north-wind'), utf8.encode(user))));
    expect(s['urls'], ['turn:gogho.st:3478?transport=udp']);
  });

  test('read from the environment; without a secret or an address it is off', () {
    final c = TurnConfig.fromEnvironment({'GHOST_TURN_SECRET': ' s ', 'GHOST_TURN_URLS': 'turn:a:3478?transport=udp, turns:a:5349?transport=tcp', 'GHOST_TURN_TTL': '600'});
    expect(c.on, isTrue);
    expect(c.urls, ['turn:a:3478?transport=udp', 'turns:a:5349?transport=tcp']);
    expect(c.ttl, const Duration(minutes: 10));
    expect(TurnConfig.fromEnvironment({'GHOST_TURN_SECRET': 's'}).on, isFalse);
    expect(TurnConfig.fromEnvironment({}).serverFor('x', DateTime.now()), isNull);
  });

  test('joining a room hands out the relay where it is set, and nothing where it is not', () async {
    for (final turn in [const TurnConfig(secret: 'k', urls: ['turn:127.0.0.1:3478']), const TurnConfig()]) {
      final relay = Relay(hub: Hub(turn: turn));
      final url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
      final answer = await _joinAnswer(url, 'ab' * 16);
      await relay.stop();
      expect(answer['ok'], isTrue);
      if (turn.on) {
        final ice = answer['ice'] as Map;
        expect(ice['urls'], ['turn:127.0.0.1:3478']);
        expect(ice['username'], matches(RegExp(r'^\d+:[0-9a-f]+$')));
        expect(ice['credential'], isA<String>());
      } else {
        expect(answer.containsKey('ice'), isFalse);
      }
    }
  });
}
