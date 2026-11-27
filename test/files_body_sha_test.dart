import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/net/crypto.dart';

/// GMFB-6 (@matt, Mac 0.11.3: "The app is super laggy when in a voice call and uploading a video to the files"): each
/// 4 MB piece going up was hashed on the UI's isolate. It is hashed aside now, and must give the very hash the relay
/// checks, small bodies and pieces alike.
void main() {
  test('a body\'s hash is the same SHA-256 as before, small or a whole piece', () async {
    final r = Random(7);
    for (final size in [0, 1, 1000, 256 * 1024 - 1, 256 * 1024, 4 * 1024 * 1024 + 32]) {
      final body = Uint8List.fromList(List.generate(size, (_) => r.nextInt(256)));
      expect(await FilesApi.bodySha(body), NetCrypto.hex(NetCrypto.sha256(body)), reason: '$size bytes');
    }
    // A list that is not a Uint8List hashes the same.
    expect(await FilesApi.bodySha(List<int>.filled(300 * 1024, 9)), NetCrypto.hex(NetCrypto.sha256(Uint8List.fromList(List<int>.filled(300 * 1024, 9)))));
  });
}
