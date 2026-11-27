import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_invite.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

// Inviting people into a space (lib/ui/space_invite.dart; Matt, 2026-11-16: "make a way to invite friends from the
// app into spaces and invite people into spaces through the app"): friends chosen and sent the space, a text already
// written, the link copied; nothing offered to someone whose role may not invite; and the friend's app saying who
// invited them. Pictures: test/shots/space-invite-*.png, space-invite-ring-*.png.

/// Friends by username as kept: nothing reaches anyone.
class _KeptBuddies implements BuddiesPort {
  _KeptBuddies(this.list);
  final List<Buddy> list;

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
  Future<String> kept() async => jsonEncode([for (final b in list) b.toJson()]);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

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

/// Opens [open] once it is shown: a page with the sheet raised over it.
class _Opener extends StatefulWidget {
  const _Opener(this.open);
  final void Function(BuildContext context) open;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

const _friends = [
  Buddy(username: 'maya', id: 'maya-id', key: 'k', name: 'Maya Chen'),
  Buddy(username: 'sam', id: 'sam-id', key: 'k', name: 'Sam Ortiz'),
  Buddy(username: 'riley', id: 'riley-id', key: 'k', name: 'Riley Fox'),
  Buddy(username: 'jordan', id: 'jordan-id', key: 'k'),
  Buddy(username: 'noor', id: 'noor-id', key: 'k', name: 'Noor Haddad', state: 'asked'),
];

void main() {
  late SpaceHarness h;
  final channel = VoiceChannel.make('Friday hang');
  final copied = <String>[];

  Future<Buddies> buddies(WidgetTester tester, List<Buddy> list) async {
    final b = Buddies(_KeptBuddies(list));
    await tester.runAsync(b.start);
    return b;
  }

  /// Draws [page] as a picture would be, without keeping one.
  Future<void> draw(WidgetTester tester, Widget page) async {
    final keep = autoUpdateGoldenFiles;
    autoUpdateGoldenFiles = false;
    try {
      await h.shoot(tester, page, 'unkept');
    } finally {
      autoUpdateGoldenFiles = keep;
    }
  }

  Future<void> load(WidgetTester tester) async {
    h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  }

  testWidgets('the sheet lists accepted friends; two chosen and Send shares the space with those two', (tester) async {
    await load(tester);
    final b = await buddies(tester, _friends);
    final sent = <List<String>>[];
    for (final dark in [false, true]) {
      sent.clear();
      await tester.pumpWidget(const SizedBox());
      await h.shoot(
        tester,
        _Opener((context) => showSpaceInvite(context, channel, buddies: b, inSpace: {'riley-id'}, send: (c, fs) async {
          sent.add([for (final f in fs) f.username]);
          return const [];
        })),
        'space-invite-phone',
        dark: dark,
      );
      expect(find.text('Invite people'), findsOneWidget);
      expect(find.text('Maya Chen'), findsOneWidget);
      expect(find.text('jordan'), findsOneWidget, reason: 'no name: the username is the name, said once, with no "@" (Matt, 2026-11-19)');
      expect(find.text('Noor Haddad'), findsNothing, reason: 'asked, not yet a friend');
      expect(find.text('In the space'), findsOneWidget, reason: 'Riley is in the call already');
      await tester.tap(find.text('Maya Chen'));
      await tester.pump();
      expect(find.text('Send invite'), findsOneWidget, reason: 'one chosen: one invite');
      await tester.tap(find.text('Sam Ortiz'));
      await tester.pump();
      await tester.tap(find.text('Riley Fox'));
      await tester.pump();
      await h.again(tester, 'space-invite-phone-chosen', dark: dark);
      expect(find.text('Send 2 invites'), findsOneWidget);
      await tester.tap(find.text('Send 2 invites'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(sent, [
        ['maya', 'sam'],
      ]);
      expect(find.text('Invited 2'), findsWidgets);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a computer; no friends yet says so and offers to add one', (tester) async {
    await load(tester);
    final b = await buddies(tester, _friends);
    await h.shoot(tester, _Opener((context) => showSpaceInvite(context, channel, buddies: b, send: (c, fs) async => const [])), 'space-invite-computer', size: SpaceHarness.computer);
    expect(find.text('Text an invite'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final none = await buddies(tester, const []);
    await h.shoot(tester, _Opener((context) => showSpaceInvite(context, channel, buddies: none, send: (c, fs) async => const [])), 'space-invite-empty');
    expect(find.textContaining('No friends here yet'), findsOneWidget);
    expect(find.text('Add a friend'), findsOneWidget);
    expect(find.text('Send invites'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Text an invite writes a new text with the link; Copy puts the link on the clipboard', (tester) async {
    await load(tester);
    final b = await buddies(tester, _friends);
    final texts = <String>[];
    Widget page() => _Opener((context) => showSpaceInvite(context, channel, buddies: b, send: (c, fs) async => const [], compose: texts.add));
    await draw(tester, page());
    await tester.tap(find.text('Text an invite'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(texts, ['Join me in Friday hang on Uplink: ${channel.link}']);
    expect(find.text('Invite people'), findsNothing, reason: 'the sheet goes');
    await tester.pumpWidget(const SizedBox());
    await draw(tester, page());
    copied.clear();
    await tester.tap(find.text('Copy invite link'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(copied, [channel.link]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('someone whose role may not invite is offered no invite', (tester) async {
    await load(tester);
    final owner = NetKeys.generate(), mine = NetKeys.generate();
    final c = VoiceChannel.make('Book club', owner: NetCrypto.hex(owner.public));
    final store = MemoryHangoutStore();
    store.keepRoster(c.chatRoom, Roster.first(c.owner).next(roles: [...Role.defaults, const Role(id: 'listener', name: 'Listener', rank: 5, perms: {Perm.speak, Perm.chat})], newcomer: 'listener'));
    final room = HangoutRoom(channel: c, route: _NoRoute(mine.id), name: 'Me', signer: KeysSigner(mine), store: store);
    expect(room.can(Perm.invite), isFalse);
    Voice.instance.putHangout(room);
    await draw(tester, _Opener((context) => showHangoutMenu(context, c)));
    expect(find.text('Settings and permissions'), findsOneWidget);
    expect(find.text('Invite people'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await draw(tester, RolesScreen(room: room, settings: true));
    expect(find.text('Invite people'), findsNothing);
    // One who may: the menu offers it, once.
    final ok = h.room();
    Voice.instance.putHangout(ok);
    await tester.pumpWidget(const SizedBox());
    await draw(tester, _Opener((context) => showHangoutMenu(context, ok.channel)));
    expect(find.text('Invite people'), findsOneWidget);
    expect(find.text('Copy invite link'), findsNothing, reason: 'in the invite sheet now');
    await tester.tap(find.text('Invite people'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('invite-search')), findsOneWidget, reason: 'the invite drawer');
    Voice.instance.clearHangouts();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a friend who can\'t be reached is named, not counted as invited', (tester) async {
    await load(tester);
    final b = await buddies(tester, _friends);
    await draw(tester, _Opener((context) => showSpaceInvite(context, channel, buddies: b, send: (c, fs) async => [for (final f in fs) if (f.username == 'sam') f])));
    await tester.tap(find.text('Maya Chen'));
    await tester.pump();
    await tester.tap(find.text('Sam Ortiz'));
    await tester.pump();
    await tester.tap(find.text('Send 2 invites'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Invited Maya Chen; couldn\'t reach Sam Ortiz'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    // No one reached: the sheet stays, and says so.
    await draw(tester, _Opener((context) => showSpaceInvite(context, channel, buddies: b, send: (c, fs) async => fs)));
    await tester.tap(find.text('Maya Chen'));
    await tester.pump();
    await tester.tap(find.text('Send invite'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('Couldn\'t reach Maya Chen'), findsWidgets);
    expect(find.text('Invite people'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a group\'s call offers no invite, and the sheet is never raised for one', (tester) async {
    await load(tester);
    final group = VoiceChannel.ofGroup('g1', 'Climbing');
    expect(SpaceCall.mayInvite(group, null), isFalse, reason: 'a group\'s channel is its members\' alone');
    expect(SpaceCall.mayInvite(channel, null), isTrue);
    expect(SpaceCall.mayInvite(h.room().channel, h.room()), isTrue);
    final b = await buddies(tester, _friends);
    final sent = <VoiceChannel>[];
    await draw(tester, _Opener((context) => showSpaceInvite(context, group, buddies: b, send: (c, fs) async {
          sent.add(c);
          return const [];
        })));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Invite people'), findsNothing);
    expect(sent, isEmpty);
    expect(await Voice.instance.share(group, [_friends.first]), [_friends.first], reason: 'given to no one');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the friend\'s app says who invited them, with Join and Not now', (tester) async {
    await load(tester);
    final v = Voice.instance;
    for (final dark in [false, true]) {
      v.ringing = VoiceRing(channel, 'Maya Chen', DateTime(2026, 11, 16, 20), invite: true);
      await h.shoot(tester, const Stack(children: [Positioned(left: 0, right: 0, top: 0, child: RingCard())]), 'space-invite-ring', dark: dark);
      expect(find.text('Maya Chen invited you to Friday hang'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
      expect(find.bySemanticsLabel('Not now'), findsOneWidget);
    }
    // A group's call reads as it did.
    v.ringing = VoiceRing(VoiceChannel.ofGroup('g1', 'Climbing'), 'Sam', DateTime(2026, 11, 16, 20));
    await draw(tester, const Stack(children: [Positioned(left: 0, right: 0, top: 0, child: RingCard())]));
    expect(find.text('Sam is calling the group'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Not now'));
    await tester.pump();
    expect(v.ringing, isNull);
    expect(find.text('Sam is calling the group'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
