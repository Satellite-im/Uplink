import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/circles/circle_screen.dart' show showCircleMenu;
import 'package:ghost_messaging/ui/circles/circle_settings.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsScreen;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/circles/members_drawer.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/circles/circle_dock.dart';
import 'package:ghost_messaging/ui/nav_bar.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart' show SpaceKind, VoiceChannel, VoiceRoute;

import 'support/list_harness.dart';

/// The dock inside a circle (Matt, 2026-11-17: "add a 'home' button on the dock while on the space and transform all
/// the icons inside the dock to be related to the circle instead of the whole app"), its members in a drawer with Add
/// people at its top ("the member list should show up as a drawer like the add user, it should include a button to
/// switch to add user at the top"), and the room under the composer matching the room under the dock ("the space below
/// the navbar and the space below the composer input should be the same").
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

final _circle = Circle(
  seed: '7' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '7a' * 32, name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '7b' * 32, name: 'Lounge', order: 1),
  ]),
);

Finder _ring(String id) => find.byKey(ValueKey('nav-$id'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  setUp(() => ListPhone([ListPhone.conversation(1, '+15551230001', 'See you at 7', name: 'Maya Chen')]).install());
  tearDown(() async {
    await Circles.instance.clear();
  });

  for (final (name, size) in [('a phone', const Size(412, 892)), ('a wide window', const Size(900, 832))]) {
    testWidgets('on $name the dock is the circle\'s while it is open, and Home takes it back to the main layout', (tester) async {
      Circles.instance.join(_circle);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name), size: size);
      expect(_ring('messages'), findsOneWidget);
      expect(_ring('home'), findsNothing);

      AppShellState.live!.openCircle(_circle);
      await settle(tester);
      // The circle's rings, and none of the app's: Home, its spaces, its members, its settings. Not its owner here, so
      // no New space.
      for (final id in ['home', 'circle-spaces', 'circle-members', 'circle-settings']) {
        expect(_ring(id), findsOneWidget, reason: id);
      }
      // The Marketplace's ring is one of the app's too (Matt, 2026-11-20).
      for (final id in ['new', 'messages', 'contacts', 'archive', 'marketplace', 'settings', 'circle-new']) {
        expect(_ring(id), findsNothing, reason: id);
      }

      await tester.tap(_ring('home'));
      await settle(tester);
      expect(AppShellState.live!.circleOpen, isFalse);
      expect(_ring('home'), findsNothing);
      expect(_ring('messages'), findsOneWidget);
      expect(find.text('Lounge'), findsNothing, reason: 'the circle\'s list is gone from the list\'s place');
      expect(tester.takeException(), isNull);
    });
  }

  // Matt, 2026-11-18: "make the settings button in circles dock open the global app settings, to manage settings in a
  // given circle we shoould click the circle name and chevron in the top of the sidebar and replace "about this circle"
  // with "Circle Settings"".
  testWidgets('the dock\'s Settings is the app\'s; the circle\'s are in its menu, over the whole window', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name), size: const Size(900, 832));
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    await tester.tap(_ring('circle-settings'));
    await settle(tester);
    expect(find.byType(SettingsScreen), findsOneWidget, reason: 'the app\'s own Settings');
    expect(find.byType(CircleSettingsPage), findsNothing);
    // Its back arrow (Matt, 2026-11-18: "add a back arrow to the settings page") takes it away, back to the circle.
    await tester.tap(find.descendant(of: find.byType(SettingsScreen), matching: find.byWidgetPredicate((w) => w is IconTap && w.label == 'Back')).first);
    await settle(tester);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(AppShellState.live!.circleOpen, isTrue);
    AppShellState.live!.home();
    await settle(tester);
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    showCircleMenu(tester.element(find.byType(AppShell)), _circle);
    await settle(tester);
    expect(find.text('About this circle'), findsNothing);
    await tester.tap(find.text('Circle settings'));
    await settle(tester);
    // Over the whole window, its sidebar beside the section (Matt, 2026-11-17: "a full screen sidebar and main page").
    expect(find.byType(CircleSettingsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('circle-settings-sidebar')), findsOneWidget);
    expect(tester.getRect(find.byType(CircleSettingsPage)).width, 900, reason: 'the whole window, not the pane');
    await tester.tap(find.byKey(const ValueKey('circle-settings-tab-roles')));
    await settle(tester);
    expect(find.byKey(const ValueKey('circle-role-owner')), findsOneWidget);
    // Closed, the circle is as it was.
    await tester.tap(find.byKey(const ValueKey('circle-settings-close')));
    await settle(tester);
    expect(find.byType(CircleSettingsPage), findsNothing);
    expect(AppShellState.live!.circleOpen, isTrue);
    expect(tester.takeException(), isNull);
  });

  // Matt, 2026-11-17: "replace the circle icon with the home page, hide the settings cog that's outside of the navbar
  // remove the users icon from the header as well find some other icon to fill the missing space".
  testWidgets('the header holds only Add people, and the dock leads with Home, Invite in the face\'s room', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name));
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    expect(find.byKey(const ValueKey('circle-invite')), findsNothing, reason: 'Add people is in the Members drawer');
    expect(find.byKey(const ValueKey('circle-header-settings')), findsNothing, reason: 'the dock has Settings');
    expect(find.byKey(const ValueKey('nav-head')), findsNothing, reason: 'no face at the dock\'s head');
    final items = tester.widget<NavPill>(find.byKey(const ValueKey('circle-dock'))).items;
    expect([for (final i in items) i.id].first, CircleDock.home);
    expect([for (final i in items) i.id], isNot(contains(CircleDock.invite)));
  });

  testWidgets('from a circle, Home then a ring of the app\'s dock: that place in the main layout, nothing of the circle\'s', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name), size: const Size(900, 832));
    final shell = AppShellState.live!;
    // A space of the circle open beside its list, then Home and Contacts: the contacts in the pane, nothing of the
    // circle's anywhere.
    shell.openCircle(_circle);
    await settle(tester);
    expect(find.text('Lounge'), findsWidgets);
    await tester.tap(_ring('home'));
    await settle(tester);
    await tester.tap(_ring('contacts'));
    await settle(tester);
    expect(find.byType(ContactsScreen), findsOneWidget);
    expect(shell.circleOpen, isFalse);
    expect(find.text('Lounge'), findsNothing);
  });

  // Matt, 2026-11-23: "add a \"mark as read\" to the context menu for circles".
  testWidgets('a circle\'s menu has Mark as read: every space in it is read, and its unread count is gone', (tester) async {
    Circles.instance.join(_circle);
    final mine = NetKeys.generate();
    final now = DateTime.now().millisecondsSinceEpoch;
    final v = Voice.instance;
    v.clearRead();
    for (final (i, c) in _circle.channels.indexed) {
      final store = MemoryHangoutStore()
        ..keepRoster(c.chatRoom, Roster.first(c.owner, kind: SpaceKind.text))
        ..keepMessages(c.chatRoom, [HangoutMessage(id: 'm$i', from: 'a', name: 'Maya Chen', text: 'Anyone up?', at: now - 60000 + i)]);
      v.putHangout(HangoutRoom(channel: c, route: _NoRoute(mine.id), name: 'Me', signer: KeysSigner(mine), store: store));
    }
    addTearDown(() {
      v.clearHangouts();
      v.clearRead();
    });
    expect(Circles.instance.unread(_circle), 2, reason: 'one in each of its two spaces');
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(900, 832));
    showCircleMenu(tester.element(find.byType(AppShell)), _circle);
    await settle(tester);
    await tester.tap(find.text('Mark as read'));
    await settle(tester);
    expect(Circles.instance.unread(_circle), 0);
    for (final c in _circle.channels) {
      expect(v.unreadIn(c), 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Members is a drawer, and Add people at its top switches it to the invite drawer', (tester) async {
    Circles.instance.join(_circle);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name));
    AppShellState.live!.openCircle(_circle);
    await settle(tester);
    await tester.tap(_ring('circle-members'));
    await settle(tester);
    expect(find.byType(MembersDrawer), findsOneWidget);
    expect(find.byType(CircleMembersList), findsOneWidget);
    final add = find.byKey(const ValueKey('members-add-people'));
    expect(add, findsOneWidget);
    // At the top: above the list of people.
    expect(tester.getRect(add).bottom, lessThanOrEqualTo(tester.getRect(find.byType(CircleMembersList)).top + 1));
    await tester.tap(add);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MembersDrawer), findsNothing);
    // The invite drawer, whichever is drawn: it is titled so.
    expect(find.text('Invite people'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a circle\'s space has Members where the shield was, listing the circle\'s people in it (Matt, 2026-11-20: "remove the shield icon for the quick space settings, instead show a members icon there")', (tester) async {
    final mine = NetKeys.generate();
    Circles.instance.join(_circle);
    Circles.instance.noteSeen(_circle, {'cccccccccccccccccccccccccccccccc': 'Cara Diaz'});
    final c = _circle.channelOf(_circle.manifest.spaces.first);
    final store = MemoryHangoutStore()..keepRoster(c.chatRoom, Roster.first(c.owner, kind: SpaceKind.text));
    final room = HangoutRoom(channel: c, route: _NoRoute(mine.id), name: 'Me', signer: KeysSigner(mine), store: store);
    Voice.instance.putHangout(room);
    addTearDown(Voice.instance.clearHangouts);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, HangoutScreen(channel: c), AppState());
    expect(find.bySemanticsLabel('Space settings'), findsNothing, reason: 'no shield in a circle\'s space');
    expect(find.byKey(const ValueKey('space-members')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('space-members')));
    await settle(tester);
    expect(find.byType(SpaceMembers), findsOneWidget);
    expect(find.textContaining('Cara Diaz', findRichText: true), findsWidgets, reason: 'a member of the circle, though not yet in the space');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a space\'s Members opens the drawer, and Add people switches it to the space\'s invite drawer', (tester) async {
    final mine = NetKeys.generate();
    final c = VoiceChannel.make('Book club', owner: NetCrypto.hex(mine.public), kind: SpaceKind.text);
    final store = MemoryHangoutStore()..keepRoster(c.chatRoom, Roster.first(c.owner, kind: SpaceKind.text));
    final room = HangoutRoom(channel: c, route: _NoRoute(mine.id), name: 'Me', signer: KeysSigner(mine), store: store);
    Voice.instance.putHangout(room);
    addTearDown(Voice.instance.clearHangouts);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, HangoutScreen(channel: c), AppState());
    await tester.tap(find.byKey(const ValueKey('space-members')));
    await settle(tester);
    expect(find.byType(MembersDrawer), findsOneWidget);
    expect(find.byType(SpaceMembers), findsOneWidget);
    expect(find.byType(HangoutChat), findsOneWidget, reason: 'the chat stays where it was, under the drawer');
    await tester.tap(find.byKey(const ValueKey('members-add-people')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MembersDrawer), findsNothing);
    expect(find.text('Invite people'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('someone a space does not let invite sees Add people greyed in its members drawer', (tester) async {
    final owner = NetKeys.generate(), mine = NetKeys.generate();
    final c = VoiceChannel.make('Book club', owner: NetCrypto.hex(owner.public));
    final store = MemoryHangoutStore()
      ..keepRoster(c.chatRoom, Roster.first(c.owner).next(roles: [...Role.defaults, const Role(id: 'listener', name: 'Listener', rank: 5, perms: {Perm.speak, Perm.chat})], newcomer: 'listener'));
    final room = HangoutRoom(channel: c, route: _NoRoute(mine.id), name: 'Me', signer: KeysSigner(mine), store: store);
    expect(room.can(Perm.invite), isFalse);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(onTap: () => showSpaceMembers(context, room), child: const ColoredBox(color: Color(0xFFFFFFFF)))), AppState());
    await tester.tapAt(const Offset(200, 200));
    await settle(tester);
    expect(find.byKey(const ValueKey('members-add-people')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('members-add-people')));
    await settle(tester);
    expect(find.byType(MembersDrawer), findsOneWidget, reason: 'greyed: nothing happens');
    expect(find.text('Invite people'), findsNothing);
  });

  // Matt, 2026-11-17: "the space below the navbar and the space below the composer input should be the same increase
  // the space below the composer bar just a bit". Measured from the screen's foot: the dock's lowest edge over the
  // list on a phone, and the composer's box in a conversation, with the bar a phone keeps at its foot.
  testWidgets('the composer stands as far above the screen\'s foot as the dock does', (tester) async {
    final sheet = await loadSheet(tester);
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.classic.name));
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final pill = tester.getRect(find.descendant(of: find.byType(NavPill), matching: find.byType(ClipRRect)).first);
    final dockGap = screen - pill.bottom;

    await pumpScreen(tester, sheet, const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), AppState());
    final box = tester.getRect(find.byType(ComposerBox));
    final composerGap = screen - box.bottom;
    // 25 and 34 points before (2026-11-17); the same since.
    expect(composerGap, moreOrLessEquals(dockGap, epsilon: 0.5), reason: 'composer $composerGap above the foot, the dock $dockGap');
  });
}

/// A relay that is never reached: the room is drawn from its store alone.
class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
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
