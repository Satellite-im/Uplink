import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// One identity on several devices at once (Matt, 2026-11-18: "I want desktop to be able to run standalone for internal
/// friends and circles ... even if the desktop is linked"): a phone and its computer both here, each handed what is
/// sent to them, neither putting the other off; a reconnect from the same device still takes its own place.

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

  Future<Map> connect(String url, {bool peek = false, String? device, String? mode, bool stamp = false}) async {
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
    socket.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (peek) 'peek': true, 'device': ?device, 'mode': ?mode, if (stamp) 'stamp': true}));
    return hello.future.timeout(const Duration(seconds: 5));
  }

  /// A packet to [to], as the app's hub route sends one: [1][seq][to][the packet].
  void sendTo(_Install to, List<int> packet) {
    final seq = ByteData(4)..setUint32(0, _rnd.nextInt(1 << 30));
    ws.add(Uint8List.fromList([Hub.toPeer, ...seq.buffer.asUint8List(), ..._unhex(to.id), ...packet]));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 200));

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

  test('a phone and its computer, one identity, are both here and both handed what is sent', () async {
    final phone = _Install(), desk = _Install.copyOf(phone), friend = _Install();
    expect((await phone.connect(url, device: 'phone'))['ok'], isTrue);
    expect((await desk.connect(url, device: 'desk'))['ok'], isTrue);
    await friend.connect(url);
    await _settle();
    expect(phone.closed, isFalse, reason: 'the computer does not put the phone off');
    expect(hub.connected, 3);
    friend.sendTo(phone, [7, 7]);
    await _settle();
    expect(phone.frames.length, 1);
    expect(desk.frames.length, 1, reason: 'the same identity on the computer has it too');
  });

  test('what a device sends to its own name while alone is kept for its other devices, not handed back to it', () async {
    final phone = _Install(), desk = _Install.copyOf(phone);
    await phone.connect(url, device: 'phone');
    await _settle();
    phone.sendTo(phone, [9, 9, 9]);
    await _settle();
    expect(phone.frames, isEmpty, reason: 'nobody else of it here: kept');
    await phone.ws.close();
    await _settle();
    final again = _Install.copyOf(phone);
    expect((await again.connect(url, device: 'phone'))['held'], 0, reason: 'not handed back to the device that sent it');
    await _settle();
    expect(again.frames, isEmpty);
    expect((await desk.connect(url, device: 'desk'))['held'], 1);
    await _settle();
    expect(desk.frames.single.sublist(17), [9, 9, 9]);
  });

  // GMFB-53: what an account sends its own name says which of its devices sent it, to a device that asks (a history goes
  // only to the device that asked for it); every other connection and every other packet is handed exactly as before.
  test('a packet to its own name is handed with the sending device to its devices that ask, live and kept; as before to the rest', () async {
    final phone = _Install(), desk = _Install.copyOf(phone), old = _Install.copyOf(phone), friend = _Install();
    await phone.connect(url, device: 'phone');
    await desk.connect(url, device: 'desk', stamp: true);
    await old.connect(url, device: 'old');
    await friend.connect(url, stamp: true);
    await _settle();
    phone.sendTo(phone, [5, 6]);
    friend.sendTo(desk, [8]);
    await _settle();
    final from = _unhex(phone.id);
    expect(desk.frames[0], [Hub.toPeerFromDevice, ...from, 5, ...utf8.encode('phone'), 5, 6], reason: 'stamped for the device that asked');
    expect(old.frames.first, [Hub.toPeer, ...from, 5, 6], reason: 'byte for byte as before for one that did not');
    expect(desk.frames[1], [Hub.toPeer, ..._unhex(friend.id), 8], reason: 'someone else\'s packet is as before');
    // Kept while the asking device was away: stamped as it is handed over.
    await desk.ws.close();
    await old.ws.close();
    await _settle();
    phone.sendTo(phone, [9]);
    await _settle();
    final back = _Install.copyOf(phone);
    expect((await back.connect(url, device: 'desk', stamp: true))['held'], 1);
    await _settle();
    expect(back.frames, [[Hub.toPeerFromDevice, ...from, 5, ...utf8.encode("phone"), 9]]);
    // A device that names none is never vouched for: as before.
    final nameless = _Install.copyOf(phone);
    await nameless.connect(url);
    await _settle();
    nameless.sendTo(nameless, [4]);
    await _settle();
    expect(back.frames.last, [Hub.toPeer, ...from, 4]);
  });

  test('the same device again takes its own place; one from before devices still takes the place of another', () async {
    final a = _Install(), again = _Install.copyOf(a), other = _Install.copyOf(a);
    await a.connect(url, device: 'phone');
    await other.connect(url, device: 'desk');
    await again.connect(url, device: 'phone');
    await _settle();
    expect(a.closed, isTrue);
    expect(other.closed, isFalse);
    expect(hub.connected, 2);
    final old1 = _Install(), old2 = _Install.copyOf(old1);
    await old1.connect(url);
    await old2.connect(url);
    await _settle();
    expect(old1.closed, isTrue, reason: 'two apps from before devices are one device, as before');
  });

  test('away is every device away; gone is the last one going', () async {
    final watcher = _Install(), phone = _Install(), desk = _Install.copyOf(phone);
    await watcher.connect(url);
    final heard = <Map>[];
    watcher.said.stream.listen(heard.add);
    watcher.ws.add(jsonEncode({'watch': [phone.id]}));
    await phone.connect(url, device: 'phone');
    await desk.connect(url, device: 'desk');
    await _settle();
    expect(heard.where((m) => m['came'] == phone.id).length, 1, reason: 'came once, with the first device');
    phone.ws.add(jsonEncode({'away': true}));
    await _settle();
    expect(heard.where((m) => m['away'] == phone.id), isEmpty, reason: 'the computer is still in use');
    desk.ws.add(jsonEncode({'away': true}));
    await _settle();
    expect(heard.lastWhere((m) => m['away'] == phone.id)['is'], isTrue);
    await phone.ws.close();
    await _settle();
    expect(heard.where((m) => m['went'] == phone.id), isEmpty, reason: 'the computer is still here');
    await desk.ws.close();
    await _settle();
    expect(heard.where((m) => m['went'] == phone.id).length, 1);
  });

  // GMFB-34: a person chooses Online, Away, Busy or Invisible. Busy is told to watchers; invisible is gone to them, and
  // someone who comes in invisible never shows as come at all.
  test('busy is told to watchers, invisible looks gone, and coming in invisible shows nothing', () async {
    final watcher = _Install(), maya = _Install(), sam = _Install();
    await watcher.connect(url);
    final heard = <Map>[];
    watcher.said.stream.listen(heard.add);
    watcher.ws.add(jsonEncode({'watch': [maya.id, sam.id]}));
    await _settle();
    await maya.connect(url, device: 'phone');
    await _settle();
    expect(heard.where((m) => m['came'] == maya.id), hasLength(1));
    maya.ws.add(jsonEncode({'mode': 'busy'}));
    await _settle();
    expect(heard.lastWhere((m) => m['busy'] == maya.id)['is'], isTrue);
    // A new watcher is told in the answer to watch.
    final late = _Install();
    await late.connect(url);
    final answer = late.said.stream.first;
    late.ws.add(jsonEncode({'watch': [maya.id]}));
    final a = await answer.timeout(const Duration(seconds: 5));
    expect(a['here'], [maya.id]);
    expect(a['busy'], [maya.id]);
    maya.ws.add(jsonEncode({'mode': 'invisible'}));
    await _settle();
    expect(heard.where((m) => m['went'] == maya.id), hasLength(1), reason: 'gone, to watchers');
    final later = _Install();
    await later.connect(url);
    final hidden = later.said.stream.first;
    later.ws.add(jsonEncode({'watch': [maya.id]}));
    expect((await hidden.timeout(const Duration(seconds: 5)))['here'], isEmpty, reason: 'not here, to anyone asking');
    maya.ws.add(jsonEncode({'away': true}));
    await _settle();
    expect(heard.where((m) => m['away'] == maya.id), isEmpty, reason: 'nothing about someone invisible');
    maya.ws.add(jsonEncode({'mode': 'online'}));
    await _settle();
    expect(heard.where((m) => m['came'] == maya.id), hasLength(2), reason: 'back');
    expect(heard.where((m) => m['busy'] == maya.id && m['is'] == true), hasLength(1), reason: 'back as online, not busy: busy was not said again');
    await maya.ws.close();
    // Coming in invisible: no came at all; going, no went either.
    await sam.connect(url, device: 'phone', mode: 'invisible');
    await _settle();
    expect(heard.where((m) => m['came'] == sam.id), isEmpty);
    await sam.ws.close();
    await _settle();
    expect(heard.where((m) => m['went'] == sam.id), isEmpty);
  });

  // Matt, 2026-11-18: his phone stopped seeing a circle's messages and members once his computer, the same identity,
  // joined its rooms: a room kept one device a member, so the last to join took the other's place.
  test('in a room, every device of a member is handed what is sent, and a member goes only with their last device', () async {
    final phone = _Install(), desk = _Install.copyOf(phone), friend = _Install();
    await phone.connect(url, device: 'phone');
    await desk.connect(url, device: 'desk');
    await friend.connect(url, device: 'phone');
    final room = 'ab' * 16, token = 'cd' * 32;
    for (final i in [phone, desk, friend]) {
      i.ws.add(jsonEncode({'join': room, 'token': token}));
      await _settle();
    }
    final cameToFriend = <Map>[];
    final wentToFriend = <Map>[];
    friend.said.stream.listen((m) {
      if (m['came'] != null) cameToFriend.add(m);
      if (m['went'] != null) wentToFriend.add(m);
    });
    // The friend writes: the phone and the computer both have it.
    friend.ws.add(Uint8List.fromList([Hub.toRoom, ..._unhex(room), 9, 9]));
    await _settle();
    expect(phone.frames.length, 1, reason: 'the phone is still in the room after the computer joined');
    expect(desk.frames.length, 1);
    // The computer writes: the friend has it, and so does the phone, the same person's other device.
    desk.ws.add(Uint8List.fromList([Hub.toRoom, ..._unhex(room), 5]));
    await _settle();
    expect(friend.frames.length, 1);
    expect(phone.frames.length, 2);
    expect(desk.frames.length, 1, reason: 'not back to the connection it came from');
    // The computer leaves: the phone is still there, so nobody is told they went.
    desk.ws.add(jsonEncode({'leave': room}));
    await _settle();
    expect(wentToFriend, isEmpty);
    friend.ws.add(Uint8List.fromList([Hub.toRoom, ..._unhex(room), 1]));
    await _settle();
    expect(phone.frames.length, 3, reason: 'the phone still has the room after the computer left it');
    // Then the phone leaves too: now they have gone.
    phone.ws.add(jsonEncode({'leave': room}));
    await _settle();
    expect(wentToFriend.length, 1);
  });
}
