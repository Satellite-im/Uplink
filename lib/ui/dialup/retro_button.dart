import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart' show AppIcon, LucideIcon;
import '../../art/pixel_emoji.dart';
import '../../kit/settings_type.dart';
import 'bevel.dart';

/// Dial-Up's push button: a silver raised square that sinks while held, its label moving one pixel right and down as
/// the era's did. Square and shadowless, and never smaller to the finger than 48 by 48 however small its face is drawn
/// (the design: "every press target stays 44-48px or larger even when it is drawn as a small square button").
///
/// Give it a [label] (words, 15px), an [icon], or a [child] of your own; [semanticLabel] is what a screen reader says
/// and is needed where there are no words. [primary] adds the dark frame the era put round the button Enter presses
/// (Send). Off ([onPressed] null), the words are grey with a white emboss (none on a dark chrome).
class RetroButton extends StatelessWidget {
  const RetroButton({
    super.key,
    required this.onPressed,
    this.label,
    this.icon,
    this.child,
    this.semanticLabel,
    this.onLongPress,
    this.primary = false,
    this.faceHeight = 40,
    this.minFaceWidth = 40,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.toggled,
    this.face,
    this.bold = false,
  }) : assert(label != null || icon != null || child != null, 'a button needs something on its face');

  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final String? label;
  final LucideIcon? icon;
  final Widget? child;

  /// Said by a screen reader; the [label] when null.
  final String? semanticLabel;
  final bool primary;

  /// The drawn face's height and least width, in logical pixels. The press target round it is at least 48 either way.
  final double faceHeight, minFaceWidth;

  /// Room between the face's rings and what is on it.
  final EdgeInsetsGeometry padding;

  /// A button that stays in (a chosen formatting toggle): drawn held while true.
  final bool? toggled;

  /// The face's colour, the window's silver when null: the taskbar's chosen button is a shade lighter, as the era
  /// drew the window in front.
  final Color? face;

  /// Bold words: the button Enter presses (Send).
  final bool bold;

  /// The least side of the press target.
  static const double target = 48;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final ring = Bevel.ringOf(context);
    return GlacierPressable(
      onPressed: onPressed,
      onLongPress: onLongPress,
      semanticLabel: semanticLabel ?? label,
      toggled: toggled,
      builder: (context, state) {
        final off = onPressed == null;
        final held = (state.pressed && !off) || (toggled ?? false);
        final ink = off ? c.disabled : c.onChrome;
        final style = pageText(t, 15, weight: bold ? 'bold' : 'regular', color: ink).copyWith(
          // The era's grey words on a disabled button had a white copy one pixel down and right under them.
          shadows: off && !c.night ? [Shadow(color: c.hi, offset: const Offset(1, 1))] : null,
        );
        final top = child ??
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) AppIcon(icon!, size: 18, color: ink, wash: false),
                if (icon != null && label != null) const SizedBox(width: 6),
                // Its emoji in square pixels where the look draws them so (a reply that is one: lib/art/pixel_emoji.dart).
                if (label != null)
                  pixelEmojiOn(t)
                      ? Text.rich(TextSpan(children: pixelEmojiSpans([TextSpan(text: label)], style)), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
                      : Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ],
            );
        Widget drawn = Bevel(
          style: held ? BevelStyle.pressed : BevelStyle.raised,
          kind: BevelKind.button,
          color: face,
          padding: padding,
          child: Transform.translate(
            offset: held ? const Offset(1, 1) : Offset.zero,
            child: DefaultTextStyle.merge(style: style, child: Center(widthFactor: 1, child: top)),
          ),
        );
        if (primary) {
          drawn = DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: c.dark, width: ring)),
            child: Padding(padding: EdgeInsets.all(ring), child: drawn),
          );
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(minWidth: target, minHeight: target),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: GlacierFocusRing(
              visible: state.focused,
              radius: 0,
              offset: 1,
              width: 1,
              color: c.onChrome,
              child: ConstrainedBox(constraints: BoxConstraints(minWidth: minFaceWidth, minHeight: faceHeight, maxHeight: faceHeight), child: drawn),
            ),
          ),
        );
      },
    );
  }
}

/// One segment of a segmented toggle under Dial-Up, drawn for the kit through GlacierOverrides (lib/main.dart's
/// InkOverrides), so every GlacierSegmentedControl in the app turns into a row of push buttons in one place (Matt,
/// 2026-11-18: "make sure every segmented toggle also has beveled button like apperances"). Each segment is a silver
/// raised square; the chosen one is held in, its label a pixel right and down, as a [RetroButton] that stays in.
class RetroSegment extends StatelessWidget {
  const RetroSegment({super.key, required this.look});
  final GlacierSegmentLook look;

  @override
  Widget build(BuildContext context) {
    final c = DialupColors.of(context.tokens);
    final held = look.selected || (look.pressed && !look.disabled);
    final ink = look.disabled ? c.disabled : c.onChrome;
    return Padding(
      // A pixel of silver between neighbours, so each reads as a button of its own rather than one bar.
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: GlacierFocusRing(
        visible: look.focused,
        radius: 0,
        offset: 1,
        width: 1,
        color: c.onChrome,
        child: Bevel(
          style: held ? BevelStyle.pressed : BevelStyle.raised,
          kind: BevelKind.button,
          // The chosen one on the bevel's inner light, as the taskbar draws the page shown (nav_bar.dart): a shade
          // lighter than the face, so an
          // icon-only toggle (the Files view, the list's tabs) still shows which is chosen.
          color: look.selected ? c.lo : null,
          padding: EdgeInsets.symmetric(horizontal: look.padding),
          child: Transform.translate(
            offset: held ? const Offset(1, 1) : Offset.zero,
            child: Center(
              child: DefaultTextStyle(
                style: look.style.copyWith(color: ink),
                softWrap: false,
                overflow: TextOverflow.visible,
                child: IconTheme.merge(data: IconThemeData(color: ink), child: look.label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
