/// The Plugins page's own parts, after Ghost.md's Market (its lib/market/market_cards.dart; Matt, 2026-11-17: "redo how
/// the plugins look with their own dedicated plugins page with a marketplace like look how ghostmd has"): a shelf's
/// heading, the grid its cards stand in and the row they scroll in on a phone, a card's frame, the capsule buttons,
/// a shelf's chip and a small tag. Each reads the page's tokens alone, and under Dial-Up's bevelled chrome draws as
/// the era's windows and buttons do (lib/ui/dialup/).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../backgrounds.dart' show lookRim, strongFill;
import '../../kit/settings_type.dart';
import '../dialup/bevel.dart';
import '../dialup/retro_button.dart';

/// A shelf's heading: its name, and a quiet word after it (how many).
class MarketHeading extends StatelessWidget {
  const MarketHeading({super.key, required this.title, this.meta, this.icon});

  final String title;
  final String? meta;
  final LucideIcon? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(3)),
      child: Row(
        children: [
          if (icon != null) ...[AppIcon(icon!, size: 18, strokeWidth: 2.1, color: t.color('app-ink-2')), SizedBox(width: t.space(2))],
          Semantics(header: true, child: Text(title, maxLines: 1, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink')))),
          SizedBox(width: t.space(2)),
          Expanded(child: meta == null ? const SizedBox.shrink() : Text(meta!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
        ],
      ),
    );
  }
}

/// Cards as many across as [minWidth] each leaves room for, up to [most], the cards of a row as tall as its tallest.
class MarketGrid extends StatelessWidget {
  const MarketGrid({super.key, required this.minWidth, required this.children, this.most = 4, this.gap});

  final double minWidth;
  final int most;
  final double? gap;
  final List<Widget> children;

  /// How many stand across [width].
  static int across(double width, double minWidth, double gap, int most) => math.max(1, math.min(most, ((width + gap) / (minWidth + gap)).floor()));

  @override
  Widget build(BuildContext context) {
    final gap = this.gap ?? context.tokens.space(3);
    return LayoutBuilder(
      builder: (context, box) {
        final n = across(box.maxWidth, minWidth, gap, most);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row * n < children.length; row++) ...[
              if (row > 0) SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < n; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      Expanded(child: row * n + i < children.length ? children[row * n + i] : const SizedBox.shrink()),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Cards in a row that scrolls sideways, each [width] wide and [height] tall: a phone's featured shelf. The row is not
/// cut at the page's gutters, so a card half past the edge says there are more.
class MarketRow extends StatelessWidget {
  const MarketRow({super.key, required this.width, required this.height, required this.children, this.fade = false});

  final double width;
  final double height;
  final List<Widget> children;

  /// Kept inside its own width and faded out at its end: where a pane stands past it, so a card is not cut off flat
  /// against the pane's divider.
  final bool fade;

  @override
  Widget build(BuildContext context) {
    final gap = context.tokens.space(3);
    final row = SizedBox(
      height: height,
      child: ListView.separated(
        key: const ValueKey('plugins-featured-row'),
        scrollDirection: Axis.horizontal,
        clipBehavior: fade ? Clip.hardEdge : Clip.none,
        itemCount: children.length,
        separatorBuilder: (context, i) => SizedBox(width: gap),
        itemBuilder: (context, i) => SizedBox(width: width, child: children[i]),
      ),
    );
    if (!fade) return row;
    // A mask: only its alpha counts, so any token's colour does.
    final mask = context.tokens.color('app-ink');
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(colors: [mask, mask, mask.withValues(alpha: 0)], stops: const [0, 0.86, 1]).createShader(rect),
      child: row,
    );
  }
}

/// A card's frame: the page's second paper, a hairline round it and the press's dip; with [selected], ringed in the
/// ink, never colour alone. Under Dial-Up a raised silver panel that sinks while pressed.
class MarketCard extends StatelessWidget {
  const MarketCard({super.key, required this.child, this.onPress, this.label, this.selected = false, this.padding});

  final Widget child;
  final VoidCallback? onPress;

  /// What a screen reader says for the card's press.
  final String? label;
  final bool selected;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final radius = t.radius('lg');
    Widget frame(bool hovered, bool pressed) {
      if (bevel) {
        final c = DialupColors.of(t);
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: selected ? Border.all(color: c.dark, width: 2) : null),
          child: Bevel(style: pressed ? BevelStyle.pressed : BevelStyle.raised, kind: BevelKind.button, padding: padding ?? EdgeInsets.zero, child: child),
        );
      }
      final rim = lookRim(t);
      return AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        clipBehavior: Clip.antiAlias,
        padding: padding,
        decoration: BoxDecoration(color: pressed ? t.color('app-paper-3') : t.color('app-paper-2'), borderRadius: BorderRadius.circular(radius)),
        // The ring over what the card holds, not under it, so a coloured head does not cover it at its corners (as
        // Ghost.md found, Matt, 2026-10-27: "the outlines on the cards on the marketplace also get clipped").
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: selected ? t.color('app-ink') : (hovered ? t.colorOf('color-mix(in oklch, var(--app-ink) 22%, transparent)') : (rim?.top.color ?? t.color('app-rule'))),
            width: selected ? 2 : t.len('glacier-hairline'),
          ),
        ),
        child: child,
      );
    }

    final press = onPress;
    if (press == null) return frame(false, false);
    return GlacierPressable(
      onPressed: press,
      semanticLabel: label,
      selected: selected,
      builder: (context, state) => GlacierFocusRing(visible: state.focused, radius: bevel ? 0 : radius, child: frame(state.hovered, state.pressed)),
    );
  }
}

/// How a capsule is drawn: filled in a colour, the page's strong fill, a ring, or glass on a colour.
enum MarketButtonLook { filled, ink, ring, glass }

/// A capsule button: Add, Remove, Settings. [color] fills a filled one with [onColor] words; glass is [onColor] at a
/// fifth on whatever colour it stands on. Under Dial-Up it is the era's push button.
class MarketButton extends StatelessWidget {
  const MarketButton({super.key, required this.label, required this.onPress, this.look = MarketButtonLook.ink, this.color, this.onColor, this.icon, this.semantics, this.large = false});

  final String label;
  final VoidCallback? onPress;
  final MarketButtonLook look;
  final Color? color;
  final Color? onColor;
  final LucideIcon? icon;

  /// What a screen reader says, where the word alone is not enough: "Add Codes".
  final String? semantics;

  /// The plugin page's size, a thumb's height.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) {
      return RetroButton(
        onPressed: onPress,
        semanticLabel: semantics ?? label,
        faceHeight: large ? 40 : 30,
        primary: look == MarketButtonLook.filled && large,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[AppIcon(icon!, size: 14, strokeWidth: 2.2, color: DialupColors.of(t).onChrome, wash: false), SizedBox(width: t.space(1))],
            Text(label, style: pageText(t, large ? 15 : 13, weight: look == MarketButtonLook.filled ? 'bold' : 'regular', color: onPress == null ? DialupColors.of(t).disabled : DialupColors.of(t).onChrome)),
          ],
        ),
      );
    }
    final off = onPress == null;
    final height = large ? t.lenOf('2.6rem') : t.lenOf('1.9rem');
    final (strong, onStrong) = strongFill(t);
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: semantics ?? label,
      builder: (context, state) {
        final on = onColor ?? onStrong;
        final (Color ground, Color ink, Color? ring) = switch (look) {
          MarketButtonLook.filled => (color ?? strong, on, null),
          MarketButtonLook.ink => (strong, onStrong, null),
          MarketButtonLook.ring => (t.color('app-paper').withValues(alpha: 0), t.color('app-ink'), t.color('app-rule')),
          MarketButtonLook.glass => (on.withValues(alpha: 0.2), on, on.withValues(alpha: 0.34)),
        };
        return GlacierFocusRing(
          visible: state.focused,
          radius: height / 2,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: off ? 0.45 : (state.pressed ? 0.8 : 1),
            child: Container(
              height: height,
              padding: EdgeInsets.symmetric(horizontal: large ? t.space(5) : t.space(3)),
              decoration: BoxDecoration(
                color: ground,
                borderRadius: BorderRadius.circular(height / 2 * t.number('glacier-radius-scale').clamp(0.0, 1.0)),
                border: ring == null ? null : Border.all(color: ring, width: t.len('glacier-hairline')),
              ),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[AppIcon(icon!, size: large ? 16 : 14, strokeWidth: 2.3, color: ink, wash: false), SizedBox(width: t.space(1))],
                    Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, large ? t.fontSize('md') : t.fontSize('sm'), weight: 'semibold', color: ink))),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Added", with its tick: what stands where Add was once a plugin is added.
class MarketAdded extends StatelessWidget {
  const MarketAdded({super.key, required this.name, this.color});

  final String name;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = color ?? (isBevelChrome(t) ? DialupColors.of(t).onChrome : t.color('app-ink-3'));
    return Semantics(
      label: '$name added',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(Lucide.circleCheck, size: 15, strokeWidth: 2.2, color: ink, wash: false),
            SizedBox(width: t.space(1)),
            Text('Added', style: pageText(t, t.fontSize('sm'), weight: 'medium', color: ink)),
          ],
        ),
      ),
    );
  }
}

/// One shelf in the page's filter: a capsule with its word, filled when it is the one chosen. Under Dial-Up, a push
/// button that stays in.
class MarketChip extends StatelessWidget {
  const MarketChip({super.key, required this.label, required this.chosen, required this.onPress, this.count});

  final String label;
  final bool chosen;
  final VoidCallback onPress;

  /// How many it holds, said quietly after its word.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) {
      return RetroButton(onPressed: onPress, toggled: chosen, faceHeight: 30, label: count == null ? label : '$label ($count)', semanticLabel: label);
    }
    final (strong, onStrong) = strongFill(t);
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      selected: chosen,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        child: Container(
          constraints: BoxConstraints(minHeight: t.space(8)),
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          decoration: BoxDecoration(
            color: chosen ? strong : (state.pressed ? t.color('app-paper-3') : t.color('app-paper').withValues(alpha: 0)),
            border: Border.all(color: chosen ? strong : t.color('app-rule'), width: t.len('glacier-hairline')),
            borderRadius: BorderRadius.circular(t.radius('full')),
          ),
          child: Align(
            widthFactor: 1,
            child: ExcludeSemantics(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: label),
                  if (count != null) TextSpan(text: '  $count', style: TextStyle(color: chosen ? onStrong.withValues(alpha: 0.7) : t.color('app-ink-3'))),
                ]),
                style: pageText(t, t.fontSize('sm'), weight: 'medium', color: chosen ? onStrong : t.color('app-ink-2')),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A word in a small capsule of its own: a plugin's shelf on its card's head, its status on its page.
class MarketTag extends StatelessWidget {
  const MarketTag({super.key, required this.label, this.ground, this.ink, this.ring});

  final String label;
  final Color? ground;
  final Color? ink;

  /// A hairline round it, on a colour.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.12rem')),
      decoration: BoxDecoration(
        color: ground ?? t.color('app-paper-3'),
        borderRadius: BorderRadius.circular(t.radius('full')),
        border: ring == null ? null : Border.all(color: ring!, width: t.len('glacier-hairline')),
      ),
      child: Text(label, maxLines: 1, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: ink ?? t.color('app-ink-2'))),
    );
  }
}
