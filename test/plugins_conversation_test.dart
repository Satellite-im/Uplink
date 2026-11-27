import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/conversation.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/common.dart';

import 'support/list_harness.dart';
import 'support/test_plugins.dart';

/// The three slots in a conversation (its header, its composer, a message's menu) as lib/plugins/conversation.dart
/// answers them, on a page made for the test: lib/ui/thread.dart does not ask for them yet.
Message _message(String body, {bool outgoing = false}) => Message(id: 1, kind: 'sms', address: outgoing ? '' : '70001', body: body, date: DateTime(2026), outgoing: outgoing, state: 'received');

class _Page extends StatelessWidget {
  const _Page(this.plugins, this.newest);
  final ConversationPlugins plugins;
  final Message newest;

  @override
  Widget build(BuildContext context) => GhostPage(
        title: 'A conversation',
        actions: plugins.header(context, newest: newest),
        body: Column(children: [
          Row(children: plugins.composer(context, text: 'so far')),
          IconTap(icon: Lucide.ellipsis, label: 'Menu', onPressed: () => showChoices(context, choices: plugins.message(context, newest))),
        ]),
      );
}

Finder _icon(String label) => find.byWidgetPredicate((w) => w is IconTap && w.label == label);

void main() {
  late PluginRegistry shipped;
  setUp(() => shipped = PluginRegistry.instance);
  tearDown(() => PluginRegistry.instance = shipped);

  testWidgets('a plugin\'s buttons for the header and the composer, and its line in a message\'s menu, each do their work', (tester) async {
    final registry = PluginRegistry([TicketsPlugin()]);
    final phone = ListPhone([])..install();
    final sheet = await loadSheet(tester);
    final wrote = <String>[];
    final plugins = ConversationPlugins(thread: 7, people: () => const [Person(address: '70001')], write: wrote.add, registry: registry);
    await pumpScreen(tester, sheet, _Page(plugins, _message('Your ticket 4411 is ready')), AppState());

    // The header: the plugin's button for a conversation whose newest words name a ticket.
    await tester.tap(_icon('Copy 4411'));
    await settle(tester);
    expect(phone.copied, ['4411']);
    expect(find.text('Copied 4411'), findsOneWidget);

    // The composer: its button writes into the message.
    await tester.tap(_icon('Ask for a ticket'));
    await settle(tester);
    expect(wrote, ['Ticket please']);

    // A message's menu: its line, which copies. (The first copy's toast is let pass: it is where the menu rises.)
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.tap(_icon('Menu'));
    await settle(tester);
    await tester.tap(find.text('Copy 4411').last);
    await settle(tester);
    expect(phone.copied, ['4411', '4411']);
  });

  testWidgets('with the plugin off, or a message it has nothing for, there is nothing to draw', (tester) async {
    final plugin = TicketsPlugin();
    final registry = PluginRegistry([plugin]);
    ListPhone([]).install();
    final sheet = await loadSheet(tester);
    final plugins = ConversationPlugins(thread: 7, people: () => const [Person(address: '70001')], registry: registry);
    final state = AppState();
    await pumpScreen(tester, sheet, _Page(plugins, _message('See you at 7')), state);
    expect(_icon('Copy 4411'), findsNothing);
    expect(_icon('Ask for a ticket'), findsOneWidget);
    final context = tester.element(find.byType(_Page));
    expect(plugins.message(context, _message('See you at 7')), isEmpty);
    state.setFlag(PluginRegistry.switchKey(plugin), false);
    await settle(tester);
    expect(_icon('Ask for a ticket'), findsNothing);
    expect(plugins.message(context, _message('Your ticket 4411 is ready')), isEmpty);
  });

  testWidgets('as the app ships, a message with a sign-in code has "Copy 482913" in its menu, and one of your own does not', (tester) async {
    final phone = ListPhone([])..install();
    final sheet = await loadSheet(tester);
    final plugins = ConversationPlugins(thread: 4, people: () => const [Person(address: '28849')]);
    final code = _message('Your verification code is 482913.');
    await pumpScreen(tester, sheet, _Page(plugins, code), AppState());
    final context = tester.element(find.byType(_Page));
    // Replies' reminders are in every message's menu (lib/plugins/replies.dart); Copy is a code's alone, and not in
    // one of your own.
    expect(plugins.message(context, _message('My code is 482913', outgoing: true)).map((c) => c.label), isNot(contains('Copy 482913')));
    expect(plugins.message(context, code).map((c) => c.label).first, 'Copy 482913');
    expect(plugins.message(context, code).map((c) => c.label), contains('Remind me in an hour'));
    expect(plugins.header(context, newest: code), isEmpty, reason: 'no plugin the app ships with puts anything in the header');
    await tester.tap(_icon('Menu'));
    await settle(tester);
    await tester.tap(find.text('Copy 482913'));
    await settle(tester);
    expect(phone.copied, ['482913']);
  });
}
