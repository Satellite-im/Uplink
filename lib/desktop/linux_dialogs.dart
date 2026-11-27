/// Choosing files on Linux (Matt, 2026-11-20: "add support on the website for linux based systems and downloads"):
/// there is no panel of the app's own there, so the desktop's standard chooser is asked for, GNOME's zenity or KDE's
/// kdialog, whichever is installed. None installed: nothing is chosen, as when a panel is put away.
library;

import 'dart:io';
import '../platform_info.dart';

/// The paths chosen (at most [most]); [pictures] limits the chooser to pictures and videos.
Future<List<String>> linuxPick({int most = 50, bool pictures = false}) async {
  const kinds = '*.png *.jpg *.jpeg *.gif *.webp *.heic *.bmp *.mp4 *.mov *.mkv *.webm';
  final tries = <(String, List<String>)>[
    ('zenity', ['--file-selection', '--multiple', '--separator=\n', '--title=Choose files', if (pictures) '--file-filter=Pictures and videos | $kinds']),
    ('kdialog', ['--getopenfilename', PlatformInfo.environment['HOME'] ?? '.', if (pictures) 'Pictures and videos ($kinds)', '--multiple', '--separate-output', '--title', 'Choose files']),
  ];
  for (final (tool, args) in tries) {
    try {
      final r = await Process.run(tool, args);
      // 1 is put away; anything else from a chooser that ran is nothing chosen.
      if (r.exitCode != 0) return const [];
      final paths = '${r.stdout}'.split('\n').map((p) => p.trim()).where((p) => p.isNotEmpty && File(p).existsSync()).toList();
      return paths.take(most).toList();
    } on ProcessException {
      // Not installed: the next.
      continue;
    }
  }
  return const [];
}
