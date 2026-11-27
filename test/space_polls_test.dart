import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/poll_card.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Polls on the screen (Matt, 2026-11-19: "add Polls as a default feature"): a poll drawn as its card, voted on by a
/// press, and asked from the + .
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

void main() {
  testWidgets('a poll is a card of its answers; a press votes, another press on it takes the vote back', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, :route) = _room();
    await room.open();
    expect(room.sendPoll('Movie tonight?', PollSpec.of(['Yes', 'No'])!), isTrue);
    final poll = room.messages.last;
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-poll');
    expect(find.byKey(ValueKey('poll-${poll.id}')), findsOneWidget);
    expect(find.text('Movie tonight?'), findsOneWidget);
    expect(find.text('No votes yet'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('poll-${poll.id}-option-0')));
    await tester.pump();
    expect(route.said.lastWhere((m) => m['t'] == 'vote')['c'], [0]);
    expect(find.text('1 vote'), findsOneWidget);
    await h.again(tester, 'space-poll-voted');
    await tester.tap(find.byKey(ValueKey('poll-${poll.id}-option-0')));
    await tester.pump();
    expect(route.said.lastWhere((m) => m['t'] == 'vote')['c'], isEmpty, reason: 'taken back');
    expect(find.text('No votes yet'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a poll is asked from its page: a question and two answers, more added, and Ask sends it', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, :route) = _room();
    await room.open();
    await h.shoot(tester, NewPollScreen(room: room), 'new-poll');
    Future<void> write(Key key, String words) async {
      await tester.enterText(find.descendant(of: find.byKey(key), matching: find.byType(EditableText)), words);
      await tester.pump();
    }

    await write(const ValueKey('poll-question'), 'Where to?');
    await write(const ValueKey('poll-answer-0'), 'Beach');
    await tester.tap(find.byKey(const ValueKey('poll-add-answer')));
    await tester.pump();
    await write(const ValueKey('poll-answer-1'), 'Mountains');
    await write(const ValueKey('poll-answer-2'), 'Lake');
    await tester.tap(find.byKey(const ValueKey('poll-ask')));
    await tester.pump();
    final sent = route.said.lastWhere((m) => m['t'] == 'msg');
    expect(sent['w'], 'Where to?');
    expect(sent['pl'], {'o': ['Beach', 'Mountains', 'Lake']});
    await tester.pump(const Duration(seconds: 1));
  });
}
