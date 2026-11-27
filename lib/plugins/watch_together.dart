/// Watch together: a video or a song from a Files space played on everyone's device in a call, in step (Matt,
/// 2026-11-19: "watch together"). The work is lib/voice/watch_together.dart's; this puts "Watch together" on a Files
/// file's menu while in a call, and the line over the call to watch too.
///
/// A plugin a whole circle can hold: in a circle's spaces it is there when the circle has it on, for everyone.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../files/files_store.dart';
import '../kit/settings_type.dart';
import '../ui/video_screen.dart';
import '../voice/channels.dart';
import '../voice/voice.dart';
import '../voice/watch_together.dart';
import 'plugin.dart';
import 'registry.dart';

class WatchTogetherPlugin extends GhostPlugin {
  const WatchTogetherPlugin();

  @override
  String get id => 'watch';

  @override
  String get name => 'Watch together';

  @override
  String get description => 'Play a video or a song from a Files space on everyone\'s device in a call, in step.';

  @override
  LucideIcon get icon => Lucide.film;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'purple';

  @override
  String get tagline => 'A film from a Files space, in step for everyone in the call.';

  @override
  String get pitch => 'Watch a film or listen to an album together in a call, each from their own sealed copy, in step.';

  @override
  List<String> get adds => const ['Watch together on a video or song in a Files space, while in a call', 'A line over the call to watch too', 'Play, pause and move it for everyone'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.film, 'The file, from its Files space', 'Each device reads it as it always does; only play, pause and where it is are said in the call.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  /// Whether it is on in the call there is now.
  static bool onInCall() {
    final s = Voice.instance.session;
    final app = Voice.instance.app;
    if (s == null || app == null) return false;
    final reg = PluginRegistry.instance;
    final p = reg.plugins.whereType<WatchTogetherPlugin>().firstOrNull;
    if (p == null) return false;
    return reg.isOnIn(p, AppStore(app), inCircle: s.channel.circle != null, circleOn: Circles.instance.pluginOnIn(s.channel, p.id));
  }

  @override
  List<SlotFill> get slots => [
        Slots.callBanner.fill((context, place, prefs) => [if (WatchTogether.instance.watching != null) const WatchingLine()]),
      ];
}

/// The Files space a seed names, among the spaces this device has.
VoiceChannel? filesSpaceOf(String seed) {
  for (final c in Circles.instance.all) {
    for (final s in c.spaces) {
      if (s.seed == seed) return c.channelOf(s);
    }
  }
  return [for (final c in Voice.instance.channels) if (c.seed == seed) c].firstOrNull;
}

/// Opens what the call is watching, in step.
void watchNow(BuildContext context) {
  final w = WatchTogether.instance.watching;
  if (w == null) return;
  final space = filesSpaceOf(w.space);
  if (space == null) return;
  Navigator.of(context).push(videoRoute(VideoScreen.stream(stream: FilesStore.instance.stream(space, w.file), title: w.file.name, poster: w.file.thumb, sync: WatchTogether.instance)));
}

/// The line over the call while it watches something: who started it, and Watch or Stop.
class WatchingLine extends StatelessWidget {
  const WatchingLine({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: WatchTogether.instance,
      builder: (context, _) {
        final t = context.tokens;
        final w = WatchTogether.instance.watching;
        if (w == null) return const SizedBox.shrink();
        final who = w.by == 'me' ? 'You are' : '${Voice.instance.nameOf(w.by)} is';
        final reachable = filesSpaceOf(w.space) != null;
        Widget pill(String label, VoidCallback onPressed) => Padding(
              padding: EdgeInsetsDirectional.only(start: t.space(2)),
              child: GlacierPressable(
                onPressed: onPressed,
                semanticLabel: label,
                builder: (context, state) => Container(
                  padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
                  decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(999)),
                  child: Text(label, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: const Color(0xFF5B3FD6))),
                ),
              ),
            );
        return Container(
          key: const ValueKey('watching'),
          margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
          decoration: BoxDecoration(color: const Color(0xFF5B3FD6), borderRadius: BorderRadius.circular(t.radius('lg'))),
          child: Row(children: [
            AppIcon(Lucide.film, size: 16, color: const Color(0xFFFFFFFF)),
            SizedBox(width: t.space(2)),
            Expanded(
              child: Text(reachable ? '$who watching ${w.file.name} together' : '$who watching ${w.file.name} from a Files space you aren\'t in', maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF))),
            ),
            if (reachable && !WatchTogether.instance.here) pill('Watch', () => watchNow(context)),
            pill('Stop', WatchTogether.instance.stop),
          ]),
        );
      },
    );
  }
}
