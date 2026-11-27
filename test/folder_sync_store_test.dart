// The synced folder against the real files store and the relay's files service on this machine (GMFB-38): what
// StoreDrive (lib/files/folder_sync.dart) makes of My files, both ways, from two devices of one account.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/files/drive.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/files/folder_sync.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

void main() {
  test('a folder on one computer goes up to My files and comes down into a folder on another; a change replaces the older; a removal follows', () async {
    final dir = Directory(Directory.systemTemp.createTempSync('ghost-folder-sync-store').resolveSymbolicLinksSync());
    final relay = Relay(files: Files(dir: Directory('${dir.path}/relay')));
    final base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
    final words = AccountCrypto.newWords();
    final stores = <FilesStore>[];
    FolderSyncEngine device(String name) {
      final store = FilesStore.forTest(base: base, signer: KeysSigner(NetKeys.generate()), data: Directory('${dir.path}/$name-store'), name: name, piece: 2);
      stores.add(store);
      final root = Directory('${dir.path}/$name-folder')..createSync();
      return FolderSyncEngine(
        root: FolderSyncEngine.resolve(root.path)!,
        drive: StoreDrive(store, Drive.channelOf(Me.mineKeyOf(words)), tick: const Duration(milliseconds: 20)),
        state: SyncState(File('${dir.path}/$name-state.json')),
        now: () => DateTime.now().add(const Duration(hours: 1)),
      );
    }

    try {
      final a = device('a'), b = device('b');
      await stores[0].start();
      await stores[1].start();
      File('${a.root}/Papers').parent.createSync(recursive: true);
      (File('${a.root}/Papers/lease.txt')..parent.createSync(recursive: true)).writeAsStringSync('the lease');
      File('${a.root}/top.txt').writeAsStringSync('top');
      var r = await a.run();
      expect(r.stopped, isNull);
      expect(r.up, 2, reason: '${r.skipped}');
      expect((await a.run()).moved, 0, reason: 'what went up is known for the drive\'s own file');

      r = await b.run();
      expect(r.stopped, isNull);
      expect(r.down, 2, reason: '${r.skipped}');
      expect(File('${b.root}/Papers/lease.txt').readAsStringSync(), 'the lease');
      expect(File('${b.root}/top.txt').readAsStringSync(), 'top');
      expect((await b.run()).moved, 0);

      // Changed on b: up as the newest, and down over a's recorded copy.
      File('${b.root}/top.txt').writeAsStringSync('top, changed on b');
      r = await b.run();
      expect(r.up, 1, reason: '${r.skipped}');
      r = await a.run();
      expect(r.down, 1, reason: '${r.skipped}');
      expect(r.both, 0);
      expect(File('${a.root}/top.txt').readAsStringSync(), 'top, changed on b');
      expect(Directory(a.root).listSync(recursive: true).whereType<File>().length, 2);
      expect((await a.run()).moved, 0);
      expect((await b.run()).moved, 0);
      // The change replaced the older in the log itself (an add, then the older's `del`, which every build reads):
      // My files lists one top.txt on both devices, not two.
      final drive = Drive.channelOf(Me.mineKeyOf(words));
      for (final s in stores) {
        await s.of(drive).refresh();
        expect([for (final f in s.of(drive).files.values) if (f.name == 'top.txt') f].length, 1);
      }

      // Removed on a: removed from My files, and moved aside on b into its hidden folder, never deleted.
      File('${a.root}/top.txt').deleteSync();
      r = await a.run();
      expect(r.deletedThere, 1, reason: '${r.skipped}');
      r = await b.run();
      expect(r.removedHere, 1, reason: '${r.skipped}');
      expect(File('${b.root}/top.txt').existsSync(), isFalse);
      expect(File('${b.root}/${FolderSyncEngine.binName}/top.txt').readAsStringSync(), 'top, changed on b');
      await stores[0].of(drive).refresh();
      expect([for (final f in stores[0].of(drive).files.values) f.name], ['lease.txt']);
      expect((await a.run()).moved, 0);
      expect((await b.run()).moved, 0);
    } finally {
      for (final s in stores) {
        await s.clear();
      }
      await relay.stop();
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
