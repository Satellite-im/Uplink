import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/net.dart';

/// The relay server is dialled for Settings › Me even with nobody encryption is on with (Matt, 2026-11-14: "it's not
/// conecting to the relay it seems it says I can't verify my number until it connects to the relay which should be
/// live"). Until then the routes started only for people to reach, and a phone with none never reached the relay.
class _Counted implements Carrier {
  _Counted(this.id);
  @override
  final String id;
  int starts = 0, stops = 0;
  bool running = false;
  @override
  String get name => id;
  @override
  String get about => '';
  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: 4096);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;
  @override
  Stream<Arrived> get arrived => const Stream.empty();
  @override
  Future<void> start() async {
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
  }

  @override
  bool reaches(Peer peer) => running;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async => Handed.passed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  List<Map<String, Object?>> peers = [];
  setUp(() {
    peers = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'netIdentity':
          return {'id': '0f' * 16, 'key': 'AlFcPW655Ja5BNP+yn9U/c0MwemXvzddylFa0KbDtANf'};
        case 'netPeers':
          return peers;
        case 'netSmsDrain':
          return const <Object>[];
      }
      return null;
    });
  });
  tearDown(() => Net.instance.shutdown());

  test('with nobody to reach nothing dials out, until something needs the relay server; then the hub alone does', () async {
    final hub = _Counted('hub'), sms = _Counted('sms');
    await Net.instance.start(AppState(), carriers: [hub, sms]);
    expect(hub.running, isFalse, reason: 'nobody to reach and nothing that needs the relay server');
    expect(sms.running, isFalse);

    await Net.instance.want('me', true);
    expect(hub.running, isTrue, reason: 'Settings › Me needs the relay server');
    expect(sms.running, isFalse, reason: 'texts are for people to reach, and there are none');

    // Said twice, it is one need.
    await Net.instance.want('me', true);
    expect(hub.starts, 1);

    await Net.instance.want('me', false);
    expect(hub.running, isFalse, reason: 'nothing needs it any more');
  });

  test('a hub switched off in Settings › Network stays off whatever needs it', () async {
    final hub = _Counted('hub'), sms = _Counted('sms');
    await Net.instance.start(AppState(), carriers: [hub, sms]);
    await Net.instance.setRoute('hub', false);
    await Net.instance.want('me', true);
    expect(hub.running, isFalse);
  });

  test('a route switched off can be switched on again, with nobody to reach', () async {
    // Matt, 2026-11-14: "I also can't toggle the relay server back on or SMS".
    final hub = _Counted('hub'), sms = _Counted('sms');
    final app = AppState();
    await Net.instance.start(app, carriers: [hub, sms]);
    await Net.instance.setRoute('hub', false);
    await Net.instance.setRoute('sms', false);
    expect(Net.instance.board!.off, containsAll(['hub', 'sms']));
    await Net.instance.setRoute('hub', true);
    await Net.instance.setRoute('sms', true);
    // Both switches stay on. Direct is the one route that starts off, by its own choice (net_direct, never net_off),
    // so it is still listed off: nothing switched it on.
    expect(Net.instance.board!.off, {'p2p'}, reason: 'both switches stay on');
    expect(app.choice('net_off', 'x'), '');
    // And with Settings › Me wanting the relay server, the hub dials once it is on again.
    await Net.instance.want('me', true);
    expect(hub.running, isTrue);
    expect(sms.running, isFalse, reason: 'nobody to text');
  });

  test('Settings › Me asks for the relay server as it opens, and from the start once it has been used', () async {
    final asked = <bool>[];
    final store = MemoryMeStore();
    final first = Me.forTest();
    await first.start(store, ChangeNotifier(), () => null, needHub: asked.add);
    expect(asked, isEmpty, reason: 'nothing has been said to the relay server yet: it is not dialled for this');
    first.wake();
    expect(asked, [true], reason: 'the page was opened');

    // Once anything has been linked or watched, it is asked for as the app starts.
    store.set('me_listed', 'on');
    final again = <bool>[];
    await Me.forTest().start(store, ChangeNotifier(), () => null, needHub: again.add);
    expect(again, [true]);
  });
}
