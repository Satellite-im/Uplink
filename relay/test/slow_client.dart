// A WebSocket client made by hand over a raw socket, so a test can read slowly (a phone on a slow link), stop reading
// (a phone put away), and be cut off without a word (its network gone). From the third review (2026-11-23).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';

import 'fed_support.dart' show someBytes, unhex;

class Slow {
  Slow._(this.socket, this.name);
  final Socket socket;
  final String name;
  late final StreamSubscription<Uint8List> _sub;
  Uint8List _rest = Uint8List(0);
  final _message = BytesBuilder(copy: false);
  int _kind = 0;

  /// What it was told, in order: each text as a map, each binary message as bytes; and when.
  final texts = <Map>[];
  final frames = <Uint8List>[];
  final events = <(Duration, String)>[];
  final _clock = Stopwatch()..start();
  final closed = Completer<int?>();
  int? closeCode;
  int bytesIn = 0, bytesOut = 0;

  /// Bytes a second it reads; 0 for as fast as they come.
  int _rate = 0;
  final _rateClock = Stopwatch();
  int _counted = 0;
  bool _away = false;
  Timer? _again;
  bool _subPaused = false;
  final _waiters = <void Function()>[];

  bool get isClosed => closed.isCompleted;

  static Future<Slow> open(int port, {String path = '/hub', int rate = 0, String name = '', int? rcvbuf}) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    if (rcvbuf != null) {
      try {
        // SO_RCVBUF on macOS (0x1002) and Linux (8).
        s.setRawOption(RawSocketOption.fromInt(RawSocketOption.levelSocket, Platform.isMacOS ? 0x1002 : 8, rcvbuf));
      } catch (_) {}
    }
    final c = Slow._(s, name);
    c._rate = rate;
    c._rateClock.start();
    final head = Completer<void>();
    final got = BytesBuilder();
    c._sub = s.listen((d) {
      if (!head.isCompleted) {
        got.add(d);
        final all = got.toBytes();
        final at = _endOfHead(all);
        if (at < 0) return;
        head.complete();
        if (all.length > at + 4) c._data(Uint8List.sublistView(all, at + 4));
        return;
      }
      c._data(d);
    }, onDone: () => c._ended(), onError: (_) => c._ended(), cancelOnError: true);
    unawaited(s.done.then((_) {}, onError: (_) {}));
    s.write('GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    await s.flush();
    await head.future.timeout(const Duration(seconds: 10));
    return c;
  }

  static int _endOfHead(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }

  void _note(String what) => events.add((_clock.elapsed, what));

  void _ended() {
    if (!closed.isCompleted) {
      _note('ended ${closeCode ?? 'without a close frame'}');
      closed.complete(closeCode);
    }
    _wake();
  }

  void _wake() {
    final w = [..._waiters];
    _waiters.clear();
    for (final f in w) {
      f();
    }
  }

  /// Reads at [bytesASecond] from now (0: as fast as it comes).
  set rate(int bytesASecond) {
    _rate = bytesASecond;
    _counted = 0;
    _rateClock
      ..reset()
      ..start();
    if (!_away) _resume();
  }

  /// Stops reading, as a phone put away does; what is sent to it waits in the machine's buffers, then at the door.
  void away() {
    _away = true;
    _note('away');
    _pause();
  }

  void back() {
    _away = false;
    _note('back');
    _counted = 0;
    _rateClock
      ..reset()
      ..start();
    _resume();
  }

  void _pause() {
    if (!_subPaused) {
      _subPaused = true;
      _sub.pause();
    }
  }

  void _resume() {
    _again?.cancel();
    if (_subPaused) {
      _subPaused = false;
      _sub.resume();
    }
  }

  void _data(Uint8List d) {
    bytesIn += d.length;
    _rest = _rest.isEmpty ? d : (BytesBuilder(copy: false)..add(_rest)..add(d)).takeBytes();
    _parse();
    if (_rate > 0 && !_away) {
      _counted += d.length;
      final due = _counted * 1000 ~/ _rate, now = _rateClock.elapsedMilliseconds;
      if (due > now) {
        _pause();
        _again?.cancel();
        _again = Timer(Duration(milliseconds: due - now), () {
          if (!_away) _resume();
        });
      }
    }
  }

  void _parse() {
    while (true) {
      final b = _rest;
      if (b.length < 2) return;
      final fin = b[0] & 0x80 != 0, op = b[0] & 0x0f;
      var len = b[1] & 0x7f, at = 2;
      if (len == 126) {
        if (b.length < 4) return;
        len = (b[2] << 8) | b[3];
        at = 4;
      } else if (len == 127) {
        if (b.length < 10) return;
        len = 0;
        for (var i = 2; i < 10; i++) {
          len = (len << 8) | b[i];
        }
        at = 10;
      }
      if (b.length < at + len) return;
      final payload = Uint8List.sublistView(b, at, at + len);
      _rest = Uint8List.sublistView(b, at + len);
      switch (op) {
        case 8:
          closeCode = payload.length >= 2 ? (payload[0] << 8) | payload[1] : 1005;
          _note('close frame $closeCode ${utf8.decode(payload.length > 2 ? payload.sublist(2) : const [], allowMalformed: true)}');
          try {
            _send(8, payload.length >= 2 ? payload.sublist(0, 2) : const []);
          } catch (_) {}
        case 9:
          try {
            _send(10, payload);
          } catch (_) {}
        case 10:
          break;
        case 0 || 1 || 2:
          if (op != 0) _kind = op;
          _message.add(Uint8List.fromList(payload));
          if (fin) {
            final whole = _message.takeBytes();
            if (_kind == 1) {
              final m = jsonDecode(utf8.decode(whole)) as Map;
              texts.add(m);
              _note('text ${utf8.decode(whole).substring(0, min(80, whole.length))}');
            } else {
              frames.add(whole);
            }
            _wake();
          }
      }
    }
  }

  void _send(int op, List<int> payload) {
    final len = payload.length;
    final mask = someBytes(4);
    final out = BytesBuilder(copy: false)
      ..addByte(0x80 | op)
      ..add(len < 126 ? [0x80 | len] : len < 65536 ? [0x80 | 126, len >> 8, len & 0xff] : [0x80 | 127, for (var i = 7; i >= 0; i--) (len >> (8 * i)) & 0xff])
      ..add(mask)
      ..add([for (var i = 0; i < len; i++) payload[i] ^ mask[i & 3]]);
    final bytes = out.takeBytes();
    bytesOut += bytes.length;
    socket.add(bytes);
  }

  void sendText(Object json) => _send(1, utf8.encode(jsonEncode(json)));
  void sendBinary(List<int> bytes) => _send(2, bytes);

  /// Waits until [ok], or [within].
  Future<bool> until(bool Function() ok, {Duration within = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(within);
    while (!ok()) {
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) return false;
      final step = Completer<void>();
      _waiters.add(step.complete);
      await step.future.timeout(left > const Duration(milliseconds: 200) ? const Duration(milliseconds: 200) : left, onTimeout: () {});
    }
    return true;
  }

  /// Signs in as [scalar]'s key (v1), as device [device]: the answer.
  Future<Map> signIn(List<int> scalar, {String device = ''}) async {
    if (!await until(() => texts.isNotEmpty, within: const Duration(seconds: 10))) throw StateError('$name: no hello');
    final hello = texts.first;
    final key = P256.publicOf(scalar);
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...unhex(hello['hello'] as String)], someBytes(32));
    sendText({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig), if (device.isNotEmpty) 'device': device});
    if (!await until(() => texts.length >= 2, within: const Duration(seconds: 15))) throw StateError('$name: no answer to its sign-in');
    return texts[1];
  }

  void cut() {
    _note('cut');
    socket.destroy();
  }
}

/// [n] bytes in two: an index first, so order and duplicates can be told.
List<int> indexed(int i, int size) => [i >> 8, i & 0xff, ...List.filled(max(0, size - 2), i & 0xff)];
int indexOf(List<int> payload) => (payload[0] << 8) | payload[1];

String idOf(List<int> scalar) => Hub.nameOf(P256.publicOf(scalar));
