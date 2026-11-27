import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpServer, InternetAddress, OSError, SocketException, WebSocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/relay_choice.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

import 'support/hub_pair.dart';

/// The hub's route over whatever carries it (lib/net/hub_link.dart): a HubCarrier is handed a way to dial, and knows
/// nothing of WebSockets. Here the way is memory (test/support/hub_pair.dart), into a real hub by Hub.attach, with no
/// server at all; then dialHub's own link, the WebSocket every build has used until now, is held to what a link
/// promises. The route through a real server is test/net_test.dart's.

/// Waits for [ok], however long the machine takes (two seconds at most), not for a length of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 400 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

Future<void> _up(HubCarrier c) async {
  await c.start();
  await _until(() => c.state.value == CarrierState.up, c.problem ?? 'it never signed in');
}

/// A hub that takes any sign-in and answers it with whatever link helpers it was made to name.
class _OddHub implements HubLink {
  _OddHub(this.helpers) {
    _said.add(jsonEncode({'hello': '00' * 32}));
  }
  final Object? helpers;
  final _said = StreamController<Object>();
  @override
  Stream<Object> get said => _said.stream;
  @override
  void say(Object message) {
    if (message is String && message.contains('"sig"')) _said.add(jsonEncode({'ok': true, 'held': 0, 'helpers': helpers}));
  }

  @override
  Future<void> close() async => _said.close();
}

void main() {
  // What a web page, a hub in the app and a peer-to-peer stream all stand on: the route and its link name no platform.
  test('dart:io and the browser are each in a file of their own, which the route, its link and the relay check never name', () {
    for (final path in ['lib/net/hub_link.dart', 'lib/net/hub_carrier.dart', 'lib/net/relay_choice.dart']) {
      final source = File(path).readAsStringSync();
      for (final platform in ['dart:io', 'dart:js_interop', 'dart:html', 'package:web/']) {
        expect(source, isNot(contains("import '$platform")), reason: '$path imports $platform');
      }
    }
    expect(File('lib/net/hub_link_io.dart').readAsStringSync(), isNot(contains('js_interop')));
    expect(File('lib/net/hub_link_web.dart').readAsStringSync(), isNot(contains("import 'dart:io'")));
  });

  group('a hub in this process, dialled through memory', () {
    test('two installs reach each other and join a room, and one whose link drops dials again and is back in it', () async {
      final memory = MemoryHub();
      final a = NetKeys.generate(), b = NetKeys.generate();
      HubCarrier route(NetKeys keys) => HubCarrier(url: memory.url, signer: KeysSigner(keys), retry: const Duration(milliseconds: 20), dial: memory.dial);
      final hubA = route(a), hubB = route(b);
      addTearDown(() async {
        await hubA.stop();
        await hubB.stop();
      });
      await _up(hubA);
      final first = memory.pairs.single;
      await _up(hubB);
      expect(memory.dialled, [memory.url, memory.url], reason: 'each dialled the address it was given, once');
      expect(memory.hub.connected, 2);

      // One to the other, by name: passed at once, and stamped by the hub with who sent it.
      final got = hubB.arrived.first;
      expect(await hubA.send(Peer(id: b.id), Uint8List.fromList([1, 2, 3])), Handed.passed);
      final arrived = await got.timeout(const Duration(seconds: 2));
      expect([arrived.from, arrived.bytes], [a.id, [1, 2, 3]]);

      // A room.
      final room = 'ab' * 16, token = 'cd' * 32;
      expect(await hubA.join(room, token), isEmpty);
      expect(await hubB.join(room, token), [a.id]);
      var heard = hubA.roomPackets.first;
      hubB.sendRoom(room, Uint8List.fromList([9]));
      final said = await heard.timeout(const Duration(seconds: 2));
      expect([said.room, said.from, said.bytes], [room, b.id, [9]]);

      // A's link drops, as a network going does. It is down, dials again by itself, signs in and joins the room again.
      final states = <CarrierState>[];
      void state() => states.add(hubA.state.value);
      hubA.state.addListener(state);
      addTearDown(() => hubA.state.removeListener(state));
      final mine = <String>[], theirs = <String>[];
      hubA.roomEvents.listen((e) => mine.add(e.closed ? 'closed' : 'in with ${e.members}'));
      hubB.roomEvents.listen((e) => theirs.add(e.went != null ? 'went ${e.went}' : 'came ${e.came}'));
      first.cut();
      await _until(() => states.length >= 3 && theirs.length >= 2, 'A never came back: $states, $theirs');
      expect(states, [CarrierState.down, CarrierState.connecting, CarrierState.up]);
      expect(memory.dialled, hasLength(3), reason: 'dialled again, once');
      expect(memory.pairs.last.isOpen, isTrue);
      expect(memory.hub.connected, 2);
      expect(mine, ['closed', 'in with ${[b.id]}']);
      expect(theirs, ['went ${a.id}', 'came ${a.id}']);
      heard = hubA.roomPackets.first;
      hubB.sendRoom(room, Uint8List.fromList([10]));
      expect((await heard.timeout(const Duration(seconds: 2))).bytes, [10]);
      expect(await hubB.send(Peer(id: a.id), Uint8List.fromList([4])), Handed.passed);

      // Stopped, its link is closed: the hub sees it go.
      await hubB.stop();
      await _until(() => memory.hub.connected == 1, 'the hub never saw B go');
      expect(memory.pairs[1].isOpen, isFalse);
    });

    test('a hub that cannot be dialled is tried again and again, and signed in to once it can be', () async {
      final memory = MemoryHub()..down = true;
      final c = HubCarrier(url: memory.url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 10), dial: memory.dial);
      addTearDown(c.stop);
      await c.start();
      await _until(() => memory.dialled.length >= 3 && c.state.value == CarrierState.down, 'it did not keep trying');
      expect(c.problem, 'The relay server could not be reached');
      expect(memory.pairs, isEmpty);
      memory.down = false;
      await _until(() => c.state.value == CarrierState.up, 'it never signed in');
      expect(c.problem, isNull);
      expect(memory.hub.connected, 1);
    });

    test('a link that comes after the route was stopped is closed, not used', () async {
      final memory = MemoryHub();
      final held = Completer<void>();
      final c = HubCarrier(
        url: memory.url,
        signer: KeysSigner(NetKeys.generate()),
        dial: (url) async {
          await held.future;
          return memory.dial(url);
        },
      );
      await c.start();
      expect(c.state.value, CarrierState.connecting);
      await c.stop();
      held.complete();
      await _until(() => memory.pairs.isNotEmpty && !memory.pairs.single.isOpen, 'the late link was left open');
      await pumpEventQueue();
      expect(c.state.value, CarrierState.off);
      expect(memory.hub.connected, 0);
    });

    // docs/OPEN_NETWORK.md, section 2: "the relay's hub says which to use as an app signs in (`"helpers"`, from
    // `GHOST_LINK_HELPERS`)". What the direct route's node is given comes from here.
    test('the link helpers the hub names as the app signs in are told, anew at every sign-in, and kept while the link is lost', () async {
      final memory = MemoryHub(Hub(helpers: ['https://link.example', 'https://two.example']));
      final c = HubCarrier(url: memory.url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 20), dial: memory.dial);
      addTearDown(c.stop);
      expect(c.helpers.value, isEmpty, reason: 'none until the hub has said');
      var told = 0;
      // Told before the route is said to be up: whoever acts on its coming up has them.
      final asUp = <List<String>>[];
      c.helpers.addListener(() => told++);
      c.state.addListener(() {
        if (c.state.value == CarrierState.up) asUp.add(c.helpers.value);
      });
      await _up(c);
      expect(c.helpers.value, ['https://link.example', 'https://two.example']);
      expect([told, asUp], [1, [['https://link.example', 'https://two.example']]]);
      expect(() => c.helpers.value.add('https://more.example'), throwsUnsupportedError);
      // The link drops: they are as they were, since that is when they are needed. Signed in again, told again.
      memory.pairs.single.cut();
      await _until(() => c.state.value != CarrierState.up || told == 2, 'the link never dropped');
      expect(c.helpers.value, ['https://link.example', 'https://two.example']);
      await _until(() => c.state.value == CarrierState.up && told == 2, 'it never signed in again');
      expect(c.helpers.value, ['https://link.example', 'https://two.example']);
    });

    test('a hub that names none, or names what is no link helper, gives none: at most four https addresses of 200 characters', () async {
      final none = MemoryHub();
      final plain = HubCarrier(url: none.url, signer: KeysSigner(NetKeys.generate()), dial: none.dial);
      addTearDown(plain.stop);
      var told = 0;
      plain.helpers.addListener(() => told++);
      await _up(plain);
      expect([plain.helpers.value, told], [isEmpty, 1], reason: 'said to have named none: whoever listens is told that too');

      // A hub of somebody else's making, saying whatever it likes.
      Future<List<String>> named(Object? helpers) async {
        final c = HubCarrier(url: 'wss://odd.test/hub', signer: KeysSigner(NetKeys.generate()), dial: (_) async => _OddHub(helpers));
        addTearDown(c.stop);
        await _up(c);
        return c.helpers.value;
      }

      expect(await named('https://link.example'), isEmpty, reason: 'not a list');
      expect(await named({'a': 'https://link.example'}), isEmpty);
      expect(await named(['http://plain.example', 'wss://socket.example', 7, null, ['https://nested.example'], 'https://${'x' * 200}.example', 'https://ok.example']), ['https://ok.example']);
      expect(await named([for (var i = 0; i < 40; i++) 'https://h$i.example']), ['https://h0.example', 'https://h1.example', 'https://h2.example', 'https://h3.example']);
    });

    test('asking whether a relay answers goes by a dial too, and closes without signing in', () async {
      final memory = MemoryHub();
      final yes = await checkRelay(memory.url, connect: memory.dial);
      expect(yes.ok, isTrue, reason: yes.problem);
      expect(memory.dialled, [memory.url]);
      expect(memory.pairs.single.isOpen, isFalse);
      await pumpEventQueue();
      expect(memory.hub.connected, 0);
      memory.down = true;
      final no = await checkRelay(memory.url, connect: memory.dial);
      expect(no.problem, 'Couldn\'t connect: Bad state: nothing answers at ${memory.url}');
    });
  });

  group('dialHub\'s own link, a WebSocket', () {
    late Relay relay;
    late String url;
    setUp(() async {
      relay = Relay(hub: Hub());
      url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
    });
    tearDown(() => relay.stop());

    /// Signs in on a bare link as HubCarrier does: what the hub answers the hello with, and everything it says after.
    Future<({Map answer, List<Object> after, Future<void> done})> signIn(HubLink link, NetKeys keys) async {
      final first = Completer<Object>(), second = Completer<Object>(), done = Completer<void>();
      final after = <Object>[];
      link.said.listen((data) => !first.isCompleted ? first.complete(data) : !second.isCompleted ? second.complete(data) : after.add(data), onDone: done.complete);
      final hello = await first.future.timeout(const Duration(seconds: 5));
      expect(hello, isA<String>(), reason: 'the hub\'s JSON comes as a String');
      final sig = NetCrypto.sign(keys, [...utf8.encode(HubCarrier.greeting), ...NetCrypto.unhex((jsonDecode(hello as String) as Map)['hello'] as String)]);
      link.say(jsonEncode({'id': keys.id, 'key': base64Encode(keys.public), 'sig': base64Encode(sig)}));
      return (answer: jsonDecode(await second.future.timeout(const Duration(seconds: 5)) as String) as Map, after: after, done: done.future);
    }

    test('what the hub says comes as Strings and Uint8Lists, and the link is done when the hub closes it', () async {
      final keys = NetKeys.generate();
      final one = await dialHub(url);
      final first = await signIn(one, keys);
      // With the hub's time and when it started (for what it kept that went with a restart: lib/net/ledger.dart).
      expect(first.answer, {'ok': true, 'held': 0, 'now': isA<int>(), 'since': isA<int>()});
      expect(first.answer['since'] as int, lessThanOrEqualTo(first.answer['now'] as int));
      // A packet to its own name, as a plain list of bytes: nobody else of it is here, so it is held.
      one.say([1, 0, 0, 0, 7, ...NetCrypto.unhex(keys.id), 5, 6]);
      await _until(() => first.after.isNotEmpty, 'the hub never answered the packet');
      expect(jsonDecode(first.after.single as String), {'ack': 7, 'here': false});
      // The same install again takes the first one's place: the first is closed by the hub, and done.
      final two = await dialHub(url);
      final second = await signIn(two, keys);
      expect(second.answer, {'ok': true, 'held': 1, 'now': isA<int>(), 'since': first.answer['since']}, reason: 'the same hub: the same start');
      await first.done.timeout(const Duration(seconds: 5));
      await _until(() => second.after.isNotEmpty, 'what was held never came');
      expect(second.after.single, isA<Uint8List>(), reason: 'a frame comes as a Uint8List');
      expect(second.after.single, [1, ...NetCrypto.unhex(keys.id), 5, 6]);
      await two.close();
      await second.done.timeout(const Duration(seconds: 5));
    });

    test('nobody there: the dial throws, and why is said in dart:io\'s own few words', () async {
      final nobody = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = nobody.port;
      await nobody.close(force: true);
      Object? thrown;
      try {
        await dialHub('ws://127.0.0.1:$port/hub');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<SocketException>());
      expect(dialProblem(thrown!), isNot(contains('127.0.0.1')), reason: 'the message alone, not the address and numbers around it');
      expect(dialProblem(const SocketException('Connection refused', osError: OSError('Connection refused', 61), port: 9)), 'Connection refused');
      expect(dialProblem(const WebSocketException('Connection was not upgraded to websocket')), 'Connection was not upgraded to websocket');
      expect(dialProblem(StateError('no')), 'Bad state: no');
    });
  });
}
