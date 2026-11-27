/// Voice changer: a voice message sent in another voice, by ElevenLabs (Matt, 2026-11-20: "build it as a plugin"), and
/// since 2026-11-21 a call's voice changed as it is said, on this device or by ElevenLabs
/// (lib/voice/live_changer.dart). The work is lib/voice/voice_changer.dart's; its pages are
/// lib/ui/voice_changer_ui.dart. This is the switch, the rows of its own section in Settings, and the line over a call.
///
/// For this device alone: it is a person's own key and their own voice. Off until added, and nothing leaves the device
/// for ElevenLabs until a key is pasted and a voice chosen; a call's voice made on the device never leaves it.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../ui/voice_changer_ui.dart';
import '../voice/channels.dart';
import '../voice/voice_changer.dart';
import 'plugin.dart';
import 'registry.dart';

/// The plugin: what the Marketplace says of it, its page in Settings, and the line over a call while the voice is
/// changed live.
class VoiceChangerPlugin extends GhostPlugin {
  const VoiceChangerPlugin();

  static const pluginId = 'voicechanger';

  @override
  String get id => pluginId;

  @override
  String get name => 'Voice changer';

  @override
  String get description => 'Sound like someone else in calls, instantly: deeper, higher, a robot and more, made on your device. And send voice messages in a realistic voice with ElevenLabs.';

  @override
  LucideIcon get icon => Lucide.audioLines;

  @override
  bool get onByDefault => false;

  @override
  String get tagline => 'Your voice messages, in another voice, said the way you said them.';

  @override
  String get pitch => 'Record a voice message and send it in another voice, said just the way you said it. With your own ElevenLabs key.';

  @override
  List<String> get adds => const ['A voice of your choosing for the voice messages you send in spaces and chats', 'Every voice in your ElevenLabs account to choose from, with a sample of each', 'A switch to go back to your own voice for a while'];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.mic, 'Each voice message you record, sent to ElevenLabs', 'Only while this is on and a voice is chosen. The recording goes from this device to ElevenLabs to be changed, so that message\'s sound is not private to you and who you send it to.'),
        PluginReach(Lucide.keyRound, 'Your ElevenLabs API key', 'Kept on this device in a file only you can read. Using it costs what your ElevenLabs plan charges.'),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'indigo',
        intro: 'Your voice in calls, changed on this device as you speak; and voice messages in another voice, by ElevenLabs.',
        summary: (prefs) {
          final c = VoiceChanger.instance;
          if (!c.hasKey) return 'Add your ElevenLabs key';
          if (c.voice == null) return 'Choose a voice';
          return c.paused ? 'Your own voice for now' : 'As ${c.voice!.name}';
        },
      );

  /// Whether it is added on this device.
  static bool isOn() {
    final app = Voice.instance.app;
    if (app == null) return false;
    final reg = PluginRegistry.instance;
    final p = reg.plugins.whereType<VoiceChangerPlugin>().firstOrNull;
    return p != null && reg.isOn(p, AppStore(app));
  }

  @override
  List<SlotFill> get slots => [
        // Over the call while one's voice is changed live in it.
        Slots.callBanner.fill((context, place, prefs) => const [LiveChangerLine()]),
        Slots.settings.fill((context, place, prefs) => const [VoiceChangerLiveRow(), VoiceChangerCallWayRow(), VoiceChangerEffectRow(), VoiceChangerKeyRow(), VoiceChangerVoiceRow(), VoiceChangerOnRow(), VoiceChangerCleanRow(), VoiceChangerForgetRow()]),
      ];
}
