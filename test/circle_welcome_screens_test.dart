import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/circles/circle_settings.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart' show settle;
import 'support/space_call_harness.dart';

/// Welcome messages, the welcome space and read-only spaces on the screen (Matt, 2026-11-20: "add - Welcome messages
/// for new members and allow setting a "welcome" channel as well as read only channels for system messages and admin /
/// moderation announcements"): the welcome card atop the welcome space, a member's read-only space (no box), an admin's
/// (the box, and a line saying everyone else reads), the system space's lines, and Circle settings › Welcome and a
/// space's Read-only switch. Pictures on a phone and a computer, light and dark: run with --update-goldens and they are
/// written to test/shots/circle-welcome-*.png.

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

class _Route implements VoiceRoute {
  _Route(this.me);
  @override
  final String me;
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

void main() {
  late NetKeys owner, admin, member;
  final news = CircleSpace(seed: 'a1' * 32, name: 'announcements', kind: SpaceKind.text, section: 'Info', extra: const {'rdo': true});
  final log = CircleSpace(seed: 'a2' * 32, name: 'system', kind: SpaceKind.text, order: 1, section: 'Info', extra: const {'rdo': true});
  final welcome = CircleSpace(seed: 'a3' * 32, name: 'welcome', kind: SpaceKind.text, order: 2, section: 'Info');
  final general = CircleSpace(seed: 'b2' * 32, name: 'general', kind: SpaceKind.text, order: 3, section: 'Chat');
  const words = 'Welcome, {name}! Say hello in # general, read # announcements for news, and be kind.';

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  /// The circle, joined here as [as]: its owner, Maya an admin, and Sam (a member).
  Future<Circle> join(WidgetTester tester, NetKeys as) async {
    final ownerKey = NetCrypto.hex(owner.public);
    final grants = {admin.id: NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)))};
    final gs = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantsMessage(ownerKey, 1, grants)));
    final base = CircleManifest(owner: ownerKey, version: 1, name: 'Night Owls', hue: 'indigo', spaces: [news, log, welcome, general], adminGrants: grants, grantsVersion: 1, grantsSig: gs);
    final m = (await tester.runAsync(() => _sign(base.next(extra: base.withWelcome(text: words, space: welcome.seed)..addAll(base.next().withSystemSpace(log.seed))), owner)))!;
    final c = Circle(seed: 'c3' * 32, owner: ownerKey, manifest: m);
    Circles.instance.signerOverride = KeysSigner(as);
    Circles.instance.join(c);
    Circles.instance.noteSeen(c, {admin.id: 'Maya Chen', member.id: 'Sam Rivera'});
    return Circles.instance.bySeed(c.seed)!;
  }

  /// [space]'s chat as [me] sees it, with [said] in it.
  Future<HangoutRoom> roomOf(Circle c, CircleSpace space, NetKeys me, String name, List<HangoutMessage> said) async {
    final channel = c.channelOf(space);
    final store = MemoryHangoutStore()
      ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
      ..keepMessages(channel.chatRoom, said);
    final room = HangoutRoom(channel: channel, route: _Route(me.id), name: name, signer: KeysSigner(me), store: store)..mayPost = (id) => Circles.instance.mayPostIn(channel, id);
    await room.setReadOnly(Circles.instance.readOnlyRoomFor(channel));
    await room.open();
    return room;
  }

  final at = DateTime(2026, 11, 20, 9, 30).millisecondsSinceEpoch;
  HangoutMessage said(String id, NetKeys from, String name, String text, int minutes) => HangoutMessage(id: id, from: from.id, name: name, text: text, at: at + minutes * 60000);

  testWidgets('a newcomer: the welcome space starts with the welcome, addressed to them', (tester) async {
    owner = NetKeys.generate();
    admin = NetKeys.generate();
    member = NetKeys.generate();
    final h = await SpaceHarness.load(tester);
    final c = await join(tester, member);
    expect(Circles.instance.landingOf(c)?.seed, welcome.seed);
    final room = await roomOf(c, welcome, member, 'Sam Rivera', [said('w1', admin, 'Maya Chen', 'Hi Sam, glad you made it!', 2)]);
    for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
      for (final dark in [false, true]) {
        await h.shoot(tester, GhostPage(title: '# welcome', body: HangoutChat(room: room)), 'circle-welcome-space-$label', size: size, dark: dark);
      }
    }
    expect(find.byKey(const ValueKey('circle-welcome-card')), findsOneWidget);
    expect(find.text('Welcome to Night Owls'), findsOneWidget);
    expect(find.text('Welcome, Sam Rivera! Say hello in # general, read # announcements for news, and be kind.'), findsOneWidget);
    expect(find.byKey(const ValueKey('read-only-foot')), findsNothing, reason: 'the welcome space is open to everyone');
    expect(find.byType(EditableText), findsOneWidget);
    await tester.runAsync(room.close);
  });

  testWidgets('a member in a read-only space reads, with no box; an admin writes, told everyone else reads', (tester) async {
    owner = NetKeys.generate();
    admin = NetKeys.generate();
    member = NetKeys.generate();
    final h = await SpaceHarness.load(tester);
    var c = await join(tester, member);
    final posts = [
      said('n1', owner, 'Night Owls', 'Book club moves to Friday at 8.', 0),
      said('n2', admin, 'Maya Chen', 'New rule: spoilers go in # spoilers, behind a tag.', 40),
    ];
    var room = await roomOf(c, news, member, 'Sam Rivera', posts);
    for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
      for (final dark in [false, true]) {
        await h.shoot(tester, GhostPage(title: '# announcements', body: HangoutChat(room: room)), 'circle-welcome-read-only-member-$label', size: size, dark: dark);
      }
    }
    expect(find.byKey(const ValueKey('read-only-foot')), findsOneWidget);
    expect(find.text('Only admins can post in # announcements.'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing, reason: 'no box');
    await tester.runAsync(room.close);
    await tester.runAsync(Circles.instance.clear);

    c = await join(tester, admin);
    room = await roomOf(c, news, admin, 'Maya Chen', posts);
    for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
      await h.shoot(tester, GhostPage(title: '# announcements', body: HangoutChat(room: room)), 'circle-welcome-read-only-admin-$label', size: size);
    }
    expect(find.byKey(const ValueKey('read-only-admin')), findsOneWidget);
    expect(find.byType(EditableText), findsOneWidget);
    await tester.runAsync(room.close);
  });

  testWidgets('the system space: joins, removals and admins among the admins\' posts, read-only for everyone else', (tester) async {
    owner = NetKeys.generate();
    admin = NetKeys.generate();
    member = NetKeys.generate();
    final h = await SpaceHarness.load(tester);
    final c = await join(tester, member);
    final riley = NetKeys.generate().id;
    Circles.instance.noteForTest(c, [
      CircleSystemNote(kind: SystemNoteKind.joined, id: member.id, name: 'Sam Rivera', at: at),
      CircleSystemNote(kind: SystemNoteKind.joined, id: riley, name: 'Riley', at: at + 5 * 60000),
      CircleSystemNote(kind: SystemNoteKind.admin, id: admin.id, name: 'Maya Chen', at: at + 20 * 60000),
      CircleSystemNote(kind: SystemNoteKind.removed, id: riley, name: 'Riley', at: at + 50 * 60000),
    ]);
    final room = await roomOf(c, log, member, 'Sam Rivera', [said('s1', admin, 'Maya Chen', 'Riley was removed for spam. Report anything odd to an admin.', 52)]);
    for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
      for (final dark in [false, true]) {
        await h.shoot(tester, GhostPage(title: '# system', body: HangoutChat(room: room)), 'circle-welcome-system-$label', size: size, dark: dark);
      }
    }
    expect(find.text('Sam Rivera joined the circle'), findsOneWidget);
    expect(find.text('Maya Chen is now an admin'), findsOneWidget);
    expect(find.text('Riley was banned from the circle'), findsOneWidget);
    expect(find.text('System messages. Only admins can post in # system.'), findsOneWidget);
    await tester.runAsync(room.close);
  });

  group('settings', () {
    late TokenSheet sheet;

    Future<void> pump(WidgetTester tester, Widget page, {required Size size, bool dark = false, String key = ''}) async {
      tester.view.physicalSize = size * 2.0;
      tester.view.devicePixelRatio = 2.0;
      tester.view.padding = size.width < 720 ? const FakeViewPadding(top: 48, bottom: 32) : FakeViewPadding.zero;
      addTearDown(tester.view.reset);
      final state = AppState()..setTheme(dark ? 'dark' : 'light');
      await tester.pumpWidget(AppScope(
        state: state,
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

    Future<void> until(WidgetTester tester, bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('Circle settings › Welcome, and a space made read-only from its settings', (tester) async {
      owner = NetKeys.generate();
      admin = NetKeys.generate();
      member = NetKeys.generate();
      await SpaceHarness.load(tester);
      sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final c = await join(tester, owner);
      for (final wide in [false, true]) {
        for (final dark in [false, true]) {
          await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.welcome), size: wide ? const Size(1180, 900) : const Size(412, 892), dark: dark, key: 'welcome');
          if (!wide) await tap(tester, find.byKey(const ValueKey('circle-settings-tab-welcome')));
          if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/circle-welcome-settings-${wide ? 'wide' : 'phone'}-${dark ? 'dark' : 'light'}.png'));
        }
      }
      expect(find.text('Welcome space'), findsOneWidget);
      expect(find.text('# welcome'), findsWidgets);
      expect(find.text('# system'), findsWidgets);
      expect(find.byKey(ValueKey('circle-readonly-${news.seed}')), findsOneWidget);

      // # general made read-only from its own settings, on a wide window.
      await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.spaces), size: const Size(1180, 900), key: 'spaces');
      await tap(tester, find.byKey(ValueKey('circle-settings-space-${general.seed}')));
      expect(find.byKey(const ValueKey('space-read-only')), findsOneWidget);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/circle-welcome-space-read-only-wide-light.png'));
      await tap(tester, find.descendant(of: find.byKey(const ValueKey('space-read-only')), matching: find.byType(GlacierSwitch)));
      await until(tester, () => readOnlyOf(Circles.instance.bySeed(c.seed)!.space(general.seed)!));
      expect(readOnlyOf(Circles.instance.bySeed(c.seed)!.space(general.seed)!), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a member sees the welcome settings without a way to change them', (tester) async {
      owner = NetKeys.generate();
      admin = NetKeys.generate();
      member = NetKeys.generate();
      await SpaceHarness.load(tester);
      sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final c = await join(tester, member);
      await pump(tester, CircleSettingsPage(seed: c.seed, section: CircleSettingsSection.welcome), size: const Size(412, 892), key: 'member');
      await tap(tester, find.byKey(const ValueKey('circle-settings-tab-welcome')));
      expect(find.textContaining('Whoever has Change the circle sets Night Owls', findRichText: true), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('circle-welcome-text')));
      expect(find.byKey(const ValueKey('circle-welcome-field')), findsNothing, reason: 'no editor for a member');
    });
  });
}
