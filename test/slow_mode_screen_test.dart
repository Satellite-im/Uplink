import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/common.dart' show GhostPage, IconTap;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Slow mode in a circle's space on the screen (Matt, 2026-11-19: "add ... slow mode"): a member waits between
/// messages, with a countdown over the box, and can't send meanwhile.

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


Future<void> _type(WidgetTester tester, String words) async {
  await tester.showKeyboard(find.byType(EditableText));
  tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
  await tester.pump();
}

void main() {
  tearDown(() async {
    Circles.instance.signerOverride = null;
    await Circles.instance.clear();
  });

  testWidgets('a member waits between messages where the space has slow mode, a countdown over the box', (tester) async {
    final h = await SpaceHarness.load(tester);
    final me = NetKeys.generate(), owner = NetKeys.generate();
    Circles.instance.signerOverride = KeysSigner(me);
    final space = CircleSpace(seed: '7b' * 32, name: 'General', kind: SpaceKind.text, extra: const {'slow': 30});
    final c = Circle(
      seed: '7' * 64,
      owner: NetCrypto.hex(owner.public),
      manifest: CircleManifest(owner: NetCrypto.hex(owner.public), version: 1, name: 'Book club', spaces: [space]),
    );
    Circles.instance.join(c);
    final channel = Circles.instance.bySeed(c.seed)!.channelOf(space);
    final store = MemoryHangoutStore()..keepRoster(channel.chatRoom, Roster.first(channel.owner));
    final route = _Route(me.id, channel.key);
    final room = HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(me), store: store);
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'slow-mode');
    expect(find.byKey(const ValueKey('slow-mode-on')), findsOneWidget, reason: 'it says the space has slow mode');
    expect(find.text('Slow mode: one message every 30 seconds'), findsOneWidget);

    await _type(tester, 'First!');
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pump();
    int sent() => route.said.where((m) => m['t'] == 'msg').length;
    expect(sent(), 1);
    expect(find.byKey(const ValueKey('slow-mode-wait')), findsOneWidget);
    expect(find.textContaining('you can write again in 0:'), findsOneWidget);

    await _type(tester, 'Second');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent(), 1, reason: 'not while waiting');
    expect(tester.widget<IconTap>(find.byKey(const ValueKey('composer-send'))).onPressed, isNull, reason: 'Send greyed out');
    await tester.pump(const Duration(seconds: 2));

  });
}
