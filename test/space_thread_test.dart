import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/snooze.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/space_thread.dart';

import 'support/space_call_harness.dart';

/// Threads in a space's chat (GMFB-36, from the Uplink gap review): a thread's replies stay off the chat, a line under
/// the message says how many and who wrote last, and pressing it opens the thread with its replies and a box: its page on
/// a phone, a panel beside the chat in a wide window. And one message snoozed, back pinned at the top of the chat.
void main() {
  testWidgets('the chat shows a thread\'s line, not its replies; the line opens the thread', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final room = h.room(threaded: true);
    expect(room.timeline.length, 4);
    await h.shoot(tester, HangoutChat(room: room), 'thread-chat', size: SpaceHarness.phone);
    expect(tester.takeException(), isNull);
    expect(find.text('Which movie?'), findsNothing, reason: 'a thread\'s reply is not in the chat');
    expect(find.text('2 replies'), findsOneWidget);
    await tester.tap(find.text('2 replies'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(SpaceThreadScreen), findsOneWidget);
    expect(find.text('Starting the movie in 10, hop in'), findsWidgets);
    expect(find.text('Which movie?'), findsOneWidget);
    expect(find.text('The new one with the robots'), findsOneWidget);
    expect(find.text('Reply in thread'), findsOneWidget, reason: 'the box');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in a wide window the thread opens as a panel beside the chat, with its replies, a box and a cross', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final room = h.room(threaded: true);
    await h.shoot(tester, HangoutChat(room: room), 'thread-panel', size: SpaceHarness.computer);
    expect(tester.takeException(), isNull);
    expect(find.text('2 replies'), findsOneWidget, reason: 'the count stays under the message');
    await tester.tap(find.text('2 replies'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(SpaceThreadScreen), findsNothing, reason: 'no page over the chat');
    expect(find.byType(SpaceThreadPanel), findsOneWidget);
    expect(find.text('Which movie?'), findsOneWidget);
    expect(find.text('The new one with the robots'), findsOneWidget);
    expect(find.text('Reply in thread'), findsOneWidget, reason: 'the box');
    expect(find.text('Saving you a seat'), findsOneWidget, reason: 'the chat beside it');
    final chat = tester.getRect(find.text('Saving you a seat'));
    final panel = tester.getRect(find.byType(SpaceThreadPanel));
    expect(panel.left, greaterThan(chat.right), reason: 'at the chat\'s right');
    expect(panel.width, inInclusiveRange(300, 420));
    await h.again(tester, 'thread-panel-open');
    await tester.tap(find.byKey(const ValueKey('thread-panel-close')));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(SpaceThreadPanel), findsNothing);
    expect(find.text('Which movie?'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a snoozed message comes back pinned at the top of the chat; pressed, it is shown and the pin goes (GMFB-36)', (tester) async {
    var now = DateTime(2026, 11, 22, 14);
    Snoozed.now = () => now;
    Snoozed.instance.reset();
    addTearDown(() {
      Snoozed.instance.reset();
      Snoozed.now = DateTime.now;
    });
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final room = h.room(threaded: true);
    final chat = Snoozed.space(room.channel.room);
    Snoozed.instance.snoozeMessage(chat, '2', now.add(const Duration(hours: 1)), title: room.channel.name, words: 'Bring snacks 🍿');
    Snoozed.instance.snoozeMessage(chat, 't1', now.add(const Duration(hours: 1)), title: room.channel.name, words: 'Which movie?');
    await h.shoot(tester, HangoutChat(room: room), 'snoozed-message', size: SpaceHarness.phone);
    expect(find.text('Back from snooze'), findsNothing);
    now = now.add(const Duration(hours: 2));
    Snoozed.instance.wakeDue();
    await tester.pump();
    expect(find.text('Back from snooze'), findsNWidgets(2));
    expect(find.text('Bring snacks 🍿'), findsNWidgets(2), reason: 'the pin and the message');
    // A message in the chat: scrolled to, and its pin put away.
    await tester.tap(find.text('Bring snacks 🍿').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(Snoozed.instance.remindersIn(chat).map((r) => r.id), ['t1']);
    expect(find.text('Back from snooze'), findsOneWidget);
    // A reply in a thread: its thread opens (its page on a phone).
    await tester.tap(find.text('Which movie?'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byType(SpaceThreadScreen), findsOneWidget);
    expect(Snoozed.instance.remindersIn(chat), isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a message\'s menu has Snooze… with the conversation\'s times (GMFB-36)', (tester) async {
    Snoozed.instance.reset();
    addTearDown(Snoozed.instance.reset);
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final room = h.room();
    await h.shoot(tester, HangoutChat(room: room), 'snooze-menu', size: SpaceHarness.phone);
    await tester.longPress(find.text('On my way!'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('Snooze…'), findsOneWidget);
    await tester.tap(find.text('Snooze…'));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.text('Until tomorrow (9 AM)'), findsOneWidget);
    await tester.tap(find.text('Until tomorrow (9 AM)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(Snoozed.instance.messageUntil(Snoozed.space(room.channel.room), '3'), isNotNull);
    // The toast's own timer is let run out.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
  });

  test('how long ago, shortly', () {
    final now = DateTime(2026, 11, 22, 12);
    expect(ago(now.subtract(const Duration(seconds: 20)), now), 'now');
    expect(ago(now.subtract(const Duration(minutes: 5)), now), '5m');
    expect(ago(now.subtract(const Duration(hours: 3)), now), '3h');
    expect(ago(now.subtract(const Duration(days: 2)), now), '2d');
  });
}
