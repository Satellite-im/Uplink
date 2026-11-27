import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'session.dart';

/// The Mac's connection to the relay for one channel (relay/README.md says what is said to it). It is dialed out,
/// names its token and that it is the computer, and is then told when the phone is there. Frames for a session ride
/// on it: [transport] gives the session a view of it that ends when the phone leaves, while this stays connected for
/// the phone's return.
class RelaySocket {
  RelaySocket({required this.url, required this.token, this.temp = false, this.onChange});

  /// The relay's address with the channel at its end.
  final String url;

  /// What shows the relay this side may use the channel: made from the pairing's key, or from the QR code's secret.
  final String token;

  /// A channel made for pairing: ten minutes, never written down by the relay.
  final bool temp;

  /// The phone came or went, or this connection opened or closed.
  final void Function()? onChange;

  WebSocket? _ws;

  /// The view the session now running has of this connection; null between sessions.
  _RelayTransport? _transport;

  /// The relay took the token, and the phone is connected to the channel too.
  bool joined = false;
  bool peer = false;
  bool closed = false;

  /// Why the relay would not have this connection, when it said.
  String? refused;

  /// Dials the relay and names the token. Never throws: a relay that is not there leaves this [closed].
  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      final ws = await WebSocket.connect(url, compression: CompressionOptions.compressionOff).timeout(timeout);
      if (closed) {
        ws.close();
        return;
      }
      _ws = ws;
      ws.add(jsonEncode({'auth': token, 'role': 'desk', if (temp) 'temp': true}));
      ws.listen(_onMessage, onDone: _ended, onError: (_) => _ended(), cancelOnError: true);
    } catch (_) {
      _ended();
    }
  }

  /// Bytes are a frame from the phone, for the session. Words are the relay's own: its answer to the token, the
  /// phone coming or going, a frame that reached nobody.
  void _onMessage(dynamic data) {
    if (data is List<int>) {
      _transport?._frames.add(data is Uint8List ? data : Uint8List.fromList(data));
      return;
    }
    Map? said;
    try {
      said = jsonDecode(data as String) as Map;
    } catch (_) {
      return;
    }
    if (said['ok'] == true) {
      joined = true;
      peer = said['peer'] == true;
    } else if (said['ok'] == false) {
      refused = '${said['err']}';
    } else if (said.containsKey('peer')) {
      peer = said['peer'] == true;
      // The phone left: the session that rode on this is over. Its next one starts when the phone is back.
      if (!peer) _transport?._end();
    } else if (said['dropped'] == true) {
      // A frame went nowhere: the phone is not there after all.
      peer = false;
      _transport?._end();
    }
    onChange?.call();
  }

  void _ended() {
    if (closed) return;
    closed = true;
    joined = false;
    peer = false;
    _transport?._end();
    onChange?.call();
  }

  /// A session's view of this connection: the frames from now until the phone leaves or the session is closed.
  FrameTransport transport() {
    _transport?._end();
    return _transport = _RelayTransport(this);
  }

  /// Tells the relay to forget the channel: the pairing was removed.
  void forget() {
    try {
      _ws?.add(jsonEncode({'delete': true}));
    } catch (_) {}
  }

  Future<void> close() async {
    final ws = _ws;
    _ended();
    try {
      await ws?.close();
    } catch (_) {}
  }
}

/// One session's frames over a [RelaySocket]: the relay passes each WebSocket message on whole, so a frame needs
/// no length before it.
class _RelayTransport implements FrameTransport {
  _RelayTransport(this._socket);
  final RelaySocket _socket;
  final _frames = StreamController<Uint8List>();
  bool _over = false;

  @override
  String get via => 'relay';

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(Uint8List frame) {
    if (_over) return;
    try {
      _socket._ws?.add(frame);
    } catch (_) {
      _end();
    }
  }

  void _end() {
    if (_over) return;
    _over = true;
    if (identical(_socket._transport, this)) _socket._transport = null;
    _frames.close();
  }

  /// Ends the session's view. The connection to the relay stays, for the next session.
  @override
  Future<void> close() async => _end();
}
