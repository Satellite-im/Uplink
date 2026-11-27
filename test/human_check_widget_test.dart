import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/human_check.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/plugins/human_check.dart';

import 'human_check_test.dart' show GateNet;
import 'support/list_harness.dart';

/// The Human check's row over Messages and its page of held chats (lib/plugins/human_check.dart; GMFB-23, Matt, Mac
/// 0.12.6: "have new messages from that platform stay hidden from notificatoins and my messages until they solve a
/// small challenge").
void main() {
  tearDown(() {
    HumanCheck.instance = null;
    InboxNetwork.holding = null;
  });

  testWidgets('"N held" over Messages opens the held chats; Let in brings one into the list', (tester) async {
    final sheet = await loadSheet(tester);
    ListPhone(const []).install();
    final began = DateTime.now().subtract(const Duration(minutes: 10));
    final net = GateNet('signal');
    final kept = <String, String>{};
    final check = HumanCheck(choices: () => const HumanCheckChoices(networks: {'signal'}), read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v, now: () => began);
    final inbox = Inbox.of([net]);
    check.watch(inbox);
    InboxChat chat(String id, String title, int minutes) => InboxChat(network: 'signal', id: id, title: title, date: began.add(Duration(minutes: minutes)), snippet: 'WHat are you doing tonight?', unread: 1);
    await tester.runAsync(() async {
      net.set([chat('a', 'Sunny', 2), chat('b', 'Rex', 3)]);
      await pumpEventQueue();
    });
    expect(net.shownChats, isEmpty);

    await pumpScreen(tester, sheet, Column(children: [HeldRow(check: check, inbox: inbox), const Expanded(child: SizedBox())]), AppState());
    expect(find.text('2 held for a human check'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('humancheck-held-row')));
    await settle(tester);
    expect(find.byKey(const ValueKey('humancheck-held-signal:a')), findsOneWidget);
    expect(find.text('Asked · waiting for an answer'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('humancheck-held-signal:a')));
    await settle(tester);
    expect(find.text('Block'), findsOneWidget);
    await tester.tap(find.text('Let in'));
    await settle(tester);
    expect(find.byKey(const ValueKey('humancheck-held-signal:a')), findsNothing);
    expect(find.byKey(const ValueKey('humancheck-held-signal:b')), findsOneWidget);
    expect(net.shownChats.map((c) => c.id), ['a']);
    expect(check.recordOf('signal', 'a')!.state, HoldState.released);
  });

  testWidgets('nothing held: no row', (tester) async {
    final sheet = await loadSheet(tester);
    ListPhone(const []).install();
    final check = HumanCheck(choices: () => const HumanCheckChoices(networks: {'signal'}), read: (_) => '', write: (_, _) {});
    final inbox = Inbox.of([GateNet('signal')]);
    await pumpScreen(tester, sheet, Column(children: [HeldRow(check: check, inbox: inbox), const Expanded(child: SizedBox())]), AppState());
    expect(find.byKey(const ValueKey('humancheck-held-row')), findsNothing);
  });
}
