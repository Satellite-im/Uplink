import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/relay_host/hosting.dart';

import 'support/direct_world.dart';
import 'support/host_support.dart';

/// A relay hosted from the app, and Direct coming after it (the fourth review's probe, 2026-11-23): Direct's P2p is made
/// when Direct is switched on and dropped when it is switched off (Net.setDirect), and the routes tell the host
/// ([RelayHosting.directChanged]). Before, a host started with Direct off never opened channel 1 on the one made later,
/// and named no link helpers, so joiners over Direct had nothing to find it by until it was started again.

const helper = 'https://link.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  late World w;
  setUp(() => w = World(helpers: const [helper]));
  tearDown(() => w.stop());

  test('a host started with Direct off takes the P2p made when Direct is switched on, and names its link helpers from then on', () async {
    final hostDevice = w.install(w.account('hana'), computer: true);
    P2p? current;
    final host = makeHost(Kept(), timer: w.clock.timer, p2p: () => current);
    addTearDown(host.shutdown);
    await host.setOn(true);
    expect([host.state, host.directBuilt], [HostState.up, false]);
    expect(host.hub!.helpers, isEmpty, reason: 'no Direct, no helpers known');
    expect(host.directHelped, isFalse, reason: 'said on its screen: not findable from afar yet');
    // Direct switched on: the routes make its P2p, and tell the host.
    await hostDevice.start();
    current = hostDevice.p2p;
    host.directChanged();
    await w.until(() => host.directUrl != null, 'no address over Direct while Direct is on');
    expect(host.hub!.helpers, [helper], reason: 'those signing in from now on are told the helpers it is found by');
    expect(host.directHelped, isTrue);
    // Off: the routes drop it, and the host lets it go.
    current = null;
    host.directChanged();
    await w.until(() => host.directUrl == null, 'it kept the dropped one');
  });
}
