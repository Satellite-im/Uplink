import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// A room keeps what is marked to be kept (Matt, 2026-11-18: "I can't see their messages in spaces within a circle"):
/// written while a phone was closed, it is handed to the phone when it comes into the room, sealed as it was sent.

final _rnd = Random(7);
List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// An install: a key, and connections to the hub signed with it.
class _Install {
  _Install() : scalar = _bytes(32) {
    key = P256.publicOf(scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;
  bool closed = false;
  late WebSocket ws;
  final said = StreamController<Map>.broadcast();
  final frames = <List<int>>[];

  /// Signs in (or only looks, with [peek]); what the hub answers the hello with.
  /// The same identity on another device ([device] names it in the hello).
  _Install.copyOf(_Install other)
      : scalar = other.scalar,
        key = other.key,
        id = other.id;

  Future<Map> connect(String url, {bool peek = false, String? device}) async {
    final socket = await WebSocket.connect(url);
    if (!peek) ws = socket;
    socket.done.then((_) => closed = true);
    final first = Completer<Map>(), hello = Completer<Map>();
    socket.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      if (!first.isCompleted) {
        first.complete(m);
      } else if (!hello.isCompleted) {
        hello.complete(m);
      } else {
        said.add(m);
      }
    });
    final nonce = _unhex((await first.future)['hello'] as String);
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], _bytes(32));
    socket.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (peek) 'peek': true, 'device': ?device}));
    return hello.future.timeout(const Duration(seconds: 5));
  }

  /// A packet to [to], as the app's hub route sends one: [1][seq][to][the packet].
  void sendTo(_Install to, List<int> packet) {
    final seq = ByteData(4)..setUint32(0, _rnd.nextInt(1 << 30));
    ws.add(Uint8List.fromList([Hub.toPeer, ...seq.buffer.asUint8List(), ..._unhex(to.id), ...packet]));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 200));

const _room = 'abababababababababababababababab';
final _token = 'cd' * 32;

void main() {
  late Relay relay;
  late Hub hub;
  late String url;

  setUp(() async {
    hub = Hub();
    relay = Relay(hub: hub);
    url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
  });
  tearDown(() => relay.stop());

  void say(_Install who, int kind, List<int> bytes) => who.ws.add(Uint8List.fromList([kind, ..._unhex(_room), ...bytes]));

  test('what is marked kept is handed to whoever joins later; what is not, is not; a wrong token gets nothing', () async {
    final writer = _Install(), phone = _Install(), stranger = _Install();
    await writer.connect(url);
    writer.ws.add(jsonEncode({'join': _room, 'token': _token}));
    await _settle();
    say(writer, Hub.toRoomKept, [1, 1, 1]);
    say(writer, Hub.toRoom, [2, 2]);
    await _settle();
    expect(hub.keptIn(_room), 1);
    await phone.connect(url);
    phone.ws.add(jsonEncode({'join': _room, 'token': _token}));
    await _settle();
    expect(phone.frames.length, 1, reason: 'the kept one alone');
    final f = phone.frames.single;
    expect(f[0], Hub.toRoom, reason: 'handed on as an ordinary room packet');
    expect(f.sublist(f.length - 3), [1, 1, 1]);
    // Kept even once everyone has left the room.
    await writer.ws.close();
    await phone.ws.close();
    await _settle();
    await stranger.connect(url);
    stranger.ws.add(jsonEncode({'join': _room, 'token': 'ef' * 32}));
    await _settle();
    expect(stranger.frames, isEmpty);
    await stranger.ws.close();
    await _settle();
    final again = _Install();
    await again.connect(url);
    again.ws.add(jsonEncode({'join': _room, 'token': _token}));
    await _settle();
    expect(again.frames.length, 1);
  });
}
