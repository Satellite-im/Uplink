// The Files space screen (Matt, 2026-11-17: "add full functionality for filesharing in a space when the space is
// designated a Files Space"). Apart from test/files_space_test.dart: a widget test's binding answers every HTTP request
// with a 400, and those tests talk to a real relay.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/file_platform.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/circles/circle_screen.dart' show circleSpacePage;
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

void main() {
  group('the Files space screen', () {
    const space = VoiceChannel(seed: '9191919191919191919191919191919191919191919191919191919191919191', name: 'Drop box', kind: SpaceKind.files);
    late Directory dir;
    late FilesStore store;
    final me = KeysSigner(NetKeys.generate());
    SpaceFile file(int n, String name, int size, int at, {String? folder, String by = 'maya'}) =>
        SpaceFile(id: n.toRadixString(16).padLeft(32, '0'), name: name, size: size, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: by, byName: 'Maya', at: at, folder: folder);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ghost-files-screen');
      store = FilesStore.forTest(base: null, signer: me, data: dir);
      store.put(space, [file(1, 'b.png', 300, 3), file(2, 'A.pdf', 900, 1, folder: 'Work'), file(3, 'notes.md', 20, 2)], folders: {'Work'}, info: const FilesInfo(used: 1220, quota: 1 << 30));
    });
    tearDown(() async {
      await store.clear();
      dir.deleteSync(recursive: true);
    });

    List<String> rows() => [for (final e in find.byType(FileRow).evaluate()) (e.widget as FileRow).file.name];

    testWidgets('lists, searches, opens a folder, sorts, turns to a grid, and stops an upload', (tester) async {
      final sheet = await loadSheet(tester);
      final state = AppState();
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: space, store: store), state);
      // The top: its folder first, then its own files, newest first.
      expect(find.byType(FolderRow), findsOneWidget);
      expect(rows(), ['b.png', 'notes.md'], reason: 'newest first, A.pdf in Work');
      expect(find.text('3 files · 1 KB'), findsWidgets);
      expect(find.byKey(const ValueKey('files-quota')), findsOneWidget);
      // Search: on a phone a magnifier in the controls' row, the field once it is pressed. It looks in every folder.
      expect(find.byType(EditableText), findsNothing);
      await tester.tap(find.byKey(const ValueKey('files-search-open')));
      await settle(tester);
      await tester.enterText(find.byType(EditableText).first, 'pdf');
      await settle(tester);
      expect(rows(), ['A.pdf']);
      await tester.enterText(find.byType(EditableText).first, 'maya');
      await settle(tester);
      expect(rows(), ['b.png', 'notes.md', 'A.pdf']);
      // Sorted by name, kept as the person's choice.
      await tester.tap(find.byKey(const ValueKey('files-sort')));
      await settle(tester);
      await tester.tap(find.text('Name'));
      await settle(tester);
      expect(rows(), ['A.pdf', 'b.png', 'notes.md']);
      expect(state.choice('files_sort', ''), 'name');
      await tester.enterText(find.byType(EditableText).first, '');
      await settle(tester);
      // A folder's row opens it; the path's top chip goes back.
      await tester.tap(find.byKey(const ValueKey('folder-Work')));
      await settle(tester);
      expect(rows(), ['A.pdf']);
      expect(find.byKey(const ValueKey('crumb-Work')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-all')));
      await settle(tester);
      expect(rows(), ['b.png', 'notes.md']);
      expect(find.byKey(const ValueKey('crumb-Work')), findsNothing);
      // The grid: the folder's tile, then the files'.
      await tester.tap(find.bySemanticsLabel('Grid'));
      await settle(tester);
      expect(find.byType(FolderTile), findsOneWidget);
      expect(find.byType(FileTile), findsNWidgets(2));
      expect(state.choice('files_view', ''), 'grid');
      // A file going up shows with its progress, and its X stops it.
      final t = Transfer.shown(space: space, name: 'clip.mov', size: 1000, done: 400);
      store.putTransfer(t);
      await settle(tester);
      expect(find.text('400 B of 1 KB'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('cancel-${t.id}')));
      await settle(tester);
      expect(store.transfers, isEmpty);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-18: "allow root level folders in the file sharing tab and nested folders".
    testWidgets('nested folders: rows before files, a path of chips to go back up, back goes up, and a folder\'s menu', (tester) async {
      const nested = VoiceChannel(seed: '9494949494949494949494949494949494949494949494949494949494949494', name: 'Shelves', kind: SpaceKind.files);
      store.put(nested, [file(1, 'plan.pdf', 300, 3, folder: 'Work', by: me.id), file(2, 'q1.xlsx', 900, 1, folder: 'Work/2027/Q1', by: me.id)], folders: {'Empty', 'Work/2027/Q2'});
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: nested, store: store), AppState());
      List<String> folders() => [for (final e in find.byType(FolderRow).evaluate()) (e.widget as FolderRow).name];
      expect(folders(), ['Empty', 'Work']);
      expect(rows(), isEmpty);
      expect(find.text('2 files · 3 folders'), findsOneWidget, reason: 'what Work holds, at any depth');
      expect(find.text('Empty'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('folder-Work')));
      await settle(tester);
      expect(folders(), ['2027']);
      expect(rows(), ['plan.pdf']);
      await tester.tap(find.byKey(const ValueKey('folder-Work/2027')));
      await settle(tester);
      expect(folders(), ['Q1', 'Q2']);
      expect(find.byKey(const ValueKey('crumb-Work')), findsOneWidget);
      expect(find.byKey(const ValueKey('crumb-Work/2027')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-Work/2027/Q2')));
      await settle(tester);
      expect(find.text('This folder is empty. Add files or folders while it is open and they go in it.'), findsOneWidget);
      // The path's chip for Work goes straight there.
      await tester.tap(find.byKey(const ValueKey('crumb-Work')));
      await settle(tester);
      expect(rows(), ['plan.pdf']);
      // Back goes up a folder before it leaves the space.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(folders(), ['Empty', 'Work']);
      expect(find.byType(FilesSpaceScreen), findsOneWidget);
      // A folder's menu: open, a folder in it, rename, move and delete.
      await tester.longPress(find.byKey(const ValueKey('folder-Work')));
      await settle(tester);
      for (final w in ['Open', 'New folder in it', 'Rename', 'Move to folder', 'Delete']) {
        expect(find.text(w), findsOneWidget, reason: w);
      }
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(find.text('Delete the folder, keep what\'s in it'), findsOneWidget);
      expect(find.text('Delete it and everything in it'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty space says how to add files, with one Upload and nothing to sort or search', (tester) async {
      const empty = VoiceChannel(seed: '9292929292929292929292929292929292929292929292929292929292929292', name: 'Hand-ins', kind: SpaceKind.files);
      store.put(empty, const []);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: empty, store: store), AppState());
      expect(find.text('No files yet'), findsWidgets);
      expect(find.byKey(const ValueKey('files-upload')), findsOneWidget);
      expect(find.byKey(const ValueKey('files-sort')), findsNothing);
      expect(find.byKey(const ValueKey('folder-all')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a file over the limit offers no Try again; one that may go again does', (tester) async {
      final sheet = await loadSheet(tester);
      store.putTransfer(Transfer.shown(space: space, name: 'huge.zip', size: 9000, state: TransferState.failed, error: 'Too big: files can be up to 2.1 GB each.', retryable: false));
      store.putTransfer(Transfer.shown(space: space, name: 'cut.mov', size: 9000, state: TransferState.failed, error: 'The connection dropped.'));
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: space, store: store), AppState());
      expect(find.text('Too big: files can be up to 2.1 GB each.'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Matt, 2026-11-21: "I need a way to see partially uploaded files, the oddysey uploaded partially but then
    // disconnected when I restarted the app it stopped uploading but kept the space reserved".
    testWidgets('unfinished uploads show how far they got, and only one this device may let go has Remove', (tester) async {
      final sheet = await loadSheet(tester);
      final at = DateTime.now().subtract(const Duration(hours: 3));
      store.put(space, [file(1, 'b.png', 300, 3)], info: FilesInfo(used: 26000000300, quota: 50000000000, parts: [
        FilesPart(id: 'a' * 32, by: me.id, size: 26000000000, have: 12300000000, at: at),
        FilesPart(id: 'b' * 32, by: 'someone-else', size: 4000000000, have: 1000000000, at: at),
      ]));
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: space, store: store), AppState());
      expect(find.text('Unfinished upload'), findsNWidgets(2));
      expect(find.textContaining('of 26'), findsOneWidget);
      expect(find.textContaining('stopped 3 hours ago · yours'), findsOneWidget);
      expect(find.byKey(ValueKey('remove-part-${'a' * 32}')), findsOneWidget);
      expect(find.byKey(ValueKey('remove-part-${'b' * 32}')), findsNothing, reason: 'not theirs to remove: not the owner, not who started it');
      await tester.tap(find.byKey(ValueKey('remove-part-${'a' * 32}')));
      await settle(tester);
      expect(find.text('Remove it'), findsOneWidget);
      expect(find.textContaining('It can\'t go on from here'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on a wide window the files are in columns under a header', (tester) async {
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, FilesSpaceScreen(channel: space, store: store), AppState(), size: const Size(1280, 800));
      expect(find.byType(FileColumnsHeader), findsOneWidget);
      expect(find.text('ADDED BY'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget, reason: 'the search has room in the one row');
      expect(tester.takeException(), isNull);
    });

    test('a name is one every system can keep, and a program is never opened', () {
      expect(SpaceFile.cleanName('invoice\u202Efdp.exe'), 'invoicefdp.exe');
      expect(SpaceFile.cleanName('..'), 'file');
      expect(SpaceFile.cleanName('a/b:c?.txt'), 'a_b_c_.txt');
      expect(SpaceFile.cleanName('CON.txt'), '_CON.txt');
      expect(SpaceFile.cleanName('notes. . '), 'notes');
      expect(FilePlatform.runsCode('setup.command'), isTrue);
      expect(FilePlatform.runsCode('Uplink.APK'), isTrue);
      expect(FilePlatform.runsCode('report.pdf'), isFalse);
    });

    test('a circle\'s Files space opens its files', () {
      expect(circleSpacePage(space), isA<FilesSpaceScreen>());
      expect(circleSpacePage(const VoiceChannel(seed: '9393939393939393939393939393939393939393939393939393939393939393', name: 'Chat', kind: SpaceKind.text)), isNot(isA<FilesSpaceScreen>()));
    });
  });
}
