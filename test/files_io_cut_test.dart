// The app's FilesApi when the connection drops while an answer's body is read (the review of web-files, F1): before the
// files layer was split for the browser this came out as FilesError(0), the relay out of reach, and an upload waited and
// tried again; after it, a raw HttpException left the upload standing in "running". IoFilesHttp says it as before.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

class _Signer implements NetSigner {
  @override
  String get id => '0' * 32;
  @override
  Uint8List get publicKey => Uint8List(65);
  @override
  Future<Uint8List> sign(List<int> message) async => Uint8List(64);
}

void main() {
  test('a connection cut while a JSON answer or a blob is read is the relay out of reach (FilesError, status 0)', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) async {
      s.listen((_) {});
      s.add('HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 500\r\n\r\n{"used": 1, '.codeUnits);
      await s.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      s.destroy();
    });
    final api = FilesApi(base: Uri.parse('http://127.0.0.1:${server.port}/files'), space: 'a' * 32, token: 't', signer: _Signer());
    addTearDown(api.close);
    await expectLater(api.info(), throwsA(isA<FilesError>().having((e) => e.offline, 'offline', isTrue)));
    final blob = await api.read('b' * 32);
    await expectLater(blob.toList(), throwsA(isA<FilesError>().having((e) => e.offline, 'offline', isTrue)));
  });
}
