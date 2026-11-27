import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/friends/file_card.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/souls/souls_send.dart';
import 'package:ghost_messaging/voice/hangout.dart' show OutgoingFile;
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

import 'files_space_test.dart' show FakeHub, FakeRoute, until, bytesOf;

// Matt, 2026-11-25: "also allow sending pictures and attachements to ghost users". lib/friends/file_card.dart.

SpaceFile _file(String name, {int size = 1258291, int thumb = 0}) => SpaceFile(
      id: 'ab' * 16,
      name: name,
      size: size,
      mime: 'image/jpeg',
      sha: 'cd' * 32,
      key: Uint8List.fromList(List.generate(32, (i) => i)),
      prefix: Uint8List.fromList(List.generate(8, (i) => i)),
      by: 'me',
      byName: 'Matt',
      at: 1795000000000,
      thumb: thumb == 0 ? null : Uint8List(thumb),
    );

void main() {
  final seed = 'e1' * 32;

  test('a card is its line, then where the files are, and reads back as it was', () {
    final card = FileCard(seed: seed, files: [_file('photo.jpg')]);
    final lines = card.words.split('\n');
    expect(lines, hasLength(2));
    expect(lines.first, '📎 photo.jpg (1.3 MB)', reason: 'what an app from before cards shows');
    final back = FileCard.of(card.words, by: '@maya', at: 5);
    expect(back, isNotNull);
    expect(back!.seed, seed);
    expect(back.files.single.name, 'photo.jpg');
    expect(back.files.single.size, 1258291);
    expect(back.files.single.key, card.files.single.key);
    expect(back.files.single.by, '@maya', reason: 'whose it is comes from who sent the message, not from the card');
    expect(FileCard(seed: seed, files: [_file('a.jpg'), _file('b.pdf')]).line, '📎 2 files');
  });

  test('words that are not a card are not one', () {
    expect(FileCard.of('hello'), isNull);
    expect(FileCard.of('📎 photo.jpg (1.3 MB)'), isNull);
    expect(FileCard.of('📎 photo.jpg\nGhost file: not json'), isNull);
    expect(FileCard.of('📎 photo.jpg\nGhost file: {"s":"short","a":[]}'), isNull);
    expect(FileCard.of('📎 photo.jpg\nGhost file: {"s":"$seed","a":[]}'), isNull, reason: 'no files');
    expect(FileCard.of('📎 photo.jpg\nGhost file: {"s":"$seed","a":[{"id":"nope"}]}'), isNull, reason: 'a file that does not read');
    expect(FileCard.of('📎 a\nmore words\nGhost file: {"s":"$seed","a":[]}'), isNull, reason: 'only on the second line');
    final six = FileCard(seed: seed, files: [for (var i = 0; i < 6; i++) _file('$i.jpg')]);
    expect(FileCard.of(six.words), isNull, reason: 'more than a card carries');
  });

  test('a list shows a card as its line and other words as they are', () {
    final card = FileCard(seed: seed, files: [_file('photo.jpg')]);
    expect(FileCard.preview(card.words), '📎 photo.jpg (1.3 MB)');
    expect(FileCard.preview('see you at 7'), 'see you at 7');
    expect(FileCard.preview(SoulsCard.preview('📎 just an emoji line')), '📎 just an emoji line');
  });

  test('a full card fits a packet and a part of history, with every small picture as large as it may be', () {
    for (final n in [1, 3, FileCard.mostFiles]) {
      final card = FileCard(seed: seed, files: [for (var i = 0; i < n; i++) _file('holiday photograph number $i.jpeg', thumb: FileCard.thumbMost(n))]);
      expect(card.words.length, lessThan(36 * 1024), reason: '$n files');
      expect(FileCard.of(card.words), isNotNull);
    }
  });

  test('the space an account keeps them in is made from its shared key, and is not its drive', () {
    final key = List.generate(32, (i) => i);
    expect(FileCard.seedOf(key), hasLength(64));
    expect(FileCard.seedOf(key), FileCard.seedOf(key));
    expect(FileCard.seedOf(key), isNot(FileCard.seedOf(List.generate(32, (i) => i + 1))));
    expect(FileCard.channelOf(seed).owner, '', reason: 'no owner: a key made from the seed would be everyone\'s who was sent a card');
  });

  // GMFB-59 (@kevin, Android, 0.12.25): "I cannot send files such as images from the android app to another ghost
  // user, only souls". The whole way between two accounts, against the relay as it is: Maya's file goes up sealed to
  // her own "sent to friends" space, the card's words are all Sam is given, and from them alone his device brings the
  // file down and opens it. Someone with the words but another file's id, or a changed key, gets nothing.
  group('two accounts and the relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    final stores = <FilesStore>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ghost-file-card');
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay'), config: const FilesConfig()));
      base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
    });

    tearDown(() async {
      for (final s in stores) {
        await s.clear();
      }
      stores.clear();
      await relay.stop();
    });

    test('a picture sent to a friend comes down whole on the friend\'s device, from the card\'s words alone', () async {
      final hub = FakeHub();
      final maya = KeysSigner(NetKeys.generate()), sam = KeysSigner(NetKeys.generate());
      FilesStore device(KeysSigner who, String name) {
        final s = FilesStore.forTest(base: base, signer: who, data: Directory('${dir.path}/$name'), route: FakeRoute(hub, who.id), name: name, piece: 2);
        stores.add(s);
        return s;
      }

      final a = device(maya, 'Maya'), b = device(sam, 'Sam');
      await a.start();
      final data = bytesOf(300 * 1000, 5);
      final picked = File('${dir.path}/in/IMG_0042.jpg')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(data);
      final mine = FileCard.seedOf(List.generate(32, (i) => i));
      final up = await a.uploadForChat(FileCard.channelOf(mine), OutgoingFile(path: picked.path, name: 'IMG_0042.jpg', size: data.length, mime: 'image/jpeg'), byName: 'maya', thumbMost: FileCard.thumbMost(1), moved: () {});
      await until(() => a.transfers.isEmpty);
      final words = FileCard(seed: mine, files: [up]).words;
      expect(words.split('\n').first, '📎 IMG_0042.jpg (300 KB)');

      // Sam's device: the words, and nothing else of Maya's.
      final card = FileCard.of(words, by: '@maya', at: 7)!;
      final got = card.files.single;
      expect(got.name, 'IMG_0042.jpg');
      expect(b.cached(got), isNull, reason: 'not here until asked for');
      expect(await File(await b.fetch(FileCard.channelOf(card.seed), got)).readAsBytes(), data);

      // The words with the file's key changed open nothing, and another id finds nothing.
      final key = Uint8List.fromList(got.key)..[0] ^= 1;
      final wrong = SpaceFile(id: got.id, name: 'other.jpg', size: got.size, mime: got.mime, sha: got.sha, key: key, prefix: got.prefix, by: got.by, byName: got.byName, at: got.at);
      final c = device(KeysSigner(NetKeys.generate()), 'Theo');
      await expectLater(c.fetch(FileCard.channelOf(card.seed), wrong), throwsA(isA<FilesError>()));
      final none = SpaceFile(id: 'f' * 32, name: 'none.jpg', size: got.size, mime: got.mime, sha: got.sha, key: got.key, prefix: got.prefix, by: got.by, byName: got.byName, at: got.at);
      await expectLater(c.fetch(FileCard.channelOf(card.seed), none), throwsA(isA<FilesError>()));
    });
  });
}
