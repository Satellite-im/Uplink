import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/market/market_models.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/settings.dart';
import 'package:ghost_messaging/plugins/spam.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/plugins/record_call.dart';
import 'package:ghost_messaging/ui/market/dev_plugins.dart';
import 'package:ghost_messaging/ui/market/market_flows.dart';
import 'package:ghost_messaging/ui/market/marketplace_screen.dart' show marketSummary;
import 'package:ghost_messaging/ui/plugins_page/plugin_art.dart';
import 'package:ghost_messaging/ui/plugins_page/plugin_cards.dart';

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// Discover, Added and In development with plugins from other developers (lib/ui/plugins_page; Matt, 2026-11-20: "I
/// would like users to be able to develop and submit their own plugins to our plugin marketplace and I'd like to be able
/// to verify them for the store through a review process"): a checked listing's card and page drawn from its package,
/// adding it after its consent sheet, the chips and shelves for packs, a store pack's Remove, a stuck pack's words,
/// Updates, a new developer, a computer with no texts, an iPhone, the catalog's lines, pictures and screenshots. Every
/// pack is read, checked, installed, withdrawn and retired by the runtime itself; only the relay is made up.
Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  late Directory dir;
  late InstalledPlugins installed;
  late FakeRelay relay;
  late MarketState market;
  late AppState state;
  final oldInstalled = InstalledPlugins.instance, oldMarket = MarketState.instance, oldRegistry = PluginRegistry.instance;

  setUp(() {
    ListPhone(const []).install();
    dir = Directory.systemTemp.createTempSync('market-discover-');
    PluginRegistry.instance = PluginRegistry(const [CodesPlugin(), SpamPlugin()]);
    relay = FakeRelay();
    // It reads InstalledPlugins.instance as it goes: each test puts its own in place.
    market = marketOver(relay, Directory('${dir.path}/market'));
    MarketState.instance = market;
    state = AppState();
  });
  tearDown(() {
    InstalledPlugins.instance = oldInstalled;
    MarketState.instance = oldMarket;
    PluginRegistry.instance = oldRegistry;
    Sms.standalone = false;
    dir.deleteSync(recursive: true);
  });

  /// This device's packs, read for the app the screens draw from: made inside the test, whose zone its work runs in.
  Future<void> ready({List<String>? keys, bool storeAllowed = true}) async {
    installed = await installedFor(state, Directory('${dir.path}/plugins'), keys: keys, storeAllowed: storeAllowed);
    InstalledPlugins.instance = installed;
  }

  /// Lists [packs] on the relay, each approved by the tests' reviewer unless [entries] says otherwise, and has the
  /// Marketplace fetch and check them, as a refresh does (real I/O, outside the test's clock).
  Future<void> listed(WidgetTester tester, List<PluginPack> packs, {Map<String, CatalogEntry> entries = const {}}) async {
    for (final p in packs) {
      await relay.list(p, entry: entries[p.id]);
    }
    await tester.runAsync(() => market.refresh(force: true));
  }

  Future<void> page(WidgetTester tester, Widget screen, {Size size = const Size(412, 892)}) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, screen, state, size: size);
  }

  bool running(String id) => PluginRegistry.instance.plugins.any((p) => p.id == id);

  testWidgets('a checked listing\'s card: drawn from its package, Reviewed, its tags; an unchecked entry isn\'t shown', (tester) async {
    await ready();
    final forged = billsPack(id: 'receipts', name: 'Receipts');
    await listed(tester, [billsPack(), forged], entries: {'receipts': await entryOf(forged, forged: true)});
    await page(tester, marketPluginsScreen());
    final card = _key('plugins-card-xbills');
    await tester.ensureVisible(card);
    await settle(tester);
    // Its name, and its first tag (Bills) on its source line with the second (Money).
    expect(find.descendant(of: card, matching: find.text('Bills')), findsNWidgets(2));
    expect(find.descendant(of: card, matching: find.textContaining('By @maya')), findsOneWidget);
    expect(_key('plugins-reviewed-xbills'), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Money')), findsOneWidget, reason: 'its tags on its source line');
    expect(find.descendant(of: card, matching: find.text('Sorting')), findsNothing, reason: 'two tags at most');
    expect(_key('plugins-card-xreceipts'), findsNothing, reason: 'its approval didn\'t verify');
    // In More to add, not Added: a leftover switch never makes a listing read as added.
    state.set('plugin_xbills', 'on');
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-discover'), matching: card), findsOneWidget);
    expect(find.text('More to add'), findsOneWidget);
  });

  testWidgets('the consent sheet is the package\'s own lines; Add installs it, it moves to Added, and the toast names its tab', (tester) async {
    await ready();
    await listed(tester, [billsPack()]);
    await page(tester, marketPluginsScreen());
    await tester.ensureVisible(_key('plugins-add-xbills'));
    await settle(tester);
    await tester.tap(_key('plugins-add-xbills'));
    await settle(tester);
    final consent = _key('market-consent');
    expect(consent, findsOneWidget);
    for (final line in ['By @maya', 'Reviewed by Uplink', 'Reads texts from numbers not in your contacts', 'Sorts texts into its own tabs and kinds', 'Can mark texts as read', 'Copies to your clipboard when you ask', 'It adds:', 'A Bills tab in the list', 'A kind in the list\'s filter: Receipts', 'Can mark Receipts texts as read as they come, once you switch it on']) {
      expect(find.descendant(of: consent, matching: find.text(line)), findsOneWidget, reason: line);
    }
    expect(_key('market-consent-dev'), findsNothing);
    expect(installed.store, isEmpty, reason: 'nothing is added before the sheet is answered');
    await tester.ensureVisible(find.text('Add Bills'));
    await settle(tester);
    await tester.tap(find.text('Add Bills'));
    await settle(tester);
    expect(File('${dir.path}/plugins/store/bills/1.0.0/package.ghostplugin').readAsBytesSync(), packBytes(billsPack()), reason: 'the bytes that were checked');
    expect(state.flag('plugin_xbills', fallback: false), isTrue);
    expect(running('xbills'), isTrue);
    expect(find.text('Bills added. Its Bills tab is in Messages.'), findsOneWidget);
    await tester.ensureVisible(_key('plugins-shelf-added'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-xbills')), findsOneWidget);
    expect(_key('plugins-added-xbills'), findsOneWidget);
  });

  testWidgets('a listing that needs a newer app, and one on a computer with no texts, can\'t be added, and say why', (tester) async {
    await ready();
    await listed(tester, [billsPack(minApp: '9.0.0')]);
    expect(market.listings.single.needsNewerApp, isTrue);
    await page(tester, marketPluginsScreen(open: 'xbills'));
    expect(_key('plugins-detail-xbills'), findsOneWidget);
    expect(find.text('Needs a newer Uplink'), findsOneWidget);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-add-xbills')), warnIfMissed: false);
    await settle(tester);
    expect(_key('market-consent'), findsNothing);
    // A computer of its own, with no phone's texts.
    Sms.standalone = true;
    await listed(tester, [billsPack(id: 'parcels', name: 'Parcels')]);
    await page(tester, marketPluginsScreen(open: 'xparcels'));
    expect(_key('plugins-detail-nohere'), findsOneWidget);
    expect(find.text(marketNoTextsWords), findsWidgets);
    await tester.tap(find.descendant(of: _key('plugins-detail-xparcels'), matching: _key('plugins-add-xparcels')), warnIfMissed: false);
    await settle(tester);
    expect(_key('market-consent'), findsNothing);
    expect(installed.store, isEmpty);
  });

  testWidgets('From developers and In development chips; Added and In development alone, and their empty words', (tester) async {
    await ready();
    await listed(tester, [billsPack()]);
    await page(tester, marketPluginsScreen());
    expect(_key('plugins-chip-store'), findsOneWidget);
    expect(_key('plugins-chip-dev'), findsNothing);
    await tester.ensureVisible(_key('plugins-chip-store'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-store'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-store'), matching: _key('plugins-card-xbills')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-shelf-store'), matching: _key('plugins-card-codes')), findsNothing);
    state.setFlag('dev_mode', true);
    // A pack in development may come with no picture: its tile draws its symbol.
    await addDev(installed, billsPack(id: 'tickets', name: 'Tickets', noIcon: true));
    await settle(tester);
    expect(_key('plugins-chip-dev'), findsOneWidget);
    await tester.ensureVisible(_key('plugins-chip-dev'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-dev'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-dev'), matching: _key('plugins-card-xtickets')), findsOneWidget);
    expect(_key('plugins-dev-xtickets'), findsOneWidget);
    final tile = find.descendant(of: _key('plugins-card-xtickets'), matching: find.byType(PluginTile));
    expect(find.descendant(of: tile, matching: find.byType(AppIcon)), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.byType(Image)), findsNothing);
    // In development alone: the dev packs, no band, no chips, no search.
    await page(tester, marketPluginsScreen(title: 'In development', shelf: 'dev', head: false));
    expect(find.descendant(of: _key('plugins-shelf-dev'), matching: _key('plugins-card-xtickets')), findsOneWidget);
    expect(_key('plugins-chips'), findsNothing);
    expect(_key('plugins-search'), findsNothing);
    await installed.removeDev('tickets');
    await settle(tester);
    expect(find.text('Nothing loaded yet. Load one in Settings › Developer › Plugins in development.'), findsOneWidget);
    expect(find.text('Show every plugin'), findsNothing);
    // Added alone, with nothing on.
    state
      ..setFlag('plugin_codes', false)
      ..setFlag('plugin_spam', false);
    await page(tester, marketPluginsScreen(title: 'Added', shelf: 'added', head: false));
    expect(find.text('Nothing added yet.'), findsOneWidget);
    expect(_key('plugins-card-xbills'), findsNothing, reason: 'a listing isn\'t added');
  });

  testWidgets('search finds a plugin by who made it and by its tag', (tester) async {
    await ready();
    await listed(tester, [billsPack()]);
    await page(tester, marketPluginsScreen());
    Future<void> search(String words) async {
      await tester.enterText(find.descendant(of: _key('plugins-search'), matching: find.byType(EditableText)), words);
      await settle(tester);
    }

    await search('maya');
    expect(find.descendant(of: _key('plugins-shelf-found'), matching: _key('plugins-card-xbills')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-shelf-found'), matching: _key('plugins-card-codes')), findsNothing);
    await search('money');
    expect(find.descendant(of: _key('plugins-shelf-found'), matching: _key('plugins-card-xbills')), findsOneWidget);
    // The docs' Bills says "Nobody in your contacts is ever sorted": a word no plugin here has.
    await search('zebra');
    expect(find.text('Nothing called “zebra”.'), findsOneWidget);
  });

  testWidgets('a tag pressed on a plugin\'s page searches for it', (tester) async {
    await ready();
    await listed(tester, [billsPack()]);
    await page(tester, marketPluginsScreen(open: 'xbills'), size: const Size(1180, 860));
    await tester.tap(_key('plugins-detail-label-money'));
    await settle(tester);
    expect(_key('plugins-shelf-found'), findsOneWidget);
    expect(find.descendant(of: _key('plugins-shelf-found'), matching: _key('plugins-card-xbills')), findsOneWidget);
  });

  testWidgets('a store pack\'s page: Reviewed by Uplink; Remove asks, then removes', (tester) async {
    await ready();
    await addStore(installed, billsPack(support: 'help@example.com'));
    await page(tester, marketPluginsScreen(open: 'xbills'));
    expect(_key('plugins-detail-xbills'), findsOneWidget);
    expect(tester.widget<Text>(_key('plugins-detail-source')).data, 'By @maya\nReviewed by Uplink');
    expect(_key('plugins-detail-reviewed'), findsOneWidget);
    expect(_key('plugins-detail-dev'), findsNothing);
    expect(find.text('Built-in plugins sort first: a text Codes, Spam filter or a kind of Kinds of text takes stays theirs.'), findsOneWidget);
    expect(_key('plugins-report-xbills'), findsOneWidget);
    // Its help, an email address, is copied.
    await tester.ensureVisible(_key('plugins-detail-support'));
    await settle(tester);
    await tester.tap(find.descendant(of: _key('plugins-detail-support'), matching: find.text('help@example.com')));
    await settle(tester);
    expect(find.text('Address copied'), findsOneWidget);
    await tester.ensureVisible(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-remove-xbills')));
    await settle(tester);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-remove-xbills')));
    await settle(tester);
    expect(_key('market-remove-confirm'), findsOneWidget);
    expect(installed.storeOf('bills'), isNotNull, reason: 'asks first');
    await tester.ensureVisible(find.text('Remove Bills'));
    await settle(tester);
    await tester.tap(find.text('Remove Bills'));
    await settle(tester);
    expect(installed.storeOf('bills'), isNull);
    expect(running('xbills'), isFalse);
    expect(Directory('${dir.path}/plugins/store/bills').existsSync(), isFalse);
  });

  testWidgets('a withdrawn pack and one whose key was retired show on Added as stuck, with their words, and go with Remove', (tester) async {
    // A second review key this build pins, then retires by its own signature.
    final second = KeysSigner(NetKeys.generate());
    await ready(keys: [reviewKey, base64Encode(second.publicKey)]);
    await addStore(installed, billsPack());
    await addStore(installed, billsPack(id: 'parcels', name: 'Parcels'), by: second);
    await withdraw(installed, billsPack(), 'It copied texts it shouldn\'t have');
    await retire(installed, second);
    expect([for (final p in installed.store) '${p.id} ${p.problem} ${p.running}'], ['bills revoked false', 'parcels untrusted_key false']);
    await page(tester, marketPluginsScreen(title: 'Added', shelf: 'added', head: false));
    final stuck = _key('plugins-shelf-stuck');
    expect(find.descendant(of: stuck, matching: _key('plugins-card-xbills')), findsOneWidget);
    expect(find.descendant(of: stuck, matching: _key('plugins-card-xparcels')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-problem-xbills'), matching: find.text('Withdrawn')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-problem-xparcels'), matching: find.text('Not working')), findsOneWidget);
    expect(_key('plugins-add-xbills'), findsNothing, reason: 'nothing to add: its page has Remove');
    await tester.tap(_key('plugins-card-xbills'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-detail-withdrawn'), matching: find.text('Withdrawn from the Marketplace: It copied texts it shouldn\'t have. It\'s off, and does nothing until you remove it.')), findsOneWidget);
    expect(_key('plugins-report-xbills'), findsNothing);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-remove-xbills')));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove Bills'));
    await settle(tester);
    await tester.tap(find.text('Remove Bills'));
    await settle(tester);
    expect([for (final p in installed.store) p.id], ['parcels']);
    await page(tester, marketPluginsScreen(open: 'xparcels'));
    expect(find.descendant(of: _key('plugins-detail-withdrawn'), matching: find.text('This version of Uplink can\'t check its review, so it\'s off. An update may fix it.')), findsOneWidget);
    await tester.tap(find.descendant(of: _key('plugins-detail-xparcels'), matching: _key('plugins-remove-xparcels')));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove Parcels'));
    await settle(tester);
    await tester.tap(find.text('Remove Parcels'));
    await settle(tester);
    expect(installed.store, isEmpty);
    expect(Directory('${dir.path}/plugins/store').listSync(), isEmpty, reason: 'their files went with them');
  });

  testWidgets('Updates: Update replaces it keeping the switch off; where it can do more, it asks first, the new host shown', (tester) async {
    await ready();
    await addStore(installed, billsPack(), on: false);
    await listed(tester, [billsPack(version: '1.1.0', whatsNew: 'Faster.')]);
    expect(market.updates, hasLength(1));
    await page(tester, const MarketUpdatesPage());
    expect(_key('market-update-bills'), findsOneWidget);
    expect(find.textContaining('1.0.0 → 1.1.0'), findsOneWidget);
    await tester.tap(find.descendant(of: _key('market-update-bills'), matching: find.text('Update')));
    await settle(tester);
    expect(installed.storeOf('bills')!.version, '1.1.0');
    expect(state.flag('plugin_xbills', fallback: false), isFalse, reason: 'an update leaves the switch as it was');
    expect(_key('market-updates-none'), findsOneWidget, reason: 'it stays, saying so');
    // A version that opens a page of its own asks first, saying where.
    await listed(tester, [billsPack(version: '1.2.0', link: 'https://bills.example/pay')]);
    await settle(tester);
    await tester.tap(find.descendant(of: _key('market-update-bills'), matching: find.text('Update')));
    await settle(tester);
    expect(_key('market-update-grew'), findsOneWidget);
    expect(find.text('It can now:'), findsOneWidget);
    expect(find.text('Opens bills.example in your browser'), findsOneWidget);
    expect(find.text('A button in a conversation\'s header'), findsOneWidget);
    expect(find.text('Reads texts from numbers not in your contacts'), findsNothing, reason: 'only what is new');
    expect(installed.storeOf('bills')!.version, '1.1.0', reason: 'nothing until it is agreed to');
    await tester.ensureVisible(find.text('Update Bills'));
    await settle(tester);
    await tester.tap(find.text('Update Bills'));
    await settle(tester);
    expect(installed.storeOf('bills')!.version, '1.2.0');
    expect(installed.storeOf('bills')!.pack!.links, ['https://bills.example/pay']);
  });

  testWidgets('Update all: those that can do nothing new; one that can do more asks on its own', (tester) async {
    await ready();
    await addStore(installed, billsPack());
    await addStore(installed, billsPack(id: 'parcels', name: 'Parcels'));
    await listed(tester, [billsPack(version: '1.1.0'), billsPack(id: 'parcels', name: 'Parcels', version: '1.1.0', link: 'https://parcels.example/track')]);
    await page(tester, const MarketUpdatesPage());
    expect(find.descendant(of: _key('market-update-all'), matching: find.text('1 of 2: the others can do something new, so each asks first.')), findsOneWidget);
    await tester.tap(_key('market-update-all'));
    await settle(tester);
    expect([for (final p in installed.store) '${p.id} ${p.version}'], ['bills 1.1.0', 'parcels 1.0.0']);
    expect(find.text('1 updated'), findsOneWidget);
    expect(_key('market-update-parcels'), findsOneWidget, reason: 'still waiting, to be asked about');
    expect(_key('market-update-all'), findsNothing, reason: 'one left');
  });

  testWidgets('a newer version by another developer is offered as a new plugin, never as an update', (tester) async {
    await ready();
    await addStore(installed, billsPack());
    // A choice of its own, which goes with the copy by @maya.
    state.set('plugin_xbills_extra', 'council tax');
    await listed(tester, [billsPack(version: '1.2.0', developer: 'someoneelse')]);
    expect(market.updates, isEmpty);
    await page(tester, marketPluginsScreen());
    await tester.ensureVisible(find.descendant(of: _key('plugins-shelf-discover'), matching: _key('plugins-card-xbills')));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-discover'), matching: _key('plugins-card-xbills')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-xbills')), findsOneWidget, reason: 'the copy here, by @maya');
    await tester.tap(find.descendant(of: _key('plugins-shelf-discover'), matching: _key('plugins-card-xbills')), warnIfMissed: true);
    await settle(tester);
    expect(find.text('This is now by @someoneelse. Adding it removes your copy by @maya, and your choices for it.'), findsOneWidget);
    expect(_key('plugins-update-xbills'), findsNothing);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-add-xbills')));
    await settle(tester);
    await tester.ensureVisible(find.text('Add Bills'));
    await settle(tester);
    await tester.tap(find.text('Add Bills'));
    await settle(tester);
    final now = installed.storeOf('bills')!;
    expect([now.version, now.pack!.developer], ['1.2.0', 'someoneelse']);
    expect(state.choice('plugin_xbills_extra', ''), '', reason: 'the old copy\'s choices went with it');
  });

  testWidgets('in a wide window the new developer\'s card opens its own page, and only that card is chosen', (tester) async {
    // The copy here and the listing share the id xbills: remembered by id alone, the pane showed the copy's page and
    // drew both cards chosen (review, 2026-11-20).
    await ready();
    await addStore(installed, billsPack());
    await listed(tester, [billsPack(version: '1.2.0', developer: 'someoneelse')]);
    await page(tester, marketPluginsScreen(), size: const Size(1180, 860));
    final listingCard = find.descendant(of: _key('plugins-shelf-discover'), matching: _key('plugins-card-xbills'));
    await tester.ensureVisible(listingCard);
    await settle(tester);
    await tester.tap(listingCard);
    await settle(tester);
    expect(_key('plugins-pane'), findsOneWidget);
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('market-developer-changed')), findsOneWidget);
    expect(find.descendant(of: _key('plugins-pane'), matching: find.textContaining('By @someoneelse')), findsWidgets);
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('plugins-remove-xbills')), findsNothing);
    bool chosen(Finder card) => tester.widget<PluginCard>(find.ancestor(of: card, matching: find.byType(PluginCard)).first).selected;
    expect(chosen(listingCard), isTrue);
    expect(chosen(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-xbills'))), isFalse);
    // The copy's card opens the copy's page in its place.
    await tester.ensureVisible(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-xbills')));
    await settle(tester);
    await tester.tap(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-xbills')));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('market-developer-changed')), findsNothing);
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('plugins-remove-xbills')), findsOneWidget);
    // And Discover opened at the listing, as the Marketplace's search hit for it opens it, is the listing's page.
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xbills', openListing: true), size: const Size(1180, 860));
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('market-developer-changed')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xbills', openListing: true));
    expect(_key('market-developer-changed'), findsOneWidget, reason: 'on a phone too');
  });

  testWidgets('on a phone a plugin\'s page goes once its plugin is removed and isn\'t listed', (tester) async {
    // Kept open on the plugin as it was, the page offered Remove again ("It isn't on this device.") or Add, which
    // switched on a plugin that wasn't there (review, 2026-11-20).
    await ready();
    await addStore(installed, billsPack());
    await withdraw(installed, billsPack(), 'It copied texts it shouldn\'t have');
    await page(tester, marketPluginsScreen(open: 'xbills'));
    expect(_key('plugins-detail-withdrawn'), findsOneWidget);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-remove-xbills')));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove Bills'));
    await settle(tester);
    await tester.tap(find.text('Remove Bills'));
    await settle(tester);
    expect(installed.store, isEmpty);
    expect(_key('plugins-detail-xbills'), findsNothing);
    expect(_key('plugins-detail-withdrawn'), findsNothing);
    // A running store pack that isn't listed: removed, its page goes rather than offering Add.
    await addStore(installed, billsPack(id: 'parcels', name: 'Parcels'));
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xparcels'));
    await tester.tap(find.descendant(of: _key('plugins-detail-xparcels'), matching: _key('plugins-remove-xparcels')));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove Parcels'));
    await settle(tester);
    await tester.tap(find.text('Remove Parcels'));
    await settle(tester);
    expect(_key('plugins-detail-xparcels'), findsNothing);
    expect(_key('plugins-add-xparcels'), findsNothing);
    expect(state.choice('plugin_xparcels', ''), '', reason: 'nothing switched on for a plugin that isn\'t here');
    // One still listed comes back as its listing.
    await addStore(installed, billsPack(id: 'tickets', name: 'Tickets'));
    await listed(tester, [billsPack(id: 'tickets', name: 'Tickets')]);
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xtickets'));
    await tester.tap(find.descendant(of: _key('plugins-detail-xtickets'), matching: _key('plugins-remove-xtickets')));
    await settle(tester);
    await tester.ensureVisible(find.text('Remove Tickets'));
    await settle(tester);
    await tester.tap(find.text('Remove Tickets'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-detail-xtickets'), matching: _key('plugins-add-xtickets')), findsOneWidget);
    // A plugin in development removed from its own screen, opened from its page by its problems: both go, leaving no
    // page that offers to switch on what isn't loaded any more.
    state.setFlag('dev_mode', true);
    await addDev(installed, billsPack(id: 'receipts', name: 'Receipts', description: 'Receipts in a kind of their own. See https://example.com/receipts for more.'), agree: true);
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xreceipts'), size: const Size(412, 4000));
    await tester.tap(_key('plugins-problems-xreceipts'));
    await settle(tester);
    expect(_key('dev-plugin-screen-receipts'), findsOneWidget);
    await tester.tap(_key('dev-plugin-remove-receipts'));
    await settle(tester);
    expect(installed.devOf('receipts'), isNull);
    expect(find.byKey(const ValueKey('dev-plugin-screen-receipts'), skipOffstage: false), findsNothing);
    expect(find.byKey(const ValueKey('plugins-detail-xreceipts'), skipOffstage: false), findsNothing);
  });

  testWidgets('an update that needs a newer Uplink isn\'t counted, nor offered on Updates or its page', (tester) async {
    await ready();
    await addStore(installed, billsPack());
    await listed(tester, [billsPack(version: '1.1.0', minApp: '9.0.0')]);
    expect(market.updates, isEmpty);
    await page(tester, const MarketUpdatesPage());
    expect(_key('market-updates-none'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await page(tester, marketPluginsScreen(open: 'xbills'));
    expect(_key('plugins-detail-xbills'), findsOneWidget);
    expect(_key('plugins-update-xbills'), findsNothing);
  });

  testWidgets('Update all says what was updated and what stopped the rest', (tester) async {
    // It said "2 updated" whatever happened (review, 2026-11-20): here this device refuses to write Bills' new copy.
    await ready();
    await addStore(installed, billsPack());
    await addStore(installed, billsPack(id: 'parcels', name: 'Parcels'));
    await listed(tester, [billsPack(version: '1.1.0'), billsPack(id: 'parcels', name: 'Parcels', version: '1.1.0')]);
    final folder = '${dir.path}/plugins/store/bills';
    Process.runSync('chmod', ['0555', folder]);
    addTearDown(() => Process.runSync('chmod', ['0755', folder]));
    await page(tester, const MarketUpdatesPage());
    await tester.tap(_key('market-update-all'));
    await settle(tester);
    expect([for (final p in installed.store) '${p.id} ${p.version}'], ['bills 1.0.0', 'parcels 1.1.0']);
    expect(find.text('2 updated'), findsNothing);
    expect(find.text('1 updated. Bills: It couldn\'t be saved on this phone.'), findsOneWidget);
    expect(_key('market-update-bills'), findsOneWidget, reason: 'still waiting');
    Process.runSync('chmod', ['0755', folder]);
  });

  testWidgets('a tag pressed on In development\'s or Added\'s plugin page searches Discover, and the page stays its own', (tester) async {
    // It set a search Added and In development don't have, and In development then listed the Added shelf under its
    // own name (review, 2026-11-20).
    await ready();
    state.setFlag('dev_mode', true);
    await addDev(installed, billsPack(id: 'tickets', name: 'Tickets'));
    await page(tester, marketPluginsScreen(title: 'In development', shelf: 'dev', head: false));
    await tester.tap(_key('plugins-card-xtickets'));
    await settle(tester);
    await tester.tap(find.descendant(of: _key('plugins-detail-xtickets'), matching: _key('plugins-detail-label-bills')));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-shelf-found'), matching: _key('plugins-card-xtickets')), findsOneWidget, reason: 'Discover, searching for Bills');
    expect(tester.widget<EditableText>(find.descendant(of: _key('plugins-search'), matching: find.byType(EditableText))).controller.text, 'Bills');
    // Under it, In development as it was.
    expect(find.byKey(const ValueKey('plugins-shelf-dev'), skipOffstage: false), findsOneWidget, reason: 'In development still lists its own');
    expect(find.byKey(const ValueKey('plugins-shelf-added'), skipOffstage: false), findsNothing);
  });

  testWidgets('Added alone lists plugins for circles under their own heading, and its row counts what it lists', (tester) async {
    await ready();
    PluginRegistry.instance = PluginRegistry(const [CodesPlugin(), SpamPlugin(), RecordCallPlugin()]);
    state
      ..setFlag('plugin_codes', false)
      ..setFlag('plugin_spam', false)
      ..setFlag('plugin_recordcall', true);
    await page(tester, marketPluginsScreen(title: 'Added', shelf: 'added', head: false));
    expect(find.descendant(of: _key('plugins-shelf-added-circles'), matching: _key('plugins-card-recordcall')), findsOneWidget);
    expect(find.text('Nothing added yet.'), findsNothing);
    expect(marketSummary('added', state).text, '1 added');
    // A withdrawn pack is on the page, and on its row.
    state.setFlag('plugin_recordcall', false);
    await addStore(installed, billsPack());
    await withdraw(installed, billsPack(), 'Pulled');
    await settle(tester);
    expect(_key('plugins-shelf-stuck'), findsOneWidget);
    expect(marketSummary('added', state).text, '1 not running');
  });

  testWidgets('a paused plugin in development can be turned back on from its page and its own screen', (tester) async {
    await ready();
    state.setFlag('dev_mode', true);
    await addDev(installed, billsPack(id: 'tickets', name: 'Tickets'), agree: true);
    final sha = sha256Hex(packBytes(billsPack(id: 'tickets', name: 'Tickets')));
    // Paused as the runtime keeps a pause: by its copy's SHA-256, and loaded again.
    state.set('plugins_paused', jsonEncode({'xtickets': sha}));
    await addDev(installed, billsPack(id: 'tickets', name: 'Tickets'));
    expect(installed.devOf('tickets')!.problem, 'paused');
    await page(tester, marketPluginsScreen(open: 'xtickets'));
    expect(_key('plugins-detail-paused'), findsOneWidget);
    await tester.tap(_key('market-unpause-xtickets'));
    await settle(tester);
    expect(installed.devOf('tickets')!.problem, isNot('paused'));
    expect(_key('plugins-detail-paused'), findsNothing);
    // Paused again: its own screen turns it back on too, and says it is paused.
    state.set('plugins_paused', jsonEncode({'xtickets': sha}));
    await addDev(installed, billsPack(id: 'tickets', name: 'Tickets'));
    await tester.pumpWidget(const SizedBox());
    await page(tester, const DevPluginScreen(packId: 'tickets'), size: const Size(412, 4000));
    expect(find.text('paused'), findsOneWidget);
    await tester.tap(_key('dev-plugin-unpause-tickets'));
    await settle(tester);
    expect(installed.devOf('tickets')!.problem, isNot('paused'));
    expect(_key('dev-plugin-unpause-tickets'), findsNothing);
    expect(find.text('Its copy goes from this device. Your choices for it are kept for when you load it again.'), findsOneWidget, reason: 'as removeDev keeps them');
  });

  testWidgets('on an iPhone nothing from other developers, and a line saying so', (tester) async {
    await ready(storeAllowed: false);
    // Checked by the Marketplace all the same: an iPhone draws none of it.
    await listed(tester, [billsPack()]);
    expect(market.listings, hasLength(1));
    await page(tester, marketPluginsScreen());
    expect(_key('market-ios'), findsOneWidget);
    expect(find.text('Plugins from other developers aren\'t on iPhone.'), findsOneWidget);
    expect(_key('plugins-card-xbills'), findsNothing);
    expect(_key('plugins-chip-store'), findsNothing);
  });

  testWidgets('the catalog\'s lines: unreachable with Try again, off, untrusted, and still checking', (tester) async {
    await ready();
    relay.down = true;
    await tester.runAsync(() => market.refresh(force: true));
    await page(tester, marketPluginsScreen());
    expect(find.descendant(of: _key('market-catalog-problem'), matching: find.text('Plugins from other developers couldn\'t be loaded.')), findsOneWidget);
    expect(find.descendant(of: _key('market-catalog-problem'), matching: find.text('Try again')), findsOneWidget);
    relay
      ..down = false
      ..answers['GET /market/catalog'] = (status: 503, body: {'ok': false, 'error': 'off', 'message': 'The Marketplace isn\'t open on this server.'});
    await tester.runAsync(() => market.refresh(force: true));
    await settle(tester);
    expect(find.text('The Marketplace isn\'t open just now.'), findsOneWidget);
    relay.answers.clear();
    final elsewhere = billsPack();
    await listed(tester, [elsewhere], entries: {'bills': await entryOf(elsewhere, by: KeysSigner(NetKeys.generate()))});
    await settle(tester);
    expect(find.text('This version of Uplink can\'t check plugins from other developers. Update it to see them.'), findsOneWidget);
    // The line is All's and From developers', not a shelf's of the app's own.
    await tester.tap(_key('plugins-chip-added'));
    await settle(tester);
    expect(_key('market-catalog-problem'), findsNothing);
    await tester.tap(_key('plugins-chip-all'));
    await settle(tester);
    // A refresh caught while its three packages are fetched.
    relay.catalog = const Catalog();
    for (final id in ['bills', 'parcels', 'receipts']) {
      await relay.list(billsPack(id: id, name: '${id[0].toUpperCase()}${id.substring(1)}'));
    }
    late Completer<void> gate;
    late Future<void> refreshing;
    await tester.runAsync(() async {
      gate = Completer<void>();
      relay.hold = gate.future;
      refreshing = market.refresh(force: true);
      while (market.checking == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });
    await settle(tester);
    expect(find.descendant(of: _key('market-catalog-checking'), matching: find.text('Checking 3 plugins from other developers…')), findsOneWidget);
    await tester.runAsync(() async {
      gate.complete();
      await refreshing;
    });
    await settle(tester);
    expect(_key('market-catalog-checking'), findsNothing);
    expect(market.listings, hasLength(3));
  });

  testWidgets('a pack\'s picture in its tile; one that doesn\'t decode falls back to its symbol', (tester) async {
    await ready();
    await listed(tester, [billsPack(), billsPack(id: 'parcels', name: 'Parcels', icon: brokenPng())]);
    expect([for (final l in market.listings) l.id], unorderedEquals(['xbills', 'xparcels']), reason: 'the format checks a picture\'s chunks, not its pixels');
    await page(tester, marketPluginsScreen());
    await tester.ensureVisible(_key('plugins-card-xparcels'));
    await settle(tester);
    Finder tile(String id) => find.descendant(of: _key('plugins-card-$id'), matching: find.byType(PluginTile));
    expect(find.descendant(of: tile('xbills'), matching: find.byType(Image)), findsOneWidget);
    expect(find.descendant(of: tile('xbills'), matching: find.byType(AppIcon)), findsNothing);
    // Decoded by the engine on a real gap: waited for until the broken one's error has come back and its symbol is
    // drawn in its place (however busy the machine), not for a fixed time.
    final symbol = find.descendant(of: tile('xparcels'), matching: find.byType(AppIcon));
    final watch = Stopwatch()..start();
    while (symbol.evaluate().isEmpty && watch.elapsed < const Duration(seconds: 60)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(symbol, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screenshots: only those whose bytes are the ones its package names', (tester) async {
    await ready();
    final a = sha256Hex(billsIcon);
    final b = 'b' * 64;
    relay.shots[a] = billsIcon;
    // Another picture's bytes under b's name: not the one the package names, so not shown.
    relay.shots[b] = billsIcon;
    await listed(tester, [billsPack(shots: [a, b])]);
    await page(tester, marketPluginsScreen(open: 'xbills'));
    await settle(tester);
    expect(_key('plugins-detail-shots'), findsOneWidget);
    await tester.ensureVisible(_key('plugins-detail-shots'));
    await settle(tester);
    expect(_key('plugins-detail-shot-$a'), findsOneWidget);
    expect(_key('plugins-detail-shot-$b'), findsNothing);
  });

  testWidgets('updated from its page, How it looks shows the new version\'s screenshots; none to be had says so', (tester) async {
    // The strip fetched its pictures once, when it was made, and kept the old version's: Update left a heading over
    // nothing until the page was opened again (review, 2026-11-20).
    await ready();
    final a = sha256Hex(billsIcon);
    // A second picture's bytes: what they draw doesn't matter here, only that they are another's.
    final other = brokenPng();
    final b = sha256Hex(other);
    relay.shots[a] = billsIcon;
    relay.shots[b] = other;
    await addStore(installed, billsPack(shots: [a]));
    await listed(tester, [billsPack(version: '1.1.0', shots: [b], whatsNew: 'New pictures.')]);
    await page(tester, marketPluginsScreen(open: 'xbills'));
    await settle(tester);
    await tester.ensureVisible(_key('plugins-detail-shots'));
    await settle(tester);
    expect(_key('plugins-detail-shot-$a'), findsOneWidget);
    await tester.ensureVisible(_key('plugins-update-xbills'));
    await settle(tester);
    await tester.tap(_key('plugins-update-xbills'));
    await settle(tester);
    expect(installed.storeOf('bills')!.version, '1.1.0');
    expect(_key('plugins-detail-whatsnew'), findsOneWidget);
    await tester.ensureVisible(_key('plugins-detail-shots'));
    await settle(tester);
    expect(_key('plugins-detail-shot-$b'), findsOneWidget, reason: 'the new version\'s, fetched on the same page');
    expect(_key('plugins-detail-shot-$a'), findsNothing);
    expect(_key('plugins-detail-shots-none'), findsNothing);
    // A version whose pictures can't be had at all: said, not a blank under the heading.
    await listed(tester, [billsPack(id: 'mycards', name: 'Cards', shots: ['c' * 64])]);
    await page(tester, marketPluginsScreen(open: 'xmycards'));
    await settle(tester);
    await tester.ensureVisible(_key('plugins-detail-shots'));
    await settle(tester);
    expect(find.descendant(of: _key('plugins-detail-shots'), matching: find.text('Its pictures couldn\'t be loaded.')), findsOneWidget);
  });

  testWidgets('a plugin in development switched on the first time asks first, saying nobody reviewed it', (tester) async {
    await ready();
    state.setFlag('dev_mode', true);
    await addDev(installed, billsPack());
    await page(tester, marketPluginsScreen(open: 'xbills'));
    expect(_key('plugins-detail-dev'), findsOneWidget);
    expect(tester.widget<Text>(_key('plugins-detail-source')).data, 'By @maya · In development · not reviewed');
    expect(_key('plugins-detail-reviewed'), findsNothing);
    expect(_key('plugins-report-xbills'), findsNothing);
    await tester.tap(find.descendant(of: _key('plugins-detail-xbills'), matching: _key('plugins-add-xbills')));
    await settle(tester);
    expect(_key('market-consent'), findsOneWidget);
    expect(_key('market-consent-dev'), findsOneWidget);
    expect(find.text('Reviewed by Uplink'), findsNothing);
    expect(installed.devOf('bills')!.agreed, isNull, reason: 'nothing agreed to before the sheet is answered');
    await tester.ensureVisible(find.text('Switch it on'));
    await settle(tester);
    await tester.tap(find.text('Switch it on'));
    await settle(tester);
    expect(installed.devOf('bills')!.agreed, DevPack.consentLines(billsPack()));
    expect(state.flag('plugin_xbills', fallback: false), isTrue);
  });

  testWidgets('Report: a reason, a few words, the username only where asked, signed', (tester) async {
    await ready();
    await addStore(installed, billsPack());
    await page(tester, marketPluginsScreen(open: 'xbills'));
    await tester.ensureVisible(_key('plugins-report-xbills'));
    await settle(tester);
    await tester.tap(_key('plugins-report-xbills'));
    await settle(tester);
    expect(_key('market-report'), findsOneWidget);
    await tester.ensureVisible(find.text('It\'s spam'));
    await settle(tester);
    await tester.tap(find.text('It\'s spam'));
    await settle(tester);
    // Words the relay would refuse (an emoji made of several holds an invisible joiner) are said here, and nothing is
    // sent: the relay answered them with "Something in that isn't right." alone (review, 2026-11-20).
    await tester.enterText(find.descendant(of: _key('market-report-words'), matching: find.byType(EditableText)), 'It hides my bank texts 🤷\u200D♂️');
    await tester.tap(_key('market-report-send'));
    await settle(tester);
    expect(find.textContaining('Your words: Emoji made of several'), findsOneWidget);
    expect(relay.asked.where((r) => r.url.path == '/market/report'), isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.enterText(find.descendant(of: _key('market-report-words'), matching: find.byType(EditableText)), 'Every bill is a scam.');
    await tester.tap(_key('market-report-send'));
    await settle(tester);
    final sent = relay.asked.where((r) => r.url.path == '/market/report').single;
    expect(String.fromCharCodes(sent.body), '{"plugin":"bills","version":"1.0.0","reason":"spam","text":"Every bill is a scam."}');
    expect(sent.headers['x-ghost-sig'], isNotNull);
    expect(find.text('Thanks: it will be looked at.'), findsOneWidget);
  });
}
