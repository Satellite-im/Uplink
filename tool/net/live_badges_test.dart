import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

/// The verified-number badge's question against the relay that is really there (relay/lib/handles.dart, `badges`;
/// Matt, 2026-11-19: "add the verfied by number badge as a default feature"): the check run after the relay is
/// deployed. A fresh install asks of itself and a username nobody has, and is told no to both; nothing is kept.
///
///     flutter test tool/net/live_badges_test.dart --dart-define=HUB=wss://gogho.st/hub
const hub = String.fromEnvironment('HUB');

void main() {
  test('badges answered by $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final keys = NetKeys.generate();
    final c = HubCarrier(url: hub, signer: KeysSigner(keys));
    await c.start();
    for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect');
    final got = c.handles.firstWhere((m) => m['dir'] == 'badges' || m['dir'] == 'err').timeout(const Duration(seconds: 30));
    c.sayHandles({'dir': 'badges', 'ids': [keys.id], 'names': ['nobody_has_this_name_x']});
    final answer = await got;
    debugPrint('answer: $answer');
    expect(answer, {'dir': 'badges', 'ids': <Object?>[], 'names': <Object?>[]});
    await c.stop();
  });
}
