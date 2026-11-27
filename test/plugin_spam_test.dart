import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/plugins/list.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/spam.dart';
import 'package:ghost_messaging/plugins/ui.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// Spam filter (lib/plugins/spam.dart; Matt, 2026-11-14: "filtering out spam messages"): which texts the rules call
/// spam and why, that a contact's never is, that it is off until chosen, and the Spam section in the list with "Not
/// spam" that sticks.
MessageFacts _facts(String text, {List<String> from = const ['+15550001111'], bool contact = false, int thread = 7, bool? outgoing}) => MessageFacts(thread: thread, senders: from, text: text, contact: contact, outgoing: outgoing);

List<String> _signs(String text, {List<String> from = const ['+15550001111']}) => [for (final s in judgeSpam(_facts(text, from: from)).signs) s.id];

const _prize = 'Congratulations! You\'ve won a \$1,000 gift card. Claim now: http://prize.example/win';
const _locked = 'Your account has been locked. Verify your identity at https://secure-login.example';
const _parcel = 'Your package could not be delivered. Reschedule here: bit.ly/3xYz';

void main() {
  group('the rules', () {
    test('each sign is found where it is, and one sign alone is not spam', () {
      expect(_signs(_prize), ['link', 'prize']);
      expect(_signs(_locked), ['link', 'pressure']);
      expect(_signs(_parcel), ['link', 'delivery', 'shortlink']);
      expect(_signs('You\'re pre-approved for a \$5,000 loan! Act now'), ['pressure', 'money']);
      expect(_signs('Deals inside: www.shop.example/sale', from: ['promo@deals.example']), ['link', 'email']);
      expect(_signs('Unable to deliver your parcel: customs fee unpaid'), ['pressure', 'delivery']);
      for (final text in [_prize, _locked, _parcel]) {
        expect(judgeSpam(_facts(text)).spam, isTrue, reason: text);
      }

      // One sign, or none: an ordinary text from a shop, a bank, a courier, a person.
      for (final text in [
        'Your order has shipped. Track it: https://shop.example/t/123',
        'Unusual activity on your card. Reply YES if this was you.',
        'You\'re pre-approved for a \$5,000 loan! Reply YES',
        'Your package is on hold at the depot until Friday',
        'Your package was delivered',
        'See you at 7',
        'Hi, is this Anna?',
      ]) {
        final verdict = judgeSpam(_facts(text));
        expect(verdict.signs.length, lessThan(2), reason: text);
        expect(verdict.spam, isFalse, reason: text);
      }
    });

    test('a phrase is a word of its own, and an email address in a text is not a link', () {
      expect(_signs('Your phone was unlocked, thanks for choosing us'), isEmpty);
      expect(_signs('The surprised look on his face was priceless'), isEmpty);
      expect(_signs('Write to me at maya@example.com'), isEmpty);
      expect(_signs('Our community.center opens at 9'), isEmpty);
      expect(_signs('Details at example.com/today'), ['link']);
    });

    test('why it is spam is said in words, the signs in the order the rules are listed', () {
      expect(judgeSpam(_facts(_prize)).why, 'a link, prize wording');
      expect(judgeSpam(_facts('URGENT: your parcel is held. Pay the customs fee now: https://post.example/pay')).why, 'a link, pressure to act, a delivery problem');
    });

    test('a text with a sign-in code in it needs three signs, not two', () {
      const code = 'Your code is 482913. If this wasn\'t you, secure your account immediately: https://bank.example/help';
      final verdict = judgeSpam(_facts(code));
      expect(verdict.signs.map((s) => s.id), ['link', 'pressure']);
      expect(verdict.needed, 3);
      expect(verdict.spam, isFalse);
    });

    test('every rule says what it is, for Settings and for the row', () {
      expect(spamRules.map((r) => r.id).toSet(), hasLength(spamRules.length));
      for (final rule in spamRules) {
        expect(rule.name, isNotEmpty);
        expect(rule.says, isNotEmpty);
        expect(rule.about, endsWith('.'));
      }
    });
  });

  group('the plugin', () {
    const plugin = SpamPlugin();
    final registry = PluginRegistry(const [plugin]);
    MemoryStore on() => MemoryStore({'plugin_spam': 'on'});

    test('is on as the app ships, a kind for the list\'s filter hidden until shown, and can be switched off', () {
      // Matt, 2026-11-14: "a filter dropdown where showing spam, political messages, and debt collectors are
      // filtered out by default". It was off until chosen, and a tab of its own.
      expect(plugin.onByDefault, isTrue);
      expect(registry.isOn(plugin, MemoryStore()), isTrue);
      expect(registry.classify(_facts(_prize), MemoryStore()).detail('spam'), 'a link, prize wording');
      final spam = registry.sections(MemoryStore()).single.section;
      expect(spam.filter, isTrue);
      expect(spam.hidden, isTrue);
      final off = MemoryStore({'plugin_spam': 'off'});
      expect(registry.isOn(plugin, off), isFalse);
      expect(registry.classify(_facts(_prize), off).isEmpty, isTrue);
      expect(shippedPlugins.whereType<SpamPlugin>(), hasLength(1));
    });

    test('a spam text is tagged with why; a contact\'s and the person\'s own never are', () {
      final store = on();
      expect(registry.classify(_facts(_prize), store).detail('spam'), 'a link, prize wording');
      expect(registry.classify(_facts(_prize, contact: true), store).isEmpty, isTrue);
      expect(registry.classify(_facts(_prize, outgoing: true), store).isEmpty, isTrue);
      expect(registry.classify(_facts('See you at 7'), store).isEmpty, isTrue);
    });

    test('its section takes what is tagged, its row says why and has "Not spam"', () async {
      final store = on();
      final facts = _facts(_prize);
      final tags = registry.classify(facts, store);
      final section = registry.sectionOf(facts, tags, store)!;
      expect(section.id, 'spam');
      final look = registry.look(section, facts, tags, store)!;
      expect(look.value, isNull);
      expect(look.caption, 'Looks like spam: a link, prize wording');
      expect(look.word!.label, 'Not spam');
      expect(look.tap, isNull, reason: 'a tap opens the conversation, as anywhere');
      // One moved here by hand, whose words the rules would not call spam.
      expect(registry.look(section, _facts('Hi, is this Anna?'), TagSet.none, store)!.caption, 'Moved here by you');
    });

    test('a conversation\'s menu has "Not spam" in Spam, and "Move to Spam" elsewhere unless it is a contact\'s', () {
      final store = on();
      List<String> menu(MessageFacts facts, {String? section}) => [for (final b in registry.actions(Slots.conversationMenu, ConversationPlace(facts, registry.classify(facts, store), section: section), store)) b.action.label];
      expect(menu(_facts(_prize), section: 'spam'), ['Not spam']);
      expect(menu(_facts('Hi, is this Anna?')), ['Move to Spam']);
      expect(menu(_facts('Hi, is this Anna?', contact: true)), isEmpty);
    });

    test('a conversation in Spam is muted as its text is seen, unless that is switched off', () {
      final store = on();
      final facts = _facts(_prize);
      final tags = registry.classify(facts, store);
      expect(registry.incoming(facts, tags, store).map((b) => b.action), [isA<MuteNotification>()]);
      expect(registry.incoming(_facts('See you at 7'), TagSet.none, store), isEmpty);
      store.write('plugin_spam_mute', 'off');
      expect(registry.incoming(facts, tags, store), isEmpty);
    });

    test('another list of rules stands in for the app\'s own', () {
      const mine = SpamPlugin(rules: [
        SpamRule(id: 'fruit', name: 'Fruit', says: 'fruit', about: 'It names a fruit.', words: r'pineapple'),
        SpamRule(id: 'short', name: 'A London number', says: 'a London number', about: 'It came from a London number.', sender: r'^\+4420'),
      ]);
      final other = PluginRegistry(const [mine]);
      final store = on();
      expect(other.classify(_facts('Fresh pineapple today', from: ['+442079460000']), store).detail('spam'), 'fruit, a London number');
      expect(other.classify(_facts(_prize), store).isEmpty, isTrue);
      expect(other.settingsOf(mine).map((s) => s.label), containsAll(['Fruit', 'A London number']));
    });

    test('a text that is both a sign-in code and spam is in Codes: Codes is asked first', () {
      final both = PluginRegistry(shippedPlugins);
      final store = on();
      expect(both.plugins.first, isA<CodesPlugin>());
      const text = 'URGENT: your account is locked. Use code 482913 to verify your identity at https://bank.example/unlock and claim your prize';
      final facts = _facts(text);
      final tags = both.classify(facts, store);
      expect(tags.names, containsAll(['code', 'spam']));
      expect(both.sectionOf(facts, tags, store)!.id, 'codes');
    });
  });

  group('in the list', () {
    late PluginRegistry shipped;
    setUp(() => shipped = PluginRegistry.instance);
    tearDown(() => PluginRegistry.instance = shipped);

    List<Map<String, Object?>> phone() => [
          ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4),
          ListPhone.conversation(2, '+15559870002', _prize, minutes: 9, unread: true),
          ListPhone.conversation(3, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 50),
          ListPhone.conversation(4, '+15559870004', _parcel, minutes: 120),
          ListPhone.conversation(5, '+15559870005', 'Hi, is this Anna?', minutes: 300),
          ListPhone.conversation(6, '+15551230006', _locked, name: 'Priya Natarajan', minutes: 400),
        ];

    testWidgets('switched off: nothing is hidden and nothing is asked of the phone', (tester) async {
      PluginRegistry.instance = PluginRegistry(const [SpamPlugin()]);
      final listed = ListPhone(phone())..install();
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const ConversationsScreen(), AppState()..setFlag('plugin_spam', false));
      // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
      expect(find.byType(FilterButton), findsNothing);
      expect(find.byType(ConversationRow), findsNWidgets(6));
      expect(listed.asked, isEmpty);
    });

    testWidgets('as the app ships: spam is hidden from Messages, said at the list\'s foot, and "Not spam" puts one back for good', (tester) async {
      PluginRegistry.instance = PluginRegistry(const [SpamPlugin()]);
      final listed = ListPhone(phone())..install();
      final sheet = await loadSheet(tester);
      final state = AppState();
      await pumpScreen(tester, sheet, const ConversationsScreen(), state);

      // Two look like spam and are from numbers: hidden, and said. Priya's, a contact's, stays. Spam is no tab.
      // No section of a plugin's: the toggle has Messages and Voice alone (Voice is always a tab since 2026-11-15).
      expect(tester.widget<SectionTabs>(find.byType(SectionTabs)).sections, isEmpty);
      expect(find.byType(FilterButton), findsOneWidget);
      expect(tester.widget<FilterButton>(find.byType(FilterButton)).hidden, 2);
      expect(find.byType(ConversationRow), findsNWidgets(4));
      expect(find.text(_prize), findsNothing);
      expect(find.text(_locked), findsOneWidget);
      expect(find.text('2 hidden · Show'), findsOneWidget);
      // The unread one was muted as it was seen.
      expect(listed.asked, ['muted 2 true']);

      // From the foot: what is hidden, each saying why, and the way back.
      await tester.tap(find.text('2 hidden · Show'));
      await settle(tester);
      expect(find.byType(PluginRow), findsNWidgets(2));
      expect(find.text('Looks like spam: a link, prize wording'), findsOneWidget);
      expect(find.text('Looks like spam: a link, a delivery problem, a shortened link'), findsOneWidget);
      expect(find.text('Show all'), findsOneWidget);

      // "Not spam" on the row: back in Messages, said, kept, and its notifications back on.
      await tester.tap(find.text('Not spam').first);
      await settle(tester);
      expect(find.text('Moved to Messages'), findsOneWidget);
      expect(find.byType(PluginRow), findsOneWidget);
      expect(listed.prefs[Filing.key], '2:');
      expect(listed.asked, ['muted 2 true', 'muted 2 false']);
      expect(listed.prefs[ListPlugins.mutedKey], '');
      await tester.tap(find.text('Show all'));
      await settle(tester);
      expect(find.text(_prize), findsOneWidget);
      expect(find.text('1 hidden · Show'), findsOneWidget);

      // One the rules missed is moved to Spam from its long press, and hidden with it.
      await tester.longPress(find.text('Hi, is this Anna?'));
      await settle(tester);
      await tester.tap(find.text('Move to Spam'));
      await settle(tester);
      expect(find.text('Moved to Spam'), findsOneWidget);
      expect(find.text('Hi, is this Anna?'), findsNothing);
      expect(find.text('2 hidden · Show'), findsOneWidget);
      expect(listed.prefs[Filing.key], '2:,5:spam');
      // A contact's conversation is not offered it.
      await tester.longPress(find.text('Call me when you land'));
      await settle(tester);
      expect(find.text('Move to Spam'), findsNothing);
    });

    testWidgets('the filter: All at the top, then each kind with its icon, ticked while shown', (tester) async {
      PluginRegistry.instance = PluginRegistry(const [SpamPlugin()]);
      ListPhone(phone()).install();
      final sheet = await loadSheet(tester);
      final state = AppState();
      await pumpScreen(tester, sheet, const ConversationsScreen(), state);
      await tester.tap(find.byType(FilterButton));
      await settle(tester);
      // Matt, 2026-11-14: "Remove the show only toggle and just habe all at the top and each of these filters get
      // ticked on or off With the icons".
      expect(find.text('Show only'.toUpperCase()), findsNothing);
      final rows = find.byType(GlacierMenuItem);
      expect(find.descendant(of: rows.first, matching: find.text('All')), findsOneWidget);
      expect(find.descendant(of: rows.at(1), matching: find.text('Personal & other')), findsOneWidget);
      expect(find.descendant(of: rows.at(2), matching: find.text('Spam')), findsOneWidget);
      expect(find.descendant(of: rows.at(2), matching: find.byType(AppIcon)), findsOneWidget, reason: 'its icon, and no tick: it is hidden');
      // Ticked: shown in Messages, the menu staying open; the choice is kept.
      await tester.tap(find.descendant(of: find.byType(GlacierMenuItem), matching: find.text('Spam')).first);
      await settle(tester);
      expect(state.flag('filter_spam', fallback: false), isTrue);
      expect(find.byType(GlacierMenuItem), findsWidgets, reason: 'the menu stays open to tick another');
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.byType(ConversationRow), findsNWidgets(6));
      expect(find.textContaining('hidden · Show'), findsNothing);
      // All, with everything ticked, unticks everything.
      await tester.tap(find.byType(FilterButton));
      await settle(tester);
      expect(find.descendant(of: find.byType(GlacierMenuItem).at(2), matching: find.byType(AppIcon)), findsNWidgets(2), reason: 'its icon and its tick');
      await tester.tap(find.descendant(of: find.byType(GlacierMenuItem), matching: find.text('All')));
      await settle(tester);
      expect(state.flag('filter_spam', fallback: true), isFalse);
      expect(state.flag(ListPlugins.othersKey), isFalse);
    });

    // Matt, 2026-11-14: "when only selecting political messages I still see personal messages".
    testWidgets('one kind ticked alone: Messages shows that kind and nothing else, personal texts included', (tester) async {
      PluginRegistry.instance = PluginRegistry(const [SpamPlugin()]);
      ListPhone(phone()).install();
      final sheet = await loadSheet(tester);
      final state = AppState()..setFlag('filter_spam', true)..setFlag(ListPlugins.othersKey, false);
      await pumpScreen(tester, sheet, const ConversationsScreen(), state);
      expect(find.byType(ConversationRow), findsNWidgets(2));
      expect(find.text(_prize), findsOneWidget);
      expect(find.text('Call me when you land'), findsNothing);
      expect(find.text('4 hidden · Show'), findsOneWidget);
      // Personal & other ticked again: everything is back.
      await tester.tap(find.byType(FilterButton));
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(GlacierMenuItem), matching: find.text('Personal & other')));
      await settle(tester);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.byType(ConversationRow), findsNWidgets(6));
    });

    testWidgets('what was marked "Not spam" is still not spam when the app is opened again', (tester) async {
      PluginRegistry.instance = PluginRegistry(const [SpamPlugin()]);
      final listed = ListPhone(phone())..install();
      listed.prefs.addAll({Filing.key: '2:'});
      final sheet = await loadSheet(tester);
      // The person's choices as Android kept them.
      final state = AppState();
      await tester.runAsync(state.load);
      await pumpScreen(tester, sheet, const ConversationsScreen(), state);
      expect(find.text('1 hidden · Show'), findsOneWidget);
      expect(find.text(_prize), findsOneWidget);
      expect(listed.asked, isEmpty, reason: 'it is in the main list: nothing mutes it');
    });
  });

  // What sampling real texts showed (2026-11-14; reworded).
  test('job offers, numbers abroad, hidden characters and lonely-hearts bait are spam; Urgent Care is not urgency', () {
    bool spam(String text, String from) => judgeSpam(MessageFacts(thread: 1, senders: [from], text: text, contact: false)).spam;
    expect(spam('Hi, I am a recruiter. Your resume has been recommended for a part-time remote job.', 'someone@mail.example'), isTrue);
    expect(spam('Earn 200 USD a day from home, part-time job, flexible.', '+639100000000'), isTrue);
    expect(spam('\u200b\u200dTired of lonely nights? Premium connections await.', 'someone@mail.example'), isTrue);
    // A clinic's link to check in is not "urgent".
    expect(spam('Please check in for your appt at City Urgent Care: https://check-in.example/x', '+18665550100'), isFalse);
    // A company's short code may speak of paying, with a link: it takes one sign more.
    expect(spam('Verizon: your past-due bill is unpaid. Pay now at https://m.vzw.example/pay', '8500'), isFalse);
    expect(spam('Your past-due bill is unpaid. Pay now at https://pay.example', '+15555550100'), isTrue);
  });
}
