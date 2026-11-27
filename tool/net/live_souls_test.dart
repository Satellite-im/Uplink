import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

/// Souls and the admin page on a live relay (relay/lib/handles.dart; Matt, 2026-11-19: "Build a new points system into
/// the app called souls ... make sure only my matt account can access it"), as a fresh install sees them: hello says
/// its souls, `souls?` answers, and the admin page answers nothing to an install that isn't @matt's, whatever it says.
///
///     flutter test tool/net/live_souls_test.dart --dart-define=HUB=wss://gogho.st/hub
const hub = String.fromEnvironment('HUB');

void main() {
  test('a fresh install has no souls, and the admin page refuses it, at $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final c = HubCarrier(url: hub, signer: KeysSigner(NetKeys.generate()));
    final heard = <Map<String, dynamic>>[];
    final sub = c.handles.listen(heard.add);
    await c.start();
    for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect');

    Future<Map<String, dynamic>> ask(Map<String, Object?> what, String answer) async {
      final from = heard.length;
      c.sayHandles(what);
      for (var i = 0; i < 400; i++) {
        final got = heard.skip(from).where((m) => m['dir'] == answer).firstOrNull;
        if (got != null) return got;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw StateError('no "$answer" from $hub');
    }

    final hello = await ask({'dir': 'hello'}, 'hello');
    expect(hello['souls'], 0, reason: 'the relay says souls on hello');
    expect(hello['special'], isEmpty);
    expect((await ask({'dir': 'souls?'}, 'souls'))['n'], 0);
    expect((await ask({'dir': 'admin-login', 'user': 'anyone', 'pass': 'anything'}, 'admin'))['ok'], false);
    expect((await ask({'dir': 'admin-users'}, 'admin-users'))['ok'], false, reason: 'not signed in, and not @matt');
    await sub.cancel();
    await c.stop();
  });
}
