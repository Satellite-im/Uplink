import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/invites/invite_relay.dart' show InviteRelayError;
import 'package:ghost_messaging/circles/invite_word.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/circles/circle_settings.dart';
import 'package:ghost_messaging/ui/circles/perm_toggle.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart' show settle;

/// A circle's settings as Discord's server settings (Matt, 2026-11-18: "The roles and settings in circles can be cleaned
/// up a lot to be closer to discord server settings please overhaul them and make it easier to use with tri toggles for
/// permissions and permission hierarchy"): the tri toggle a space's overrides are set with, the roles' order dragged
/// and moved, and the role editor's permissions a member may not grant. Pictures of each, light and dark, on a phone
/// and a wide window: run with --update-goldens and they are written to test/shots/circle-settings-*.png.

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
}

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

/// Who is in the made-up circle: its owner, Maya (who leads, and may manage roles), Theo and Sam.
class _Cast {
  _Cast() : owner = NetKeys.generate(), maya = NetKeys.generate();
  final NetKeys owner, maya;
  final theo = 'f2', sam = 'f3', riley = 'f4';
  final leads = CircleRole.make('Leads', hue: 'rose', perms: {CirclePerm.roles, CirclePerm.invite});
  final mods = CircleRole.make('Moderators', hue: 'green', perms: {CirclePerm.invite, CirclePerm.write, CirclePerm.voice});
  final readers = CircleRole.make('Readers', hue: 'amber', perms: {CirclePerm.write});
  final guests = CircleRole.make('Guests', hue: circleRoleNoHue);
  final general = CircleSpace.make('General', kind: SpaceKind.text);
  final lounge = CircleSpace.make('Lounge', order: 1);
  final shelf = CircleSpace.make('Reading list', kind: SpaceKind.files, order: 2, section: 'Books');

  /// The circle, signed by its owner: four roles in their order, people given them, and General's overrides (readers
  /// may write there, guests may not, everyone may not invite).
  Future<Circle> circle() async {
    final ownerKey = NetCrypto.hex(owner.public);
    final grant = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, maya.id)));
    final base = CircleManifest(owner: ownerKey, version: 1, name: 'Book Club', hue: 'coral', icon: 'book', spaces: [general, lounge, shelf], adminGrants: {maya.id: grant});
    final roled = base.next(extra: base.withRoles(roles: [leads, mods, readers, guests], assignments: {maya.id: [leads.id], theo: [mods.id, readers.id], sam: [readers.id], riley: [guests.id]}));
    final m = await _sign(roled.next(extra: roled.withOverrides({
      general.seed: {
        CircleManifest.everyoneId: const CircleOverride(deny: {CirclePerm.invite}),
        readers.id: const CircleOverride(allow: {CirclePerm.write, CirclePerm.files}),
        guests.id: const CircleOverride(deny: {CirclePerm.write}),
      },
    })), owner);
    return Circle(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), owner: ownerKey, manifest: m, mine: true);
  }
}

Future<void> _until(WidgetTester tester, bool Function() ok) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late TokenSheet sheet;
  setUpAll(_fonts);
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  /// [cast]'s circle joined here, this install signing as [as] (the owner unless said).
  Future<Circle> join(WidgetTester tester, _Cast cast, {NetKeys? as}) async {
    sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final c = (await tester.runAsync(cast.circle))!;
    Circles.instance.signerOverride = KeysSigner(as ?? cast.owner);
    Circles.instance.join(c);
    Circles.instance.noteSeen(c, {cast.maya.id: 'Maya Chen', cast.theo: 'Theo Park', cast.sam: 'Sam Rivera', cast.riley: 'Riley'});
    addTearDown(() async {
      Circles.instance.signerOverride = null;
      await Circles.instance.clear();
    });
    return c;
  }

  /// Draws [page] at [size], light or [dark], in the app's own type.
  Future<void> pump(WidgetTester tester, Widget page, {Size size = const Size(1180, 820), bool dark = false, String key = ''}) async {
    tester.view.physicalSize = size * 2.0;
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = size.width < 720 ? const FakeViewPadding(top: 48, bottom: 32) : FakeViewPadding.zero;
    addTearDown(tester.view.reset);
    final state = AppState()..setTheme(dark ? 'dark' : 'light');
    await tester.pumpWidget(AppScope(
      state: state,
      // A new app each time, so pages pushed in the last picture are not left over this one.
      child: WidgetsApp(
        key: ValueKey('app-$key-$dark-${size.width}'),
        color: const Color(0xFF4F5BD5),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(
          sheet: sheet,
          attrs: ghostAttrs(state, size.width < 720 ? 'mobile' : 'desktop'),
          typography: ghostTypography('noto'),
          child: InkOverrides(child: GlacierToastProvider(child: child!)),
        ),
        home: KeyedSubtree(key: ValueKey('$key-$dark-${size.width}'), child: page),
      ),
    ));
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  testWidgets('a space\'s tri toggle: Deny, As the circle says and Allow, each setting the override for everyone', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.spaces));
    expect(find.text('2 roles changed', findRichText: true), findsNothing);
    await tap(tester, find.byKey(ValueKey('circle-settings-space-${cast.lounge.seed}')));
    expect(find.byKey(const ValueKey('space-perm-v')), findsOneWidget, reason: 'a voice space: talking');
    expect(find.byKey(const ValueKey('space-perm-f')), findsNothing, reason: 'files are not a voice space\'s');
    final talk = find.byKey(const ValueKey('space-perm-toggle-v'));
    expect(tester.widget<PermTriToggle>(talk).value, PermOverride.inherit);
    Future<void> choose(String seg, PermOverride want) async {
      await tap(tester, find.descendant(of: talk, matching: find.byKey(ValueKey('perm-$seg'))));
      await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.overrideOf(cast.lounge.seed, CircleManifest.everyoneId).of(CirclePerm.voice) == want);
      await settle(tester);
      expect(Circles.instance.bySeed(c.seed)!.manifest.overrideOf(cast.lounge.seed, CircleManifest.everyoneId).of(CirclePerm.voice), want);
      expect(tester.widget<PermTriToggle>(talk).value, want);
    }

    await choose('deny', PermOverride.deny);
    await choose('allow', PermOverride.allow);
    await choose('inherit', PermOverride.inherit);
    expect(Circles.instance.bySeed(c.seed)!.manifest.overrides.containsKey(cast.lounge.seed), isFalse, reason: 'nothing left to say: nothing kept');

    // A role chosen: its own override, apart from everyone's.
    await tap(tester, find.byKey(ValueKey('space-perm-role-${cast.mods.id}')));
    await tap(tester, find.descendant(of: talk, matching: find.byKey(const ValueKey('perm-deny'))));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.overrideOf(cast.lounge.seed, cast.mods.id).of(CirclePerm.voice) == PermOverride.deny);
    expect(Circles.instance.bySeed(c.seed)!.manifest.overrideOf(cast.lounge.seed, cast.mods.id).of(CirclePerm.voice), PermOverride.deny);
    expect(Circles.instance.bySeed(c.seed)!.manifest.overrideOf(cast.lounge.seed, CircleManifest.everyoneId).isEmpty, isTrue, reason: 'everyone\'s stays as it was');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tri toggle by itself: read as one choice of three, moved by the arrow keys', (tester) async {
    final cast = _Cast();
    await join(tester, cast);
    var value = PermOverride.inherit;
    await pump(tester, StatefulBuilder(builder: (context, set) => Center(child: PermTriToggle(value: value, label: 'Write for Readers', onChanged: (v) => set(() => value = v)))), size: const Size(412, 300));
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Write for Readers'), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('Write for Readers')).value, 'As the circle says');
    // Focus the middle segment, then the arrows.
    final middle = find.byKey(const ValueKey('perm-inherit'));
    Focus.of(tester.element(find.descendant(of: middle, matching: find.byType(GlacierFocusRing)))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, PermOverride.allow);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, PermOverride.deny);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, PermOverride.deny, reason: 'it stops at the end');
    semantics.dispose();
  });

  testWidgets('roles in their order: one dragged by its handle, one moved down from its menu; everyone stays last', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.roles), size: const Size(1180, 1100));
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(4), reason: 'the owner may move every role');
    expect(find.byKey(const ValueKey('circle-role-everyone')), findsOneWidget);
    List<String> names() => Circles.instance.bySeed(c.seed)!.manifest.roles.map((r) => r.name).toList();
    // Leads dragged down past Moderators.
    final handle = find.descendant(of: find.byKey(ValueKey('circle-role-${cast.leads.id}')), matching: find.byType(ReorderableDragStartListener));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await _until(tester, () => names().first != 'Leads');
    expect(names(), ['Moderators', 'Leads', 'Readers', 'Guests']);
    await settle(tester);
    // Readers moved down from its menu, for the keyboard and a screen reader.
    await tap(tester, find.byKey(ValueKey('circle-role-menu-${cast.readers.id}')));
    await tap(tester, find.text('Move down').last);
    await _until(tester, () => names().last == 'Readers');
    expect(names(), ['Moderators', 'Leads', 'Guests', 'Readers']);
    await settle(tester);
    // The list follows; everyone is still under the last.
    final ys = [for (final r in Circles.instance.bySeed(c.seed)!.manifest.roles) tester.getTopLeft(find.byKey(ValueKey('circle-role-${r.id}'))).dy];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(tester.getTopLeft(find.byKey(const ValueKey('circle-role-everyone'))).dy, greaterThan(ys.last));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a member who manages roles: Leads above them locked, and in a role under theirs what only the owner gives is off, with why', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast, as: cast.maya);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.roles), size: const Size(1180, 1100));
    expect(find.byType(ReorderableDragStartListener), findsNWidgets(3), reason: 'her own Leads can\'t be moved by her');
    expect(find.byKey(const ValueKey('circle-role-new')), findsOneWidget);
    // Moderators, under her: what changes the circle is the owner's to give.
    await tap(tester, find.byKey(ValueKey('circle-role-${cast.mods.id}')));
    await tap(tester, find.text('Permissions'));
    GlacierSwitch sw(String wire) => tester.widget<GlacierSwitch>(find.descendant(of: find.byKey(ValueKey('role-perm-$wire')), matching: find.byType(GlacierSwitch)));
    expect(sw('c').disabled, isTrue);
    expect(sw('s').disabled, isTrue);
    expect(sw('r').disabled, isTrue);
    expect(sw('w').disabled, isFalse);
    expect(sw('i').disabled, isFalse);
    expect(tester.widget<SettingRow>(find.byKey(const ValueKey('role-perm-c'))).disabledReason, contains('Only the owner'));
    await tap(tester, find.descendant(of: find.byKey(const ValueKey('role-perm-f')), matching: find.byType(GlacierSwitch)));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.roles.firstWhere((r) => r.id == cast.mods.id).perms.contains(CirclePerm.files));
    expect(Circles.instance.bySeed(c.seed)!.manifest.roles.firstWhere((r) => r.id == cast.mods.id).perms, contains(CirclePerm.files));
    // Her own Leads: read only, every switch off, saying why.
    await tap(tester, find.byKey(const ValueKey('circle-settings-tab-roles')));
    await tap(tester, find.byKey(ValueKey('circle-role-${cast.leads.id}')));
    await tap(tester, find.text('Permissions'));
    expect(find.textContaining('at or above your own highest role'), findsWidgets);
    for (final p in CirclePerm.values) {
      expect(sw(p.wire).disabled, isTrue, reason: p.label);
    }
    expect(find.byKey(const ValueKey('role-clear-perms')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('members: searched, each with their roles as chips; a role given from someone\'s page', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.members), size: const Size(1180, 1000));
    expect(find.byKey(ValueKey('member-role-${cast.theo}-${cast.mods.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('member-role-${cast.theo}-${cast.readers.id}')), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('circle-members-search')), matching: find.byType(EditableText)), 'sam');
    await settle(tester);
    expect(find.byKey(ValueKey('circle-person-${cast.sam}')), findsOneWidget);
    expect(find.byKey(ValueKey('circle-person-${cast.theo}')), findsNothing);
    await tap(tester, find.byKey(ValueKey('circle-person-${cast.sam}')));
    await tap(tester, find.descendant(of: find.byKey(ValueKey('person-role-${cast.mods.id}')), matching: find.byType(GlacierSwitch)));
    await _until(tester, () => Circles.instance.bySeed(c.seed)!.manifest.rolesOf(cast.sam).length == 2);
    expect(Circles.instance.bySeed(c.seed)!.manifest.rolesOf(cast.sam).map((r) => r.name), ['Moderators', 'Readers']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invite word: chosen by whoever may change the circle, shown to everyone, refused where taken', (tester) async {
    // Matt, 2026-11-19: "add the custom invite code word as a default feature".
    final cast = _Cast();
    final c = await join(tester, cast);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.invite), size: const Size(1180, 1000));
    expect(find.byKey(const ValueKey('circle-word-choose')), findsOneWidget);
    expect(find.text('Choose an invite word'), findsOneWidget);

    final held = <String, String>{};
    final words = InviteWords(ask: (what) async {
      if (what['dir'] == 'word-set') {
        if (held[what['h']] == 'someone else') throw const InviteRelayError('That word is taken. Try another.');
        held[what['h'] as String] = 'me';
      }
      if (what['dir'] == 'word-drop') held.remove(what['h']);
      return {'dir': what['dir'], 'ok': true};
    });
    await tester.runAsync(() => Circles.instance.setInviteWord(Circles.instance.bySeed(c.seed)!, 'bookclub', words: words));
    await settle(tester);
    expect(Circles.instance.bySeed(c.seed)!.inviteWord, 'bookclub');
    expect(find.text('gogho.st/c/bookclub'), findsOneWidget);
    expect(find.byKey(const ValueKey('circle-word-remove')), findsOneWidget);
    expect(held.keys, [inviteWordHash('bookclub')]);

    // Changed: the old word let go. A word someone else holds: refused, and the circle keeps its own.
    await tester.runAsync(() => Circles.instance.setInviteWord(Circles.instance.bySeed(c.seed)!, 'book-club', words: words));
    expect(held.keys, [inviteWordHash('book-club')]);
    held[inviteWordHash('readers')] = 'someone else';
    Object? refused;
    await tester.runAsync(() async {
      try {
        await Circles.instance.setInviteWord(Circles.instance.bySeed(c.seed)!, 'readers', words: words);
      } catch (e) {
        refused = e;
      }
    });
    expect(refused, isA<InviteRelayError>());
    expect(Circles.instance.bySeed(c.seed)!.inviteWord, 'book-club');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a member who may not change the circle sees its word, and no way to change it', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast, as: cast.maya);
    await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.invite), size: const Size(1180, 1000));
    expect(find.byKey(const ValueKey('circle-word-choose')), findsNothing);
    expect(find.text('No invite word yet'), findsOneWidget);
    await expectLater(Circles.instance.setInviteWord(c, 'mine'), throwsStateError);
  });

  // The pictures: light and dark, a phone and a wide window.
  testWidgets('pictures of the settings', (tester) async {
    final cast = _Cast();
    final c = await join(tester, cast);
    final views = <String, Future<void> Function(bool wide)>{
      'overview': (wide) async {},
      'roles': (wide) async {
        if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-roles')));
      },
      'role': (wide) async {
        if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-roles')));
        await tap(tester, find.byKey(ValueKey('circle-role-${cast.mods.id}')));
        await tap(tester, find.text('Permissions'));
      },
      'members': (wide) async {
        if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-members')));
      },
      'plugins': (wide) async {
        if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-plugins')));
      },
      'space': (wide) async {
        if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-spaces')));
        await tap(tester, find.byKey(ValueKey('circle-settings-space-${cast.general.seed}')));
        await tap(tester, find.byKey(ValueKey('space-perm-role-${cast.readers.id}')));
      },
    };
    const sections = {'overview': CircleSettingsSection.overview, 'roles': CircleSettingsSection.roles, 'role': CircleSettingsSection.roles, 'members': CircleSettingsSection.members, 'plugins': CircleSettingsSection.plugins, 'space': CircleSettingsSection.spaces};
    for (final MapEntry(key: name, value: go) in views.entries) {
      for (final wide in [false, true]) {
        for (final dark in [false, true]) {
          await pump(tester, CircleSettingsPage(seed: c.seed, section: sections[name]!), size: wide ? const Size(1180, 820) : const Size(412, 892), dark: dark, key: name);
          await go(wide);
          await tester.pump(const Duration(milliseconds: 400));
          if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/circle-settings-$name-${wide ? 'wide' : 'phone'}-${dark ? 'dark' : 'light'}.png'));
        }
      }
    }
    expect(tester.takeException(), isNull);
  });
}
