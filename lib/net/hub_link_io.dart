import 'dart:io';
import 'dart:typed_data';

import 'hub_link.dart';

/// [dialHub] where there is dart:io (a phone, a computer, the tests): its WebSocket, given ten seconds to connect and
/// pinged every 25 once it has, so one that died without saying so is found out.
Future<HubLink> dialHub(String url) async {
  // No compression: what a hub sends is held whole before its length is looked at, and sealed packets don't shrink.
  final ws = await WebSocket.connect(url, compression: CompressionOptions.compressionOff).timeout(const Duration(seconds: 10));
  ws.pingInterval = const Duration(seconds: 25);
  return _WebSocketLink(ws);
}

/// [dialProblem] here: a socket's or a WebSocket's own message, without the address and the numbers put around it.
String dialProblem(Object error) => error is SocketException ? error.message.isEmpty ? '$error' : error.message : error is WebSocketException ? error.message : '$error';

/// [HubLink] over dart:io's WebSocket.
class _WebSocketLink implements HubLink, HubLinkEnd {
  _WebSocketLink(this._ws);
  final WebSocket _ws;

  @override
  int? get closeCode => _ws.closeCode;

  @override
  late final Stream<Object> said = _ws.map<Object>((data) => data is String || data is Uint8List ? data as Object : Uint8List.fromList(data as List<int>));

  @override
  void say(Object message) => _ws.add(message);

  @override
  Future<void> close() => _ws.close();
}
