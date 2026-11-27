import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/mentions.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// A circle's chat with one of everything in it, the same at every run: drawn before and after the flat line was shared
/// with the groups on other networks (lib/ui/flat_line.dart), and its pictures (build/flat-groups/circle-*) are the same
/// to the byte.
HangoutRoom _room() {
  final keys = NetKeys.generate();
  final channel = VoiceChannel(seed: '5d' * 32, name: 'general', owner: 'ab' * 32, kind: SpaceKind.text, circle: 'c' * 64);
  final at = DateTime(2026, 11, 18, 9).millisecondsSinceEpoch;
  const min = 60000;
  final file = SpaceFile(id: '1f' * 16, name: 'agenda.pdf', size: 245760, mime: 'application/pdf', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 0);
  final store = MemoryHangoutStore()
    ..keepRoster(channel.chatRoom, Roster.first(channel.owner))
    ..keepMessages(channel.chatRoom, [
      HangoutMessage(id: '1', from: 'maya', name: 'Maya Chen', text: 'Morning all! Standup in ten?', at: at),
      HangoutMessage(id: '2', from: 'maya', name: 'Maya Chen', text: 'I put the agenda in Files.', at: at + min, edited: at + 2 * min),
      HangoutMessage(id: '3', from: 'kevin', name: 'Kevin Moss', text: 'On my way, grabbing coffee first', at: at + 2 * min, reply: const SpaceReply(id: '1', from: 'maya', name: 'Maya Chen', text: 'Morning all! Standup in ten?')),
      HangoutMessage(id: '4', from: 'me', name: 'Me', text: 'Same here. Five minutes.', at: at + 3 * min),
      HangoutMessage(id: '5', from: 'me', name: 'Me', text: 'Can someone share the link? https://example.com/a', at: at + 4 * min, reply: const SpaceReply(id: '4', from: 'me', name: 'Me', text: 'Same here. Five minutes.')),
      HangoutMessage(id: '6', from: 'kevin', name: 'Kevin Moss', text: '@Me it is in the agenda', at: at + 5 * min, mentions: const [Mention(0, 3, 'me')]),
      HangoutMessage(id: '7', from: 'kevin', name: 'Kevin Moss', text: 'and @Me once more, with a much longer line of words so that it wraps onto another line on a phone', at: at + 6 * min, mentions: const [Mention(4, 3, 'me')]),
      HangoutMessage(id: '8', from: 'maya', name: 'Maya Chen', text: 'The file', at: at + 240 * min, files: [file]),
      HangoutMessage(id: '9', from: 'me', name: 'Me', text: '', at: at + 241 * min, sticker: 'mischief-14'),
      HangoutMessage(id: '10', from: 'maya', name: 'Maya Chen', text: 'Lunch?', at: at + 252 * min, poll: const PollSpec(options: ['Tacos', 'Soup'])),
    ]);
  final r = HangoutRoom(channel: channel, route: _NoRoute('me'), name: 'Me', signer: KeysSigner(keys), store: store);
  for (final (i, (msg, who, emoji)) in const [('1', 'kevin', '👍'), ('1', 'me', '👍'), ('1', 'kevin', '🎉'), ('9', 'maya', '😂')].indexed) {
    r.reactions.take(msg, who, emoji, on: true, at: at + i);
  }
  return r;
}

void main() {
  for (final (size, label) in [(const Size(1280, 800), 'computer'), (const Size(412, 900), 'phone'), (const Size(412, 2300), 'tall'), (const Size(320, 2300), 'narrow')]) {
    for (final dark in [false, true]) {
      testWidgets('a circle\'s chat, with one of everything in it: $label, ${dark ? 'dark' : 'light'}', (tester) async {
        final h = await SpaceHarness.load(tester);
        await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: _room())), 'circle-$label', size: size, dark: dark, dir: '../build/flat-groups');
        expect(find.text('Me'), findsWidgets);
      });
    }
  }
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
