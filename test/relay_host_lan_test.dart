import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/home_record.dart';
import 'package:ghost_messaging/net/homes.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/relay_host/hosting.dart';
import 'package:ghost_relay/fed_dial.dart' show connectPinned;

import 'support/host_support.dart';

/// A relay hosted from the app, over real sockets and in other processes (lib/relay_host; docs/OPEN_NETWORK.md, section
/// 5): a device on the same network signs in at `ws://address:port/hub` from a process of its own and talks with this
/// app, which is on the relay in memory; and the relay keeps its link to a public relay, a real one started here with
/// `GHOST_FED=open` (gogho.st won't take the link yet), over which someone on each reaches the other. Everything on this
/// machine alone.

/// The `dart` beside the Flutter running this test.
String get _dart {
  final root = Platform.environment['FLUTTER_ROOT'];
  return root == null ? 'dart' : '$root${Platform.pathSeparator}bin${Platform.pathSeparator}dart';
}

/// A process's output a line at a time, and a way to wait for a line that matches.
class _Lines {
  _Lines(Process p) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(lines.add);
    p.stderr.transform(utf8.decoder).listen(errors.write);
  }
  final lines = <String>[];
  final errors = StringBuffer();

  Future<String> next(RegExp pattern, String what, {Duration most = const Duration(seconds: 90)}) async {
    await waitFor(() => lines.any(pattern.hasMatch), '$what (said: $lines; errors: $errors)', most: most);
    return lines.firstWhere(pattern.hasMatch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('a device on the same network signs in from a process of its own at ws://address:port/hub, and it and this app reach each other; stopped, it sees its relay gone', () async {
    final host = makeHost(Kept(), lan: true);
    addTearDown(host.shutdown);
    await host.setOn(true);
    expect(host.problem, isNull);
    final url = host.lanUrls.single;
    expect(url, matches(RegExp(r'^ws://127\.0\.0\.1:\d+/hub$')));
    final mine = OnHost(host);
    await mine.up();

    final other = await Process.start(_dart, ['test/support/lan_install.dart', url]);
    addTearDown(() => other.kill(ProcessSignal.sigkill));
    final said = _Lines(other);
    final id = (await said.next(RegExp(r'^ID [0-9a-f]{32}$'), 'the other device never signed in')).substring(3);
    expect(host.connections, 2);
    expect(host.hub!.signsV2(id), isTrue, reason: 'bound to the address it dialled on this network');

    expect(await mine.carrier.send(Peer(id: id), Uint8List.fromList([1, 2, 3])), Handed.passed);
    await said.next(RegExp('^GOT ${mine.id} 010203\$'), 'what this app sent never reached the other process');
    await waitFor(() => mine.got.isNotEmpty, 'its answer never came back to this app');
    expect([mine.got.single.from, mine.got.single.bytes], [id, [3, 2, 1]]);

    // Stopped: the device on the network finds its connection closed.
    await host.setOn(false);
    await said.next(RegExp(r'^CLOSED$'), 'the other device never saw its relay go');
    expect(await other.exitCode.timeout(const Duration(seconds: 30)), 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('it stays linked to a public relay (a real one, GHOST_FED=open), and someone on each reaches the other through the link', () async {
    // A port for the public relay, known before it starts: its own address is part of its settings.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final via = 'ws://127.0.0.1:$port/hub';
    final data = await Directory.systemTemp.createTemp('relay-public-');
    addTearDown(() => data.delete(recursive: true));
    final relay = await Process.start(_dart, ['bin/relay.dart', '--host', '127.0.0.1', '--port', '$port', '--data', data.path],
        workingDirectory: 'relay', environment: {'GHOST_FED': 'open', 'GHOST_FED_STANDING': 'open', 'GHOST_PUBLIC_HUB': via}, includeParentEnvironment: false);
    addTearDown(() => relay.kill(ProcessSignal.sigkill));
    final relayLines = _Lines(relay);
    await relayLines.next(RegExp('listening on ws://127\\.0\\.0\\.1:$port'), 'the public relay never started');

    // The hosted relay dials it as a relay with no address does: out, and asks to stay. (Its own guard dials only public
    // addresses on 443, so a test hands it one to this machine.)
    final host = makeHost(Kept(), via: via, viaPlain: true, viaPorts: {port}, viaDial: (uri) => connectPinned(uri, InternetAddress.loopbackIPv4));
    addTearDown(host.shutdown);
    await host.setOn(true);
    await waitFor(() => host.viaLink.kind == ViaKind.stays, 'it never linked to the public relay, or wasn\'t let stay: ${host.viaLink.kind} ${host.viaLink.said}');

    // Xena on the hosted relay, in memory; Zed on the public one, over a WebSocket. Each install's own code makes and
    // gives its home record (lib/net/homes.dart) and is given the other's, as friends are.
    Homes homesFor(HubCarrier c, NetKeys keys) {
      final kept = <String, String>{};
      return Homes(signer: KeysSigner(keys), read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v)..attach(c);
    }

    final xena = OnHost(host);
    final xenaHomes = homesFor(xena.carrier, xena.keys);
    await xena.up();
    final zedKeys = NetKeys.generate();
    final zed = HubCarrier(url: via, signer: KeysSigner(zedKeys), retry: const Duration(milliseconds: 50));
    final zedGot = <Arrived>[];
    zed.arrived.listen(zedGot.add);
    final zedHomes = homesFor(zed, zedKeys);
    await zed.start();
    await waitFor(() => zed.state.value == CarrierState.up, 'Zed never signed in to the public relay: ${zed.problem}');
    await waitFor(() => xenaHomes.mine != null && zedHomes.mine != null, 'their home records were never made');
    expect(xenaHomes.mine!.h, [hostedAddress(host.relayId!, via)], reason: 'Xena lives on the hosted relay, reached through the public one');
    expect(zedHomes.mine!.h, [via]);
    xenaHomes.give(zedHomes.mine!.toJson());
    zedHomes.give(xenaHomes.mine!.toJson());

    /// Sends until a relay takes it: the records are given a moment before.
    Future<Handed> sendTaken(HubCarrier from, String to, List<int> packet) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        try {
          return await from.send(Peer(id: to), Uint8List.fromList(packet));
        } on CarrierError {
          if (DateTime.now().isAfter(end)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }

    // From the hosted relay to the public one: over the link it dialled.
    await sendTaken(xena.carrier, zedKeys.id, [5, 5, 5]);
    await waitFor(() => zedGot.isNotEmpty, 'what Xena sent never reached Zed');
    expect([zedGot.single.from, zedGot.single.bytes], [xena.id, [5, 5, 5]]);
    expect(xena.carrier.passedOn(zedKeys.id), isTrue, reason: 'passed to another relay');
    // And back: the public relay passes it over the same link, which nothing reached in to make.
    await sendTaken(zed, xena.id, [6, 6]);
    await waitFor(() => xena.got.isNotEmpty, 'what Zed sent never reached Xena');
    expect([xena.got.single.from, xena.got.single.bytes], [zedKeys.id, [6, 6]]);
    expect(zed.passedOn(xena.id), isTrue);

    await zed.stop();
    xenaHomes.dispose();
    zedHomes.dispose();
    await xena.carrier.stop();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
