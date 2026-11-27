import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/emoji_data.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/me/pictures.dart';
import 'package:ghost_messaging/sms.dart' show Sms, SmsCalls;
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Enter in a space's box, and people's pictures by their messages (Matt, 2026-11-19: "Pressing enter isn't sending
/// messages on desktop in circles. also Profile pictures are not loading in circles spaces").
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

/// A 2x2 red PNG, as a profile picture.
const _red = 'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGN4YGAARAwQCgAlzgUBlaDndgAAAABJRU5ErkJggg==';

Future<void> _type(WidgetTester tester, String words) async {
  await tester.showKeyboard(find.byType(EditableText));
  tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
  await tester.pump();
}

/// A computer's calls (Sms.remote), saying which were made.
class _Computer implements SmsCalls {
  _Computer(this.typing);

  /// Whether a text field is taking typing: the Mac's emoji panel types into that one, and opens on nothing without it.
  final bool Function() typing;
  final made = <String>[];
  bool typingAtEmoji = false;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    made.add(method);
    if (method == 'emoji') typingAtEmoji = typing();
    return null;
  }
}

void main() {
  testWidgets('on a computer, Emoji opens the app\'s own picker, and what is picked goes into the box (Matt, 2026-11-19: "roll an in house emoji picker")', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    final was = Sms.calls;
    final computer = _Computer(() => tester.testTextInput.hasAnyClients);
    Sms.calls = computer;
    addTearDown(() => Sms.calls = was);
    await tester.runAsync(EmojiData.load);
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-emoji');
    await tester.tap(find.byKey(const ValueKey('composer-emoji')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('emoji-sheet')), findsOneWidget);
    expect(computer.made, isNot(contains('emoji')), reason: 'not the computer\'s own panel');
    await tester.tap(find.byKey(const ValueKey('emoji-😀')));
    await tester.tap(find.byKey(const ValueKey('emoji-😃')));
    await tester.pump(const Duration(milliseconds: 300));
    final box = tester.widgetList<EditableText>(find.byType(EditableText, skipOffstage: false)).where((e) => e.controller.text.isNotEmpty).single;
    expect(box.controller.text, '😀😃');
    await tester.pump(const Duration(seconds: 1));
  });

  tearDown(() => ProfilePictures.instance.keep(_maya, ''));

  for (final on in [true, false]) {
    testWidgets('Enter sends where Enter sends is on, Shift+Enter does not (${on ? 'on' : 'off'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      final (:room, :route) = _room();
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-enter-$on');
      AppState.of(tester.element(find.byType(HangoutChat))).setFlag('enter_sends', on);
      await tester.pump();
      int sent() => route.said.where((m) => m['t'] == 'msg').length;

      await _type(tester, 'first line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sent(), 0, reason: 'Shift+Enter never sends');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent(), on ? 1 : 0);
      if (on) {
        expect(route.said.lastWhere((m) => m['t'] == 'msg')['x'], 'first line');
        expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, isEmpty, reason: 'the box emptied');
      }
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('a face by someone\'s messages is their profile picture where they have one, asked of them once', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, :route) = _room();
    await room.open();
    // Maya is here and says she has a picture this device hasn't got; Kevin is here with none.
    room.present[_maya] = HangoutPerson(_maya, name: 'Maya Chen', pictureHash: ProfilePictures.hashOf(_red));
    room.present[_kevin] = const HangoutPerson(_kevin, name: 'Kevin Moss');
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-faces-asked');
    final faces = find.byType(SpaceFace);
    expect(faces, findsWidgets);
    expect(find.descendant(of: faces, matching: find.byType(Image)), findsNothing, reason: 'not here yet: initials');
    expect(route.said.where((m) => m['t'] == 'pic?' && m['to'] == _maya), hasLength(1), reason: 'asked of her, once');
    expect(route.said.where((m) => m['t'] == 'pic?' && m['to'] == _kevin), isEmpty, reason: 'he has none');

    // Her answer comes and is kept: her face is her picture.
    ProfilePictures.instance.keep(_maya, _red);
    await tester.pump();
    final mayaFace = find.byWidgetPredicate((w) => w is SpaceFace && w.id == _maya);
    expect(find.descendant(of: mayaFace, matching: find.byType(Image)), findsOneWidget);
    final kevinFace = find.byWidgetPredicate((w) => w is SpaceFace && w.id == _kevin);
    expect(find.descendant(of: kevinFace, matching: find.byType(Image)), findsNothing);
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-faces-pictured');
    // The question's wait runs out (her answer was kept by another way here).
    await tester.pump(const Duration(seconds: 7));
  });
}
