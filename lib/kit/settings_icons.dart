import 'package:flutter/widgets.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';

/// Every icon Settings draws, by the name the web app imports it under from `@glacier/icons` (a proxy over
/// lucide-react), plus the app's own back arrow (art/Icons.tsx `ArrowLeft`).
enum SettingsGlyph {
  arrowLeft,
  bell,
  bookOpen,
  calendarDays,
  check,
  chevronRight,
  circleUser,
  contact,
  fileCode,
  flaskConical,
  folder,
  folderOpen,
  folderInput,
  hardDriveDownload,
  hardDriveUpload,
  info,
  mic,
  puzzle,
  search,
  shapes,
  sparkles,
  sunMoon,
  terminal,
  userGroup,
  // Meetings' row: the people in a meeting (Matt, 2026-10-24: "use a different icon for meetings"), where it was the
  // ghost (GHST-110).
  users,
  // Sounds' row (Matt, 2026-10-27: "build ... the sounds settings"): a speaker.
  volume,
  x,
}

/// The one way Settings draws an icon: a [SettingsGlyph] at a size, in the colour the surrounding [IconTheme] or
/// [color] gives it, as an `<svg>` on the page takes `currentColor`.
///
/// Each is the web's own drawing: the kit's lucide paths ([AppIcon]) with the wash the page gives its icons (a third
/// of the icon's ink inside its body, app.css "Icons are outlines, with a wash inside"), chosen in [_kit] and nowhere
/// else; and the back arrow, which is the app's own (art/Icons.tsx `ArrowLeft`, [AppIcons.arrowLeft]).
///
/// [strokeWidth] is the JSX's: almost every icon in Settings is written with none and so is Lucide's own 2; the tick
/// on a choice card asks for 2.5. The back arrow is the app's own stroke and is 2.4 whatever is asked.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.glyph, {super.key, this.size = 16, this.color, this.strokeWidth});

  final SettingsGlyph glyph;

  /// The side of the icon's square in logical pixels: the `size` the web passes its icon.
  final double size;
  final Color? color;

  /// The stroke the web asks for on its 24-unit grid; Lucide's own 2 when null.
  final double? strokeWidth;

  @override
  Widget build(BuildContext context) {
    final kit = _kit(glyph);
    return AppIcon(kit, size: size, strokeWidth: strokeWidth ?? (glyph == SettingsGlyph.arrowLeft ? 2.4 : 2), color: color);
  }
}

/// The kit's icon for [glyph] (the back arrow is Lucide's here, where Ghost.md draws its own).
LucideIcon _kit(SettingsGlyph glyph) => switch (glyph) {
      SettingsGlyph.arrowLeft => Lucide.arrowLeft,
      SettingsGlyph.bell => Lucide.bell,
      SettingsGlyph.bookOpen => Lucide.bookOpen,
      SettingsGlyph.calendarDays => Lucide.calendarDays,
      SettingsGlyph.check => Lucide.check,
      SettingsGlyph.chevronRight => Lucide.chevronRight,
      SettingsGlyph.circleUser => Lucide.circleUser,
      SettingsGlyph.contact => Lucide.contactRound,
      SettingsGlyph.fileCode => Lucide.fileCode,
      SettingsGlyph.flaskConical => Lucide.flaskConical,
      SettingsGlyph.folder => Lucide.folder,
      SettingsGlyph.folderOpen => Lucide.folderOpen,
      SettingsGlyph.folderInput => Lucide.folderInput,
      SettingsGlyph.hardDriveDownload => Lucide.hardDriveDownload,
      SettingsGlyph.hardDriveUpload => Lucide.hardDriveUpload,
      SettingsGlyph.info => Lucide.info,
      SettingsGlyph.mic => Lucide.mic,
      SettingsGlyph.puzzle => Lucide.puzzle,
      SettingsGlyph.search => Lucide.search,
      SettingsGlyph.shapes => Lucide.shapes,
      SettingsGlyph.sparkles => Lucide.sparkles,
      SettingsGlyph.sunMoon => Lucide.sunMoon,
      SettingsGlyph.terminal => Lucide.terminal,
      SettingsGlyph.userGroup => Lucide.userGroup,
      SettingsGlyph.users => Lucide.users,
      SettingsGlyph.volume => Lucide.volume2,
      SettingsGlyph.x => Lucide.x,
    };
