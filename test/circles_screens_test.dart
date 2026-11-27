import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/ui/circles/circle_settings.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/desktop/ui/qr.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/ui/circles/arrange_spaces.dart';
import 'package:ghost_messaging/ui/circles/circle_face.dart';
import 'package:ghost_messaging/ui/circles/circle_invite.dart';
import 'package:ghost_messaging/ui/invite_people.dart' show InvitePeopleSheet;
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/circles/new_circle.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// The circle screens (lib/ui/circles; Matt, 2026-11-17: "make a new design for [circles]. We want it to be simpler and
/// easier to digest with it's own sidebar full of spaces each space should be able to act as a chat and a voice chat,
/// or just a texting space ... use iconography and color where possible"): making one, renaming it, a new space of
/// each kind, what each kind opens as, arranging spaces, and inviting people. Pictures of each in every look:
/// THEME_SCREENS=new-circle,circle-space-new,circle-settings,circle-arrange,circle-invite in themes_test.

/// Friends as kept: nothing reaches anyone.
class _KeptBuddies implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => false;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

Buddies _friends() => Buddies(_KeptBuddies())
  ..all = const [
    Buddy(username: 'maya', id: 'f1', key: 'k1', name: 'Maya Chen'),
    Buddy(username: 'theo', id: 'f2', key: 'k2', name: 'Theo Park'),
  ];

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
}

/// A circle owned by [keys], signed, with a texting space, a voice space and a Files space under a heading; this
/// install signs as its owner, so its pages offer what an owner may change.
Future<Circle> _ownCircle(NetKeys keys) async {
  final owner = NetCrypto.hex(keys.public);
  final m = await CircleManifest(owner: owner, version: 1, name: 'Book Club', hue: 'coral', icon: 'book', spaces: [
    CircleSpace.make('General', kind: SpaceKind.text),
    CircleSpace.make('Lounge', order: 1),
    CircleSpace.make('Reading list', kind: SpaceKind.files, order: 2, section: 'Books'),
  ]).signedBy(keys.id, keys.public, (b) async => NetCrypto.sign(keys, b));
  return Circle(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), owner: owner, manifest: m, mine: true);
}

/// Pumps until [ok] holds: the signing behind each change finishes in its own time.
Future<void> _until(WidgetTester tester, bool Function() ok) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(_fonts);
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  Future<Circle> joinOwn(WidgetTester tester) async {
    final keys = NetKeys.generate();
    final c = (await tester.runAsync(() => _ownCircle(keys)))!;
    Circles.instance.signerOverride = KeysSigner(keys);
    Circles.instance.join(c);
    addTearDown(() async {
      Circles.instance.signerOverride = null;
      await Circles.instance.clear();
    });
    return c;
  }

  // Matt, 2026-11-20: "I can't seem to kick users or ban them from circles, please add that functionality".
  testWidgets('Members: a person\'s page has Kick and Ban; whoever is banned is listed, with Unban', (tester) async {
    final c = await joinOwn(tester);
    final sam = NetKeys.generate();
    // Sam listed among the circle's people: made an admin, so the list knows him.
    await tester.runAsync(() => Circles.instance.grantAdmin(Circles.instance.bySeed(c.seed)!, sam.id));
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.members), AppState(), size: const Size(1100, 1200));
    await tester.tap(find.byKey(ValueKey('circle-person-${sam.id}')));
    await settle(tester);
    expect(find.byKey(const ValueKey('person-kick')), findsOneWidget);
    expect(find.byKey(const ValueKey('person-ban')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('person-ban')));
    await tester.tap(find.byKey(const ValueKey('person-ban')));
    await settle(tester);
    await tester.tap(find.text('Ban ${circlePeople(Circles.instance.bySeed(c.seed)!).firstWhere((p) => p.id == sam.id).name}').last);
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.removed.contains(sam.id));
    expect(Circles.instance.bySeed(c.seed)!.manifest.granted(sam.id), isFalse, reason: 'banned, no longer an admin');
    await pumpScreen(tester, sheet, CircleSettingsPage(key: const ValueKey('again'), seed: c.seed, section: CircleSettingsSection.members), AppState(), size: const Size(1100, 1200));
    expect(find.byKey(const ValueKey('circle-banned')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('circle-banned-${sam.id}')));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.removed.isEmpty);
    expect(Circles.instance.bySeed(c.seed)!.manifest.removed, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new circle: its name, colour and icon previewed, a texting and a voice space to start, a space retyped, a friend brought', (tester) async {
    final sheet = await loadSheet(tester);
    ({String name, String? hue, String icon, List<CircleSpace>? spaces})? made;
    List<Buddy>? shared;
    final buddies = _friends();
    Circle? result;
    await pumpScreen(
      tester,
      sheet,
      NewCircleScreen(
        buddies: buddies,
        make: ({required String name, String? hue, String icon = 'users', String? picture, List<CircleSpace>? spaces}) async {
          made = (name: name, hue: hue, icon: icon, spaces: spaces);
          return result = Circle(seed: 'a' * 64, owner: '', manifest: CircleManifest.placeholder(owner: '', name: name, hue: hue ?? 'blue'));
        },
        share: (c, friends) async {
          shared = friends;
          return const [];
        },
      ),
      AppState(),
      // Tall enough that the whole page is built at once: its face stays to be read after the icon is chosen.
      size: const Size(412, 2600),
    );
    expect(find.text('General'), findsWidgets, reason: 'the texting space a circle starts with');
    expect(find.text('Lounge'), findsWidgets, reason: 'and its voice space');
    expect(circleIcons.length, 24, reason: 'a grid of 24 icons to choose from');

    await tester.enterText(find.byType(EditableText).first, 'Night Owls');
    await tester.pump();
    expect(find.text('Night Owls'), findsWidgets, reason: 'the name previewed under the face');
    await tester.tap(find.byKey(const ValueKey('circle-hue-green')));
    await tester.ensureVisible(find.byKey(const ValueKey('circle-icon-rocket')));
    await tester.tap(find.byKey(const ValueKey('circle-icon-rocket')));
    await tester.pump();
    final face = tester.widget<CircleFace>(find.byKey(const ValueKey('new-circle-face')));
    expect((face.hue, face.icon), ('green', 'rocket'));

    // The voice space made a Files space instead, from its menu.
    await tester.ensureVisible(find.byKey(const ValueKey('new-circle-space-1')));
    await tester.tap(find.byKey(const ValueKey('new-circle-space-1')));
    await settle(tester);
    await tester.tap(find.text('Make it files'));
    await settle(tester);

    await tester.ensureVisible(find.byKey(const ValueKey('new-circle-friend-f1')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('new-circle-friend-f1')), matching: find.byType(GlacierSwitch)));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('circle-make')));
    await tester.tap(find.byKey(const ValueKey('circle-make')));
    await settle(tester);

    expect(made, isNotNull);
    expect((made!.name, made!.hue, made!.icon), ('Night Owls', 'green', 'rocket'));
    expect([for (final s in made!.spaces!) (s.name, s.kind)], [('General', SpaceKind.text), ('Lounge', SpaceKind.files)]);
    expect(result, isNotNull);
    expect(shared?.map((f) => f.id), ['f1'], reason: 'the friend chosen is sent the circle once it is made');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: the owner renames the circle, sees themselves as its owner, and the QR code of its link', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    // On a phone the settings' sidebar is the first page, and each section opens over it (Matt, 2026-11-17: "basic
    // circle settings with a full screen sidebar and main page settings").
    await pumpScreen(tester, sheet, CircleSettingsScreen(seed: c.seed), AppState(), size: const Size(412, 1400));
    expect(find.text('Circle settings'), findsOneWidget);
    for (final s in CircleSettingsSection.values) {
      expect(find.byKey(ValueKey('circle-settings-tab-${s.name}')), findsOneWidget);
    }
    Future<void> open(CircleSettingsSection s) async {
      await tester.tap(find.byKey(ValueKey('circle-settings-tab-${s.name}')));
      await settle(tester);
    }

    Future<void> back() async {
      Navigator.of(tester.element(find.byType(SettingsPaneScope).last)).pop();
      await settle(tester);
    }

    // Leaving, and deleting for its owner, at the sidebar's foot (Matt, 2026-11-18: "closer to discord server settings").
    expect(find.byKey(const ValueKey('circle-leave')), findsOneWidget);
    expect(find.byKey(const ValueKey('circle-delete')), findsOneWidget, reason: 'its owner may delete it');
    await open(CircleSettingsSection.members);
    final you = tester.widget<CircleRoleTag>(find.byType(CircleRoleTag).first);
    expect((you.person.name, you.person.role), ('You', 'Owner'));
    await back();
    await open(CircleSettingsSection.roles);
    expect(find.byKey(const ValueKey('circle-role-owner')), findsOneWidget);
    expect(find.text('You'), findsWidgets, reason: 'the owner, by name');
    await back();
    await open(CircleSettingsSection.spaces);
    expect(find.byKey(const ValueKey('circle-settings-new-space')), findsOneWidget, reason: 'a space added from settings');
    expect(find.byKey(ValueKey('circle-settings-space-${c.spaces.first.seed}')), findsOneWidget);
    await back();

    await open(CircleSettingsSection.invite);
    await tester.tap(find.byKey(const ValueKey('circle-qr')));
    await settle(tester);
    expect(find.byType(QrView), findsOneWidget);
    expect(tester.widget<QrView>(find.byType(QrView)).data, c.link);
    await back();

    await open(CircleSettingsSection.overview);
    await tester.tap(find.byKey(const ValueKey('circle-rename')));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).last, 'Bookworms');
    await tester.tap(find.byKey(const ValueKey('words-save')));
    await _until(tester, () => Circles.instance.bySeed(c.seed)?.name == 'Bookworms');
    expect(Circles.instance.bySeed(c.seed)!.name, 'Bookworms');
    expect(Circles.instance.bySeed(c.seed)!.manifest.version, 2, reason: 'a new manifest, signed here');
    await settle(tester);
    expect(find.text('Bookworms'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings on a wide window: the sidebar of sections beside the one chosen', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    for (final section in [CircleSettingsSection.overview, CircleSettingsSection.spaces, CircleSettingsSection.roles]) {
      await pumpScreen(tester, sheet, CircleSettingsPage(key: ValueKey(section), seed: c.seed, section: section), AppState(), size: const Size(1100, 760));
      expect(find.byKey(const ValueKey('circle-settings-sidebar')), findsOneWidget);
      expect(find.byKey(ValueKey('circle-settings-${section.name}')), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  // Matt, 2026-11-18: "Build custom roles".
  testWidgets('roles: a new role made, given what it lets people do, and what everyone may do', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.roles), AppState(), size: const Size(1100, 1200));
    expect(find.byKey(const ValueKey('circle-role-new')), findsOneWidget);
    // Everyone (@everyone) last, opened in the section's own pane: changing the circle is never everyone's.
    await tester.tap(find.byKey(const ValueKey('circle-role-everyone')));
    await settle(tester);
    GlacierSwitch perm(String wire) => tester.widget<GlacierSwitch>(find.descendant(of: find.byKey(ValueKey('role-perm-$wire')), matching: find.byType(GlacierSwitch)));
    expect(perm('w').disabled, isFalse);
    expect(perm('c').disabled, isTrue, reason: 'changing the circle is never everyone\'s');
    await tester.tap(find.byKey(const ValueKey('circle-settings-tab-roles')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('circle-role-new')));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).last, 'Moderators');
    await tester.tap(find.byKey(const ValueKey('words-save')));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.roles.length == 1);
    await settle(tester);
    // Its page: name, colour, what it lets people do.
    expect(find.text('Moderators'), findsWidgets);
    await tester.tap(find.text('Permissions'));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('role-perm-s')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('role-perm-s')), matching: find.byType(GlacierSwitch)));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.roles.single.perms.contains(CirclePerm.spaces));
    expect(Circles.instance.bySeed(c.seed)!.manifest.roles.single.perms, {CirclePerm.spaces});
    await tester.tap(find.byKey(const ValueKey('circle-settings-tab-roles')));
    await settle(tester);
    expect(find.byKey(ValueKey('circle-role-${Circles.instance.bySeed(c.seed)!.manifest.roles.single.id}')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new space: the three kinds as cards, a heading tapped from those the circle has, added to it', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, NewCircleSpaceScreen(circle: c), AppState());
    for (final k in SpaceKind.values) {
      expect(find.byKey(ValueKey('space-kind-${k.wire}')), findsOneWidget);
      expect(find.text(spaceKindTitle(k)), findsWidgets);
    }
    await tester.tap(find.byKey(const ValueKey('space-kind-files')));
    await tester.pump();
    await tester.enterText(find.byType(EditableText).first, 'Photos');
    await tester.tap(find.byKey(const ValueKey('space-heading-Books')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('circle-space-add')));
    await tester.tap(find.byKey(const ValueKey('circle-space-add')));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.spaces.length == 4);
    final added = Circles.instance.bySeed(c.seed)!.spaces.last;
    expect((added.name, added.kind, added.section), ('Photos', SpaceKind.files, 'Books'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  test('each kind opens as its own page: a texting or voice space its chat, a Files space its files page', () {
    final c = Circle(
      seed: 'b' * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: 'Kinds', spaces: [
        CircleSpace(seed: '1' * 64, name: 'Talk', kind: SpaceKind.voice),
        CircleSpace(seed: '2' * 64, name: 'Chat', kind: SpaceKind.text, order: 1),
        CircleSpace(seed: '3' * 64, name: 'Drop', kind: SpaceKind.files, order: 2),
      ]),
    );
    final pages = [for (final ch in c.channels) circleSpacePage(ch)];
    expect(pages[0], isA<HangoutScreen>());
    expect(pages[1], isA<HangoutScreen>());
    expect(c.channels[1].hasVoice, isFalse, reason: 'a texting space has no call, so its page has no Join');
    expect(pages[2], isA<FilesSpaceScreen>());
    expect(spaceKindIcon(SpaceKind.text), isNot(spaceKindIcon(SpaceKind.voice)));
  });

  testWidgets('arranging: a space dragged by its handle moves for everyone; one deleted from its menu goes', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, ArrangeCircleSpacesScreen(seed: c.seed), AppState());
    final first = c.spaces.first;
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
    // General, dragged down past the other two.
    final handle = find.descendant(of: find.byKey(ValueKey('arrange-${first.seed}')), matching: find.byType(ReorderableDragStartListener));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.spaces.last.seed == first.seed);
    expect(Circles.instance.bySeed(c.seed)!.spaces.last.seed, first.seed);
    await settle(tester);

    final files = c.spaces.last;
    await tester.tap(find.byKey(ValueKey('arrange-${files.seed}')));
    await settle(tester);
    await tester.tap(find.text('Delete space').last);
    await settle(tester);
    await tester.tap(find.text('Delete space').last);
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.space(files.seed) == null);
    expect(Circles.instance.bySeed(c.seed)!.spaces.length, 2);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the invite sheet: friends chosen and sent the circle, the link copied, its QR code shown', (tester) async {
    final c = await joinOwn(tester);
    final sheet = await loadSheet(tester);
    List<Buddy>? sent;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await pumpScreen(
      tester,
      sheet,
      Builder(
        builder: (context) => GlacierPressable(
          onPressed: () => showCircleInvite(context, c, buddies: _friends(), compose: (_) {}, send: (circle, friends) async {
            sent = friends;
            return const [];
          }),
          semanticLabel: 'Invite',
          builder: (_, _) => const SizedBox.expand(child: Text('Invite')),
        ),
      ),
      AppState(),
    );
    // Its QR code and link first: a toast after sending would lie over the sheet's foot.
    await tester.tap(find.text('Invite'));
    await settle(tester);
    expect(find.byType(InvitePeopleSheet), findsOneWidget);
    expect(find.text('Invite people'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('invite-qr')));
    await tester.pump();
    expect(tester.widget<QrView>(find.byType(QrView)).data, c.link);
    await tester.tap(find.byKey(const ValueKey('invite-copy')));
    await settle(tester);
    expect(copied, c.link);
    expect(Circle.fromLink(copied!)?.seed, c.seed, reason: 'the link copied brings whoever opens it into this circle');
    expect(find.byType(InvitePeopleSheet), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.text('Invite'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('invite-b:f2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('invite-send')));
    await settle(tester);
    expect(sent?.map((f) => f.id), ['f2']);
    expect(find.byType(InvitePeopleSheet), findsNothing, reason: 'put away once sent');
    await tester.pump(const Duration(seconds: 6));
    expect(circleInviteWords(c), contains(c.link));
    expect(jsonEncode(circleInviteWords(c)).toLowerCase(), isNot(contains('server')));
    expect(tester.takeException(), isNull);
  });
}
