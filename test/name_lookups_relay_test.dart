import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

/// Me.whois against a real relay on this machine, over a real socket (the review's probes 6 and 7, 2026-11-23, made
/// tests): each lookup gets its own answer, two of one name at once share one question (S4), a refused lookup fails
/// every one waiting, and the relay counts lookups for the account, all its devices together (what the name watch
/// shares out among them: lib/net/name_watch.dart, S1). And the relay's hash of a name is the app's (Me.nameKeyOf).

Future<void> _until(bool Function() done, {String? reason}) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

class _Install {
  _Install(String url, NetKeys keys) : hub = HubCarrier(url: url, signer: KeysSigner(keys));
  final HubCarrier hub;
  final store = MemoryMeStore();
  final routes = ChangeNotifier();
  late Me me = Me.forTest();

  Future<void> open() async {
    await hub.start();
    await _until(() => hub.state.value == CarrierState.up, reason: hub.problem);
    await me.start(store, routes, () => hub);
  }
}

void main() {
  late Relay relay;
  late int port;
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('lookups');
    relay = Relay(hub: Hub(handles: Handles(dataDir: dir, config: const HandlesConfig(publicUrl: 'http://127.0.0.1'))));
    port = await relay.start(port: 0);
  });
  tearDown(() async {
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  String url() => 'ws://127.0.0.1:$port/hub';

  test('PROBE 6: lookups at once each get their own answer; one refused fails every one waiting; and the relay\'s hash of a name is the app\'s', () async {
    final maya = _Install(url(), NetKeys.generate()), sam = _Install(url(), NetKeys.generate()), asker = _Install(url(), NetKeys.generate());
    await maya.open();
    await sam.open();
    await asker.open();
    await maya.me.claimUsername('maya');
    await sam.me.claimUsername('sam_k');
    final both = await Future.wait([asker.me.whois('maya'), asker.me.whois('@SAM_K'), asker.me.whois('nobody_here')]);
    expect([both[0]?.id, both[1]?.id, both[2]], [maya.hub.signer.id, sam.hub.signer.id, isNull]);
    // Which name a key holds, as the relay keeps it: the app's own hash of it (what the name watch compares).
    expect([await maya.me.heldName(), await asker.me.heldName()], [Me.nameKeyOf('maya'), isNull]);
    expect(Me.nameKeyOf('@Maya'), Handles.nameKey('maya'));
    for (var i = 0; i < 116; i++) {
      await asker.me.whois('filler$i');
    }
    final results = await Future.wait([
      for (final n in ['maya', 'sam_k', 'nobody_here']) asker.me.whois(n).then<Object?>((v) => v?.id ?? 'none', onError: (Object e) => 'refused: $e'),
    ]);
    expect(results[0], maya.hub.signer.id);
    expect(results.skip(1), everyElement(startsWith('refused: Too many lookups')));
  });

  test('S4: two lookups of one name at once share one question and its answer', () async {
    final maya = _Install(url(), NetKeys.generate()), asker = _Install(url(), NetKeys.generate());
    await maya.open();
    await asker.open();
    await maya.me.claimUsername('maya');
    for (var i = 0; i < 118; i++) {
      await asker.me.whois('filler$i');
    }
    final twice = await Future.wait([asker.me.whois('maya'), asker.me.whois('@Maya')]);
    expect([twice[0]?.id, twice[1]?.id], [maya.hub.signer.id, maya.hub.signer.id]);
    // One question was asked for both (119 in all): one more is answered, the next is refused.
    expect((await asker.me.whois('one_more'))?.id, isNull);
    await expectLater(asker.me.whois('too_many'), throwsA(isA<MeError>()));
  });

  test('PROBE 7: the relay counts lookups for the account, not the device: what one device of an account used is gone for the next', () async {
    final keys = NetKeys.generate();
    final phone = _Install(url(), keys);
    await phone.open();
    for (var i = 0; i < 110; i++) {
      await phone.me.whois('nobody$i');
    }
    await phone.hub.stop();
    // Another device of the same account (the same identity, as an account's sign-in makes it).
    final mac = _Install(url(), keys);
    await mac.open();
    var ok = 0;
    Object? refused;
    for (var i = 0; i < 20; i++) {
      try {
        await mac.me.whois('other$i');
        ok++;
      } catch (e) {
        refused = e;
        break;
      }
    }
    expect(ok, 10, reason: 'the Mac had only what the phone left of 120');
    expect('$refused', contains('Too many lookups'));
  });
}
