/// The Plugins page's colour (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page with a
/// marketplace like look how ghostmd has"): each plugin's tile, card head and page wear its hue, read from the tokens
/// as Settings' own section colours are (`[data-hue]`, lib/kit/settings_css.dart), so every look settles them as it
/// settles those (assets/css/app.css: Mist's teal, Lamplight's amber, Dial-Up's ink). Ghost.md's
/// Market (its lib/market/) wrote its gradients and its white glass in hex; here nothing is: the words on a colour
/// are the page's own paper or ink, whichever reads better on it.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../me/me.dart' as me;
import '../../plugins/networks.dart';
import '../../plugins/plugin.dart';
import '../me.dart' show NetworkMark;
import '../dialup/bevel.dart';

/// A hue's colours as the page draws them, from tokens that carry it (`t.child(attrs: {'hue': …})`).
@immutable
class PluginHues {
  const PluginHues._({required this.start, required this.end, required this.on, required this.accent, required this.wash, required this.light, required this.dark});

  /// The colours of [hue] under [t] (the page's tokens), kept per tokens and hue.
  factory PluginHues.of(Tokens t, String hue) {
    final kept = _kept[t] ??= {};
    return kept[hue] ??= PluginHues._read(t.child(attrs: {'hue': hue}));
  }

  factory PluginHues._read(Tokens t) {
    final hue = t.colorOf('var(--hue, var(--app-ink))');
    // On the light page the hue's deep shade at the start and its bright one at the end, as Settings' chips pair them;
    // on the dark one --hue is already the bright shade: the start is it taken a little way into the page's dark and
    // the end is it whole. Mixed half into black, Uplink dark's colours came out mauve, brown and brick, where Ghost.md's
    // Market keeps its tiles vivid in the dark (Matt asked for vivid).
    final start = t.isDark ? t.colorOf('color-mix(in srgb, var(--hue, var(--app-ink)) 76%, var(--app-paper))') : hue;
    final end = t.isDark ? hue : t.colorOf('color-mix(in srgb, var(--hue-dark, var(--hue, var(--app-ink))) 70%, var(--hue, var(--app-ink)))');
    final paper = t.color('app-paper'), ink = t.color('app-ink');
    final light = paper.computeLuminance() >= ink.computeLuminance() ? paper : ink;
    final dark = identical(light, paper) ? ink : paper;
    return PluginHues._(
      start: start,
      end: end,
      // White on the colour, in every look (Matt, 2026-11-17: "make the text on the cards white not black").
      on: const Color(0xFFFFFFFF),
      accent: hue,
      wash: t.colorOf('color-mix(in srgb, var(--hue, var(--app-ink)) 14%, transparent)'),
      light: light,
      dark: dark,
    );
  }

  static final Expando<Map<String, PluginHues>> _kept = Expando('plugin hues');

  /// The two ends of the colour, top start to bottom end.
  final Color start, end;

  /// Words and marks on the colour: the page's lighter one (white paper, a dark page's ink) where it reads at 3:1 on
  /// all of it, else its darker (a dark ink on Lamplight's amber).
  final Color on;

  /// The hue on the page itself, where it marks something: deep on the light page, bright on the dark.
  final Color accent;

  /// The hue as a wash on the page, under an icon.
  final Color wash;

  /// The page's lighter and darker of paper and ink: the glow over a tile and the shade under it.
  final Color light, dark;

  /// The colour as a fill, a soft light from its top start corner over it (Ghost.md's tileLight).
  LinearGradient get gradient => LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [start, Color.lerp(start, end, 0.55)!, end]);

  /// Glass on the colour: a chip, a button.
  Color get glass => on.withValues(alpha: 0.18);
  Color get glassRing => on.withValues(alpha: 0.3);

  /// A small tag on the colour: solid enough that what lies under it (the faint icon, the gradient's bright end) does
  /// not decide whether its word reads. Light words on the page's dark, dark words on its light.
  Color get tag => identical(on, dark) ? light.withValues(alpha: 0.5) : dark.withValues(alpha: 0.34);
  Color get tagRing => on.withValues(alpha: 0.22);

  /// The faint icon on a coloured head, behind its words.
  Color get faint => on.withValues(alpha: 0.10);
}

/// Of [light] and [dark], the one that reads on every colour in [on]: the light one where it reaches [least] on all of
/// them (3:1 for large, bold words; 4.5:1 for a line of small ones), else whichever reads better: a dark ink on
/// Lamplight's amber.
Color onColour(Color light, Color dark, List<Color> on, {double least = 3}) {
  double worst(Color ink) => on.map((c) => _contrast(ink, c)).reduce(math.min);
  final l = worst(light);
  if (l >= least) return light;
  return worst(dark) > l ? dark : light;
}

/// WCAG's contrast ratio between two colours, 1 (the same) to 21 (black on white).
double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// A corner of [px] under the look's radius scale (as lib/backgrounds.dart's lookCorner): Dial-Up and Runestone square.
double pluginCorner(Tokens t, double px) => px * t.number('glacier-radius-scale').clamp(0.0, 1.0);

/// The light laid over a coloured surface: a glow from its top start corner, in the page's lighter colour.
Widget hueGlow(PluginHues c, {required double radius}) => IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: RadialGradient(center: const Alignment(-0.8, -0.9), radius: 1.1, colors: [c.light.withValues(alpha: 0.22), c.light.withValues(alpha: 0)]),
        ),
        child: const SizedBox.expand(),
      ),
    );

/// A plugin's symbol, [size] across in [color]: its icon, or for a network (lib/plugins/networks.dart) the network's
/// own mark, as Settings › Connections draws it.
Widget pluginSymbol(GhostPlugin plugin, double size, Color color, {double strokeWidth = 2}) {
  if (plugin is NetworkPlugin) {
    final known = me.networks.where((n) => n.id == plugin.network).firstOrNull ?? me.Network(plugin.network, plugin.name, 'blue', plugin.name[0], signIn: false);
    return NetworkMark(known, size: size * 0.92, tint: color);
  }
  return AppIcon(plugin.icon, size: size, strokeWidth: strokeWidth, color: color, wash: false);
}

/// A plugin's own picture where it has one (a pack's icon, Matt, 2026-11-20: "a submission area with a form to accept
/// an icon"), [size] across and filling it, decoded at the size it is drawn; else, and wherever it doesn't decode,
/// [symbol]. A pack keeps one copy of its bytes, so the image cache finds it again on every build.
Widget pluginPicture(GhostPlugin plugin, double size, {required Widget symbol}) {
  final png = plugin.iconPng;
  if (png == null) return symbol;
  return Builder(
    builder: (context) => Image.memory(
      png,
      width: size,
      height: size,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      cacheWidth: math.max(1, (size * MediaQuery.devicePixelRatioOf(context)).round()),
      errorBuilder: (context, _, _) => symbol,
    ),
  );
}

/// A plugin's tile: its colour with its icon in the middle, [size] square, or its own picture over the colour (whose
/// clear parts show it). Under Dial-Up's bevelled chrome it is a raised silver square with the icon in ink, a toolbar
/// button of the era, its picture at seven tenths inside the bevel.
class PluginTile extends StatelessWidget {
  const PluginTile({super.key, required this.plugin, required this.size, this.shadow = false});

  final GhostPlugin plugin;
  final double size;

  /// A soft shadow under it: a tile floating on the band.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) {
      final c = DialupColors.of(t);
      final symbol = pluginSymbol(plugin, size * 0.5, c.onChrome);
      return SizedBox.square(
        dimension: size,
        child: Bevel(child: Center(child: plugin.iconPng == null ? symbol : SizedBox.square(dimension: size * 0.7, child: pluginPicture(plugin, size * 0.7, symbol: symbol)))),
      );
    }
    final c = PluginHues.of(t, plugin.hue);
    final radius = pluginCorner(t, size * 0.28);
    final symbol = Center(child: pluginSymbol(plugin, size * 0.5, c.on));
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: c.gradient,
          boxShadow: shadow ? [BoxShadow(color: c.dark.withValues(alpha: 0.22), blurRadius: 14, offset: const Offset(0, 6))] : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            hueGlow(c, radius: radius),
            if (plugin.iconPng == null) symbol else ClipRRect(borderRadius: BorderRadius.circular(radius), child: pluginPicture(plugin, size, symbol: symbol)),
          ],
        ),
      ),
    );
  }
}

/// A plugin's icon on a chip of glass, on its colour, or its own picture filling the chip: the featured card's and the
/// page's hero.
class GlassChip extends StatelessWidget {
  const GlassChip({super.key, required this.plugin, required this.size});

  final GhostPlugin plugin;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = PluginHues.of(t, plugin.hue);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.glass, borderRadius: BorderRadius.circular(pluginCorner(t, size * 0.3)), border: Border.all(color: c.glassRing)),
      clipBehavior: plugin.iconPng == null ? Clip.none : Clip.antiAlias,
      // Its own picture, where it has one, fills the chip.
      child: plugin.iconPng == null ? pluginSymbol(plugin, size * 0.54, c.on) : pluginPicture(plugin, size, symbol: pluginSymbol(plugin, size * 0.54, c.on)),
    );
  }
}
