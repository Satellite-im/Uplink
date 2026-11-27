import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/account/argon2_browser.dart';
import 'package:ghost_messaging/net/crypto.dart';

/// The password's stretching (Argon2id) as both halves must give it (Matt: "the full web client"): Dart's here, held
/// to test/vectors/argon2id.json; the browser's own (web/argon2id.js) is held to the same file by
/// tool/web/build-argon2.mjs as it is built, and by tool/web/e2e.mjs in the page itself. An account made on a phone
/// is signed in to in a browser only if the two give the same key.
void main() {
  final file = jsonDecode(File('test/vectors/argon2id.json').readAsStringSync()) as Map;
  final vectors = (file['vectors'] as List).cast<Map>();

  test('the vectors are there: the reference implementation\'s own, an account\'s settings, and a password that is not ASCII', () {
    expect(vectors.length, greaterThanOrEqualTo(8));
    expect(vectors.where((v) => '${v['of']}'.contains('reference implementation')).length, greaterThanOrEqualTo(6));
    expect(vectors.any((v) => v['m'] == AccountCrypto.argonMemoryKiB && v['t'] == AccountCrypto.argonPasses && v['p'] == AccountCrypto.argonLanes), isTrue);
    expect(vectors.any((v) => utf8.encode(v['password'] as String).length != (v['password'] as String).length), isTrue);
  });

  for (final v in vectors) {
    test('Dart\'s gives ${v['key'].toString().substring(0, 12)}… (${v['m']} KiB, ${v['t']} passes, ${v['p']} lanes): ${v['of']}', () {
      final key = AccountCrypto.passwordKey(v['password'] as String, NetCrypto.unhex(v['salt'] as String), memoryKiB: v['m'] as int, passes: v['t'] as int, lanes: v['p'] as int);
      expect(NetCrypto.hex(key), v['key']);
    });
  }

  test('where this runs there is no browser to ask, and the password is stretched in Dart, off the screen\'s thread', () async {
    expect(browserArgon2id(Uint8List(8), Uint8List(16), memoryKiB: 256, passes: 1, lanes: 1), isNull);
    final v = vectors.firstWhere((v) => v['m'] == 256 && v['p'] == 1);
    final key = await AccountCrypto.passwordKeyAway(v['password'] as String, NetCrypto.unhex(v['salt'] as String), memoryKiB: v['m'] as int, passes: v['t'] as int, lanes: v['p'] as int);
    expect(NetCrypto.hex(key), v['key']);
  });

  test('the browser\'s file is the one its script builds, from the version the extension pins', () {
    final built = File('web/argon2id.js').readAsStringSync();
    final pinned = (jsonDecode(File('extension/package.json').readAsStringSync()) as Map)['dependencies']['@noble/hashes'] as String;
    expect(pinned, matches(RegExp(r'^\d+\.\d+\.\d+$')), reason: 'one version, not a range');
    expect(built, contains('From @noble/hashes $pinned ('));
    final integrity = ((jsonDecode(File('extension/package-lock.json').readAsStringSync()) as Map)['packages'] as Map)['node_modules/@noble/hashes']['integrity'] as String;
    expect(built, contains(integrity));
    expect(built, contains('tool/web/build-argon2.mjs'));
    // Nothing in it reaches out: no address, and nothing that fetches.
    expect(RegExp(r'https?://(?!paulmillr\.com\b)').hasMatch(built), isFalse);
    for (final word in ['fetch(', 'XMLHttpRequest', 'importScripts(', 'WebSocket', 'eval(']) {
      expect(built.contains(word), isFalse, reason: word);
    }
  });
}
