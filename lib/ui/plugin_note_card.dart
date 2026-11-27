/// A plugin's note in a space's chat drawn as its card (Matt, 2026-11-19: "use icons for starting and stopping recording
/// and allow plugins to render messages like these as cards with iconography and details"): the plugin's icon on its
/// colour (on red for something going on now), a title, a line under it, and facts in a row, each with its icon.
///
/// The note is lib/voice/plugin_note.dart; what a plugin draws for it is GhostPlugin.card. A note no plugin here draws
/// is shown as its words.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../plugins/plugin.dart';
import '../plugins/registry.dart';
import '../voice/hangout.dart';
import 'plugins_page/plugin_art.dart' show PluginHues;

/// The card [m]'s plugin draws for it, and the plugin; null where it has no note, or no plugin here draws it.
({PluginChatCard card, GhostPlugin plugin})? pluginCardOf(HangoutMessage m, {required bool mine, PluginRegistry? registry}) {
  final note = m.note;
  if (note == null) return null;
  // A plugin that ships with the app draws its card where the registry has none of them too (the browser's page starts
  // with an empty one, and showed the words with their emoji, GMFB-43): a card is how a note looks, not a feature.
  final plugin = (registry ?? PluginRegistry.instance).plugins.where((p) => p.id == note.plugin).firstOrNull ??
      (registry == null ? shippedPlugins.where((p) => p.id == note.plugin).firstOrNull : null);
  if (plugin == null) return null;
  try {
    final card = plugin.card(note, mine: mine);
    return card == null ? null : (card: card, plugin: plugin);
  } catch (_) {
    return null;
  }
}

/// The icon drawn in place of the emoji at the head of Record call's line, and the words after it; null for any other
/// words (GMFB-43). The same icons as its card and the recording bar: the record dot, in red, and the stop.
({LucideIcon icon, bool red, String words})? recordingWordsOf(String text) {
  final line = PluginChatNote.recordingLine(text);
  if (line == null) return null;
  return (icon: line.started ? Lucide.circleDot : Lucide.circleStop, red: line.started, words: line.words);
}

/// [icon] as a span at the head of a run of words in [style], with a gap after it: Record call's dot or stop where its
/// emoji was (GMFB-43).
InlineSpan noteIconSpan(Tokens t, ({LucideIcon icon, bool red, String words}) mark, TextStyle style) => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 5),
        child: AppIcon(mark.icon, key: ValueKey(mark.red ? 'note-icon-started' : 'note-icon-stopped'), size: (style.fontSize ?? 14) * 1.05, color: mark.red ? t.danger : style.color),
      ),
    );

/// [text] in a line or two where a message's words are shown short (a quote, the bar over the box while answering):
/// Record call's line with its icon in place of the emoji (GMFB-43), any other words as they are.
class NoteWords extends StatelessWidget {
  const NoteWords(this.text, {super.key, required this.style, this.maxLines = 1});
  final String text;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final mark = recordingWordsOf(text);
    if (mark == null) return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
    return Text.rich(TextSpan(children: [noteIconSpan(context.tokens, mark, style), TextSpan(text: mark.words)]), maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
  }
}

/// [card] drawn in the chat for [plugin], no wider than [maxWidth].
class PluginChatCardView extends StatelessWidget {
  const PluginChatCardView({super.key, required this.card, required this.plugin, this.maxWidth = 360, this.ground, this.ink});
  final PluginChatCard card;
  final GhostPlugin plugin;
  final double maxWidth;

  /// The card's ground and words, where the chat's look says (an era's paper); the page's otherwise.
  final Color? ground, ink;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hues = PluginHues.of(t, card.hue ?? plugin.hue);
    final red = t.danger;
    final ink = this.ink ?? t.color('app-ink');
    final soft = this.ink?.withValues(alpha: 0.7) ?? t.color('app-ink-2');
    final disc = t.lenOf('2.25rem');
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        key: ValueKey('plugin-card-${plugin.id}'),
        padding: EdgeInsets.all(t.space(3)),
        decoration: BoxDecoration(
          color: ground ?? t.color('app-paper-2'),
          borderRadius: BorderRadius.circular(t.lenOf('0.9rem')),
          border: Border.all(color: t.color('app-rule')),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: disc,
            height: disc,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: card.alert ? red : hues.wash),
            child: AppIcon(card.icon, size: 18, color: card.alert ? const Color(0xFFFFFFFF) : hues.accent),
          ),
          SizedBox(width: t.space(3)),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(card.title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink, height: 1.3)),
              if (card.detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(card.detail, style: pageText(t, t.fontSize('sm'), color: soft, height: 1.35)),
              ],
              if (card.facts.isNotEmpty) ...[
                SizedBox(height: t.space(2)),
                Wrap(spacing: t.space(3), runSpacing: t.space(1), children: [
                  for (final (icon, words) in card.facts)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon(icon, size: 14, color: soft),
                      SizedBox(width: t.space(1)),
                      Flexible(child: Text(words, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: soft))),
                    ]),
                ]),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
