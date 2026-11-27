import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';

/// What carries frames between the Mac and the phone: a socket on the local network ([TcpTransport]) or the relay
/// (`RelaySocket`). A session ([LinkSession]) is the same over either.
abstract class FrameTransport {
  /// local, relay.
  String get via;

  /// The frames that arrive; done when the connection ends.
  Stream<Uint8List> get frames;
  void send(Uint8List frame);
  Future<void> close();
}

/// A connection straight to the phone: each frame with its length, four bytes, before it (android DeskService).
class TcpTransport implements FrameTransport {
  TcpTransport._(this._socket) {
    _socket.listen(_onBytes, onDone: _end, onError: (_) => _end(), cancelOnError: true);
    // A write to a connection the phone has dropped fails here, not where it was written: taken as the end.
    _socket.done.then((_) {}, onError: (_) => _end());
  }

  /// Dials the phone at [host] and [port]. Throws where nothing answers within [timeout].
  static Future<TcpTransport> connect(String host, int port, {Duration timeout = const Duration(milliseconds: 1500)}) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(socket);
  }

  final Socket _socket;
  final _frames = StreamController<Uint8List>();

  /// The bytes that have come and are not yet a whole frame.
  final _buffer = BytesBuilder(copy: false);
  bool _closed = false;

  @override
  String get via => 'local';

  @override
  Stream<Uint8List> get frames => _frames.stream;

  /// Cuts what has arrived into frames by their lengths and passes each whole one on; the rest waits for more.
  /// A length of nothing, or over the largest a frame may be, ends the connection.
  void _onBytes(Uint8List bytes) {
    _buffer.add(bytes);
    var all = _buffer.takeBytes();
    var at = 0;
    while (all.length - at >= 4) {
      final length = ByteData.sublistView(all, at, at + 4).getUint32(0);
      if (length == 0 || length > DeskCrypto.maxFrame) {
        _end();
        return;
      }
      if (all.length - at - 4 < length) break;
      _frames.add(Uint8List.sublistView(all, at + 4, at + 4 + length));
      at += 4 + length;
    }
    if (at < all.length) _buffer.add(Uint8List.sublistView(all, at));
  }

  void _end() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    _frames.close();
  }

  @override
  void send(Uint8List frame) {
    if (_closed) return;
    final head = Uint8List(4);
    ByteData.sublistView(head).setUint32(0, frame.length);
    try {
      _socket.add(head);
      _socket.add(frame);
    } catch (_) {
      _end();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // What was said last is sent before the connection goes.
    try {
      await _socket.flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _end();
  }
}

/// The phone answered a hello with a refusal: `unknown` is a pairing it does not have.
class LinkRefused implements Exception {
  const LinkRefused(this.why);
  final String why;

  @override
  String toString() => 'The phone refused: $why';
}

/// There is no connection to the phone to ask over, or it ended before the answer came.
class LinkDown implements Exception {
  const LinkDown([this.message = 'Your phone isn\'t reachable']);
  final String message;

  @override
  String toString() => message;
}

/// The phone answered a request with an error of its own: its words.
class PhoneError implements Exception {
  const PhoneError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One connection to the phone, from the Mac's side (the phone's is android DeskSession.kt; docs/desktop.md).
///
/// [open] says hello in the clear (which pairing, a random number, a throwaway public key), takes the phone's hello
/// back, makes the connection's two keys and says `ready` sealed, which is what shows the phone that this Mac holds
/// the pairing's key; the phone's `ready` shows the same of it. From then: [request] asks and is answered, and
/// [events] is what either side says happened.
class LinkSession {
  LinkSession(this.transport);

  final FrameTransport transport;

  /// The pairing's key this connection is under: given for a paired phone, made here while pairing.
  Uint8List? key;

  /// What the phone's `ready` said of it: its name, the app's version, how the pairing connects.
  Map<String, dynamic> ready = const {};

  /// What seals and opens this connection's frames, once the hellos have made its keys.
  DeskChannel? _channel;
  StreamSubscription<Uint8List>? _sub;

  /// What [open] waits on: the phone's hello, then its `ready`.
  Completer<Uint8List>? _helloBack;
  Completer<Map<String, dynamic>>? _readyBack;

  /// The requests not yet answered, by their ids; [_next] is the id the next one goes under.
  final _waiting = <int, Completer<dynamic>>{};
  final _events = StreamController<({String name, Map<String, dynamic> args})>.broadcast();
  final _done = Completer<void>();
  int _next = 1;
  bool _live = false;
  bool _closed = false;

  /// Open and proved on both sides: requests and events can go.
  bool get live => _live && !_closed;
  bool get closed => _closed;

  /// Completes when the connection has ended, however it did.
  Future<void> get done => _done.future;

  Stream<({String name, Map<String, dynamic> args})> get events => _events.stream;

  /// Opens the connection under the pairing [id] names. A paired phone: [pairKey]. While pairing: [pairing] and
  /// [secret], the Mac's key pair and the sixteen bytes its QR code showed, and [id] the QR code's own.
  Future<void> open({
    required String id,
    Uint8List? pairKey,
    DeskKeyPair? pairing,
    Uint8List? secret,
    required String name,
    String app = '',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    assert((pairKey != null) != (pairing != null && secret != null));
    _sub = transport.frames.listen(_onFrame, onDone: _ended, onError: (_) => _ended(), cancelOnError: true);
    try {
      final nonce = DeskCrypto.randomBytes(16);
      final ephemeral = DeskCrypto.newKeyPair();
      _helloBack = Completer<Uint8List>();
      _say(DeskCrypto.hello, utf8.encode(jsonEncode({'v': 1, 'id': id, if (pairing != null) 'pair': true, 'n': base64.encode(nonce), 'e': base64.encode(ephemeral.public)})));
      final back = jsonDecode(utf8.decode(await _helloBack!.future.timeout(timeout))) as Map<String, dynamic>;
      if (back['err'] != null) throw LinkRefused('${back['err']}');
      var under = pairKey;
      if (pairing != null) {
        // The phone's public key for the pairing came in the clear. If it was swapped on the way, the key made here
        // is not the phone's, and the `ready` that follows does not open there.
        under = DeskCrypto.pairKey(pairing, base64.decode(back['k'] as String), secret!);
      }
      final keys = under == null ? null : DeskCrypto.sessionKeys(under, nonce, base64.decode(back['n'] as String), ephemeral, base64.decode(back['e'] as String));
      if (under == null || keys == null) throw const LinkRefused('a key that is no key');
      key = under;
      _channel = DeskChannel(sendKey: keys.desk, receiveKey: keys.phone);
      _readyBack = Completer<Map<String, dynamic>>();
      _send({'t': 'ready', 'name': name, 'app': app, 'proto': 1});
      ready = await _readyBack!.future.timeout(timeout);
      _live = true;
    } catch (e) {
      await close();
      if (e is LinkRefused) rethrow;
      throw LinkDown(e is TimeoutException ? 'The phone did not answer' : 'The connection ended: $e');
    }
  }

  /// Sends one frame: its type's byte, then [body]. [_send] seals a message and sends it as a sealed frame.
  void _say(int type, List<int> body) => transport.send(Uint8List.fromList([type, ...body]));

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null || _closed) return;
    _say(DeskCrypto.sealed, channel.seal(jsonEncode(message)));
  }

  /// Takes one frame from the phone: its hello, or a sealed `ready`, `res` (an answer) or `ev` (an event). Anything
  /// else, or anything that does not open, closes the connection.
  void _onFrame(Uint8List frame) {
    if (_closed || frame.isEmpty) return;
    final body = Uint8List.sublistView(frame, 1);
    if (frame[0] == DeskCrypto.hello) {
      final waiting = _helloBack;
      // One hello to a connection: another is not the phone's to send.
      if (waiting == null || waiting.isCompleted) {
        close();
      } else {
        waiting.complete(body);
      }
      return;
    }
    final text = frame[0] == DeskCrypto.sealed ? _channel?.open(body) : null;
    if (text == null) {
      // Not the next frame: repeated, out of order, changed, or under another key.
      close();
      return;
    }
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      close();
      return;
    }
    switch (m['t']) {
      case 'ready':
        final waiting = _readyBack;
        if (waiting == null || waiting.isCompleted) {
          close();
        } else {
          waiting.complete(m);
        }
      case 'res':
        final waiting = _waiting.remove(m['id']);
        if (waiting == null || waiting.isCompleted) return;
        if (m['ok'] == true) {
          waiting.complete(m['r']);
        } else {
          waiting.completeError(PhoneError('${m['e'] ?? 'The phone could not do that'}'));
        }
      case 'ev':
        if (_live) _events.add((name: '${m['m']}', args: (m['a'] as Map?)?.cast<String, dynamic>() ?? const {}));
      default:
        close();
    }
  }

  /// Asks the phone for [method] and gives its answer: a list, a map, a number, words, or null.
  Future<dynamic> request(String method, [Map<String, dynamic>? args, Duration timeout = const Duration(seconds: 20)]) {
    if (!live) return Future.error(const LinkDown());
    final id = _next++;
    final answer = Completer<dynamic>();
    _waiting[id] = answer;
    _send({'t': 'req', 'id': id, 'm': method, 'a': ?args});
    return answer.future.timeout(timeout, onTimeout: () {
      _waiting.remove(id);
      throw const LinkDown('The phone did not answer');
    });
  }

  /// Says something happened: `confirmed` and `cancel` while pairing, `mode` and `unpaired` after.
  void event(String name, [Map<String, dynamic>? args]) {
    if (!live) return;
    _send({'t': 'ev', 'm': name, 'a': ?args});
  }

  /// The connection is over: everything still waiting on it fails with [LinkDown], and [done] completes.
  void _ended() {
    if (_closed) return;
    _closed = true;
    _live = false;
    _sub?.cancel();
    for (final w in [_helloBack, _readyBack]) {
      if (w != null && !w.isCompleted) w.completeError(const LinkDown());
    }
    for (final w in _waiting.values) {
      if (!w.isCompleted) w.completeError(const LinkDown());
    }
    _waiting.clear();
    _events.close();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    if (_closed) return;
    _ended();
    await transport.close();
  }
}
