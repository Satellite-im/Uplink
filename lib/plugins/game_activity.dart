/// Game activity: what you are playing, beside your name, for friends and the spaces you are in (Matt, 2026-11-20:
/// "what about game presence sensing like discord has?", then "THat sounds good, let's build").
///
/// Off until added. On, a Mac or Windows computer looks for a game among its running programs and says its name and
/// when it began (lib/games/game_activity.dart, lib/games/game_sense.dart); a phone and an iPhone say nothing of their
/// own (Android would need its Usage access; an iPhone can't see what else runs) and show what friends are playing
/// whether or not this is added. Who is told is the two switches; a game can be kept out by name, and a program the
/// app doesn't know can be named as a game.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import 'plugin.dart';

class GameActivityPlugin extends GhostPlugin {
  const GameActivityPlugin();

  @override
  String get id => 'gameactivity';

  @override
  String get name => 'Game activity';

  @override
  String get description => 'Shows friends and the spaces you\'re in which game you\'re playing on this computer, and for how long.';

  @override
  LucideIcon get icon => LucideMore.gamepad;

  // What it says leaves this device, so it is chosen: off.
  @override
  bool get onByDefault => false;

  @override
  PluginShelf get shelf => PluginShelf.tools;

  @override
  String get hue => 'mint';

  @override
  String get tagline => 'Friends see what you\'re playing.';

  @override
  List<String> get adds => const ['"Playing …" on your profile, for friends', 'The same in spaces and circles you\'re in', 'What friends are playing, on their profiles'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(LucideMore.gamepad, 'The names of the programs running on this computer', 'Read on this computer every half minute. Only a game\'s name and when it began are ever sent.'),
        PluginReach(Lucide.users, 'Your friends by username, and people in your spaces', 'Told what you\'re playing, sealed as your messages to them are. Each has a switch.'),
      ];

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(key: 'friends', label: 'Tell friends', hint: 'Friends by username see it on your profile.', icon: Lucide.users),
        PluginSetting.toggle(key: 'spaces', label: 'Tell spaces and circles', hint: 'People in a space you\'re in see it on your profile there.', icon: Lucide.hash),
        PluginSetting.words(key: 'never', label: 'Never show these games', hint: 'A game\'s name a line, as it is shown.', icon: Lucide.eyeOff, placeholder: 'Stardew Valley'),
        PluginSetting.words(key: 'also', label: 'Also games', hint: 'A program the app doesn\'t know is a game: its name a line, as its file or app is called.', icon: Lucide.plus, placeholder: 'MyGame.exe'),
        PluginSetting.note(label: 'On a Mac or Windows computer', hint: 'A phone can\'t see which game is running. It shows what your friends are playing.', icon: Lucide.laptop),
      ];
}
