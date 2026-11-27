import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

import '../../test/support/open_space_fakes.dart' show FakeMedia, FakeStore;

/// How long coming into an open space takes before its floor is on the screen, against a relay that is really there
/// (Matt, 2026-11-23: "it took a really long time to load"). Run a relay of this branch first:
///
///     (cd relay && dart run bin/relay.dart --port 18791 --data <a new folder>)
///     flutter test tool/net/open_space_timing_test.dart --dart-define=HUB=ws://127.0.0.1:18791/hub
///
/// For each kind of space, Maya is in the call already and Matt comes in, twice: with his connection to the relay up,
/// and as the app does it just after opening or waking (the room asked for while the connection is still being made;
/// HubCarrier.join waits for it). It says, in ms, when the floor used to be made (once VoiceSession.join returned:
/// before 0.12.21) and when it is made now (as the call is begun), and when each first hears where the other stands.
const hub = String.fromEnvironment('HUB');

Future<void> _up(HubCarrier c) async {
  await c.start();
  for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect to $hub');
}

Future<int> _until(bool Function() ok, Stopwatch w) async {
  while (!ok() && w.elapsedMilliseconds < 20000) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  return ok() ? w.elapsedMilliseconds : -1;
}

void main() {
  for (final kind in [SpaceKind.voice, SpaceKind.open]) {
    for (final cold in [false, true]) {
      test('${kind.name}, the relay ${cold ? 'still being reached' : 'already reached'}', () async {
        expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=ws://…/hub');
        final c = VoiceChannel.make('Plaza', kind: kind);
        final maya = HubCarrier(url: hub, signer: KeysSigner(NetKeys.generate()));
        final matt = HubCarrier(url: hub, signer: KeysSigner(NetKeys.generate()));
        await _up(maya);
        final b = VoiceSession(channel: c, route: HubVoiceRoute(maya), media: FakeMedia(), name: 'Maya');
        await b.join();
        final bFloor = kind == SpaceKind.open ? OpenSpace(b, store: FakeStore(), random: math.Random(2)) : null;
        if (!cold) await _up(matt);

        final w = Stopwatch()..start();
        if (cold) unawaited(matt.start());
        final a = VoiceSession(channel: c, route: HubVoiceRoute(matt), media: FakeMedia(), name: 'Matt');
        // Now: the floor as the call is begun (Voice.join).
        final aFloor = kind == SpaceKind.open ? OpenSpace(a, store: FakeStore(), random: math.Random(1)) : null;
        final floorNow = w.elapsedMilliseconds;
        await a.join();
        // Before: the floor once the join came back.
        final floorBefore = w.elapsedMilliseconds;
        final sawMaya = await _until(() => a.members.containsKey(maya.signer.id), w);
        var heardBoth = -1;
        if (aFloor != null && bFloor != null) {
          heardBoth = await _until(() => aFloor.placeOf(maya.signer.id).said && bFloor.placeOf(matt.signer.id).said, w);
        }
        debugPrint('TIMING ${kind.name} ${cold ? 'cold' : 'warm'}: joined (floor before) $floorBefore ms, floor now $floorNow ms, '
            'Maya in the call $sawMaya ms${aFloor == null ? '' : ', both placed $heardBoth ms'}');
        aFloor?.dispose();
        bFloor?.dispose();
        await a.leave();
        await b.leave();
        await matt.stop();
        await maya.stop();
      });
    }
  }
}
