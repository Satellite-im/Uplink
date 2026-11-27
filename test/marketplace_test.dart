import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/l10n/words.dart' show Tr;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart' show SettingRow, SettingsFindableMark;
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/ui.dart' show SectionTabs;
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/market/marketplace_screen.dart';
import 'package:ghost_messaging/ui/nav_bar.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/plugins_page/plugins_page.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// The Marketplace's ring and its place in the frame (lib/ui/shell.dart, lib/ui/market/marketplace_screen.dart; Matt,
/// 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail with a marketplace
/// icon"): the ring in every navigation, its list in the list's place with Discover beside it or its rows' pages over
/// it, the sections offered as the device and its choices stand, the way it and Settings, Archive and Messages give way
/// to each other, and Settings' plugins found and opened in it.
Finder _key(String k) => find.byKey(ValueKey(k));

const _phone = Size(412, 892), _wide = Size(1000, 760);

void main() {
  late Directory dir;
  InstalledPlugins? installed;
  late FakeRelay relay;
  late MarketState market;
  late AppState state;
  var made = 0;
  final oldInstalled = InstalledPlugins.instance, oldMarket = MarketState.instance, oldRegistry = PluginRegistry.instance;

  setUp(() {
    ListPhone([
      ListPhone.conversation(1, '+15551230001', 'See you at 7', name: 'Maya Chen'),
      ListPhone.conversation(2, '+15551230002', 'The build is out', name: 'Sam Ortiz', archived: true),
    ]).install();
    dir = Directory.systemTemp.createTempSync('marketplace-');
    PluginRegistry.instance = PluginRegistry(shippedPlugins);
    relay = FakeRelay();
    // It reads InstalledPlugins.instance as it goes: each test puts its own in place.
    market = marketOver(relay, Directory('${dir.path}/market'));
    MarketState.instance = market;
    state = AppState();
    installed = null;
  });
  tearDown(() {
    InstalledPlugins.instance = oldInstalled;
    MarketState.instance = oldMarket;
    PluginRegistry.instance = oldRegistry;
    dir.deleteSync(recursive: true);
  });

  AppShellState shell() => AppShellState.live!;

  /// This device's packs, read for the app the frame draws from: made inside the test, whose zone its work runs in.
  Future<InstalledPlugins> ready({bool storeAllowed = true}) async {
    final here = await installedFor(state, Directory('${dir.path}/plugins-${made++}'), storeAllowed: storeAllowed);
    InstalledPlugins.instance = installed = here;
    return here;
  }

  Future<void> frame(WidgetTester tester, {Size size = _phone, NavStyle style = NavStyle.rail}) async {
    if (installed == null) await ready();
    state.set(NavStyle.pref, style.name);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), state, size: size);
  }

  testWidgets('the ring: between Archive and Settings on the rail, in the dock and classic pills, "Market" on Dial-Up\'s taskbar', (tester) async {
    await frame(tester);
    final archive = tester.getTopLeft(_key('rail-archive')).dy, ring = tester.getTopLeft(_key('rail-marketplace')).dy, settings = tester.getTopLeft(_key('rail-settings')).dy;
    expect(ring, greaterThan(archive));
    expect(ring, lessThan(settings));
    for (final style in [NavStyle.dock, NavStyle.classic]) {
      await frame(tester, style: style);
      expect(_key('nav-marketplace'), findsOneWidget, reason: style.name);
      expect(tester.widget<NavPill>(find.byType(NavPill)).items.map((i) => i.id), ['new', 'messages', 'contacts', 'archive', 'marketplace', 'settings']);
    }
    // Dial-Up's taskbar: six buttons, the Marketplace's said short.
    state.setLook(Look.dialup);
    await frame(tester, style: NavStyle.classic);
    expect(find.text('Market'), findsOneWidget);
  });

  testWidgets('the ring counts the updates waiting', (tester) async {
    await addStore(await ready(), billsPack());
    await relay.list(billsPack(version: '1.1.0'));
    await tester.runAsync(() => market.refresh(force: true));
    await frame(tester);
    expect(tester.widget<NavRing>(_key('rail-marketplace')).item.count, 1);
    // Updated, nothing waits.
    expect((await market.update(market.updates.single.listing)).ok, isTrue);
    await settle(tester);
    expect(tester.widget<NavRing>(_key('rail-marketplace')).item.count, 0);
  });

  testWidgets('wide: its list in the list\'s place, Discover beside it, the ring lit, no band or search in the list', (tester) async {
    await frame(tester, size: _wide);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    expect(find.byType(MarketplaceScreen), findsOneWidget);
    expect(_key('marketplace'), findsOneWidget);
    expect(shell().marketOpen, isTrue);
    expect(shell().marketSection.value, 'discover');
    final discover = find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Discover');
    expect(discover, findsOneWidget);
    expect(tester.getRect(discover).left, greaterThanOrEqualTo(tester.getRect(find.byType(MarketplaceScreen)).right - 1), reason: 'beside the list, not over it');
    expect(tester.widget<NavRing>(_key('rail-marketplace')).shown, isTrue);
    expect(_key('plugins-entry'), findsNothing, reason: 'Discover beside it has the band');
    expect(_key('market-search'), findsNothing);
    expect(tester.widget<SettingsSectionRow>(_key('market-row-discover')).selected, isTrue);
    // A row's page takes the pane's place.
    await tester.tap(_key('market-row-added'));
    await settle(tester);
    expect(shell().marketSection.value, 'added');
    expect(find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Added'), findsOneWidget);
  });

  testWidgets('a phone: the list alone with the band and the search; a row\'s page over it, and back', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    expect(find.byType(MarketplaceScreen), findsOneWidget);
    expect(_key('plugins-entry'), findsOneWidget);
    expect(_key('market-search'), findsOneWidget);
    expect(shell().marketSection.value, isNull, reason: 'on a phone it opens on its list');
    await tester.tap(_key('market-row-added'));
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Added'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Back').last);
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Added'), findsNothing);
    expect(find.byType(MarketplaceScreen), findsOneWidget);
    // The band opens Discover.
    await tester.tap(_key('plugins-entry'));
    await settle(tester);
    expect(shell().marketSection.value, 'discover');
    await tester.tap(find.bySemanticsLabel('Back').last);
    await settle(tester);
    // Its search finds a section by its words.
    await tester.enterText(find.descendant(of: _key('market-search'), matching: find.byType(EditableText)), 'submit');
    await settle(tester);
    expect(_key('market-row-submit'), findsOneWidget);
    expect(_key('market-row-discover'), findsNothing);
    expect(_key('plugins-entry'), findsNothing);
    // And plugins, by name, tag or who made them: a listing among them, opening Discover at its page.
    await relay.list(billsPack());
    await tester.runAsync(() => market.refresh(force: true));
    await tester.enterText(find.descendant(of: _key('market-search'), matching: find.byType(EditableText)), 'maya');
    await settle(tester);
    expect(_key('market-hit-xbills'), findsOneWidget);
    await tester.tap(_key('market-hit-xbills'));
    await settle(tester);
    await settle(tester);
    expect(_key('plugins-detail-xbills'), findsOneWidget);
    expect(_key('plugins-detail-reviewed'), findsOneWidget);
  });

  testWidgets('opened on a phone and widened, Discover is beside it', (tester) async {
    await frame(tester);
    shell().go('marketplace');
    await settle(tester);
    expect(shell().marketSection.value, isNull);
    tester.view.physicalSize = _wide * 2.0;
    await settle(tester);
    await settle(tester);
    expect(shell().marketSection.value, 'discover', reason: 'unfolding never leaves the pane empty');
    expect(find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Discover'), findsOneWidget);
  });

  testWidgets('In development only in developer mode; the Review queue only for the admin with an identity', (tester) async {
    await frame(tester, size: _wide);
    shell().marketplace();
    await settle(tester);
    expect(_key('market-row-dev'), findsNothing);
    expect(_key('market-row-review'), findsNothing);
    state.setFlag('dev_mode', true);
    await settle(tester);
    expect(_key('market-row-dev'), findsOneWidget);
    expect(_key('market-row-review'), findsNothing, reason: 'not the admin');
    await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    await settle(tester);
    expect(_key('market-row-review'), findsOneWidget);
    expect(marketOffered('review', state), isTrue);
    // A computer that follows its phone has no identity of its own: no review from there.
    MarketState.instance = MarketState(api: () => MarketApi(hubUrl: 'https://relay.test', transport: relay.call), cache: dir);
    expect(marketOffered('review', state), isFalse);
    // Developer mode off: In development goes, and its page with it.
    MarketState.instance = market;
    shell().marketplace(section: 'dev');
    await settle(tester);
    expect(_key('market-dev-manage'), findsOneWidget);
    state.setFlag('dev_mode', false);
    await settle(tester);
    await settle(tester);
    expect(_key('market-row-dev'), findsNothing);
    expect(_key('market-dev-manage'), findsNothing);
    expect(shell().marketSection.value, 'discover', reason: 'beside the list Discover takes its place');
  });

  testWidgets('no Make your own on an iPhone, nor anything from other developers', (tester) async {
    await ready(storeAllowed: false);
    state.setFlag('dev_mode', true);
    await frame(tester);
    shell().marketplace();
    await settle(tester);
    for (final k in ['market-row-submit', 'market-row-mine', 'market-row-dev', 'market-docs']) {
      expect(_key(k), findsNothing, reason: k);
    }
    expect(find.text('MAKE YOUR OWN'), findsNothing);
    expect(_key('market-row-discover'), findsOneWidget);
  });

  testWidgets('Messages closes it; Settings and the Marketplace close each other', (tester) async {
    await frame(tester, size: _wide);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    await tester.tap(_key('rail-home'));
    await settle(tester);
    expect(shell().marketOpen, isFalse);
    expect(find.byType(MarketplaceScreen), findsNothing);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    await tester.tap(_key('rail-settings'));
    await settle(tester);
    expect(shell().settingsOpen, isTrue);
    expect(shell().marketOpen, isFalse);
    expect(find.byType(MarketplaceScreen), findsNothing);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(shell().settingsOpen, isFalse);
    expect(find.byType(SettingsScreen), findsNothing);
    // Beside its page, back leaves it whole.
    expect(shell().marketSection.value, 'discover');
  });

  testWidgets('Archive, then the Marketplace, then Archive again is Archive', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-archive'));
    await settle(tester);
    await tester.tap(_key('rail-marketplace'));
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    await tester.tap(_key('rail-archive'));
    await settle(tester);
    expect(shell().marketOpen, isFalse);
    expect(find.byWidgetPredicate((w) => w is ConversationsScreen && w.archived).hitTestable(), findsOneWidget);
    expect(find.byType(MarketplaceScreen), findsNothing);
    expect(tester.widget<NavRing>(_key('rail-archive')).shown, isTrue);
    expect(tester.widget<NavRing>(_key('rail-marketplace')).shown, isFalse);
  });

  testWidgets('in the classic style on a phone the pill goes under the Marketplace, as under Settings', (tester) async {
    await frame(tester, style: NavStyle.classic);
    final opacity = find.ancestor(of: find.byType(NavPill), matching: find.byType(AnimatedOpacity)).first;
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    await tester.tap(_key('nav-marketplace'));
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
  });

  testWidgets('Settings › Plugins and a plugin\'s own section open Discover at it, from a link or the API', (tester) async {
    await frame(tester);
    // ui.openSettings('plugin-spam'), and any old link to it.
    shell().settings('plugin-spam');
    await settle(tester);
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(shell().settingsOpen, isFalse);
    expect(shell().marketSection.value, 'discover');
    expect(_key('plugins-detail-spam'), findsOneWidget);
    shell().go('messages');
    await settle(tester);
    // ui.openSettings('plugins'): Discover itself.
    shell().settings('plugins');
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(shell().marketSection.value, 'discover');
    expect(find.byWidgetPredicate((w) => w is PluginsPage && w.title == 'Discover'), findsOneWidget);
  });

  testWidgets('asked for before the first frame, it opens once there is a frame', (tester) async {
    final sheet = await loadSheet(tester);
    state.set(NavStyle.pref, NavStyle.rail.name);
    tester.view.physicalSize = _phone * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    // Built and not yet laid out: the frame's list is made as it is laid out, so there is no list to open it in.
    await tester.pumpWidget(_app(sheet, state, const AppShell()), phase: EnginePhase.build);
    shell().settings('plugin-spam');
    expect(shell().marketOpen, isFalse, reason: 'held until there is a list to open it in');
    await settle(tester);
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(_key('plugins-detail-spam'), findsOneWidget);
  });

  testWidgets('a Settings search hit for a plugin\'s setting opens the Marketplace at it', (tester) async {
    await frame(tester, size: _wide);
    await tester.tap(_key('rail-settings'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).first, 'link previews');
    await settle(tester);
    await tester.tap(find.descendant(of: find.byType(SettingsScreen), matching: find.text('Link previews')).first);
    await settle(tester);
    await settle(tester);
    expect(shell().marketOpen, isTrue);
    expect(shell().settingsOpen, isFalse);
    expect(shell().marketSection.value, 'discover');
    expect(_key('plugins-detail-embeds'), findsOneWidget);
  });

  testWidgets('at 412x892: a hit in Plugins\' own rows opens its plugin; a pack\'s setting opens its page with the row lit', (tester) async {
    await frame(tester);
    Future<void> search(String words, String hit) async {
      await tester.tap(_key('rail-settings'));
      await settle(tester);
      await tester.enterText(find.byType(EditableText).first, words);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(SettingsScreen), matching: find.text(hit)).first);
      await settle(tester);
      await settle(tester);
    }

    await search('watch together', 'Watch together');
    expect(shell().marketOpen, isTrue);
    expect(_key('plugins-detail-watch'), findsOneWidget);
    shell().go('messages');
    await settle(tester);
    // Bills, added from the Marketplace: its own settings are in the unlisted Plugins section Settings' search reads.
    await addStore(installed!, billsPack());
    await settle(tester);
    await search('more words for bills', 'More words for bills');
    expect(_key('plugins-detail-xbills'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    final lit = [for (final e in find.byKey(SettingsFindableMark.lightKey).evaluate()) SettingsFindableMark.isLit(e.widget)];
    expect(lit, contains(true), reason: 'the row the search found is lit');
  });

  testWidgets('a hit in a plugin\'s own section opens that plugin, whichever other plugin shares its words', (tester) async {
    // Kinds of text comes before Spam filter and shares "Signal and Telegram" with it: a hit in Spam filter's own
    // section opened Kinds of text's page, and with Kinds off a page that didn't even draw the setting (review,
    // 2026-11-20).
    for (final kinds in ['on', 'off']) {
      state.set('plugin_kinds', kinds);
      await frame(tester);
      await tester.tap(_key('rail-settings'));
      await settle(tester);
      await tester.enterText(find.byType(EditableText).first, 'signal and telegram');
      await settle(tester);
      final hits = [for (final e in find.byType(SettingsSectionRow).evaluate()) (e.widget as SettingsSectionRow).summary];
      expect(hits, contains('Spam filter'), reason: 'Kinds $kinds');
      if (kinds == 'on') expect(hits, contains('Kinds of text'));
      await tester.tap(find.byWidgetPredicate((w) => w is SettingsSectionRow && w.label == 'Signal and Telegram' && w.summary == 'Spam filter'));
      await settle(tester);
      await settle(tester);
      expect(shell().marketOpen, isTrue, reason: 'Kinds $kinds');
      expect(_key('plugins-detail-spam'), findsOneWidget, reason: 'Kinds $kinds');
      expect(_key('plugins-detail-kinds'), findsNothing, reason: 'Kinds $kinds');
      shell().go('messages');
      await settle(tester);
    }
  });

  testWidgets('In development lists a plugin whose copy doesn\'t load, with its problems, as its row counts it', (tester) async {
    // The row said "1 loaded" over a page that said "Nothing loaded yet." (review, 2026-11-20).
    state.setFlag('dev_mode', true);
    final here = await ready();
    expect((await here.loadDev(packFile(billsJson(), (j) => j['hue'] = 'chartreuse'), const DevSource('paste'))).code, 'invalid');
    await frame(tester, size: _wide);
    shell().marketplace(section: 'dev');
    await settle(tester);
    expect(find.descendant(of: _key('market-row-dev'), matching: find.text('1 not loading')), findsOneWidget);
    expect(_key('plugins-nothing'), findsNothing);
    expect(find.descendant(of: _key('plugins-dev-broken-mybills'), matching: find.text('1 problem')), findsOneWidget);
    await tester.tap(_key('plugins-dev-broken-mybills'));
    await settle(tester);
    expect(_key('dev-plugin-screen-mybills'), findsOneWidget);
    // Its own screen can't send it for review until it loads: the form opened on it held another plugin.
    final submit = tester.widget<SettingRow>(_key('dev-plugin-submit-mybills'));
    expect([submit.disabled, submit.onPress], [true, null]);
    expect(switch (submit.hint) { Tr(:final words) => words, Text(:final data) => data, _ => null }, 'Put its problems right first.');
    // One that loads beside it: counted and listed apart.
    await addDev(here, billsPack(id: 'mytickets', name: 'Tickets mine'));
    shell().marketplace(section: 'added');
    await settle(tester);
    shell().marketplace(section: 'dev');
    await settle(tester);
    expect(find.descendant(of: _key('market-row-dev'), matching: find.text('1 loaded · 1 not loading')), findsOneWidget);
    expect(_key('plugins-shelf-dev'), findsOneWidget);
    expect(_key('plugins-dev-broken-mybills'), findsOneWidget);
  });

  testWidgets('a tab\'s menu names the plugin that made it, and opens its page, on a phone and beside the list', (tester) async {
    // A puzzling new tab leads back to its plugin (D.6), by a long press or the other button: nothing held the line
    // (review, 2026-11-20).
    final bill = packSamples.firstWhere((s) => s.id == 's01').text;
    ListPhone([
      {...ListPhone.conversation(3, '72975', bill, unread: true), 'heard': bill},
    ]).install();
    // Kinds of text's Payment reminders would take the bill first.
    state.set('plugin_kinds', 'off');
    await addStore(await ready(), billsPack());
    Finder tab(String label) {
      Finder by(bool Function(Widget w) test) => find.descendant(of: find.byType(SectionTabs), matching: find.byWidgetPredicate(test));
      final exact = by((w) => (w is Semantics && w.properties.label == label) || (w is Text && w.data == label));
      return exact.evaluate().isNotEmpty ? exact.last : by((w) => w is Semantics && (w.properties.label ?? '').startsWith('$label, ')).last;
    }

    for (final (size, wide) in [(_phone, false), (_wide, true)]) {
      await frame(tester, size: size);
      for (final (label, about, page) in [('Bills', 'About Bills', 'plugins-detail-xbills'), ('Codes', 'About Codes', 'plugins-detail-codes')]) {
        // The tab's label wraps its press beside the list, which the hit test doesn't name: the menu that opens says it
        // was this tab's.
        wide ? await tester.tap(tab(label), buttons: kSecondaryButton, warnIfMissed: false) : await tester.longPress(tab(label));
        await settle(tester);
        expect(find.text(about), findsOneWidget, reason: '$label, ${wide ? 'wide' : 'a phone'}');
        await tester.tap(find.text(about));
        await settle(tester);
        await settle(tester);
        expect(shell().marketOpen, isTrue);
        expect(shell().marketSection.value, 'discover');
        expect(_key(page), findsOneWidget, reason: '$label, ${wide ? 'wide' : 'a phone'}');
        shell().go('messages');
        await settle(tester);
        await settle(tester);
      }
    }
  });

  testWidgets('beside Settings the first section is Me, now that Plugins is the Marketplace\'s', (tester) async {
    await frame(tester, size: _wide);
    await tester.tap(_key('rail-settings'));
    await settle(tester);
    expect(shell().settingsSection.value, 'me');
    expect(find.byType(PluginsPage), findsNothing);
  });

  testWidgets('the ring\'s menu: its sections offered now', (tester) async {
    state.setFlag('dev_mode', true);
    await frame(tester, size: _wide);
    await tester.tap(_key('rail-marketplace'), buttons: 2);
    await settle(tester);
    for (final label in ['Discover', 'Added', 'Submit a plugin', 'My submissions', 'In development']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Updates'), findsNothing, reason: 'none waiting');
  });

  testWidgets('Submit with a dev pack opens the form with it loaded, and My submissions at a submission marks it', (tester) async {
    await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'maya'), ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    state.setFlag('dev_mode', true);
    await addDev(await ready(), billsPack());
    await frame(tester, size: _wide);
    shell().marketplace(section: 'submit', arg: 'bills');
    await settle(tester);
    expect(shell().marketSection.value, 'submit');
    expect(_key('market-submit'), findsOneWidget);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.textContaining('bills · 1.0.0')), findsOneWidget);
    expect(tester.widget<SettingsSectionRow>(_key('market-row-submit')).selected, isTrue);
    final sid = relay.store.put(packBytes(billsPack()), status: 'submitted');
    shell().marketplace(section: 'mine', arg: sid);
    await settle(tester);
    expect(shell().marketSection.value, 'mine');
    expect(_key('market-mine'), findsOneWidget);
    expect(find.descendant(of: _key('market-mine-marked'), matching: _key('market-mine-$sid')), findsOneWidget);
    // The Review queue, for the admin, reads its queue in the pane.
    state.setFlag('dev_mode', true);
    await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
    await settle(tester);
    shell().marketplace(section: 'review');
    await settle(tester);
    expect(_key('market-review'), findsOneWidget);
    expect(_key('market-review-$sid'), findsOneWidget);
    expect(market.reviewWaiting, 1);
  });
}

/// The app's tree as pumpScreen (test/support/list_harness.dart) makes it, to pump only part of a frame.
Widget _app(TokenSheet sheet, AppState state, Widget screen) => AppScope(
      state: state,
      child: WidgetsApp(
        color: const Color(0xFF4F5BD5),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(
          sheet: sheet,
          attrs: {'theme': 'light', ...ghostAttrs(state, 'mobile')},
          child: InkOverrides(child: GlacierToastProvider(child: child!)),
        ),
        home: screen,
      ),
    );
