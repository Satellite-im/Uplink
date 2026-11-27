import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/mentions.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show GhostPage, UnreadBadge;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/mention_field.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/mention_alerts.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Mentions in a space's chat on the screen (Matt, 2026-11-19: "Add mentions support to spaces and circles with the
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

/// The words a message is drawn with, as they read on the screen (a mention's label for a screen reader left out).
Finder _drawn(String words) => find.byWidgetPredicate((w) => w is Text && (w.data ?? w.textSpan?.toPlainText(includeSemanticsLabels: false)) == words);

Future<void> _type(WidgetTester tester, String words) async {
  await tester.showKeyboard(find.byType(EditableText));
  tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
  await tester.pump();
}

void main() {
  for (final circle in [true, false]) {
    testWidgets('"@" offers the people who wrote, the one picked goes in as @Name and is sent with who it means (${circle ? 'a circle\'s channel' : 'bubbles'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      final (:room, :route) = _room(circle: circle);
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-mentions-$circle');
      expect(find.byKey(const ValueKey('mention-suggestions')), findsNothing);

      await _type(tester, 'Hi @');
      expect(find.byKey(const ValueKey('mention-suggestions')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-$_maya')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-$_kevin')), findsOneWidget);

      await _type(tester, 'Hi @ma');
      expect(find.byKey(const ValueKey('mention-$_kevin')), findsNothing, reason: 'narrowed to Maya');
      await tester.tap(find.byKey(const ValueKey('mention-$_maya')));
      await tester.pump();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.text, 'Hi @Maya Chen ');
      expect(field.controller.selection.baseOffset, 'Hi @Maya Chen '.length);
      expect(find.byKey(const ValueKey('mention-suggestions')), findsNothing, reason: 'closed once picked');
      expect((field.controller as MentionController).mentions, const [Mention(3, 10, _maya)]);

      // Words after it, then sent: the message carries the mention.
      final words = 'Hi @Maya Chen see you there';
      tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pump();
      final sent = route.said.lastWhere((m) => m['t'] == 'msg');
      expect(sent['x'], words);
      expect(sent['mn'], [[3, 10, _maya]]);
      expect(room.messages.last.mentions, const [Mention(3, 10, _maya)]);
      expect(_drawn(words), findsOneWidget, reason: 'drawn with its words as they are');
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('on a keyboard: the arrows choose, Enter puts the chosen one in without sending, Escape closes the list', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, :route) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-mentions-keys');
    await _type(tester, '@');
    // Kevin wrote last, so he is first; down to Maya, and Enter.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '@Maya Chen ');
    expect(route.said.where((m) => m['t'] == 'msg'), isEmpty, reason: 'Enter picked, it did not send');

    await _type(tester, '@Maya Chen @k');
    expect(find.byKey(const ValueKey('mention-$_kevin')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('mention-suggestions')), findsNothing);
    await _type(tester, '@Maya Chen @ke');
    expect(find.byKey(const ValueKey('mention-suggestions')), findsOneWidget, reason: 'opens again as the query changes');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a message that mentions you stands out, its mention drawn in the accent, and a press on it says who', (tester) async {
    final h = await SpaceHarness.load(tester);
    final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
    final (:room, route: _) = _room(messages: (me) => [
          HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: '@Me can you look at this?', at: at, mentions: [Mention(0, 3, me)]),
          HangoutMessage(id: '2', from: _kevin, name: 'Kevin Moss', text: 'Ask @Maya Chen too', at: at + 60000, mentions: const [Mention(4, 10, _maya)]),
        ]);
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-mentions-drawn');
    // The row that mentions you has the accent's bar; the other has none.
    final marked = find.ancestor(of: _drawn('@Me can you look at this?'), matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border is Border && ((w.decoration as BoxDecoration).border as Border).left.width == 3));
    expect(marked, findsOneWidget);
    final plain = find.ancestor(of: _drawn('Ask @Maya Chen too'), matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border is Border && ((w.decoration as BoxDecoration).border as Border).left.width == 3));
    expect(plain, findsNothing);
    // Maya's name in Kevin's words is a mention, read as one.
    final rich = tester.widget<Text>(_drawn('Ask @Maya Chen too'));
    final spans = <InlineSpan>[];
    rich.textSpan!.visitChildren((s) {
      spans.add(s);
      return true;
    });
    final mention = spans.whereType<TextSpan>().firstWhere((s) => s.text == '@Maya Chen');
    expect(mention.semanticsLabel, 'Mention: Maya Chen');
    expect(mention.style?.fontWeight, FontWeight.w600);
    await tester.pump(const Duration(seconds: 1));
  });

  test('a mention of this device is notified once, not one of someone else, not one already read, not while its space is on the screen', () {
    final alerts = <MentionAlert>[];
    var front = true, on = true;
    final a = MentionAlerts(notify: alerts.add, cancel: (_) {}, inFront: () => front, on: () => on);
    final (:room, route: _) = _room(messages: (_) => const []);
    final me = room.me;
    HangoutMessage m(String id, int at, String to) => HangoutMessage(id: id, from: _maya, name: 'Maya Chen', text: '@X hi', at: at, mentions: [Mention(0, 2, to)]);
    a.heard(room, [m('1', 10, _kevin)], readAt: 0);
    expect(alerts, isEmpty, reason: 'someone else is meant');
    a.heard(room, [m('2', 10, me)], readAt: 20);
    expect(alerts, isEmpty, reason: 'read already');
    MentionAlerts.showing = room.channel.seed;
    a.heard(room, [m('3', 30, me)], readAt: 20);
    expect(alerts, isEmpty, reason: 'on the screen while the app is in front');
    front = false;
    a.heard(room, [m('4', 30, me)], readAt: 20);
    expect(alerts.single.title, 'Maya Chen in #general');
    expect(alerts.single.body, '@X hi');
    expect(alerts.single.key, MentionAlerts.keyOf(room.channel));
    on = false;
    a.heard(room, [m('5', 40, me)], readAt: 20);
    expect(alerts, hasLength(1), reason: 'switched off in Settings');
    MentionAlerts.showing = null;
  });

  testWidgets('an unread mark says "@" where something unread mentions you', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, const Center(child: Row(mainAxisSize: MainAxisSize.min, children: [UnreadBadge(count: 3, color: Color(0xFFDD3A30), mentioned: true), UnreadBadge(color: Color(0xFFDD3A30), mentioned: true), UnreadBadge(count: 2, color: Color(0xFFDD3A30))])), 'unread-mentions');
    expect(find.text('@3'), findsOneWidget);
    expect(find.text('@'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });
}
