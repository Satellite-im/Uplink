import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/pushes.dart';
import 'package:ghost_relay/relay.dart';

/// An iPhone's push token reaches the relay server (Matt, 2026-11-16: "Yes, wake-ups"; lib/standalone/wake.dart):
/// said on the hub route when it comes, again on every sign-in, and forgotten when the app says so.
Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(ok(), isTrue);
}

void main() {
  late Relay relay;
  late Pushes pushes;
  late Directory dir;
  late String url;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('push_wake');
    pushes = Pushes(dataDir: dir, send: (_, _) async => true);
    relay = Relay(hub: Hub(pushes: pushes));
    url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
  });
  tearDown(() async {
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  test('a token set before the route is up is said on signing in; one set after, at once; null forgets it', () async {
    final hub = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 100));
    hub.push = {'apns': 'ab' * 80, 'sandbox': true};
    await hub.start();
    await _until(() => hub.state.value == CarrierState.up);
    await _until(() => pushes.registered == 1);
    hub.push = {'apns': 'cd' * 80, 'sandbox': false};
    await _until(() => File('${dir.path}/pushes.json').readAsStringSync().contains('cd' * 80));
    hub.push = null;
    await _until(() => pushes.registered == 0);
    await hub.stop();
  });

  test('a server that lost it hears it again on the next sign-in', () async {
    final hub = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 100));
    hub.push = {'apns': 'ef' * 80, 'sandbox': true};
    await hub.start();
    await _until(() => pushes.registered == 1);
    pushes.said(hub.signer.id, null);
    expect(pushes.registered, 0);
    await hub.stop();
    await hub.start();
    await _until(() => pushes.registered == 1);
    await hub.stop();
  });

  test('nothing said when there was never a token', () async {
    final hub = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()));
    hub.push = null;
    await hub.start();
    await _until(() => hub.state.value == CarrierState.up);
    expect(pushes.registered, 0);
    await hub.stop();
  });
}
