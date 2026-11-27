import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/glacier.dart' show GlacierSwitch;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/plugins/embeds.dart';
import 'package:ghost_messaging/plugins/networks.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/quiet.dart';
import 'package:ghost_messaging/plugins/record_call.dart';
import 'package:ghost_messaging/plugins/scribe.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/settings.dart';
import 'package:ghost_messaging/plugins/spam.dart';
import 'package:ghost_messaging/plugins/translate.dart';
import 'package:ghost_messaging/ui/me.dart' show NetworkMark;
import 'package:ghost_messaging/ui/plugins_page/plugin_cards.dart';
import 'package:ghost_messaging/ui/plugins_page/plugin_detail.dart';
import 'package:ghost_messaging/ui/plugins_page/plugins_page.dart';
import 'package:ghost_messaging/ui/translated_card.dart';
import 'package:ghost_messaging/ui/settings.dart';

import 'support/list_harness.dart';

/// The Plugins page (lib/ui/plugins_page/; Matt, 2026-11-17: "redo how the plugins look with their own dedicated
/// plugins page with a marketplace like look how ghostmd has"): its shelves, its search and chips, Add on a card, a
/// plugin's page with Remove, and that page beside the shelves with room. Four of the shipped plugins, Link previews
/// and Quiet hours switched off, so there is something on both shelves.
const _plugins = <GhostPlugin>[CodesPlugin(), SpamPlugin(), EmbedsPlugin(), QuietPlugin()];

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  late PluginRegistry registry;
  late ListPhone phone;
  late AppState state;

  setUp(() {
    registry = PluginRegistry(_plugins);
    phone = ListPhone(const [])..install();
    state = AppState()
      ..setFlag('plugin_embeds', false)
      ..setFlag('plugin_quiet', false);
  });

  Future<void> page(WidgetTester tester, {Size size = const Size(412, 892), String? open}) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, pluginsScreen(registry, open), state, size: size);
  }

  testWidgets('the shelves: the band\'s count, the featured plugins, then those added and those to discover', (tester) async {
    await page(tester);
    expect(find.text('4 plugins · 2 added'), findsOneWidget);
    // Codes and the Spam filter are featured (Translate is too, where the app has it).
    expect(find.byType(FeaturedPluginCard), findsNWidgets(2));
    expect(_key('plugins-shelf-added'), findsOneWidget);
    expect(_key('plugins-shelf-discover'), findsOneWidget);
    final added = find.descendant(of: _key('plugins-shelf-added'), matching: find.byType(PluginCard));
    expect([for (final e in added.evaluate()) (e.widget as PluginCard).plugin.id], ['codes', 'spam']);
    final discover = find.descendant(of: _key('plugins-shelf-discover'), matching: find.byType(PluginCard));
    expect([for (final e in discover.evaluate()) (e.widget as PluginCard).plugin.id], ['embeds', 'quiet']);
  });

  testWidgets('the networks are plugins on a Networks shelf, each with its mark and its connection once added', (tester) async {
    // Matt, 2026-11-20: "i want all of them to be in the marketplace".
    registry = PluginRegistry([..._plugins, ...networkPlugins]);
    await page(tester, size: const Size(412, 3200));
    final cards = [for (final e in find.byType(PluginCard).evaluate()) (e.widget as PluginCard).plugin.id];
    for (final p in networkPlugins) {
      expect(cards, contains(p.id), reason: p.name);
    }
    expect(find.byType(NetworkMark), findsWidgets, reason: 'a network\'s own mark on its tile');
    await tester.runAsync(() async {
      final image = await captureImage(find.byType(WidgetsApp).evaluate().single);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/themes/networks/shelf.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
    await tester.ensureVisible(_key('plugins-chip-networks'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-networks'));
    await settle(tester);
    final shown = [for (final e in find.byType(PluginCard).evaluate()) (e.widget as PluginCard).plugin.id];
    expect(shown, [for (final p in networkPlugins) p.id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugins meant for circles are shown apart from those for this device alone, under their own chip', (tester) async {
    // Matt, 2026-11-19: "Label plugins meant for circles in a separate section from the ones that are global".
    registry = PluginRegistry([..._plugins, const RecordCallPlugin(), const ScribePlugin()]);
    state.setFlag('plugin_recordcall', true);
    await page(tester, size: const Size(412, 2400));
    List<String> on(String shelf) => [for (final e in find.descendant(of: _key(shelf), matching: find.byType(PluginCard)).evaluate()) (e.widget as PluginCard).plugin.id];
    expect(on('plugins-shelf-circles'), ['recordcall', 'scribe'], reason: 'added or not, a circle\'s plugin is in its own section');
    expect(on('plugins-shelf-added'), ['codes', 'spam']);
    expect(on('plugins-shelf-discover'), ['embeds', 'quiet']);
    await tester.tap(_key('plugins-chip-circles'));
    await settle(tester);
    expect(on('plugins-shelf-circles'), ['recordcall', 'scribe']);
    expect(_key('plugins-shelf-discover'), findsNothing);
  });

  testWidgets('Add on a card switches the plugin on, and its card moves to the added', (tester) async {
    await page(tester);
    final add = find.descendant(of: _key('plugins-shelf-discover'), matching: _key('plugins-add-embeds'));
    await tester.dragUntilVisible(add, _key('plugins-scroll'), const Offset(0, -240));
    await settle(tester);
    await tester.tap(add);
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(const EmbedsPlugin())), isTrue);
    expect(phone.prefs['plugin_embeds'], 'on');
    expect(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-embeds')), findsOneWidget);
    expect(find.text('4 plugins · 3 added'), findsOneWidget);
  });

  testWidgets('search finds a plugin by its name, its line or what it adds, and says when nothing matches', (tester) async {
    await page(tester);
    await tester.enterText(find.byType(EditableText), 'preview');
    await settle(tester);
    expect(_key('plugins-shelf-found'), findsOneWidget);
    expect(find.byType(PluginCard), findsOneWidget);
    expect(_key('plugins-card-embeds'), findsOneWidget);
    expect(find.byType(FeaturedPluginCard), findsNothing, reason: 'the featured shelf is the page unsearched');

    // What it adds: Quiet hours' "Quiet hours from 10 PM to 7 AM".
    await tester.enterText(find.byType(EditableText), '10 pm');
    await settle(tester);
    expect([for (final e in find.byType(PluginCard).evaluate()) (e.widget as PluginCard).plugin.id], ['quiet']);

    await tester.enterText(find.byType(EditableText), 'zebra');
    await settle(tester);
    expect(find.byType(PluginCard), findsNothing);
    expect(find.text('Nothing called “zebra”.'), findsOneWidget);
    await tester.tap(find.text('Show every plugin'));
    await settle(tester);
    expect(find.byType(PluginCard), findsNWidgets(4));
  });

  testWidgets('a chip shows one shelf: Added, or the plugins of a kind', (tester) async {
    await page(tester);
    // Only the shelves that have a plugin have a chip.
    expect(_key('plugins-chip-safety'), findsOneWidget);
    expect(_key('plugins-chip-organise'), findsOneWidget);
    expect(_key('plugins-chip-messages'), findsOneWidget);
    expect(_key('plugins-chip-tools'), findsNothing);

    // On a phone the chips are a row that scrolls: the last is brought into view first, as a thumb would.
    await tester.ensureVisible(_key('plugins-chip-safety'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-safety'));
    await settle(tester);
    expect([for (final e in find.byType(PluginCard).evaluate()) (e.widget as PluginCard).plugin.id], ['spam', 'quiet']);
    expect(find.byType(FeaturedPluginCard), findsNothing);

    await tester.ensureVisible(_key('plugins-chip-added'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-added'));
    await settle(tester);
    expect([for (final e in find.byType(PluginCard).evaluate()) (e.widget as PluginCard).plugin.id], ['codes', 'spam']);

    await tester.ensureVisible(_key('plugins-chip-all'));
    await settle(tester);
    await tester.tap(_key('plugins-chip-all'));
    await settle(tester);
    expect(find.byType(PluginCard), findsNWidgets(4));
  });

  testWidgets('on a phone a plugin\'s page opens over the shelves, with Remove, and Add to have it back', (tester) async {
    await page(tester);
    final card = find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-spam'));
    await tester.dragUntilVisible(card, _key('plugins-scroll'), const Offset(0, -240));
    await settle(tester);
    await tester.tap(card);
    await settle(tester);
    expect(find.byType(PluginDetailPage), findsOneWidget);
    expect(_key('plugins-detail-spam'), findsOneWidget);
    expect(find.text('What it reads and keeps'), findsOneWidget);
    // Added, its own settings are on its page: the Spam filter's strictness.
    expect(_key('plugins-detail-settings'), findsOneWidget);

    await tester.tap(_key('plugins-remove-spam'));
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(const SpamPlugin())), isFalse);
    expect(_key('plugins-detail-settings'), findsNothing, reason: 'removed, its settings wait for it to be added again');
    expect(find.text('Once it is added, its settings are here.'), findsOneWidget);

    await tester.tap(_key('plugins-add-spam'));
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(const SpamPlugin())), isTrue);
    expect(_key('plugins-remove-spam'), findsOneWidget);
  });

  testWidgets('with room a plugin\'s page stands beside the shelves, its card ringed, and closes with its X', (tester) async {
    await page(tester, size: const Size(1180, 860));
    expect(_key('plugins-pane'), findsNothing);
    // The band's line is longer since the Marketplace (plugins from other developers too): the shelf starts lower.
    await tester.ensureVisible(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-codes')));
    await settle(tester);
    await tester.tap(find.descendant(of: _key('plugins-shelf-added'), matching: _key('plugins-card-codes')));
    await settle(tester);
    expect(_key('plugins-pane'), findsOneWidget);
    expect(find.byType(PluginDetailPage), findsNothing, reason: 'beside, not over');
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('plugins-detail-codes')), findsOneWidget);
    expect(tester.widget<PluginCard>(find.descendant(of: _key('plugins-shelf-added'), matching: find.byType(PluginCard)).first).selected, isTrue);
    await tester.tap(_key('plugins-detail-close'));
    await settle(tester);
    expect(_key('plugins-pane'), findsNothing);
  });

  testWidgets('a plugin open from the start is beside the shelves with room', (tester) async {
    await page(tester, size: const Size(1180, 860), open: 'quiet');
    expect(find.descendant(of: _key('plugins-pane'), matching: _key('plugins-detail-quiet')), findsOneWidget);
  });

  testWidgets('a plugin open from the start is over the shelves on a phone', (tester) async {
    await page(tester, open: 'quiet');
    expect(find.byType(PluginDetailPage), findsOneWidget);
    expect(_key('plugins-detail-quiet'), findsOneWidget);
  });

  test('Settings no longer lists Plugins: the Marketplace is their place; the section stays, unlisted, for the search', () {
    // Matt, 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail with a
    // marketplace icon".
    final section = pluginsSection(registry);
    expect(section.listed, isFalse);
    expect(section.entry, isNull, reason: 'the band is the Marketplace\'s list\'s now');
    expect(section.screen, isNull);
    expect(section.label, 'Marketplace');
    final own = pluginPages(registry);
    expect(own, isNotEmpty);
    expect(own.every((s) => !s.listed), isTrue, reason: 'still opened by its id, and searched, but not listed');
  });

  testWidgets('Settings\' search finds a plugin by name, and the seek it carries opens the plugin\'s page', (tester) async {
    final sheet = await loadSheet(tester);
    final model = SettingsModel(state);
    addTearDown(model.dispose);
    final section = pluginsSection(registry);
    await pumpScreen(tester, sheet, SectionPage(section: section, model: model), state);
    final context = tester.element(find.byType(SectionPage));
    final hits = searchSettings(context, model, [section], 'link previews');
    expect([for (final h in hits) h.setting], contains('Link previews'));
    // A hit carries the setting it found to the shelves ([SettingsSeek]), which open that plugin: in the app the
    // Marketplace's Discover (lib/ui/shell.dart, test/marketplace_test.dart).
    await pumpScreen(tester, sheet, SettingsSeek(seek: 'Link previews', child: pluginsScreen(registry)), state);
    expect(find.byType(PluginDetailPage), findsOneWidget);
    expect(_key('plugins-detail-embeds'), findsOneWidget);
  });

  testWidgets('on a phone the chips scroll sideways in one row; with room they wrap', (tester) async {
    await page(tester);
    expect(find.descendant(of: _key('plugins-chips'), matching: find.byType(Wrap)), findsNothing);
    expect(tester.widget(_key('plugins-chips')), isA<SingleChildScrollView>());
    final ys = {for (final k in ['all', 'added', 'safety', 'organise', 'messages']) tester.getTopLeft(_key('plugins-chip-$k')).dy};
    expect(ys, hasLength(1), reason: '"Messages" was left alone on a second row');
    await page(tester, size: const Size(1180, 860));
    expect(tester.widget(_key('plugins-chips')), isA<Wrap>());
  });

  testWidgets('Translate\'s page shows a translated text as it looks: the words as sent dimmed in the card, the translation in the bubble', (tester) async {
    registry = PluginRegistry([const TranslatePlugin(), ..._plugins]);
    await page(tester, open: 'translate');
    expect(_key('plugins-detail-translate'), findsOneWidget);
    expect(_key('plugins-detail-preview'), findsOneWidget);
    final preview = find.byType(TranslatePreview);
    expect(find.descendant(of: preview, matching: find.byType(OriginalCard)), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.text('¿Sigues viniendo a la cena del sábado?')), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.text('Are you still coming to dinner on Saturday?')), findsOneWidget);
    // Featured, its pitch is whole: written for three lines, not the tagline cut off.
    expect(const TranslatePlugin().pitch.length, lessThan(80));
  });

  testWidgets('a plugin\'s own section is its page from the Plugins page: Add or Remove under its colour, no second switch', (tester) async {
    registry = PluginRegistry([const TranslatePlugin(), ..._plugins]);
    final own = pluginPages(registry).firstWhere((s) => s.id == 'plugin-translate');
    expect(own.screen, isNotNull, reason: 'it was a plain list of rows with the switch on a card at its top');
    final sheet = await loadSheet(tester);
    final model = SettingsModel(state);
    addTearDown(model.dispose);
    await pumpScreen(tester, sheet, Builder(builder: (context) => own.screen!(context, model)), state);
    expect(find.byType(PluginScreen), findsOneWidget);
    expect(_key('plugins-detail-translate'), findsOneWidget);
    expect(_key('plugins-add-translate'), findsOneWidget);
    expect(find.byType(GlacierSwitch), findsNothing, reason: 'not added: its settings wait for it');
    await tester.tap(_key('plugins-add-translate'));
    await settle(tester);
    expect(state.flag(PluginRegistry.switchKey(const TranslatePlugin()), fallback: false), isTrue);
    expect(_key('plugins-remove-translate'), findsOneWidget);
    expect(_key('plugins-detail-settings'), findsOneWidget);
    // Its own settings, the plugin's switch not among them: "Translate texts as they come" and "Wi-Fi only".
    expect(find.text('Translate texts as they come'), findsOneWidget);
    expect(find.textContaining('Set to: Into'), findsOneWidget, reason: 'what its settings come to, named as such');
  });
}
