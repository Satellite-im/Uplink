import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetCrypto, NetKeys;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner, RoomEvent;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'themes_test.dart' show ThemeScreen, shootLook;

// Dial-Up's "People Here" beside a space's chat (lib/ui/hangout_screen.dart's _people; Matt, 2026-11-27: "the 'people
// here' reports people not in voice chat actively", with a picture of "People Here: 3" under "2 in voice"): in a space
// with a call it lists who is in the call, and not who only has the space open; in a texting space, which has no call,
// who has it open, as before. It listed everyone with the space open in both.

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

HangoutRoom _room(String name, SpaceKind kind) {
  final keys = NetKeys.generate();
  final channel = VoiceChannel.make(name, owner: NetCrypto.hex(keys.public), kind: kind);
  final room = HangoutRoom(channel: channel, route: _Route(keys.id), name: 'Me', signer: KeysSigner(keys), store: MemoryHangoutStore());
  // Maya is in the call, Dana only has the space open.
  room.present.addAll({'a': const HangoutPerson('a', name: 'Maya Chen', inVoice: true), 'b': const HangoutPerson('b', name: 'Dana')});
  return room;
}

void main() {
  testWidgets('a space with a call lists who is in the call; a texting space, who has it open', (tester) async {
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final v = Voice.instance;
    addTearDown(v.clearHangouts);

    final lounge = _room('Lounge', SpaceKind.voice);
    v.putHangout(lounge);
    await shootLook(tester, sheet, Look.dialup, 'light', ThemeScreen('people-here-voice', () => HangoutScreen(channel: lounge.channel), size: ThemeScreen.wide), write: false);
    // This device is not in the call either: only Maya is.
    expect(find.text('People Here: 1'), findsOneWidget);
    expect(find.text('Maya Chen'), findsWidgets);
    expect(find.text('Dana'), findsNothing, reason: 'she has the space open and is not in its call');
    expect(find.text('You'), findsNothing, reason: 'nor is this device');
    await tester.pumpWidget(const SizedBox());

    final general = _room('General', SpaceKind.text);
    v.putHangout(general);
    await shootLook(tester, sheet, Look.dialup, 'light', ThemeScreen('people-here-text', () => HangoutScreen(channel: general.channel), size: ThemeScreen.wide), write: false);
    expect(find.text('People Here: 3'), findsOneWidget);
    for (final name in ['You', 'Maya Chen', 'Dana']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
  });
}
