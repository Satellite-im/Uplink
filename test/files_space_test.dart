// A Files space end to end (Matt, 2026-11-17: "add full functionality for filesharing in a space when the space is
// designated a Files Space"): the app's files store against the relay's own files service, on this machine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart' show OutgoingFile;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

/// The hub's rooms between the test's devices: what one sends to a room the others in it get.
class FakeHub {
  final List<FakeRoute> routes = [];
}

class FakeRoute implements VoiceRoute {
  FakeRoute(this.hub, this.me) {
    hub.routes.add(this);
  }
  final FakeHub hub;
  @override
  final String me;
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    for (final r in hub.routes) {
      if (r != this) r._packets.add((room: room, from: me, bytes: bytes));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

Future<void> until(bool Function() test, {String? reason, Duration most = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(most);
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('waited too long${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Uint8List bytesOf(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('what the relay said of a space is kept whole: its owner, the roster\'s revision and cas come back from disk', () {
    final said = FilesInfo.from({'seq': 7, 'used': 10, 'quota': 100, 'maxFile': 50, 'files': 2, 'owner': 'ab12', 'rv': 3, 'cas': 1});
    final back = FilesInfo.from((jsonDecode(jsonEncode(said.toJson())) as Map).cast<String, dynamic>());
    expect([back.seq, back.used, back.quota, back.maxFile, back.files, back.owner, back.rv, back.cas], [7, 10, 100, 50, 2, 'ab12', 3, true]);
    // A relay from before them says none, and none are written.
    expect(const FilesInfo(seq: 1).toJson().keys, isNot(anyOf(contains('owner'), contains('rv'), contains('cas'))));
  });


  test('a file as big as the relay takes (a 26 GB film) is believed and listed, as one of 4 GB and more was not', () {
    final big = SpaceFile.fromJson({'id': 'f' * 32, 'n': 'The Odyssey.mkv', 'z': 26054267438 - 16 * 99389, 'k': base64Encode(List.filled(32, 7)), 'p': base64Encode(List.filled(8, 1)), 'd': 'Movies', 'at': 1}, by: 'x');
    expect(big, isNotNull);
    expect(big!.folder, 'Movies');
    expect(SpaceFile.maxSize, greaterThan(50000000000));
  });
  group('sealing a file', () {
    final key = NetCrypto.randomBytes(32), prefix = NetCrypto.randomBytes(8);
    const id = '00112233445566778899aabbccddeeff';

    test('sizes: a chunk is 16 bytes more sealed, an empty file is one empty chunk', () {
      expect(FileSeal.chunks(0), 1);
      expect(FileSeal.sealedSize(0), 16);
      expect(FileSeal.chunks(FileSeal.chunk), 1);
      expect(FileSeal.chunks(FileSeal.chunk + 1), 2);
      expect(FileSeal.sealedSize(FileSeal.chunk + 1), FileSeal.chunk + 1 + 32);
      expect(FileSeal.plainLength(1, FileSeal.chunk + 1), 1);
    });

    test('opens what it sealed, and nothing changed, moved or cut short', () {
      const size = 3 * 1000 + 7;
      final plain = bytesOf(size, 1);
      final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, plain: plain, chunkSize: 1000));
      expect(sealed.length, FileSeal.sealedSize(size, chunkSize: 1000));
      expect(FileSeal.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, sealed: sealed, chunkSize: 1000)), plain);
      // From the middle: chunks 2 and 3 alone.
      final from = FileSeal.sealedOffset(2, chunkSize: 1000);
      expect(FileSeal.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: size, first: 2, sealed: Uint8List.sublistView(sealed, from), chunkSize: 1000)), plain.sublist(2000));
      // A byte changed.
      final changed = Uint8List.fromList(sealed)..[5] ^= 1;
      expect(FileSeal.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, sealed: changed, chunkSize: 1000)), isNull);
      // Chunk 1 where chunk 0 should be.
      final chunk1 = Uint8List.sublistView(sealed, 1016, 2032);
      expect(FileSeal.openChunk(key, prefix, id, 0, false, chunk1), isNull);
      // Cut short after a whole chunk: that chunk was not sealed as the last, so it can't pass for the whole file.
      expect(FileSeal.openChunk(key, prefix, id, 0, true, Uint8List.sublistView(sealed, 0, 1016)), isNull);
      // Another file's id.
      expect(FileSeal.openChunk(key, prefix, 'ffffffffffffffffffffffffffffffff', 0, false, Uint8List.sublistView(sealed, 0, 1016)), isNull);
    });

    test('a description opens with the space\'s files key and no other', () {
      final seed = NetCrypto.hex(NetCrypto.randomBytes(32));
      final op = FileOp.seal(FileSeal.filesKey(seed), FileOp.rename('a' * 32, 'notes.txt'));
      expect(FileOp.open(FileSeal.filesKey(seed), op), {'t': 'ren', 'id': 'a' * 32, 'n': 'notes.txt'});
      expect(FileOp.open(FileSeal.filesKey(NetCrypto.hex(NetCrypto.randomBytes(32))), op), isNull);
      expect(FileSeal.filesRoom(seed), hasLength(32));
      expect(FileSeal.filesToken(seed), hasLength(64));
    });

    test('the files address comes from the hub\'s', () {
      expect(FilesApi.baseFor('wss://gogho.st/hub').toString(), 'https://gogho.st/files');
      expect(FilesApi.baseFor('ws://127.0.0.1:8787/x/hub').toString(), 'http://127.0.0.1:8787/x/files');
    });
  });

  group('the list a log makes', () {
    SpaceFile file(String id, String by) => SpaceFile(id: id, name: '$id.txt', size: 3, mime: 'text/plain', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: by, byName: by, at: 1);
    LoggedOp e(int seq, String by, Map<String, Object?> op) => LoggedOp(seq: seq, by: by, at: seq, op: op);

    test('each may rename, move and remove their own; the owner anyone\'s; nobody else', () {
      final a = file('a' * 32, 'maya'), b = file('b' * 32, 'sam');
      final list = FilesList.read([
        e(1, 'maya', FileOp.add(a)),
        e(2, 'sam', FileOp.add(b)),
        e(3, 'sam', FileOp.rename(a.id, 'mine now.txt')), // not Sam's: skipped
        e(4, 'maya', FileOp.rename(a.id, 'plan.txt')),
        e(5, 'sam', FileOp.delete(a.id)), // skipped
        e(6, 'owner', FileOp.move(b.id, 'Old')),
        e(7, 'sam', FileOp.folder('Photos')),
        e(8, 'maya', FileOp.add(a)), // the same id again: skipped
        e(9, 'sam', const {'t': 'from-a-newer-build'}),
      ], const OwnerRules('owner'));
      expect(list.files.keys, [a.id, b.id]);
      expect(list.files[a.id]!.name, 'plan.txt');
      expect(list.files[b.id]!.folder, 'Old');
      expect(list.folders, {'Old', 'Photos'});
      final after = FilesList.read([e(1, 'maya', FileOp.add(a)), e(2, 'owner', FileOp.delete(a.id)), e(3, 'maya', FileOp.folder('X')), e(4, 'maya', FileOp.unfolder('X'))], const OwnerRules('owner'));
      expect(after.files, isEmpty);
      expect(after.folders, isEmpty);
    });

    // Matt, 2026-11-18: "allow root level folders in the file sharing tab and nested folders".
    test('a folder path is cleaned name by name, no deeper than eight, and a one-level folder is still one', () {
      expect(SpaceFile.cleanFolder('Photos'), 'Photos');
      expect(SpaceFile.cleanFolder('Trip/Day 2'), 'Trip/Day 2');
      expect(SpaceFile.cleanFolder('/Trip//../Day 2/./'), 'Trip/Day 2');
      expect(SpaceFile.cleanFolder('Trip/CON/a:b'), 'Trip/_CON/a_b');
      expect(SpaceFile.cleanFolder('..'), isNull);
      expect(SpaceFile.cleanFolder(''), isNull);
      expect(SpaceFile.cleanFolder(' / '), isNull);
      expect(SpaceFile.cleanFolder(7), isNull);
      expect(SpaceFile.cleanFolder(List.filled(12, 'a').join('/')), List.filled(8, 'a').join('/'));
      expect(SpaceFile.cleanFolder('x' * 200), 'x' * 80);
      expect(SpaceFile.folderLine('a/b/c'), ['a', 'a/b', 'a/b/c']);
      expect(SpaceFile.folderParent('a/b'), 'a');
      expect(SpaceFile.folderParent('a'), isNull);
      expect(SpaceFile.inFolder('ab', 'a'), isFalse);
      expect(SpaceFile.inFolder('a/b', 'a'), isTrue);
      // A file written by 0.9.6 (its `d` one name) reads as it did, in a folder of one name.
      final old = SpaceFile.fromJson({...file('c' * 32, 'maya').toJson(), 'd': 'Work'}, by: 'maya')!;
      expect(old.folder, 'Work');
      final nested = SpaceFile.fromJson({...file('c' * 32, 'maya').toJson(), 'd': 'Work/2027'}, by: 'maya')!;
      expect(nested.folder, 'Work/2027');
      expect(nested.toJson()['d'], 'Work/2027', reason: 'still the field 0.9.6 reads as the folder');
    });

    test('folders nest, stay when empty, move whole, and go only when nothing is in them', () {
      final a = file('a' * 32, 'maya'), b = file('b' * 32, 'sam');
      final list = FilesList.read([
        e(1, 'maya', FileOp.folder('Empty')),
        e(2, 'maya', FileOp.folder('Trip/Day 1/Morning')),
        e(3, 'maya', FileOp.add(a.copyWith(folder: 'Trip/Day 1'))),
        e(4, 'sam', FileOp.add(b)),
        e(5, 'sam', FileOp.move(b.id, 'Trip/Day 2')),
      ], const OwnerRules('owner'));
      expect(list.folders, {'Empty', 'Trip', 'Trip/Day 1', 'Trip/Day 1/Morning', 'Trip/Day 2'});
      expect(list.subfolders(null), ['Empty', 'Trip']);
      expect(list.subfolders('Trip'), ['Trip/Day 1', 'Trip/Day 2']);
      expect(list.filesIn('Trip/Day 1').single.id, a.id);
      expect(list.filesUnder('Trip').length, 2);
      expect(list.filesIn(null), isEmpty);

      List<LoggedOp> log(List<(String, Map<String, Object?>)> more) => [
            e(1, 'maya', FileOp.folder('Trip/Day 1/Morning')),
            e(2, 'maya', FileOp.add(a.copyWith(folder: 'Trip/Day 1'))),
            e(3, 'sam', FileOp.add(b.copyWith(folder: 'Trip'))),
            e(4, 'maya', FileOp.folder('Other')),
            for (final (i, (by, op)) in more.indexed) e(5 + i, by, op),
          ];

      // Renamed with all it holds, by the owner (who may move Sam's file in it too).
      var l = FilesList.read(log([('owner', FileOp.moveFolder('Trip', 'Holiday'))]), const OwnerRules('owner'));
      expect(l.folders, {'Holiday', 'Holiday/Day 1', 'Holiday/Day 1/Morning', 'Other'});
      expect(l.files[a.id]!.folder, 'Holiday/Day 1');
      expect(l.files[b.id]!.folder, 'Holiday');
      // Moved into another folder.
      l = FilesList.read(log([('owner', FileOp.moveFolder('Trip/Day 1', 'Other/Day 1'))]), const OwnerRules('owner'));
      expect(l.files[a.id]!.folder, 'Other/Day 1');
      expect(l.folders, containsAll(['Other/Day 1/Morning', 'Trip']));
      expect(l.folders, isNot(contains('Trip/Day 1')));
      // Emptied into the folder it is in (no `to`): what it held goes up a level.
      l = FilesList.read(log([('owner', FileOp.moveFolder('Trip/Day 1', null))]), const OwnerRules('owner'));
      expect(l.files[a.id]!.folder, 'Trip');
      expect(l.folders, {'Trip', 'Trip/Morning', 'Other'});
      l = FilesList.read(log([('owner', FileOp.moveFolder('Trip', null))]), const OwnerRules('owner'));
      expect(l.files[b.id]!.folder, isNull);
      expect(l.files[a.id]!.folder, 'Day 1');
      // Not let through: Maya moving a folder with Sam's file in it, a folder into itself, one past eight deep, one that
      // isn't there, and a `to` that cleans to nothing. All or nothing: nothing moved.
      for (final (by, op) in [
        ('maya', FileOp.moveFolder('Trip', 'Holiday')),
        ('owner', FileOp.moveFolder('Trip', 'Trip/Day 1/Trip')),
        ('owner', FileOp.moveFolder('Trip/Day 1', List.filled(8, 'x').join('/'))),
        ('owner', FileOp.moveFolder('Nowhere', 'Somewhere')),
        ('owner', {'t': 'mvdir', 'd': 'Trip', 'to': '..'}),
      ]) {
        l = FilesList.read(log([(by, op)]), const OwnerRules('owner'));
        expect(l.files[a.id]!.folder, 'Trip/Day 1', reason: '$op');
        expect(l.folders, {'Trip', 'Trip/Day 1', 'Trip/Day 1/Morning', 'Other'}, reason: '$op');
      }
      // A folder with a file anywhere in it stays; an empty one goes with the empty folders in it.
      l = FilesList.read(log([('owner', FileOp.unfolder('Trip'))]), const OwnerRules('owner'));
      expect(l.folders, contains('Trip/Day 1/Morning'));
      l = FilesList.read(log([('owner', FileOp.delete(a.id)), ('owner', FileOp.delete(b.id)), ('owner', FileOp.unfolder('Trip'))]), const OwnerRules('owner'));
      expect(l.folders, {'Other'});
      // A build that doesn't know `mvdir` skips it, as every older build skips a kind it doesn't know.
      expect(FileOp.moveFolder('a', null), {'t': 'mvdir', 'd': 'a', 'to': null});
    });

    test('sorts by newest, name, size and type', () {
      final f = [
        SpaceFile(id: '1' * 32, name: 'b.png', size: 10, mime: '', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'x', byName: '', at: 3),
        SpaceFile(id: '2' * 32, name: 'A.pdf', size: 30, mime: '', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'x', byName: '', at: 1),
        SpaceFile(id: '3' * 32, name: 'c.zip', size: 20, mime: '', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'x', byName: '', at: 2),
      ];
      expect(FilesSort.newest.apply(f).map((x) => x.name), ['b.png', 'c.zip', 'A.pdf']);
      expect(FilesSort.name.apply(f).map((x) => x.name), ['A.pdf', 'b.png', 'c.zip']);
      expect(FilesSort.size.apply(f).map((x) => x.name), ['A.pdf', 'c.zip', 'b.png']);
      expect(FilesSort.type.apply(f).map((x) => x.kind), [FileKind.image, FileKind.pdf, FileKind.archive]);
      expect(FileKind.of('song.FLAC'), FileKind.audio);
      expect(FileKind.of('blob', 'application/pdf'), FileKind.pdf);
      expect(fileSize(2100000), '2.1 MB');
    });
  });

  group('two devices and the relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    final maya = KeysSigner(NetKeys.generate()), sam = KeysSigner(NetKeys.generate());
    late VoiceChannel space;
    late FakeHub hub;
    final stores = <FilesStore>[];

    Future<void> boot({FilesConfig config = const FilesConfig()}) async {
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay'), config: config));
      base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
    }

    FilesStore device(KeysSigner who, String name, {List<String>? said}) {
      final s = FilesStore.forTest(base: base, signer: who, data: Directory('${dir.path}/$name'), route: FakeRoute(hub, who.id), name: name, piece: 2, announce: said == null ? null : (c, w) => said.add(w));
      stores.add(s);
      return s;
    }

    File fileOf(String name, Uint8List bytes) => File('${dir.path}/in/$name')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ghost-files-app');
      hub = FakeHub();
      space = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Drop box', kind: SpaceKind.files, owner: NetCrypto.hex(maya.publicKey));
      await boot();
    });

    tearDown(() async {
      for (final s in stores) {
        await s.clear();
      }
      stores.clear();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    test('a file added on one device is listed on the other at once, comes down whole, and opens', () async {
      final said = <String>[];
      final a = device(maya, 'Maya', said: said), b = device(sam, 'Sam');
      await a.start();
      await b.open(space);
      expect(b.of(space).ready, isTrue);
      expect(b.of(space).files, isEmpty);
      final data = bytesOf(1300 * 1000, 7); // five chunks, three requests of two
      a.upload(space, [fileOf('report.pdf', data).path]);
      expect(a.transfers.single.up, isTrue);
      await until(() => a.transfers.isEmpty || a.transfers.first.state == TransferState.done, reason: '${a.transfers.firstOrNull?.error}');
      expect(a.of(space).files.values.single.name, 'report.pdf');
      // Sam had the space open: told in the chat room, not by waiting for the next look.
      await until(() => b.of(space).files.isNotEmpty);
      final f = b.of(space).files.values.single;
      expect(f.byName, 'Maya');
      expect(f.by, maya.id);
      expect(f.size, data.length);
      expect(f.kind, FileKind.pdf);
      expect(said, ['Maya added report.pdf (1.3 MB)']);
      // The space's room holds its list as well as its files (the relay counts the log's bytes too).
      expect(b.of(space).info!.used, inInclusiveRange(FileSeal.sealedSize(data.length), FileSeal.sealedSize(data.length) + 8192));
      // Maya has it already; Sam brings it down.
      expect(a.cached(f), isNotNull);
      expect(b.cached(f), isNull);
      final path = await b.fetch(space, f);
      expect(await File(path).readAsBytes(), data);
      expect(path, endsWith('/report.pdf'));
      expect(b.transfers, isEmpty);
      // Kept: the list and the file are there for a store made again (the app opened again) before the relay answers.
      // The list is written a moment after it changes, by another isolate (lib/inbox/kept_writer.dart): here, now.
      b.of(space).flushKept();
      final again = FilesStore.forTest(base: Uri.parse('http://127.0.0.1:1/files'), signer: sam, data: Directory('${dir.path}/Sam'));
      stores.add(again);
      expect(again.of(space).files.values.single.name, 'report.pdf');
      expect(again.cached(f), path);
    });

    // Matt, 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other
    // chats". A chat space's files go up sealed under its own seed, as a Files space's do, and in no list.
    test('a file for a chat space\'s message goes up sealed under its own seed, in no list, and comes down whole on the other device', () async {
      final said = <String>[];
      final chat = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Lounge', kind: SpaceKind.text, owner: NetCrypto.hex(maya.publicKey));
      final a = device(sam, 'Sam', said: said), b = device(maya, 'Maya');
      await a.start();
      final data = bytesOf(600 * 1000, 3);
      final f = OutgoingFile(path: fileOf('beach.gif', data).path, name: 'beach.gif', size: data.length, mime: 'image/gif');
      var moved = 0;
      final up = await a.uploadForChat(chat, f, byName: 'Sam', thumbMost: 4096, moved: () => moved++);
      expect(up.name, 'beach.gif');
      expect(up.by, sam.id);
      expect(up.byName, 'Sam');
      expect(up.size, data.length);
      expect(moved, greaterThan(0));
      expect(f.progress, 1);
      expect(said, isEmpty, reason: 'nothing said in the chat: the message is the word');
      expect(a.of(chat).files, isEmpty, reason: 'no `add` in the space\'s log');
      expect(a.cached(up), isNotNull, reason: 'the sender has it already');
      await until(() => a.transfers.isEmpty);
      expect(File('${dir.path}/Sam/queue.json').existsSync() ? File('${dir.path}/Sam/queue.json').readAsStringSync() : '[]', '[]');

      // Maya, from the message alone: brought down and opened with the file's own key.
      final path = await b.fetch(chat, up);
      expect(await File(path).readAsBytes(), data);
      await b.open(chat);
      expect(b.of(chat).files, isEmpty);
      expect(b.of(chat).info!.used, greaterThanOrEqualTo(FileSeal.sealedSize(data.length)));

      // One that fails says why, and asked again goes on.
      final gone = OutgoingFile(path: '${dir.path}/in/none.txt', name: 'none.txt', size: 4, mime: 'text/plain');
      await expectLater(a.uploadForChat(chat, gone, byName: 'Sam', thumbMost: 4096, moved: () {}), throwsA(isA<FilesError>()));
      expect(gone.retryable, isTrue);
      fileOf('none.txt', Uint8List.fromList([1, 2, 3, 4]));
      final later = await a.uploadForChat(chat, gone, byName: 'Sam', thumbMost: 4096, moved: () {});
      expect(await File(await b.fetch(chat, later)).readAsBytes(), [1, 2, 3, 4]);
    });

    test('a download cut short goes on from its last whole chunk', () async {
      final a = device(maya, 'Maya'), b = device(sam, 'Sam');
      final data = bytesOf(900 * 1000, 8);
      a.upload(space, [fileOf('clip.mov', data).path]);
      await until(() => a.of(space).files.isNotEmpty);
      await b.open(space);
      final f = b.of(space).files.values.single;
      // Two chunks' worth already here, and part of a third: the part is cut back and the rest asked for by Range.
      final part = File('${dir.path}/Sam/cache/${f.id}.part')..parent.createSync(recursive: true);
      part.writeAsBytesSync(data.sublist(0, 2 * FileSeal.chunk + 100));
      final path = await b.fetch(space, f);
      expect(await File(path).readAsBytes(), data);
      // A part that is wrong (not what was sealed) fails the check and is let go, not kept as the file.
      b.cached(f);
      File(path).deleteSync();
      part.writeAsBytesSync(Uint8List(FileSeal.chunk));
      await expectLater(b.fetch(space, f), throwsA(isA<FilesError>()));
      expect(part.existsSync(), isFalse);
      expect(File(path).existsSync(), isFalse);
    });

    test('an upload stopped by the app closing picks up where the relay says it got to', () async {
      final data = bytesOf(3 * 1000 * 1000, 9);
      final first = FilesStore.forTest(base: base, signer: maya, data: Directory('${dir.path}/Maya'), piece: 1);
      stores.add(first);
      first.upload(space, [fileOf('big.zip', data).path]);
      await until(() => first.transfers.isNotEmpty && first.transfers.first.blob != null && first.transfers.first.done > FileSeal.chunk);
      final blob = first.transfers.first.blob!;
      await first.clear(); // the app closed: the queue on disk is what is left
      await until(() => File('${dir.path}/Maya/queue.json').readAsStringSync().contains(blob));
      final second = FilesStore.forTest(base: base, signer: maya, data: Directory('${dir.path}/Maya'), piece: 4);
      stores.add(second);
      await second.start();
      expect(second.transfers.single.blob, blob);
      await until(() => second.of(space).files.isNotEmpty, reason: '${second.transfers.firstOrNull?.error}');
      expect(second.of(space).files.values.single.id, blob, reason: 'the same blob, not one started again');
      final b = device(sam, 'Sam');
      await b.open(space);
      expect(await File(await b.fetch(space, b.of(space).files.values.single)).readAsBytes(), data);
      expect(File('${dir.path}/Maya/queue.json').readAsStringSync(), '[]');
    });

    // Matt, 2026-11-21: "I need a way to see partially uploaded files, the oddysey uploaded partially but then
    // disconnected when I restarted the app it stopped uploading but kept the space reserved".
    test('an upload left part way that no device can pick up is listed with how far it got, and removing it frees its room', () async {
      final data = bytesOf(3 * 1000 * 1000, 4);
      final sams = FilesStore.forTest(base: base, signer: sam, data: Directory('${dir.path}/Sam'), piece: 1);
      stores.add(sams);
      sams.upload(space, [fileOf('odyssey.mkv', data).path]);
      await until(() => sams.transfers.isNotEmpty && sams.transfers.first.blob != null && sams.transfers.first.done > FileSeal.chunk);
      final blob = sams.transfers.first.blob!;
      await sams.clear();
      // Its queue lost (a file sent from a chat is never on it; an app reinstalled loses it): nothing will pick it up.
      File('${dir.path}/Sam/queue.json').deleteSync();
      final a = device(maya, 'Maya'), b = device(sam, 'Sam');
      await a.open(space);
      await b.open(space);
      final held = a.of(space).info!.used;
      expect(held, greaterThanOrEqualTo(FileSeal.sealedSize(data.length)), reason: 'its room is held');
      final part = a.unfinished(space).single;
      expect(part.id, blob);
      expect(part.by, sam.id);
      expect(part.size, FileSeal.sealedSize(data.length));
      expect(part.have, greaterThan(FileSeal.chunk));
      expect(part.have, lessThan(part.size));
      expect(b.unfinishedBy(space, b.unfinished(space).single), 'you');
      expect(a.unfinishedBy(space, part), isNull, reason: 'Sam has listed nothing yet, so the list has no name for them');
      // Whoever started it and the space's owner may let it go; the owner does.
      expect(b.canRemoveUnfinished(space, part), isTrue);
      expect(a.canRemoveUnfinished(space, part), isTrue);
      expect(await a.removeUnfinished(space, part), isTrue);
      expect(a.unfinished(space), isEmpty);
      expect(a.of(space).info!.used, lessThan(held - FileSeal.sealedSize(data.length) + 1), reason: 'its room is free');
      await b.of(space).refresh();
      expect(b.unfinished(space), isEmpty);
    });

    test('an upload this device is still sending is its transfer, not an unfinished one', () async {
      final data = bytesOf(3 * 1000 * 1000, 5);
      final a = FilesStore.forTest(base: base, signer: maya, data: Directory('${dir.path}/Maya'), piece: 1);
      stores.add(a);
      a.upload(space, [fileOf('slow.bin', data).path]);
      await until(() => a.transfers.isNotEmpty && a.transfers.first.blob != null && a.transfers.first.done > FileSeal.chunk);
      await a.of(space).refresh();
      expect(a.of(space).info!.parts, hasLength(1), reason: 'the relay lists it');
      expect(a.unfinished(space), isEmpty, reason: 'this device is sending it');
      // Let it finish before the relay stops, or the send in flight is cut off under the test.
      await until(() => a.of(space).files.isNotEmpty, reason: '${a.transfers.firstOrNull?.error}');
      await a.of(space).refresh();
      expect(a.of(space).info!.parts, isEmpty, reason: 'finished: no longer listed');
    });

    test('rename, folders, move and delete reach the other device; only the uploader or owner may', () async {
      final a = device(maya, 'Maya'), b = device(sam, 'Sam');
      await b.open(space);
      a.upload(space, [fileOf('a.txt', bytesOf(10, 1)).path]);
      await until(() => b.of(space).files.length == 1);
      b.upload(space, [fileOf('b.txt', bytesOf(10, 2)).path], folder: 'Sam\'s');
      await until(() => b.of(space).files.length == 2);
      await a.open(space);
      final mine = a.of(space).files.values.firstWhere((f) => f.name == 'a.txt');
      final theirs = a.of(space).files.values.firstWhere((f) => f.name == 'b.txt');
      expect(theirs.folder, 'Sam\'s');
      // Sam can't touch Maya's; Maya owns the space and can touch Sam's.
      expect(b.canChange(space, mine), isFalse);
      expect(await b.rename(space, mine, 'mine.txt'), isFalse);
      expect(a.canChange(space, theirs), isTrue);
      expect(await a.rename(space, mine, 'plan.txt'), isTrue);
      expect(await a.newFolder(space, 'Plans'), isTrue);
      expect(await a.move(space, a.of(space).files[mine.id]!, 'Plans'), isTrue);
      await until(() => b.of(space).files[mine.id]?.name == 'plan.txt' && b.of(space).files[mine.id]?.folder == 'Plans');
      expect(b.of(space).folders, containsAll(['Plans', 'Sam\'s']));
      expect(await a.delete(space, theirs), isTrue);
      await until(() => b.of(space).files.length == 1);
      // The owner's delete let the blob go on the relay too.
      expect(Directory('${dir.path}/relay/${FileSeal.filesRoom(space.seed)}/blobs').listSync().length, 1);
      expect(b.of(space).info!.used, inInclusiveRange(FileSeal.sealedSize(10), FileSeal.sealedSize(10) + 8192), reason: 'the file left and the list');
    });

    // Matt, 2026-11-18: "allow root level folders in the file sharing tab and nested folders".
    test('nested folders are made empty, renamed, moved and deleted, and the other device sees each', () async {
      final a = device(maya, 'Maya'), b = device(sam, 'Sam');
      await b.open(space);
      await a.open(space);
      expect(await a.newFolder(space, 'Trip'), isTrue);
      expect(await a.newFolder(space, 'Day 1', parent: 'Trip'), isTrue);
      expect(await a.newFolder(space, 'Day 1', parent: 'Trip'), isFalse, reason: 'there already');
      expect(await a.newFolder(space, 'x', parent: List.filled(8, 'd').join('/')), isFalse, reason: 'nine deep');
      await until(() => b.of(space).folders.contains('Trip/Day 1'), reason: 'an empty nested folder reaches Sam');
      a.upload(space, [fileOf('pier.jpg', bytesOf(10, 3)).path], folder: 'Trip/Day 1');
      await until(() => b.of(space).files.length == 1);
      expect(b.of(space).files.values.single.folder, 'Trip/Day 1');
      b.upload(space, [fileOf('sams.txt', bytesOf(10, 4)).path], folder: 'Trip');
      await until(() => a.of(space).files.length == 2);
      // Sam can't move a folder with Maya's file in it; Maya (the owner) can rename hers, Sam's file and all.
      expect(b.whyNotMoveFolder(space, 'Trip', 'Holiday'), isNotNull);
      expect(await b.moveFolder(space, 'Trip', 'Holiday'), isFalse);
      expect(a.whyNotMoveFolder(space, 'Trip', 'Trip/Day 1/Trip'), 'A folder can\'t go inside itself.');
      expect(await a.renameFolder(space, 'Trip', 'Holiday'), isTrue);
      await until(() => b.of(space).folders.containsAll(['Holiday', 'Holiday/Day 1']) && !b.of(space).folders.contains('Trip'));
      expect({for (final f in b.of(space).files.values) f.name: f.folder}, {'pier.jpg': 'Holiday/Day 1', 'sams.txt': 'Holiday'});
      // Moved to the top, then let go keeping what it held (it goes up a level), then deleted with its file.
      expect(await a.moveFolder(space, 'Holiday/Day 1', 'Day 1'), isTrue);
      expect(await a.newFolder(space, 'Inner', parent: 'Day 1'), isTrue);
      expect(await a.removeFolder(space, 'Holiday'), isTrue);
      await until(() => b.of(space).files.values.any((f) => f.name == 'sams.txt' && f.folder == null) && !b.of(space).folders.contains('Holiday'));
      expect(await a.removeFolder(space, 'Day 1', deleteFiles: true), isTrue);
      await until(() => b.of(space).files.length == 1 && b.of(space).folders.isEmpty, reason: 'Day 1, Inner and pier.jpg gone');
      expect(b.of(space).files.values.single.name, 'sams.txt');
    });

    test('a file too big for the relay fails with its words, and nothing is kept for it', () async {
      await relay.stop();
      await boot(config: const FilesConfig(maxFile: 50000));
      final a = device(maya, 'Maya');
      a.upload(space, [fileOf('huge.iso', bytesOf(60000, 3)).path]);
      await until(() => a.transfers.single.state == TransferState.failed);
      expect(a.transfers.single.error, contains('Too big'));
      expect(a.transfers.single.retryable, isFalse, reason: 'trying again can never mend it, so no Try again is offered');
      expect(a.of(space).files, isEmpty);
      await a.cancel(a.transfers.single);
      expect(a.transfers, isEmpty);
    });

    test('with the relay away, the list is what was kept and an upload waits', () async {
      final a = device(maya, 'Maya');
      await a.open(space);
      await relay.stop();
      await a.of(space).refresh();
      expect(a.of(space).error!.offline, isTrue);
      a.upload(space, [fileOf('later.txt', bytesOf(5, 4)).path]);
      await until(() => a.transfers.single.state == TransferState.waiting);
      expect(a.transfers.single.error, contains('Can\'t reach'));
      // Not tried again and again meanwhile: it waits its turn.
      final tries = a.transfers.single.tries;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.transfers.single.tries, tries);
    });
  });
}
