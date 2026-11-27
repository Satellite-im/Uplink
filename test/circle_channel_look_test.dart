import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// A circle's chat is a channel, as Slack and Discord draw one; a space of one's own or a group's keeps its bubbles
/// (Matt, 2026-11-18: "Id like the chats in circles to be more like discord or slack and keep the bubbles for dms and
/// small groups").
HangoutRoom _room({required bool circle}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: circle ? 'c' * 64 : null);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  final at = DateTime(2026, 11, 18, 9).millisecondsSinceEpoch;
  const min = 60000;
  store.keepMessages(channel.chatRoom, [
    HangoutMessage(id: '1', from: 'maya', name: 'Maya Chen', text: 'Morning all! Standup in ten?', at: at),
    HangoutMessage(id: '2', from: 'maya', name: 'Maya Chen', text: 'I put the agenda in Files.', at: at + min),
    HangoutMessage(id: '3', from: 'kevin', name: 'Kevin Moss', text: 'On my way, grabbing coffee first', at: at + 2 * min),
    HangoutMessage(id: '4', from: keys.id, name: 'Me', text: 'Same here. Five minutes.', at: at + 3 * min),
    HangoutMessage(id: '5', from: keys.id, name: 'Me', text: 'Can someone share the link?', at: at + 4 * min),
    HangoutMessage(id: '6', from: 'maya', name: 'Maya Chen', text: 'Back after lunch: the build is green again.', at: at + 240 * min),
    HangoutMessage(id: '7', from: 'maya', name: 'Maya Chen', text: 'Nice work everyone.', at: at + 252 * min),
  ]);
  return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
}

void main() {
  testWidgets('a circle\'s chat is a channel: everyone on the left, a run\'s name and time once', (tester) async {
    final h = await SpaceHarness.load(tester);
    for (final dark in [false, true]) {
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: _room(circle: true))), 'circle-channel', dark: dark);
      // Yours on the left as everyone's, under your name.
      final mine = tester.getRect(find.text('Same here. Five minutes.'));
      final theirs = tester.getRect(find.text('On my way, grabbing coffee first'));
      expect(mine.left, theirs.left, reason: 'one column, no sides');
      expect(find.text('Me'), findsOneWidget);
      // Maya's two in a row are one run; four hours later she is named again, and twelve minutes after that again.
      expect(find.text('Maya Chen'), findsNWidgets(3));
    }
  });

  testWidgets('a space outside a circle keeps its bubbles: yours on the right', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, GhostPage(title: 'Lounge', body: HangoutChat(room: _room(circle: false))), 'space-bubbles');
    final mine = tester.getRect(find.text('Same here. Five minutes.'));
    final theirs = tester.getRect(find.text('On my way, grabbing coffee first'));
    expect(mine.left, greaterThan(theirs.left + 40));
    expect(find.text('You'), findsNothing);
  });
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
