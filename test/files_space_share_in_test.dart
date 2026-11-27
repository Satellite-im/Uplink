// The "Add … to" sheet for files brought into the app from outside a Files space: shared in from another app on a
// phone, or dropped on a Mac's window (Matt, 2026-11-17: "Finish the missing pieces that went unfinished" of Files
// spaces). It names the files with their sizes and total before anything is copied, lists the Files spaces this device
// can add to across circles, and copies only once one is chosen.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/files_space/file_badge.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/ui/files_space/share_in.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

const _own = VoiceChannel(seed: '7171717171717171717171717171717171717171717171717171717171717171', name: 'Hand-ins', kind: SpaceKind.files);
const _photos = VoiceChannel(seed: '7272727272727272727272727272727272727272727272727272727272727272', name: 'Photos', kind: SpaceKind.files, circle: _owlsSeed);
const _drop = VoiceChannel(seed: '7373737373737373737373737373737373737373737373737373737373737373', name: 'Drop box', kind: SpaceKind.files, circle: _bookSeed);
const _talk = VoiceChannel(seed: '7474747474747474747474747474747474747474747474747474747474747474', name: 'Lounge', circle: _owlsSeed);
const _locked = VoiceChannel(seed: '7575757575757575757575757575757575757575757575757575757575757575', name: 'Read only', kind: SpaceKind.files);

const _owlsSeed = '7676767676767676767676767676767676767676767676767676767676767676';
const _bookSeed = '7777777777777777777777777777777777777777777777777777777777777777';
final _owls = Circle(seed: _owlsSeed, owner: '', manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles'));
final _book = Circle(seed: _bookSeed, owner: '', manifest: CircleManifest(owner: '', version: 1, name: 'Book Club', hue: 'amber', icon: 'book'));
Circle? _circleOf(VoiceChannel c) => switch (c.circle) { _owlsSeed => _owls, _bookSeed => _book, _ => null };

const _files = [
  IncomingFile(source: 'content://com.example.photos/1', name: 'Sunset at the pier.jpg', size: 3200000, mime: 'image/jpeg'),
  IncomingFile(source: 'content://com.example.docs/2', name: 'Q3 report.pdf', size: 2100000, mime: 'application/pdf'),
  IncomingFile(source: 'content://com.example.docs/3', name: 'budget 2027.xlsx', size: 84000),
];

/// A page that asks, as the share does, once it is up.
class _Asker extends StatefulWidget {
  const _Asker(this.ask);
  final void Function(BuildContext context) ask;
  @override
  State<_Asker> createState() => _AskerState();
}

class _AskerState extends State<_Asker> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.ask(context));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  group('what is brought in', () {
    test('the total says how many and how big, and "over" where a size is not known', () {
      expect(incomingTotal(_files), '3 files · 5.4 MB');
      expect(incomingTotal(const [IncomingFile(source: 'a', name: 'a.txt', size: 820)]), '1 file · 820 B');
      expect(incomingTotal(const [..._files, IncomingFile(source: 'x', name: 'x.bin')]), '4 files · over 5.4 MB');
      expect(incomingTotal(const [IncomingFile(source: 'x', name: 'x.bin')]), '1 file');
      expect(incomingTitle(_files.take(1).toList()), 'Add “Sunset at the pier.jpg” to');
      expect(incomingTitle(_files), 'Add 3 files to');
    });

    test('a file known only by its address is named from it', () {
      final f = IncomingFile.ofUri('content://com.example.files/document/My%20notes.md');
      expect(f.name, 'My notes.md');
      expect(f.size, -1);
      expect(f.kind, FileKind.text);
      // As the phone names one it is given no name for (MainActivity.cleanFileName).
      expect(IncomingFile.ofUri('content://com.example/').name, 'file');
    });

    test('dropped paths are read for their sizes, and folders are left out', () {
      final dir = Directory.systemTemp.createTempSync('ghost-share-in');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/clip.mov')..writeAsBytesSync(List.filled(1500, 1));
      final folder = Directory('${dir.path}/Trip')..createSync();
      final files = IncomingFile.ofPaths([a.path, folder.path, '${dir.path}/gone.txt']);
      expect([for (final f in files) (f.name, f.size, f.kind)], [('clip.mov', 1500, FileKind.video)]);
      expect(files.single.source, a.path);
    });

    test('the spaces offered: Files spaces this device may add to, its own first, then circle by circle', () {
      final spaces = addableFilesSpaces(from: const [_talk, _photos, _locked, _drop, _own], may: (c) => c != _locked, circleOf: _circleOf);
      // Book Club before Night Owls; a voice space and one this device may not add to are left out.
      expect([for (final c in spaces) c.name], ['Hand-ins', 'Drop box', 'Photos']);
    });
  });

  group('the "Add … to" sheet', () {
    testWidgets('names each file with its kind and size, says the total, and copies nothing until a space is chosen', (tester) async {
      final sheet = await loadSheet(tester);
      final kept = <String>[];
      final sent = <String>[];
      final opened = <String>[];
      await pumpScreen(
        tester,
        sheet,
        _Asker((context) => FilesShareIn.offer(
              context,
              _files,
              spaces: const [_own, _drop, _photos],
              circleOf: _circleOf,
              keep: (source) async {
                kept.add(source);
                return '/kept/${source.split('/').last}';
              },
              owned: true,
              upload: (c, paths, owned) => sent.add('${c.name}: ${paths.join(', ')}${owned ? ' (copies)' : ''}'),
              open: (_, c) => opened.add(c.name),
            )),
        AppState(),
      );
      await settle(tester);
      expect(find.text('Add 3 files to'), findsOneWidget);
      for (final name in ['Sunset at the pier.jpg', 'Q3 report.pdf', 'budget 2027.xlsx']) {
        expect(find.text(name), findsOneWidget);
      }
      for (final size in ['3.2 MB', '2.1 MB', '84 KB']) {
        expect(find.text(size), findsOneWidget);
      }
      expect(find.text('3 files · 5.4 MB'), findsOneWidget);
      // Each file's kind: a picture, a PDF, a spreadsheet.
      expect([for (final e in find.byType(FileBadge).evaluate()) (e.widget as FileBadge).kind], [FileKind.image, FileKind.pdf, FileKind.sheet]);
      // The spaces, a circle's named with its circle.
      expect(find.text('Hand-ins'), findsOneWidget);
      expect(find.text('Files space'), findsOneWidget);
      expect(find.text('Files space in Book Club'), findsOneWidget);
      expect(find.text('Files space in Night Owls'), findsOneWidget);
      expect(kept, isEmpty, reason: 'nothing is copied before a space is chosen');

      await tester.tap(find.text('Drop box'));
      await settle(tester);
      expect(kept, ['content://com.example.photos/1', 'content://com.example.docs/2', 'content://com.example.docs/3']);
      expect(sent, ['Drop box: /kept/1, /kept/2, /kept/3 (copies)']);
      expect(opened, ['Drop box']);
      expect(find.text('Add 3 files to'), findsNothing, reason: 'the sheet went');
    });

    testWidgets('a long list names the first few and says how many more', (tester) async {
      final sheet = await loadSheet(tester);
      final many = [for (var i = 1; i <= 8; i++) IncomingFile(source: 'content://com.example/$i', name: 'scan $i.png', size: 1000 * i)];
      await pumpScreen(tester, sheet, _Asker((context) => FilesShareIn.offer(context, many, spaces: const [_own], upload: (_, _, _) {}, open: (_, _) {})), AppState());
      await settle(tester);
      expect(find.text('scan 4.png'), findsOneWidget);
      expect(find.text('scan 5.png'), findsNothing);
      expect(find.text('and 4 more'), findsOneWidget);
      expect(find.text('8 files · 36 KB'), findsOneWidget);
    });

    testWidgets('a file that cannot be read is said so, and the rest still go', (tester) async {
      final sheet = await loadSheet(tester);
      final sent = <List<String>>[];
      await pumpScreen(
        tester,
        sheet,
        _Asker((context) => FilesShareIn.offer(context, _files, spaces: const [_own], keep: (s) async => s.endsWith('/2') ? null : s, upload: (_, paths, _) => sent.add(paths), open: (_, _) {})),
        AppState(),
      );
      await settle(tester);
      await tester.tap(find.text('Hand-ins'));
      await settle(tester);
      expect(sent, [
        ['content://com.example.photos/1', 'content://com.example.docs/3']
      ]);
      expect(find.text('Adding 2 files to Hand-ins. 1 file couldn\'t be read.'), findsOneWidget);
    });

    testWidgets('a drop on the window asks where only while no Files space is showing', (tester) async {
      final sheet = await loadSheet(tester);
      final dir = Directory.systemTemp.createTempSync('ghost-share-in-drop');
      final store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir);
      addTearDown(() async {
        await store.clear();
        dir.deleteSync(recursive: true);
      });
      final a = File('${dir.path}/minutes.docx')..writeAsBytesSync(List.filled(2400, 1));
      final sent = <String>[];
      void drop() => FilesShareIn.takeDrop([a.path], spaces: const [_own], upload: (c, paths, owned) => sent.add('${c.name}: ${paths.join(', ')}${owned ? ' (copies)' : ''}'), open: (_, _) {});

      // A Files space showing takes the drop itself: no sheet.
      final key = GlobalKey<NavigatorState>();
      FilesShareIn.attach(key);
      await pumpScreen(tester, sheet, Navigator(key: key, onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => FilesSpaceScreen(channel: _own, store: store))), AppState());
      expect(FilesShareIn.filesShowing(), isTrue);
      drop();
      await settle(tester);
      expect(find.text('Add “minutes.docx” to'), findsNothing);

      // Elsewhere in the app: the sheet, the file named with its size, sent from where it is (not copied).
      final other = GlobalKey<NavigatorState>();
      FilesShareIn.attach(other);
      await pumpScreen(tester, sheet, Navigator(key: other, onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SizedBox.expand())), AppState());
      expect(FilesShareIn.filesShowing(), isFalse);
      drop();
      await settle(tester);
      expect(find.text('Add “minutes.docx” to'), findsOneWidget);
      expect(find.text('2 KB'), findsOneWidget);
      await tester.tap(find.text('Hand-ins'));
      await settle(tester);
      expect(sent, ['Hand-ins: ${a.path}']);
    });

    testWidgets('with no Files space to add to, it says so and still names the files', (tester) async {
      final sheet = await loadSheet(tester);
      var sent = false;
      await pumpScreen(tester, sheet, _Asker((context) => FilesShareIn.offer(context, _files.take(1).toList(), spaces: const [], upload: (_, _, _) => sent = true)), AppState());
      await settle(tester);
      expect(find.textContaining('There is no Files space to add this file to yet'), findsOneWidget);
      expect(find.text('Sunset at the pier.jpg'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(sent, isFalse);
    });
  });
}
