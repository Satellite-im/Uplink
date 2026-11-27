// "Sync a folder" in My files on a computer (GMFB-38: "Sync a folder on your computer with a drive"): the entry's
// words, the folder chosen shown with its path and state line, a refused folder said why, and Stop syncing.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/drive.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/files/folder_sync.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/files_space/folder_sync_entry.dart';
import 'package:ghost_messaging/ui/files_space/my_files.dart';

import 'support/list_harness.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

class _NoDrive implements SyncDrive {
  @override
  String get id => 'none';
  @override
  int get maxFile => 0;
  @override
  int? get free => null;
  @override
  Future<List<DriveFile>?> list() async => const [];
  @override
  Future<DriveFile?> upload(String local, String? folder, String name) async => null;
  @override
  Future<String> fetch(DriveFile f) async => throw const SyncSkip('none');
  @override
  Future<bool> delete(DriveFile f) async => true;
}

/// Files the test lists, removed when the sync says so.
class _ListDrive extends _NoDrive {
  final Map<String, DriveFile> files = {};
  @override
  Future<List<DriveFile>?> list() async => files.values.toList();
  @override
  Future<DriveFile?> upload(String local, String? folder, String name) async {
    final bytes = File(local).readAsBytesSync();
    final f = DriveFile(id: 'f${files.length + 1}-$name', path: folder == null ? name : '$folder/$name', size: bytes.length, sha: crypto.sha256.convert(bytes).toString(), at: files.length + 1);
    return files[f.id] = f;
  }

  @override
  Future<bool> delete(DriveFile f) async {
    files.remove(f.id);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final drive = Drive.channelOf(Me.mineKeyOf(AccountCrypto.newWords()));
  late Directory dir;
  late FilesStore store;

  setUp(() {
    ListPhone([]).install();
    dir = Directory(Directory.systemTemp.createTempSync('ghost-folder-sync-entry').resolveSymbolicLinksSync());
    store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: Directory('${dir.path}/store'));
  });
  tearDown(() async {
    await store.clear();
    dir.deleteSync(recursive: true);
  });

  FolderSync sync() => FolderSync(data: () => Directory('${dir.path}/app/folder-sync'), drive: () async => _NoDrive(), home: () => '${dir.path}/home', own: () => ['${dir.path}/app'], quiet: Duration.zero);

  testWidgets('a test\'s store alone shows no entry; with a sync it offers a folder, shows it, and stops', (tester) async {
    store.put(drive, [SpaceFile(id: '1'.padLeft(32, '0'), name: 'a.pdf', size: 9, mime: 'application/pdf', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: Drive.signerOf(drive)!.id, byName: 'Matt', at: 1)], info: const FilesInfo(used: 9, quota: 1 << 30));
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, MyFilesScreen(drive: () async => drive, store: store), AppState(), size: const Size(1100, 800), platform: 'desktop');
    expect(_key('folder-sync'), findsNothing);

    Directory('${dir.path}/home').createSync();
    final picked = Directory('${dir.path}/home/Synced')..createSync();
    var answer = '${dir.path}/home';
    final s = sync();
    await pumpScreen(tester, sheet, MyFilesScreen(key: const ValueKey('second'), drive: () async => drive, store: store, sync: s, pickFolder: () async => answer), AppState(), size: const Size(1100, 800), platform: 'desktop');
    expect(_key('folder-sync'), findsOneWidget);
    expect(find.text('Sync a folder'), findsOneWidget);
    expect(find.text('Keep a folder on this computer in step with My files.'), findsOneWidget);

    // The home folder itself is refused, and said why.
    await tester.tap(_key('folder-sync-choose'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(s.root, isNull);
    expect(find.textContaining('home folder can\'t be synced'), findsOneWidget);

    answer = picked.path;
    await tester.tap(_key('folder-sync-choose'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && (s.root == null || s.running); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(s.root, picked.path);
    expect(find.text(picked.path), findsOneWidget);
    expect(tester.widget<Text>(_key('folder-sync-line')).data, 'In step.');
    expect(find.textContaining('New, changed and removed files go both ways. A changed file replaces the older one in My files.'), findsOneWidget);
    expect(find.textContaining('the hidden folder .ghost-deleted here, never deleted'), findsOneWidget);

    await tester.tap(_key('folder-sync-stop'));
    await tester.pump();
    expect(s.root, isNull);
    expect(find.text('Sync a folder'), findsOneWidget);
    expect(picked.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
    // Let the toast go before the test ends.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  });

  // GMFB-38, "a Files space or the personal drive": the same entry in a Files space, in the space's name.
  testWidgets('a Files space\'s entry names the space, says who gets the files, and what a sync never does', (tester) async {
    final sheet = await loadSheet(tester);
    final picked = Directory('${dir.path}/Team')..createSync();
    final s = FolderSync(data: () => Directory('${dir.path}/app/folder-sync'), drive: () async => _NoDrive(), home: () => '${dir.path}/home', own: () => ['${dir.path}/app'], quiet: Duration.zero, space: 'abc123', driveName: 'Team files');
    await pumpScreen(tester, sheet, FolderSyncEntry(sync: s, pick: () async => picked.path), AppState(), size: const Size(1100, 800), platform: 'desktop');
    expect(find.text('Keep a folder on this computer in step with Team files. Everyone in the space gets what is in it.'), findsOneWidget);
    await tester.tap(_key('folder-sync-choose'));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && (s.root == null || s.running); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(find.text(picked.path), findsOneWidget);
    expect(tester.widget<Text>(_key('folder-sync-rules')).data, allOf(contains('replaces the older one in Team files'), contains('A file removed from Team files is moved into the hidden folder .ghost-deleted here')));
    expect(tester.takeException(), isNull);
  });

  // GMFB-38: many files gone at once are asked about, not removed.
  testWidgets('many files gone at once ask before anything is removed, and Remove them removes them', (tester) async {
    final sheet = await loadSheet(tester);
    final picked = Directory('${dir.path}/Many')..createSync();
    for (var i = 0; i < 6; i++) {
      File('${picked.path}/f$i.txt').writeAsStringSync('$i');
    }
    final d = _ListDrive();
    final s = FolderSync(data: () => Directory('${dir.path}/app/folder-sync'), drive: () async => d, home: () => '${dir.path}/home', own: () => ['${dir.path}/app'], quiet: Duration.zero);
    Future<void> settle() => tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          for (var i = 0; i < 200 && s.running; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
    await tester.runAsync(() async {
      // Old enough not to be "still being written".
      for (final f in picked.listSync()) {
        (f as File).setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
      }
    });
    await pumpScreen(tester, sheet, FolderSyncEntry(sync: s, pick: () async => picked.path), AppState(), size: const Size(1100, 800), platform: 'desktop');
    await tester.tap(_key('folder-sync-choose'));
    await settle();
    await tester.pump();
    expect(d.files.length, 6);
    expect(_key('folder-sync-held'), findsNothing);
    for (var i = 0; i < 4; i++) {
      File('${picked.path}/f$i.txt').deleteSync();
    }
    await tester.runAsync(s.pass);
    await tester.pump();
    expect(tester.widget<Text>(_key('folder-sync-held')).data, '4 files are gone from this folder. Remove them from My files too?');
    expect(tester.widget<Text>(_key('folder-sync-line')).data, 'Waiting for you: 4 files are gone.');
    expect(d.files.length, 6, reason: 'nothing removed while asked');
    await tester.tap(_key('folder-sync-remove-held'));
    await settle();
    await tester.pump();
    expect(_key('folder-sync-held'), findsNothing);
    expect(d.files.length, 2);
    expect(tester.widget<Text>(_key('folder-sync-line')).data, 'In step.');
    expect(tester.takeException(), isNull);
  });
}
