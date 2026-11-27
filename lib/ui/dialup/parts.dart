import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart' show AppIcon, LucideIcon;
import '../../art/lucide.g.dart' show Lucide;
import '../../kit/settings_type.dart';
import '../../packs/pack_paint.dart';
import 'bevel.dart';
import 'retro_button.dart';

/// The smaller pieces Dial-Up's layout is made of (lib/looks.dart): what the app's own widgets turn into while
/// [isDialup] (lib/ui/common.dart's GhostPage, IconTap and Avatar, the composer, the navigation, the list).

/// What stands on a title bar's band: the page's ink, and the words and icons drawn in it, are the band's white, so a
/// page's own header (a face, a name, a line under it) and its icon buttons read there without knowing they are on
/// navy. A class in assets/css/app.css (`.dialup-band`), so it is a scope of the tokens like `.app-inverse`.
class DialupBand extends StatelessWidget {
  const DialupBand({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlacierScope(classes: const {'dialup-band'}, child: child);
}

/// The silver panel along a page's foot (the composer's): the page's ground is the window's silver there, so what a
/// conversation draws on the page's ground under its words (lib/ui/thread.dart's composer) is the panel's.
class DialupPanel extends StatelessWidget {
  const DialupPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlacierScope(classes: const {'dialup-panel'}, child: child);
}

/// A kit field (a search field, an input) set into a [Sunken] frame: white, and without its own line round it, since
/// the frame is its edge (`.dialup-well` in assets/css/app.css). The kit reads its colours in its own build, so the
/// scope reaches it.
class DialupWell extends StatelessWidget {
  const DialupWell({super.key, required this.child});
  final Widget child;

  @override
  // The scope round the frame too, so a look whose fields are another ground than its pages' (Runestone's parchment)
  // has the frame's own face in it; Dial-Up's rule says nothing of the paper, so its frame is the page's white still.
  Widget build(BuildContext context) => GlacierScope(classes: const {'dialup-well'}, child: Sunken(small: true, child: child));
}

/// Round buttons that are to stand up off the panel as raised [RetroButton]s (the composer's +, stickers,
/// microphone): an IconTap (lib/ui/common.dart) under this draws as one. Elsewhere an IconTap is a flat tool button,
/// as the era's toolbars and title bars had them, which shows its bevel only while it is held.
class RetroIcons extends InheritedWidget {
  const RetroIcons({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RetroIcons>() != null;

  @override
  bool updateShouldNotify(RetroIcons old) => false;
}

/// An IconTap under Dial-Up, away from [RetroIcons]: a flat square the size of a press, its icon in the page's ink,
/// that sinks into a bevel while held. Off, its icon is faint.
class DialupTool extends StatelessWidget {
  const DialupTool({super.key, required this.icon, required this.label, required this.onPressed, this.size = 20, this.color, this.box = 44});

  final LucideIcon icon;
  final String label;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  final double box;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) {
        final off = onPressed == null;
        final held = state.pressed && !off;
        final ink = color ?? t.color('app-ink');
        final mark = Opacity(opacity: off ? 0.4 : 1, child: AppIcon(icon, size: size, color: ink));
        return GlacierFocusRing(
          visible: state.focused,
          radius: 0,
          offset: 0,
          width: 1,
          color: ink,
          child: SizedBox.square(
            dimension: box,
            child: held
                ? CustomPaint(
                    painter: BevelPainter(colors: c, style: BevelStyle.pressed, face: const Color(0x00000000), ring: Bevel.ringOf(context)),
                    child: Center(child: Transform.translate(offset: const Offset(1, 1), child: mark)),
                  )
                : Center(child: mark),
          ),
        );
      },
    );
  }
}

/// A face (a person's picture or initials) set into the page: square, in one ring of the sunken bevel, as the era
/// set every picture in a frame.
class DialupFace extends StatelessWidget {
  const DialupFace({super.key, required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ring = Bevel.ringOf(context);
    // Where the look draws with a resource pack (lib/packs/): round, inside the pack's own orb, as the game frames
    // what stands by its map (Matt, 2026-11-27: "find a different look for the profile pictures make them inside a
    // circle like shown", with a picture of one). The orb's ring is 4 of its 34 pixels each side.
    final orb = packOf(context.tokens)?[_orbName];
    if (orb != null) {
      final inner = (size * 26 / 34).floorToDouble();
      return SizedBox.square(
        dimension: size,
        child: Stack(alignment: Alignment.center, children: [
          Positioned.fill(child: CustomPaint(painter: OrbPainter(orb))),
          ClipOval(child: SizedBox.square(dimension: inner, child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox.square(dimension: size - ring * 2, child: child)))),
        ]),
      );
    }
    return SizedBox.square(
      dimension: size,
      child: Bevel(style: BevelStyle.sunken, rings: 1, color: context.tokens.color('app-paper'), child: ClipRect(child: SizedBox.square(dimension: size - ring * 2, child: child))),
    );
  }
}

/// A round face inside the pack's own orb where the look draws with a pack (lib/packs/), and [child] as it is
/// otherwise: a profile's picture wherever it is shown (lib/ui/profile_card.dart's ProfileFace), as [DialupFace]
/// frames a conversation's.
class PackOrb extends StatelessWidget {
  const PackOrb({super.key, required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final orb = packOf(context.tokens)?[_orbName];
    if (orb == null) return child;
    final inner = (size * 26 / 34).floorToDouble();
    return SizedBox.square(
      dimension: size,
      child: Stack(alignment: Alignment.center, children: [
        Positioned.fill(child: CustomPaint(painter: OrbPainter(orb))),
        ClipOval(child: SizedBox.square(dimension: inner, child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox.square(dimension: size, child: child)))),
      ]),
    );
  }
}

/// The corner a face in a call is drawn with under [t], and its talking rings with it (Matt, 2026-11-27: "in voice chat
/// I should have the square icons with the talking wobbles being square like they are in the sidebar and make the
/// profile pictures a squircle with the same texture outline we use for the user profile pictures"): null in a look of
/// round faces; 0, a square, in Dial-Up; and where the look draws with a resource pack, a squircle's, the corner the
/// pack's orb has when it is drawn for a face of 44.
double? voiceCorner(Tokens t, double size) {
  if (!isBevelChrome(t)) return null;
  return packOf(t)?[_orbName] == null ? 0 : size * 17 / 44;
}

const _orbName = 'other/minimap_orb_frame_small';

/// Someone's face in a call, [size] square, in the shape [voiceCorner] says: round as [child] is in a look of round
/// faces, square in a ring of the sunken bevel in Dial-Up ([DialupFace]), and with a resource pack a squircle inside
/// the pack's own orb, the frame a profile's picture has ([PackOrb]), its corners kept and its sides drawn out between
/// them. [child] is the picture or the initial, filling [size] square.
class VoiceFace extends StatelessWidget {
  const VoiceFace({super.key, required this.size, required this.child});
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!isBevelChrome(t)) return ClipOval(child: SizedBox.square(dimension: size, child: child));
    final orb = packOf(t)?[_orbName];
    if (orb == null) return DialupFace(size: size, child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox.square(dimension: size, child: child)));
    // The orb's ring is 4 of its 34 pixels, and its inner edge 13 from its middle; drawn as for a face of 44.
    final scale = size / 44, ring = (4 * scale).ceilToDouble() - 0.5;
    return SizedBox.square(
      dimension: size,
      child: Stack(alignment: Alignment.center, children: [
        Positioned.fill(child: CustomPaint(painter: SquirclePainter(orb, scale))),
        ClipRRect(
          borderRadius: BorderRadius.circular(13 * scale),
          child: SizedBox.square(dimension: size - ring * 2, child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox.square(dimension: size, child: child))),
        ),
      ]),
    );
  }
}

/// A pack's round frame as a squircle's over the whole of its box: its four quarters at the corners, each of its
/// pixels [scale] across, and its middle drawn out between them.
class SquirclePainter extends CustomPainter {
  const SquirclePainter(this.orb, this.scale);
  final ui.Image orb;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) => paintNine(canvas, orb, Offset.zero & size, inset: (orb.width - 2) / 2, scale: scale);

  @override
  bool shouldRepaint(SquirclePainter old) => old.orb != orb || old.scale != scale;
}

/// A pack's round frame over the whole of its box, its pixels kept square.
class OrbPainter extends CustomPainter {
  const OrbPainter(this.orb);
  final ui.Image orb;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImageRect(orb, Rect.fromLTWH(0, 0, orb.width.toDouble(), orb.height.toDouble()), Offset.zero & size, Paint()..filterQuality = FilterQuality.none);

  @override
  bool shouldRepaint(OrbPainter old) => old.orb != orb;
}

/// A count on a button's corner (the taskbar's Archive, Contacts, Settings): a small red square with white figures in
/// a black line, not the app's round badge.
class DialupCount extends StatelessWidget {
  const DialupCount({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: t.colorOf('var(--app-count, var(--app-danger))'), border: Border.all(color: c.night ? c.hi : c.dark)),
      child: Text(count > 99 ? '99+' : '$count', style: pageText(t, 11, weight: 'bold', height: 1.2, color: t.colorOf('var(--app-on-count, #FFFFFF)'))),
    );
  }
}

/// A square box with a tick in it, sunk into the page: choosing several rows of a list.
class DialupCheck extends StatelessWidget {
  const DialupCheck({super.key, required this.checked, this.size = 20});
  final bool checked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox.square(
      dimension: size,
      child: Sunken(
        child: checked ? Center(child: AppIcon(Lucide.check, size: size - 6, strokeWidth: 3, color: t.color('app-ink'))) : null,
      ),
    );
  }
}
