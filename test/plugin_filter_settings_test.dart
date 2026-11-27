import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart' show Pick, SettingRow;
import 'package:ghost_messaging/plugins/kinds.dart';
import 'package:ghost_messaging/plugins/list.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/settings.dart';
import 'package:ghost_messaging/plugins/spam.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// The filters' settings (Matt, 2026-11-16: "Fix the filtering a bit more this message got through also include
/// detailed settings for the filtering with strictness settings and tweak options for everything"): the new signs,
/// how strict each filter is, each sign and kind switched on or off, the person's own words and senders, and their
/// pages in Settings.
MessageFacts _facts(String text, {String from = '+15550001111', bool group = false, int thread = 7}) => MessageFacts(thread: thread, senders: [from], text: text, contact: false, group: group);

bool _spam(String text, {String from = '+15550001111', Map<String, String> prefs = const {}}) {
  final store = MemoryStore({for (final e in prefs.entries) 'plugin_spam_${e.key}': e.value});
  final p = PluginRegistry([const SpamPlugin()]).prefsOf(const SpamPlugin(), store);
  return const SpamPlugin().tuned.single(_facts(text, from: from), p).isNotEmpty;
}

String? _kind(String text, {Map<String, String> prefs = const {}, bool group = false}) {
  final store = MemoryStore({for (final e in prefs.entries) 'plugin_kinds_${e.key}': e.value});
  final p = PluginRegistry([const KindsPlugin()]).prefsOf(const KindsPlugin(), store);
  final tags = const KindsPlugin().tuned.single(_facts(text, group: group), p);
  return tags.isEmpty ? null : tags.single.detail;
}

void main() {
  networkTabs();
  group('the new signs', () {
    test('the scams most often texted now are caught as the app ships', () {
      // A toll notice and the reply-Y trick are strong: each counts double.
      expect(_spam('Your vehicle has an unpaid toll balance of \$6.99. Pay now to avoid late fees: https://ezpass-tolls.example/pay'), isTrue);
      expect(_spam('USPS: Your package is pending. Reply Y and reopen this message to activate the link.'), isTrue);
      expect(_spam('Final notice from the DMV: your registration will be suspended. https://dmv-nc.example'), isTrue);
      // A wrong-number opener from abroad; a company's name from a stranger with a shortened link.
      expect(_spam('Hi, is this Jessica? Long time no talk', from: '+447700900123'), isTrue);
      expect(_spam('Amazon: a charge of \$499 was made. Not you? bit.ly/3abc'), isTrue);
      expect(_spam('Send it by Zelle and the investment returns are guaranteed'), isTrue);
    });

    test('everyday texts are left alone', () {
      for (final text in [
        'Hi, is this Anna?',
        'Hey are you around later?',
        'Picked up the package from UPS, see you soon',
        'I parked by the toll booth, call me',
        'https://www.gamestop.com/video-games/nintendo-switch-2/products/hello-kitty-party-land.html',
        'There is a recall on my car for it randomly catching on fire',
      ]) {
        expect(_spam(text), isFalse, reason: text);
      }
      // A company naming itself from its own short code is not counted.
      expect(judgeSpam(_facts('CVS Pharmacy: Rx Ready. Delivery is a beautiful thing: i.cvs.com/D5FhmE9tw', from: '898287')).spam, isFalse);
    });
  });

  group('strictness', () {
    const one = 'Claim your reward: https://rewards.example/x'; // a link, prize wording: two signs
    const single = 'Visit https://shop.example/new for the new range'; // a link: one sign

    test('relaxed takes three signs, balanced two, strictest one', () {
      expect(_spam(one, prefs: {'level': 'relaxed'}), isFalse);
      expect(_spam(one), isTrue);
      expect(_spam(single), isFalse);
      expect(_spam(single, prefs: {'level': 'strictest'}), isTrue);
    });

    test('strict makes no allowance for sign-in codes or short codes; the allowances can be switched off', () {
      const code = 'Your code is 482913. If this wasn\'t you, secure your account immediately: https://bank.example/help';
      expect(_spam(code), isFalse, reason: 'balanced: a code takes one sign more');
      expect(_spam(code, prefs: {'level': 'strict'}), isTrue);
      expect(_spam(code, prefs: {'codes_lenient': 'off'}), isTrue);
      const bill = 'Your past-due bill is unpaid. Pay now at https://m.example/pay';
      expect(_spam(bill, from: '8500'), isFalse);
      expect(_spam(bill, from: '8500', prefs: {'short_lenient': 'off'}), isTrue);
    });

    test('a strong sign counts once where the person says so', () {
      const toll = 'Toll notice: https://tolls.example';
      expect(_spam(toll, prefs: {'level': 'relaxed'}), isTrue, reason: 'link + toll counted double: three');
      expect(_spam(toll, prefs: {'level': 'relaxed', 'strong_double': 'off'}), isFalse);
    });

    test('a sign switched off is not looked for', () {
      const prize = 'Congratulations! You\'ve won a gift card. Claim now: http://prize.example/win';
      expect(_spam(prize), isTrue);
      expect(_spam(prize, prefs: {'rule_prize': 'off'}), isFalse);
      expect(judgeSpam(_facts(prize), tuning: const SpamTuning(off: {'prize'})).signs.map((s) => s.id), ['link']);
    });
  });

  group('the person\'s own lists', () {
    test('always and never, by word or by sender; a number by its last ten digits; never wins', () {
      expect(_spam('Join our crypto pool', prefs: {'always_words': 'crypto pool'}), isTrue);
      expect(judgeSpam(_facts('Join our crypto pool'), tuning: const SpamTuning(alwaysWords: ['crypto pool'])).why, 'says "crypto pool"');
      expect(_spam('Hello', from: '+15550002222', prefs: {'always_senders': '(555) 000-2222'}), isTrue);
      expect(_spam('Congratulations! You\'ve won. Claim now: http://prize.example', prefs: {'never_words': 'congratulations'}), isFalse);
      expect(_spam('Congratulations! You\'ve won. Claim now: http://prize.example', from: '+15550003333', prefs: {'never_senders': '5550003333'}), isFalse);
      expect(_spam('crypto pool', from: '+15550003333', prefs: {'always_words': 'crypto pool', 'never_senders': '+1 555 000 3333'}), isFalse);
    });

    test('group chats and Signal and Telegram can be left out', () {
      const prize = 'Congratulations! You\'ve won a gift card. Claim now: http://prize.example/win';
      final store = MemoryStore({'plugin_spam_groups': 'off', 'plugin_spam_networks': 'off'});
      final p = PluginRegistry([const SpamPlugin()]).prefsOf(const SpamPlugin(), store);
      final classify = const SpamPlugin().tuned.single;
      expect(classify(_facts(prize, group: true), p), isEmpty);
      expect(classify(_facts(prize, thread: -(1 << 40) - 5), p), isEmpty);
      expect(classify(_facts(prize), p), isNotEmpty);
    });
  });

  group('kinds', () {
    test('relaxed sorts by sure signs only, strict by any one', () {
      const twoWeak = 'The election is close, every vote counts';
      expect(_kind(twoWeak), 'political');
      expect(_kind(twoWeak, prefs: {'level': 'relaxed'}), isNull);
      expect(_kind('Remember to vote', prefs: {'level': 'strict'}), 'political');
      expect(_kind('Remember to vote'), isNull);
    });

    test('a kind switched off sorts nothing; the person\'s own words sort as a sure sign does', () {
      expect(_kind('Paid for by Friends of Pat'), 'political');
      expect(_kind('Paid for by Friends of Pat', prefs: {'kind_political': 'off'}), isNull);
      expect(_kind('Sunrise Solar Co: our crew is nearby'), isNull);
      expect(_kind('Sunrise Solar Co: our crew is nearby', prefs: {'words_sales': 'sunrise solar, roofing'}), 'sales');
      expect(_kind('Paid for by Friends of Pat', group: true, prefs: {'groups': 'off'}), isNull);
    });
  });

  test('a filter\'s choice changing sorts every conversation again', () {
    final registry = PluginRegistry([const SpamPlugin()]);
    final store = MemoryStore();
    final before = registry.switches(store);
    registry.prefsOf(const SpamPlugin(), store).set('level', 'strict');
    expect(registry.switches(store), isNot(before));
    final now = registry.switches(store);
    registry.prefsOf(const SpamPlugin(), store).set('level', 'strict');
    expect(registry.switches(store), now, reason: 'the same choice again changes nothing');
  });

  testWidgets('the Spam filter\'s page: strictness to pick, signs to switch, lists to type', (tester) async {
    final registry = PluginRegistry([const SpamPlugin()]);
    ListPhone(const [])..install();
    final sheet = await loadSheet(tester);
    final state = AppState();
    final model = SettingsModel(state);
    addTearDown(model.dispose);
    final page = pluginPages(registry).single;
    expect(page.summary!(model), 'Balanced · muted');
    await pumpScreen(tester, sheet, SectionPage(section: page, model: model), state);

    for (final heading in ['HOW STRICT', 'ALLOWANCES', 'SIGNS TO LOOK FOR', 'YOUR OWN LISTS', 'WHERE IT LOOKS', 'WHEN SPAM COMES']) {
      expect(find.textContaining(RegExp(heading, caseSensitive: false)), findsWidgets, reason: heading);
    }
    expect(find.byType(Pick), findsNWidgets(4));
    expect(tester.widget<Pick>(find.byType(Pick).at(1)).checked, isTrue, reason: 'Balanced, as the app ships');
    await tester.tap(find.byType(Pick).at(2));
    await settle(tester);
    expect(state.choice('plugin_spam_level', ''), 'strict');
    expect(page.summary!(model), 'Strict · muted');

    // A sign switched off from its row.
    final toll = find.ancestor(of: find.text('Tolls, tickets and the DMV'), matching: find.byType(SettingRow)).first;
    // Far down the page: switched from its control, as a tap would.
    tester.widget<GlacierSwitch>(find.descendant(of: toll, matching: find.byType(GlacierSwitch))).onCheckedChange!(false);
    await settle(tester);
    expect(state.choice('plugin_spam_rule_toll', ''), 'off');

    // Words typed, kept a line each.
    final field = find.byType(EditableText).first;
    await tester.ensureVisible(field);
    await tester.enterText(field, 'crypto pool, sweepstakes');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(state.choice('plugin_spam_always_words', ''), 'crypto pool\nsweepstakes');
  });
}

/// A network's own tab (Signal's, Telegram's) leaves out what Messages hides, and a chat can be put back by hand.
void networkTabs() {
  testWidgets('a Signal chat that is spam is kept out of Signal\'s tab, found by a search, and put back by "Not spam"', (tester) async {
    ListPhone(const [])..install();
    final state = AppState();
    final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([const SpamPlugin()]));
    addTearDown(list.dispose);
    list.bind(state);
    const key = 'signal:abc';
    final facts = MessageFacts(thread: ListPlugins.chatThread(key), senders: const ['Prize Desk'], text: 'Congratulations! You\'ve won a gift card. Claim now: http://prize.example/win', contact: false);
    list.sort(const [], chats: [(key: key, facts: facts), (key: 'signal:friend', facts: _facts('see you at 7', thread: ListPlugins.chatThread('signal:friend')))]);
    expect(list.sectionOfChat(key)?.id, SpamPlugin.section);
    expect(list.hidesChat(key, searching: false), isTrue);
    expect(list.hidesChat(key, searching: true), isFalse);
    expect(list.hidesChat('signal:friend', searching: false), isFalse);
  });
}
