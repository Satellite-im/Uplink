/// A file's mark in a Files space (Matt, 2026-11-17: "use iconography and color where possible"): its kind's icon in
/// its kind's colour, one of the app's hues (lib/kit/settings_css.dart `data-hue`), so pictures, videos, sound, PDFs,
/// documents, spreadsheets, archives and code each read at a glance in every look; or a small picture of it where it
/// is a picture.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../files/files_store.dart';
import '../../files/local_thumbs.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../dialup/bevel.dart';

/// Each kind's hue and icon.
String fileHue(FileKind kind) => switch (kind) {
      FileKind.image => 'purple',
      FileKind.video => 'rose',
      FileKind.audio => 'mint',
      FileKind.pdf => 'coral',
      FileKind.doc => 'blue',
      FileKind.sheet => 'green',
      FileKind.slides => 'orange',
      FileKind.archive => 'amber',
      FileKind.code => 'cyan',
      FileKind.text => 'indigo',
      FileKind.other => 'slate',
    };

/// Each kind's ink under Dial-Up, from the era's sixteen colours (deep on the white well, bright on the dark chrome
/// Runestone draws with): Dial-Up settles every app hue into plain ink, which left every file a black mark in a white box, and the
/// kinds are told apart by their colour as much as their icon.
Color fileRetroInk(Tokens t, FileKind kind) {
  final (light, dark) = switch (kind) {
    FileKind.image => (0xFF800080, 0xFFFF80FF),
    FileKind.video => (0xFFC00000, 0xFFFF6060),
    FileKind.audio => (0xFF008080, 0xFF00FFFF),
    FileKind.pdf => (0xFF800000, 0xFFFF8080),
    FileKind.doc => (0xFF000080, 0xFF8080FF),
    FileKind.sheet => (0xFF008000, 0xFF00FF00),
    FileKind.slides => (0xFF0000FF, 0xFF60A0FF),
    FileKind.archive => (0xFF808000, 0xFFFFFF00),
    FileKind.code => (0xFF404040, 0xFFE0E0E0),
    FileKind.text => (0xFF808080, 0xFFC0C0C0),
    FileKind.other => (0xFF000000, 0xFFFFFFFF),
  };
  return Color(t.isDark ? dark : light);
}

/// The icon a kind of file is marked with.
LucideIcon fileIcon(FileKind kind) => switch (kind) {
      FileKind.image => Lucide.image,
      FileKind.video => Lucide.film,
      FileKind.audio => LucideMore.music,
      FileKind.pdf => Lucide.scrollText,
      FileKind.doc => Lucide.fileText,
      FileKind.sheet => Lucide.table,
      FileKind.slides => LucideMore.chartColumn,
      FileKind.archive => Lucide.archive,
      FileKind.code => Lucide.fileCode,
      FileKind.text => Lucide.text,
      FileKind.other => Lucide.file,
    };

/// A kind's icon on a wash of its colour, in a rounded square [size] across.
class FileBadge extends StatelessWidget {
  const FileBadge({super.key, required this.kind, this.size = 40, this.filled = false});
  final FileKind kind;
  final double size;

  /// Filled with the colour (a chosen row), the icon in the page's own colour on it.
  final bool filled;

  @override
  Widget build(BuildContext context) => GlacierScope(
        attrs: {'hue': fileHue(kind)},
        child: Builder(builder: (context) {
          final t = context.tokens;
          final bevel = isBevelChrome(t);
          final colour = bevel ? fileRetroInk(t, kind) : settingsHue(t);
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bevel ? null : (filled ? colour : settingsHueWash(t)),
              borderRadius: BorderRadius.circular(bevel ? 0 : size * 0.28),
              border: bevel ? Border.all(color: DialupColors.of(t).shadow) : null,
            ),
            child: AppIcon(fileIcon(kind), size: size * 0.5, color: filled && !bevel ? t.color('glacier-bg') : colour, wash: !filled),
          );
        }),
      );
}

/// A file's face: its small picture where it has one, else its [FileBadge].
class FileFace extends StatelessWidget {
  const FileFace({super.key, required this.file, this.size = 40});
  final SpaceFile file;
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        // Its own small picture, or one made here from its copy (lib/files/local_thumbs.dart).
        listenable: LocalThumbs.instance,
        builder: (context, _) {
          final thumb = LocalThumbs.instance.of(file);
          if (thumb == null) return FileBadge(kind: file.kind, size: size);
          final t = context.tokens;
          final bevel = isBevelChrome(t);
          return ClipRRect(
            borderRadius: BorderRadius.circular(bevel ? 0 : size * 0.28),
            child: _VideoMark(
              on: file.kind == FileKind.video,
              size: size * 0.42,
              child: _Thumb(bytes: thumb, width: size, height: size, fallback: FileBadge(kind: file.kind, size: size)),
            ),
          );
        },
      );
}

/// A play mark over a video's picture, so it reads as a video and not a photo.
class _VideoMark extends StatelessWidget {
  const _VideoMark({required this.on, required this.size, required this.child});
  final bool on;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!on) return child;
    return Stack(alignment: Alignment.center, children: [
      child,
      Container(
        key: const ValueKey('file-video-mark'),
        width: size,
        height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x8C000000)),
        child: Center(child: AppIcon(Lucide.play, size: size * 0.5, color: const Color(0xFFFFFFFF))),
      ),
    ]);
  }
}

/// A picture's small copy, from its bytes; [fallback] where they can't be drawn.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.bytes, required this.width, required this.height, required this.fallback});
  final Uint8List bytes;
  final double width, height;
  final Widget fallback;

  @override
  // Decoded at the size it is drawn: a small picture that claims a huge size is never unpacked whole on every device
  // that draws the space's list.
  Widget build(BuildContext context) {
    final px = (width.isFinite ? width : 400) * MediaQuery.devicePixelRatioOf(context);
    return Image.memory(bytes, width: width, height: height, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: px.round().clamp(16, 1024), errorBuilder: (_, _, _) => fallback);
  }
}

/// A file's tile in the grid: its picture, or a large mark of its kind on its colour with its ending ("PDF") under the
/// mark, filling a square.
class FileTilePicture extends StatelessWidget {
  const FileTilePicture({super.key, required this.file});
  final SpaceFile file;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: LocalThumbs.instance, builder: (context, _) => _build(context, LocalThumbs.instance.of(file)));

  Widget _build(BuildContext context, Uint8List? thumb) {
    return LayoutBuilder(builder: (context, box) {
      final side = box.maxWidth;
      if (thumb != null) {
        return _VideoMark(
          on: file.kind == FileKind.video,
          size: (side * 0.28).clamp(28.0, 56.0),
          child: _Thumb(bytes: thumb, width: side, height: box.maxHeight, fallback: const SizedBox.shrink()),
        );
      }
      return GlacierScope(
        attrs: {'hue': fileHue(file.kind)},
        child: Builder(builder: (context) {
          final t = context.tokens;
          final bevel = isBevelChrome(t);
          final colour = bevel ? fileRetroInk(t, file.kind) : settingsHue(t);
          final ending = FileKind.endingOf(file.name).toUpperCase();
          return Container(
            color: bevel ? DialupColors.of(t).paper : settingsHueWash(t),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(fileIcon(file.kind), size: side * 0.3, color: colour),
              if (ending.isNotEmpty && ending.length <= 5) ...[
                SizedBox(height: t.space(1)),
                Text(ending, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: colour, tracking: 0.8)),
              ],
            ]),
          );
        }),
      );
    });
  }
}
