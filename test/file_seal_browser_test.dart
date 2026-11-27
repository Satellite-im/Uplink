// The browser's own sealing of a Files space's chunks (lib/net/file_seal_async_web.dart, WebCrypto) held to the app's
// (FileSeal, FastGcm): the same bytes, both ways, and the same refusals. Run in a browser:
//   flutter test --platform chrome test/file_seal_browser_test.dart
// (on a computer it is passed over: it needs a page's crypto.subtle).
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/file_seal_async.dart';

void main() {
  final key = NetCrypto.randomBytes(32), prefix = NetCrypto.randomBytes(8);
  const id = '00112233445566778899aabbccddeeff';
  Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

  test('WebCrypto seals each chunk to the very bytes FileSeal does, and each opens the other\'s', () async {
    for (final size in [0, 1, 999, 1000, 1001, 3507]) {
      final plain = bytes(size);
      final run = SealRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, plain: plain, chunkSize: 1000);
      final ours = FileSeal.sealRun(run);
      expect(await SealAsync.sealRun(run), ours, reason: 'size $size');
      expect(await SealAsync.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: size, first: 0, sealed: ours, chunkSize: 1000)), plain, reason: 'size $size');
    }
    // From the middle, as a download picks up.
    final plain = bytes(3507);
    final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: 3507, first: 0, plain: plain, chunkSize: 1000));
    final from = FileSeal.sealedOffset(2, chunkSize: 1000);
    expect(await SealAsync.openRun(OpenRun(key: key, prefix: prefix, fileId: id, size: 3507, first: 2, sealed: Uint8List.sublistView(sealed, from), chunkSize: 1000)), plain.sublist(2000));
  });

  test('WebCrypto refuses what FileSeal refuses: a byte changed, a chunk moved, cut short, another key', () async {
    final plain = bytes(2500);
    final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: 2500, first: 0, plain: plain, chunkSize: 1000));
    Future<Uint8List?> open(Uint8List s, {List<int>? k, int first = 0}) => SealAsync.openRun(OpenRun(key: Uint8List.fromList(k ?? key), prefix: prefix, fileId: id, size: 2500, first: first, sealed: s, chunkSize: 1000));
    expect(await open(Uint8List.fromList(sealed)..[5] ^= 1), isNull);
    expect(await open(Uint8List.sublistView(sealed, 1016, 2032)), isNull);
    expect(await open(Uint8List.sublistView(sealed, 0, 1500)), isNull);
    expect(await open(sealed, k: NetCrypto.randomBytes(32)), isNull);
    expect(await open(sealed, k: [1, 2, 3]), isNull);
  });

  test('the body hash a piece is signed with is the same from the browser\'s SHA-256', () async {
    final big = bytes(300 * 1024);
    expect(NetCrypto.hex(await SealAsync.sha256(big)), NetCrypto.hex(NetCrypto.sha256(big)));
    expect(await FilesApi.bodySha(big), NetCrypto.hex(NetCrypto.sha256(big)));
  });
}
