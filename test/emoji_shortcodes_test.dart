import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/emoji_data.dart';
import 'package:ghost_messaging/emoji_shortcodes.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';
import 'support/space_call_harness.dart';

/// Emoji by shortcode in the composer (GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji
/// to the joy emoji and auto suggest with a popup"): the rules (lib/emoji_shortcodes.dart), then a space's chat and a
/// conversation of texts on the screen (lib/ui/emoji_suggestions.dart).
final _data = EmojiData.parse(File('assets/emoji/emoji.tsv').readAsStringSync());
final _codes = EmojiShortcodes.of(_data);

TextEditingValue _v(String text, [int? cursor]) => TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length));

/// [was] with [typed] written at its end, as a keyboard does it, and what the composer makes of it.
String _typing(String was, String typed) => (_codes.expand(_v(was), _v('$was$typed')) ?? _v('$was$typed')).text;

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;
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

({HangoutRoom room, _Route route}) _room() {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: 'c' * 64);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  store.keepMessages(channel.chatRoom, [HangoutMessage(id: '1', from: 'a' * 32, name: 'Maya Chen', text: 'Morning all!', at: DateTime(2026, 11, 22, 9).millisecondsSinceEpoch)]);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}

Future<void> _type(WidgetTester tester, String words) async {
  await tester.showKeyboard(find.byType(EditableText));
  tester.testTextInput.updateEditingValue(_v(words));
  await tester.pump();
}

String _field(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).controller.text;

final _popup = find.byKey(const ValueKey('emoji-suggestions'));

void main() {
  group('the rules', () {
    test('a whole known shortcode becomes its emoji as its closing colon is typed', () {
      expect(_typing('hi :joy', ':'), 'hi 😂');
      expect(_typing(':joy', ':'), '😂');
      expect(_typing('(:fire', ':'), '(🔥');
      expect(_typing('😂:joy', ':'), '😂😂', reason: 'one straight after another');
    });

    test('times, links, unknown names and colons inside words are left alone', () {
      expect(_typing('10:30', ':'), '10:30:');
      expect(_typing('at 10:30:45', ':'), 'at 10:30:45:');
      expect(_typing('see https', ':'), 'see https:');
      expect(_typing('a :nope', ':'), 'a :nope:');
      expect(_typing('word:joy', ':'), 'word:joy:', reason: 'no gap before the opening colon');
      expect(_typing('hi :', ':'), 'hi ::');
    });

    test('words put in whole, a draft or a paste, keep their shortcodes as written', () {
      expect(_codes.expand(_v(''), _v('hi :joy:')), isNull);
      expect(_codes.expand(_v('hi :joy: there'), _v('hi :joy: there', 8)), isNull, reason: 'the cursor moved, nothing typed');
    });

    test('the Slack and GitHub names the ticket asks for are all there', () {
      const names = {
        'joy': '😂', 'heart': '❤️', 'thumbsup': '👍', '+1': '👍', 'fire': '🔥', 'smile': '😄', 'sob': '😭', 'tada': '🎉',
        'eyes': '👀', 'pray': '🙏', '100': '💯', 'ok_hand': '👌', 'wave': '👋', 'rocket': '🚀', '-1': '👎',
      };
      for (final MapEntry(:key, :value) in names.entries) {
        expect(_codes.emojiFor(key), value, reason: ':$key:');
      }
    });

    test('a query is a colon after a gap and at least two letters', () {
      expect(ShortcodeQuery.at('hi :jo', 6), const ShortcodeQuery(3, 'jo'));
      expect(ShortcodeQuery.at(':+1', 3), const ShortcodeQuery(0, '+1'));
      expect(ShortcodeQuery.at('hi :j', 5), isNull, reason: 'one letter');
      expect(ShortcodeQuery.at('10:30', 5), isNull);
      expect(ShortcodeQuery.at('hi :jo there', 12), isNull);
    });

    test('matches: the name itself, then names that start with it, then names with it inside; used lately first', () {
      final thu = _codes.match('thu');
      expect(thu.first.emoji, '👍');
      expect(thu.map((m) => m.emoji), contains('👎'));
      expect(thu.length, lessThanOrEqualTo(EmojiShortcodes.most));
      expect(_codes.match('joy').first.emoji, '😂', reason: 'the name itself first');
      final heart = _codes.match('heart');
      expect(heart.first.emoji, '❤️');
      final rest = heart.skip(1).map((m) => m.emoji).toList();
      final liked = rest.last;
      expect(_codes.match('heart', recent: [liked])[1].emoji, liked, reason: 'used lately: first after the exact name');
      final ok = _codes.match('hand');
      expect(ok.every((m) => m.code.contains('hand')), isTrue);
      final starts = ok.indexWhere((m) => !m.code.startsWith('hand'));
      if (starts >= 0) expect(ok.skip(starts).every((m) => !m.code.startsWith('hand')), isTrue, reason: 'starts-with before contains');
    });
  });

  group('a space\'s chat', () {
    testWidgets('":joy:" becomes 😂; "10:30:" and ":nope:" stay', (tester) async {
      final h = await SpaceHarness.load(tester);
      await tester.runAsync(EmojiData.load);
      final (:room, route: _) = _room();
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'emoji-shortcodes-expand');
      await _type(tester, 'hi :joy');
      expect(_popup, findsOneWidget, reason: 'offered while it is written');
      await _type(tester, 'hi :joy:');
      expect(_field(tester), 'hi 😂');
      expect(_popup, findsNothing);
      await _type(tester, '10:30');
      await _type(tester, '10:30:');
      expect(_field(tester), '10:30:');
      await _type(tester, ':nope');
      await _type(tester, ':nope:');
      expect(_field(tester), ':nope:');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('":thu" offers 👍; Enter puts it in without sending, a press does too, Escape closes; Enter sends with no list', (tester) async {
      final h = await SpaceHarness.load(tester);
      await tester.runAsync(EmojiData.load);
      final (:room, :route) = _room();
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'emoji-shortcodes-popup');
      AppState.of(tester.element(find.byType(HangoutChat))).setFlag('enter_sends', true);
      await tester.pump();

      await _type(tester, 'nice :thu');
      expect(_popup, findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-suggestion-thumbsup')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_field(tester), 'nice 👍');
      expect(route.said.where((m) => m['t'] == 'msg'), isEmpty, reason: 'Enter picked, it did not send');
      expect(_popup, findsNothing);

      await _type(tester, 'nice 👍 :thu');
      await tester.tap(find.byKey(const ValueKey('emoji-suggestion-thumbsup')));
      await tester.pump();
      expect(_field(tester), 'nice 👍 👍');

      await _type(tester, 'ok :thu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_popup, findsNothing);
      expect(_field(tester), 'ok :thu', reason: 'closed, the words as written');
      await _type(tester, 'ok :thum');
      expect(_popup, findsOneWidget, reason: 'opens again as the query changes');

      await _type(tester, 'see you there');
      expect(_popup, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(route.said.where((m) => m['t'] == 'msg').map((m) => m['x']), ['see you there'], reason: 'with no list, Enter sends');
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('a conversation of texts: ":joy:" becomes 😂, ":thu" offers 👍 and Enter puts it in', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'status':
          return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
        case 'messages':
          return const [];
        case 'e2e':
          return {'address': (call.arguments as Map)['address'], 'state': 'none', 'verified': false, 'changed': false};
        case 'prefs':
          return <String, String>{};
        case 'ghostPeers':
        case 'netSmsAvailable':
          return false;
        default:
          return null;
      }
    });
    await tester.runAsync(EmojiData.load);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: 7, people: [Person(address: '+15551230007', name: 'Person 7')]), AppState());
    await _type(tester, 'hi :joy');
    await _type(tester, 'hi :joy:');
    expect(_field(tester), 'hi 😂');
    await _type(tester, 'hi 😂 :thu');
    expect(_popup, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_field(tester), 'hi 😂 👍');
    expect(_popup, findsNothing);
    await _type(tester, 'hi 😂 👍 :thu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_popup, findsNothing);
    await settle(tester);
  });
}
