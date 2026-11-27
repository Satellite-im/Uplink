import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// No door of the relay takes compressed messages (found in review, 2026-11-22). A WebSocket holds a whole message in
/// memory before anything can look at its length, and a deflated one of a few hundred kilobytes opens out to hundreds
/// of megabytes: more than the relay is allowed, so one message from anyone ended it, with everything it was holding.
/// An app that offers compression is answered without it, and goes on as before.
///
/// What the relay agreed to is read from its own answer to the upgrade (dart:io's WebSocket doesn't say what was
/// agreed), asked for as a browser or an app from before would ask.
Future<({int status, String? extensions})> _upgrade(int port, String path) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl('GET', Uri.parse('http://127.0.0.1:$port$path'));
    request.headers
      ..set('Connection', 'Upgrade')
      ..set('Upgrade', 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', base64Encode(List.filled(16, 7)))
      ..set('Sec-WebSocket-Extensions', 'permessage-deflate; client_max_window_bits');
    final response = await request.close();
    final answer = (status: response.statusCode, extensions: response.headers.value('sec-websocket-extensions'));
    (await response.detachSocket()).destroy();
    return answer;
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Relay relay;
  late int port;

  setUp(() async {
    relay = Relay(hub: Hub());
    port = await relay.start(host: '127.0.0.1', port: 0);
  });

  tearDown(() => relay.stop());

  test('the hub answers an app that offers compression without it', () async {
    final answer = await _upgrade(port, '/hub');
    expect(answer.status, HttpStatus.switchingProtocols);
    expect(answer.extensions, isNull, reason: 'a compressed message is opened out before its length can be looked at');
  });

  test('a pairing\'s channel answers without compression too', () async {
    final answer = await _upgrade(port, '/relay/00112233445566778899aabbccddeeff');
    expect(answer.status, HttpStatus.switchingProtocols);
    expect(answer.extensions, isNull);
  });

  test('and an app that offers it still signs in to the hub as before', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub', compression: CompressionOptions.compressionDefault);
    final hello = jsonDecode(await ws.first as String) as Map;
    expect(hello['hello'], hasLength(64));
    await ws.close();
  });
}
