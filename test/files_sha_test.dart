import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_store.dart';

/// A file's checksum before it goes up (lib/files/files_store.dart; Matt, 2026-11-21, of a 26 GB file: "it's taking a
/// long time to 'getting file ready'"): the same words as before from a faster reader, which says how far it is.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sha'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the checksum is SHA-256, for nothing, a few bytes, and a file of several reads', () {
    final empty = File('${dir.path}/empty')..writeAsBytesSync(const []);
    expect(shaOfFile(empty.path), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    final abc = File('${dir.path}/abc')..writeAsStringSync('abc');
    expect(shaOfFile(abc.path), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    // Past two reads of four megabytes, and not a whole number of them.
    final bytes = Uint8List(9 * 1024 * 1024 + 123);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 31 + (i >> 8)) & 255;
    }
    final big = File('${dir.path}/big')..writeAsBytesSync(bytes);
    expect(shaOfFile(big.path), crypto.sha256.convert(bytes).toString());
    // The Dart reader (Android, Windows, Linux) and the Mac's own say the same.
    for (final f in [empty, abc, big]) {
      expect(shaOfFile(f.path, plain: true), shaOfFile(f.path));
    }
  });

  test('aside, it says how far it has read, never past the end, and gives the same checksum', () async {
    final bytes = Uint8List(24 * 1024 * 1024);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 7) & 255;
    }
    final file = File('${dir.path}/told')..writeAsBytesSync(bytes);
    final direct = <int>[];
    expect(shaOfFile(file.path, told: direct.add), crypto.sha256.convert(bytes).toString());
    expect(direct.last, bytes.length);
    expect(direct, orderedEquals([...direct]..sort()));
    final heard = <int>[];
    expect(await shaOfFileAside(file.path, told: heard.add), crypto.sha256.convert(bytes).toString());
    expect(heard.every((n) => n > 0 && n <= bytes.length), isTrue);
    expect(await shaOfFileAside(file.path), crypto.sha256.convert(bytes).toString());
  });

  test('a file that is not there is an error, not a wait for ever', () async {
    await expectLater(shaOfFileAside('${dir.path}/none', told: (_) {}), throwsA(isA<FileSystemException>()));
  });
}
