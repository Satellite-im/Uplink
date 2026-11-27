import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_relay/fed_dial.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha1.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:ghost_relay/ws_door.dart';
import 'package:test/test.dart';

import 'fed_support.dart' show withoutClock;

/// A ceiling on a message's length in front of the WebSocket parser, at every door (lib/ws_door.dart; found in the
/// review of relays that talk, 2026-11-22): Dart holds a whole message before anything can look at its length, so a
/// frame that says it is a terabyte long, or a message in endless pieces, was read until the relay had nothing left.
/// Here the doors are real ones on this machine, spoken to byte by byte over plain sockets.

/// A frame as a client sends one: masked (with a mask of nothing, which leaves the bytes as they are), [op] its kind,
/// [fin] whether it ends its message. [say] is the length its header claims, where that is not the truth.
List<int> frame(int op, List<int> payload, {bool fin = true, bool mask = true, int? say}) {
  final len = say ?? payload.length;
  return [
    (fin ? 0x80 : 0) | op,
    if (len < 126) (mask ? 0x80 : 0) | len else if (len < 65536) ...[(mask ? 0x80 : 0) | 126, len >> 8, len & 0xff] else ...[(mask ? 0x80 : 0) | 127, for (var i = 7; i >= 0; i--) (len >> (8 * i)) & 0xff],
    if (mask) ...[0, 0, 0, 0],
    ...payload,
  ];
}

/// A raw connection to a door of [port] at [path], upgraded by hand with RFC 6455's own example key: the answer's head,
/// and the socket, whose every byte that comes after is in [heard].
class Raw {
  Raw._(this.socket, this.head);
  final Socket socket;
  final String head;
  final heard = BytesBuilder();
  final closed = Completer<void>();

  static Future<Raw> open(int port, String path, {String key = 'dGhlIHNhbXBsZSBub25jZQ==', String extra = ''}) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final got = BytesBuilder();
    final head = Completer<String>();
    Raw? raw;
    s.listen((d) {
      if (raw != null) return raw.heard.add(d);
      got.add(d);
      final text = latin1.decode(got.toBytes());
      final end = text.indexOf('\r\n\r\n');
      if (end >= 0 && !head.isCompleted) {
        head.complete(text.substring(0, end));
        final after = got.toBytes().sublist(end + 4);
        got.clear();
        got.add(after);
      }
    }, onDone: () {
      if (!head.isCompleted) head.complete('');
      if (!(raw?.closed.isCompleted ?? true)) raw!.closed.complete();
    }, onError: (_) {});
    s.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n$extra\r\n');
    await s.flush();
    raw = Raw._(s, await head.future.timeout(const Duration(seconds: 10)));
    raw.heard.add(got.takeBytes());
    return raw;
  }

  /// Sends [bytes]; false where the door had closed already.
  Future<bool> send(List<int> bytes) async {
    if (closed.isCompleted) return false;
    try {
      socket.add(bytes);
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether the door closes the connection within [within].
  Future<bool> closes({Duration within = const Duration(seconds: 5)}) async {
    try {
      await closed.future.timeout(within);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// The text messages the door sent, as maps, read from [heard] (unmasked frames, each whole).
  List<Map> said() {
    final b = heard.toBytes();
    final out = <Map>[];
    var i = 0;
    while (i + 2 <= b.length) {
      var len = b[i + 1] & 0x7f, at = i + 2;
      if (len == 126) {
        len = (b[at] << 8) | b[at + 1];
        at += 2;
      } else if (len == 127) {
        len = 0;
        for (var k = 0; k < 8; k++) {
          len = (len << 8) | b[at + k];
        }
        at += 8;
      }
      if (at + len > b.length) break;
      if (b[i] & 0x0f == 1) out.add(jsonDecode(utf8.decode(b.sublist(at, at + len))) as Map);
      i = at + len;
    }
    return out;
  }

  void destroy() => socket.destroy();
}

/// A hello to the hub, signed as an app signs one, for the number in the hub's own hello.
String helloFor(Map hubHello, List<int> scalar) {
  final key = P256.publicOf(scalar);
  final nonce = [for (var i = 0; i < 64; i += 2) int.parse((hubHello['hello'] as String).substring(i, i + 2), radix: 16)];
  final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], List.filled(32, 9));
  return jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig)});
}

void main() {
  String hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  group('the handshake', () {
    test('SHA-1 is the standard\'s, for its examples', () {
      expect(hex(sha1([])), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(hex(sha1(utf8.encode('abc'))), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(hex(sha1(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))), '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
      expect(hex(sha1(List.filled(1000000, 0x61))), '34aa973cd4c4daa4f61eeb2bdbad27316534016f');
      // Lengths around a block's edge, where the padding goes into a second block.
      for (final n in [55, 56, 63, 64, 65]) {
        expect(sha1(List.filled(n, 7)), hasLength(20), reason: '$n');
      }
      expect(hex(sha1(List.filled(56, 0x61))), 'c2db330f6083854c99d4b5bfb6e8f29f201be699');
    });

    test('the accept for a key is RFC 6455\'s own example', () {
      expect(acceptOf('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
    });
  });

  group('the guard, byte by byte', () {
    test('a frame that says it is a terabyte long is refused at its header, before anything it says it carries', () {
      final g = FrameGuard(most: 1 << 20);
      final header = frame(2, const [], say: 1 << 40);
      expect(header, hasLength(14));
      // The first byte of its length that puts it past the ceiling is enough.
      var refusedAt = -1;
      for (var i = 0; i < header.length; i++) {
        if (!g.take([header[i]])) {
          refusedAt = i;
          break;
        }
      }
      expect(refusedAt, inInclusiveRange(2, 9), reason: 'within the eight bytes of its length');
      expect(g.why, 'a message longer than this door takes');
      expect(g.take([0]), isFalse, reason: 'and no from then on');
    });

    test('a message in many pieces is held to the ceiling all together', () {
      final g = FrameGuard(most: 1000, first: 1000);
      expect(g.take(frame(1, List.filled(300, 0x61), fin: false)), isTrue);
      expect(g.take(frame(0, List.filled(300, 0x61), fin: false)), isTrue);
      expect(g.take(frame(0, List.filled(300, 0x61), fin: false)), isTrue);
      expect(g.take(frame(0, const [], say: 101, fin: false).sublist(0, 2)), isFalse, reason: '1,001 bytes, refused at the piece\'s header');
      // Exactly the ceiling, in pieces, is taken; and the next message starts again from nothing.
      final h = FrameGuard(most: 1000, first: 1000);
      expect(h.take([...frame(1, List.filled(500, 1), fin: false), ...frame(0, List.filled(500, 1))]), isTrue);
      expect(h.take(frame(2, List.filled(1000, 1))), isTrue);
    });

    test('the first message has a ceiling of its own: a hello is small', () {
      final g = FrameGuard(most: 100000, first: 100);
      expect(g.take(frame(1, List.filled(101, 0x61))), isFalse);
      final h = FrameGuard(most: 100000, first: 100);
      expect(h.take(frame(1, List.filled(100, 0x61))), isTrue);
      expect(h.take(frame(2, List.filled(50000, 0x61))), isTrue, reason: 'after it, the door\'s own');
    });

    test('control frames: whole, and no longer than 125 bytes; between the pieces of a message they are not counted in it', () {
      final g = FrameGuard(most: 1000, first: 1000);
      expect(g.take([...frame(1, List.filled(600, 1), fin: false), ...frame(9, List.filled(125, 2)), ...frame(10, const []), ...frame(0, List.filled(400, 1))]), isTrue);
      expect(FrameGuard(most: 1000).take(frame(9, List.filled(126, 2))), isFalse, reason: 'a ping of 126 bytes');
      expect(FrameGuard(most: 1000).take(frame(9, const [], fin: false)), isFalse, reason: 'a ping in pieces');
      expect(FrameGuard(most: 1000).take(frame(8, const [], say: 70000).sublist(0, 2)), isFalse, reason: 'a close that says it is long');
    });

    test('what no WebSocket sends: a piece of no message, a message inside a message, bits for an extension, a kind there is none of, too many pieces', () {
      expect(FrameGuard(most: 1000).take(frame(0, [1])), isFalse);
      expect(FrameGuard(most: 1000).take([...frame(1, [1], fin: false), ...frame(2, [1])]), isFalse);
      expect(FrameGuard(most: 1000).take([0xc1, 0x80, 0, 0, 0, 0]), isFalse, reason: 'compressed, which no door agreed to');
      expect(FrameGuard(most: 1000).take(frame(3, [1])), isFalse);
      expect(FrameGuard(most: 1000).take(frame(11, [1])), isFalse);
      final g = FrameGuard(most: 100000, framesAMessage: 10);
      expect(g.take([...frame(1, [1], fin: false), for (var i = 0; i < 8; i++) ...frame(0, [1], fin: false), ...frame(0, [1])]), isTrue, reason: 'ten pieces');
      expect(g.take([...frame(1, [1], fin: false), for (var i = 0; i < 10; i++) ...frame(0, [1], fin: false)]), isFalse, reason: 'eleven');
    });

    test('a ping or pong with something in it, between the pieces of a message, is handed on after its last piece; an empty one, or a Close, at once', () {
      final message = [...frame(1, utf8.encode('hello '), fin: false), ...frame(9, utf8.encode('p')), ...frame(0, utf8.encode('wor'), fin: false), ...frame(10, const []), ...frame(10, utf8.encode('q')), ...frame(0, utf8.encode('ld'))];
      final expected = [...frame(1, utf8.encode('hello '), fin: false), ...frame(0, utf8.encode('wor'), fin: false), ...frame(10, const []), ...frame(0, utf8.encode('ld')), ...frame(9, utf8.encode('p')), ...frame(10, utf8.encode('q'))];
      expect(FrameGuard(most: 1000).pass(message), expected);
      final g = FrameGuard(most: 1000);
      final out = <int>[];
      for (final b in message) {
        out.addAll(g.pass([b])!);
      }
      expect(out, expected);
      // Outside a message, as they came; and more than a message may hold back ends the connection.
      final plain = [...frame(9, const [1]), ...frame(1, utf8.encode('x'))];
      expect(FrameGuard(most: 1000).pass(plain), plain);
      final flood = [...frame(1, const [1], fin: false), for (var i = 0; i <= FrameGuard.laterMost; i++) ...frame(9, const [1])];
      expect(FrameGuard(most: 1000).pass(flood), isNull);
      final empties = [...frame(1, const [1], fin: false), for (var i = 0; i <= FrameGuard.laterMost; i++) ...frame(10, const [])];
      expect(FrameGuard(most: 1000).pass(empties), empties, reason: 'empty pongs (answers to the relay\'s own pings) go through as they came');
      final close = [...frame(1, const [1], fin: false), ...frame(8, const [3, 232])];
      expect(FrameGuard(most: 1000).pass(close), close, reason: 'a Close goes through, to be answered');
    });

    test('a byte at a time is read as all at once, masked or not', () {
      final stream = [...frame(1, utf8.encode('hello'), fin: false), ...frame(9, [1, 2]), ...frame(0, List.filled(300, 3)), ...frame(2, List.filled(70000, 4), mask: false), ...frame(2, const [])];
      final whole = FrameGuard(most: 100000);
      expect(whole.take(stream), isTrue);
      final bytewise = FrameGuard(most: 100000);
      expect(stream.every((b) => bytewise.take([b])), isTrue);
      final small = FrameGuard(most: 69999);
      expect(stream.every((b) => small.take([b])), isFalse, reason: 'and the same ceiling refuses the same frame');
    });
  });

  group('the doors', () {
    late Relay relay;
    late int port;
    late Hub hub;

    setUp(() async {
      hub = Hub();
      relay = Relay(hub: hub);
      port = await relay.start(host: '127.0.0.1', port: 0);
    });
    tearDown(() => relay.stop());

    test('the hub\'s answer to RFC 6455\'s example: 101, its accept, and no extension', () async {
      final raw = await Raw.open(port, '/hub', extra: 'Sec-WebSocket-Extensions: permessage-deflate\r\n');
      final lines = raw.head.split('\r\n');
      expect(lines.first, startsWith('HTTP/1.1 101'));
      final headers = {for (final l in lines.skip(1)) l.substring(0, l.indexOf(':')).toLowerCase(): l.substring(l.indexOf(':') + 1).trim()};
      expect(headers['sec-websocket-accept'], 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
      expect(headers['upgrade']?.toLowerCase(), 'websocket');
      expect(headers['connection']?.toLowerCase(), 'upgrade');
      expect(headers.containsKey('sec-websocket-extensions'), isFalse);
      await pumpEventQueue();
      expect(raw.said().single['hello'], hasLength(64), reason: 'and its hello follows');
      raw.destroy();
    });

    test('a ping between the pieces of a message: the message arrives whole, and the ping is answered after it', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final got = <Object?>[];
      server.listen((r) async {
        final ws = await upgradeGuarded(r, most: 1 << 20, first: 1 << 20);
        ws?.listen((d) => got.add(d), onError: (_) {});
      });
      final raw = await Raw.open(server.port, '/');
      await raw.send([...frame(1, utf8.encode('hello '), fin: false), ...frame(9, utf8.encode('p')), ...frame(0, utf8.encode('world'))]);
      for (var i = 0; i < 200 && (got.isEmpty || raw.heard.length < 3); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(got, ['hello world'], reason: 'Dart\'s own parser alone gives "world", and puts "hello " in the pong');
      expect(raw.heard.toBytes(), [0x8a, 1, ...utf8.encode('p')], reason: 'the pong, with the ping\'s own byte');
      raw.destroy();
    });

    test('a Close between the pieces of a message is answered at once, not held for a message that never ends', () async {
      final raw = await Raw.open(port, '/hub');
      await pumpEventQueue();
      final hello = raw.said().single;
      await raw.send(utf8.encode(''));
      await raw.send([...frame(1, utf8.encode('{"id":'), fin: false), ...frame(8, const [3, 232])]);
      expect(await raw.closes(), isTrue);
      expect(raw.heard.toBytes().sublist(raw.heard.length - 4, raw.heard.length - 2), [0x88, 2], reason: 'its Close answered with a Close (Dart says which number)');
      expect(hello.containsKey('hello'), isTrue);
    });

    test('a key with a byte past ASCII is refused with a 400, not left hanging (found in the second review, 2026-11-23)', () async {
      final raw = await Raw.open(port, '/hub', key: 'dGhlIHNhbXBsZSBub25jZQ==\u00e9');
      expect(raw.head, startsWith('HTTP/1.1 400'));
      expect(await raw.closes(), isTrue);
      final pairing = await Raw.open(port, '/${'ab' * 16}', key: '\u00e9dGhlIHNhbXBsZSBub25jZQ==');
      expect(pairing.head, startsWith('HTTP/1.1 400'));
    });

    test('the hub: a frame that says it is a terabyte long ends the connection at its header, with nothing more sent', () async {
      final raw = await Raw.open(port, '/hub');
      expect(await raw.send(frame(1, const [], say: 1 << 40)), isTrue);
      expect(await raw.closes(), isTrue, reason: 'Dart\'s own parser would wait for the terabyte');
      expect(hub.connected, 0);
    });

    test('the hub: a message in endless pieces ends the connection as it passes the ceiling, signed in or not', () async {
      // Before the hello the first message is held to 16 KB: pieces up to it are waited on, as any message is, and
      // the piece that passes it ends the connection, with nothing more sent.
      List<int> pieces(int count, int size) => [for (var i = 0; i < count; i++) ...frame(i == 0 ? 1 : 0, List.filled(size, 0x61), fin: false)];
      final under = await Raw.open(port, '/hub');
      expect(await under.send(pieces(4, 4096)), isTrue);
      expect(await under.closes(within: const Duration(milliseconds: 300)), isFalse, reason: 'exactly 16 KB: still a message being sent');
      expect(await under.send(frame(0, const [], say: 1, fin: false)), isTrue);
      expect(await under.closes(), isTrue, reason: 'one byte more is past it');
      // Signed in: the hub's own ceiling, a megabyte.
      final raw = await Raw.open(port, '/hub');
      await pumpEventQueue();
      expect(await raw.send(frame(1, utf8.encode(helloFor(raw.said().first, List.filled(32, 5))))), isTrue);
      for (var i = 0; i < 50 && raw.said().length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(withoutClock(raw.said()[1]), {'ok': true, 'held': 0});
      expect(await raw.send(pieces(16, 65536)), isTrue);
      expect(await raw.closes(within: const Duration(milliseconds: 300)), isFalse, reason: 'a megabyte in pieces, not yet ended: waited on');
      expect(await raw.send(frame(0, const [], say: 1, fin: false)), isTrue);
      expect(await raw.closes(), isTrue, reason: 'Dart\'s own parser would hold every piece until the last came');
    });

    test('the hub: a message in a few pieces, under the ceiling, is read whole as before', () async {
      final raw = await Raw.open(port, '/hub');
      await pumpEventQueue();
      final hello = utf8.encode(helloFor(raw.said().first, List.filled(32, 6)));
      final third = hello.length ~/ 3;
      expect(await raw.send([...frame(1, hello.sublist(0, third), fin: false), ...frame(0, hello.sublist(third, 2 * third), fin: false), ...frame(0, hello.sublist(2 * third))]), isTrue);
      for (var i = 0; i < 50 && raw.said().length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(withoutClock(raw.said()[1]), {'ok': true, 'held': 0});
      expect(hub.connected, 1);
      raw.destroy();
    });

    test('a pairing\'s door: the same, at its own ceiling', () async {
      final raw = await Raw.open(port, '/relay/00112233445566778899aabbccddeeff');
      expect(raw.head.split('\r\n').first, startsWith('HTTP/1.1 101'));
      expect(await raw.send(frame(2, const [], say: 1 << 40)), isTrue);
      expect(await raw.closes(), isTrue);
      // A whole frame of a megabyte, as a pairing sends one, is taken (it is answered, not closed on).
      final ok = await Raw.open(port, '/relay/00112233445566778899aabbccddeeff');
      expect(await ok.send(frame(1, utf8.encode(jsonEncode({'auth': 'ab' * 32, 'role': 'phone'})))), isTrue);
      expect(await ok.send(frame(2, List.filled(Relay.maxFrame, 1))), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(ok.said().map((m) => m.keys.first), containsAll(['ok', 'dropped']), reason: 'joined, and told the frame was dropped with the other end away');
      expect(await ok.closes(within: const Duration(milliseconds: 100)), isFalse);
      ok.destroy();
    });
  });

  group('a connection this relay dials', () {
    /// A hub played by hand at a port of this machine: it answers the handshake as [answer] makes it (the right
    /// accept by default), then says [then].
    Future<(ServerSocket, List<String>)> playHub({String Function(String accept)? answer, List<int> then = const []}) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final asked = <String>[];
      server.listen((s) {
        final got = BytesBuilder();
        var answered = false;
        s.listen((d) {
          if (answered) return;
          got.add(d);
          final text = latin1.decode(got.toBytes());
          if (!text.contains('\r\n\r\n')) return;
          answered = true;
          asked.add(text);
          final key = RegExp(r'Sec-WebSocket-Key: (\S+)', caseSensitive: false).firstMatch(text)!.group(1)!;
          final accept = acceptOf(key);
          s.add(latin1.encode(answer?.call(accept) ?? 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n'));
          s.add(then);
        }, onError: (_) {}, onDone: () => s.destroy());
        // The other end may be gone before what is said here is written: that is the point of some of these.
        s.done.then((_) {}, onError: (_) {});
      });
      return (server, asked);
    }

    Uri at(ServerSocket s) => Uri.parse('ws://relay.invalid:${s.port}/hub');

    test('what it asks: a GET of the hub with the host as named, a key, version 13, and no extension or protocol', () async {
      final (server, asked) = await playHub(then: frame(1, utf8.encode('{"hello":1}'), mask: false));
      final socket = await connectPinned(at(server), InternetAddress.loopbackIPv4);
      expect(await socket.incoming.first, '{"hello":1}');
      final lines = asked.single.split('\r\n');
      expect(lines.first, 'GET /hub HTTP/1.1');
      expect(lines, containsAll(['Host: relay.invalid:${server.port}', 'Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Version: 13']));
      expect(lines.where((l) => l.toLowerCase().startsWith('sec-websocket-extensions') || l.toLowerCase().startsWith('sec-websocket-protocol')), isEmpty);
      expect(base64Decode(lines.firstWhere((l) => l.startsWith('Sec-WebSocket-Key: ')).substring(19)), hasLength(16));
      await socket.close();
      await server.close();
    });

    test('a hub that answers with a frame that says it is a terabyte long: the connection ends at its header', () async {
      final (server, _) = await playHub(then: [0x82, 127, 0, 0, 1, 0, 0, 0, 0, 0]);
      final socket = await connectPinned(at(server), InternetAddress.loopbackIPv4);
      final heard = <Object?>[];
      final done = Completer<void>();
      socket.incoming.listen(heard.add, onDone: done.complete, onError: (_) {});
      await done.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('still open: the terabyte was being waited for'));
      expect([heard, socket.isOpen], [isEmpty, isFalse]);
      await server.close();
    });

    test('and one that sends a message in endless pieces: ended past the ceiling', () async {
      final pieces = [...frame(1, utf8.encode('{"hello":1}'), mask: false), ...frame(2, List.filled(65536, 1), fin: false, mask: false), for (var i = 0; i < 3; i++) ...frame(0, List.filled(65536, 1), fin: false, mask: false)];
      final (server, _) = await playHub(then: pieces);
      final socket = await connectPinned(at(server), InternetAddress.loopbackIPv4);
      final done = Completer<void>();
      socket.incoming.listen((_) {}, onDone: done.complete, onError: (_) {});
      await done.future.timeout(const Duration(seconds: 5), onTimeout: () => fail('still open: the pieces were being held'));
      expect(linkMost, lessThan(4 * 65536));
      await server.close();
    });

    test('an answer that is not the handshake asked for is refused, and nothing is followed', () async {
      final cases = <String, String Function(String)>{
        'another accept': (a) => 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${acceptOf('another')}\r\n\r\n',
        'no accept': (a) => 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n',
        'an extension': (a) => 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $a\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n',
        'a protocol': (a) => 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $a\r\nSec-WebSocket-Protocol: chat\r\n\r\n',
        'not upgraded': (a) => 'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $a\r\n\r\n',
        'a redirect': (a) => 'HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/hub\r\n\r\n',
        'a page': (a) => 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi',
        'HTTP/1.0': (a) => 'HTTP/1.0 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $a\r\n\r\n',
        'a head that never ends': (a) => 'HTTP/1.1 101 Switching Protocols\r\nX: ${'y' * 9000}',
      };
      for (final e in cases.entries) {
        final (server, asked) = await playHub(answer: e.value);
        await expectLater(connectPinned(at(server), InternetAddress.loopbackIPv4, timeout: const Duration(seconds: 3)), throwsA(anything), reason: e.key);
        expect(asked, hasLength(1), reason: '${e.key}: asked once, and nothing followed');
        await server.close();
      }
      // One that closes before answering, and one that never answers at all.
      final quiet = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      quiet.listen((s) => s.listen((_) {}, onError: (_) {}));
      await expectLater(connectPinned(at(quiet), InternetAddress.loopbackIPv4, timeout: const Duration(milliseconds: 300)), throwsA(isA<TimeoutException>()));
      await quiet.close();
    });

    test('and it still takes a real hub\'s answer, and the hub\'s hello after it', () async {
      final hub = Hub();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(hub.accept);
      final socket = await connectPinned(Uri.parse('ws://relay.invalid:${server.port}/hub'), InternetAddress.loopbackIPv4);
      final hello = jsonDecode(await socket.incoming.first as String) as Map;
      expect(hello['hello'], matches(RegExp(r'^[0-9a-f]{64}$')));
      await socket.close();
      hub.stop();
      await server.close(force: true);
    });
  });

  group('wss', () {
    late Directory dir;
    var openssl = true;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('ghost-wss-');
      // A CA of the test's own and a certificate it signed for relay.test, made with openssl where it is there.
      Future<bool> run(List<String> args) async {
        try {
          return (await Process.run('openssl', args, workingDirectory: dir.path)).exitCode == 0;
        } catch (_) {
          return false;
        }
      }

      File('${dir.path}/ext.cnf').writeAsStringSync('subjectAltName=DNS:relay.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n');
      openssl = await run(['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'ca.key']) &&
          await run(['req', '-x509', '-new', '-sha256', '-key', 'ca.key', '-days', '3650', '-subj', '/CN=Uplink test CA', '-out', 'ca.pem', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign']) &&
          await run(['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'leaf.key']) &&
          await run(['req', '-new', '-sha256', '-key', 'leaf.key', '-subj', '/CN=relay.test', '-out', 'leaf.csr']) &&
          // (SHA-256, and a year: a certificate signed with SHA-1, or for a server and good for longer, is refused where
          // the system checks it, as on a Mac.)
          await run(['x509', '-req', '-sha256', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-days', '365', '-extfile', 'ext.cnf', '-out', 'leaf.pem']);
    });
    tearDownAll(() => dir.deleteSync(recursive: true));

    test('to the address checked, with the certificate checked against the name dialled', () async {
      if (!openssl) return markTestSkipped('no openssl on this machine to make a certificate with');
      final hub = Hub();
      final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, SecurityContext()
        ..useCertificateChain('${dir.path}/leaf.pem')
        ..usePrivateKey('${dir.path}/leaf.key'));
      final asked = <String>[];
      server.listen((r) {
        asked.add(r.uri.path);
        hub.accept(r);
      });
      final trusting = SecurityContext(withTrustedRoots: false)..setTrustedCertificates('${dir.path}/ca.pem');
      // Nobody this machine trusts vouches for it: refused before a request is made.
      await expectLater(connectPinned(Uri.parse('wss://relay.test:${server.port}/hub'), InternetAddress.loopbackIPv4), throwsA(isA<HandshakeException>()));
      expect(asked, isEmpty);
      // Vouched for, and for the name dialled: the hub's hello.
      final socket = await connectPinned(Uri.parse('wss://relay.test:${server.port}/hub'), InternetAddress.loopbackIPv4, context: trusting);
      expect((jsonDecode(await socket.incoming.first as String) as Map)['hello'], hasLength(64));
      await socket.close();
      expect(asked, ['/hub']);
      // The same certificate for another name than the one dialled: refused.
      await expectLater(connectPinned(Uri.parse('wss://other.test:${server.port}/hub'), InternetAddress.loopbackIPv4, context: trusting), throwsA(isA<HandshakeException>()));
      expect(asked, ['/hub']);
      hub.stop();
      await server.close(force: true);
    });
  });

  test('the hub\'s and the pairings\' ceilings, and a link\'s, are over the longest each carries', () {
    // A hello is a few hundred bytes; a watch list of 5,000 keys is about 340 KB.
    expect(firstMost, greaterThan(4096));
    expect(Hub.maxMessage, greaterThan(jsonEncode({'dir': 'watch', 'add': List.filled(5000, 'ab' * 32)}).length));
    expect(Relay.maxMessage, greaterThan(Relay.maxFrame));
    expect(linkMost, greaterThan(Hub.maxPacket + 256));
    expect(hexOf(sha256([])), hasLength(64));
  });
}
