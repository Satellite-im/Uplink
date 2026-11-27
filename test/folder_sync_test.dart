// A folder on a computer kept in step with My files (GMFB-38: "Sync a folder on your computer with a drive"): one
// pass's rules against a real temporary folder and a drive of the test's own. A changed file replaces the older one, a
// removal is followed only for a file the sync had in step (a local file is moved aside, never deleted), many gone at
// once wait for the person, and a local file is replaced only where its content is one the sync recorded.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/folder_sync.dart';

/// A drive in memory: files by id, each with its bytes. Like the real one, the same path added again is a newer file
/// beside the older until the older is removed ([delete], as the log's `del`).
class FakeDrive implements SyncDrive {
  FakeDrive(this.dir);
  final Directory dir;
  final Map<String, (DriveFile, List<int>)> files = {};
  int _n = 0, uploads = 0, fetches = 0;
  bool reachable = true;

  @override
  String get id => 'drive-1';
  @override
  int maxFile = 0;
  @override
  int? free;

  DriveFile put(String path, String text) {
    final bytes = utf8.encode(text);
    final f = DriveFile(id: 'f${++_n}', path: path, size: bytes.length, sha: crypto.sha256.convert(bytes).toString(), at: _n);
    files[f.id] = (f, bytes);
    return f;
  }

  void remove(String path) => files.removeWhere((_, v) => v.$1.path == path);
  List<DriveFile> of(String path) => [for (final v in files.values) if (v.$1.path == path) v.$1];

  /// Ids this device may not remove (someone else's, in a space), and how many were removed.
  final Set<String> refuse = {};
  int deletes = 0;

  @override
  Future<bool> delete(DriveFile f) async {
    if (refuse.contains(f.id)) return false;
    deletes++;
    files.remove(f.id);
    return true;
  }
  List<String> get paths => [for (final v in files.values) v.$1.path]..sort();
  String newest(String path) => utf8.decode((files.values.where((v) => v.$1.path == path).toList()..sort((a, b) => b.$1.at.compareTo(a.$1.at))).first.$2);

  @override
  Future<List<DriveFile>?> list() async => reachable ? [for (final v in files.values) v.$1] : null;

  @override
  Future<DriveFile?> upload(String local, String? folder, String name) async {
    uploads++;
    return put(folder == null ? name : '$folder/$name', File(local).readAsStringSync());
  }

  @override
  Future<String> fetch(DriveFile f) async {
    fetches++;
    final at = File('${dir.path}/cache/${f.id}')..parent.createSync(recursive: true);
    at.writeAsBytesSync(files[f.id]!.$2);
    return at.path;
  }
}

void main() {
  late Directory tmp;
  late String root;
  late FakeDrive drive;
  // The clock a pass reads: an hour on from the real one, so files the test has just written are not "still being
  // written" unless the test says so.
  var ahead = const Duration(hours: 1);
  DateTime now() => DateTime.now().add(ahead);

  File local(String path) => File('$root/$path');
  void write(String path, String text) => local(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
  List<String> localPaths() => [
        for (final e in Directory(root).listSync(recursive: true, followLinks: false))
          if (e is File) e.path.substring(root.length + 1),
      ]..sort();

  FolderSyncEngine engine({int most = 2000, Set<String> allow = const {}, Set<String> forget = const {}}) => FolderSyncEngine(root: root, drive: drive, state: SyncState(File('${tmp.path}/app/state.json')), now: now, most: most, allow: allow, forget: forget);
  Future<SyncReport> pass({int most = 2000}) => engine(most: most).run();

  setUp(() {
    tmp = Directory(Directory.systemTemp.createTempSync('ghost-folder-sync').resolveSymbolicLinksSync());
    root = FolderSyncEngine.resolve((Directory('${tmp.path}/Synced')..createSync()).path)!;
    drive = FakeDrive(tmp);
    ahead = const Duration(hours: 1);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a file new in the folder goes up under the same path, its folders with it', () async {
    write('notes.txt', 'one');
    write('Trip/Day 2/plan.md', 'two');
    final r = await pass();
    expect(r.stopped, isNull);
    expect(r.up, 2);
    expect(drive.paths, ['Trip/Day 2/plan.md', 'notes.txt']);
    expect(drive.newest('Trip/Day 2/plan.md'), 'two');
    expect(r.line, 'In step.');
  });

  test('a file new in the drive comes down, under a temporary name until it is whole', () async {
    drive.put('Papers/lease.pdf', 'lease');
    drive.put('top.txt', 'top');
    final r = await pass();
    expect(r.down, 2);
    expect(local('Papers/lease.pdf').readAsStringSync(), 'lease');
    expect(local('top.txt').readAsStringSync(), 'top');
    expect(localPaths(), ['Papers/lease.pdf', 'top.txt'], reason: 'no temporary file is left');
    expect(drive.uploads, 0);
  });

  test('a pass after nothing changed moves nothing', () async {
    write('a.txt', 'a');
    drive.put('b.txt', 'b');
    await pass();
    final ups = drive.uploads, downs = drive.fetches;
    final r = await pass();
    expect(r.moved, 0);
    expect(r.line, 'In step.');
    expect(drive.uploads, ups);
    expect(drive.fetches, downs);
    expect(drive.files.length, 2);
  });

  test('changed here replaces the older in the drive; changed there comes down over the copy the sync recorded', () async {
    write('a.txt', 'a1');
    write('b.txt', 'b1');
    await pass();
    write('a.txt', 'a2 longer');
    drive.put('b.txt', 'b2 from the drive');
    final r = await pass();
    expect(r.up, 1);
    expect(r.down, 1);
    expect(r.both, 0);
    expect(drive.newest('a.txt'), 'a2 longer');
    expect(local('b.txt').readAsStringSync(), 'b2 from the drive');
    expect(localPaths(), ['a.txt', 'b.txt']);
    // GMFB-38, "the files log has no replace": the older a.txt is removed once the newer is up, not left beside it.
    expect(drive.of('a.txt').length, 1);
    // And b1, which the test's drive left beside b2 as a build from before would: the sync had it in step.
    expect(drive.of('b.txt').length, 1);
    expect(drive.deletes, 2);
    expect((await pass()).moved, 0);
  });

  test('both changed keeps both: the drive\'s beside it with a suffix, the local one untouched and sent up', () async {
    write('doc.txt', 'first');
    await pass();
    write('doc.txt', 'mine, changed here');
    drive.put('doc.txt', 'theirs, changed there');
    final r = await pass();
    expect(r.both, 1);
    expect(local('doc.txt').readAsStringSync(), 'mine, changed here');
    expect(local('doc (from My files).txt').readAsStringSync(), 'theirs, changed there');
    expect(drive.newest('doc.txt'), 'mine, changed here');
    // The path was in step before: the drive's is replaced, its words kept beside here, which go up next pass.
    expect(drive.of('doc.txt').length, 1);
    final again = await pass();
    expect(again.both, 0);
    expect(localPaths(), ['doc (from My files).txt', 'doc.txt']);
    expect(drive.paths, ['doc (from My files).txt', 'doc.txt']);
    expect(drive.newest('doc (from My files).txt'), 'theirs, changed there');
    expect((await pass()).moved, 0);
  });

  test('a file on both sides the sync has no record of is never replaced: same content is in step, different keeps both', () async {
    write('same.txt', 'equal');
    drive.put('same.txt', 'equal');
    write('diff.txt', 'local words');
    drive.put('diff.txt', 'drive words');
    final r = await pass();
    expect(local('diff.txt').readAsStringSync(), 'local words');
    expect(local('diff (from My files).txt').readAsStringSync(), 'drive words');
    expect(r.both, 1);
    expect(drive.files.values.where((v) => v.$1.path == 'same.txt').length, 1, reason: 'not sent again');
    // Never in step before: the drive's diff.txt is someone's file the sync never had, and stays.
    expect(drive.of('diff.txt').length, 2);
    expect(drive.deletes, 0);
  });

  test('a local file changed without its size or time showing it is still not replaced (its content is checked)', () async {
    write('a.txt', 'aaaa');
    await pass();
    final when = local('a.txt').lastModifiedSync();
    write('a.txt', 'bbbb');
    local('a.txt').setLastModifiedSync(when);
    drive.put('a.txt', 'from the drive');
    final r = await pass();
    expect(local('a.txt').readAsStringSync(), 'bbbb');
    expect(local('a (from My files).txt').readAsStringSync(), 'from the drive');
    expect(r.both, 1);
  });

  // GMFB-38: deletes, both ways, only of what the sync had in step.
  test('removed here is removed from the drive; removed there is moved into .ghost-deleted here, never deleted', () async {
    write('here.txt', 'here');
    write('Trip/there.txt', 'there');
    write('keep.txt', 'keep');
    await pass();
    local('here.txt').deleteSync();
    drive.remove('Trip/there.txt');
    final r = await pass();
    expect(r.stopped, isNull);
    expect(r.deletedThere, 1);
    expect(r.removedHere, 1);
    expect(drive.paths, ['keep.txt']);
    expect(local('Trip/there.txt').existsSync(), isFalse);
    expect(File('$root/.ghost-deleted/Trip/there.txt').readAsStringSync(), 'there', reason: 'moved aside, whole');
    // Nothing comes back, and what was set aside is hidden from the sync.
    final again = await pass();
    expect(again.moved, 0);
    expect(drive.paths, ['keep.txt']);
    expect(local('here.txt').existsSync(), isFalse);
    // Removed there a second time under the same name: set aside beside the first, never over it.
    write('Trip/there.txt', 'there again');
    await pass();
    drive.remove('Trip/there.txt');
    await pass();
    expect(File('$root/.ghost-deleted/Trip/there (2).txt').readAsStringSync(), 'there again');
    expect(File('$root/.ghost-deleted/Trip/there.txt').readAsStringSync(), 'there');
  });

  test('a file on one side the sync never had in step is never removed, and one changed meanwhile goes the other way', () async {
    write('synced-here.txt', 'one');
    write('synced-there.txt', 'two');
    await pass();
    // Never synced: new on each side while the other's copy is gone. Each is sent or brought, never removed.
    write('only-here.txt', 'local only');
    drive.put('only-there.txt', 'drive only');
    // Removed here, but changed in the drive since: the drive's comes down.
    local('synced-here.txt').deleteSync();
    drive.put('synced-here.txt', 'changed there');
    // Removed in the drive, but changed here since: it goes up again.
    drive.remove('synced-there.txt');
    write('synced-there.txt', 'changed here, longer');
    final r = await pass();
    expect(r.deletedThere, 0);
    expect(r.removedHere, 0);
    expect(local('only-there.txt').readAsStringSync(), 'drive only');
    expect(drive.newest('only-here.txt'), 'local only');
    expect(local('synced-here.txt').readAsStringSync(), 'changed there');
    expect(drive.newest('synced-there.txt'), 'changed here, longer');
    expect(Directory('$root/.ghost-deleted').existsSync(), isFalse);
  });

  test('a local file changed without its size or time showing it is sent up, not set aside, when the drive removed it', () async {
    write('a.txt', 'aaaa');
    await pass();
    final when = local('a.txt').lastModifiedSync();
    write('a.txt', 'bbbb');
    local('a.txt').setLastModifiedSync(when);
    drive.remove('a.txt');
    final r = await pass();
    expect(r.removedHere, 0);
    expect(local('a.txt').readAsStringSync(), 'bbbb');
    expect(drive.newest('a.txt'), 'bbbb');
  });

  test('a changed file that isn\'t this device\'s to replace leaves both; one not this device\'s to remove comes back', () async {
    write('a.txt', 'a1');
    write('b.txt', 'b1');
    await pass();
    drive.refuse.addAll([for (final f in drive.files.values) f.$1.id]);
    write('a.txt', 'a2 longer');
    local('b.txt').deleteSync();
    final r = await pass();
    expect(drive.of('a.txt').length, 2);
    expect(r.skipped.keys, contains('whose older copy in My files isn\'t yours to remove'));
    expect(r.skipped.keys, contains('that aren\'t yours to remove from My files, so they come back'));
    // Next pass: a.txt in step on the newer, the older never brought down over it; b.txt back.
    final again = await pass();
    expect(local('a.txt').readAsStringSync(), 'a2 longer');
    expect(local('b.txt').readAsStringSync(), 'b1');
    expect(again.down, 1);
    expect((await pass()).moved, 0);
  });

  test('an older copy of a path left in the drive by a build from before never comes down once the newer is removed', () async {
    write('a.txt', 'v1');
    await pass();
    // Another computer's older build sent its change beside the first, as builds before the replace did. The first is
    // the sync's, so it is removed once the newer comes down.
    drive.put('a.txt', 'v2 from an old build');
    await pass();
    expect(local('a.txt').readAsStringSync(), 'v2 from an old build');
    expect(drive.of('a.txt').length, 1);
    expect(drive.newest('a.txt'), 'v2 from an old build');

    // In a space, where the older is someone else's this device may not remove, it stays beside the newer.
    final first = drive.of('a.txt').single;
    drive.refuse.add(first.id);
    drive.put('a.txt', 'v3 from an old build');
    await pass();
    expect(local('a.txt').readAsStringSync(), 'v3 from an old build');
    expect(drive.of('a.txt').length, 2);
    // The newer removed in the drive: the folder follows, and v2 is not brought back from under it.
    drive.files.remove(drive.of('a.txt').reduce((x, y) => x.at > y.at ? x : y).id);
    final r = await pass();
    expect(r.removedHere, 1);
    expect(r.down, 0);
    expect(local('a.txt').existsSync(), isFalse);
    expect((await pass()).down, 0);
    expect(local('a.txt').existsSync(), isFalse);
    expect(drive.of('a.txt').single.id, first.id, reason: 'left in the drive, never brought down');
  });

  test('state from a build before the drive\'s time was kept learns it on the first pass, and then holds an older copy back', () async {
    write('a.txt', 'v1');
    await pass();
    // v1 stays beside v2 (not this device's to remove).
    drive.refuse.add(drive.of('a.txt').single.id);
    drive.put('a.txt', 'v2');
    await pass();
    expect(drive.of('a.txt').length, 2);
    // As a build from before kept it: no 'a'.
    final f = File('${tmp.path}/app/state.json');
    final j = jsonDecode(f.readAsStringSync()) as Map;
    for (final e in (j['files'] as Map).values) {
      (e as Map).remove('a');
    }
    f.writeAsStringSync(jsonEncode(j));
    expect((await pass()).moved, 0);
    expect(((jsonDecode(f.readAsStringSync()) as Map)['files'] as Map)['a.txt']['a'], isNotNull);
    drive.files.remove(drive.of('a.txt').reduce((x, y) => x.at > y.at ? x : y).id);
    final r = await pass();
    expect(r.down, 0);
    expect(local('a.txt').existsSync(), isFalse);
  });

  group('many gone at once', () {
    test('more than 20 removed from the folder are held: nothing removed from the drive and nothing brought back', () async {
      for (var i = 0; i < 25; i++) {
        write('f$i.txt', '$i');
      }
      await pass();
      for (var i = 0; i < 25; i++) {
        local('f$i.txt').deleteSync();
      }
      final r = await pass();
      expect(r.heldHere.length, 25);
      expect(r.heldThere, isEmpty);
      expect(r.deletedThere, 0);
      expect(r.down, 0);
      expect(drive.files.length, 25);
      expect(localPaths(), isEmpty);
      expect(r.line, 'Waiting for you: 25 files are gone.');
      // Held again next pass, until the person says.
      expect((await pass()).heldHere.length, 25);
      // Yes: removed, however many.
      final yes = await engine(allow: {...r.heldHere}).run();
      expect(yes.deletedThere, 25);
      expect(drive.files, isEmpty);
    });

    test('more than half of those in step removed from the drive are held; a few are not', () async {
      for (var i = 0; i < 8; i++) {
        write('f$i.txt', '$i');
      }
      await pass();
      drive.remove('f0.txt');
      drive.remove('f1.txt');
      expect((await pass()).removedHere, 2, reason: 'two of eight go as they are');
      for (var i = 2; i < 7; i++) {
        drive.remove('f$i.txt');
      }
      final r = await pass();
      expect(r.heldThere.length, 5, reason: 'five of the six left');
      expect(r.removedHere, 0);
      expect(r.up, 0, reason: 'not sent up again while held');
      expect(localPaths(), ['.ghost-deleted/f0.txt', '.ghost-deleted/f1.txt', 'f2.txt', 'f3.txt', 'f4.txt', 'f5.txt', 'f6.txt', 'f7.txt']);
      // No: kept, as never synced, so each goes up again.
      final no = await engine(forget: {...r.heldThere}).run();
      expect(no.up, 5);
      expect(drive.paths, ['f2.txt', 'f3.txt', 'f4.txt', 'f5.txt', 'f6.txt', 'f7.txt']);
    });

    test('the choice asks, and Remove them and Keep them are each for that pass', () async {
      final s = FolderSync(data: () => Directory('${tmp.path}/app/folder-sync'), drive: () async => drive, home: () => '${tmp.path}/home', own: () => ['${tmp.path}/app'], quiet: Duration.zero);
      for (var i = 0; i < 6; i++) {
        write('f$i.txt', '$i');
      }
      expect(s.choose(root), isNull);
      while (s.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      for (var i = 0; i < 4; i++) {
        local('f$i.txt').deleteSync();
      }
      await s.pass();
      expect(s.heldHere.length, 4);
      expect(s.line, 'Waiting for you: 4 files are gone.');
      await s.keepHeld();
      expect(s.heldHere, isEmpty);
      expect(localPaths().length, 6, reason: 'brought back');
      for (var i = 0; i < 4; i++) {
        local('f$i.txt').deleteSync();
      }
      await s.pass();
      expect(s.heldHere.length, 4);
      await s.removeHeld();
      expect(s.heldHere, isEmpty);
      expect(drive.paths, ['f4.txt', 'f5.txt']);
      expect(s.line, 'In step.');
    });
  });

  test('hidden files and folders and links are left out, and a link is never followed or written through', () async {
    final outside = Directory('${tmp.path}/Outside')..createSync();
    File('${outside.path}/secret.txt').writeAsStringSync('secret');
    write('.env', 'hidden');
    write('.git/config', 'hidden');
    write('Thumbs.db', 'x');
    write('desktop.ini', 'x');
    write('.DS_Store', 'x');
    write('ok.txt', 'ok');
    Link('$root/way-out').createSync(outside.path);
    Link('$root/linked.txt').createSync('${outside.path}/secret.txt');
    // The drive has a path that would go through the link, and names that climb out.
    drive.put('way-out/planted.txt', 'planted');
    drive.put('../climbed.txt', 'no');
    drive.put('.hidden/x.txt', 'no');
    final r = await pass();
    expect(drive.paths.where((p) => !p.startsWith('.') && !p.startsWith('way-out')), ['ok.txt']);
    expect(File('${outside.path}/planted.txt').existsSync(), isFalse);
    expect(File('${tmp.path}/climbed.txt').existsSync(), isFalse);
    expect(outside.listSync().length, 1);
    expect(Directory('$root/.hidden').existsSync(), isFalse);
    expect(r.skipped.keys, contains('a link'));
    expect(r.line, startsWith('In step, but for'));
  });

  test('a file still being written is left this pass and taken the next', () async {
    ahead = Duration.zero;
    write('draft.txt', 'half');
    final r = await pass();
    expect(drive.paths, isEmpty);
    expect(r.skipped['still being written'], 1);
    ahead = const Duration(hours: 1);
    expect((await pass()).up, 1);
    expect(drive.newest('draft.txt'), 'half');
  });

  test('too big, no room, and names another system can\'t hold are left out with the reason, and the rest go', () async {
    drive.maxFile = 10;
    write('big.bin', 'x' * 50);
    write('small.txt', 'ok');
    write('what?.txt', 'windows can\'t hold this');
    final r = await pass();
    expect(drive.paths, ['small.txt']);
    expect(r.skipped.keys.any((k) => k.startsWith('too big')), isTrue);
    expect(r.skipped['with a name My files can\'t hold'], 1);
    drive.maxFile = 0;
    drive.free = 5;
    final r2 = await pass();
    expect(r2.skipped['with no room left in My files'], 1);
    expect(r2.line, contains('left out'));
    expect(local('big.bin').existsSync(), isTrue);
  });

  test('one pass moves no more than its cap, says so, and the next goes on', () async {
    for (var i = 0; i < 5; i++) {
      write('f$i.txt', '$i');
    }
    final r = await pass(most: 3);
    expect(r.up, 3);
    expect(r.capped, isTrue);
    expect(r.line, contains('More next time'));
    final r2 = await pass(most: 3);
    expect(r2.up, 2);
    expect(r2.capped, isFalse);
  });

  test('the state survives a restart: a new engine on the same state file knows what was in step', () async {
    write('a.txt', 'a1');
    await pass();
    expect(File('${tmp.path}/app/state.json').existsSync(), isTrue);
    expect(Directory(root).listSync().length, 1, reason: 'the state is not kept in the synced folder');
    // "Restarted": only the drive changed since. With the state it is a plain change that comes down; without it,
    // it would be two files that differ.
    drive.put('a.txt', 'a2 from another device');
    final r = await pass();
    expect(r.both, 0);
    expect(local('a.txt').readAsStringSync(), 'a2 from another device');
    expect(localPaths(), ['a.txt']);
  });

  test('the home folder, anything above it, a disk\'s top, and the app\'s own folders are refused', () {
    final home = '${tmp.path}/home/me';
    final app = '$home/Library/Application Support/Ghost Messaging';
    Directory('$app/folder-sync').createSync(recursive: true);
    Directory('$home/Documents').createSync();
    String? why(String p) => FolderSyncEngine.whyNot(FolderSyncEngine.resolve(p) ?? p, home: home, own: [app]);
    expect(why(home), contains('home folder'));
    expect(why('${tmp.path}/home'), contains('home folder'));
    expect(why('/'), contains('whole disk'));
    expect(FolderSyncEngine.whyNot(r'C:\', home: r'C:\Users\me'), contains('whole disk'));
    expect(FolderSyncEngine.whyNot('C:', home: r'C:\Users\me'), contains('whole disk'));
    expect(FolderSyncEngine.whyNot('/Volumes/Backup', home: '/Users/me'), contains('whole disk'));
    expect(why(app), contains('its own files'));
    expect(why('$app/folder-sync'), contains('its own files'));
    expect(why('$home/Library'), contains('its own files'), reason: 'it holds the app\'s folder');
    expect(why('$home/Documents'), isNull);
  });

  group('this computer\'s choice', () {
    FolderSync sync({SyncDrive? Function()? d}) => FolderSync(
          data: () => Directory('${tmp.path}/app/folder-sync'),
          drive: () async => d == null ? drive : d(),
          home: () => '${tmp.path}/home',
          own: () => ['${tmp.path}/app'],
          quiet: Duration.zero,
        );

    test('choosing runs a pass and is remembered on this device; stopping forgets it and removes nothing', () async {
      Directory('${tmp.path}/home').createSync();
      write('a.txt', 'a');
      final s = sync();
      expect(s.choose('${tmp.path}/home'), contains('home folder'));
      expect(s.choose('${tmp.path}/app'), isNotNull);
      expect(s.root, isNull);
      expect(s.choose(root), isNull);
      while (s.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(s.line, 'In step.');
      expect(drive.paths, ['a.txt']);
      // A new run of the app reads the same choice.
      final next = sync()..load();
      expect(next.root, root);
      next.stop();
      expect((sync()..load()).root, isNull);
      expect(local('a.txt').existsSync(), isTrue);
      expect(drive.paths, ['a.txt']);
    });

    test('signed out, out of reach, or the folder gone: it stops quietly and says why', () async {
      final s = sync(d: () => null);
      expect(s.choose(root), isNull);
      await s.pass();
      while (s.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(s.line, 'Stopped: sign in to your Uplink account on this computer.');
      final t = sync();
      drive.reachable = false;
      expect(t.choose(root), isNull);
      while (t.running) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(t.line, 'Stopped: My files can\'t be reached right now.');
      Directory(root).deleteSync(recursive: true);
      await t.pass();
      expect(t.line, 'Stopped: the folder isn\'t there any more.');
    });

    // GMFB-38, "Pick a local folder on desktop to keep in two-way sync with a Files space or the personal drive".
    test('a Files space has a folder of its own, kept apart from My files\' and never in, around or the same as it', () async {
      final team = FakeDrive(Directory('${tmp.path}/team'));
      FolderSync space({SyncDrive? Function()? d}) => FolderSync(
            data: () => Directory('${tmp.path}/app/folder-sync'),
            drive: () async => d == null ? team : d(),
            home: () => '${tmp.path}/home',
            own: () => ['${tmp.path}/app'],
            quiet: Duration.zero,
            space: 'abc123',
            driveName: 'Team files',
          );
      Future<void> wait(FolderSync s) async {
        while (s.running) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      write('mine.txt', 'private');
      Directory('$root/Inside').createSync();
      final mine = sync();
      expect(mine.choose(root), isNull);
      await wait(mine);

      // What is in My files must not go up into a space: its folder, one in it and one around it are all refused.
      final s = space();
      expect(s.choose(root), contains('already synced'));
      expect(s.choose('$root/Inside'), contains('already synced'));
      final shared = Directory('${tmp.path}/Shared/Team')..createSync(recursive: true);
      File('${shared.path}/plan.txt').writeAsStringSync('plan');
      expect(s.choose(shared.path), isNull);
      await wait(s);
      expect(s.line, 'In step.');
      expect(team.paths, ['plan.txt']);
      expect(drive.paths, ['mine.txt'], reason: 'My files has only its own folder\'s files');
      expect(File('${tmp.path}/app/folder-sync/space-abc123.json').existsSync(), isTrue);
      // And My files can't then take the space's folder, or the one around it.
      expect(sync().choose('${tmp.path}/Shared'), contains('already synced'));

      // Each is remembered apart; stopping the space's leaves My files' as it was, and removes nothing.
      expect((sync()..load()).root, root);
      expect((space()..load()).root, shared.path);

      // Both changed: the space's copy is kept beside the local one under the space's name.
      team.put('plan.txt', 'theirs');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File('${shared.path}/plan.txt').writeAsStringSync('mine, changed');
      await s.pass();
      expect(File('${shared.path}/plan (from Team files).txt').readAsStringSync(), 'theirs');
      expect(File('${shared.path}/plan.txt').readAsStringSync(), 'mine, changed');

      // The space gone from this computer, or a role that can't add files: it stops and says why.
      final gone = space(d: () => null)..load();
      await gone.pass();
      expect(gone.line, 'Stopped: this space isn\'t on this computer any more.');
      final role = space(d: () => throw const SyncStop('your role in this space can\'t add files.'))..load();
      await role.pass();
      expect(role.line, 'Stopped: your role in this space can\'t add files.');
      team.reachable = false;
      await s.pass();
      expect(s.line, 'Stopped: Team files can\'t be reached right now.');

      s.stop();
      expect((space()..load()).root, isNull);
      expect((sync()..load()).root, root);
      expect(File('${shared.path}/plan.txt').existsSync(), isTrue);
      expect(team.paths, contains('plan.txt'));
    });
  });
}
