/// My files: the account's own drive, in the pane (GMFB-37, @matt: "A private file drive for each account, not tied to
/// any space"). The drive is made from the account's key (lib/files/drive.dart) and shown by the Files space's own
/// page; this is the way in, and what is said where there is no drive to show.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../files/drive.dart';
import '../../files/files_store.dart';
import '../../files/folder_sync.dart';
import '../../kit/settings_kit.dart';
import '../../sms.dart';
import '../../voice/voice.dart';
import '../common.dart';
import '../shell.dart';
import '../skeleton.dart';
import 'files_screen.dart';
import 'folder_sync_entry.dart';

/// Opens My files where a space opens: in the shell's pane (beside the list in a wide window), else as a page.
void openMyFiles(BuildContext context) {
  const page = MyFilesScreen(key: ValueKey('my-files'));
  final shell = AppShell.maybeOf(context);
  // 'files:' as a Files space on its own is, so the dock puts it away as it does one (AppShellState._loosePage).
  if (shell != null) return shell.show(page, showing: 'files:mine');
  unawaited(push<void>(context, (_) => page));
}

/// The account's drive, once it is made from the account's key; else why there is none here.
class MyFilesScreen extends StatefulWidget {
  const MyFilesScreen({super.key, this.drive, this.store, this.sync, this.pickFolder});

  /// The folder kept in step with the drive on a computer (GMFB-38): the app's where null and the store is the app's
  /// (a test gives its own, with what chooses its folder; a test's store alone shows none).
  final FolderSync? sync;
  final Future<String?> Function()? pickFolder;

  /// What makes the drive, the account's own where null (a test gives its own).
  final Future<VoiceChannel?> Function()? drive;

  /// The files store to show, the app's where null (a test gives its own).
  final FilesStore? store;

  @override
  State<MyFilesScreen> createState() => _MyFilesScreenState();
}

class _MyFilesScreenState extends State<MyFilesScreen> {
  late final Future<VoiceChannel?> _drive = (widget.drive ?? Drive.mine)();

  Widget _says(BuildContext context, String words) {
    final t = context.tokens;
    return GhostPage(
      title: Drive.name,
      body: Padding(padding: EdgeInsets.all(t.space(4)), child: Align(alignment: Alignment.topCenter, child: SettingsCallout(child: Text(words, key: const ValueKey('my-files-says'))))),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A browser whose build has no Files spaces has no drive either (Sms.browserFiles; docs/OPEN_NETWORK.md, part 6).
    if (!Sms.filesHere) return _says(context, 'My files isn\'t in the browser yet. It opens in Uplink on a phone or a computer.');
    return FutureBuilder<VoiceChannel?>(
      future: _drive,
      builder: (context, got) {
        if (got.connectionState != ConnectionState.done) return const GhostPage(title: Drive.name, body: SkeletonFiles(label: 'Opening your files…'));
        final c = got.data;
        // The drive is made from the account's recovery words: a device that keeps none (signed in to no account, or a
        // computer linked to a phone, which is not given them) has nothing to make it from.
        if (c == null) {
          return _says(context, 'My files is kept for your Uplink account, so every device signed in to it shows the same files. Sign in to your account on this device in Settings to use it here.');
        }
        // On a computer: a folder of its own kept in step with the drive (GMFB-38).
        final sync = widget.sync ?? (widget.store == null && FolderSync.here ? FolderSync.instance : null);
        return FilesSpaceScreen(key: ValueKey('files-space-${c.seed}'), channel: c, store: widget.store, above: sync == null ? null : FolderSyncEntry(sync: sync, pick: widget.pickFolder));
      },
    );
  }
}
