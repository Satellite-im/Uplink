import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';
import 'package:ghost_relay/fed_dial.dart' show connectPinned;
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

import 'hub_pair.dart';

/// What the tests of a relay hosted from the app stand on (test/relay_host_test.dart and the rest): a host as the app
/// makes one, but for what it keeps and where, and installs on it in memory.

/// What the app keeps for the host: its choices and its secrets.
class Kept {
  final choices = <String, String>{};
  final secrets = <String, String>{};
  String get hubUrl => (choices['net_hub'] ?? '').isEmpty ? Net.defaultHub : choices['net_hub']!;
}

/// A host as the app makes one, but for what it keeps ([k]) and where: a folder of its own for the test ([folder]),
/// made and deleted with it where none is given, as the app always has one (its key, and so its name, outlives a stop).
/// The local network's door is shut unless [lan], and listens at [port] (0: any free one) on this machine alone.
RelayHost makeHost(Kept k, {Directory? folder, bool phone = false, Timer Function(Duration, void Function())? timer, P2p? Function()? p2p, int port = 0, bool lan = false, String? via, FedDial? viaDial, Set<int> viaPorts = const {}, bool viaPlain = false, Future<List<String>> Function()? addresses}) {
  k.choices[RelayHost.portKey] = '$port';
  if (!lan) k.choices[RelayHost.lanKey] = 'off';
  final dir = folder ?? Directory.systemTemp.createTempSync('relay-host-');
  if (folder == null) addTearDown(() => dir.deleteSync(recursive: true));
  return RelayHost(
    read: (key) => k.choices[key] ?? '',
    write: (key, v) => k.choices[key] = v,
    secretRead: (n) async => k.secrets[n],
    secretKeep: (n, v) async => k.secrets[n] = v,
    folder: () async => dir,
    p2p: p2p ?? () => null,
    phone: phone,
    timer: timer,
    via: via,
    viaDial: viaDial,
    viaPorts: viaPorts,
    viaPlain: viaPlain,
    addresses: addresses,
    hubUrl: () => k.hubUrl,
    useRelay: (url) async {
      k.choices['net_hub'] = url;
      return null;
    },
    moveBack: (url) async => k.choices['net_hub'] = url,
    forgetHub: (url) => k.choices['net_hub'] = url,
    passChanged: () {},
  );
}

/// Waits for [ok], however long the machine takes ([most] at most), not for a length of time.
Future<void> waitFor(bool Function() ok, String what, {Duration most = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(most);
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue, reason: what);
}

/// An install on the relay this device hosts, in memory: its key and its route, dialled as the app dials its own.
/// Another device's way in to [host], in memory: attached as anyone's (asked for the pass phrase), signed for as reached
/// by the relay's name, as this app's own address names it.
Future<HubLink> _strangerDial(RelayHost host) async {
  final pair = HubPair();
  host.hub!.attach(pair.socket, reachedAs: host.relayId);
  return pair.link;
}

class OnHost {
  /// This app on [host], in memory ([RelayHost.dialHere]: the keeper's own, never asked for the pass phrase); with
  /// [stranger], another device's way in, in memory too but attached as anyone's, so asked as anyone is.
  OnHost(RelayHost host, {String? Function()? pass, HubDial? dial, bool stranger = false}) : keys = NetKeys.generate() {
    carrier = HubCarrier(url: host.ownUrl!, signer: KeysSigner(keys), retry: const Duration(milliseconds: 20), dial: (url) {
      dials++;
      return (dial ?? (stranger ? (_) => _strangerDial(host) : (_) => host.dialHere()))(url);
    })
      ..pass = pass;
    carrier.arrived.listen(got.add);
  }
  final NetKeys keys;
  late final HubCarrier carrier;
  final got = <Arrived>[];
  int dials = 0;
  String get id => keys.id;
  Future<void> up() async {
    await carrier.start();
    await waitFor(() => carrier.state.value == CarrierState.up, 'never signed in: ${carrier.problem}');
  }
}

/// A public relay in this process, on this machine, that lets relays hosted from an app stay linked to it (GHOST_FED
/// open, standing links open): what a hosted relay must be linked to before it is offered for use. [via] is its hub's
/// address; [host] makes a hosted relay's settings for it ([viaPlain], [viaPorts], [viaDial]).
class PublicRelay {
  PublicRelay._(this.relay, this.port);
  final Relay relay;
  final int port;
  String get via => 'ws://127.0.0.1:$port/hub';

  /// A hosted relay's way to dial it.
  Future<HubSocket> viaDial(Uri uri) => connectPinned(uri, InternetAddress.loopbackIPv4);

  static Future<PublicRelay> start() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final via = 'ws://127.0.0.1:$port/hub';
    final fed = Federation(config: FedConfig(mode: FedMode.open, publicHub: via, standingOpen: true));
    final relay = Relay(hub: Hub(federation: fed));
    await relay.start(port: port);
    final r = PublicRelay._(relay, port);
    addTearDown(relay.stop);
    return r;
  }
}
