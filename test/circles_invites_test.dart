import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/ui/circles/circle_invite_card.dart';
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// A circle offered to this device: a friend's invite, or a circle's link opened from outside the app. It waits with
/// Join and Not now rather than being joined at once (Matt, 2026-11-17: "Finish the missing pieces that went
/// unfinished", of Circles: Circles.instance.invite was set, never shown, and the circle joined unasked).
Future<({Circle circle, NetKeys keys})> _circle({String name = 'Night Owls', String? seed}) async {
  final keys = NetKeys.generate();
  final owner = NetCrypto.hex(keys.public);
  final m = await CircleManifest(owner: owner, version: 1, name: name, hue: 'indigo', icon: 'book', spaces: [
    CircleSpace.make('General', kind: SpaceKind.text),
    CircleSpace.make('Lounge', order: 1),
    CircleSpace.make('Drop box', kind: SpaceKind.files, order: 2, section: 'Sharing'),
  ]).signedBy(keys.id, keys.public, (b) async => NetCrypto.sign(keys, b));
  return (circle: Circle(seed: seed ?? NetCrypto.hex(NetCrypto.randomBytes(32)), owner: owner, manifest: m), keys: keys);
}

/// [c] as a friend's invite gives it to this device (Circles.share's body, read back).
Circle _asInvite(Circle c) => Circles.fromInvite(Circles.inviteBody(c, 'Maya'))!;

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  group('invites wait', () {
    test('a friend\'s invite is not joined until Join; Join joins it and it is answered', () async {
      final c = (await _circle()).circle;
      final app = AppState();
      final circles = Circles.forTest(app: app);
      final i = circles.offer(_asInvite(c), from: 'Maya Chen')!;
      expect(circles.all, isEmpty, reason: 'the circle\'s room is not entered before the person says so');
      expect((i.from, i.fresh, i.later, i.spaceCount), ('Maya Chen', true, false, 3));
      expect(circles.invite?.seed, c.seed, reason: 'the banner shows it');
      expect(circleInviteLine(i), 'Maya Chen invited you · 3 spaces');

      final joined = circles.acceptInvite(c.seed)!;
      expect(joined.seed, c.seed);
      expect(circles.all.map((x) => x.seed), [c.seed]);
      expect(circles.invites, isEmpty);
      expect(circles.invite, isNull);
      expect(app.choice('circle_invites', ''), '[]');
    });

    test('Not now keeps it under Invites, without the banner, across a launch; dismissed, it is gone', () async {
      final c = (await _circle()).circle;
      final app = AppState();
      final circles = Circles.forTest(app: app)..offer(_asInvite(c), from: 'Maya Chen');
      circles.laterInvite(c.seed);
      expect(circles.invite, isNull, reason: 'no banner once put off');
      expect(circles.invites.single.later, isTrue);
      expect(circles.all, isEmpty);

      // The next launch: kept as it was, still not joined.
      final again = Circles.forTest(app: app);
      final kept = again.invites.single;
      expect((kept.seed, kept.from, kept.later, kept.fresh, kept.spaceCount), (c.seed, 'Maya Chen', true, false, 3));
      expect(kept.circle.manifest.trustedFor(c.owner), isTrue, reason: 'the signed manifest is kept with it');
      expect(again.all, isEmpty);

      again.dismissInvite(c.seed);
      expect(again.invites, isEmpty);
      expect(Circles.forTest(app: app).invites, isEmpty, reason: 'dismissed for good');
      expect(again.all, isEmpty, reason: 'dismissing never joins');
    });

    test('an invite kept from before a launch has a card but no banner; seen on its banner, the card stays', () async {
      final c = (await _circle()).circle;
      final app = AppState();
      Circles.forTest(app: app).offer(_asInvite(c), from: 'Maya Chen');
      final next = Circles.forTest(app: app);
      expect(next.invites.single.later, isFalse, reason: 'still a card at the top of the Circles tab');
      expect(next.invite, isNull, reason: 'the banner is for what comes while the app is open');

      final now = Circles.forTest()..offer(_asInvite(c), from: 'Maya Chen');
      now.seenInvite(c.seed);
      expect((now.invite, now.invites.single.later), (null, false));
    });

    test('a circle already held takes a newer manifest from an invite, with no invite to answer', () async {
      final made = await _circle();
      final circles = Circles.forTest()..join(made.circle);
      final newer = await made.circle.manifest.next(name: 'Night Owls 2').signedBy(made.keys.id, made.keys.public, (b) async => NetCrypto.sign(made.keys, b));
      expect(circles.offer(_asInvite(made.circle.copyWith(manifest: newer)), from: 'Maya'), isNull);
      expect(circles.invites, isEmpty);
      expect(circles.all.single.name, 'Night Owls 2');
    });

    test('a circle left before is not brought back by a friend sending it again: it waits, and Join brings it back', () async {
      final c = (await _circle()).circle;
      final circles = Circles.forTest()..join(c);
      await circles.leave(c);
      expect(circles.removed(c.seed), isTrue);
      circles.offer(_asInvite(c), from: 'Maya');
      expect(circles.all, isEmpty);
      expect(circles.removed(c.seed), isTrue, reason: 'still left until Join');
      circles.acceptInvite(c.seed);
      expect((circles.all.single.seed, circles.removed(c.seed)), (c.seed, false));
    });

    test('offered again, an invite comes back to the top as new; leaving or joining another way answers it', () async {
      final a = (await _circle(name: 'A')).circle, b = (await _circle(name: 'B')).circle;
      final circles = Circles.forTest()
        ..offer(_asInvite(a), from: 'Maya')
        ..offer(_asInvite(b), from: 'Theo');
      circles.laterInvite(a.seed);
      expect(circles.invites.map((i) => i.circle.name), ['B', 'A']);
      circles.offer(_asInvite(a), from: 'Theo');
      expect(circles.invites.map((i) => (i.circle.name, i.from, i.later)), [('A', 'Theo', false), ('B', 'Theo', false)]);
      // Its link pasted (+ New › Join a circle by link): joined, so the invite has been answered.
      expect(circles.joinLink(b.link)?.seed, b.seed);
      expect(circles.invites.map((i) => i.circle.name), ['A']);
    });

    test('joined or left on the paired phone or computer: the invite here is answered too', () async {
      final a = (await _circle(name: 'A')).circle, b = (await _circle(name: 'B')).circle, c = (await _circle(name: 'C')).circle;
      // On the phone: the computer joined A, and left C, whose invite waited here too.
      final phone = Circles.forTest()
        ..offer(_asInvite(a), from: 'Maya')
        ..offer(_asInvite(b), from: 'Theo')
        ..offer(_asInvite(c), from: 'Ada');
      expect(phone.invite, isNotNull);
      await phone.answerDesk({'op': 'circle-join', 'c': a.toJson()});
      await phone.answerDesk({'op': 'circle-forget', 's': c.seed});
      expect(phone.all.map((x) => x.seed), [a.seed]);
      expect(phone.invites.map((i) => i.circle.name), ['B'], reason: 'no card for a circle held, nor one left');
      // On the computer: the phone holds B, and has left A.
      final desk = Circles.forTest()
        ..offer(_asInvite(a), from: 'Maya')
        ..offer(_asInvite(b), from: 'Theo');
      desk.fromPhone({'circles': [b.toJson()], 'circles_gone': [a.seed]});
      expect(desk.all.map((x) => x.seed), [b.seed]);
      expect(desk.invites, isEmpty);
      expect(desk.invite, isNull, reason: 'no banner either');
    });
  });

  group('links from outside the app', () {
    test('a circle\'s link is found in an invite\'s words; a space\'s link or other words are not one', () async {
      final c = (await _circle()).circle;
      expect(Circles.linkIn('Join my circle Night Owls on Uplink: ${c.link}'), c.link);
      expect(Circles.linkIn(c.link), c.link);
      expect(Circles.linkIn('https://gogho.st/join/#${'1' * 64}.TmlnaHQ'), isNull);
      expect(Circles.linkIn('see you at 8'), isNull);
      expect(Circles.linkIn(null), isNull);
    });

    test('a link opened from outside is an invite to answer; one for a circle held is that circle', () async {
      final c = (await _circle()).circle;
      final circles = Circles.forTest();
      final got = circles.offerLink(c.link)!;
      expect(got.held, isNull);
      final i = got.invite!;
      expect((i.link, i.from, i.circle.name, i.spaceCount), (true, '', 'Night Owls', null), reason: 'a link says only its name until it is joined');
      expect(circleInviteLine(i), 'From a link you opened');
      expect(circles.all, isEmpty);
      circles.acceptInvite(c.seed);
      expect(circles.offerLink(c.link)!.held?.seed, c.seed);
      expect(circles.offerLink('not a link'), isNull);
    });

    test('where a link and a friend\'s invite name different owners, the link is believed', () async {
      final real = await _circle();
      final seed = real.circle.seed;
      // Someone else's key put on the same circle's invite.
      final forged = (await _circle(seed: seed)).circle;
      final circles = Circles.forTest()..offerLink(real.circle.link);
      circles.offer(_asInvite(forged), from: 'Mallory');
      final i = circles.invites.single;
      expect((i.circle.owner, i.link, i.from), (real.circle.owner, true, 'Mallory'));
      // The real owner's manifest, from a friend, is taken into it.
      circles.offer(_asInvite(real.circle), from: 'Maya');
      expect((circles.invites.single.circle.owner, circles.invites.single.spaceCount), (real.circle.owner, 3));
      expect(circles.acceptInvite(seed)?.owner, real.circle.owner);
    });
  });

  group('on screen', () {
    setUpAll(_fonts);
    tearDown(() async {
      await Circles.instance.clear();
      Voice.instance.dismissRing();
    });

    testWidgets('a new invite is a banner and a card at the top of Messages under the rail; Not now leaves it under Invites; Join opens the circle', (tester) async {
      final c = (await tester.runAsync(_circle))!.circle;
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(412, 892));
      await settle(tester);
      Circles.instance.offer(_asInvite(c), from: 'Maya Chen');
      await settle(tester);
      expect(find.byKey(ValueKey('circle-invite-banner-${c.seed}')), findsOneWidget);
      expect(find.text('Maya Chen invited you to Night Owls'), findsOneWidget);

      // The banner pressed: the Circles tab, where the card is; the banner gives way to it.
      await tester.tap(find.byKey(const ValueKey('circle-invite-banner-open')));
      await settle(tester);
      expect(find.byKey(ValueKey('circle-invite-card-${c.seed}')), findsOneWidget);
      expect(find.byKey(ValueKey('circle-invite-banner-${c.seed}')), findsNothing);

      await tester.tap(find.byKey(ValueKey('circle-invite-later-${c.seed}')));
      await settle(tester);
      expect(find.byKey(ValueKey('circle-invite-card-${c.seed}')), findsNothing);
      expect(find.text('INVITES'), findsOneWidget);
      expect(find.byKey(ValueKey('circle-invite-row-${c.seed}')), findsOneWidget);
      expect(Circles.instance.all, isEmpty);

      await tester.tap(find.byKey(ValueKey('circle-invite-row-join-${c.seed}')));
      await settle(tester);
      expect(Circles.instance.all.single.seed, c.seed);
      expect(find.byType(CircleScreen), findsOneWidget, reason: 'Join opens the circle');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the banner\'s Join opens the circle; its Not now keeps it for the Circles tab', (tester) async {
      final a = (await tester.runAsync(() => _circle(name: 'Book Club')))!.circle;
      final b = (await tester.runAsync(() => _circle(name: 'Night Owls')))!.circle;
      final sheet = await loadSheet(tester);
      // The Circles tab is the dock's; under the rail, the default, invites are atop Messages (the test above).
      await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.dock.name), size: const Size(412, 892));
      await settle(tester);
      Circles.instance.offer(_asInvite(a), from: 'Theo');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('circle-invite-banner-later')));
      await settle(tester);
      expect(find.byKey(ValueKey('circle-invite-banner-${a.seed}')), findsNothing);
      expect(Circles.instance.invites.single.later, isTrue);

      Circles.instance.offer(_asInvite(b), from: 'Maya');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('circle-invite-banner-join')));
      await settle(tester);
      expect(Circles.instance.all.map((c) => c.name), ['Night Owls']);
      expect(find.byType(CircleScreen), findsOneWidget);
      expect(Circles.instance.invites.map((i) => i.circle.name), ['Book Club'], reason: 'the one put off still waits');

      // The tab says how many invites wait unanswered: none, the one left is put off.
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Back').first);
      await settle(tester);
      await tester.tap(find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.circleDot).first);
      await settle(tester);
      expect(find.byKey(ValueKey('circle-invite-row-${a.seed}')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('circle-invite-dismiss-${a.seed}')));
      await settle(tester);
      expect(Circles.instance.invites, isEmpty);
      expect(find.text('INVITES'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
