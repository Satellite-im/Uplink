import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/signal.dart';
import 'package:ghost_messaging/inbox/telegram.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/reaction_stickers.dart';

import 'support/list_harness.dart';

/// Reacting to and replying to a Signal or Telegram message (Matt, 2026-11-17: "Id like to be able to reply to messages
/// as well as react to telegram and signal messages if possible").
class _Net extends InboxNetwork {
  final reacted = <(String, String, bool)>[];
  final replied = <(String, String)>[];
  final sent = <String>[];
  var list = <InboxMessage>[
    InboxMessage(id: '1', text: 'are you coming tonight?', date: DateTime(2026, 11, 17, 9), mine: false, sender: 'Jo', reactions: const [InboxReaction(emoji: '❤️', count: 2, mine: true)]),
    InboxMessage(id: '2', text: 'yes!', date: DateTime(2026, 11, 17, 9, 1), mine: true, replyTo: '1', replyText: 'are you coming tonight?', replySender: 'Jo'),
  ];

  @override
  String get id => 'signal';
  @override
  String get name => 'Signal';
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => [InboxChat(network: 'signal', id: 'c1', title: 'Jo', date: DateTime(2026, 11, 17, 9, 1), snippet: 'yes!')];
  @override
  List<InboxMessage> messagesOf(String chatId) => list;
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async => sent.add(text);
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
  @override
  bool get canReact => true;
  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async => reacted.add((messageId, emoji, remove));
  @override
  bool get canReply => true;
  @override
  Future<void> reply(String chatId, String messageId, String text) async => replied.add((messageId, text));
}

void main() {
  test('Signal\'s reactions, one a person, as kinds: how many each and whether yours is among them', () {
    final r = signalReactions({'aci-jo': '❤️', 'aci-sam': '❤️', 'aci-me': '😂', '': '👍'}, me: 'aci-me');
    expect(r.map((x) => (x.emoji, x.count, x.mine)), [('❤️', 2, false), ('😂', 1, true), ('👍', 1, true)]);
    expect(signalReactions(null), isEmpty);
  });

  test('Telegram\'s reactions: the emoji ones, with their counts and whether this account chose them', () {
    final r = telegramReactions({
      'reactions': {
        'reactions': [
          {'type': {'@type': 'reactionTypeEmoji', 'emoji': '👍'}, 'total_count': 3, 'is_chosen': true},
          {'type': {'@type': 'reactionTypeCustomEmoji', 'custom_emoji_id': '1'}, 'total_count': 1, 'is_chosen': false},
        ],
      },
    });
    expect(r.map((x) => (x.emoji, x.count, x.mine)), [('👍', 3, true)]);
    expect(Telegram().reactionChoices, isNot(contains('😂')), reason: 'Telegram has no 😂; 🤣 stands in');
  });

  testWidgets('a long press reacts, or takes yours off; Reply quotes the message and sends as a reply', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _Net();
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'c1'), AppState());
    await settle(tester);
    // Drawn: the reply's quote, and a heart for each of the two who gave one (Matt, 2026-11-17: "show multiple
    // reactions as multiple emoji's pinned on and around the message").
    expect(find.byType(InboxQuote), findsOneWidget);
    expect(find.text('❤️'), findsNWidgets(2));
    expect(find.text('2'), findsNothing);

    await tester.longPress(find.text('are you coming tonight?').last);
    await settle(tester);
    expect(find.byType(InboxReactionRow), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(InboxReactionRow), matching: find.text('😂')));
    await settle(tester);
    expect(net.reacted.last, ('1', '😂', false));

    // Yours again takes it off.
    await tester.longPress(find.text('are you coming tonight?').last);
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(InboxReactionRow), matching: find.text('❤️')));
    await settle(tester);
    expect(net.reacted.last, ('1', '❤️', true));

    // Reply: the bar says to whom, and the words go as a reply.
    await tester.pump(const Duration(seconds: 6));
    await tester.longPress(find.text('are you coming tonight?').last);
    await settle(tester);
    await tester.tap(find.text('Reply'));
    await settle(tester);
    expect(find.text('Replying to Jo'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'on my way');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(net.replied.single, ('1', 'on my way'));
    expect(net.sent, isEmpty);
    expect(find.text('Replying to Jo'), findsNothing, reason: 'the bar goes once sent');
  });

  // Matt, 2026-11-17: "Add support for edited messages on telegram and signal and the ability to see the original
  // message".
  testWidgets('an edited message says Edited under it, and a press shows what it first said', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _Net()
      ..list = [
        InboxMessage(id: '1', text: 'see you at 9', date: DateTime(2026, 11, 17, 9), mine: false, sender: 'Jo', edited: true, versions: const ['see you at 7', 'see you at 8']),
        InboxMessage(id: '2', text: 'ok!', date: DateTime(2026, 11, 17, 9, 1), mine: true),
      ];
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'c1'), AppState());
    await settle(tester);
    expect(find.byKey(const ValueKey('edited-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('edited-2')), findsNothing);
    if (autoUpdateGoldenFiles) await expectLater(find.byType(InboxChatScreen), matchesGoldenFile('shots/x-inbox-edited.png'));
    await tester.tap(find.byKey(const ValueKey('edited-1')));
    await settle(tester);
    expect(find.text('First sent as:\nsee you at 7'), findsOneWidget);
    expect(find.text('Copy original'), findsOneWidget);
    expect(find.text('see you at 8'), findsOneWidget, reason: 'the wording between, as Edit 1');
  });

  // Matt, 2026-11-17: "Make reactions pin at randomish places slightly askue so multiple reactions look like stickers
  // plastered on and around the message without overlapping text much".
  test('a sticker lands in the same place every time, askew, along the foot or a lower corner', () {
    final a = stickerPlace('sms:7', '❤️', 0, 1), b = stickerPlace('sms:7', '❤️', 0, 1);
    expect((a.x, a.y, a.turn, a.scale), (b.x, b.y, b.turn, b.scale), reason: 'the same message and emoji: the same place');
    final six = [for (var i = 0; i < 6; i++) stickerPlace('sms:7', 'e$i', i, 6)];
    expect(six.every((p) => p.turn.abs() <= 0.3), isTrue, reason: 'at most about 17 degrees');
    expect(six.every((p) => p.scale >= 0.85 && p.scale <= 1.2), isTrue, reason: 'a little bigger or smaller, no more');
    expect(six.map((p) => p.scale).toSet().length, greaterThan(3), reason: 'each its own size');
    expect(six.every((p) => p.y >= 0.3), isTrue, reason: 'low on the bubble, clear of most of its words');
    expect(six.where((p) => p.out != 0), isNotEmpty, reason: 'with many, some go on a corner\'s side');
    expect(six.map((p) => p.turn).toSet().length, greaterThan(3), reason: 'each leans its own way');
  });

  testWidgets('stickers on messages with one, three and six reactions', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _Net()
      ..list = [
        InboxMessage(id: '1', text: 'are you coming tonight?', date: DateTime(2026, 11, 17, 9), mine: false, sender: 'Jo', reactions: const [InboxReaction(emoji: '❤️')]),
        InboxMessage(id: '2', text: 'Damn we were going to have a Steve and Katelynn were coming over party', date: DateTime(2026, 11, 17, 9, 1), mine: true, reactions: const [InboxReaction(emoji: '😂', count: 3), InboxReaction(emoji: '❤️'), InboxReaction(emoji: '🔥')]),
        InboxMessage(id: '3', text: 'lol ask him, he\'s the boss', date: DateTime(2026, 11, 17, 9, 2), mine: false, sender: 'Katelynn', reactions: const [
          InboxReaction(emoji: '❤️'), InboxReaction(emoji: '😂'), InboxReaction(emoji: '👍'), InboxReaction(emoji: '🔥'), InboxReaction(emoji: '🎉'), InboxReaction(emoji: '😮'),
        ]),
      ];
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'c1'), AppState());
    await settle(tester);
    expect(find.byType(ReactionStickers), findsNWidgets(3));
    // Three laughs are three laughing faces on the second message, beside its heart and fire.
    expect(find.descendant(of: find.byType(ReactionStickers).at(1), matching: find.text('😂')), findsNWidgets(3));
    if (autoUpdateGoldenFiles) await expectLater(find.byType(InboxChatScreen), matchesGoldenFile('shots/x-reaction-stickers.png'));
  });
}
