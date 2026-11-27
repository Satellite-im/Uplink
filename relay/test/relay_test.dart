import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// One end of a channel: what the relay said to it (text) and what the other end sent it (bytes), in order.
class End {
  End(this.ws) {
    ws.listen((d) => d is String ? said.add(jsonDecode(d) as Map) : frames.add(d as List<int>), onDone: () => closed.complete(ws.closeCode));
  }
  final WebSocket ws;
  final said = <Map>[];
  final frames = <List<int>>[];
  final closed = Completer<int?>();

  static Future<End> join(int port, String channel, String token, String role, {bool temp = false, String prefix = ''}) async {
    final end = End(await WebSocket.connect('ws://127.0.0.1:$port$prefix/$channel'));
    end.ws.add(jsonEncode({'auth': token, 'role': role, if (temp) 'temp': true}));
    return end;
  }

  Future<void> until(bool Function() test) async {
    for (var i = 0; i < 400 && !test(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(test(), isTrue, reason: 'said: $said, frames: ${frames.length}');
  }
}

const channel = '00112233445566778899aabbccddeeff';
final token = 'a' * 64;

void main() {
  test('SHA-256 is the standard\'s', () {
    expect(hexOf(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(hexOf(sha256(const [])), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(hexOf(sha256(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))), '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    // A message longer than one block, and one whose padding spills into another.
    expect(hexOf(sha256(List.filled(1000, 0x61))), '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    expect(hexOf(sha256(List.filled(56, 0x61))), 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a');
  });

  group('the relay', () {
    late Relay relay;
    late int port;
    setUp(() async {
      relay = Relay();
      port = await relay.start(port: 0);
    });
    tearDown(() => relay.stop());

    test('passes frames between a phone and a computer, and says when the other comes and goes', () async {
      final phone = await End.join(port, channel, token, 'phone');
      await phone.until(() => phone.said.isNotEmpty);
      expect(phone.said.first, {'ok': true, 'peer': false});
      // Nobody there yet: the frame is dropped, and the phone is told.
      phone.ws.add([1, 2, 3]);
      await phone.until(() => phone.said.length == 2);
      expect(phone.said[1], {'dropped': true});

      final mac = await End.join(port, channel, token, 'desk', prefix: '/relay');
      await mac.until(() => mac.said.isNotEmpty);
      expect(mac.said.first, {'ok': true, 'peer': true});
      await phone.until(() => phone.said.length == 3);
      expect(phone.said[2], {'peer': true});

      mac.ws.add([9, 8, 7, 6]);
      phone.ws.add(List.filled(300000, 5));
      await phone.until(() => phone.frames.isNotEmpty);
      await mac.until(() => mac.frames.isNotEmpty);
      expect(phone.frames.single, [9, 8, 7, 6]);
      expect(mac.frames.single.length, 300000);
      expect(mac.frames.single.every((b) => b == 5), isTrue);

      await mac.ws.close();
      await phone.until(() => phone.said.length == 4);
      expect(phone.said[3], {'peer': false});
    });

    test('lets in only holders of the channel\'s token', () async {
      final phone = await End.join(port, channel, token, 'phone');
      await phone.until(() => phone.said.isNotEmpty);
      final stranger = await End.join(port, channel, 'b' * 64, 'desk');
      expect(await stranger.closed.future, 4403);
      expect(stranger.said.single, {'ok': false, 'err': 'refused'});
      // Nothing of it reached the phone.
      expect(phone.said.length, 1);
      // Not a token at all, not an end there is, and a first word that is not the token.
      for (final hello in [{'auth': 'short', 'role': 'desk'}, {'auth': token, 'role': 'relay'}, {'hello': 1}]) {
        final ws = End(await WebSocket.connect('ws://127.0.0.1:$port/$channel'));
        ws.ws.add(jsonEncode(hello));
        expect(await ws.closed.future, 4400);
      }
      final bytesFirst = End(await WebSocket.connect('ws://127.0.0.1:$port/$channel'));
      bytesFirst.ws.add([1, 2, 3]);
      expect(await bytesFirst.closed.future, 4400);
      // An address that names no channel is not a WebSocket here.
      await expectLater(WebSocket.connect('ws://127.0.0.1:$port/not-a-channel'), throwsA(anything));
    });

    test('one phone and one computer: a second of the same end takes the first one\'s place', () async {
      final first = await End.join(port, channel, token, 'desk');
      await first.until(() => first.said.isNotEmpty);
      final second = await End.join(port, channel, token, 'desk');
      expect(await first.closed.future, 4409);
      await second.until(() => second.said.isNotEmpty);
      final phone = await End.join(port, channel, token, 'phone');
      await phone.until(() => phone.said.isNotEmpty);
      expect(phone.said.first, {'ok': true, 'peer': true});
      phone.ws.add([4]);
      await second.until(() => second.frames.isNotEmpty);
      expect(first.frames, isEmpty);
    });

    test('unpairing removes the channel', () async {
      final phone = await End.join(port, channel, token, 'phone');
      final mac = await End.join(port, channel, token, 'desk');
      await mac.until(() => mac.said.isNotEmpty);
      expect(relay.channelCount, 1);
      mac.ws.add(jsonEncode({'delete': true}));
      expect(await phone.closed.future, 4410);
      expect(await mac.closed.future, 4410);
      expect(relay.channelCount, 0);
      // The name is free again: whoever comes next sets its token.
      final next = await End.join(port, channel, 'c' * 64, 'phone');
      await next.until(() => next.said.isNotEmpty);
      expect(next.said.first['ok'], true);
    });

    test('answers a ping', () async {
      final phone = await End.join(port, channel, token, 'phone');
      await phone.until(() => phone.said.isNotEmpty);
      phone.ws.add(jsonEncode({'ping': 7}));
      await phone.until(() => phone.said.length == 2);
      expect(phone.said[1], {'pong': 7});
    });

    test('says what it is to a browser', () async {
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port/'))).close();
      expect(response.statusCode, 200);
      expect(await utf8.decodeStream(response), contains('Ghost Messaging relay'));
      client.close();
    });
  });

  test('a channel made for pairing lives ten minutes and is never written; a pairing\'s own is kept, with no token in the file', () async {
    final dir = Directory.systemTemp.createTempSync('ghost-relay-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    var now = DateTime.utc(2026, 11, 13, 12);
    var relay = Relay(dataDir: dir, now: () => now);
    var port = await relay.start(port: 0);
    final pairing = await End.join(port, 'f' * 32, token, 'desk', temp: true);
    final kept = await End.join(port, channel, token, 'desk');
    await pairing.until(() => pairing.said.isNotEmpty);
    await kept.until(() => kept.said.isNotEmpty);
    expect(relay.channelCount, 2);
    now = now.add(const Duration(minutes: 11));
    relay.sweep();
    expect(await pairing.closed.future, 4410);
    expect(relay.channelCount, 1);
    await relay.stop();

    final file = File('${dir.path}/channels.json').readAsStringSync();
    expect(file, contains(channel));
    expect(file, isNot(contains('f' * 32)));
    expect(file, isNot(contains(token)));
    expect(file, contains(hexOf(sha256(utf8.encode(token)))));
    expect((jsonDecode(file) as Map)['channels'][channel].keys, ['h', 'd']);

    // Started again, it knows the pairing, and still refuses another token.
    relay = Relay(dataDir: dir, now: () => now);
    port = await relay.start(port: 0);
    expect(relay.channelCount, 1);
    final wrong = await End.join(port, channel, 'b' * 64, 'phone');
    expect(await wrong.closed.future, 4403);
    final right = await End.join(port, channel, token, 'phone');
    await right.until(() => right.said.isNotEmpty);
    expect(right.said.first['ok'], true);
    await right.ws.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Ninety days with nobody on it, and it is gone.
    now = now.add(const Duration(days: 91));
    relay.sweep();
    expect(relay.channelCount, 0);
    await relay.stop();
    expect(File('${dir.path}/channels.json').readAsStringSync(), isNot(contains(channel)));
  });
}
