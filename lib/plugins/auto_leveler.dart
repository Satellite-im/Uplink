/// Auto leveler: everyone in a call heard at about the same loudness on this device (Matt, 2026-11-20: "build the auto
/// leveler plugin that levels everyone's voice levels"). The work is lib/voice/leveler.dart's; this turns it on in a
/// call while the plugin is on, and shows in a person's sheet what it is doing to them.
///
/// A plugin a whole circle can hold: in a circle's spaces it is on when the circle has it on (Circle settings ›
/// Plugins). It changes only what this device plays: nothing is sent, and nobody else hears anything different.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../voice/channels.dart';
import 'plugin.dart';
import 'registry.dart';

/// The plugin: what the Marketplace says of it, and whether it is on in the call there is.
class AutoLevelerPlugin extends GhostPlugin {
  const AutoLevelerPlugin();

  static const pluginId = 'autoleveler';

  @override
  String get id => pluginId;

  @override
  String get name => 'Auto leveler';

  @override
  String get description => 'Everyone in a call at about the same loudness: the quiet ones brought up, the loud ones brought down, on this device.';

  @override
  LucideIcon get icon => Lucide.audioLines;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'teal';

  @override
  String get tagline => 'Everyone in a call at the same loudness.';

  @override
  String get pitch => 'No more turning one friend up and another down: each voice is brought to the same level as they talk.';

  @override
  List<String> get adds => const [
        'Each person in a call turned up or down to the same loudness, a few seconds after they start talking',
        'At most about 9 dB either way, so a whisper stays a whisper',
        'What it is doing to each person, in their sheet',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.audioLines, 'How loud each person arrives, on this device', 'Read from the call as the talking ripples are. Nothing is sent, kept or told to anyone.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  /// Whether it is on in the call there is now.
  static bool onInCall() {
    final s = Voice.instance.session;
    final app = Voice.instance.app;
    if (s == null || app == null) return false;
    final reg = PluginRegistry.instance;
    final p = reg.plugins.whereType<AutoLevelerPlugin>().firstOrNull;
    if (p == null) return false;
    return reg.isOnIn(p, AppStore(app), inCircle: s.channel.circle != null, circleOn: Circles.instance.pluginOnIn(s.channel, p.id));
  }
}
