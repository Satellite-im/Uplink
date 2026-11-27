import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Reactions in spaces and circles (Matt, 2026-11-20: "add reactions after done to spaces and circles"): who put which
/// emoji where, newest word winning; said apart from posts where the relay takes reactions, so a member of a read-only
/// space may react though not post; handed to a device coming in; stickers on a space's bubbles and pills under a
/// circle channel's lines. Pictures: test/shots/space-reactions-*.png (--update-goldens).

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

/// A route with reactions of their own, or ([reactions] false) one like a relay from before.
class _Route implements VoiceRoute, ReactionRoute {
  _Route(this.me, this.key, {this.reactions = true});
  @override
  final String me;
  final List<int> key;
  final bool reactions;
  final said = <Map<String, dynamic>>[];
  final reacted = <Map<String, dynamic>>[];
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _reactions = StreamController<({String room, String from, Uint8List bytes})>.broadcast();

  Uint8List seal(Map<String, Object?> what) => NetCrypto.seal(key, utf8.encode(jsonEncode(what)));
  Map<String, dynamic> open(Uint8List b) => (jsonDecode(utf8.decode(NetCrypto.open(key, b)!)) as Map).cast<String, dynamic>();

  @override
  bool get takesReactions => reactions;
  @override
  void sendReaction(String room, Uint8List bytes) => reacted.add(open(bytes));
  @override
  Stream<({String room, String from, Uint8List bytes})> get reactionPackets => _reactions.stream;
  void handReaction(String room, String from, Map<String, Object?> what) => _reactions.add((room: room, from: from, bytes: seal(what)));
  void hand(String room, String from, Map<String, Object?> what) => _packets.add((room: room, from: from, bytes: seal(what)));

  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) => said.add(open(bytes));
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

void main() {
  test('the newest word wins: on, off, on again, and an old word said again changes nothing', () {
    final r = SpaceReactions();
    expect(r.take('m1', 'a', '❤️', on: true, at: 10), isTrue);
    expect(r.take('m1', 'b', '❤️', on: true, at: 11), isTrue);
    expect(r.take('m1', 'b', '😂', on: true, at: 12), isTrue);
    expect(r.of('m1', 'a').map((t) => (t.emoji, t.count, t.mine)).toList(), [('❤️', 2, true), ('😂', 1, false)]);
    expect(r.take('m1', 'a', '❤️', on: false, at: 20), isTrue);
    expect(r.take('m1', 'a', '❤️', on: true, at: 15), isFalse, reason: 'older than the word that took it off');
    expect(r.of('m1', 'a').first.count, 1);
    expect(r.take('m1', 'a', 'not an emoji', on: true, at: 30), isFalse);
    final copy = SpaceReactions()..takeAll(jsonDecode(jsonEncode(r.toJson())));
    expect(copy.of('m1', 'b').map((t) => (t.emoji, t.count, t.mine)).toList(), [('❤️', 1, true), ('😂', 1, true)]);
  });

  group('in a room', () {
    late NetKeys owner, admin, member;
    late Circle circle;
    final news = CircleSpace(seed: 'a1' * 32, name: 'announcements', kind: SpaceKind.text, extra: const {'rdo': true});

    setUp(() async {
      owner = NetKeys.generate();
      admin = NetKeys.generate();
      member = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final grants = {admin.id: NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)))};
      final gs = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantsMessage(ownerKey, 1, grants)));
      final m = await _sign(CircleManifest(owner: ownerKey, version: 1, name: 'Night Owls', spaces: [news], adminGrants: grants, grantsVersion: 1, grantsSig: gs), owner);
      circle = Circle(seed: 'c3' * 32, owner: ownerKey, manifest: m);
      Circles.instance.signerOverride = KeysSigner(member);
      Circles.instance.join(circle);
    });
    tearDown(() async {
      Circles.instance.signerOverride = null;
      await Circles.instance.clear();
    });

    Future<(HangoutRoom, _Route, VoiceChannel)> open({bool reactions = true}) async {
      final c = Circles.instance.bySeed(circle.seed)!;
      final channel = c.channelOf(c.space(news.seed)!);
      final route = _Route(member.id, channel.key, reactions: reactions);
      final store = MemoryHangoutStore()
        ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
        ..keepMessages(channel.chatRoom, [HangoutMessage(id: 'n1', from: admin.id, name: 'Maya', text: 'Book club moves to Friday', at: 1000)]);
      final room = HangoutRoom(channel: channel, route: route, name: 'Sam', signer: KeysSigner(member), store: store)..mayPost = (id) => Circles.instance.mayPostIn(channel, id);
      await room.setReadOnly(Circles.instance.readOnlyRoomFor(channel));
      await room.open();
      return (room, route, channel);
    }

    test('a member of a read-only space can\'t post but reacts, as a reaction packet; taken back off the same way', () async {
      final (room, route, _) = await open();
      expect(room.mayWrite, isFalse);
      expect(room.mayReact, isTrue);
      final m = room.messages.single;
      expect(room.react(m, '🎉'), isTrue);
      expect(route.reacted.single, containsPair('t', 'react'));
      expect(route.reacted.single['e'], '🎉');
      expect(route.reacted.single['on'], isTrue);
      expect(route.said.where((x) => x['t'] == 'react'), isEmpty, reason: 'not as a post the relay would refuse');
      expect(room.reactionsOn(m).single.mine, isTrue);
      expect(room.react(m, '🎉'), isTrue);
      expect(route.reacted.last['on'], isFalse);
      expect(room.reactionsOn(m), isEmpty);
      await room.close();
    });

    test('with a relay from before, a reaction goes as a kept packet', () async {
      final (room, route, _) = await open(reactions: false);
      room.react(room.messages.single, '👍');
      expect(route.reacted, isEmpty);
      expect(route.said.where((x) => x['t'] == 'react').length, 1);
      await room.close();
    });

    test('from a reaction packet only a reaction is taken; reactions come with the history, kept on the device', () async {
      final (room, route, channel) = await open();
      final at = room.hubRoom;
      route.handReaction(at, admin.id, {'t': 'react', 'id': 'n1', 'e': '❤️', 'on': true, 'at': 5});
      route.handReaction(at, member.id, {'t': 'msg', 'id': 'x', 'x': 'smuggled', 'at': 6});
      route.hand(at, owner.id, {
        't': 'reacts',
        'to': member.id,
        'r': {
          'n1': {
            owner.id: {'❤️': [1, 7], '🔥': [1, 8]},
          },
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(room.messages.map((m) => m.id), ['n1'], reason: 'no message from a reaction packet');
      expect(room.reactionsOn(room.messages.single).map((t) => (t.emoji, t.count)).toList(), [('❤️', 2), ('🔥', 1)]);
      await room.close();
      // A new room over the same store has them.
      final again = HangoutRoom(channel: channel, route: route, name: 'Sam', store: room.store);
      expect(again.reactionsOn(again.messages.single).length, 2);
    });
  });

  group('pictures', () {
    setUp(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    });
    tearDown(() async {
      Circles.instance.signerOverride = null;
      await Circles.instance.clear();
    });

    // Earlier than now, so a reaction taken off in the test is the newer word.
    final at = DateTime(2026, 11, 19, 18, 5).millisecondsSinceEpoch;

    /// A room with [said] in it and reactions on them, as [me] sees it.
    Future<HangoutRoom> room(VoiceChannel channel, NetKeys me, List<HangoutMessage> said, List<(String, String, String)> reacts) async {
      final store = MemoryHangoutStore()
        ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
        ..keepMessages(channel.chatRoom, said);
      final r = HangoutRoom(channel: channel, route: _Route(me.id, channel.key), name: 'Sam', signer: KeysSigner(me), store: store);
      for (final (i, (msg, who, emoji)) in reacts.indexed) {
        r.reactions.take(msg, who, emoji, on: true, at: at + i);
      }
      await r.open();
      return r;
    }

    testWidgets('stickers on a space\'s bubbles, and the row to react with over a message\'s menu', (tester) async {
      final h = await SpaceHarness.load(tester);
      final me = NetKeys.generate(), maya = NetKeys.generate(), theo = NetKeys.generate();
      final channel = VoiceChannel(seed: '5d' * 32, name: 'Friday games', owner: NetCrypto.hex(me.public), kind: SpaceKind.text);
      final r = await room(channel, me, [
        HangoutMessage(id: 'g1', from: maya.id, name: 'Maya Chen', text: 'Board games at mine on Friday?', at: at),
        HangoutMessage(id: 'g2', from: me.id, name: 'Sam', text: 'In! I\'ll bring snacks', at: at + 60000),
        HangoutMessage(id: 'g3', from: theo.id, name: 'Theo Park', text: 'Count me in too', at: at + 120000),
      ], [('g1', me.id, '🎉'), ('g1', theo.id, '🎉'), ('g1', theo.id, '❤️'), ('g2', maya.id, '😂')]);
      for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
        for (final dark in [false, true]) {
          await h.shoot(tester, GhostPage(title: '# Friday games', body: HangoutChat(room: r)), 'space-reactions-space-$label', size: size, dark: dark);
        }
      }
      expect(find.byKey(const ValueKey('reactions-g1')), findsOneWidget);
      expect(find.byKey(const ValueKey('reactions-g3')), findsNothing);

      // Pressed and held: the row over the menu; a press puts 👍 on Theo's message.
      await h.shoot(tester, GhostPage(title: '# Friday games', body: HangoutChat(room: r)), 'space-reactions-menu-phone');
      await tester.longPress(find.text('Count me in too'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('reaction-pick-row')), findsOneWidget);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/space-reactions-menu-phone-light.png'));
      await tester.tap(find.byKey(const ValueKey('react-👍')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(r.reactionsOn(r.messages.last).single.emoji, '👍');
      expect((r.route as _Route).reacted.single['id'], 'g3');
      await tester.runAsync(r.close);
    });

    testWidgets('pills under a circle channel\'s lines, a press putting yours on or taking it off; in a read-only space too', (tester) async {
      final h = await SpaceHarness.load(tester);
      final owner = NetKeys.generate(), admin = NetKeys.generate(), me = NetKeys.generate(), theo = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final grants = {admin.id: NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)))};
      final news = CircleSpace(seed: 'a1' * 32, name: 'announcements', kind: SpaceKind.text, extra: const {'rdo': true});
      final m = (await tester.runAsync(() => _sign(CircleManifest(owner: ownerKey, version: 1, name: 'Night Owls', spaces: [news], adminGrants: grants), owner)))!;
      final c = Circle(seed: 'c3' * 32, owner: ownerKey, manifest: m);
      Circles.instance.signerOverride = KeysSigner(me);
      Circles.instance.join(c);
      final channel = Circles.instance.bySeed(c.seed)!.channelOf(news);
      final r = await room(channel, me, [
        HangoutMessage(id: 'n1', from: admin.id, name: 'Maya Chen', text: 'Book club moves to Friday at 8. Bring the next three chapters read!', at: at),
        HangoutMessage(id: 'n2', from: owner.id, name: 'Night Owls', text: 'Welcome to everyone who joined this week 👋', at: at + 30 * 60000),
      ], [('n1', theo.id, '👍'), ('n1', me.id, '👍'), ('n1', admin.id, '📚'), ('n2', theo.id, '❤️'), ('n2', admin.id, '🎉'), ('n2', owner.id, '❤️')]);
      r.mayPost = (id) => Circles.instance.mayPostIn(channel, id);
      for (final (size, label) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
        for (final dark in [false, true]) {
          await h.shoot(tester, GhostPage(title: '# announcements', body: HangoutChat(room: r)), 'space-reactions-circle-$label', size: size, dark: dark);
        }
      }
      expect(find.byKey(const ValueKey('read-only-foot')), findsOneWidget, reason: 'no posting');
      expect(find.byKey(const ValueKey('reaction-chip-👍')), findsOneWidget);
      // Theo's ❤️ on n2: a press adds this person's.
      await tester.tap(find.byKey(const ValueKey('reaction-chip-❤️')));
      await tester.pump();
      expect(r.reactionsOn(r.messages.last).firstWhere((t) => t.emoji == '❤️').count, 3);
      await tester.tap(find.byKey(const ValueKey('reaction-chip-👍')));
      await tester.pump();
      expect(r.reactionsOn(r.messages.first).firstWhere((t) => t.emoji == '👍').mine, isFalse, reason: 'taken off');
      await tester.runAsync(r.close);
    });
  });
}
