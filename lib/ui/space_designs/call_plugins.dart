/// The plugins' places in a call (Matt, 2026-11-19: "what are some plugins we could add to integrate with circles? I'd
/// like to have a "record call" plugin"): what a call's menu offers of theirs (Slots.callControls) and what they put
/// over the call's page (Slots.callBanner).
///
/// In a circle's space a plugin a circle may hold is on as the circle says (CircleManifest.pluginOn), not as this
/// device's switch (Matt, 2026-11-19: "Some plugins should be serverside / cirlce side as well").
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../circles/circles.dart';
import '../../plugins/plugin.dart';
import '../../plugins/registry.dart';
import '../../voice/channels.dart';
import '../../voice/voice.dart';
import '../common.dart';

/// One thing a plugin offers in a call's menu, as the call's page draws it.
@immutable
class SpaceExtra {
  const SpaceExtra({required this.label, required this.icon, required this.run, this.danger = false, this.builtIn = false, this.hint});
  final String label;

  /// The line under it in the call's menu, where it is not the screen's or a plugin's.
  final String? hint;
  final LucideIcon icon;
  final void Function(BuildContext context) run;
  final bool danger;

  /// The app's own (Share screen), not a plugin's: where plugins' rows are marked, it is not.
  final bool builtIn;
}

/// What the plugins have for the call [Voice] is in and for a space's header, asked of the registry afresh each time.
abstract final class CallPlugins {
  /// The call [Voice] is in, as a plugin is shown it.
  static CallPlace? place() {
    final v = Voice.instance;
    final s = v.session;
    if (s == null) return null;
    return CallPlace(
      space: s.channel.seed,
      spaceName: s.channel.name,
      circle: s.channel.circle,
      people: [
        CallPerson(id: 'me', name: s.name.isEmpty ? 'You' : s.name, me: true, muted: s.muted || s.deafened),
        for (final m in s.members.values)
          if (m.id != s.bridgeId) CallPerson(id: m.id, name: v.nameOf(m.id), muted: m.muted),
      ],
    );
  }

  /// Whether plugin `id` is on in [c] as its circle says, in the shape the registry asks for.
  static bool? Function(String id) _circleOn(VoiceChannel c) => (id) => Circles.instance.pluginOnIn(c, id);

  /// What the plugins that are on in this call have for its menu.
  static List<SpaceExtra> extras() {
    final v = Voice.instance;
    final s = v.session;
    final app = v.app;
    final place = CallPlugins.place();
    if (s == null || app == null || place == null) return const [];
    final reg = PluginRegistry.instance;
    return [
      for (final b in reg.actionsIn(Slots.callControls, place, AppStore(app), inCircle: s.channel.circle != null, circleOn: _circleOn(s.channel)))
        SpaceExtra(label: b.action.label, icon: b.action.icon, danger: b.action.danger, run: (context) => b.action.run(_CallHost(reg, b.plugin, context))),
    ];
  }

  /// What the plugins that are on in [c] put in its header (Slots.spaceHeader): in a circle's space as the circle says.
  static List<SpaceExtra> header(VoiceChannel c) {
    final v = Voice.instance;
    final app = v.app;
    if (app == null) return const [];
    final place = SpacePlace(space: c.seed, spaceName: c.name, circle: c.circle, voice: c.hasVoice, inCall: v.session?.channel.room == c.room);
    final reg = PluginRegistry.instance;
    return [
      for (final b in reg.actionsIn(Slots.spaceHeader, place, AppStore(app), inCircle: c.circle != null, circleOn: _circleOn(c)))
        SpaceExtra(label: b.action.label, icon: b.action.icon, danger: b.action.danger, run: (context) => b.action.run(_CallHost(reg, b.plugin, context))),
    ];
  }

  /// What the plugins that are on in this call put over its page.
  static List<Widget> banners(BuildContext context) {
    final v = Voice.instance;
    final s = v.session;
    final place = CallPlugins.place();
    if (s == null || place == null) return const [];
    return PluginRegistry.instance.widgetsIn(Slots.callBanner, context, place, AppStore(AppState.of(context)), inCircle: s.channel.circle != null, circleOn: _circleOn(s.channel));
  }
}

/// What a plugin's action in a call is handed: it can say, copy and show a page; a call has no conversation to open.
class _CallHost implements PluginHost {
  _CallHost(this.registry, this.plugin, this.context);
  final PluginRegistry registry;
  final GhostPlugin plugin;
  final BuildContext context;

  @override
  PluginPrefs get prefs => registry.prefsOf(plugin, AppStore(AppState.of(context)));

  @override
  void say(String words) {
    if (context.mounted) toast(context, words);
  }

  @override
  void copy(String text, {String? say}) {
    Clipboard.setData(ClipboardData(text: text));
    if (say != null) this.say(say);
  }

  @override
  void present(WidgetBuilder page) {
    if (context.mounted) push(context, page);
  }

  // The rest act on a conversation, which a call has none of: they do nothing here.
  @override
  void open(int thread) {}
  @override
  Future<void> markRead(int thread) async {}
  @override
  void move(int thread, String? section) {}
  @override
  void write(String text) {}
  @override
  Future<void> deleteThread(int thread) async {}
  @override
  Future<void> reload() async {}
}
