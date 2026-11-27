import 'dart:convert';
import 'dart:async';

import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/art/app_icon.dart' show AppIcon;
import 'package:ghost_messaging/ui/composer_box.dart' show ComposerBox;
import 'package:ghost_messaging/ui/special_badges.dart' show SpecialBadges;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/glacier.dart' show GlacierContext;
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/net/name_watch.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// (The space below is the mentions test's own.) Mentions in a space's chat on the screen (Matt, 2026-11-19: "Add mentions support to spaces and circles with the
/// @user prefix"): "@" in the composer offers the space's people, the one picked goes in as "@Name" and is sent with
/// who it means, and a message that mentions you stands out.
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _kevin = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;

  /// What was said in the room, opened.
  final said = <Map<String, dynamic>>[];
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    final clear = NetCrypto.open(key, bytes);
    if (clear != null) said.add((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
  }

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

({HangoutRoom room, _Route route}) _room({bool circle = true, List<HangoutMessage> Function(String me)? messages}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: circle ? 'c' * 64 : null);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
  store.keepMessages(channel.chatRoom, messages?.call(keys.id) ??
      [
        HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: 'Morning all!', at: at),
        HangoutMessage(id: '2', from: _kevin, name: 'Kevin Moss', text: 'Coffee first.', at: at + 60000),
      ]);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}


/// A friends list holding Maya as a friend, and nothing more.
class _Friends implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'me';
  @override
  String get displayName => 'Me';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => jsonEncode([
        {'u': 'maya', 'i': _maya, 'k': 'k', 'n': 'Maya Chen', 's': 'yes', 'st': 'Out walking'},
      ]);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

/// Faces and names open the profile card (Matt, 2026-11-19: "Clicking on a users profile picture or name should open
/// the profile drawer as well, move the send message button inside the input like we have on the rest of the app as
/// well within that drawer").
void main() {
  setUp(() async {
    Buddies.instance = Buddies(_Friends());
    await Buddies.instance.start();
  });
  tearDown(() => Buddies.instance = null);

  for (final circle in [true, false]) {
    testWidgets('a name and a face in a space open their profile card (${circle ? 'a circle\'s channel' : 'bubbles'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      final (:room, route: _) = _room(circle: circle);
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'profile-open-$circle');
      await tester.tap(find.text('Kevin Moss').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Members'), findsOneWidget, reason: 'the card, with the space\'s members among its choices');
      expect(find.text('Mention Kevin Moss'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Mention Kevin Moss'), findsNothing);
      // Maya's face.
      final face = find.ancestor(of: find.text('MC'), matching: find.byType(GestureDetector)).first;
      await tester.tap(face);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Mention Maya Chen'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  // The name watch (lib/net/name_watch.dart; docs/OPEN_NETWORK.md, section 3): the relay now gives a friend's username to
  // another key, and their card says so; they are still who was added.
  testWidgets('a friend whose username the relay now gives to another account: their card says so in its own ink, with the usual reason, and that they are still who you added', (tester) async {
    final kept = {
      NameWatch.keptName: jsonEncode({
        'me': 'me',
        'r': {
          '': {
            'x': {_maya: ['maya', 'c' * 32, DateTime(2026, 11, 22).millisecondsSinceEpoch, 'friend']},
          },
        },
      }),
    };
    NameWatch.instance = NameWatch(me: () => 'me', username: () => 'me', friends: () => [const WatchedName('maya', _maya, 'k')], whois: (_) async => null, tell: (_, _) async {}, read: (n) => kept[n] ?? '', write: (n, v) => kept[n] = v, now: DateTime.now, timer: (_, _) => Timer(Duration.zero, () {}))..start();
    addTearDown(() => NameWatch.instance = null);
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'profile-name-watch');
    await tester.tap(find.text('Maya Chen').first);
    await tester.pump(const Duration(milliseconds: 400));
    final line = tester.widget<Text>(find.byKey(const ValueKey('profile-name-watch')));
    expect(line.data, '@maya now belongs to another account on the relay. If Maya changed or gave up their username, that\'s why. You\'re still talking to the Maya Chen you added.');
    // Not in the danger ink (the review, M2): almost always the reason is an ordinary one.
    final t = tester.element(find.byKey(const ValueKey('profile-name-watch'))).tokens;
    expect(line.style?.color, t.color('app-ink'));
    expect(line.style?.color, isNot(t.color('app-danger')));
    // Kevin, whose username the relay gives as ever, has no such line.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Kevin Moss').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('profile-name-watch')), findsNothing);
    NameWatch.instance!.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a friend\'s card has the message box with Send inside it, as every conversation\'s has', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'profile-dm');
    await tester.tap(find.text('Maya Chen').first);
    await tester.pump(const Duration(milliseconds: 400));
    final box = find.byKey(const ValueKey('profile-dm'));
    expect(box, findsOneWidget);
    expect(tester.widget(box), isA<ComposerBox>());
    final send = find.descendant(of: box, matching: find.byKey(const ValueKey('profile-dm-send')));
    expect(send, findsOneWidget, reason: 'Send inside the box');
    final boxRect = tester.getRect(box), sendRect = tester.getRect(send);
    expect(boxRect.contains(sendRect.center), isTrue);
    // Its edges in line with the choices under it (Matt, 2026-11-19: "there is too much padding on the left and right
    // of the send message bar in the profile popup it doesn't line up with the @mention open chat and copy options").
    final chatRow = find.ancestor(of: find.text('Open chat'), matching: find.byType(Row)).first;
    final chatMark = tester.getRect(find.descendant(of: chatRow, matching: find.byType(AppIcon)).first);
    expect(boxRect.left, moreOrLessEquals(chatMark.left, epsilon: 0.5), reason: 'the box starts where the choices\' marks do');
    expect(find.text('Out walking'), findsOneWidget, reason: 'her status on the card');
    await h.again(tester, 'profile-dm-card');
    await tester.pump(const Duration(seconds: 1));
  });

  // Shaped as Discord's (Matt, 2026-11-20: "display badges on the users profile popup and redesign the profile popup to
  // be more like discords"): a banner, the face over its edge, the badges' marks in a tray and by name in the panel.
  for (final dark in [false, true]) {
  testWidgets('the card has a banner, the face over its edge, and the badges in a tray and by name (${dark ? 'dark' : 'light'})', (tester) async {
    SpecialBadges.instance.reset();
    addTearDown(SpecialBadges.instance.reset);
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    SpecialBadges.instance.heard(ids: [_maya], names: const [], byId: {_maya: ['founder', 'bughunter']});
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'profile-badges', dark: dark);
    await tester.tap(find.text('Maya Chen').first);
    await tester.pump(const Duration(milliseconds: 400));
    final banner = tester.getRect(find.byKey(const ValueKey('profile-banner')));
    final face = tester.getRect(find.byKey(const ValueKey('profile-face')));
    expect(face.top, lessThan(banner.bottom), reason: 'the face over the banner\'s lower edge');
    expect(face.bottom, greaterThan(banner.bottom));
    expect(find.byKey(const ValueKey('profile-badge-tray')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-badge-founder')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-badge-bughunter')), findsOneWidget);
    expect(find.text('Founder'), findsOneWidget, reason: 'by name in the panel');
    expect(find.text('Bug hunter'), findsOneWidget);
    await h.again(tester, 'profile-badges-card', dark: dark);
    await tester.pump(const Duration(seconds: 1));
  });
  }
}
