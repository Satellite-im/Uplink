import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/list.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/settings.dart';
import 'package:ghost_messaging/plugins/ui.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';
import 'support/test_plugins.dart';

/// The list of conversations and Settings › Plugins with a plugin made up for the purpose
/// (test/support/test_plugins.dart): its section's chip and rows, what it puts in the list's slots, a conversation
/// filed by hand, a rule run on a message that has just come, and its switch.
List<Map<String, Object?>> _phone() => [
      ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4),
      ListPhone.conversation(2, '70001', 'Your ticket 4411 is ready', minutes: 9, unread: true),
      ListPhone.conversation(3, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 50),
      ListPhone.conversation(4, '70002', 'ticket 5522 was closed', minutes: 120),
      ListPhone.conversation(5, '+15551230006', 'I have ticket 77 for you', name: 'Priya Natarajan', minutes: 300),
      ListPhone.conversation(6, '70003', 'ticket 9000, long ago', minutes: 9000, archived: true),
    ];

// A tab of the list's toggle: icons alone since 2026-11-15, each named for a screen reader ("Codes", "Codes, 2"), and a
// tab's unread count is the number beside its icon.
Finder _chip(String label) => find.descendant(
      of: find.byType(SectionTabs),
      matching: find.byWidgetPredicate((w) => (w is Semantics && (w.properties.label == label || (w.properties.label ?? '').startsWith('$label, '))) || (w is Text && w.data == label)),
    );
Finder _icon(String label) => find.byWidgetPredicate((w) => w is IconTap && w.label == label);

final _markReadRow = find.byKey(const ValueKey('quick-mark-read'));
QuickRow _markRead(WidgetTester tester) => tester.widget<QuickRow>(_markReadRow);

void main() {
  late PluginRegistry shipped;
  setUp(() => shipped = PluginRegistry.instance);
  tearDown(() => PluginRegistry.instance = shipped);

  testWidgets('with no plugin the list is as it was: no chips, every conversation in it', (tester) async {
    PluginRegistry.instance = PluginRegistry(const []);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
    expect(find.byType(ConversationRow), findsNWidgets(5));
    expect(find.byType(PluginRow), findsNothing);
    expect(phone.asked, isEmpty);
  });

  testWidgets('a section has a chip while it has conversations, its own rows, and leaves the main list without them', (tester) async {
    PluginRegistry.instance = PluginRegistry([TicketsPlugin()]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    final state = AppState();
    await pumpScreen(tester, sheet, const ConversationsScreen(), state);

    // The main list: the two tickets from numbers that are not contacts have left it; a contact's has not, and the
    // archived one is nobody's.
    expect(_chip('Messages'), findsOneWidget);
    expect(_chip('Tickets'), findsOneWidget);
    // Both read: a tab counts only what is unread (Matt, 2026-11-14: "remove ... the badge count for codes that are
    // already read").
    expect(_chip('2'), findsNothing);
    expect(find.byType(ConversationRow), findsNWidgets(3));
    expect(find.text('Your ticket 4411 is ready'), findsNothing);
    expect(find.text('I have ticket 77 for you'), findsOneWidget);
    // The plugin's button is a row under the search with Mark all read, not in the header (Matt, 2026-11-20: "also the
    // clean button is still in the header we should remove that").
    expect(_icon('Ticket desk'), findsNothing);
    expect(find.byKey(const ValueKey('quick-Ticket desk')), findsOneWidget);
    expect(find.text('Tickets wait here.'), findsNothing);

    // Its chip: its own list, the newest first, each row with the number large, and its note over the list.
    await tester.tap(_chip('Tickets'));
    await settle(tester);
    expect(find.byType(PluginRow), findsNWidgets(2));
    expect(find.byType(ConversationRow), findsNothing);
    expect(tester.getCenter(find.text('4411')).dy, lessThan(tester.getCenter(find.text('5522')).dy));
    expect(find.text('Tickets wait here.'), findsOneWidget);
    expect(find.textContaining('Archived ('), findsNothing, reason: 'the way to Archived is the main list\'s');

    // A tap is the row's own: it copies, and says so. The button at its end does the same.
    await tester.tap(find.text('4411'));
    await settle(tester);
    expect(phone.copied, ['4411']);
    expect(find.text('Copied 4411'), findsOneWidget);
    await tester.tap(_icon('Copy 5522'));
    await settle(tester);
    expect(phone.copied, ['4411', '5522']);

    // Its long press offers to open it, since a tap does not, and has the plugin's own line.
    await tester.longPress(find.text('5522'));
    await settle(tester);
    expect(find.text('Open conversation'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);
    await tester.tap(find.text('Keep in Messages').last);
    await settle(tester);
    // Filed in the main list: one left in the section, and the choice is kept with the person's others.
    expect(find.byType(PluginRow), findsOneWidget);
    expect(_chip('1'), findsOneWidget);
    expect(phone.prefs[Filing.key], '4:');

    // The word on the last row does the same: the section is empty, its chip goes, and the list is the main one.
    await tester.tap(find.text('Keep in Messages'));
    await settle(tester);
    // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
    expect(find.byType(ConversationRow), findsNWidgets(5));
    expect(find.text('ticket 5522 was closed'), findsOneWidget);
    expect(phone.prefs[Filing.key], '4:,2:');

    // From the main list a conversation can be filed back: its menu has the plugin's line for that.
    await tester.longPress(find.text('ticket 5522 was closed'));
    await settle(tester);
    expect(find.text('Open conversation'), findsNothing);
    await tester.tap(find.text('Move to Tickets'));
    await settle(tester);
    expect(find.text('ticket 5522 was closed'), findsNothing, reason: 'filed in Tickets, out of the main list');
    expect(phone.prefs[Filing.key], '2:', reason: 'it is where its words put it anyway: nothing is kept for it');
  });

  testWidgets('a search from the main list looks through the sections too; from a section, through that section', (tester) async {
    PluginRegistry.instance = PluginRegistry([TicketsPlugin()]);
    ListPhone(_phone()).install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await tester.enterText(find.byType(EditableText).first, 'ticket');
    await settle(tester);
    expect(find.byType(ConversationRow), findsNWidgets(3));
    expect(find.text('Your ticket 4411 is ready'), findsOneWidget);
    await tester.tap(_chip('Tickets'));
    await settle(tester);
    expect(find.byType(PluginRow), findsNWidgets(2));
    await tester.enterText(find.byType(EditableText).first, 'closed');
    await settle(tester);
    expect(find.byType(PluginRow), findsOneWidget);
    expect(find.text('5522'), findsOneWidget);
  });

  testWidgets('the tabs are one toggle; the button beside them and a tab\'s own menu mark its conversations as read', (tester) async {
    PluginRegistry.instance = PluginRegistry([TicketsPlugin()]);
    final all = _phone();
    all[0] = ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4, unread: true);
    all[2] = ListPhone.conversation(3, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 50, unread: true);
    final phone = ListPhone(all)..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await settle(tester);
    // One segmented toggle holds the tabs, and Mark all read is at the title row's end with the main list's two
    // unread (Matt, 2026-11-14: "make the mark all read aligned to the right of the messages title row").
    expect(find.descendant(of: find.byType(SectionTabs), matching: find.byType(GlacierSegmentedControl)), findsOneWidget);
    expect(_markRead(tester).count, 2);
    // A row with its mark and its name under the search, above the toggle (Matt, 2026-11-20: "layout the mark all read
    // and the share feedback buttons to a icon list like shown in the screenshot under the searchbar"); the toggle is the
    // kit's middle size ("the segmented toggle for messages vs codes can be a size larger").
    expect(find.text('Mark all read'), findsOneWidget);
    final toggle = tester.getRect(find.byType(GlacierSegmentedControl));
    // No "Messages" over the list (Matt, 2026-11-17: "Remove the word messages from the top of the page its redundant").
    expect(find.descendant(of: find.byType(ConversationsScreen), matching: find.text('Messages')), findsNothing);
    expect(tester.getRect(_markReadRow).bottom, lessThan(toggle.top));
    expect(tester.widget<GlacierSegmentedControl>(find.byType(GlacierSegmentedControl)).size, GlacierSegmentedSize.md);

    // The button marks the tab shown: Maya's and Dad's, and not the ticket, which is in its own tab.
    phone.asked.clear();
    await tester.tap(_markReadRow);
    await settle(tester);
    expect(phone.asked.toSet(), {'markRead 1', 'markRead 3'});
    expect(find.text('2 conversations marked as read'), findsOneWidget);
    // Nothing left unread there: the row is quiet, and does nothing.
    expect(_markRead(tester).onPress, isNull);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);

    // A press with the other button on a tab brings up that tab's menu, whichever tab is shown.
    await tester.tap(_chip('Tickets'), buttons: kSecondaryButton);
    await settle(tester);
    expect(find.textContaining('Tickets ·'), findsOneWidget);
    expect(find.text('Mark all as read'), findsOneWidget);
    // Select all goes to that tab with every conversation of it chosen, for the bar at the top to act on.
    await tester.tap(find.text('Select all'));
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(_icon('Stop selecting'));
    await settle(tester);
    expect(find.byType(PluginRow), findsNWidgets(2), reason: 'it is the Tickets tab that is shown now');

    // A long press does the same where there is no other button: the main list's menu, from the Tickets tab.
    await tester.longPress(_chip('Messages'));
    await settle(tester);
    expect(find.textContaining('Messages · nothing unread'), findsOneWidget);
    phone.asked.clear();
    await tester.tap(find.text('Mark all as read'));
    await settle(tester);
    expect(phone.asked, isEmpty);
    expect(find.text('Nothing is unread in Messages'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
  });

  testWidgets('with no section to make a tab of, Mark all read is in the title row while anything is unread, and goes after', (tester) async {
    PluginRegistry.instance = PluginRegistry(const []);
    final all = _phone();
    all[0] = ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4, unread: true);
    final phone = ListPhone(all)..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await settle(tester);
    // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
    // Conversation 2 is unread in the phone's list too: two in all.
    expect(_markRead(tester).count, 2);
    phone.asked.clear();
    await tester.tap(_markReadRow);
    await settle(tester);
    expect(phone.asked.toSet(), {'markRead 1', 'markRead 2'});
    // Nothing unread: the button goes, and with no other button the bar over the search goes too.
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(_markRead(tester).count, 0);
  });

  testWidgets('Mark all read, Share feedback and the toggle scroll away with the list; the search stays', (tester) async {
    // Matt, 2026-11-20: "scroll the share feedback mark all as read and the segmented toggle when scrolling down".
    PluginRegistry.instance = PluginRegistry(const []);
    ListPhone([for (var i = 1; i <= 40; i++) ListPhone.conversation(i, '+155512300${i.toString().padLeft(2, '0')}', 'Message $i', name: 'Person $i', minutes: i)]).install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await settle(tester);
    final search = tester.getTopLeft(find.byType(GlacierSearchField)).dy;
    final row = tester.getTopLeft(_markReadRow).dy;
    final toggle = tester.getTopLeft(find.byType(GlacierSegmentedControl)).dy;
    await tester.drag(find.text('Person 3'), const Offset(0, -120));
    await settle(tester);
    expect(tester.getTopLeft(find.byType(GlacierSearchField)).dy, search, reason: 'the search stays');
    expect(tester.getTopLeft(_markReadRow).dy, lessThan(row - 60), reason: 'Mark all read went up with the list');
    expect(tester.getTopLeft(find.byType(GlacierSegmentedControl)).dy, lessThan(toggle - 60), reason: 'and the toggle');
  });

  testWidgets('several can be chosen in a section, where a tap then chooses', (tester) async {
    PluginRegistry.instance = PluginRegistry([TicketsPlugin()]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await tester.tap(_chip('Tickets'));
    await settle(tester);
    await tester.longPress(find.text('4411'));
    await settle(tester);
    await tester.tap(find.text('Select'));
    await settle(tester);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(SectionTabs), findsNothing, reason: 'the chips give way while choosing');
    await tester.tap(find.text('5522'));
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    expect(phone.copied, isEmpty);
  });

  testWidgets('switched off, the plugin leaves the list as it was; switched on again, its section is back', (tester) async {
    final plugin = TicketsPlugin();
    PluginRegistry.instance = PluginRegistry([plugin]);
    ListPhone(_phone()).install();
    final sheet = await loadSheet(tester);
    final state = AppState();
    await pumpScreen(tester, sheet, const ConversationsScreen(), state);
    await tester.tap(_chip('Tickets'));
    await settle(tester);
    expect(find.byType(PluginRow), findsNWidgets(2));

    state.setFlag(PluginRegistry.switchKey(plugin), false);
    await settle(tester);
    // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
    expect(find.byType(PluginRow), findsNothing);
    expect(find.byType(ConversationRow), findsNWidgets(5));
    expect(_icon('Ticket desk'), findsNothing);

    state.setFlag(PluginRegistry.switchKey(plugin), true);
    await settle(tester);
    expect(_chip('Tickets'), findsOneWidget);
    expect(find.byType(ConversationRow), findsNWidgets(3));
  });

  testWidgets('a rule is run on an unread conversation as it is first seen, and a mute it asked for is undone when the conversation leaves', (tester) async {
    PluginRegistry.instance = PluginRegistry([TicketsPlugin()]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    final state = AppState()
      ..setFlag('plugin_tickets_read', true)
      ..setFlag('plugin_tickets_quiet', true);
    await pumpScreen(tester, sheet, const ConversationsScreen(), state);
    // The unread ticket, and no other: marked as read and muted, once.
    expect(phone.asked, ['markRead 2', 'muted 2 true']);
    expect(phone.prefs[ListPlugins.mutedKey], '2:tickets:tickets');
    // Read again, with the same words: nothing more is asked.
    Sms.instance.changes.add(2);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(phone.asked, ['markRead 2', 'muted 2 true']);

    // Filed back in the main list: the mute the plugin asked for is taken off.
    await tester.tap(_chip('Tickets'));
    await settle(tester);
    await tester.longPress(find.text('4411'));
    await settle(tester);
    await tester.tap(find.text('Keep in Messages').last);
    await settle(tester);
    expect(phone.asked.last, 'muted 2 false');
    expect(phone.prefs[ListPlugins.mutedKey], '');
  });

  testWidgets('a mute a plugin asked for is undone when the plugin is switched off', (tester) async {
    final plugin = TicketsPlugin();
    PluginRegistry.instance = PluginRegistry([plugin]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    final state = AppState()..setFlag('plugin_tickets_quiet', true);
    await pumpScreen(tester, sheet, const ConversationsScreen(), state);
    expect(phone.asked, ['muted 2 true']);
    state.setFlag(PluginRegistry.switchKey(plugin), false);
    await settle(tester);
    expect(phone.asked, ['muted 2 true', 'muted 2 false']);
  });

  testWidgets('Settings › Plugins: each plugin with its switch, and its own settings while it is on', (tester) async {
    final plugin = TicketsPlugin();
    final registry = PluginRegistry([plugin]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    final state = AppState();
    final model = SettingsModel(state);
    addTearDown(model.dispose);
    final section = pluginsSection(registry);
    await pumpScreen(tester, sheet, SectionPage(section: section, model: model), state);

    expect(section.summary!(model), 'Tickets');
    expect(find.text('Tickets'), findsOneWidget);
    expect(find.text('Texts with a ticket number get a section of their own.'), findsOneWidget);
    // Its own card: the rows it describes in words, then what it put in the settings slot.
    expect(find.text('Mark tickets as read'), findsOneWidget);
    expect(find.text('What a ticket is'), findsOneWidget);
    expect(find.text('A row of its own'), findsOneWidget);
    expect(find.byType(GlacierSwitch), findsNWidgets(2));

    // Its own switch is kept under its name.
    await tester.tap(find.byType(GlacierSwitch).last);
    await settle(tester);
    expect(phone.prefs['plugin_tickets_read'], 'on');

    // Switched off: its card goes, and Settings' list says none is on.
    await tester.tap(find.byType(GlacierSwitch).first);
    await settle(tester);
    expect(phone.prefs['plugin_tickets'], 'off');
    expect(find.text('Mark tickets as read'), findsNothing);
    expect(find.byType(GlacierSwitch), findsOneWidget);
    expect(section.summary!(model), 'None on');

    // Settings' search reads the page as it reads every other: the plugin and its setting are found by name.
    state.setFlag('plugin_tickets', true);
    await settle(tester);
    final context = tester.element(find.byType(SectionPage));
    final found = [for (final h in searchSettings(context, model, [section], 'ticket')) h.setting ?? h.section.label];
    expect(found, containsAll(['Tickets', 'Mark tickets as read', 'What a ticket is']));
  });

  testWidgets('a plugin that asks for one has a section of its own in Settings, its switch at the top', (tester) async {
    // Matt, 2026-11-14: "the plugins and all being able to make their own setting sections".
    final plugin = _PagedTickets();
    final registry = PluginRegistry([plugin]);
    final phone = ListPhone(_phone())..install();
    final sheet = await loadSheet(tester);
    final state = AppState();
    final model = SettingsModel(state);
    addTearDown(model.dispose);
    // One section, for the one that asked; a plugin that does not ask has none.
    expect(pluginPages(PluginRegistry([TicketsPlugin()])), isEmpty);
    final pages = pluginPages(registry);
    expect([for (final s in pages) s.id], ['plugin-paged']);
    final own = pages.single;
    expect(own.label, 'Paged tickets');
    expect(own.group, pluginsSection(registry).group, reason: 'its row is under Plugins, on the same card');
    expect(own.when, isNull, reason: 'listed on or off, so it can be switched back on from its page');
    expect(own.summary!(model), 'Left unread');

    // Its page: what it says of itself, the rows it describes in words, and what it put in the settings slot.
    await pumpScreen(tester, sheet, SectionPage(section: own, model: model), state);
    expect(find.text('Tickets, set here.'), findsOneWidget);
    expect(find.text('Mark tickets as read'), findsOneWidget);
    expect(find.text('What a ticket is'), findsOneWidget);
    expect(find.text('A row of its own'), findsOneWidget);
    // At the top, its own switch (Matt, 2026-11-14: "Plugins should be able to be toggled on and off from the top of
    // each plugin setting page"); then its settings.
    expect(tester.getRect(find.byType(GlacierSwitch).first).top, lessThan(tester.getRect(find.text('Mark tickets as read')).top));
    expect(tester.widget<GlacierSwitch>(find.byType(GlacierSwitch).first).checked, isTrue);
    await tester.tap(find.byType(GlacierSwitch).at(1));
    await settle(tester);
    expect(phone.prefs['plugin_paged_read'], 'on');
    expect(own.summary!(model), 'Read as they arrive');
    // Found by Settings' search like any other page's.
    final context = tester.element(find.byType(SectionPage));
    expect([for (final h in searchSettings(context, model, [own], 'mark tickets')) h.setting], ['Mark tickets as read']);

    // Settings › Plugins keeps its switch and leaves its settings to its own section.
    await pumpScreen(tester, sheet, SectionPage(section: pluginsSection(registry), model: model), state);
    expect(find.text('Paged tickets'), findsOneWidget);
    expect(find.byType(GlacierSwitch), findsOneWidget);
    expect(find.text('Mark tickets as read'), findsNothing);
    // Its settings are on its page in the Marketplace now (lib/ui/plugins_page; Matt, 2026-11-17: "their own dedicated
    // plugins page"; 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail").
    expect(find.textContaining('settings are on its page in the Marketplace'), findsOneWidget);

    // Switched off from the top of its own page: its settings go, its switch stays to turn it back on, and its row
    // says Off.
    await pumpScreen(tester, sheet, SectionPage(section: own, model: model), state);
    await tester.tap(find.byType(GlacierSwitch).first);
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(plugin)), isFalse);
    expect(find.text('Mark tickets as read'), findsNothing);
    expect(find.byType(GlacierSwitch), findsOneWidget);
    expect(own.summary!(model), 'Off');
    await tester.tap(find.byType(GlacierSwitch));
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(plugin)), isTrue);
    expect(find.text('Mark tickets as read'), findsOneWidget);
  });

  test('sorting five thousand conversations into sections takes a few milliseconds, and is not done again for the same list', () async {
    final plugin = TicketsPlugin();
    final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([plugin]));
    addTearDown(list.dispose);
    list.bind(AppState());
    final all = [
      for (var i = 0; i < 5000; i++)
        Conversation.from({'id': i, 'date': 9000000 - i, 'people': [ListPhone.person('7${1000 + i}')], 'snippet': i % 9 == 0 ? 'Your ticket $i is ready' : 'A text of ordinary words, number $i'}),
    ];
    list.take(all);
    while (list.tags.waiting > 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final clock = Stopwatch()..start();
    final sorted = list.sort(all);
    final first = clock.elapsedMicroseconds;
    expect(sorted.counts['tickets'], 556);
    clock.reset();
    expect(list.sort(all), same(sorted));
    final again = clock.elapsedMicroseconds;
    // ignore: avoid_print
    print('5000 conversations sorted in ${(first / 1000).toStringAsFixed(1)} ms; asked again, ${(again / 1000).toStringAsFixed(3)} ms');
    expect(first, lessThan(60000));
    expect(list.pick(all, null, searching: false), hasLength(5000 - 556));
    expect(list.pick(all, 'tickets', searching: false), hasLength(556));
  });
}

/// The made-up plugin with a section of its own in Settings.
class _PagedTickets extends TicketsPlugin {
  @override
  String get id => 'paged';
  @override
  String get name => 'Paged tickets';
  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'amber',
        intro: 'Tickets, set here.',
        summary: (prefs) => prefs.flag('read', fallback: false) ? 'Read as they arrive' : 'Left unread',
      );
}
