import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/admin_page.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart' show sealedWords;
import 'package:ghost_messaging/ui/souls.dart';
import 'package:ghost_messaging/ui/special_badges.dart';
import 'package:glacier/glacier.dart';

import 'support/market_fakes.dart';
import 'support/space_call_harness.dart';

/// Souls and the admin page (Matt, 2026-11-19: "Build a new points system into the app called souls ... display the
/// points in the top bar next to the feedback button with a flame icon ... create a simple admin page for me to login
/// to ... make sure only my matt account can access it ... see all users who signed up on the relay and issue special
/// badges and souls").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  // GMFB-25: souls are counted by each relay apart, and nothing said whose count was shown on a relay of one's own.
  test('on a relay of your own the Souls page says whose count it is; on Uplink\'s it says nothing more', () {
    expect(soulsRelayWords('wss://gogho.st/hub'), isNull);
    expect(soulsRelayWords('wss://relay.example.com/hub'), startsWith('Each relay counts souls apart. This is your count on relay.example.com, and souls go only between people on it.'));
    expect(soulsRelayWords('wss://relay.example.com/hub'), contains('still yours there'));
    expect(sealedWords('wss://gogho.st/hub'), 'Your texts stay on this phone. Friends, circles and spaces go through gogho.st\'s relay, sealed so it can\'t read them.');
    expect(sealedWords('wss://relay.example.com/hub'), 'Your texts stay on this phone. Friends, circles and spaces go through the relay you chose (relay.example.com), sealed so it can\'t read them.');
  });

  test('counts read short', () {
    expect(soulsCount(0), '0');
    expect(soulsCount(950), '950');
    expect(soulsCount(1234), '1,234');
    expect(soulsCount(12500), '12.5k');
    expect(soulsCount(250000), '250k');
  });

  test('what the relay says of souls and badges is kept, and a gift is told', () {
    final me = Me.forTest();
    me.hear({'dir': 'hello', 'ways': <String, String>{}, 'links': <Object>[], 'souls': 40, 'special': ['alpha']});
    expect(me.souls, 40);
    expect(me.special, ['alpha']);
    me.hear({'dir': 'souls', 'n': 65, 'special': ['alpha'], 'got': 25, 'why': 'Found the Windows crash'});
    expect(me.souls, 65);
    expect((me.gifts.value.last.souls, me.gifts.value.last.why), (25, 'Found the Windows crash'));
    me.hear({'dir': 'souls', 'n': 65, 'special': ['alpha', 'bughunter'], 'badge': 'bughunter'});
    expect(me.gifts.value.last.badge, 'bughunter');
    expect(specialBadgesOf(me.special).map((b) => b.name), ['Bug hunter', 'Alpha tester'], reason: 'in the order they are drawn');
  });

  test('the admin page is offered in developer mode, to @matt alone', () {
    final app = AppState();
    final m = SettingsModel(app);
    expect(adminOffered(m), isFalse);
    app.setFlag('dev_mode', true);
    expect(adminOffered(m), Me.instance.username == 'matt');
  });

  test('special badges heard with the verified answer: by id and by username, and none for the rest', () {
    final b = SpecialBadges()..heard(ids: ['aa', 'bb'], names: ['maya'], byId: {'aa': ['team', 'founder']}, byName: {'maya': ['helper']});
    expect(b.of('aa').map((x) => x.id), ['team', 'founder']);
    expect(b.of('bb'), isEmpty);
    expect(b.of('cc', username: 'Maya').map((x) => x.id), ['helper']);
  });

  testWidgets('the flame and the count in the top bar; a press says what souls are, with your badges', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seedSouls(1250, ['bughunter', 'alpha']);
    await h.shoot(
      tester,
      GhostPage(title: 'Messages', actions: const [SoulsChip()], body: const SizedBox.expand()),
      'souls-chip',
    );
    expect(find.text('1,250'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('souls')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('souls-sheet')), findsOneWidget);
    expect(find.text('Bug hunter'), findsOneWidget);
    await h.again(tester, 'souls-chip');
    // A gift while the app is open is said.
    Me.instance.hear({'dir': 'souls', 'n': 1275, 'got': 25, 'why': 'Found the crash'});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('You got 25 souls: Found the crash'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    Me.instance.seedSouls(0);
  });

  // Matt, 2026-11-21: "add the ability to notify a user when they have recieved souls wiht a description for why like
  // "bug bounty" etc it should notify them next time they connect to the app (or immediatly if they're connected in
  // real time)".
  test('gifts are kept until shown, said once each however often the relay says them, and the relay is told they were shown', () {
    final me = Me.forTest();
    me.hear({'dir': 'souls', 'n': 40, 'got': 40, 'why': 'Bug bounty', 'gift': 'g1'});
    me.hear({'dir': 'souls-gifts', 'n': 40, 'list': [{'g': 'g1', 'souls': 40, 'why': 'Bug bounty'}, {'g': 'g2', 'badge': 'bughunter'}]});
    expect([for (final g in me.gifts.value) (g.id, g.away)], [('g1', false), ('g2', true)]);
    final shown = me.takeGifts();
    expect(shown, hasLength(2));
    expect(me.gifts.value, isEmpty);
    expect(giftWords(shown.first), 'You got 40 souls: Bug bounty');
    expect(giftWords(shown.last), 'You were given the Bug hunter badge');
  });

  testWidgets('given while away: a card on opening, each with why, and a way to the souls', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seedSouls(140);
    Me.instance.hear({
      'dir': 'souls-gifts',
      'n': 140,
      'list': [
        {'g': 'a1', 'souls': 100, 'why': 'Bug bounty: the Windows crash'},
        {'g': 'a2', 'souls': 40, 'why': 'Helped test calls'},
      ],
    });
    await h.shoot(tester, GhostPage(title: 'Messages', actions: const [SoulsChip()], body: const SizedBox.expand()), 'souls-away');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('souls-gifts')), findsOneWidget);
    expect(find.text('You got 140 souls'), findsOneWidget);
    expect(find.text('100 souls · Bug bounty: the Windows crash'), findsOneWidget);
    expect(find.text('40 souls · Helped test calls'), findsOneWidget);
    expect(find.text('See your souls'), findsOneWidget);
    expect(Me.instance.gifts.value, isEmpty, reason: 'taken, and the relay told');
    await h.again(tester, 'souls-away');
    Me.instance.seedSouls(0);
  });

  testWidgets('the flame is a soul\'s ghostly white-green, glowing on a dark look (Matt, 2026-11-20: "make the fire for souls the white green ghostly color like a soul")', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seedSouls(1250);
    await h.shoot(tester, GhostPage(title: 'Messages', actions: const [SoulsChip()], body: const SizedBox.expand()), 'souls-chip', dark: true);
    final t = tester.element(find.byType(SoulsChip)).tokens;
    expect(t.isDark, isTrue);
    final flame = tester.widget<SoulFlame>(find.byType(SoulFlame));
    expect(flame.size, 16);
    final c = soulsFlame(t);
    expect(c.g, greaterThan(c.r), reason: 'green');
    expect(c.computeLuminance(), greaterThan(0.7), reason: 'and nearly white');
    Me.instance.seedSouls(0);
  });

  testWidgets('the admin page: a wrong sign-in says so; signed in, everyone listed; souls and a badge given', (tester) async {
    final h = await SpaceHarness.load(tester);
    final said = <Map<String, Object?>>[];
    final users = [
      {'id': 'a1a1a1a1a1a1a1a1', 'name': 'maya', 'named': true, 'at': '2026-11-18', 'verified': true, 'links': ['discord'], 'souls': 40, 'special': ['alpha'], 'here': true},
      {'id': 'b2b2b2b2b2b2b2b2', 'name': 'kevin', 'named': true, 'at': '2026-11-15', 'verified': false, 'links': <String>[], 'souls': 0, 'special': <String>[], 'here': false, 'account': '0x9f2c00000000000000000000000000000000b2b2', 'was': ['kev_old']},
      {'id': 'c3c3c3c3c3c3c3c3', 'named': true, 'at': '2026-11-14', 'verified': false, 'links': <String>[], 'souls': 0, 'special': <String>[], 'here': false},
    ];
    Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
      said.add(what);
      return switch (what['dir']) {
        'admin-login' => what['pass'] == 'right' ? {'dir': 'admin', 'ok': true} : {'dir': 'admin', 'ok': false, 'err': 'That isn\'t right.'},
        'admin-users' => {'ok': true, 'users': users},
        'admin-log' => {'ok': true, 'grants': [{'at': '2026-11-19T20:00:00.000Z', 'to': 'a1a1a1a1a1a1a1a1', 'souls': 40, 'why': 'First bug'}]},
        'admin-give' => {'ok': true, 'n': 40 + (what['souls'] as int)},
        'admin-badge' => {'ok': true, 'special': ['alpha', if (what['on'] == true) what['badge']]},
        _ => {'ok': false},
      };
    }

    // The Marketplace's review rows read a Marketplace of the test's own (Matt, 2026-11-20: "I'd like to be able to verify
    // them for the store through a review process").
    final market = MarketApi(hubUrl: 'https://relay.test', signer: KeysSigner(NetKeys.generate()), transport: FakeRelay().call);
    await h.shoot(tester, GhostPage(title: 'Admin', body: SettingsPaneScope(finder: SettingsFinder(), child: ListView(padding: const EdgeInsets.all(16), children: [AdminPanel(ask: ask, market: market)]))), 'admin-sign-in');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-user')), matching: find.byType(EditableText)), 'wisp-keeper-1a2b');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-pass')), matching: find.byType(EditableText)), 'wrong');
    await tester.tap(find.byKey(const ValueKey('admin-sign-in')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('That isn\'t right.'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-pass')), matching: find.byType(EditableText)), 'right');
    await tester.tap(find.byKey(const ValueKey('admin-sign-in')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('@maya'), findsOneWidget);
    expect(find.text('@kevin'), findsOneWidget);
    expect(find.textContaining('3 people · 1 connected now'), findsOneWidget);
    // Plugin review, before Everyone, once signed in.
    expect(find.byKey(const ValueKey('admin-plugin-review')), findsOneWidget);
    expect(find.text('0 waiting · 0 reports'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('admin-plugin-review'))).dy, lessThan(tester.getTopLeft(find.text('@maya')).dy));
    await h.again(tester, 'admin-list');

    // Found by a name given up, by the start of the id, and by the account (Matt, 2026-11-20: "tie users names to their
    // accounts when they sign back in later or reconnect to the app so that we can give out bug bounties properly").
    for (final q in ['kev_old', 'b2b2', '0x9f2c']) {
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-search')), matching: find.byType(EditableText)), q);
      await tester.pump();
      expect(find.text('@kevin'), findsOneWidget, reason: q);
      expect(find.text('@maya'), findsNothing, reason: q);
    }
    expect(find.textContaining('was @kev_old'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-search')), matching: find.byType(EditableText)), '');
    await tester.pump();

    await tester.tap(find.text('@kevin'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Who: the id the ticket's Reporter line names, the account, the names before.
    expect(find.text('b2b2b2b2b2b2b2b2'), findsOneWidget);
    expect(find.text('0x9f2c00000000000000000000000000000000b2b2'), findsOneWidget);
    expect(find.text('@kev_old'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('admin-amount')));
    await tester.pump();
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-amount')), matching: find.byType(EditableText)), '25');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('admin-why')), matching: find.byType(EditableText)), 'Found the crash');
    await tester.ensureVisible(find.byKey(const ValueKey('admin-give')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('admin-give')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(said.where((w) => w['dir'] == 'admin-give').single, {'dir': 'admin-give', 'to': 'b2b2b2b2b2b2b2b2', 'souls': 25, 'why': 'Found the crash'});
    await tester.ensureVisible(find.byKey(const ValueKey('admin-badge-bughunter')));
    await tester.pump();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('admin-badge-bughunter')), matching: find.byType(GlacierSwitch)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(said.where((w) => w['dir'] == 'admin-badge').single, {'dir': 'admin-badge', 'to': 'b2b2b2b2b2b2b2b2', 'badge': 'bughunter', 'on': true});
    await h.again(tester, 'admin-person');
    await tester.pump(const Duration(seconds: 5));
  });
}
