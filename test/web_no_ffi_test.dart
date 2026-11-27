import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/apple_sha.dart';
import 'package:ghost_messaging/files/apple_sha_web.dart' as web_sha;
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/td_json_web.dart' as web_td;
import 'package:ghost_messaging/inbox/telegram.dart';

/// What reaches C through `dart:ffi` is in two halves each (Matt: "the full web client"): a build for a browser can't
/// so much as name `dart:ffi`, so the browser's half says "not here" the way a build without the library always has.
/// That nothing else names `dart:ffi` is one of the release guards (test/source_guards_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });

  test('TDLib in a browser: no library, so Telegram says it isn\'t in this build', () async {
    expect(await web_td.TdJson.start(), isNull);
    final tg = Telegram(apiId: 12345, apiHash: 'hash', folder: '/tmp/tg', transport: web_td.TdJson.start);
    await tg.start(AppState());
    expect(tg.state, InboxState.signedOut);
    await tg.begin();
    expect(tg.state, InboxState.unavailable);
    expect(tg.error, 'Telegram isn\'t in this build of the app.');
  });

  test('CommonCrypto in a browser: none, so a file is read by the plain Dart reader', () {
    expect(web_sha.AppleSha.open(), isNull);
  });

  test('CommonCrypto on a Mac, moved to its own file, hashes as it did', () {
    final sha = AppleSha.open();
    expect(sha, isNotNull);
    final bytes = Uint8List.fromList(utf8.encode('abc' * 100000));
    // In two pieces, the second from the buffer's start as shaOfFile hands them on.
    sha!.add(bytes, 100000);
    sha.add(Uint8List.sublistView(bytes, 100000), bytes.length - 100000);
    expect(sha.end(), crypto.sha256.convert(bytes).bytes);
    sha.close();
  }, skip: Platform.isMacOS ? false : 'CommonCrypto is a Mac\'s and an iPhone\'s');
}

