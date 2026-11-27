import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'hub_link.dart';

/// [dialHub] in a browser: the browser's own WebSocket, given ten seconds to open as hub_link_io.dart's is. A page
/// can send no pings of its own, so there is no interval to set: the browser answers the hub's (relay/lib/hub.dart
/// pings every 30 seconds), and the link is done when the browser says the connection closed.
Future<HubLink> dialHub(String url) async {
  final link = _BrowserLink(web.WebSocket(url));
  try {
    await link._opened.future.timeout(const Duration(seconds: 10));
  } catch (_) {
    link._ws.close();
    rethrow;
  }
  return link;
}

/// [dialProblem] in a browser: the error's own words. A browser tells a page next to nothing of why a WebSocket
/// didn't open.
String dialProblem(Object error) => '$error';

/// A WebSocket that closed before it opened.
class _NeverOpened implements Exception {
  @override
  String toString() => 'the browser could not open a connection there';
}

/// [HubLink] over the browser's own WebSocket.
class _BrowserLink implements HubLink, HubLinkEnd {
  _BrowserLink(this._ws) {
    // Frames as array buffers, not blobs: read at once, as dart:io hands them over.
    _ws.binaryType = 'arraybuffer';
    _ws.onopen = ((web.Event _) {
      if (!_opened.isCompleted) _opened.complete();
    }).toJS;
    _ws.onmessage = ((web.MessageEvent e) {
      final data = e.data;
      if (data.isA<JSString>()) {
        _said.add((data as JSString).toDart);
      } else if (data.isA<JSArrayBuffer>()) {
        _said.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    // However it ends (an error is always followed by this), and whether or not it ever opened.
    _ws.onclose = ((web.CloseEvent e) {
      closeCode = e.code;
      if (!_opened.isCompleted) _opened.completeError(_NeverOpened());
      if (!_closed.isCompleted) _closed.complete();
      _said.close();
    }).toJS;
  }

  final web.WebSocket _ws;
  final _opened = Completer<void>();
  final _closed = Completer<void>();
  final _said = StreamController<Object>();

  @override
  int? closeCode;

  @override
  Stream<Object> get said => _said.stream;

  @override
  void say(Object message) => _ws.send(message is String ? message.toJS : (message is Uint8List ? message : Uint8List.fromList(message as List<int>)).toJS);

  @override
  Future<void> close() {
    _ws.close();
    return _closed.future;
  }
}
