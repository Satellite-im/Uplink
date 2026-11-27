import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:glacier/glacier.dart' show GlacierSearchField;

import 'support/list_harness.dart';

/// The list on the screen (Matt, 2026-11-26: "clicking a message to read it shoots it down the list if it's old which
/// is un desirable"): an old unread conversation stands near the top; read, it stays where it is for as long as the
/// list is looked at, and goes to where its date puts it once the app is left (lib/ui/list_order.dart).

List<Map<String, Object?>> _phone() => [
      ListPhone.conversation(1, '+15551230001', 'See you at 7', name: 'Maya Chen', minutes: 2),
      ListPhone.conversation(2, '+15551230002', 'Running late', name: 'Dad', minutes: 6, unread: true),
      ListPhone.conversation(3, '+15551230003', 'Thanks!', name: 'Priya Natarajan', minutes: 45),
      // Three weeks old and never opened.
      ListPhone.conversation(4, '+15551230004', 'Your parcel is at the depot', name: 'Parcel Desk', minutes: 30000, unread: true),
      ListPhone.conversation(5, '+15551230005', 'Happy birthday', name: 'Jo Park', minutes: 50000),
    ];

/// The names of the rows from the top of the screen down.
List<String> _drawn(WidgetTester tester) {
  final at = <String, double>{};
  for (final e in find.byType(ConversationRow).evaluate()) {
    at[(e.widget as ConversationRow).conversation.title] = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
  }
  return at.keys.toList()..sort((a, b) => at[a]!.compareTo(at[b]!));
}

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  tester.binding.handleAppLifecycleStateChanged(state);
  await settle(tester);
}

void main() {
  late PluginRegistry shipped;
  setUp(() {
    shipped = PluginRegistry.instance;
    PluginRegistry.instance = PluginRegistry(const []);
  });
  tearDown(() => PluginRegistry.instance = shipped);

  testWidgets('read, an old conversation stays where it is; the app left, the list is put straight', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    // Unread first, the newest of them at the top; then what is read, the newest first.
    expect(_drawn(tester), ['Dad', 'Parcel Desk', 'Maya Chen', 'Priya Natarajan', 'Jo Park']);

    // The old one is read (as its conversation does on being opened).
    await tester.runAsync(() => Sms.instance.markRead(4));
    await settle(tester);
    expect(phone.asked, ['markRead 4']);
    expect([phone.alone, phone.lots], [[4], [0]], reason: 'its row alone is read again, not the list');
    expect(tester.widget<ConversationRow>(find.widgetWithText(ConversationRow, 'Parcel Desk')).conversation.unread, isFalse);
    expect(_drawn(tester), ['Dad', 'Parcel Desk', 'Maya Chen', 'Priya Natarajan', 'Jo Park'], reason: 'nothing moved');
    // The keys that step through conversations go by the order drawn.
    expect([for (final c in ConversationsScreen.live!.order) c.title], _drawn(tester));

    // A text comes in another conversation: that one goes to the top, and nothing else changes places.
    phone.conversations[2] = ListPhone.conversation(3, '+15551230003', 'One more thing', name: 'Priya Natarajan', minutes: 0, unread: true);
    Sms.instance.changes.add(3);
    await settle(tester);
    expect(_drawn(tester), ['Priya Natarajan', 'Dad', 'Parcel Desk', 'Maya Chen', 'Jo Park']);

    // The app is left: the one that was read goes to where its date puts it, with nobody looking.
    await _lifecycle(tester, AppLifecycleState.inactive);
    expect(_drawn(tester), ['Priya Natarajan', 'Dad', 'Maya Chen', 'Parcel Desk', 'Jo Park']);
    // Come back to: as it was left.
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(_drawn(tester), ['Priya Natarajan', 'Dad', 'Maya Chen', 'Parcel Desk', 'Jo Park']);

    // Read while the app is away (on another device): straight to its place, never held.
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      await _lifecycle(tester, s);
    }
    phone.conversations[1]['unread'] = false;
    Sms.instance.changes.add(2);
    await settle(tester);
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      await _lifecycle(tester, s);
    }
    expect(_drawn(tester), ['Priya Natarajan', 'Maya Chen', 'Dad', 'Parcel Desk', 'Jo Park']);
  });

  testWidgets('pressed and come back from, the conversation is where it was, read', (tester) async {
    final phone = ListPhone(_phone())..install();
    phone.messages[4] = [
      {'id': 1, 'kind': 'sms', 'address': '+15551230004', 'body': 'Your parcel is at the depot', 'date': 1, 'outgoing': false, 'state': 'received', 'read': false, 'thread': 4},
    ];
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    expect(_drawn(tester).take(2), ['Dad', 'Parcel Desk']);
    await tester.tap(find.text('Parcel Desk'));
    await settle(tester);
    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(phone.asked, contains('markRead 4'));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await settle(tester);
    expect(find.byType(ThreadScreen), findsNothing);
    expect(_drawn(tester), ['Dad', 'Parcel Desk', 'Maya Chen', 'Priya Natarajan', 'Jo Park']);
    expect(tester.widget<ConversationRow>(find.widgetWithText(ConversationRow, 'Parcel Desk')).conversation.unread, isFalse);
    // Coming back reads that conversation's row and the newest ones: not every conversation over again.
    expect(phone.lots.where((at) => at > 0), isEmpty);
  });

  testWidgets('every one marked read at once: nothing moves', (tester) async {
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    final before = _drawn(tester);
    await tester.tap(find.byKey(const ValueKey('quick-mark-read')));
    await settle(tester);
    expect(phone.asked, containsAll(['markRead 2', 'markRead 4']));
    expect(_drawn(tester), before);
    expect(tester.widgetList<ConversationRow>(find.byType(ConversationRow)).where((r) => r.conversation.unread), isEmpty);
  });

  testWidgets('a search begun and ended lets go of what was held: the list is as its dates have it', (tester) async {
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    phone.conversations[3]['unread'] = false;
    Sms.instance.changes.add(4);
    await settle(tester);
    expect(_drawn(tester), ['Dad', 'Parcel Desk', 'Maya Chen', 'Priya Natarajan', 'Jo Park']);
    tester.widget<GlacierSearchField>(find.byType(GlacierSearchField)).onValueChange!('par');
    await settle(tester);
    expect(_drawn(tester), ['Jo Park', 'Parcel Desk'].where((n) => n.toLowerCase().contains('par')).toList()..sort((a, b) => a == 'Parcel Desk' ? -1 : 1));
    tester.widget<GlacierSearchField>(find.byType(GlacierSearchField)).onValueChange!('');
    await settle(tester);
    expect(_drawn(tester), ['Dad', 'Maya Chen', 'Priya Natarajan', 'Parcel Desk', 'Jo Park']);
  });
}
