import 'dart:async';
import 'dart:convert' show jsonEncode, utf8;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/custom_theme.dart';
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/backgrounds.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/packs/resource_pack.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/kit/semantic_colors.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/plugins/plugin.dart' show DeviceLanguage, DeviceTranslation, TextHost;
import 'package:ghost_messaging/plugins/registry.dart' show PluginRegistry;
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/me/me.dart' show Me, MemoryMeStore;
import 'package:ghost_messaging/plugins/pack/pack.dart' show InstalledPlugins, PluginPack, parsePack;
import 'package:ghost_messaging/plugins/settings.dart' show marketPluginsScreen, pluginsScreen;
import 'package:ghost_messaging/ui/market/marketplace_screen.dart' show MarketplaceScreen;
import 'package:ghost_messaging/ui/market/review_item.dart' show ReviewItemScreen;
import 'package:ghost_messaging/ui/market/submit_screen.dart' show SubmitPluginScreen;
import 'package:ghost_messaging/plugins/shown_store.dart' show ShownStore;
import 'package:ghost_messaging/plugins/ui.dart' show SectionTabs;
import 'package:ghost_messaging/sms.dart' show Person, Sms;
import 'package:ghost_messaging/ui/circles/arrange_spaces.dart';
import 'package:ghost_messaging/ui/circles/circle_invite.dart';
import 'package:ghost_messaging/ui/circles/circle_list.dart';
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/circles/members_drawer.dart';
import 'package:ghost_messaging/ui/circles/circle_face.dart' show CircleFace;
import 'package:ghost_messaging/ui/circles/new_circle.dart';
import 'package:ghost_messaging/ui/compose.dart';
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:ghost_messaging/ui/dialup/dialup.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/jump_to_latest.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'account_shots.dart';
import 'circle_sample.dart';
import 'files_shots.dart';
import 'files_share_in_shots.dart';
import 'support/fake_friends.dart';
import 'support/market_fakes.dart';
import 'support/fake_video.dart';

/// The looks (lib/looks.dart; Matt, 2026-11-16: "spend some time making a few themes for ghost, base one of them
/// heavily on the old AOL chatrooms").
///
/// Every run checks that each look, in each brightness it has, gives every colour the app's Dart reads (a look's
/// rules that loop or leave a grey out make a colour come out empty, which would stop the app drawing at all), that
/// its ink reads on its paper and your bubble's words on your bubble, and that Uplink's own look is as it was.
///
/// It also builds a few screens in every look ([themeScreens]), failing on an exception. With THEME_SHOTS=1 in the
/// environment (or `flutter test --update-goldens test/themes_test.dart`) it keeps their pictures at
/// `build/themes/<look>-<brightness>-<screen>.png`, for looking at side by side. Those are never compared and never
/// kept in git (test/shots is for the app's own pictures). Add a screen to [themeScreens].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TokenSheet sheet;

  setUpAll(() async {
    sheet = await _loadSheet();
  });

  group('every look gives every colour the app reads', () {
    for (final look in Look.values) {
      for (final b in brightnessesOf(look)) {
        test('${look.name} $b', () {
          final t = Tokens.root(sheet, attrs: look.attrs(platform: 'mobile', theme: b));
          expect(t.attrs['theme'], b);
          for (final name in colourTokens) {
            expect(() => t.color(name), returnsNormally, reason: '--$name under ${look.name} $b');
          }
          // The page's words on the page, and your bubble's words on your bubble (WCAG AA, 4.5:1).
          expect(_contrast(t.color('app-ink'), t.color('app-paper')), greaterThanOrEqualTo(4.5), reason: 'ink on paper, ${look.name} $b');
          final (mine, onMine) = bubbleOf(t, 'theme');
          expect(_contrast(onMine, mine), greaterThanOrEqualTo(4.5), reason: 'words on your bubble, ${look.name} $b');
          expect(_contrast(t.color('app-on-bubble-mine'), t.color('app-bubble-mine')), greaterThanOrEqualTo(4.5));
          // The accent the look's own bubbles leave in place reads too.
          expect(_contrast(t.color('app-on-accent'), t.color('app-accent')), greaterThanOrEqualTo(4.5), reason: 'words on the accent, ${look.name} $b');
          // A look's brightness is the page's: Dart's isDark, the system bars and the bubble greys go by it.
          expect(t.isDark, b == 'dark');
        });
      }
    }
  });

  test('a look stamps its preset and its fixed brightness; Uplink stamps neither, and follows Theme', () {
    _answerChannel();
    final app = AppState();
    expect(ghostAttrs(app, 'mobile'), {'platform': 'mobile'}, reason: 'Uplink on System: exactly what the app stamped before looks');
    app.setTheme('dark');
    expect(ghostAttrs(app, 'desktop'), {'platform': 'desktop', 'theme': 'dark'});
    app.setLook(Look.mist);
    expect(ghostAttrs(app, 'mobile'), {'platform': 'mobile', 'theme': 'light', 'theme-preset': 'mist'}, reason: 'Mist is always light');
    app.setLook(Look.sharp);
    expect(ghostAttrs(app, 'mobile')['theme'], 'dark', reason: 'Sharp has both halves, so Theme says');
    app.setLook(Look.dialup);
    expect(ghostAttrs(app, 'mobile')['rounding'], 'square');
  });

  test('choosing a look makes your bubbles its own; Uplink again puts them back, unless a colour was chosen since', () {
    _answerChannel();
    final app = AppState();
    expect(app.bubble, 'white');
    app.setLook(Look.lamplight);
    expect(app.bubble, 'theme');
    expect(app.choice('theme_bubble', ''), 'orange', reason: 'the keyboard is told the nearest of its own colours');
    app.setLook(Look.ghost);
    expect(app.bubble, 'white');
    app.setLook(Look.sharp);
    app.setBubble('blue');
    app.setLook(Look.ghost);
    expect(app.bubble, 'blue', reason: 'a colour chosen after the look stays');
    for (final look in Look.values) {
      expect(bubbleColors.map((b) => b.id), contains(look.keyboard), reason: 'a colour Ghost Keyboard knows');
    }
  });

  // Matt, 2026-11-27: "I think we should add texture packs to all themes, but remove the phosphor entirely and remove
  // the dark dial uptheme, also remove lamplight and mist and make them texture packs for the Ghost theme".
  group('looks and their packs', () {
    test('four looks are offered; Mist and Lamplight are Uplink\'s packs, and Dial-Up is its light half alone', () {
      _answerChannel();
      expect(Look.offered, [Look.ghost, Look.sharp, Look.dialup, Look.runestone]);
      expect(Look.ghost.packs, [Look.mist, Look.lamplight]);
      expect([Look.mist.family, Look.lamplight.family], [Look.ghost, Look.ghost]);
      for (final look in Look.offered) {
        expect([look.isPack, look.family], [false, look], reason: look.name);
      }
      expect([Look.sharp.packs, Look.dialup.packs, Look.runestone.packs], [isEmpty, isEmpty, isEmpty]);
      expect([for (final l in Look.values) if (l.pictures) l], [Look.runestone], reason: 'a resource pack\'s pictures are Runestone\'s alone');
      // Dial-Up is drawn light whatever Theme says.
      expect(Look.dialup.forced, 'light');
      final app = AppState()
        ..setTheme('dark')
        ..setLook(Look.dialup);
      expect(ghostAttrs(app, 'mobile')['theme'], 'light');
      // Nothing of Phosphor's, or of Dial-Up's dark half, is left to stamp.
      final css = File('assets/css/app.css').readAsStringSync();
      expect(css, isNot(contains("data-theme-preset='phosphor'")));
      expect(css, isNot(contains("[data-theme-preset='dialup'][data-theme='dark']")));
      expect(Look.values.map((l) => l.name), isNot(contains('phosphor')));
      expect(Look.named('phosphor'), Look.ghost);
    });

    test('a pack is drawn as the look it was: its own preset, brightness and bubbles, under Uplink', () {
      _answerChannel();
      final app = AppState()..setTheme('dark');
      app.setLook(Look.mist);
      expect(ghostAttrs(app, 'mobile'), {'platform': 'mobile', 'theme': 'light', 'theme-preset': 'mist'});
      expect(app.bubble, 'theme', reason: 'your bubbles are the pack\'s teal');
      expect([app.look, app.look.family], [Look.mist, Look.ghost]);
      app.setLook(Look.lamplight);
      expect(ghostAttrs(app, 'mobile'), {'platform': 'mobile', 'theme': 'dark', 'theme-preset': 'lamplight'});
      expect(app.bubble, 'theme');
      // Uplink's own again: no preset, Theme's brightness, and the bubbles you had.
      app.setLook(Look.ghost);
      expect(ghostAttrs(app, 'mobile'), {'platform': 'mobile', 'theme': 'dark'});
      expect(app.bubble, 'white');
    });

    test('a look keeps the pack it was last in, and choosing its own lets the pack go', () {
      _answerChannel();
      final app = AppState()..setLook(Look.lamplight);
      expect(Look.last(app, Look.ghost), Look.lamplight);
      app.setLook(Look.sharp);
      expect(Look.last(app, Look.ghost), Look.lamplight, reason: 'Uplink is still in Lamplight after a while in Sharp');
      expect([Look.last(app, Look.sharp), Look.last(app, Look.dialup)], [Look.sharp, Look.dialup]);
      app.setLook(Look.last(app, Look.ghost));
      expect(app.look, Look.lamplight);
      app.setLook(Look.ghost);
      expect(Look.last(app, Look.ghost), Look.ghost, reason: 'Uplink\'s own, chosen');
      // Mist chosen as a look, before packs were noted: still Mist when Uplink is chosen again.
      final old = AppState()..set(Look.pref, 'mist');
      old.setLook(Look.runestone);
      expect(Look.last(old, Look.ghost), Look.mist);
    });

    test('Phosphor, taken out, is Uplink as if Uplink had been chosen', () async {
      Future<AppState> opened(Map<String, String> kept) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'prefs' ? kept : null);
        final app = AppState();
        await app.load();
        return app;
      }

      // Your bubbles were the look's green: the colour they had before it comes back.
      var app = await opened({'look': 'phosphor', 'bubble': 'theme', 'bubble_before_look': 'pink', 'theme_bubble': 'green'});
      expect([app.look, app.choice(Look.pref, ''), app.bubble, app.choice('theme_bubble', '')], [Look.ghost, 'ghost', 'pink', 'white']);
      // None noted: white, as Uplink starts.
      app = await opened({'look': 'phosphor', 'bubble': 'theme'});
      expect([app.look, app.bubble], [Look.ghost, 'white']);
      // A colour chosen under it stays.
      app = await opened({'look': 'phosphor', 'bubble': 'blue'});
      expect([app.look, app.bubble], [Look.ghost, 'blue']);
      // A look of one's own over it keeps its bubbles: they wear its accent.
      const dusk = CustomTheme(name: 'Dusk', dark: true, paper: Color(0xFF101418), surface: Color(0xFF1A2026), ink: Color(0xFFE8EEF2), accent: Color(0xFF4FC3F7));
      app = await opened({'look': 'phosphor', 'bubble': 'theme', CustomTheme.usedPref: dusk.code});
      expect([app.look, app.bubble, CustomTheme.used(app)?.name], [Look.ghost, 'theme', 'Dusk']);
      // Any other look is left exactly as it was kept, a pack among them.
      app = await opened({'look': 'lamplight', 'bubble': 'theme'});
      expect([app.look, app.bubble], [Look.lamplight, 'theme']);
      // And Dial-Up kept in its dark half is Dial-Up, light.
      app = await opened({'look': 'dialup', 'theme': 'dark', 'bubble': 'theme'});
      expect([app.look, ghostAttrs(app, 'mobile')['theme']], [Look.dialup, 'light']);
    });
  });

  test('a look\'s own bubbles leave its accent alone; a colour chosen still wins over it', () {
    expect(accentPair('theme').light, isNull);
    expect(accentPair('theme').dark, isNull);
    expect(accentCss('theme'), isNull);
    // Chosen on Mist's page, blue is the accent; white would not be seen on it, so it is not.
    final mist = Tokens.root(sheet, attrs: Look.mist.attrs(platform: 'mobile'));
    final page = mist.color('app-paper');
    expect(accentPair('blue', lightPage: page).light, isNotNull);
    expect(accentPair('white', lightPage: page).light, isNull);
  });

  test('Uplink is drawn as it was: the colours that were hex in the Dart, the scrims, and the accent check', () {
    for (final b in ['light', 'dark']) {
      final t = Tokens.root(sheet, attrs: Look.ghost.attrs(platform: 'mobile', theme: b));
      int argb(Color c) => c.toARGB32();
      expect(argb(t.danger), argb(t.colorOf('#dd3a30')));
      expect(argb(t.unread), argb(t.colorOf('#4f5bd5')));
      expect(argb(t.chosen), argb(t.colorOf('#4f5bd5')));
      expect(argb(t.info), argb(t.colorOf('#4f5bd5')));
      expect(argb(t.online), argb(t.colorOf('#2fb35a')));
      expect(argb(t.warn), argb(t.colorOf('#c27c00')));
      expect(argb(t.pinned), argb(t.colorOf('#d38b00')));
      expect(argb(t.chosenWash), argb(t.colorOf('color-mix(in srgb, #4f5bd5 22%, transparent)')));
      expect(argb(t.textSelection), argb(t.colorOf('color-mix(in srgb, #4f5bd5 30%, transparent)')));
      expect(argb(t.failedGround), argb(t.colorOf('color-mix(in srgb, #dd3a30 18%, var(--app-paper-2))')));
      expect(argb(t.sheetScrim), 0x66000000);
      expect(argb(t.menuScrim), 0x73000000);
      expect(t.raw('app-bubble-theirs'), isNull, reason: 'their bubbles are the paper\'s, as before');
      expect(t.raw('app-bubble-rim'), isNull);
    }
    // The accent's check against Uplink's own papers, read from its rules, decides as the fixed near white and near
    // black did, for every colour.
    final light = Tokens.root(sheet, attrs: const {'platform': 'mobile', 'theme': 'light'}).color('app-paper');
    final dark = Tokens.root(sheet, attrs: const {'platform': 'mobile', 'theme': 'dark'}).color('app-paper');
    for (final b in bubbleColors) {
      expect(accentCss(b.id, lightPage: light, darkPage: dark), accentCss(b.id), reason: b.id);
    }
  });

  group('Dial-Up', () {
    for (final b in brightnessesOf(Look.dialup)) {
      test('$b: its chrome, its names and its title bar read', () {
        final t = Tokens.root(sheet, attrs: Look.dialup.attrs(platform: 'mobile', theme: b));
        for (final name in dialupTokens) {
          expect(() => t.color(name), returnsNormally, reason: '--$name under Dial-Up $b');
        }
        expect(isBevelChrome(t), isTrue);
        double on(String a, String b) => _contrast(t.color(a), t.color(b));
        final paper = t.color('app-paper');
        // Names on the transcript's white (or black) page, yours, theirs and each of a room's six.
        for (final n in ['app-name-mine', 'app-name-theirs', for (var i = 1; i <= 6; i++) 'app-name-$i']) {
          expect(_contrast(t.color(n), paper), greaterThanOrEqualTo(4.5), reason: '$n on the page, $b');
        }
        expect(on('app-titlebar-ink', 'app-titlebar'), greaterThanOrEqualTo(4.5), reason: 'the title on its band');
        expect(on('app-on-chrome', 'app-chrome'), greaterThanOrEqualTo(4.5), reason: 'a button\'s words on silver');
        expect(on('app-ink-3', 'app-chrome'), greaterThanOrEqualTo(4.5), reason: 'secondary words (Host lines) on silver');
        expect(on('app-ink-3', 'app-paper'), greaterThanOrEqualTo(4.5), reason: 'secondary words on the page');
        expect(on('app-on-tooltip', 'app-tooltip'), greaterThanOrEqualTo(4.5), reason: 'a hover tip');
        expect(on('app-on-highlight', 'app-highlight'), greaterThanOrEqualTo(4.5), reason: 'a chosen row');
        expect(_contrast(t.danger, paper), greaterThanOrEqualTo(4.5), reason: 'a failure\'s words');
        expect(_contrast(t.unread, paper), greaterThanOrEqualTo(4.5), reason: 'an unread count');
        // Square everything, a pill too; nothing moves; no tracking; and the face is Arimo, with the emoji set behind.
        expect(t.radius('md'), 0);
        expect(t.len('glacier-radius-full'), 0);
        expect(t.duration('glacier-duration-normal').inMilliseconds, 0);
        expect(t.attrs['font'], 'arimo');
        expect(t.families('glacier-font-sans').first, 'Arimo');
        expect(DialupColors.of(t).nameFor('+15551230001'), DialupColors.of(t).nameFor('+1 (555) 123-0001'), reason: 'one colour per person');
      });
    }

    test('no other look is drawn as a chat room, but Runestone, which draws its stone with the same chrome', () {
      expect(isBevelChrome(Tokens.root(sheet, attrs: Look.runestone.attrs(platform: 'mobile', theme: 'dark'))), isTrue);
      for (final look in Look.values.where((l) => l != Look.dialup && l != Look.runestone)) {
        for (final b in brightnessesOf(look)) {
          expect(isBevelChrome(Tokens.root(sheet, attrs: look.attrs(platform: 'mobile', theme: b))), isFalse, reason: '${look.name} $b');
        }
      }
      expect(isBevelChrome(Tokens.root(sheet, attrs: const {'platform': 'mobile'})), isFalse);
    });

    // Runestone (Matt, 2026-11-27: "make a theme in Ghost that fits this with the runescape font and everything", then
    // "use the light background for chats like dark vanilla uses"): the same chrome in dark stone, its own letters, and
    // a chat written on parchment in inks that read there.
    test('Runestone: its stone, its lettering and its parchment read', () {
      final t = Tokens.root(sheet, attrs: Look.runestone.attrs(platform: 'mobile', theme: 'light'));
      expect(t.isDark, isTrue, reason: 'dark whatever Theme says');
      for (final name in dialupTokens) {
        expect(() => t.color(name), returnsNormally, reason: '--$name under Runestone');
      }
      double on(String a, String b) => _contrast(t.color(a), t.color(b));
      expect(on('app-titlebar-ink', 'app-titlebar'), greaterThanOrEqualTo(4.5), reason: 'a heading on its band');
      expect(on('app-on-chrome', 'app-chrome'), greaterThanOrEqualTo(4.5), reason: 'a button\'s words on stone');
      expect(on('app-ink-2', 'app-paper'), greaterThanOrEqualTo(4.5), reason: 'secondary words on a panel');
      expect(on('app-ink-3', 'app-paper'), greaterThanOrEqualTo(4.5), reason: 'a row\'s second line on a panel');
      expect(on('app-ink-3', 'app-chrome'), greaterThanOrEqualTo(4.5), reason: 'small words on stone');
      expect(_contrast(t.danger, t.color('app-paper')), greaterThanOrEqualTo(4.5), reason: 'a failure on a panel');
      expect(_contrast(t.danger, t.color('app-chrome')), greaterThanOrEqualTo(4.5), reason: 'a failure on stone');
      expect(on('app-on-tooltip', 'app-tooltip'), greaterThanOrEqualTo(4.5));
      expect(on('app-on-highlight', 'app-highlight'), greaterThanOrEqualTo(4.5), reason: 'a chosen row');
      // Its face, a regular and a bold and nothing between, each word over the game's hard shadow.
      expect(t.attrs['font'], 'runestone');
      expect(t.families('glacier-font-sans').first, 'Runestone');
      expect(t.weight('medium'), FontWeight.w400);
      expect(t.weight('semibold'), FontWeight.w700);
      final words = t.textAt(16, color: t.color('app-ink'));
      expect(words.shadows, [const Shadow(color: Color(0xFF000000), offset: Offset(1, 1))], reason: 'light words stand on the shadow');
      expect(t.textAt(16, color: const Color(0xFF000000)).shadows, isNull, reason: 'dark words are not smudged by it');
      // Square, and nothing moves, as Dial-Up.
      expect(t.radius('md'), 0);
      expect(t.duration('glacier-duration-normal').inMilliseconds, 0);
      // The chat and every field: parchment, dark inks, no shadow; everyone's name black, six dark inks for a room.
      for (final scope in ['parchment', 'dialup-well']) {
        final p = t.child(classes: {scope});
        final paper = p.color('app-paper');
        expect(paper.computeLuminance(), greaterThan(0.4), reason: '$scope is light');
        expect(p.raw('app-well')?.trim(), 'parchment');
        expect(p.textShadows, isNull, reason: 'no shadow on $scope');
        final c = DialupColors.of(p);
        for (final ink in [c.ink, c.inkSoft, c.nameMine, c.nameTheirs, ...c.names, c.wordsMine, c.wordsTheirs, p.danger, p.color('app-ink-2')]) {
          expect(_contrast(ink, paper), greaterThanOrEqualTo(4.5), reason: '$ink on $scope');
        }
        expect(c.wordsMine, isNot(c.wordsTheirs), reason: 'what you say and what is said to you are two inks');
        // The stone a button on the parchment is drawn in is still the page's.
        expect(c.chrome, DialupColors.of(t).chrome);
      }
      // Dial-Up says nothing of either colour: its words are the page's ink on both sides, as they were.
      final dial = DialupColors.of(Tokens.root(sheet, attrs: Look.dialup.attrs(platform: 'mobile', theme: 'light')));
      expect(dial.wordsMine, dial.ink);
      expect(dial.wordsTheirs, dial.ink);
      expect(dial.close, dial.onChrome);
    });

    testWidgets('its pieces draw', (tester) async {
      _answerChannel();
      final shots = Platform.environment['THEME_SHOTS'] == '1' || autoUpdateGoldenFiles;
      await tester.runAsync(_fonts);
      final sheet = (await tester.runAsync(_loadSheet))!;
      for (final b in brightnessesOf(Look.dialup)) {
        await shootLook(tester, sheet, Look.dialup, b, ThemeScreen('chrome', () => const _DialupPieces()), write: shots);
        expect(find.bySemanticsLabel('Back'), findsWidgets);
      }
    });

    // The window's chrome on a small phone (360 wide, as the design asks it be checked at): the Chat List and its
    // taskbar, a conversation's title bar and composer, a page with a way back. An overflow is an exception, which
    // fails here. Then words in the composer, where Send comes with its word on it.
    testWidgets('its chrome holds at 360 wide', (tester) async {
      _answerChannel();
      final shots = Platform.environment['THEME_SHOTS'] == '1' || autoUpdateGoldenFiles;
      await tester.runAsync(_fonts);
      Inbox.instance = Inbox.of([_telegram()]);
      addTearDown(() => Inbox.instance = null);
      final sheet = (await tester.runAsync(_loadSheet))!;
      const small = Size(360, 740);
      Widget maya() => const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]);
      for (final b in brightnessesOf(Look.dialup)) {
        for (final screen in [
          ThemeScreen('conversations-360', () => const AppShell(), size: small),
          ThemeScreen('thread-360', maya, size: small),
          ThemeScreen('compose-360', () => const ComposeScreen(), size: small),
          ThemeScreen('settings-360', () => const SettingsSectionScreen('appearance'), size: small),
        ]) {
          await shootLook(tester, sheet, Look.dialup, b, screen, write: shots);
        }
        expect(find.bySemanticsLabel('Back'), findsWidgets);
        await shootLook(tester, sheet, Look.dialup, b, ThemeScreen('typing-360', maya, size: small), write: false);
        await tester.enterText(find.byType(EditableText).first, 'on my way, ten minutes');
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(tester.takeException(), isNull);
        expect(find.text('Send'), findsOneWidget);
        if (shots) await _capture(tester, 'dialup-$b-typing-360');
      }
    });
  });

  // The video player (lib/ui/video_screen.dart; Matt, 2026-11-18: "add support for playing mkv video files and mp4's
  // within the app in a player themed by glacier UI"): playing with its controls up, paused, and a file that can't be
  // played, on a computer's window and (paused) a phone, in Uplink light and dark and Dial-Up's Daytime.
  testWidgets('the video player in Uplink and Dial-Up', (tester) async {
    _answerChannel();
    final shots = Platform.environment['THEME_SHOTS'] == '1' || autoUpdateGoldenFiles;
    await tester.runAsync(_fonts);
    final sheet = (await tester.runAsync(_loadSheet))!;
    addTearDown(() => VideoEngine.make = VideoEngine.defaultEngine);
    const desk = Size(1100, 700);
    for (final (look, b) in [(Look.ghost, 'light'), (Look.ghost, 'dark'), (Look.dialup, 'light')]) {
      for (final (name, engine, size, onDesk) in [
        ('video-playing', () => FakeVideoEngine(), desk, true),
        ('video-paused', () => FakeVideoEngine(still: true, at: const Duration(minutes: 1, seconds: 7)), desk, true),
        ('video-paused-phone', () => FakeVideoEngine(still: true, at: const Duration(minutes: 1, seconds: 7)), ThemeScreen.phone, false),
        ('video-error', () => FakeVideoEngine(fails: true), desk, true),
        // Streamed (Matt, 2026-11-18: "would it be possible to setup streaming and buffering of the file?"): what is
        // ready ahead shown on the scrubber, and the small spinner while it waits for more.
        ('video-buffering', () => FakeVideoEngine(still: true, at: const Duration(minutes: 1, seconds: 7), buffered: const Duration(minutes: 1, seconds: 50), buffering: true), desk, true),
      ]) {
        VideoEngine.make = engine;
        await shootLook(tester, sheet, look, b, ThemeScreen(name, () => VideoScreen(path: '/tmp/holiday.mkv', title: 'Maya Chen', desk: onDesk), size: size), write: shots);
        expect(find.bySemanticsLabel('Back'), findsWidgets, reason: '${look.name} $b $name');
      }
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  group('screens in every look', () {
    final shots = Platform.environment['THEME_SHOTS'] == '1' || autoUpdateGoldenFiles;
    setUpAll(_fonts);
    tearDown(() {
      Inbox.instance = null;
      Voice.instance.own = [];
      Voice.instance.clearHangouts();
    });
    for (final look in Look.values) {
      testWidgets(look.name, (tester) async {
        _answerChannel();
        // Telegram signed in and the space kept, for every screen alike: the list shows the same rows in every look.
        Inbox.instance = Inbox.of([_telegram()]);
        Voice.instance.own = [_space().channel];
        Voice.instance.putHangout(_space());
        var sheet = (await tester.runAsync(_loadSheet))!;
        // THEME_PACK=<a resource pack's archive on this disk> draws Runestone with that pack's pictures and colours, as
        // the app does once the person has fetched one (lib/packs/). Nothing is fetched here; without it Runestone is
        // drawn as it is with no pack, in flat stone.
        final pack = Platform.environment['THEME_PACK'];
        if (look == Look.runestone && pack != null) {
          await tester.runAsync(() => ResourcePacks.instance.debugUse(PackEntry(id: 'pack-shown', name: 'Shown', author: '', commit: '0' * 40), File(pack).readAsBytesSync()));
          addTearDown(() => ResourcePacks.instance.current = null);
          sheet = TokenSheet.kept([...sheet.rules, ...TokenSheet.parse(ResourcePacks.instance.current!.css).rules]);
        }
        for (final b in brightnessesOf(look)) {
          for (final screen in themeScreens) {
            // THEME_SCREENS=plugins,plugin-detail draws those alone, for working on one screen.
            final only = Platform.environment['THEME_SCREENS']?.split(',');
            if (only != null && !only.contains(screen.name)) continue;
            await shootLook(tester, sheet, look, b, screen, write: shots);
          }
        }
      });
    }

    // Matt, 2026-11-17: "unify the compose layout between sms / rcs chats, telegram and signal chats as well as spaces
    // chats, they should all have the same layout so there is no shift when switching between them ... if it's not
    // avilable on a given chat just disable the button but still show it".
    testWidgets('the composer and its buttons are in the same place in a text, a Telegram chat and a space', (tester) async {
      _answerChannel();
      Inbox.instance = Inbox.of([_telegram()]);
      Voice.instance.own = [_space().channel];
      Voice.instance.putHangout(_space());
      final sheet = (await tester.runAsync(_loadSheet))!;
      final at = <String, Map<String, Rect>>{};
      for (final name in ['thread', 'inbox', 'space']) {
        await shootLook(tester, sheet, Look.ghost, 'light', themeScreens.firstWhere((s) => s.name == name), write: false);
        at[name] = {
          'box': tester.getRect(find.byType(ComposerBox)),
          for (final key in ['composer-plus', 'composer-stickers', 'composer-mic']) key: tester.getRect(find.byKey(ValueKey(key))),
        };
      }
      // To within a ten-billionth of a point: the pages above sum their heights in different orders, and with the
      // composer's foot at the dock's room (18 points, 2026-11-17) the sums came out 1e-13 apart.
      for (final part in at['thread']!.keys) {
        expect(at['inbox']![part], rectMoreOrLessEquals(at['thread']![part]!), reason: '$part: Telegram as a text');
        expect(at['space']![part], rectMoreOrLessEquals(at['thread']![part]!), reason: '$part: a space as a text');
      }
    });
  });
}

/// The brightnesses [look] has.
List<String> brightnessesOf(Look look) => [if (look.light) 'light', if (look.dark) 'dark'];

/// Every colour token the app's Dart reads by name (and the kit's components, the few that matter most), which every
/// look must give.
const colourTokens = [
  'app-ink', 'app-ink-2', 'app-ink-3', 'app-ink-4', //
  'app-paper', 'app-paper-2', 'app-paper-3', 'app-rule', //
  'glacier-bg', 'app-accent', 'app-on-accent', 'app-bubble-mine', 'app-on-bubble-mine', //
  'glacier-surface', 'glacier-text', 'glacier-border-subtle', 'glacier-text-muted', 'glacier-text-subtle', //
  'glacier-segment-track', 'glacier-segment-thumb', 'glacier-selection', 'glacier-overlay', //
  'app-danger', 'app-unread', 'app-chosen', 'app-info', 'app-online', 'app-warn', 'app-pinned', //
  'app-text-selection', 'app-sheet-scrim', 'app-menu-scrim',
];

/// The colours Dial-Up's own pieces read (lib/ui/dialup/), which its rules must give in both halves.
const dialupTokens = [
  'app-chrome', 'app-on-chrome', 'app-bevel-hi', 'app-bevel-lo', 'app-bevel-shadow', 'app-bevel-dark', //
  'app-titlebar', 'app-titlebar-end', 'app-titlebar-ink', 'app-titlebar-inactive', 'app-titlebar-inactive-ink', //
  'app-name-mine', 'app-name-theirs', 'app-name-1', 'app-name-2', 'app-name-3', 'app-name-4', 'app-name-5', 'app-name-6', //
  'app-desktop', 'app-tooltip', 'app-on-tooltip', 'app-highlight', 'app-on-highlight',
];

/// Dial-Up's pieces on one page, for looking at: a window with its title bar, a well, and buttons up, held and off.
class _DialupPieces extends StatelessWidget {
  const _DialupPieces();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final text = t.textAt(16, color: c.ink);
    // Bold through the face's weight axis: Arimo is variable, and textAt's `wght` would outvote a fontWeight.
    final bold = t.textAt(16, weight: 'bold');
    return ColoredBox(
      color: c.desktop,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 60, 12, 40),
        child: Bevel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TitleBar(title: 'Maya Chen', subtitle: 'Telegram · People Here: 4', onClose: () {}),
              const SizedBox(height: 6),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Sunken(
                    padding: const EdgeInsets.all(8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text.rich(TextSpan(children: [TextSpan(text: 'Host: ', style: text.copyWith(color: c.inkSoft, fontStyle: FontStyle.italic)), TextSpan(text: '*** You are in "Lobby".', style: text.copyWith(color: c.inkSoft, fontStyle: FontStyle.italic))])),
                      const SizedBox(height: 4),
                      Text.rich(TextSpan(children: [TextSpan(text: 'Maya Chen: ', style: bold.copyWith(color: c.nameTheirs)), TextSpan(text: 'are you coming tonight?', style: text)])),
                      const SizedBox(height: 4),
                      Text.rich(TextSpan(children: [TextSpan(text: 'You: ', style: bold.copyWith(color: c.nameMine)), TextSpan(text: 'on my way, ten minutes', style: text)])),
                      const SizedBox(height: 4),
                      for (var i = 0; i < 6; i++) Text.rich(TextSpan(children: [TextSpan(text: 'Person ${i + 1}: ', style: bold.copyWith(color: c.names[i])), TextSpan(text: 'hello', style: text)])),
                      const SizedBox(height: 8),
                      Container(color: c.highlight, padding: const EdgeInsets.all(4), child: Text('A chosen row', style: text.copyWith(color: c.onHighlight))),
                      const SizedBox(height: 8),
                      Container(color: c.tooltip, padding: const EdgeInsets.all(4), child: Text('A hover tip', style: text.copyWith(color: c.onTooltip, fontSize: 14))),
                    ]),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Row(children: [
                  RetroButton(onPressed: () {}, label: '+', semanticLabel: 'More'),
                  const SizedBox(width: 6),
                  const Expanded(child: SizedBox(height: 40, child: Sunken(padding: EdgeInsets.symmetric(horizontal: 8)))),
                  const SizedBox(width: 6),
                  RetroButton(onPressed: () {}, label: 'Send', primary: true),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: Row(children: [
                  RetroButton(onPressed: () {}, label: 'Held', toggled: true),
                  const SizedBox(width: 6),
                  const RetroButton(onPressed: null, label: 'Off'),
                  const SizedBox(width: 6),
                  TitleBarButton(glyph: TitleGlyph.help, label: 'Details', onPressed: () {}),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A screen drawn in every look by [shootLook]: its [name] in the file's name, how to make it, the window it is drawn
/// in, and anything to put in place before (a network signed in, a space's chat).
class ThemeScreen {
  const ThemeScreen(this.name, this.build, {this.size = phone, this.before, this.ready, this.choices, this.after});
  final String name;
  final Widget Function() build;
  final Size size;
  final void Function()? before;

  /// Made ready inside the look's own test, after [before], with the tester for work on the real event loop: a
  /// plugin's package checked by the Marketplace, a pack loaded on the device.
  final Future<void> Function(WidgetTester tester)? ready;

  /// The person's choices for this screen alone, made on the [AppState] it is drawn with (a plugin switched on).
  final void Function(AppState state)? choices;

  /// Put back after it is drawn (what [before] changed that would outlive the test: a timer); waited for, so the next
  /// screen starts from nothing (the circles' invites leaked into the next picture while their clear was not awaited).
  final FutureOr<void> Function()? after;

  static const phone = Size(412, 892), wide = Size(750, 832);
}

/// The screens every look is drawn on. Add one here and it is drawn in every look and brightness.
final themeScreens = <ThemeScreen>[
  ThemeScreen('conversations', () => const AppShell()),
  ThemeScreen('thread', () => const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')])),
  ThemeScreen('group', () => ThreadScreen(thread: 2, people: [for (final p in _conversations[1]['people'] as List) Person.from(p as Map)])),
  ThemeScreen('inbox', () => InboxChatScreen(network: _telegram(), chatId: '10')),
  ThemeScreen('settings-appearance', () => const SettingsSectionScreen('appearance')),
  ThemeScreen('space', () => HangoutScreen(channel: _space().channel)),
  ThemeScreen('frame-wide', () => const AppShell(), size: ThemeScreen.wide),
  // A group on a wide screen, and a space where people are coming and going (Dial-Up's Host lines and People Here).
  // The list and a conversation on a small phone (360 wide) in every look, not only Dial-Up's chrome check above.
  ThemeScreen('conversations-narrow', () => const AppShell(), size: const Size(360, 780)),
  ThemeScreen('thread-narrow', () => const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), size: const Size(360, 780)),
  ThemeScreen('group-narrow', () => ThreadScreen(thread: 2, people: [for (final p in _conversations[1]['people'] as List) Person.from(p as Map)]), size: const Size(360, 780)),
  ThemeScreen('group-wide', () => ThreadScreen(thread: 2, people: [for (final p in _conversations[1]['people'] as List) Person.from(p as Map)]), size: ThemeScreen.wide),
  ThemeScreen('space-room', () => HangoutScreen(channel: _busySpace('phone').channel), before: () => Voice.instance.putHangout(_busySpace('phone'))),
  // A texting space with a description: its mark, name and description in the header, at a conversation's height
  // (Matt, 2026-11-17: "make the text header for spaces show the icon and the name and an area for a description").
  ThemeScreen('space-text-about', () => HangoutScreen(channel: _aboutSpace().channel), before: () => Voice.instance.putHangout(_aboutSpace())),
  ThemeScreen('space-room-wide', () => HangoutScreen(channel: _busySpace('wide').channel), size: ThemeScreen.wide, before: () => Voice.instance.putHangout(_busySpace('wide'))),
  // The Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page with a
  // marketplace like look how ghostmd has"): Settings' list with its band leading there, the page on a phone, a
  // plugin's page over it, and on a computer's window with a plugin's page beside the shelves.
  ThemeScreen('settings', () => const SettingsScreen(), size: const Size(412, 2100)),
  // The Marketplace since 2026-11-20 (Matt: "Move plugins out of settings into a marketplace button on the navigation
  // rail with a marketplace icon"): its list on a phone, with the band, and its Discover.
  ThemeScreen('marketplace', () => const MarketplaceScreen()),
  ThemeScreen('plugins', () => marketPluginsScreen()),
  // A plugin in development's page and a listing's: whether it was reviewed is said in every look, Dial-Up's lines and
  // bevelled label among them, so an unreviewed pack's page never looks like a reviewed one's.
  ThemeScreen('plugin-detail-dev', () => marketPluginsScreen(open: 'xbills'), ready: _devPack, after: _packsGone),
  ThemeScreen('plugin-detail-listing', () => marketPluginsScreen(open: 'xbills'), ready: _listing, after: _packsGone),
  // Submit a plugin, a plugin loaded (Matt, 2026-11-20: "Add a submission area with a form to accept an icon,
  // description, plugin tags, etc"), and a submission as the reviewer reads it ("I'd like to be able to verify them for
  // the store through a review process"), each against a Marketplace in memory.
  ThemeScreen('plugin-submit', () => SubmitPluginScreen(api: _marketApi(), market: _submitMarket, start: _submitPack()), before: _submitting, after: _submitted),
  ThemeScreen('market-review-item', () => ReviewItemScreen(_reviewSid ?? '', api: _marketApi()), before: _reviewing, after: _submitted),
  // Translate's page, as it is before it is added (its picture of a translated text, Add) and once it is (its
  // settings, beside the shelves on a computer); and the Spam filter's, a plugin with a shelf tag and a summary.
  ThemeScreen('plugin-detail', () => pluginsScreen(null, 'translate'), before: _translating, after: _translated),
  ThemeScreen('plugin-detail-spam', () => pluginsScreen(null, 'spam')),
  ThemeScreen('plugins-desktop', () => pluginsScreen(null, 'translate'), size: const Size(1180, 860), choices: _translateOn, before: _translating, after: _translated),
  // Translate (Matt, 2026-11-17: "add a translate plugin which can automatically translate texts when detected from
  // another language and show the original text dimmed in a card with the translated text for the actual message
  // bubble"): a conversation with Spanish texts translated, one swapped back, and one whose language is being got
  // ready; a Telegram chat in French; and the plugin's own page.
  ThemeScreen('translated', () => const ThreadScreen(thread: 8, people: [Person(address: '+15551230009', name: 'Lucía Ortega')]), choices: _translateOn, before: _translating, after: _translated),
  ThemeScreen('translated-inbox', () => InboxChatScreen(network: _telegram(), chatId: '11', fallback: _camille), choices: _translateOn, before: _translating, after: _translated),
  ThemeScreen('translate-settings', () => const SettingsSectionScreen('plugin-translate'), choices: _translateOn, before: _translating, after: _translated),
  // The down arrow back to the newest message (Matt, 2026-11-17: "add a down arrow that pops up when we enter a chat and
  // we're not scrolled to the bottom or after we scroll up a certain amount, remember the scroll position when switching
  // between chats"): a long conversation opened where it was left, two screens up, with two texts come since.
  ThemeScreen('thread-scrolled', () => const ThreadScreen(thread: 12, people: [Person(address: '+15551230012', name: 'Priya Natarajan')]), before: () => _leftUp(12), after: ScrollMemory.clear),
  // The same on a small phone and a wide window, where the pane's edge and the quick replies could crowd it; and the
  // arrow over a Telegram chat and over a space's chat. Each its own chat: the screen drawn before is let go only as the
  // next is drawn, and keeps its own spot as it goes.
  ThemeScreen('thread-scrolled-360', () => const ThreadScreen(thread: 13, people: [Person(address: '+15551230012', name: 'Priya Natarajan')]), size: const Size(360, 780), before: () => _leftUp(13), after: ScrollMemory.clear),
  ThemeScreen('thread-scrolled-wide', () => const ThreadScreen(thread: 14, people: [Person(address: '+15551230012', name: 'Priya Natarajan')]), size: ThemeScreen.wide, before: () => _leftUp(14), after: ScrollMemory.clear),
  ThemeScreen('inbox-scrolled', () => InboxChatScreen(network: _telegram(), chatId: '12', fallback: _priyaTg), before: () => ScrollMemory.keep('inbox:telegram:12', 1400, seen: '37'), after: ScrollMemory.clear),
  ThemeScreen('space-scrolled', () => HangoutScreen(channel: _longSpace().channel), before: () {
    Voice.instance.putHangout(_longSpace());
    ScrollMemory.keep('space:${_longSpace().channel.room}', 1400, seen: '37');
  }, after: ScrollMemory.clear),
  // Circles (Matt, 2026-11-17: "make a new design for [circles] ... with it's own sidebar full of spaces"): a circle's
  // list of spaces on a phone and as the sidebar of a wide window, the Circles tab, and making one.
  ThemeScreen('circle', () => CircleScreen(seed: _circle.seed), before: _joinCircle, after: _leaveCircle),
  ThemeScreen('circle-wide', () => const AppShell(), size: ThemeScreen.wide, before: _joinCircle, after: _leaveCircle, choices: (_) => _openCircleSoon()),
  // The other pages that take the list's place in a wide window, Settings and Archived: under Dial-Up each sits in
  // the same white well as the Chat List (Matt, 2026-11-18: "the sidebar in circles on the dial up theme is missing
  // the border bevel").
  ThemeScreen('settings-side-wide', () => const AppShell(), size: ThemeScreen.wide, choices: (_) => _goSoon('settings')),
  ThemeScreen('archived-wide', () => const AppShell(), size: ThemeScreen.wide, choices: (_) => _goSoon('archive')),
  ThemeScreen('new-circle', () => const NewCircleScreen()),
  // The Circles tab, where the Spaces tab was: each circle and nothing else (Matt, 2026-11-17: "it should only be
  // circles"); on a phone and a wide window.
  ThemeScreen('circles-tab', () => const AppShell(), before: _joinBothCircles, after: _leaveOwnCircle, choices: (_) => _tapCirclesTabSoon()),
  ThemeScreen('circles-tab-wide', () => const AppShell(), size: ThemeScreen.wide, before: _joinBothCircles, after: _leaveOwnCircle, choices: (_) => _tapCirclesTabSoon()),
  // A Files space (test/files_shots.dart): its list, grid, a wide window, files going up, an empty one, a picture opened.
  ...filesThemeScreens,
  // Files brought in from outside a Files space (test/files_share_in_shots.dart): the "Add … to" sheet, and the hint
  // over a Mac's window while files are dragged onto it.
  ...shareInThemeScreens,
  // A circle's list, the one way a circle is drawn (Matt, 2026-11-17: "Lets remove the other views and focus on the list
  // view / layout it's the most practical of them all so far"), with something going on: people talking, new messages,
  // files counted; on a phone and as a wide window's sidebar with a space open beside it.
  ThemeScreen('circle-list', () => CircleList(view: sampleCircleView())),
  ThemeScreen('circle-list-wide', () => CircleList(view: sampleCircleView(wide: true, selected: sampleCircle.spaces.first.seed)), size: const Size(380, 860)),
  // A circle of one's own: a new space's three kinds as cards (phone and wide), its settings (people and their roles,
  // the QR code), arranging its spaces, and the invite sheet.
  ThemeScreen('circle-space-new', () => NewCircleSpaceScreen(circle: _ownCircle), before: _joinOwnCircle, after: _leaveOwnCircle),
  ThemeScreen('circle-space-new-wide', () => NewCircleSpaceScreen(circle: _ownCircle), size: ThemeScreen.wide, before: _joinOwnCircle, after: _leaveOwnCircle),
  ThemeScreen('circle-settings', () => CircleSettingsScreen(seed: _ownCircle.seed, qr: true), size: const Size(412, 2300), before: _joinOwnCircle, after: _leaveOwnCircle),
  ThemeScreen('circle-arrange', () => ArrangeCircleSpacesScreen(seed: _ownCircle.seed), before: _joinOwnCircle, after: _leaveOwnCircle),
  // Inside a circle the dock is the circle's, Home first (Matt, 2026-11-17: "add a 'home' button on the dock while on
  // the space and transform all the icons inside the dock to be related to the circle"), its settings beside Add people
  // in its header ("move the server settings to the header next to the add friend"): a circle of one's own, so New
  // space is among the rings, on a phone and a wide window. Then a circle's and a space's members in the drawer, Add
  // people at its top ("the member list should show up as a drawer like the add user").
  ThemeScreen('circle-dock', () => const AppShell(), before: _joinOwnCircle, after: _leaveOwnCircle, choices: (_) => _openOwnCircleSoon()),
  ThemeScreen('circle-dock-wide', () => const AppShell(), size: ThemeScreen.wide, before: _joinOwnCircle, after: _leaveOwnCircle, choices: (_) => _openOwnCircleSoon()),
  ThemeScreen('circle-members', () => _overPage(MembersDrawer(title: 'Members', subtitle: _ownCircle.name, face: CircleFace.of(_ownCircle, size: 40), list: (_) => CircleMembersList(seed: _ownCircle.seed), onAddPeople: () {})), before: _joinOwnCircle, after: _leaveOwnCircle),
  ThemeScreen('space-members', () => _overPage(MembersDrawer(title: 'Members', subtitle: 'Saturday hike', list: (_) => SpaceMembers(room: _busySpace('members'), shrinkWrap: true), onAddPeople: () {})), before: () => Voice.instance.putHangout(_busySpace('members'))),
  ThemeScreen('circle-invite', () => CircleInviteSheet(circle: _ownCircle, send: (_, _) async => const [], compose: (_) {}, buddies: _inviteFriends, qr: true), before: _joinOwnCircle, after: _leaveOwnCircle),
  // A circle offered and not yet joined (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"): its
  // banner over the conversations as it comes, and in the Circles tab a card for a new one and a row under Invites for
  // one put off with Not now.
  ThemeScreen('circle-invite-banner', () => const AppShell(), before: _inviteToCircles, after: _leaveCircle),
  ThemeScreen('circle-invites-tab', () => const AppShell(), before: _inviteToCircles, after: _leaveCircle, choices: (_) => _tapCirclesTabSoon()),
  // Contacts with two friends on Uplink (Matt, 2026-11-17: "add the ability to sort contacts by friends in
  // ghost"): All with the friends first under their heading and the Friends chip among the filters, then that chip on.
  ThemeScreen('contacts', () => const ContactsScreen(), before: _twoFriends, after: _noFriends),
  ThemeScreen('contacts-friends', () => const ContactsScreen(), before: _twoFriends, after: _noFriends, choices: (_) => _tapFriendsChipSoon()),
  // An Uplink account (test/account_shots.dart; Matt, 2026-11-17: "We need to have a way to login to existing accounts"):
  // making one, its recovery words, signing in each way, and the devices signed in.
  ...accountThemeScreens,
];

/// Theo and Sam, friends on Uplink; the phone's contacts name them ('searchContacts' in [_answerChannel]).
void _twoFriends() {
  Friends.instance = Friends(FakePort('+15551239999')
    ..stand('+15551230002', friend: 'yes')
    ..stand('+15551230003', friend: 'yes'));
  unawaited(Friends.instance.refresh());
}

void _noFriends() => Friends.instance = null;

/// The Friends chip pressed once Contacts is up, as a finger would.
void _tapFriendsChipSoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = find.text('Friends').evaluate();
      if (chip.isEmpty) return;
      final box = chip.first.renderObject! as RenderBox;
      final at = box.localToGlobal(box.size.center(Offset.zero));
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(position: at, pointer: 9002));
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(position: at, pointer: 9002));
    });

/// A circle to draw: three spaces, one of each kind, one under a heading. Unsigned: drawn, never checked.
final _circle = Circle(
  seed: '7' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: const [
    CircleSpace(seed: '7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a', name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b', name: 'Lounge', order: 1),
    CircleSpace(seed: '7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c', name: 'Drop box', kind: SpaceKind.files, order: 2, section: 'Sharing'),
  ]),
);

/// This install's own circle (its owner is the key [Circles] signs with here), so its pages show what an owner may
/// change. Drawn, never signed.
final _ownKeys = NetKeys.generate();
final _ownCircle = Circle(
  seed: '6' * 64,
  owner: NetCrypto.hex(_ownKeys.public),
  manifest: CircleManifest(owner: NetCrypto.hex(_ownKeys.public), version: 1, name: 'Book Club', hue: 'coral', icon: 'book', spaces: const [
    CircleSpace(seed: '6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a', name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b', name: 'Lounge', order: 1),
    CircleSpace(seed: '6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c6c', name: 'Reading list', kind: SpaceKind.files, order: 2, section: 'Books'),
    CircleSpace(seed: '6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d', name: 'Spoilers', kind: SpaceKind.text, order: 3, section: 'Books'),
  ]),
);

/// Two friends to choose from on the invite sheet, one chosen by nobody: kept nowhere, nothing sent.
final _inviteFriends = Buddies(_StillBuddies())
  ..all = const [
    Buddy(username: 'maya', id: 'f1', key: 'k1', name: 'Maya Chen'),
    Buddy(username: 'theo', id: 'f2', key: 'k2', name: 'Theo Park'),
  ];

class _StillBuddies implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => false;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void _joinOwnCircle() {
  Circles.instance.signerOverride = KeysSigner(_ownKeys);
  Circles.instance.join(_ownCircle);
}

Future<void> _leaveOwnCircle() {
  Circles.instance.signerOverride = null;
  return Circles.instance.clear();
}

void _joinCircle() {
  Circles.instance.join(_circle);
  // Its General space with a few messages, so a wide window shows a conversation beside the list, not a bare title.
  Voice.instance.putHangout(_circleGeneral());
}

/// The test circle's General space's chat, with a few messages in it.
HangoutRoom _circleGeneral() => _general ??= () {
      final keys = NetKeys.generate();
      final channel = _circle.channelOf(_circle.spaces.first);
      final store = MemoryHangoutStore();
      final at = _now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
      store.keepMessages(channel.chatRoom, [
        HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Who is up for the late show tonight?', at: at),
        HangoutMessage(id: '2', from: 'c', name: 'Theo', text: 'Me! Saving seats in the back', at: at + 120000),
        HangoutMessage(id: '3', from: keys.id, name: 'Me', text: 'Popcorn is on me', at: at + 300000),
      ]);
      return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
    }();
HangoutRoom? _general;
Future<void> _leaveCircle() => Circles.instance.clear();

/// Night Owls held, Film Night offered by a friend just now, and Climbing's link opened before and put off.
void _inviteToCircles() {
  Circles.instance.join(_circle);
  Circles.instance.offerLink(_climbing.link);
  Circles.instance.laterInvite(_climbing.seed);
  Circles.instance.offer(_filmNight, from: 'Maya Chen');
}

/// A friend's circle to be invited to: its manifest came with the invite, so its spaces are counted.
final _filmNight = Circle(
  seed: '5' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Film Night', hue: 'rose', icon: 'film', spaces: const [
    CircleSpace(seed: '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a', name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b', name: 'Watch party', order: 1),
    CircleSpace(seed: '5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c', name: 'Posters', kind: SpaceKind.files, order: 2),
    CircleSpace(seed: '5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d5d', name: 'Picks', kind: SpaceKind.text, order: 3),
  ]),
);

/// A circle known only by its link: its name, nothing more, until it is joined.
final _climbing = Circle(seed: '4' * 64, owner: '', manifest: CircleManifest.placeholder(owner: '', name: 'Climbing', hue: 'green'));

void _joinBothCircles() {
  _joinOwnCircle();
  Circles.instance.join(_circle);
}

/// The Circles tab chosen once the list is up, as a finger would: a tap on its icon among the tabs. The picture is
/// taken after the pumps that follow, so the tap lands before it.
void _tapCirclesTabSoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = find.descendant(of: find.byType(SectionTabs), matching: find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.circleDot)).evaluate();
      if (tab.isEmpty) return;
      final box = tab.first.renderObject! as RenderBox;
      final at = box.localToGlobal(box.size.center(Offset.zero));
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(position: at, pointer: 9001));
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(position: at, pointer: 9001));
    });

/// The circle opened in the list's place once the frame is up.
void _openCircleSoon() => WidgetsBinding.instance.addPostFrameCallback((_) => AppShellState.live?.openCircle(_circle));

/// The shell's page [id] (`settings`, `archive`) opened once the frame is up.
void _goSoon(String id) => WidgetsBinding.instance.addPostFrameCallback((_) => AppShellState.live?.go(id));

/// The circle of one's own opened in the list's place once the frame is up.
void _openOwnCircleSoon() => WidgetsBinding.instance.addPostFrameCallback((_) => AppShellState.live?.openCircle(_ownCircle));

/// [drawer] as it is raised: over a page, dimmed by the sheets' scrim.
Widget _overPage(Widget drawer) => Builder(
      builder: (context) => Stack(children: [
        Positioned.fill(child: ColoredBox(color: context.tokens.color('glacier-bg'))),
        Positioned.fill(child: ColoredBox(color: context.tokens.sheetScrim)),
        Positioned.fill(child: drawer),
      ]),
    );

void _translateOn(AppState state) => state.set('plugin_translate', 'on');

/// The French chat's name, as it was opened: it is not in the network's list of chats, so the list's pictures stay
/// as they were, and its bar read "Telegram" over "Telegram" without it.
final _priyaTg = InboxChat(network: 'telegram', id: '12', title: 'Priya Natarajan', date: _now.subtract(const Duration(minutes: 1)), snippet: 'Text 40');
final _camille = InboxChat(network: 'telegram', id: '11', title: 'Camille Laurent', date: _now.subtract(const Duration(minutes: 4)), snippet: 'Yes, where?');

InstalledPlugins? _installedBefore;
MarketState? _marketBefore;
InstalledPlugins? _packsHere;
Directory? _packsDir;

// A screen's `after` runs when the whole look's test ends (addTearDown), so each of these first puts back what the one
// before it changed: the dev pack must be gone before the listing is drawn.

/// A pack loaded in development by the runtime, running: its own page shows it unreviewed.
Future<void> _devPack(WidgetTester tester) async {
  _packsGone();
  _installedBefore = InstalledPlugins.instance;
  _packsDir = Directory.systemTemp.createTempSync('theme-packs-');
  final here = _packsHere = await installedFor(AppState()..setFlag('dev_mode', true), Directory('${_packsDir!.path}/plugins'));
  InstalledPlugins.instance = here;
  await addDev(here, billsPack());
}

/// An approved plugin the Marketplace has fetched and checked, not on this device.
Future<void> _listing(WidgetTester tester) async {
  _packsGone();
  _installedBefore = InstalledPlugins.instance;
  _marketBefore = MarketState.instance;
  _packsDir = Directory.systemTemp.createTempSync('theme-packs-');
  // Nothing installed: only the review key it pins is asked.
  final here = _packsHere = InstalledPlugins(root: Directory('${_packsDir!.path}/plugins'), reviewKeys: [reviewKey]);
  InstalledPlugins.instance = here;
  final relay = FakeRelay();
  await relay.list(billsPack(whatsNew: 'Receipts are a kind of their own.'));
  final m = marketOver(relay, Directory('${_packsDir!.path}/market'), installed: here);
  await tester.runAsync(() => m.refresh(force: true));
  MarketState.instance = m;
}

void _packsGone() {
  PluginRegistry.instance.uninstall('xbills');
  _packsHere?.dispose();
  _packsHere = null;
  if (_installedBefore != null) InstalledPlugins.instance = _installedBefore!;
  if (_marketBefore != null) MarketState.instance = _marketBefore!;
  _installedBefore = null;
  _marketBefore = null;
  try {
    _packsDir?.deleteSync(recursive: true);
  } catch (_) {}
  _packsDir = null;
}

FakeRelay? _relay;
MarketState? _submitMarket;
String? _reviewSid;
Directory? _submitDir;
final _reviewer = KeysSigner(NetKeys.generate());

MarketApi _marketApi() => MarketApi(hubUrl: 'https://relay.test', signer: _reviewer, transport: (_relay ??= FakeRelay()).call);

PluginPack _submitPack() => parsePack(packFile(billsJson()), appVersion: '0.10.1').pack!;

/// A developer with a username, and a Marketplace in memory for the form to ask.
void _submitting() {
  _submitted();
  _relay = FakeRelay();
  _submitDir = Directory.systemTemp.createTempSync('theme-submit-');
  _submitMarket = MarketState(api: _marketApi, cache: _submitDir, installed: InstalledPlugins.instance, appVersion: '0.10.1');
  unawaited(Me.instance.start(MemoryMeStore()..set('me_username', 'maya'), ValueNotifier(0), () => null));
}

/// A submission waiting for review, with the developer's notes.
void _reviewing() {
  _submitting();
  _reviewSid = _relay!.store.put(packFile(billsJson(), (j) => j['developer'] = 'maya'), status: 'submitted', notes: 'Try it on s01.');
}

void _submitted() {
  _relay = null;
  _submitMarket = null;
  _reviewSid = null;
  try {
    _submitDir?.deleteSync(recursive: true);
  } catch (_) {}
  _submitDir = null;
  unawaited(Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null));
}

void _translating() {
  _hostBefore ??= PluginRegistry.textHost;
  PluginRegistry.textHost = _FakeTranslator();
  ShownStore.instance.forget();
  // Swapped back by the person: the Spanish in the bubble, the English in the card.
  ShownStore.instance.flip('sms:23');
}

void _translated() {
  ShownStore.instance.forget();
  PluginRegistry.textHost = _hostBefore ?? PluginRegistry.textHost;
}

TextHost? _hostBefore;

/// The phone's translation, made up for the pictures.
class _FakeTranslator implements TextHost {
  static const _said = {
    '¡Hola! ¿Sigues viniendo a la cena del sábado?': 'Hi! Are you still coming to dinner on Saturday?',
    'Perfecto, yo llevo el postre. Mi madre hizo flan otra vez': 'Perfect, I\'ll bring dessert. My mother made flan again',
    'No te olvides de traer la guitarra, por favor': 'Don\'t forget to bring the guitar, please',
    'Salut ! Tu es libre ce soir pour un verre ?': 'Hi! Are you free tonight for a drink?',
  };

  @override
  String get language => 'en';
  @override
  bool get canTranslate => true;

  @override
  Future<DeviceTranslation> translate(String text, {required String to, List<String> known = const [], bool fetch = true, bool wifiOnly = true}) async {
    final said = _said[text];
    if (said != null) return DeviceTranslation('done', text: said, from: text.startsWith('Salut') ? 'fr' : 'es');
    if (text.startsWith('Obrigada')) return const DeviceTranslation('fetching', from: 'pt');
    return const DeviceTranslation('same', from: 'en');
  }

  @override
  Future<List<DeviceLanguage>> languages() async => const [DeviceLanguage('en', downloaded: true), DeviceLanguage('es', downloaded: true), DeviceLanguage('fr', downloaded: true), DeviceLanguage('pt', fetching: true)];

  @override
  Future<bool> model(String tag, {bool delete = false, bool wifiOnly = true}) async => true;
}

/// Draws [screen] in [look] at [brightness] as the app would, from the person's choices alone (lib/looks.dart's
/// ghostAttrs), and with [write] keeps its picture at `build/themes/<look>-<brightness>-<screen>.png`.
Future<void> shootLook(WidgetTester tester, TokenSheet sheet, Look look, String brightness, ThemeScreen screen, {bool write = true}) async {
  tester.view.physicalSize = screen.size * 2.0;
  tester.view.devicePixelRatio = 2.0;
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
  screen.before?.call();
  await screen.ready?.call(tester);
  // Sms keeps a part's future, made in the test that first asked for it: in a later test its callbacks wait on that
  // test's fake zone, which has gone, so the group's sticker was blank in every look but the first. Each screen is
  // handed one made here, and the picture is decoded afresh.
  Sms.instance.holdPart(902, Future.value(File('assets/stickers/party/03.webp').readAsBytesSync()));
  PaintingBinding.instance.imageCache.clear();
  final state = AppState()
    ..setTheme(brightness)
    ..setLook(look)
    // The changing dock, which every picture here was first drawn with; THEME_NAV=rail draws the rail with circles,
    // which a device that never chose has (lib/ui/nav_style.dart), for looking a look over in it.
    ..set(NavStyle.pref, Platform.environment['THEME_NAV'] ?? NavStyle.classic.name);
  screen.choices?.call(state);
  if (screen.after != null) addTearDown(screen.after!);
  final name = '${look.name}-$brightness-${screen.name}';
  await tester.pumpWidget(AppScope(
    state: state,
    // A navigator of its own for each screen: a page one screen opened over itself (a plugin's, on the Plugins page)
    // would otherwise still stand over every screen drawn after it.
    child: WidgetsApp(
      key: ValueKey('app-$name'),
      color: const Color(0xFF4F5BD5),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(
        sheet: sheet,
        attrs: ghostAttrs(state, 'mobile'),
        typography: ghostTypography('noto'),
        child: InkOverrides(child: GlacierToastProvider(child: child!)),
      ),
      home: KeyedSubtree(key: ValueKey(name), child: screen.build()),
    ),
  ));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // Pictures (a sticker, a face) decode on a real async gap and are drawn on the frame after: one short gap left the
  // group's sticker blank in some looks' pictures, so a few, each followed by a frame.
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 125));
  }
  expect(tester.takeException(), isNull, reason: name);
  if (!write) return;
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('build/themes/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Keeps what is on the screen now at `build/themes/<name>.png`, for a screen changed after [shootLook] drew it.
Future<void> _capture(WidgetTester tester, String name) async {
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File('build/themes/$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<TokenSheet> _loadSheet() async {
  final sheet = await loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css']);
  installSettingsStyles(sheet);
  return sheet;
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
}

/// The app's fonts (as test/screens_test.dart loads them), so the pictures show words.
Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  // Runestone's regular and bold are one family of two files.
  final runestone = FontLoader('Runestone');
  for (final file in ['assets/fonts/Runestone-Regular.ttf', 'assets/fonts/Runestone-Bold.ttf']) {
    runestone.addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  }
  await runestone.load();
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
}

// --- a made-up phone ------------------------------------------------------------------------------------------------

final _now = DateTime.now();
int _ago({int days = 0, int hours = 0, int minutes = 0}) => _now.subtract(Duration(days: days, hours: hours, minutes: minutes)).millisecondsSinceEpoch;
Map<String, Object?> _p(String address, [String? name]) => {'address': address, 'name': name, 'photo': null};

final _conversations = [
  {'id': 1, 'date': _ago(minutes: 4), 'people': [_p('+15551230001', 'Maya Chen')], 'snippet': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'unread': true, 'error': false, 'archived': false},
  {'id': 2, 'date': _ago(minutes: 52), 'people': [_p('+15551230002', 'Jordan Park'), _p('+15551230003', 'Sam Rivera'), _p('+15551230004', 'Alex Kim')], 'snippet': 'Picture', 'unread': true, 'error': false, 'archived': false},
  {'id': 3, 'date': _ago(hours: 5), 'people': [_p('+15551230005', 'Dad')], 'snippet': 'Call me when you land', 'unread': false, 'error': false, 'archived': false, 'pinned': true},
  {'id': 4, 'date': _ago(days: 1, hours: 2), 'people': [_p('28849')], 'snippet': 'Your verification code is 482913. Don\'t share it with anyone.', 'unread': false, 'error': false, 'archived': false, 'muted': true},
  {'id': 5, 'date': _ago(days: 3), 'people': [_p('+15551230006', 'Priya Natarajan')], 'snippet': 'haha yes 😂', 'unread': false, 'error': true, 'archived': false},
  {'id': 6, 'date': _ago(days: 12), 'people': [_p('+15551230007')], 'snippet': 'Your package was delivered', 'unread': false, 'error': false, 'archived': false, 'draft': 'Thanks, I\'ll pick it up tom'},
  {'id': 7, 'date': _ago(days: 40), 'people': [_p('+15551230008', 'Old Thread')], 'snippet': 'ok', 'unread': false, 'error': false, 'archived': true},
];

List<Map<String, Object?>> _messages(int thread) => switch (thread) {
      12 || 13 || 14 => _long,
      8 => [
          {'id': 25, 'kind': 'sms', 'address': '+15551230009', 'body': 'Obrigada pela ajuda de ontem, foi muito gentil', 'date': _ago(minutes: 1), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 24, 'kind': 'sms', 'address': '+15551230009', 'body': 'Perfecto, yo llevo el postre. Mi madre hizo flan otra vez', 'date': _ago(minutes: 3), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 23, 'kind': 'sms', 'address': '+15551230009', 'body': 'No te olvides de traer la guitarra, por favor', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 22, 'kind': 'sms', 'address': '+15551230009', 'body': 'Yes! I\'ll be there around 7', 'date': _ago(minutes: 9), 'outgoing': true, 'state': 'delivered', 'read': true},
          {'id': 21, 'kind': 'sms', 'address': '+15551230009', 'body': '¡Hola! ¿Sigues viniendo a la cena del sábado?', 'date': _ago(minutes: 12), 'outgoing': false, 'state': 'received', 'read': true},
        ],
      2 => [
          {'id': 16, 'kind': 'mms', 'address': '', 'body': 'Trailhead at 9', 'date': _ago(minutes: 47), 'outgoing': true, 'state': 'failed', 'read': true, 'parts': [], 'why': 'mobile data is off. Picture messages need it, even on Wi-Fi'},
          {'id': 15, 'kind': 'mms', 'address': '', 'body': '', 'date': _ago(minutes: 48), 'outgoing': true, 'state': 'sent', 'read': true, 'parts': [{'id': 902, 'type': 'image/png', 'name': 'ghost-sticker-party-03.png'}]},
          {'id': 13, 'kind': 'mms', 'address': '+15551230004', 'body': '👍 to "Hike this weekend?"', 'date': _ago(minutes: 50), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
          {'id': 11, 'kind': 'mms', 'address': '+15551230003', 'body': 'Look at this view 🏔️', 'date': _ago(minutes: 52), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
          {'id': 10, 'kind': 'mms', 'address': '', 'body': 'Saturday works for me', 'date': _ago(hours: 1), 'outgoing': true, 'state': 'read', 'read': true, 'parts': []},
          {'id': 9, 'kind': 'mms', 'address': '+15551230004', 'body': 'Same, any time after noon', 'date': _ago(hours: 1, minutes: 5), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
          {'id': 8, 'kind': 'mms', 'address': '+15551230002', 'body': 'Hike this weekend?', 'date': _ago(hours: 1, minutes: 8), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
          {'id': 7, 'kind': 'mms', 'address': '+15551230002', 'body': 'Who\'s around Saturday', 'date': _ago(hours: 1, minutes: 9), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
        ],
      _ => [
          {'id': 10, 'kind': 'sms', 'address': '+15551230001', 'body': '🎉🍿', 'date': _ago(minutes: 1), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 6, 'kind': 'sms', 'address': '+15551230001', 'body': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 8, 'kind': 'sms', 'address': '+15551230001', 'body': '❤️ to “Dinner at mine first?”', 'date': _ago(minutes: 20), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 5, 'kind': 'sms', 'address': '+15551230001', 'body': 'Dinner at mine first?', 'date': _ago(minutes: 30), 'outgoing': true, 'state': 'delivered', 'read': true},
          {'id': 4, 'kind': 'sms', 'address': '+15551230001', 'body': 'Movie night is still on for tonight right?', 'date': _ago(minutes: 31), 'outgoing': true, 'state': 'delivered', 'read': true},
          {'id': 3, 'kind': 'sms', 'address': '+15551230001', 'body': 'Here\'s the link https://example.com/tickets', 'date': _ago(days: 1, hours: 1), 'outgoing': false, 'state': 'received', 'read': true},
          {'id': 2, 'kind': 'sms', 'address': '+15551230001', 'body': 'Did you get the tickets?', 'date': _ago(days: 1, hours: 1, minutes: 2), 'outgoing': true, 'state': 'sent', 'read': true},
          {'id': 1, 'kind': 'sms', 'address': '+15551230001', 'body': 'Hey! Long time 👋', 'date': _ago(days: 1, hours: 3), 'outgoing': false, 'state': 'received', 'read': true},
        ],
    };

/// A long conversation (threads 12, 13 and 14) for the down arrow's screen: forty texts, newest first, every third yours.
final _long = [
  for (var i = 40; i >= 1; i--)
    {'id': 1200 + i, 'kind': 'sms', 'address': '+15551230012', 'body': i % 3 == 0 ? 'Text $i of mine, about the weekend and who is driving' : 'Text $i from Priya, a line or two long so the conversation runs several screens', 'date': _ago(minutes: 200 - i * 4), 'outgoing': i % 3 == 0, 'state': i % 3 == 0 ? 'delivered' : 'received', 'read': true},
];

/// [thread] (12, or 13 and 14 for the same conversation at other widths) left two screens up, the newest text from
/// Priya seen then being the third newest of hers: the two since are counted on the arrow.
void _leftUp(int thread) => ScrollMemory.keep('sms:$thread', 1400, seen: 'sms:${1200 + 37}');

void _answerChannel() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'status':
        return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      case 'conversations':
        return _conversations;
      case 'conversationsPage':
        if (args['archived'] == true) return {'items': _conversations.where((c) => c['archived'] == true).toList(), 'next': null};
        return {'items': _conversations, 'next': null};
      case 'conversation':
        return _conversations.where((c) => c['id'] == args['thread']).firstOrNull;
      case 'archivedCount':
        return _conversations.where((c) => c['archived'] == true).length;
      case 'messages':
        return _messages((args['thread'] as num).toInt());
      case 'people':
        // The translated conversation (thread 8) is not in the list, so the list's pictures stay as they were.
        return _conversations.where((c) => c['id'] == args['thread']).firstOrNull?['people'] ?? [_p('+15551230009', 'Lucía Ortega')];
      case 'update':
        return {'phase': 'idle', 'current': '0.8.2', 'auto': true, 'canInstall': true, 'source': 'https://gogho.st'};
      case 'ownNumber':
        return '+15551239999';
      // The phone's contacts, for Contacts ('contacts' above): two of them friends there.
      case 'searchContacts':
        return [
          {'name': 'Maya Chen', 'address': '+1 555-123-0001', 'photo': null, 'label': 'Mobile'},
          {'name': 'Theo Park', 'address': '+1 555-123-0002', 'photo': null, 'label': 'Mobile'},
          {'name': 'Sam Rivera', 'address': '+1 555-123-0003', 'photo': null, 'label': 'Work'},
          {'name': 'Mom', 'address': '+1 555-123-0010', 'photo': null, 'label': 'Mobile'},
        ];
      case 'contact':
        return _p(args['address'] as String);
      case 'e2e':
        return {'address': args['address'], 'state': 'none', 'verified': false, 'changed': false};
      case 'ghostPeers':
        return false;
      case 'keyboardHere':
        return true;
      case 'netSmsAvailable':
        return false;
      case 'netSmsDrain':
        return const <Object>[];
      case 'prefs':
        return <String, String>{};
      case 'part':
        return (args['id'] as num).toInt() == 902 ? File('assets/stickers/party/03.webp').readAsBytesSync() : null;
      default:
        return null;
    }
  });
}

/// A Telegram signed in, held in memory, with one chat (as test/inbox_screens_test.dart's).
InboxNetwork _telegram() => _tg ??= _FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '10', title: 'Jo Park', date: _now.subtract(const Duration(minutes: 2)), snippet: 'are you coming tonight?', unread: 2),
    ], {
      '10': [
        InboxMessage(id: '1', text: 'hey! long time', date: _now.subtract(const Duration(minutes: 30)), mine: false),
        InboxMessage(id: '2', text: 'I know, how have you been?', date: _now.subtract(const Duration(minutes: 28)), mine: true),
        InboxMessage(id: '3', text: 'good! there\'s a thing at the park later', date: _now.subtract(const Duration(minutes: 3)), mine: false),
        InboxMessage(id: '4', text: 'are you coming tonight?', date: _now.subtract(const Duration(minutes: 2)), mine: false),
        InboxMessage(id: '5', text: 'yes! save me a spot', date: _now.subtract(const Duration(minutes: 1)), mine: true),
      ],
      // A long chat for the down arrow's screen ('inbox-scrolled'): forty messages, every third yours.
      '12': [
        for (var i = 1; i <= 40; i++)
          InboxMessage(id: '$i', text: i % 3 == 0 ? 'Message $i of mine, about the weekend and who is driving' : 'Message $i from Priya, a line or two long so the chat runs several screens', date: _now.subtract(Duration(minutes: 200 - i * 4)), mine: i % 3 == 0),
      ],
      // A chat in French, translated (the 'translated-inbox' screen): not in the list of chats, so the list is as it was.
      '11': [
        InboxMessage(id: '1', text: 'Salut ! Tu es libre ce soir pour un verre ?', date: _now.subtract(const Duration(minutes: 6)), mine: false),
        InboxMessage(id: '2', text: 'Yes, where?', date: _now.subtract(const Duration(minutes: 4)), mine: true),
      ],
    });
InboxNetwork? _tg;

class _FakeNetwork extends InboxNetwork {
  _FakeNetwork(this.id, this.name, this._chats, this._messages);
  @override
  final String id;
  @override
  final String name;
  final List<InboxChat> _chats;
  final Map<String, List<InboxMessage>> _messages;

  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => '@matt';
  @override
  List<InboxChat> get chats => _chats;
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

/// A space's chat with a few messages, this device its owner, Maya a moderator (as test/support/space_call_harness's).
HangoutRoom _space() => _room ??= () {
      final keys = NetKeys.generate();
      final channel = VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public));
      final store = MemoryHangoutStore();
      final at = DateTime(2026, 11, 16, 19, 40).millisecondsSinceEpoch;
      store.keepMessages(channel.chatRoom, [
        HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Starting the movie in 10, hop in', at: at),
        HangoutMessage(id: '2', from: 'a', name: 'Maya Chen', text: 'Bring snacks 🍿', at: at + 20000),
        HangoutMessage(id: '3', from: 'c', name: 'Riley', text: 'On my way!', at: at + 60000),
        HangoutMessage(id: '4', from: keys.id, name: 'Me', text: 'Saving you a seat', at: at + 90000),
      ]);
      store.keepRoster(channel.chatRoom, Roster.first(channel.owner).next(assigned: {'a': Role.moderator}));
      return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
    }();
HangoutRoom? _room;

/// A texting space with a description its owner signed ('space-text-about').
HangoutRoom _aboutSpace() => _about ??= () {
      final keys = NetKeys.generate();
      final channel = VoiceChannel.make('Book club', owner: NetCrypto.hex(keys.public), kind: SpaceKind.text);
      final store = MemoryHangoutStore();
      final at = _now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
      store.keepMessages(channel.chatRoom, [
        HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Chapter 4 by Friday?', at: at),
        HangoutMessage(id: '2', from: keys.id, name: 'Me', text: 'Works for me', at: at + 60000),
      ]);
      store.keepRoster(channel.chatRoom, Roster.first(channel.owner, kind: SpaceKind.text));
      const words = 'Fiction on Fridays. One chapter a week, spoilers in threads please.';
      final key = NetCrypto.hex(keys.public);
      final sig = NetCrypto.sign(keys, SpaceAbout.signedBytes(channel.chatRoom, words, 1, keys.id, key));
      store.keepAbout(channel.chatRoom, jsonEncode(SpaceAbout(text: words, version: 1, by: keys.id, byKey: key, sig: NetCrypto.hex(sig)).toJson()));
      return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
    }();
HangoutRoom? _about;

/// A space whose chat runs several screens, for the down arrow over a space's chat ('space-scrolled').
HangoutRoom _longSpace() => _long2 ??= () {
      final keys = NetKeys.generate();
      final channel = VoiceChannel.make('Book club', owner: NetCrypto.hex(keys.public));
      final store = MemoryHangoutStore();
      final at = _now.subtract(const Duration(minutes: 200)).millisecondsSinceEpoch;
      store.keepMessages(channel.chatRoom, [
        for (var i = 1; i <= 40; i++)
          HangoutMessage(id: '$i', from: i % 3 == 0 ? keys.id : 'a', name: i % 3 == 0 ? 'Me' : 'Maya Chen', text: i % 3 == 0 ? 'Line $i of mine, about the next book' : 'Line $i from Maya, a line or two long so the chat runs several screens', at: at + i * 240000),
      ]);
      store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
      return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
    }();
HangoutRoom? _long2;

/// A space with people in it: Maya (in voice) and Dana there on joining, then Riley comes in and Dana leaves, each
/// saying their name as the app does ('hi', sealed with the space's key). One per [screen], each joined afresh.
HangoutRoom _busySpace(String screen) => _busy[screen] ??= () {
      final keys = NetKeys.generate();
      final channel = VoiceChannel.make('Saturday hike', owner: NetCrypto.hex(keys.public));
      final store = MemoryHangoutStore();
      final at = _now.subtract(const Duration(minutes: 20)).millisecondsSinceEpoch;
      store.keepMessages(channel.chatRoom, [
        HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Meet at the north trailhead, 9 sharp', at: at),
        HangoutMessage(id: '2', from: 'b', name: 'Dana', text: 'I can drive two people', at: at + 60000),
        HangoutMessage(id: '3', from: keys.id, name: 'Me', text: 'Count me in for a seat, I\'ll bring coffee for everyone who wants it', at: at + 120000),
      ]);
      return HangoutRoom(channel: channel, route: _BusyRoute(keys.id, channel), name: 'Me', signer: KeysSigner(keys), store: store);
    }();
final _busy = <String, HangoutRoom>{};

class _BusyRoute extends _NoRoute {
  _BusyRoute(super.me, this.channel);
  final VoiceChannel channel;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();

  void _hi(String from, String name, {bool voice = false}) =>
      _packets.add((room: channel.chatRoom, from: from, bytes: NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'hi', 'n': name, 'a': voice})))));

  @override
  Future<List<String>> join(String room, String token) async {
    Timer(const Duration(milliseconds: 1), () {
      _hi('a', 'Maya Chen', voice: true);
      _hi('b', 'Dana');
    });
    Timer(const Duration(milliseconds: 60), () => _events.add(RoomEvent(channel.chatRoom, came: 'c')));
    Timer(const Duration(milliseconds: 110), () => _hi('c', 'Riley'));
    Timer(const Duration(milliseconds: 160), () => _events.add(RoomEvent(channel.chatRoom, went: 'b')));
    return const ['a', 'b'];
  }

  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
}

class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
  @override
  final String me;
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}
