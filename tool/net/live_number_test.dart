import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

/// Verifying a phone number against the relay that is really there, and the texting service behind it (docs/me.md,
/// "A phone number"): the check run after the relay is deployed with the service's values.
///
///     flutter test tool/net/live_number_test.dart --dart-define=HUB=wss://gogho.st/hub
///         says whether the server can text a code (its hello: "phone": "text"), and sends nothing
///     … --dart-define=NUMBER=+15550100199
///         also has a code texted to that number (it costs a text; only a number whose owner asked for it)
///     … --dart-define=NUMBER=+15550100199 --dart-define=CODE=482913
///         says the code that arrived back, and the number is linked to this made-up install, then unlinked
///
/// The install is a key pair kept in build/live-number.key between the runs, as only the install a code was sent
/// for may try it. Nothing it does is kept by the server once it ends but the hours' counts of texts asked for.
const hub = String.fromEnvironment('HUB');
const number = String.fromEnvironment('NUMBER');
const code = String.fromEnvironment('CODE');

void main() {
  test('a number verified through $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final file = File('build/live-number.key');
    final keys = file.existsSync() ? NetKeys.fromScalar(NetCrypto.unhex(file.readAsStringSync().trim())) : NetKeys.generate();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(NetCrypto.hex(keys.scalar));

    final c = HubCarrier(url: hub, signer: KeysSigner(keys));
    await c.start();
    for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect');
    final heard = StreamController<Map<String, dynamic>>.broadcast();
    final sub = c.handles.listen(heard.add);
    Future<Map<String, dynamic>> ask(Map<String, Object?> what, Set<String> answers) {
      final got = heard.stream.firstWhere((m) => answers.contains(m['dir'])).timeout(const Duration(seconds: 30));
      c.sayHandles(what);
      return got;
    }

    final hello = await ask({'dir': 'hello'}, {'hello'});
    debugPrint('ways: ${hello['ways']}');
    expect((hello['ways'] as Map)['phone'], 'text', reason: 'the server cannot text a code');

    if (number.isNotEmpty && code.isEmpty) {
      final sent = await ask({'dir': 'text', 'p': 'phone', 'handle': number}, {'text', 'err'});
      debugPrint('asked for a code: $sent');
      expect(sent['dir'], 'text');
    }
    if (number.isNotEmpty && code.isNotEmpty) {
      final linked = await ask({'dir': 'code', 'p': 'phone', 'handle': number, 'code': code}, {'linked', 'err'});
      debugPrint('the code back: ${linked['dir']} ${linked['err'] ?? ''}');
      expect(linked['dir'], 'linked');
      final gone = await ask({'dir': 'unlink', 'p': 'phone'}, {'unlinked'});
      debugPrint('unlinked again: ${gone['dir']}');
      file.deleteSync();
    }
    await sub.cancel();
    await c.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
