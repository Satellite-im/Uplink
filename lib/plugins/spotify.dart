/// Spotify: songs queued by anyone in a circle's call and played to everyone in it from the Spotify app of one of them
/// (Matt, 2026-11-25: "Please add a spotify plugin for circles that allows a user to add songs to a queue and play them
/// from spotify"; "I want it to join a voice chat and stream the music over the voice chat i'm in"). The work is
/// lib/voice/spotify.dart's and the queue's panel is lib/ui/spotify_panel.dart; this puts Spotify in a call's menu and in
/// the space's header while in its call, and the line over the call saying what plays.
///
/// A plugin for a whole circle and nothing else: in a circle's spaces it is there when the circle has it on.
library;

import '../art/app_icon.dart' show LucideIcon;
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../circles/circles.dart';
import '../ui/spotify_panel.dart';
import '../voice/channels.dart';
import 'plugin.dart';

class SpotifyPlugin extends GhostPlugin {
  const SpotifyPlugin();

  static const pluginId = 'spotify';

  @override
  String get id => pluginId;

  @override
  String get name => 'Spotify';

  @override
  String get description => 'Queue songs in a call and hear them together, played from the Spotify app of someone in it on a Mac or a PC.';

  @override
  LucideIcon get icon => LucideMore.music;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'green';

  @override
  String get tagline => 'A queue of songs for a call, played from one person\'s Spotify.';

  @override
  String get pitch => 'Paste a song\'s link and it joins the queue. Whoever pressed Start plays them all to the call from their own Spotify.';

  @override
  List<String> get adds => const [
        'Spotify in a call\'s menu and in the space\'s header',
        'A queue everyone who may speak can add to, skip and pause',
        'The music in the call in stereo, at a loudness of its own for each person',
        'Lossless to whoever wears headphones and is connected directly',
        'Started by someone on a Mac or a PC with the Spotify app',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(LucideMore.music, 'The sound of the DJ\'s own Spotify app, live, to the people in the call', 'Of Spotify alone, never of another app. It goes from their computer to each person in the call, sealed as the call is, and nothing of it is stored.'),
        PluginReach(Lucide.keyRound, 'The DJ\'s own Spotify account', 'Spotify\'s terms are for personal use and don\'t allow rebroadcasting, so this is for a small private call, and the DJ\'s account carries that risk.'),
        PluginReach(Lucide.globe, 'Spotify\'s servers, for what a song is and its cover', 'The device that adds a song asks Spotify its title, and each device in the call loads its cover.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.circle};

  /// Whether it is on in the call there is now: in a circle's space, where the circle has it on.
  static bool onInCall() {
    final s = Voice.instance.session;
    return s != null && s.channel.circle != null && Circles.instance.pluginOnIn(s.channel, pluginId) == true;
  }

  static PluginAction _open() => PluginAction(label: 'Spotify', icon: LucideMore.music, run: (host) => host.present((context) => const SpotifyScreen()));

  @override
  List<SlotFill> get slots => [
        Slots.spaceHeader.fill((place, prefs) => place.voice && place.inCall ? [_open()] : const []),
        Slots.callControls.fill((place, prefs) => [_open()]),
        Slots.callBanner.fill((context, place, prefs) => const [MusicLine()]),
      ];
}
