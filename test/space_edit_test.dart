import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner, RoomEvent;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Editing a message in a space or a circle (Matt, 2026-11-20: "I'd like to be able to edit messages sent in circles
/// from any computer or phone connected to the account that sent it"): its writer's, from any of their devices, and
/// nobody else's; told to everyone in the room and kept for whoever is away.
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;
  final said = <Map<String, dynamic>>[];
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    final clear = NetCrypto.open(key, bytes);
    if (clear != null) said.add((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
  }

  /// [what] said in the room by [from], as the relay hands it over.
  void hear(String room, String from, Map<String, Object?> what) => _packets.add((room: room, from: from, bytes: NetCrypto.seal(key, utf8.encode(jsonEncode(what)))));

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

({HangoutRoom room, _Route route}) _room({List<HangoutMessage> Function(String me)? messages}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: 'c' * 64);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  final at = DateTime(2026, 11, 20, 9).millisecondsSinceEpoch;
  store.keepMessages(channel.chatRoom, messages?.call(keys.id) ??
      [
        HangoutMessage(id: 'm1', from: keys.id, name: 'Me', text: 'See you at 6', at: at),
        HangoutMessage(id: 'm2', from: _maya, name: 'Maya Chen', text: 'Great', at: at + 60000),
      ]);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
  tearDown(() => HangoutRoom.sameAs = (id) => id);

  test('its writer edits it; the edit is said, kept for the away, and the message marked edited', () async {
    final (:room, :route) = _room();
    await room.open();
    final mine = room.messages.firstWhere((m) => m.id == 'm1');
    final hers = room.messages.firstWhere((m) => m.id == 'm2');
    expect(room.canEdit(mine), isTrue);
    expect(room.canEdit(hers), isFalse, reason: 'nobody else\'s, whatever their role');
    expect(room.edit(mine, 'See you at 7'), isTrue);
    final now = room.messages.firstWhere((m) => m.id == 'm1');
    expect((now.text, now.edited != null), ('See you at 7', true));
    final said = route.said.lastWhere((m) => m['t'] == 'edit');
    expect((said['id'], said['x']), ('m1', 'See you at 7'));
    expect(room.edit(now, 'See you at 7'), isFalse, reason: 'nothing changed');
    // Kept: its edited words and when, as the history hands them to whoever comes later.
    final back = HangoutMessage.fromJson(jsonDecode(jsonEncode(now.toJson())) as Map<String, dynamic>, now.from)!;
    expect((back.text, back.edited), ('See you at 7', now.edited));
  });

  test('an edit from the writer\'s other device is taken; from anyone else, or older, it is not', () async {
    final (:room, :route) = _room();
    await room.open();
    final at = DateTime(2026, 11, 20, 10).millisecondsSinceEpoch;
    route.hear(room.channel.chatRoom, _maya, {'t': 'edit', 'id': 'm2', 'x': 'Great!!', 'ed': at});
    await _settle();
    expect(room.messages.firstWhere((m) => m.id == 'm2').text, 'Great!!', reason: 'her own edit, from whichever of her devices');
    route.hear(room.channel.chatRoom, 'b' * 32, {'t': 'edit', 'id': 'm2', 'x': 'Hacked', 'ed': at + 1});
    await _settle();
    expect(room.messages.firstWhere((m) => m.id == 'm2').text, 'Great!!', reason: 'not someone else\'s word');
    route.hear(room.channel.chatRoom, _maya, {'t': 'edit', 'id': 'm2', 'x': 'Older', 'ed': at - 1000});
    await _settle();
    expect(room.messages.firstWhere((m) => m.id == 'm2').text, 'Great!!', reason: 'an older edit comes too late');
  });

  test('an id carried over to the writer\'s identity edits as them; an edit before its message waits for it', () async {
    HangoutRoom.sameAs = (id) => id == 'c' * 32 ? _maya : id;
    final (:room, :route) = _room();
    await room.open();
    final at = DateTime(2026, 11, 20, 10).millisecondsSinceEpoch;
    route.hear(room.channel.chatRoom, 'c' * 32, {'t': 'edit', 'id': 'm2', 'x': 'From her old computer', 'ed': at});
    await _settle();
    expect(room.messages.firstWhere((m) => m.id == 'm2').text, 'From her old computer');
    route.hear(room.channel.chatRoom, _maya, {'t': 'edit', 'id': 'm3', 'x': 'Edited before it came', 'ed': at + 5});
    route.hear(room.channel.chatRoom, _maya, {'t': 'msg', 'id': 'm3', 'x': 'First words', 'at': at, 'n': 'Maya Chen'});
    await _settle();
    expect(room.messages.firstWhere((m) => m.id == 'm3').text, 'Edited before it came');
  });

  testWidgets('Edit in its menu puts its words in the box; Save changes it, marked edited; Escape stops', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-edit');
    await tester.longPress(find.textContaining('See you at 6'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('space-editing')), findsOneWidget);
    final box = find.byType(EditableText).last;
    expect(tester.widget<EditableText>(box).controller.text, 'See you at 6');
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'See you at 7', selection: TextSelection.collapsed(offset: 12)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('space-editing')), findsNothing);
    expect(find.textContaining('See you at 7'), findsWidgets);
    expect(find.textContaining('(edited)'), findsOneWidget);
    await h.again(tester, 'space-edit');

    // Edit, then Escape: given back, nothing changed.
    await tester.longPress(find.textContaining('See you at 7').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('space-editing')), findsNothing);
    expect(room.messages.firstWhere((m) => m.id == 'm1').text, 'See you at 7');
    await tester.pump(const Duration(seconds: 1));
  });
}
