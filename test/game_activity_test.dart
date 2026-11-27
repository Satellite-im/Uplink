import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/games/game_activity.dart';
import 'package:ghost_messaging/games/game_sense.dart';
import 'package:ghost_messaging/plugins/game_activity.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// Game activity (Matt, 2026-11-20: "what about game presence sensing like discord has?", "THat sounds good, let's
/// build"): which program is a game (lib/games/game_sense.dart), what is said of it and for how long it is believed
/// (lib/games/game_activity.dart), and the plugin that decides who is told (lib/plugins/game_activity.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  group('which program is a game', () {
    test('by the library it runs from: the folder is the game\'s name', () {
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Steam\steamapps\common\Hades II\Hades2.exe'), 'Hades II');
      expect(GameSense.gameOf(r'D:\SteamLibrary\steamapps\common\Baldurs Gate 3\bin\bg3_dx11.exe'), 'Baldurs Gate 3');
      expect(GameSense.gameOf('/Users/sam/Library/Application Support/Steam/steamapps/common/Stardew Valley/Contents/MacOS/StardewValley'), 'Stardew Valley');
      expect(GameSense.gameOf(r'C:\Program Files\Epic Games\RocketLeague\Binaries\Win64\RocketLeague.exe'), 'RocketLeague');
      expect(GameSense.gameOf(r'C:\XboxGames\Forza Horizon 5\Content\ForzaHorizon5.exe'), 'Forza Horizon 5');
      expect(GameSense.gameOf(r'C:\Riot Games\VALORANT\live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe'), 'VALORANT');
    });

    test('never a helper, a crash reporter, a launcher or a library\'s own tools', () {
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Steam\steamapps\common\Hades II\UnityCrashHandler64.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Steam\steamapps\common\Steamworks Shared\_CommonRedist\vcredist.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Steam\steamapps\common\Proton 9.0\proton.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Riot Games\Riot Client\RiotClientServices.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Program Files (x86)\Steam\steam.exe'), isNull);
      expect(GameSense.gameOf(r'C:\Windows\System32\svchost.exe'), isNull);
      expect(GameSense.gameOf('/Applications/Safari.app/Contents/MacOS/Safari'), isNull);
    });

    test('by its program\'s name where it is known, and Minecraft by its own Java', () {
      expect(GameSense.gameOf('/Applications/RuneLite.app/Contents/MacOS/RuneLite'), 'Old School RuneScape');
      expect(GameSense.gameOf(r'C:\Users\sam\AppData\Local\RuneLite\RuneLite.exe'), 'Old School RuneScape');
      expect(GameSense.gameOf('/Users/sam/Library/Application Support/minecraft/runtime/java-runtime-delta/mac-os-arm64/java-runtime-delta/jre.bundle/Contents/Home/bin/java'), 'Minecraft');
      expect(GameSense.gameOf('/usr/bin/java'), isNull);
    });

    test('and whatever the person calls a game, by its file\'s or its app\'s name', () {
      expect(GameSense.gameOf(r'D:\Games\MyGame\MyGame.exe'), isNull);
      expect(GameSense.gameOf(r'D:\Games\MyGame\MyGame.exe', also: {'mygame.exe'}), 'MyGame');
      expect(GameSense.gameOf('/Applications/Dolphin.app/Contents/MacOS/Dolphin', also: {'Dolphin'}), 'Dolphin');
    });

    test('a Mac app that says it is a game is one, by the name it shows', () {
      expect(GameSense.factsOf({'LSApplicationCategoryType': 'public.app-category.role-playing-games', 'CFBundleName': 'Disco'}, 'x'), (game: true, name: 'Disco'));
      expect(GameSense.factsOf({'LSApplicationCategoryType': 'public.app-category.games', 'CFBundleDisplayName': 'Mini Motorways', 'CFBundleName': 'mm'}, 'x').name, 'Mini Motorways');
      expect(GameSense.factsOf({'LSApplicationCategoryType': 'public.app-category.productivity'}, 'Notes'), (game: false, name: 'Notes'));
      expect(GameSense.factsOf(const {}, 'Thing').game, isFalse);
    });

    test('the programs running are read, an app is asked what it is once, and a game never shown is not', () async {
      final asked = <String>[];
      var listing = '/Applications/Safari.app/Contents/MacOS/Safari\n/Applications/Mini Motorways.app/Contents/MacOS/Mini Motorways\n/Applications/Mini Motorways.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper\n/usr/sbin/cfprefsd\n';
      final sense = GameSense(
        windows: false,
        runner: (program, args) async {
          if (program == '/bin/ps') return listing;
          asked.add(args.last);
          return jsonEncode(args.last.contains('Mini Motorways') ? {'LSApplicationCategoryType': 'public.app-category.games', 'CFBundleName': 'Mini Motorways'} : {'LSApplicationCategoryType': 'public.app-category.productivity', 'CFBundleName': 'Safari'});
        },
      );
      expect(await sense.now(), 'Mini Motorways');
      expect(asked, hasLength(2), reason: 'each app once; a helper inside an app is that app');
      expect(await sense.now(), 'Mini Motorways');
      expect(asked, hasLength(2), reason: 'not asked again');
      expect(await sense.now(never: {'mini motorways'}), isNull);
      // A second game started: the newer of the two is the one said.
      await sense.now();
      listing += '/Users/sam/Library/Application Support/Steam/steamapps/common/Hades/Hades.app/Contents/MacOS/Hades\n';
      expect(await sense.now(), 'Hades');
      listing = '/usr/sbin/cfprefsd\n';
      expect(await sense.now(), isNull);
    });

    test('Windows\' list is read by its own command, and a list that can\'t be read is no game', () async {
      String? ran;
      final sense = GameSense(windows: true, runner: (program, args) async {
        ran = program;
        return 'C:\\Windows\\explorer.exe\r\n\r\nC:\\Program Files (x86)\\Steam\\steamapps\\common\\Hades II\\Hades2.exe\r\n';
      });
      expect(await sense.now(), 'Hades II');
      expect(ran, 'powershell');
      expect(await GameSense(windows: true, runner: (_, _) async => throw const FormatException('no')).now(), isNull);
    });
  });

  group('what is said', () {
    test('a game and when it began, and back; nothing that is not a name; a clock ahead is now', () {
      final since = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch - 60000 * 125);
      final g = GameActivity.fromJson(jsonDecode(jsonEncode(GameActivity('Hades II', since).toJson())))!;
      expect(g, GameActivity('Hades II', since));
      expect(g.words(), 'Playing Hades II · 2 h 5 min');
      expect(GameActivity('Hades', DateTime.now()).words(), 'Playing Hades');
      expect(GameActivity('Hades', DateTime.now().subtract(const Duration(hours: 3))).words(), 'Playing Hades · 3 h');
      expect(GameActivity.fromJson(null), isNull);
      expect(GameActivity.fromJson({'n': '   '}), isNull);
      expect(GameActivity.fromJson({'n': 7}), isNull);
      expect(GameActivity.fromJson({'n': 'a\nb\u0007c'})!.name, 'a b c', reason: 'one line');
      expect(GameActivity.fromJson({'n': 'x' * 500})!.name.length, GameActivity.most);
      final ahead = GameActivity.fromJson({'n': 'Hades', 's': DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch})!;
      expect(DateTime.now().difference(ahead.since).inSeconds.abs(), lessThan(5));
    });

    test('someone\'s game is believed for twelve minutes after it was last said', () {
      // Today's, not a fixed date: a game said to have begun more than a week before the real clock is taken to have
      // begun now (GameActivity.fromJson), and this test, written for 2026-11-20, failed from 2026-11-27 on.
      final start = DateTime.now();
      var now = start;
      final all = GameActivities(clock: () => now);
      var told = 0;
      all.addListener(() => told++);
      all.heard('maya', {'n': 'Hades', 's': now.millisecondsSinceEpoch});
      expect(all.of('maya')?.name, 'Hades');
      expect(told, 1);
      // Said again (every five minutes while it goes on): still believed, nobody told anew.
      now = now.add(const Duration(minutes: 5));
      all.heard('maya', {'n': 'Hades', 's': start.millisecondsSinceEpoch});
      expect(told, 1);
      now = now.add(const Duration(minutes: 11));
      expect(all.of('maya')?.name, 'Hades');
      now = now.add(const Duration(minutes: 2));
      expect(all.of('maya'), isNull, reason: 'a computer that went away never said it stopped');
      // A phone tells its computer everyone's at once: those not named are not playing.
      all.heard('sam', {'n': 'Doom'});
      all.heardAll({'theo': {'n': 'Celeste'}});
      expect(all.of('sam'), isNull);
      expect(all.all().keys, ['theo']);
    });
  });

  group('the plugin', () {
    const plugin = GameActivityPlugin();

    test('ships off, on this device alone, with a switch for friends and one for spaces', () {
      expect(shippedPlugins.whereType<GameActivityPlugin>(), hasLength(1));
      expect(plugin.onByDefault, isFalse);
      expect(plugin.scopes, {PluginScope.device});
      expect([for (final s in plugin.settings) ?s.key], ['friends', 'spaces', 'never', 'also']);
    });

    test('looks only while it is added, and tells friends and spaces each by its switch, once, and that it stopped', () async {
      final app = AppState();
      String? running;
      final sense = GameSense(windows: true, runner: (_, _) async => running == null ? '' : 'C:\\Steam\\steamapps\\common\\$running\\game.exe\n');
      final told = <String>[];
      final all = GameActivities();
      final presence = GamePresence(sense: sense, activities: all, every: const Duration(days: 1), first: const Duration(days: 1), tell: (game, {required friends, required spaces}) => told.add('${game?.name}|${friends ? 'f' : ''}${spaces ? 's' : ''}'));
      // The service reads the app's own choices: looked at by hand here, as its timer would.
      presence.app = app;
      running = 'Hades';
      await presence.look();
      expect(told, isEmpty, reason: 'not added: nothing is looked for or said');
      expect(all.mine, isNull);

      app.set('plugin_gameactivity', 'on');
      await presence.look();
      expect(told, ['Hades|fs']);
      expect(all.mine?.name, 'Hades');
      expect(presence.forFriends?.name, 'Hades');
      final began = all.mine!.since;
      await presence.look();
      expect(told, hasLength(1), reason: 'the same game is not said again at once');
      expect(all.mine!.since, began, reason: 'and goes on from when it began');

      // Spaces switched off: they are told it stopped, friends still told the game.
      app.set('plugin_gameactivity_spaces', 'off');
      await presence.look();
      expect(told.last, 'Hades|fs');
      expect(presence.forSpaces, isNull);
      expect(presence.forFriends?.name, 'Hades');
      running = 'Celeste';
      await presence.look();
      expect(told.last, 'Celeste|f');
      // A game kept out by name is not said; friends are told nothing is being played.
      app.set('plugin_gameactivity_never', 'celeste');
      await presence.look();
      expect(told.last, 'null|f');
      expect(all.mine, isNull);
      await presence.look();
      expect(told, hasLength(4), reason: 'nothing more to say');
      // Removed while playing: said once more, that it stopped.
      app.set('plugin_gameactivity_never', '');
      await presence.look();
      expect(told.last, 'Celeste|f');
      app.set('plugin_gameactivity', 'off');
      await presence.look();
      expect(told.last, 'null|f');
    });

    test('a game still being played is said again after a while, for whoever opened the app since', () async {
      final app = AppState()..set('plugin_gameactivity', 'on');
      final told = <String?>[];
      final presence = GamePresence(
        sense: GameSense(windows: true, runner: (_, _) async => 'C:\\Steam\\steamapps\\common\\Hades\\game.exe\n'),
        activities: GameActivities(),
        every: const Duration(days: 1),
        first: const Duration(days: 1),
        again: Duration.zero,
        tell: (game, {required friends, required spaces}) => told.add(game?.name),
      )..app = app;
      await presence.look();
      await presence.look();
      expect(told, ['Hades', 'Hades']);
    });
  });
}
