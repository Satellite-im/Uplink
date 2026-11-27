/// The Plugins page's head (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page with a
/// marketplace like look how ghostmd has"): a band in colour, its name and what plugins are, how many there are and
/// how many are added, with the plugins' tiles scattered at its end, as Ghost.md's Market opens. Its colours are four
/// of Settings' hues, so each look settles them (Lamplight's band is its amber, Mist's turns teal); under Dial-Up it
/// is a window of the era instead, its tiles a row of toolbar buttons.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_type.dart';
import '../../plugins/plugin.dart';
import '../dialup/bevel.dart';
import '../dialup/title_bar.dart';
import 'plugin_art.dart';

/// The hues the band runs through, top start to bottom end (Ghost.md's Market band, by name rather than hex).
const List<String> bandHues = ['indigo', 'purple', 'rose', 'orange'];

/// The band itself, at the top of the page's list.
class PluginsBand extends StatelessWidget {
  const PluginsBand({super.key, required this.plugins, required this.added, required this.line, required this.wide, this.compact = false});

  /// Every plugin, the featured ones first: the first few float on the band.
  final List<GhostPlugin> plugins;
  final int added;

  /// What plugins are, in a line.
  final String line;
  final bool wide;

  /// The short band of Settings' list, which leads here: no line, the count as its second line.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final count = '${plugins.length} ${plugins.length == 1 ? 'plugin' : 'plugins'} · $added added';
    if (isBevelChrome(t)) return _window(context, t, count);
    final stops = [for (final hue in bandHues) PluginHues.of(t, hue)];
    final colours = [for (final c in stops) c.start];
    final first = stops.first;
    // White on the band in every look, as on the cards (Matt, 2026-11-17: "make the text on the cards white not black").
    const on = Color(0xFFFFFFFF);
    final radius = pluginCorner(t, t.radius('lg') * (compact ? 1.2 : 1.6));
    final height = compact ? t.lenOf('5.5rem') : (wide ? t.lenOf('12rem') : t.lenOf('11rem'));
    final tiles = plugins.take(compact ? 3 : (wide ? 7 : 4)).toList();
    // Where each tile sits inside the band's padding, as a share of the room left round it (0 at the end and the top,
    // 1 at the start and the bottom of the tiles' corner), its size in rem and its turn. Laid out so no two meet
    // and none touches the band's edge, as Market's float clear: they had sat on its top and end, one over another.
    const four = [(0.0, 0.0, 3.6, -0.10), (1.0, 0.25, 3.0, 0.08), (0.15, 1.0, 2.6, 0.12), (0.62, 1.0, 2.4, 0.06)];
    const seven = [(0.0, 0.0, 3.6, -0.10), (0.35, 0.5, 3.0, 0.08), (0.2, 1.0, 2.6, 0.12), (0.5, 0.0, 2.4, 0.06), (0.95, 0.5, 2.2, -0.10), (0.65, 1.0, 2.6, -0.04), (1.0, 0.0, 2.0, 0.10)];
    const small = [(0.0, 0.0, 2.6, -0.10), (0.5, 1.0, 2.2, 0.10), (1.0, 0.1, 2.0, -0.06)];
    final pad = t.space(compact ? 4 : (wide ? 6 : 5));
    return ClipRRect(
      key: const ValueKey('plugins-band'),
      borderRadius: BorderRadius.circular(radius),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: colours, stops: const [0, 0.38, 0.72, 1])),
          child: LayoutBuilder(
            builder: (context, box) {
              final across = compact ? math.min(box.maxWidth * 0.36, t.lenOf('9rem')) : (wide ? math.min(box.maxWidth * 0.4, 420.0) : box.maxWidth * 0.42);
              final where = compact ? small : (wide ? seven : four);
              final end = compact ? t.space(8) : 0.0;
              // The tiles' corner: from the band's end padding across [across], and from its top padding to its bottom's.
              final roomW = math.max(0.0, across - pad), roomH = math.max(0.0, height - pad * 2);
              return Stack(
                children: [
                  Positioned.fill(child: hueGlow(first, radius: radius)),
                  for (var i = 0; i < tiles.length; i++)
                    Builder(builder: (context) {
                      final size = t.lenOf('${where[i].$3}rem');
                      return PositionedDirectional(
                        end: end + pad + where[i].$1 * math.max(0.0, roomW - size),
                        top: pad + where[i].$2 * math.max(0.0, roomH - size),
                        child: Transform.rotate(angle: where[i].$4, child: PluginTile(plugin: tiles[i], size: size, shadow: true)),
                      );
                    }),
                  Container(
                    width: box.maxWidth,
                    alignment: AlignmentDirectional.bottomStart,
                    padding: EdgeInsets.all(pad),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: height - pad * 2, maxWidth: math.max(0, box.maxWidth - across - pad - (compact ? t.space(8) : 0))),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.end,
                        children: [
                          // The Marketplace's own band since plugins left Settings for it (Matt, 2026-11-20: "Move plugins out of
                          // settings into a marketplace button on the navigation rail with a marketplace icon").
                          Text('Marketplace', style: pageText(t, t.fontSize(compact ? 'xl' : (wide ? '3xl' : '2xl')), weight: 'bold', color: on)),
                          if (!compact) ...[
                            SizedBox(height: t.space(1)),
                            Text(line, maxLines: 4, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize(wide ? 'md' : 'sm'), height: 1.35, color: on.withValues(alpha: 0.92))),
                            SizedBox(height: t.space(3)),
                          ] else
                            SizedBox(height: t.lenOf('0.1rem')),
                          Text(count, key: const ValueKey('plugins-band-count'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize(compact ? 'sm' : 'xs'), weight: 'semibold', color: on.withValues(alpha: 0.82))),
                        ],
                      ),
                    ),
                  ),
                  if (compact) PositionedDirectional(end: t.space(3), top: 0, bottom: 0, child: Center(child: AppIcon(Lucide.chevronRight, size: 20, strokeWidth: 2.2, color: on, wash: false))),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Dial-Up's: a raised window, its name on a title bar, and on its silver a row of the plugins' toolbar buttons with
  /// the line and the count beside them.
  Widget _window(BuildContext context, Tokens t, String count) {
    final c = DialupColors.of(t);
    final tiles = plugins.take(compact ? 4 : (wide ? 8 : 6)).toList();
    return Bevel(
      key: const ValueKey('plugins-band'),
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The Marketplace's window, its ring's own mark on its title bar (it was "Built-in extras" while every plugin
          // was the app's own).
          TitleBar(title: 'Marketplace', subtitle: compact ? count : null, leading: AppIcon(Lucide.store, size: 16, strokeWidth: 2.2, color: c.titlebarInk, wash: false)),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  Text(line, style: pageText(t, 15, height: 1.35, color: c.onChrome)),
                  const SizedBox(height: 10),
                ],
                Row(children: [
                  for (final p in tiles) Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: PluginTile(plugin: p, size: 36)),
                  const Spacer(),
                ]),
                if (!compact) ...[
                  const SizedBox(height: 8),
                  Text(count, key: const ValueKey('plugins-band-count'), style: pageText(t, 13, color: c.onChrome)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
