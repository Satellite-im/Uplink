/// A plugin on the Plugins page's shelves (Matt, 2026-11-17: "redo how the plugins look with their own dedicated
/// plugins page with a marketplace like look how ghostmd has"), after Ghost.md's Market cards: a row card on a phone,
/// a card with a coloured head standing in a grid with room, and a featured card that is all colour. Each says Add,
/// or that it is added, and opens the plugin's page when pressed.
///
/// A plugin from another developer (Matt, 2026-11-20: "I would like users to be able to develop and submit their own
/// plugins to our plugin marketplace") says so on its card: who made it, and that it was reviewed, or that it is in
/// development and wasn't, or that it was withdrawn or doesn't run; and its first two tags.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_type.dart';
import '../../market/listing_plugin.dart' show StuckPackPlugin;
import '../../plugins/pack/pack.dart' show packLabels;
import '../../plugins/plugin.dart';
import '../dialup/bevel.dart';
import '../dialup/title_bar.dart';
import 'market_parts.dart';
import 'plugin_art.dart';
import '../../l10n/words.dart';

/// Add, or that it is added: the end of a plugin's card. [onColour] is on the plugin's own colour (the featured card).
/// [onAdd] null draws Add that can't be pressed (a listing this device can't take, its page says why); [adding] says
/// a listing is on its way. A store pack that doesn't run has nothing here: its page has Remove.
Widget addOrAdded(BuildContext context, GhostPlugin plugin, {required bool added, required VoidCallback? onAdd, bool onColour = false, bool adding = false}) {
  final t = context.tokens;
  final c = PluginHues.of(t, plugin.hue);
  if (plugin is StuckPackPlugin) return const SizedBox.shrink();
  if (added) return MarketAdded(key: ValueKey('plugins-added-${plugin.id}'), name: plugin.name, color: onColour && !isBevelChrome(t) ? c.on : null);
  if (adding) return MarketButton(key: ValueKey('plugins-adding-${plugin.id}'), label: 'Adding…', look: onColour ? MarketButtonLook.glass : MarketButtonLook.filled, color: c.start, onColor: c.on, onPress: null);
  return MarketButton(
    key: ValueKey('plugins-add-${plugin.id}'),
    label: 'Add',
    semantics: 'Add ${plugin.name}',
    icon: Lucide.plus,
    look: onColour ? MarketButtonLook.glass : MarketButtonLook.filled,
    color: c.start,
    onColor: c.on,
    onPress: onAdd,
  );
}

/// The words of a stuck pack's mark: withdrawn by review, or not working for any other reason.
String stuckWord(StuckPackPlugin p) => p.problem == 'revoked' ? 'Withdrawn' : 'Not working';

/// Where a plugin from another developer comes from, small, under its name: "By @maya" and its mark (Reviewed, In
/// development, Withdrawn or Not working), and with [labels] its first two tags after them. Null for a built-in.
Widget? pluginSourceLine(BuildContext context, GhostPlugin plugin, {bool labels = false, Color? ink}) {
  if (plugin.source == PluginSource.builtIn) return null;
  final t = context.tokens;
  final bevel = isBevelChrome(t);
  final soft = ink ?? (bevel ? DialupColors.of(t).onChrome : t.color('app-ink-3'));
  final style = pageText(t, t.fontSize('xs'), weight: 'medium', color: soft);
  final dev = plugin.developer;
  final mark = switch (plugin) {
    StuckPackPlugin() => MarketTag(key: ValueKey('plugins-problem-${plugin.id}'), label: stuckWord(plugin)),
    _ when plugin.source == PluginSource.dev => MarketTag(key: ValueKey('plugins-dev-${plugin.id}'), label: 'In development'),
    _ => Row(
        key: ValueKey('plugins-reviewed-${plugin.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(LucideMore.badgeCheck, size: 13, strokeWidth: 2.2, color: soft, wash: false),
          SizedBox(width: t.lenOf('0.2rem')),
          Tr('Reviewed', style: style),
        ],
      ),
  };
  return Wrap(
    spacing: t.space(2),
    runSpacing: t.space(1),
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (dev != null) Text('By @$dev', maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      mark,
      if (labels)
        for (final l in plugin.labels.take(2)) Text(packLabels[l] ?? l, style: style),
    ],
  );
}

/// A plugin from another developer's first two tags as small tags of their own: a grid card's, under its line (a
/// built-in's tags are for search alone).
Widget? pluginLabelTags(BuildContext context, GhostPlugin plugin) {
  if (plugin.labels.isEmpty || plugin.source == PluginSource.builtIn) return null;
  final t = context.tokens;
  return Wrap(spacing: t.space(1), runSpacing: t.space(1), children: [for (final l in plugin.labels.take(2)) MarketTag(label: packLabels[l] ?? l)]);
}

/// One plugin on a shelf: its tile, its name, its line, and Add or that it is added; pressed, its page. [wide] is a
/// card standing in a grid, its colour across its head; otherwise a row, a phone's, its tile at its start.
class PluginCard extends StatelessWidget {
  const PluginCard({super.key, required this.plugin, required this.added, required this.onAdd, required this.onOpen, this.wide = false, this.selected = false, this.adding = false});

  final GhostPlugin plugin;
  final bool added;

  /// Null where it can't be added here: Add is drawn, and can't be pressed.
  final VoidCallback? onAdd;
  final VoidCallback onOpen;
  final bool wide;

  /// A listing on its way: "Adding…".
  final bool adding;

  /// Its page is the one open beside the shelves.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final ink = bevel ? DialupColors.of(t).onChrome : t.color('app-ink');
    final soft = bevel ? DialupColors.of(t).onChrome : t.color('app-ink-2');
    final name = Text(plugin.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: bevel ? 'bold' : 'semibold', color: ink));
    final line = Text(plugin.tagline, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), height: 1.35, color: soft));
    final end = addOrAdded(context, plugin, added: added, onAdd: onAdd, adding: adding);
    if (!wide || bevel) {
      // A row card's source line has its tags after it, where a grid card has them under its line.
      final from = pluginSourceLine(context, plugin, labels: true);
      return MarketCard(
        key: ValueKey('plugins-card-${plugin.id}'),
        onPress: onOpen,
        label: plugin.name,
        selected: selected,
        padding: EdgeInsets.all(t.space(3)),
        child: Row(
          children: [
            PluginTile(plugin: plugin, size: t.lenOf('3.2rem')),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [name, if (from != null) ...[SizedBox(height: t.lenOf('0.1rem')), from], SizedBox(height: t.lenOf('0.15rem')), line],
              ),
            ),
            SizedBox(width: t.space(2)),
            end,
          ],
        ),
      );
    }
    final c = PluginHues.of(t, plugin.hue);
    final head = t.lenOf('5rem');
    final from = pluginSourceLine(context, plugin);
    final tags = pluginLabelTags(context, plugin);
    final symbol = pluginSymbol(plugin, head * 0.42, c.on);
    return MarketCard(
      key: ValueKey('plugins-card-${plugin.id}'),
      onPress: onOpen,
      label: plugin.name,
      selected: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The head: the plugin's colour edge to edge, its icon large and faint past the end, and its shelf on it.
          SizedBox(
            height: head,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: c.gradient),
              child: Stack(
                clipBehavior: Clip.hardEdge,
                fit: StackFit.expand,
                children: [
                  hueGlow(c, radius: 0),
                  // Faint, and mostly past the head's bottom end, clear of its tag.
                  PositionedDirectional(end: -head * 0.3, bottom: -head * 0.45, child: AppIcon(plugin.icon, size: head * 1.15, strokeWidth: 1.6, color: c.faint, wash: false)),
                  PositionedDirectional(
                    start: t.space(3),
                    bottom: t.space(3),
                    child: plugin.iconPng == null ? symbol : ClipRRect(borderRadius: BorderRadius.circular(pluginCorner(t, head * 0.12)), child: pluginPicture(plugin, head * 0.42, symbol: symbol)),
                  ),
                  PositionedDirectional(top: t.space(2), end: t.space(2), child: MarketTag(label: plugin.shelf.label, ground: c.tag, ink: c.on, ring: c.tagRing)),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(t.space(3)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  name,
                  if (from != null) ...[SizedBox(height: t.lenOf('0.1rem')), from],
                  SizedBox(height: t.lenOf('0.15rem')),
                  line,
                  if (tags != null) ...[SizedBox(height: t.space(2)), tags],
                  SizedBox(height: t.space(3)),
                  const Spacer(),
                  Align(alignment: AlignmentDirectional.centerEnd, child: end),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A plugin at the head of the page: the whole card in its colour, its icon large and faint, its name and line on it,
/// and Add on glass. Under Dial-Up, a small window of its own: its name on a title bar, its line on the silver.
class FeaturedPluginCard extends StatelessWidget {
  const FeaturedPluginCard({super.key, required this.plugin, required this.added, required this.onAdd, required this.onOpen});

  final GhostPlugin plugin;
  final bool added;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return _window(context, t);
    final c = PluginHues.of(t, plugin.hue);
    final radius = pluginCorner(t, t.radius('lg') * 1.5);
    return GlacierPressable(
      key: ValueKey('plugins-featured-${plugin.id}'),
      onPressed: onOpen,
      semanticLabel: plugin.name,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: radius,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 140),
          scale: state.pressed ? 0.98 : 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: c.gradient),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  hueGlow(c, radius: radius),
                  // Faint, in the empty middle of the card's end and half past it: under the shelf's tag it made the
                  // tag hard to read, and low down it ran under Add.
                  PositionedDirectional(end: -t.space(8), top: t.space(12), child: AppIcon(plugin.icon, size: t.lenOf('6rem'), strokeWidth: 1.5, color: c.faint, wash: false)),
                  Padding(
                    padding: EdgeInsets.all(t.space(4)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          GlassChip(plugin: plugin, size: t.lenOf('2.6rem')),
                          const Spacer(),
                          MarketTag(label: plugin.shelf.label, ground: c.tag, ink: c.on, ring: c.tagRing),
                        ]),
                        const Spacer(),
                        Text(plugin.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xl'), weight: 'bold', color: c.on)),
                        SizedBox(height: t.lenOf('0.1rem')),
                        // Its pitch, written to be whole in three lines (four where three cards share a narrowed shelf): the tagline cut off mid-word hid what it does.
                        Text(plugin.pitch, maxLines: 4, overflow: TextOverflow.fade, style: pageText(t, t.fontSize('sm'), height: 1.3, color: c.on.withValues(alpha: 0.92))),
                        SizedBox(height: t.space(3)),
                        Align(alignment: AlignmentDirectional.centerEnd, child: addOrAdded(context, plugin, added: added, onAdd: onAdd, onColour: true)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Dial-Up's featured card: a small window, the plugin's name on its title bar.
  Widget _window(BuildContext context, Tokens t) {
    final c = DialupColors.of(t);
    return GlacierPressable(
      key: ValueKey('plugins-featured-${plugin.id}'),
      onPressed: onOpen,
      semanticLabel: plugin.name,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: 0,
        child: Bevel(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TitleBar(title: plugin.name, leading: AppIcon(plugin.icon, size: 16, strokeWidth: 2.2, color: c.titlebarInk, wash: false)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        PluginTile(plugin: plugin, size: 40),
                        const SizedBox(width: 10),
                        Expanded(child: Text(plugin.shelf.label, style: pageText(t, 13, color: c.onChrome))),
                      ]),
                      const SizedBox(height: 8),
                      Expanded(child: Text(plugin.pitch, maxLines: 3, overflow: TextOverflow.fade, style: pageText(t, 14, height: 1.3, color: c.onChrome))),
                      Align(alignment: AlignmentDirectional.centerEnd, child: addOrAdded(context, plugin, added: added, onAdd: onAdd)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
