/// Scribe: a recorded call written out, each line with who said it and when, on this device (Matt, 2026-11-19: "Start
/// with the recording plugin, then scribe"). The work is lib/voice/scribe.dart's; this decides when it runs and puts
/// it in the Recordings page (lib/ui/recording_ui.dart).
///
/// A plugin a whole circle can hold: a recording made in a circle's space is written out when the circle has Scribe
/// on; any other when it is added here.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../voice/channels.dart';
import '../voice/recorder.dart';
import 'plugin.dart';
import 'registry.dart';

class ScribePlugin extends GhostPlugin {
  const ScribePlugin();

  @override
  String get id => 'scribe';

  @override
  String get name => 'Scribe';

  @override
  String get description => 'Write out a recorded call: every line with who said it and when, made on this device.';

  @override
  LucideIcon get icon => Lucide.scrollText;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'amber';

  @override
  String get tagline => 'Who said what, and when, from each recording.';

  @override
  String get pitch => 'Every recorded call written out, each line named for whoever said it.';

  @override
  List<String> get adds => const [
        'The words of each recording, named and timed',
        'A line summing the call up, where the phone has its own model',
        'Subtitles over the recording in the player',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.scrollText, 'Recordings, heard on this device', 'By the device\'s own speech recognition. Nothing is sent anywhere.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(key: 'auto', label: 'Write out each recording when it is saved', hint: 'Otherwise, from its menu in Recordings.'),
      ];

  /// Whether Scribe is on for [r]: by the circle of the space it was made in, where it was a circle's; else by this
  /// device's switch.
  static bool onFor(Recording r) {
    final app = Voice.instance.app;
    if (app == null) return false;
    final reg = PluginRegistry.instance;
    final plugin = reg.plugins.whereType<ScribePlugin>().firstOrNull;
    if (plugin == null) return false;
    final space = [for (final c in Voice.instance.channels) if (c.seed == r.seed) c].firstOrNull;
    final inCircle = space?.circle != null;
    return reg.isOnIn(plugin, AppStore(app), inCircle: inCircle, circleOn: space == null ? null : Circles.instance.pluginOnIn(space, plugin.id));
  }

  /// Whether [r] should be written out as soon as it is saved.
  static bool autoFor(Recording r) {
    if (!onFor(r)) return false;
    final app = Voice.instance.app;
    final reg = PluginRegistry.instance;
    final plugin = reg.plugins.whereType<ScribePlugin>().first;
    return app != null && reg.prefsOf(plugin, AppStore(app)).flag('auto');
  }
}
