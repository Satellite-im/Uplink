/// The Link previews plugin's cards for the links in a message (lib/plugins/embeds.dart), for any chat that draws
/// them under its messages: a chat on another network (lib/ui/inbox_ui.dart) and a space's (lib/ui/hangout_screen.dart;
/// Matt, 2026-11-25: "klippy links to gifs are not expanding into gif previews": a space's chat drew no card for any
/// link). Nothing while the plugin is off on this device, and only the known services' links where "other sites" is
/// off, as in a conversation of texts.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../links.dart';
import '../plugins/embeds.dart';
import '../plugins/registry.dart';

/// The cards for the links in [text], two at most; none for a link [skip] says is drawn some other way.
List<Widget> linkCardsUnder(BuildContext context, String text, {bool Function(String url)? skip}) {
  if (text.isEmpty || !text.contains('://')) return const [];
  final registry = PluginRegistry.instance;
  final plugin = registry.plugins.whereType<EmbedsPlugin>().firstOrNull;
  if (plugin == null) return const [];
  final app = AppState.maybeOf(context);
  if (app == null) return const [];
  final store = AppStore(app);
  if (!registry.isOn(plugin, store)) return const [];
  final others = registry.prefsOf(plugin, store).flag('others');
  final links = MessageLink.find(text).map((l) => l.address).where((u) => skip == null || !skip(u)).toSet().take(2);
  final t = context.tokens;
  return [for (final url in links) Padding(padding: EdgeInsets.only(top: t.space(1)), child: EmbedCard(key: ValueKey('embed-$url'), url: url, others: others))];
}
