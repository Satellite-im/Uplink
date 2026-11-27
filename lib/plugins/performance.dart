/// Performance: what the app itself is spending, in a small row under the title bar (Matt, 2026-11-24: "add a
/// performance plugin that adds a small row to the top of the screen just below the titlebar that shows app usage,
/// spikes and a log we can copy").
///
/// Off until added. On, the app measures itself (lib/perf/app_usage.dart): the processor, memory and frames in the
/// row (lib/ui/performance_row.dart), a count of spikes, and a log of each spike and of every minute, with the
/// busiest threads by name on Android and Linux. Log opens it; Copy takes it. It goes on reading with the app put
/// away, slower, which is the point of it on a phone: a log copied after an afternoon in a pocket says what the app
/// did there. Nothing it reads leaves the device unless the person copies the log and sends it.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import 'plugin.dart';

class PerformancePlugin extends GhostPlugin {
  const PerformancePlugin();

  @override
  String get id => 'performance';

  @override
  String get name => 'Performance';

  @override
  String get description => 'A small row under the title bar with how much of the processor and memory the app is using, a count of spikes, and a log you can copy.';

  @override
  LucideIcon get icon => Lucide.gauge;

  // A tool for looking into the app, and it reads every two seconds while it is on: chosen, so off.
  @override
  bool get onByDefault => false;

  @override
  PluginShelf get shelf => PluginShelf.tools;

  @override
  String get hue => 'amber';

  @override
  String get tagline => 'See what the app is using, and copy a log of it.';

  @override
  List<String> get adds => const ['A row under the title bar: processor, memory, frames', 'A count of spikes: a busy processor, a slow frame, a held-up app', 'A log of each spike and of every minute, to copy'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(LucideMore.cpu, 'How much of the processor and memory this app uses', 'Read on this device every two seconds, every ten while the app is put away. Other apps are not looked at.'),
        PluginReach(Lucide.fileText, 'A log kept on this device', 'The last 500 lines, gone when the app closes. It leaves the device only if you copy it and send it.'),
      ];

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.note(label: 'It keeps reading while the app is put away', hint: 'More slowly. That is how a log copied from a phone says what the app did in a pocket.', icon: Lucide.activity),
        PluginSetting.note(label: 'Windows and the browser', hint: 'They don\'t say how much of the processor an app uses: the row shows memory, frames and hold-ups there.', icon: Lucide.laptop),
      ];
}
