/// Soundboard: pads in a call that play a short sound on everyone's device (Matt, 2026-11-20: "build a soundboards
/// plugin for circles"). The work is lib/voice/soundboard.dart's and the pads are lib/ui/soundboard_screen.dart; this
/// puts Soundboard in a call's menu and in the space's header while in its call, and the line over the call saying who
/// played what.
///
/// A plugin a whole circle can hold: in a circle's spaces it is there when the circle has it on, for everyone, with
/// the circle's own sounds beside the app's (Circle settings › Plugins).
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../kit/settings_type.dart';
import '../ui/soundboard_screen.dart';
import '../voice/channels.dart';
import '../voice/soundboard.dart';
import 'plugin.dart';
import 'registry.dart';

/// The plugin: what the Marketplace says of it, and where it puts Soundboard in a call.
class SoundboardPlugin extends GhostPlugin {
  const SoundboardPlugin();

  static const pluginId = 'soundboard';

  @override
  String get id => pluginId;

  @override
  String get name => 'Soundboard';

  @override
  String get description => 'Pads in a call that play a short sound for everyone in it: an air horn, applause, a sad trombone, or a circle\'s own.';

  @override
  LucideIcon get icon => Lucide.megaphone;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'amber';

  @override
  String get tagline => 'An air horn, applause and a circle\'s own sounds, for everyone in the call.';

  @override
  String get pitch => 'Press a pad in a call and everyone hears it. A circle can add sounds of its own.';

  @override
  List<String> get adds => const ['Soundboard in a call\'s menu and in the space\'s header', 'Twelve sounds to start with', 'A circle\'s own sounds, added by whoever may change it', 'A loudness of its own, and a switch to hear none of it'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.megaphone, 'Which pad was pressed, said in the call', 'No sound is sent: each device plays its own copy, at the loudness it chose, or not at all.'),
        PluginReach(Lucide.folderOpen, 'A circle\'s own sounds, sealed on the relay', 'Kept where the circle\'s banner is, and named in the circle\'s signed page: only those can be played.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  /// Whether it is on in the call there is now.
  static bool onInCall() {
    final s = Voice.instance.session;
    final app = Voice.instance.app;
    if (s == null || app == null) return false;
    final reg = PluginRegistry.instance;
    final p = reg.plugins.whereType<SoundboardPlugin>().firstOrNull;
    if (p == null) return false;
    return reg.isOnIn(p, AppStore(app), inCircle: s.channel.circle != null, circleOn: Circles.instance.pluginOnIn(s.channel, p.id));
  }

  /// The action that opens the pads for the call there is.
  static PluginAction _open() => PluginAction(label: 'Soundboard', icon: Lucide.megaphone, run: (host) => host.present((context) => SoundboardScreen(space: Voice.instance.session?.channel)));

  @override
  List<SlotFill> get slots => [
        // In the space's header while in its call, and in every call's menu.
        Slots.spaceHeader.fill((place, prefs) => place.voice && place.inCall ? [_open()] : const []),
        Slots.callControls.fill((place, prefs) => [_open()]),
        Slots.callBanner.fill((context, place, prefs) => const [SoundPlayedLine()]),
      ];
}

/// The line over the call for a moment after a sound: who played it, and which.
class SoundPlayedLine extends StatelessWidget {
  const SoundPlayedLine({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Soundboard.instance,
      builder: (context, _) {
        final t = context.tokens;
        final p = Soundboard.instance.last;
        if (p == null) return const SizedBox.shrink();
        final who = p.by == 'me' ? 'You' : Voice.instance.nameOf(p.by);
        final unheard = p.by != 'me' && Soundboard.instance.quiet;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            key: const ValueKey('sound-played'),
            margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
            decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(p.sound.emoji, style: pageText(t, t.fontSize('sm'))),
              SizedBox(width: t.space(2)),
              Flexible(
                child: Semantics(
                  liveRegion: true,
                  child: Text('$who played ${p.sound.name}${unheard ? ' (muted here)' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF))),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}
