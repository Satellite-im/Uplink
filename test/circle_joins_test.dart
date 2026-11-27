import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/circles/pending_link.dart';
import 'package:ghost_messaging/desktop/links.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Joins told of in circles (Matt, 2026-11-19: "add join notifications for memebers in circles"), and a circle's link
/// carried through getting the app and setting it up ("have it prompt them to download the app if it's not downloaded
/// already and then have it redirect to the circle after they sign up for their account").
Future<Circle> _circle({String name = 'Night Owls'}) async {
  final keys = NetKeys.generate();
  final owner = NetCrypto.hex(keys.public);
  final m = await CircleManifest(owner: owner, version: 1, name: name, hue: 'indigo', icon: 'book', spaces: [
    CircleSpace.make('General', kind: SpaceKind.text),
  ]).signedBy(keys.id, keys.public, (b) async => NetCrypto.sign(keys, b));
  return Circle(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), owner: owner, manifest: m);
}

/// A hub in memory: what one route says in a room, every other route in it hears, stamped with who said it.
class _Hub {
  final routes = <_Route>[];
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me) {
    hub.routes.add(this);
  }
  final _Hub hub;
  @override
  final String me;
  final rooms = <String>{};
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();

  @override
  Future<List<String>> join(String room, String token) async {
    rooms.add(room);
    return [for (final r in hub.routes) if (r != this && r.rooms.contains(room)) r.me];
  }

  @override
  void leave(String room) => rooms.remove(room);
  @override
  void send(String room, Uint8List bytes) {
    for (final r in hub.routes) {
      if (r != this && r.rooms.contains(room)) r._packets.add((room: room, from: me, bytes: bytes));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  group('joins told of', () {
    test('one who comes in after this device is told of once; this device\'s own, and the owner\'s, are not', () async {
      final c = await _circle();
      final circles = Circles.forTest(app: AppState())..join(c);
      final told = <CircleJoin>[];
      final sub = circles.joined.listen(told.add);
      final later = DateTime.now().millisecondsSinceEpoch + 1000;

      circles.heardJoined(c, 'maya', 'Maya Chen', later);
      circles.heardJoined(c, 'maya', 'Maya Chen', later + 5);
      await _settle();
      expect(told.map((j) => j.line), ['Maya Chen joined Night Owls'], reason: 'said again (another of her devices, or the hub handing it over again), not told of again');
      expect(circles.seenIn(c)['maya'], 'Maya Chen', reason: 'her name is the members list\'s too');
      expect(circles.joinsIn(c).keys, ['maya']);

      circles.heardJoined(c, c.manifest.ownerId, 'Owner', later);
      circles.heardJoined(c, 'sam', '', later);
      await _settle();
      expect(told.map((j) => j.line), ['Maya Chen joined Night Owls', 'Someone new joined Night Owls']);
      await sub.cancel();
    });

    test('joins from before this device came in, or long ago, are taken in quietly', () async {
      final c = await _circle();
      final circles = Circles.forTest(app: AppState())..join(c);
      final told = <CircleJoin>[];
      final sub = circles.joined.listen(told.add);
      final now = DateTime.now().millisecondsSinceEpoch;
      circles.heardJoined(c, 'early', 'Early Bird', now - 60000);
      await _settle();
      expect(told, isEmpty);
      expect(circles.seenIn(c)['early'], 'Early Bird', reason: 'still one of its members');
      await sub.cancel();
    });

    test('a circle held from before joins were said counts from now; what was told of stays told across a launch', () async {
      final c = await _circle();
      final app = AppState();
      // Held before this build: no joined-at kept.
      app.set('circles', '[${_json(c)}]');
      final first = Circles.forTest(app: app);
      final told = <CircleJoin>[];
      final sub = first.joined.listen(told.add);
      first.heardJoined(c, 'old', 'Old Friend', DateTime.now().millisecondsSinceEpoch - 5000);
      first.heardJoined(c, 'new', 'New Friend', DateTime.now().millisecondsSinceEpoch + 1000);
      await _settle();
      expect(told.map((j) => j.name), ['New Friend']);
      await sub.cancel();

      final again = Circles.forTest(app: app);
      final told2 = <CircleJoin>[];
      final sub2 = again.joined.listen(told2.add);
      again.heardJoined(c, 'new', 'New Friend', DateTime.now().millisecondsSinceEpoch + 1000);
      await _settle();
      expect(told2, isEmpty, reason: 'kept as told of');
      await sub2.cancel();
    });

    test('through the room: one who joins says so, and those in it are told', () async {
      final c = await _circle();
      final hub = _Hub();
      final here = Circles.forTest(app: AppState(), route: _Route(hub, 'aaaa'))..join(c);
      await _settle();
      final told = <CircleJoin>[];
      final sub = here.joined.listen(told.add);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final newcomer = Circles.forTest(app: AppState(), route: _Route(hub, 'bbbb'))..join(c);
      await _settle();
      expect(told.map((j) => j.id), ['bbbb']);
      expect(told.single.circle.seed, c.seed);
      // Opened again later (the next launch, the hub handing it over again): not said twice.
      await sub.cancel();
      expect(newcomer.joinsIn(c), isEmpty, reason: 'its own join is not one it is told of');
    });
  });

  group('a link carried through setup', () {
    late Map<String, String> prefs;
    String? clip;
    setUp(() {
      prefs = {};
      clip = null;
      PendingCircleLink.readPrefs = () async => {...prefs};
      PendingCircleLink.writePref = (k, v) async => prefs[k] = v;
      PendingCircleLink.readClipboard = () async => clip;
    });

    const link = 'https://gogho.st/join/#c.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.TmlnaHQgT3dscw';

    test('a link opened before setup is held, then taken once', () async {
      expect(await PendingCircleLink.hold('Join us! $link'), isTrue);
      expect(await PendingCircleLink.take(fresh: true), link);
      expect(await PendingCircleLink.take(fresh: true), isNull, reason: 'taken once');
      expect(await PendingCircleLink.hold('nothing here'), isFalse);
    });

    test('the invite page\'s copy is found on a new install\'s first setup, once', () async {
      clip = link;
      expect(await PendingCircleLink.take(fresh: true), link);
      expect(await PendingCircleLink.take(fresh: true), isNull, reason: 'the clipboard is looked at only the first time');
    });

    test('an install already in circles never reads the clipboard', () async {
      clip = link;
      expect(await PendingCircleLink.take(fresh: false), isNull);
      expect(prefs['pending_clip_checked'], '1');
    });

    test('the app\'s own scheme is read as the https link', () {
      expect(DeskLinks.normalise('ghostmsg://join/#c.abc'), 'https://gogho.st/join/#c.abc');
      expect(DeskLinks.normalise('ghostmsg://join#c.abc'), 'https://gogho.st/join/#c.abc');
      expect(DeskLinks.normalise(link), link);
    });
  });
}

/// [c] as Circles keeps it (`circles`).
String _json(Circle c) => jsonEncode(c.toJson());
