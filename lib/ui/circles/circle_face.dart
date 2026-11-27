/// A circle's face and the marks of its spaces' kinds (Matt, 2026-11-17: "use iconography and color where possible").
///
/// A circle wears one of the app's hues (lib/kit/settings_css.dart `data-hue`, settled into each look by app.css) and
/// a Lucide icon, or its own small picture. A space's kind has one mark everywhere: headphones for chat and voice, a
/// speech bubble for texting, a folder for files.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../circles/circle.dart';
import '../../kit/settings_kit.dart';
import '../../sms.dart' show Sms;
import '../../voice/voice.dart';
import '../dialup/bevel.dart';

/// The icons offered when a circle is made or changed, by Lucide's name, as a grid of 24: people, making, places,
/// moods. Names are kept in the manifest, so a name once offered keeps drawing ([circleIconOf]).
final circleIcons = <String, LucideIcon>{
  'users': Lucide.users,
  'ghost': Lucide.ghost,
  'sparkles': Lucide.sparkles,
  'smile': LucideMore.smile,
  'book': Lucide.book,
  'graduation-cap': Lucide.graduationCap,
  'code': Lucide.code,
  'terminal': Lucide.terminal,
  'palette': Lucide.palette,
  'film': Lucide.film,
  'music': LucideMore.music,
  'headphones': LucideMore.headphones,
  'rocket': LucideMore.rocket,
  'flame': Lucide.flame,
  'sun': Lucide.sun,
  'snowflake': Lucide.snowflake,
  'waves': Lucide.waves,
  'compass': Lucide.compass,
  'globe': Lucide.globe,
  'bird': LucideMore.bird,
  'utensils': LucideMore.utensils,
  'lightbulb': Lucide.lightbulb,
  'flask-conical': Lucide.flaskConical,
  'crown': Lucide.crown,
};

/// Icons offered by an earlier build, still drawn for the circles that chose them.
final _olderCircleIcons = <String, LucideIcon>{
  'circle': Lucide.circle,
  'image': Lucide.image,
  'message-circle': LucideMore.messageCircle,
};

/// A circle's icon by name; one from a newer build that this one doesn't draw shows as [Lucide.users].
LucideIcon circleIconOf(String name) => circleIcons[name] ?? _olderCircleIcons[name] ?? Lucide.all[name] ?? Lucide.users;

/// A space's kind in a word or three, as the new-space cards name it.
/// The kinds of space offered where one is made or changed: all of them, but for Files in a browser whose build has
/// no Files spaces (Sms.filesHere), and an open space in a browser: it is a call to walk around in, and a browser has
/// no calls yet (Sms.callsHere).
List<SpaceKind> get spaceKindsOffered => [
      for (final k in SpaceKind.values)
        if (!(k == SpaceKind.files && !Sms.filesHere) && !(k == SpaceKind.open && Sms.browser)) k,
    ];

String spaceKindTitle(SpaceKind kind) => switch (kind) {
      SpaceKind.voice => 'Chat & voice',
      SpaceKind.text => 'Text',
      SpaceKind.files => 'Files',
      SpaceKind.open => 'Open space',
    };

/// What a space of [kind] is for, in a line.
String spaceKindBlurb(SpaceKind kind) => switch (kind) {
      SpaceKind.voice => 'A chat with a call anyone can hop into',
      SpaceKind.text => 'Just messages, no call',
      SpaceKind.files => 'Share files and pictures, with a chat beside them',
      SpaceKind.open => 'A room you walk around in: hear who is near you',
    };

/// A space's mark for its kind.
LucideIcon spaceKindIcon(SpaceKind kind) => switch (kind) {
      SpaceKind.voice => LucideMore.headphones,
      SpaceKind.text => Lucide.messageSquare,
      SpaceKind.files => Lucide.folder,
      SpaceKind.open => Lucide.compass,
    };

/// A circle's face: its picture, or its icon on a wash of its colour; filled with the colour when [selected]. Round,
/// as its name says, and drawn in [hue] through the app's hue tokens, so each look settles it into its own page.
class CircleFace extends StatelessWidget {
  const CircleFace({super.key, required this.hue, required this.icon, this.picture, this.size = 44, this.selected = false, this.semanticLabel, this.ringed = true});

  /// Drawn for [circle].
  factory CircleFace.of(Circle circle, {Key? key, double size = 44, bool selected = false, bool ringed = true}) =>
      CircleFace(key: key, hue: circle.hue, icon: circle.icon, picture: circle.picture, size: size, selected: selected, semanticLabel: circle.name, ringed: ringed);

  final String hue;
  final String icon;
  final String? picture;
  final double size;
  final bool selected;
  final String? semanticLabel;

  /// Chosen, it wears a ring of its colour at its edge. Not in the rail, which draws its own halo round it a little apart
  /// (Matt, 2026-11-20: "make sure the circle icons take up the full width there are double borders right now").
  final bool ringed;

  static final Map<String, Uint8List?> _pictures = {};

  /// The last few pictures drawn, decoded: kept to 32, the oldest let go, as each change of a circle's picture would
  /// otherwise add one (of up to 24 KB) for as long as the app runs.
  static Uint8List? _bytes(String b64) {
    if (_pictures.containsKey(b64)) {
      final got = _pictures.remove(b64);
      return _pictures[b64] = got;
    }
    Uint8List? got;
    try {
      got = base64.decode(b64);
    } catch (_) {}
    if (_pictures.length >= 32) _pictures.remove(_pictures.keys.first);
    return _pictures[b64] = got;
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        image: true,
        child: GlacierScope(
          attrs: {'hue': hue},
          child: Builder(builder: (context) {
            final t = context.tokens;
            final bevel = isBevelChrome(t);
            final bytes = picture == null ? null : _bytes(picture!);
            final colour = settingsHue(t);
            // A picture fills the round itself: clipped to it, a little zoomed so no edge of a square picture shows, with
            // nothing of the circle's colour behind it to show round its rim (Matt, 2026-11-19: "the icons inside the
            // sidebar rail for the circles bleed around the edges since they're square and not zoomed to fit"). Chosen,
            // its ring is drawn over it.
            if (bytes != null && !bevel) {
              return SizedBox.square(
                dimension: size,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(shape: BoxShape.circle, border: selected && ringed ? Border.all(color: colour, width: 2) : null),
                  child: ClipOval(
                    child: Transform.scale(
                      scale: 1.08,
                      child: Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => ColoredBox(color: settingsHueWash(t), child: Center(child: _icon(t, colour, bevel)))),
                    ),
                  ),
                ),
              );
            }
            return Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Dial-Up's faces are plain: ink on the well, a ring round them.
                color: bevel ? null : (selected ? colour : settingsHueWash(t)),
                border: bevel || (selected && ringed) ? Border.all(color: bevel ? DialupColors.of(t).dark : colour, width: bevel ? 1 : 2) : null,
              ),
              child: bytes != null
                  ? Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => _icon(t, colour, bevel))
                  : _icon(t, colour, bevel),
            );
          }),
        ),
      );

  Widget _icon(Tokens t, Color colour, bool bevel) => AppIcon(circleIconOf(icon), size: size * 0.48, color: selected && !bevel ? t.color('glacier-bg') : colour, wash: !selected);
}

/// A space's kind mark in a small round of its colour: voice green, texting blue, files amber (the app's hues).
class SpaceKindBadge extends StatelessWidget {
  const SpaceKindBadge({super.key, required this.kind, this.size = 28, this.live = false});
  final SpaceKind kind;
  final double size;

  /// Someone is in its call now.
  final bool live;

  /// The name of the app hue a kind is drawn in.
  static String hueOf(SpaceKind kind) => switch (kind) {
        SpaceKind.voice => 'green',
        SpaceKind.text => 'blue',
        SpaceKind.files => 'amber',
        SpaceKind.open => 'purple',
      };

  @override
  Widget build(BuildContext context) => GlacierScope(
        attrs: {'hue': hueOf(kind)},
        child: Builder(builder: (context) {
          final t = context.tokens;
          final bevel = isBevelChrome(t);
          // Dial-Up settles every hue into black: there the kind keeps a colour of the era's sixteen (green, navy,
          // olive; their bright twins on Runestone's dark stone), so voice, texting and files still read apart.
          final colour = bevel ? Color(switch (kind) {
            SpaceKind.voice => t.isDark ? 0xFF00FF00 : 0xFF008000,
            SpaceKind.text => t.isDark ? 0xFF8080FF : 0xFF000080,
            SpaceKind.files => t.isDark ? 0xFFFFFF00 : 0xFF808000,
            SpaceKind.open => t.isDark ? 0xFFFF80FF : 0xFF800080,
          }) : settingsHue(t);
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bevel ? null : (live ? colour : settingsHueWash(t)),
              borderRadius: BorderRadius.circular(bevel ? 0 : size * 0.32),
            ),
            child: AppIcon(spaceKindIcon(kind), size: size * 0.56, color: live && !bevel ? t.color('glacier-bg') : colour, wash: !live),
          );
        }),
      );
}

/// A small mark for a page's title bar ([GhostPage.titleLeading]): [child] in every look but Dial-Up, whose navy title
/// bar sinks a mark drawn in a hue or in black; there it is [icon] alone in the title bar's own ink.
class TitleBarMark extends StatelessWidget {
  const TitleBarMark({super.key, required this.icon, required this.child, this.size = 18});
  final LucideIcon icon;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!isBevelChrome(t)) return child;
    return SizedBox.square(dimension: size, child: Center(child: AppIcon(icon, size: size * 0.86, color: DialupColors.of(t).titlebarInk, wash: false)));
  }
}
