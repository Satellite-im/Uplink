import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/ui/sms_space_ui.dart';
import 'package:ghost_messaging/voice/voice.dart' show SpaceKind;

import 'support/space_call_harness.dart';

/// An SMS space's members, you first (Matt, 2026-11-19: "I created an SMS space but I don't see a list of members
/// including myself I should at the very least be included on the text list since I have my phone number linked").
void main() {
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  for (final texter in [true, false]) {
    testWidgets('the members list has you first, and says how the space reaches you (${texter ? 'your phone texts for it' : 'another\'s phone does'})', (tester) async {
      final me = NetKeys.generate(), other = NetKeys.generate();
      Circles.instance.signerOverride = KeysSigner(me);
      final owner = texter ? me : other;
      final space = CircleSpace(seed: '8a' * 32, name: 'Texts', kind: SpaceKind.text, extra: {'sms': {'by': owner.id}});
      final c = Circle(
        seed: '8' * 64,
        owner: NetCrypto.hex(owner.public),
        manifest: CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Family', spaces: [space]),
      );
      Circles.instance.join(c);
      final h = await SpaceHarness.load(tester);
      await h.shoot(tester, TextedPeopleScreen(space: Circles.instance.bySeed(c.seed)!.channelOf(space)), 'sms-members-$texter');
      expect(find.text('MEMBERS'), findsOneWidget, reason: 'section headings are drawn in capitals');
      final you = find.byKey(ValueKey('sms-member-${me.id}'));
      expect(you, findsOneWidget, reason: 'you are in the list');
      expect(find.descendant(of: you, matching: find.text('You')), findsOneWidget);
      if (texter) {
        expect(find.textContaining('Your phone texts for this space'), findsOneWidget);
        expect(find.text('IN IT BY TEXT'), findsOneWidget);
      } else {
        expect(find.byKey(ValueKey('sms-member-${other.id}')), findsOneWidget, reason: 'the texter, the circle\'s owner here');
        expect(find.text('Their phone texts for this space'), findsOneWidget);
      }
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
