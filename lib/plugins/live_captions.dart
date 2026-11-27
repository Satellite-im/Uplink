/// Live captions: a call's words shown as they are said, each person's written out on their own device and named;
/// translated into this device's language where Translate is added (Matt, 2026-11-19: "Live captions"). The work is
/// lib/voice/captions.dart's; this puts the switch in a call's menu and the captions over the call.
///
/// A plugin a whole circle can hold: in a circle's spaces it is there when the circle has it on, for everyone.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../voice/captions.dart';
import '../voice/channels.dart';
import 'plugin.dart';
import 'registry.dart';
import 'translate.dart';
import 'translate_host.dart';

class LiveCaptionsPlugin extends GhostPlugin {
  const LiveCaptionsPlugin();

  @override
  String get id => 'captions';

  @override
  String get name => 'Live captions';

  @override
  String get description => 'A call\'s words shown as they are said, each written out on its speaker\'s own device and named.';

  @override
  LucideIcon get icon => Lucide.text;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'cyan';

  @override
  String get tagline => 'Everyone\'s words, named, as they are said.';

  @override
  String get pitch => 'Captions in calls, written out on each speaker\'s own device; translated where Translate is added.';

  @override
  List<String> get adds => const ['Captions on or off in a call\'s menu', 'Everyone\'s words over the call, named', 'Translated into your language where Translate is added'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.mic, 'Your voice, written out on this device', 'Only while someone in the call wants captions; only the words are sent, sealed, to the call.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  @override
  List<SlotFill> get slots => [
        Slots.callControls.fill((place, prefs) {
          if (!CallCaptions.supported) return const [];
          final on = CallCaptions.instance.on;
          return [
            PluginAction(label: on ? 'Hide captions' : 'Show captions', icon: Lucide.text, run: (host) => CallCaptions.instance.setOn(!on)),
          ];
        }),
        Slots.callBanner.fill((context, place, prefs) {
          CallCaptions.translate = _translate;
          return [if (CallCaptions.instance.on) const CaptionsPanel()];
        }),
      ];
}

/// Someone's line in this device's language, where Translate is added here: by the device's own translation, into the
/// language Translate is set to; null where it is not added, or the line needs nothing.
Future<String?> _translate(String words) async {
  final app = Voice.instance.app;
  if (app == null) return null;
  final reg = PluginRegistry.instance;
  final tp = reg.plugins.whereType<TranslatePlugin>().firstOrNull;
  if (tp == null || !reg.isOn(tp, AppStore(app))) return null;
  const host = DeviceTextHost();
  if (!host.canTranslate) return null;
  final prefs = reg.prefsOf(tp, AppStore(app));
  final answer = await host.translate(words, to: TranslatePlugin.targetOf(prefs, host), known: TranslatePlugin.knownOf(prefs), wifiOnly: prefs.flag('wifi'));
  final said = (answer.text ?? '').trim();
  return answer.state == 'done' && said.isNotEmpty && said != words ? said : null;
}

/// The newest lines of the call, each with who said it; a line still being said a little fainter.
class CaptionsPanel extends StatelessWidget {
  const CaptionsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CallCaptions.instance,
      builder: (context, _) {
        final t = context.tokens;
        final shown = CallCaptions.instance.shown;
        if (shown.isEmpty) return const SizedBox.shrink();
        return Container(
          key: const ValueKey('captions'),
          margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
          decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(t.radius('lg'))),
          child: Semantics(
            liveRegion: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              for (final l in shown)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: t.space(1) / 2),
                  child: Opacity(
                    opacity: l.done ? 1 : 0.75,
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${l.from == 'me' ? 'You' : Voice.instance.nameOf(l.from)}  ', style: pageText(t, t.fontSize('sm'), weight: 'bold', color: const Color(0xFFFFE08A))),
                        TextSpan(text: l.shown ?? l.words, style: pageText(t, t.fontSize('sm'), color: const Color(0xFFFFFFFF))),
                      ]),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ]),
          ),
        );
      },
    );
  }
}
