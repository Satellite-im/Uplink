import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/custom_theme.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/packs/resource_pack.dart';
import 'package:ghost_messaging/ui/look_picker.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsSectionScreen;
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// Settings › Appearance with packs under every look (Matt, 2026-11-27: "I think we should add texture packs to all
/// themes, but remove the phosphor entirely and remove the dark dial uptheme, also remove lamplight and mist and make
/// them texture packs for the Ghost theme"; and, of Runestone in flat stone on his phone, "I see the runestone theme
/// but I wanted it to use the duckscape look"): the four looks in the picker, and Textures under each
/// (lib/ui/resource_packs_ui.dart). What a look and a pack are is test/themes_test.dart's; how a resource pack is
/// fetched and kept is test/resource_pack_test.dart's. Nothing here is fetched from anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'prefs' ? <String, String>{} : null);
  });
  tearDown(() => ResourcePacks.instance = ResourcePacks());

  Finder row(String id) => find.byKey(ValueKey('pack-$id'));
  Future<void> press(WidgetTester tester, Finder what) async {
    await tester.ensureVisible(what);
    await tester.pump();
    await tester.tap(what);
    await settle(tester);
  }

  Future<AppState> appearance(WidgetTester tester, AppState app) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('appearance'), app, size: const Size(412, 4000));
    return app;
  }

  /// The words on [id]'s row.
  List<String> words(WidgetTester tester, String id) =>
      [for (final e in find.descendant(of: row(id), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];

  testWidgets('the picker offers the four looks, each drawn in its pack, and rings Uplink while a pack of Uplink\'s is in use', (tester) async {
    final app = await appearance(tester, AppState());
    final picker = find.byType(LookPicker);
    List<String> names() => [for (final e in find.descendant(of: picker, matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? '']
        .where((w) => w != 'Free?' && w != 'Yes!')
        .toList();
    // The tile ringed, by what it tells a screen reader.
    String ringed() => [
          for (final e in find.descendant(of: picker, matching: find.byType(GlacierPressable)).evaluate())
            if ((e.widget as GlacierPressable).semanticLabel case final String label when label.endsWith(', chosen')) label.substring(0, label.length - ', chosen'.length),
        ].join(' + ');
    expect(names(), ['Uplink', 'Sharp', 'Dial-Up', 'Runestone'], reason: 'no Mist, Lamplight or Phosphor among the looks');
    expect(ringed(), 'Uplink');
    // The look the tile named [label] is drawn in.
    Look tile(String label) {
      final pressable = find.ancestor(of: find.descendant(of: picker, matching: find.text(label)), matching: find.byType(GlacierPressable)).first;
      return tester.widget<LookPreview>(find.descendant(of: pressable, matching: find.byType(LookPreview))).look;
    }

    expect(tile('Uplink'), Look.ghost);

    // Lamplight, from Textures: Uplink is still the look ringed, and its tile is Lamplight's page.
    await press(tester, row('lamplight'));
    expect(app.look, Look.lamplight);
    expect(names(), ['Uplink', 'Sharp', 'Dial-Up', 'Runestone']);
    expect(ringed(), 'Uplink');
    expect(tile('Uplink'), Look.lamplight);

    // Sharp, then Uplink again from the picker: back in Lamplight, where it was left.
    await press(tester, find.descendant(of: picker, matching: find.text('Sharp')));
    expect(app.look, Look.sharp);
    expect(ringed(), 'Sharp');
    expect(tile('Uplink'), Look.lamplight, reason: 'the tile shows what pressing it gives');
    await press(tester, find.descendant(of: picker, matching: find.text('Uplink')));
    expect(app.look, Look.lamplight);
  });

  testWidgets('Textures under Uplink: its own, Mist and Lamplight, the one in use ticked', (tester) async {
    final app = await appearance(tester, AppState());
    expect(find.text('TEXTURES'), findsOneWidget);
    expect(words(tester, 'none').first, 'Uplink');
    expect(words(tester, 'mist').first, 'Mist');
    expect(words(tester, 'lamplight').first, 'Lamplight');
    expect(find.byKey(const ValueKey('pack-get')), findsNothing, reason: 'the hub is Runestone\'s');
    bool ticked(String id) => _ticked(row(id));
    expect([ticked('none'), ticked('mist'), ticked('lamplight')], [true, false, false]);

    await press(tester, row('mist'));
    expect([app.look, app.bubble], [Look.mist, 'theme']);
    expect([ticked('none'), ticked('mist'), ticked('lamplight')], [false, true, false]);
    expect(find.textContaining('Mist is always light'), findsOneWidget, reason: 'Theme says why it offers no choice');

    await press(tester, row('lamplight'));
    expect(app.look, Look.lamplight);
    expect(find.textContaining('Lamplight is always dark'), findsOneWidget);

    await press(tester, row('none'));
    expect([app.look, app.bubble], [Look.ghost, 'white']);
    expect([ticked('none'), ticked('mist'), ticked('lamplight')], [true, false, false]);
  });

  testWidgets('Textures under Sharp and Dial-Up: the look\'s own, and a line that no pack has been made yet', (tester) async {
    final app = await appearance(tester, AppState()..setLook(Look.sharp));
    expect(words(tester, 'none').first, 'Sharp');
    expect(find.text('Nobody has made a pack for Sharp yet.'), findsOneWidget);
    expect([row('mist'), row('lamplight'), find.byKey(const ValueKey('pack-get'))].map((f) => f.evaluate().length), [0, 0, 0]);

    app.setLook(Look.dialup);
    await settle(tester);
    expect(words(tester, 'none').first, 'Dial-Up');
    expect(find.text('Nobody has made a pack for Dial-Up yet.'), findsOneWidget);
    expect(find.textContaining('Dial-Up is always light'), findsOneWidget, reason: 'its dark half is gone');
  });

  testWidgets('Textures under Runestone: plain stone, the pack it comes with and how that stands, and the hub', (tester) async {
    final app = await appearance(tester, AppState()..setLook(Look.runestone));
    final packs = ResourcePacks.instance;
    expect(words(tester, 'none').first, 'Plain stone');
    expect(find.byKey(const ValueKey('pack-get')), findsOneWidget);
    // Not on this device yet: named, and a press fetches it.
    expect(words(tester, ResourcePacks.usual), ['Duckscape', 'The pack Runestone comes with', 'Get']);
    expect(find.textContaining('It comes with Duckscape'), findsOneWidget, reason: 'the section says what is fetched, and from where');

    // On its way.
    packs.fetching = ResourcePacks.usual;
    app.changed();
    await settle(tester);
    expect(words(tester, ResourcePacks.usual), ['Duckscape', 'Fetching it from the packs\' hub', 'Fetching']);

    // No connection.
    packs
      ..fetching = null
      ..failed = ResourcePacks.usual;
    app.changed();
    await settle(tester);
    expect(words(tester, ResourcePacks.usual), ['Duckscape', 'It couldn\'t be fetched. Check the connection and try again.', 'Try again']);

    // Plain stone pressed: kept as the choice, and the pack is offered again, not fetched.
    await press(tester, row('none'));
    expect(ResourcePacks.chosen(app), '');
    expect(app.choice(ResourcePacks.pref, 'never'), '');
    expect(words(tester, ResourcePacks.usual), ['Duckscape', 'The pack Runestone comes with', 'Get']);

    // A look of one's own has no Textures at all.
    CustomTheme.save(app, const CustomTheme(name: 'Dusk', dark: true, paper: Color(0xFF101418), surface: Color(0xFF1A2026), ink: Color(0xFFE8EEF2), accent: Color(0xFF4FC3F7)));
    await settle(tester);
    expect(find.text('TEXTURES'), findsNothing);
  });
}

/// Whether the row at [row] shows its tick: the check drawn as its value.
bool _ticked(Finder row) => find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.check)).evaluate().isNotEmpty;
