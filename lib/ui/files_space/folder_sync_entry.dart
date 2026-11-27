/// "Sync a folder" in My files and in a Files space on a computer (GMFB-38: "Sync a folder on your computer with a
/// drive"): the folder chosen with its path, what the sync is doing, and Stop syncing. The rules are
/// lib/files/folder_sync.dart's; this is the way in and the words.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../files/folder_sync.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../platform_info.dart';
import '../common.dart';
import '../../l10n/words.dart';

/// The computer's own "choose a folder", asked of the system with nothing new built into the app: the Mac's
/// (`choose folder` through osascript), Windows' folder dialog (through PowerShell), and GNOME's zenity or KDE's
/// kdialog on Linux. The path chosen; null where it was put away or there is no chooser.
Future<String?> pickSyncFolder([String drive = 'My files']) async {
  // Into a script's and a command's quoted words, and a space's name is whatever its owner wrote: letters, digits
  // and a few marks only, so nothing in it can end the quoted words.
  final words = 'Choose a folder to sync with ${drive.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), ' ').trim()}';
  final tries = <(String, List<String>)>[
    if (PlatformInfo.isMacOS) ('osascript', ['-e', 'POSIX path of (choose folder with prompt "$words")']),
    if (PlatformInfo.isWindows)
      (
        'powershell',
        [
          '-NoProfile',
          '-STA',
          '-Command',
          "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; \$d = New-Object System.Windows.Forms.FolderBrowserDialog; \$d.Description = '$words'; \$d.ShowNewFolderButton = \$true; if (\$d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write(\$d.SelectedPath) }",
        ]
      ),
    if (PlatformInfo.isLinux) ...[
      ('zenity', ['--file-selection', '--directory', '--title=$words']),
      ('kdialog', ['--getexistingdirectory', PlatformInfo.environment['HOME'] ?? '.', '--title', words]),
    ],
  ];
  for (final (tool, args) in tries) {
    try {
      final r = await Process.run(tool, args, stdoutEncoding: utf8);
      if (r.exitCode != 0) return null;
      final path = '${r.stdout}'.trim();
      return path.isEmpty ? null : path;
    } on ProcessException {
      // Not installed: the next.
      continue;
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// The entry at the top of My files, and of a Files space this device may add files to: "Sync a folder" where none
/// is chosen; else its path, its state line and Stop syncing.
class FolderSyncEntry extends StatefulWidget {
  const FolderSyncEntry({super.key, required this.sync, this.pick});
  final FolderSync sync;

  /// What chooses the folder, the system's where null (a test gives its own).
  final Future<String?> Function()? pick;

  @override
  State<FolderSyncEntry> createState() => _FolderSyncEntryState();
}

class _FolderSyncEntryState extends State<FolderSyncEntry> {
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    widget.sync.load();
    // My files opened: a pass, where a folder is chosen.
    unawaited(widget.sync.pass());
  }

  Future<void> _choose() async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      final pick = widget.pick;
      final path = await (pick == null ? pickSyncFolder(widget.sync.driveName) : pick());
      if (path == null || !mounted) return;
      final why = widget.sync.choose(path);
      if (why != null && mounted) toast(context, why);
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) {
        final root = widget.sync.root;
        final name = widget.sync.driveName;
        // A space's folder is everyone's in the space: said before a folder is chosen (GMFB-38).
        final shared = widget.sync.space != null;
        final quiet = pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'));
        // Too many files gone at once: asked, not done (GMFB-38).
        final here = widget.sync.heldHere.length, there = widget.sync.heldThere.length, held = here + there;
        return Padding(
          key: const ValueKey('folder-sync'),
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(2)),
          child: SettingsCallout(
            icon: const AppIcon(Lucide.folderInput, size: 18),
            action: root == null
                ? RowAction(key: const ValueKey('folder-sync-choose'), onPress: _choose, disabled: _choosing, child: const Tr('Sync a folder'))
                : RowAction(key: const ValueKey('folder-sync-stop'), onPress: widget.sync.stop, child: const Tr('Stop syncing')),
            child: root == null
                ? Text('Keep a folder on this computer in step with $name.${shared ? ' Everyone in the space gets what is in it.' : ''}', key: const ValueKey('folder-sync-words'))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(root, key: const ValueKey('folder-sync-path'), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(widget.sync.line.isEmpty ? (widget.sync.running ? 'Looking for changes' : 'Waiting to sync') : widget.sync.line, key: const ValueKey('folder-sync-line'), style: quiet),
                    if (held > 0) ...[
                      SizedBox(height: t.space(1)),
                      Text(
                        [
                          if (here > 0) '$here ${here == 1 ? 'file is' : 'files are'} gone from this folder. Remove ${here == 1 ? 'it' : 'them'} from $name too?',
                          if (there > 0) '$there ${there == 1 ? 'file is' : 'files are'} gone from $name. Remove ${there == 1 ? 'it' : 'them'} from this folder too?',
                        ].join(' '),
                        key: const ValueKey('folder-sync-held'),
                      ),
                      SizedBox(height: t.space(1)),
                      Wrap(spacing: t.space(2), runSpacing: t.space(1), children: [
                        RowAction(key: const ValueKey('folder-sync-remove-held'), onPress: () => unawaited(widget.sync.removeHeld()), child: Text(held == 1 ? 'Remove it' : 'Remove them')),
                        RowAction(key: const ValueKey('folder-sync-keep-held'), onPress: () => unawaited(widget.sync.keepHeld()), child: Text(held == 1 ? 'Keep it' : 'Keep them')),
                      ]),
                    ],
                    Text('New, changed and removed files go both ways. A changed file replaces the older one in $name. A file removed from $name is moved into the hidden folder ${FolderSyncEngine.binName} here, never deleted, and many gone at once wait for you to say.', key: const ValueKey('folder-sync-rules'), style: quiet),
                  ]),
          ),
        );
      },
    );
  }
}
