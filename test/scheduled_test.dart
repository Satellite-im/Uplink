import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/scheduled.dart';
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/ui/schedule_ui.dart';
import 'package:glacier/glacier.dart';

import 'support/space_call_harness.dart';

/// Messages scheduled from Send (lib/scheduled.dart, lib/ui/schedule_ui.dart; Matt, 2026-11-20: "Add support for
/// scheduling messages by pressing and holding or right clicking on the send button").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var clock = DateTime(2026, 11, 20, 14, 0);
  final sent = <ScheduledMessage>[];
  var answer = true;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    clock = DateTime(2026, 11, 20, 14, 0);
    sent.clear();
    answer = true;
    Scheduled.instance.reset();
    Scheduled.now = () => clock;
    Scheduled.sender = (m) async {
      if (answer) sent.add(m);
      return answer;
    };
  });
  tearDown(() => Scheduled.instance.reset());

  const to = (kind: 'text', target: '+15551230001', who: 'Maya Chen');

  test('a message waits for its time, then goes once, and is kept between runs', () async {
    final app = AppState();
    Scheduled.instance.start(app);
    Scheduled.instance.add(to, 'Happy birthday!', DateTime(2026, 11, 21, 9));
    expect(jsonDecode(app.choice(Scheduled.storeKey, '[]')), hasLength(1), reason: 'kept with the app\'s choices');

    await Scheduled.instance.sendDue();
    expect(sent, isEmpty, reason: 'not yet');

    // The app opened again the next morning: read back, and sent as it starts.
    Scheduled.instance.reset();
    clock = DateTime(2026, 11, 21, 9, 3);
    Scheduled.instance.start(app);
    await pumpEventQueue();
    expect(sent.map((m) => m.text), ['Happy birthday!']);
    expect(sent.single.target, '+15551230001');
    expect(Scheduled.instance.all, isEmpty);
    await Scheduled.instance.sendDue();
    expect(sent, hasLength(1), reason: 'sent once');
  });

  test('one that fails is tried again, then waits for Send now', () async {
    Scheduled.instance.start(AppState());
    final m = Scheduled.instance.add(to, 'On my way', DateTime(2026, 11, 20, 14, 30));
    clock = DateTime(2026, 11, 20, 15);
    answer = false;
    for (var i = 0; i < Scheduled.maxTries + 2; i++) {
      await Scheduled.instance.sendDue();
    }
    final stuck = Scheduled.instance.all.single;
    expect(stuck.tries, Scheduled.maxTries, reason: 'no more tries once stuck');
    expect(stuck.stuck, isTrue);
    answer = true;
    expect(await Scheduled.instance.sendNow(m.id), isTrue);
    expect(sent.single.text, 'On my way');
    expect(Scheduled.instance.all, isEmpty);
  });

  test('cancelled, it never goes; each conversation sees only its own', () async {
    Scheduled.instance.start(AppState());
    final a = Scheduled.instance.add(to, 'one', DateTime(2026, 11, 20, 15));
    Scheduled.instance.add((kind: 'space', target: 'abc', who: 'Lounge'), 'two', DateTime(2026, 11, 20, 15));
    expect(Scheduled.instance.forConversation('text', '+15551230001').map((m) => m.text), ['one']);
    Scheduled.instance.cancel(a.id);
    clock = DateTime(2026, 11, 20, 16);
    await Scheduled.instance.sendDue();
    expect(sent.map((m) => m.text), ['two']);
  });

  test('times are said as a person would, and the suggestions are ahead', () {
    final now = DateTime(2026, 11, 20, 14); // a Friday
    expect(scheduleWhen(DateTime(2026, 11, 20, 18), now), 'Today, 6:00 PM');
    expect(scheduleWhen(DateTime(2026, 11, 21, 9), now), 'Tomorrow, 9:00 AM');
    expect(scheduleWhen(DateTime(2026, 11, 23, 9), now), 'Monday, 9:00 AM');
    expect(scheduleWhen(DateTime(2026, 12, 2, 9), now), 'Dec 2, 9:00 AM');
    final offered = scheduleSuggestions(now);
    expect(offered.map((o) => o.$1), ['In 1 hour', 'This evening', 'Tomorrow morning', 'Monday morning']);
    expect(offered.every((o) => o.$2.isAfter(now)), isTrue);
    expect(scheduleSuggestions(DateTime(2026, 11, 18, 20)).map((o) => o.$1), ['In 1 hour', 'Tomorrow morning'], reason: 'a Wednesday evening');
  });

  testWidgets('Send pressed and held, or right-clicked, offers Send later', (tester) async {
    final h = await SpaceHarness.load(tester);
    Scheduled.instance.start(AppState());
    final text = TextEditingController(text: 'See you at 8');
    var sends = 0;
    await h.shoot(
      tester,
      Builder(
        builder: (context) {
          final buttons = composerButtons(
            context.tokens,
            hasSomething: true,
            onAttach: null,
            onSticker: null,
            onRecord: null,
            onSend: () => sends++,
            onSendMenu: () => openSendMenu(context, to: to, text: text.text, onScheduled: text.clear),
          );
          return Align(alignment: Alignment.bottomCenter, child: Column(mainAxisSize: MainAxisSize.min, children: [const ScheduledStrip(to: to), Row(children: buttons.ends)]));
        },
      ),
      'schedule-send-menu',
    );
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pump();
    expect(sends, 1, reason: 'a tap still sends');

    await tester.longPress(find.byKey(const ValueKey('composer-send')));
    await tester.pumpAndSettle();
    expect(find.text('Send later'), findsOneWidget);
    expect(find.text('Tomorrow morning'), findsOneWidget);
    await tester.tap(find.text('Tomorrow morning'));
    await tester.pumpAndSettle();
    expect(text.text, isEmpty, reason: 'what was written is kept for later, not left in the box');
    final m = Scheduled.instance.all.single;
    expect(m.text, 'See you at 8');
    expect(m.when, DateTime(2026, 11, 21, 9));
    expect(find.text('Tomorrow, 9:00 AM'), findsOneWidget, reason: 'shown over the composer');
    expect(sends, 1);

    // Right-clicked, on a computer.
    text.text = 'Again';
    await tester.tap(find.byKey(const ValueKey('composer-send')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Send later'), findsOneWidget);
    await tester.tap(find.text('In 1 hour'));
    await tester.pumpAndSettle();
    expect(Scheduled.instance.all.map((m) => m.text), ['Again', 'See you at 8']);

    // The strip's row: Cancel (once the toast saying it was scheduled has gone).
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Today, 3:00 PM'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(Scheduled.instance.all.map((m) => m.text), ['See you at 8']);
    Scheduled.instance.reset(); // its timer, before the test's end looks for any left
  });
}
