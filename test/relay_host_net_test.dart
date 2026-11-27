import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart' show AccountBackup;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/me/me.dart' show MemoryMeStore;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/relay_choice.dart';
import 'package:ghost_messaging/relay_host/address.dart';
import 'package:ghost_messaging/relay_host/hosting.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

import 'support/fake_p2p.dart';
import 'support/host_support.dart';
import 'support/hub_pair.dart';

/// A relay hosted from the app, as the routes hold it (lib/net/net.dart; lib/relay_host): started as the routes start,
/// before the relay's route dials it; reached through dialHub; kept to on a move by the direct route's link helpers;
/// stopped at sign-out, and on Android a minute after the app is put away.

/// An account's install with nothing behind it: signing out is all it is asked.
class _Install implements AccountPort, AccountRelay, AccountProfiles {
  final secrets = <String, String>{};
  @override
  String get hubId => 'ab' * 16;
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async => throw AccountError('no relay here');
  @override
  Future<Uint8List> identityExport() async => NetKeys.generate().scalar;
  @override
  Future<void> identityImport(List<int> scalar, List<int> public) async {}
  @override
  Future<void> secretKeep(String name, String value) async => value.isEmpty ? secrets.remove(name) : secrets[name] = value;
  @override
  Future<String?> secretRead(String name) async => secrets[name];
  @override
  Future<bool> restart() async => true;
  @override
  Future<bool> identityForget() async => true;
  @override
  Future<void> wipeHere(String note) async {}
  @override
  bool get fresh => true;
  @override
  String get deviceName => 'Test';
  @override
  AccountBackup fill(AccountBackup backup) => backup;
  @override
  Future<void> apply(AccountBackup backup) async {}
  @override
  Future<void> forget() async {}
  @override
  Future<void> stopAll() async {}
  @override
  Future<void> wipe() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NetKeys me;
  late Map<String, String> secrets;
  late Directory folder;
  setUp(() {
    HttpOverrides.global = null;
    me = NetKeys.generate();
    secrets = {};
    folder = Directory.systemTemp.createTempSync('relay-host-net-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final a = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (a['message'] as List).cast<int>());
        case 'netPeers':
          return const <Object>[];
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${a['value'] ?? ''}';
          value.isEmpty ? secrets.remove('${a['name']}') : secrets['${a['name']}'] = value;
          return null;
        case 'secretRead':
          return secrets['${a['name']}'];
      }
      return null;
    });
  });
  tearDown(() async {
    await Net.instance.shutdown();
    Net.relayHostMaker = makeRelayHost;
    Net.p2pNode = null;
    folder.deleteSync(recursive: true);
  });

  /// The routes' own host, as the app makes it, but for its folder (and, where given, its clock and kind of device).
  RelayHost hostHere({bool phone = false, FakeClock? clock}) => RelayHost(folder: () async => folder, phone: phone, timer: clock?.timer);

  test('with hosting on, the routes start it before their relay\'s route dials it: this app, on it, signs in in memory', () async {
    // Started once, to have a name (its key is kept in its folder).
    final first = hostHere();
    final app = AppState()..set(RelayHost.lanKey, 'off');
    Net.relayHostMaker = () => first;
    await Net.instance.start(app);
    await first.setOn(true);
    final own = first.ownUrl!;
    await Net.instance.shutdown();
    expect([first.state, first.on], [HostState.off, true], reason: 'it stops with the routes, as the app closes; the choice stays');
    // The app opened again, its relay the one on this device.
    app.set('net_hub', own);
    Net.relayHostMaker = hostHere;
    await Net.instance.start(app);
    final host = Net.instance.relayHost!;
    await waitFor(() => host.state == HostState.up, 'it never started');
    expect([host.state, host.relayId, Net.instance.hostedHere], [HostState.up, first.relayId, first.relayId]);
    expect(relayInUseWords(Net.instance.hubUrl), 'The relay on this device');
    await Net.instance.want('test', true);
    await waitFor(() => Net.instance.hub!.state.value == CarrierState.up, 'this app never signed in to its own relay: ${Net.instance.hub!.problem}');
    expect([host.connections, host.inUse], [1, true]);
    expect((host as RelayHost).hub!.signsV2(me.id), isTrue);
    await Net.instance.want('test', false);
  });

  test('moving onto a relay hosted from an app keeps the direct route\'s link helpers, which it is reached by; any other relay\'s take their place', () async {
    final mesh = FakeP2pMesh();
    final node = mesh.node();
    Net.p2pNode = () => node;
    final one = Relay(hub: Hub(helpers: ['https://link.one.example']));
    final first = 'ws://127.0.0.1:${await one.start(port: 0)}/hub';
    addTearDown(one.stop);
    final app = AppState()..set('net_hub', first)..set(Net.directName, 'on');
    await Net.instance.start(app);
    await Net.instance.want('test', true);
    final p2p = Net.instance.p2p!;
    await waitFor(() => Net.instance.hub!.state.value == CarrierState.up && p2p.loaded && p2p.helpers.isNotEmpty, 'never signed in to the first relay');
    // Someone's relay, reached over Direct: the helpers stay as they are.
    final theirs = GhostRelayAddress(relay: 'ab' * 16, node: 'cd' * 32, via: Net.defaultHub);
    await Net.instance.setHub('$theirs');
    expect(Net.instance.hubUrl, '$theirs');
    expect(p2p.helpers, ['https://link.one.example']);
    // Another relay: the helpers in use are let go at once.
    await Net.instance.setHub('ws://127.0.0.1:1/hub');
    expect(p2p.helpers, isEmpty);
    await Net.instance.want('test', false);
  });

  test('on a relay hosted from an app, a hub that names no link helpers doesn\'t take away those its Direct connection runs on', () async {
    final mesh = FakeP2pMesh();
    final node = mesh.node();
    Net.p2pNode = () => node;
    final one = Relay(hub: Hub(helpers: ['https://link.one.example']));
    final first = 'ws://127.0.0.1:${await one.start(port: 0)}/hub';
    addTearDown(one.stop);
    await Net.instance.start(AppState()..set('net_hub', first)..set(Net.directName, 'on'));
    await Net.instance.want('test', true);
    final p2p = Net.instance.p2p!;
    await waitFor(() => p2p.loaded && p2p.helpers.isNotEmpty, 'never signed in to the first relay');
    // A hosted relay whose keeper's relay named no helpers, reached (here) in memory in Direct's place.
    // (A relay of its own name: the one an address names must be the one that answers.)
    final fed = Federation(config: const FedConfig(mode: FedMode.list, via: Net.defaultHub), dial: (_) => Future.error(StateError('no via here')));
    final hub = Hub(federation: fed);
    // As the relay in an app attaches a Direct connection: signed for as reached at its node.
    HubDials.hosted = (url) async {
      final pair = HubPair();
      hub.attach(pair.socket, reachedAs: 'cd' * 32);
      return pair.link;
    };
    final url = '${GhostRelayAddress(relay: fed.id, node: 'cd' * 32, via: Net.defaultHub)}';
    await Net.instance.setHub(url);
    await waitFor(() => Net.instance.hub!.state.value == CarrierState.up, 'never signed in to the hosted relay');
    await pumpEventQueue();
    expect(Net.instance.hub!.helpers.value, isEmpty, reason: 'it said it names none');
    expect(p2p.helpers, ['https://link.one.example']);
    await Net.instance.want('test', false);
  });

  test('signing out stops the relay on this device and switches it off, forgets its phrase and the phrase given for another\'s, and sets this app\'s relay back', () async {
    final app = AppState()..set(RelayHost.lanKey, 'off');
    Net.relayHostMaker = hostHere;
    await Net.instance.start(app);
    final host = Net.instance.relayHost!;
    await host.setOn(true);
    await host.setPass('the phrase of whoever signs out');
    expect(await host.useHere(), isNull);
    expect(Net.instance.hubUrl, host.ownUrl);
    final install = _Install()..secrets[Net.joinPassName] = jsonEncode({'u': 'ws://10.0.0.5:7787/hub', 'p': 'someone else\'s'});
    final account = Account(relay: install, port: install, store: MemoryMeStore(), profiles: install);
    expect(await account.signOut(), isTrue);
    expect([host.on, host.state, host.hasPass, secrets[RelayHost.passKey]], [false, HostState.off, false, null]);
    expect(app.choice('net_hub', 'unset'), '', reason: 'back to Uplink\'s own, as before it moved');
    expect(install.secrets.containsKey(Net.joinPassName), isFalse);
    expect(File('${folder.path}/relay-key.json').existsSync(), isTrue, reason: 'its folder stays');
  });

  test('on a phone, put away for a minute it stops, and back it starts again', () async {
    final clock = FakeClock();
    final app = AppState()..set(RelayHost.lanKey, 'off')..set(RelayHost.onKey, 'on');
    Net.relayHostMaker = () => hostHere(phone: true, clock: clock);
    await Net.instance.start(app);
    final host = Net.instance.relayHost!;
    await waitFor(() => host.state == HostState.up, 'it never started');
    // Only inactive (split screen, the shade, a call's screen): away for presence, not for the relay (the second
    // review, 2026-11-23: it stopped a minute on).
    Net.instance.setAway(true, hostAway: hostAwayIn(AppLifecycleState.inactive));
    await clock.pass(const Duration(minutes: 2));
    await pumpEventQueue();
    expect(host.state, HostState.up, reason: 'inactive is not put away');
    Net.instance.setAway(false, hostAway: false);
    Net.instance.setAway(true, hostAway: hostAwayIn(AppLifecycleState.paused));
    await clock.pass(const Duration(minutes: 1));
    await waitFor(() => host.state == HostState.off, 'it never stopped');
    expect(host.on, isTrue);
    Net.instance.setAway(false);
    await waitFor(() => host.state == HostState.up, 'it never started again');
  });

  test('the routes don\'t wait for the relay on this device to start: a slow start holds up no route (the second review, 2026-11-23)', () async {
    final never = Completer<Directory?>();
    final app = AppState()..set(RelayHost.lanKey, 'off')..set(RelayHost.onKey, 'on');
    Net.relayHostMaker = () => RelayHost(folder: () => never.future);
    await Net.instance.start(app).timeout(const Duration(seconds: 20));
    expect(Net.instance.relayHost!.state, HostState.starting, reason: 'still starting, and the routes up all the same');
    never.complete(folder);
    await waitFor(() => Net.instance.relayHost!.state == HostState.up, 'it never started once its folder came');
  });

  test('Direct switched on after the relay on this device started: it opens channel 1 on it; off and on again, on the new one (the fourth review, 2026-11-23)', () async {
    final mesh = FakeP2pMesh();
    Net.p2pNode = () => mesh.node();
    final app = AppState()..set(RelayHost.lanKey, 'off')..set(RelayHost.onKey, 'on')..set(Net.directName, 'off');
    Net.relayHostMaker = hostHere;
    await Net.instance.start(app);
    final host = Net.instance.relayHost!;
    await waitFor(() => host.state == HostState.up, 'it never started');
    expect([host.directBuilt, host.directUrl], [false, null]);
    await Net.instance.want('test', true);
    await Net.instance.setDirect(true);
    await waitFor(() => host.directUrl != null, 'Direct switched on, and the relay never had an address over it ("Bringing Direct up…" for good)');
    final first = Net.instance.p2p;
    await Net.instance.setDirect(false);
    await waitFor(() => host.directUrl == null && !host.directBuilt, 'Direct switched off, and the relay kept the dropped one');
    await Net.instance.setDirect(true);
    await waitFor(() => host.directUrl != null, 'switched on again, the relay never took the new one');
    expect(identical(Net.instance.p2p, first), isFalse, reason: 'a new one, which it took');
    await Net.instance.want('test', false);
  });

  test('a relay hosted from an app is dialled as the routes say; with nothing to say how, it is refused in words', () async {
    final was = HubDials.hosted;
    HubDials.hosted = null;
    addTearDown(() => HubDials.hosted = was);
    final address = '${GhostRelayAddress(relay: 'ab' * 16, node: 'cd' * 32)}';
    Object? failed;
    try {
      await dialHub(address);
    } catch (e) {
      failed = e;
    }
    expect(failed, isA<HubDialRefused>());
    expect(dialProblem(failed!), 'A relay hosted from someone\'s app can\'t be reached from here.');
    expect((await checkRelay(address)).problem, 'Couldn\'t connect: A relay hosted from someone\'s app can\'t be reached from here.');
    // And with the routes up, someone else's is dialled over Direct, which this build doesn't have.
    await Net.instance.start(AppState());
    expect((await checkRelay(address)).problem, startsWith('Couldn\'t connect: This device has no Direct route'));
    expect(P2pChannel.hub, 1);
  });
}
