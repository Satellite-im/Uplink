import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/account/gzip.dart';
import 'package:ghost_messaging/account/gzip_io.dart' as io;
import 'package:ghost_messaging/account/gzip_web.dart' as web;
import 'package:ghost_messaging/net/crypto.dart';

/// gzip for the account's backup (lib/account/gzip.dart; Matt: "the full web client"): a backup packed on a phone is
/// opened in a browser and one packed in a browser on a phone, so each half must open what the other packed.
void main() {
  final rnd = Random(7);
  final samples = <String, List<int>>{
    'nothing': const [],
    'one byte': const [0x7b],
    'a little JSON': utf8.encode(jsonEncode({'v': 1, 'w': 'abandon ability able', 'f': []})),
    'friends and circles that pack well': utf8.encode(jsonEncode({'f': [for (var i = 0; i < 4000; i++) {'u': 'friend$i', 'k': 'ab' * 33, 'n': 'Friend number $i'}]})),
    'what does not pack at all': [for (var i = 0; i < 70000; i++) rnd.nextInt(256)],
    'one byte over and over': List<int>.filled(300000, 0x61),
  };

  test('where this runs, the backup\'s gzip is dart:io\'s own', () {
    expect(identical(gzip, io.gzip), isTrue);
    expect(identical(gzip, web.gzip), isFalse);
  });

  for (final MapEntry(key: name, value: clear) in samples.entries) {
    test('each half opens what the other packed: $name', () {
      final byIo = io.gzip.encode(clear), byWeb = web.gzip.encode(clear);
      // Both are gzip: its two magic bytes, and deflate.
      expect(byIo.sublist(0, 3), [0x1f, 0x8b, 8]);
      expect(byWeb.sublist(0, 3), [0x1f, 0x8b, 8]);
      expect(web.gzip.decode(byIo), clear);
      expect(io.gzip.decode(byWeb), clear);
      expect(web.gzip.decode(byWeb), clear);
      expect(io.gzip.decode(byIo), clear);
      // And neither is the worse packer by much: the relay keeps a limited size.
      expect(byWeb.length, lessThan(byIo.length * 1.1 + 32));
    });
  }

  test('a pack that was changed is refused by both, and one cut short by the browser\'s', () {
    final clear = samples['friends and circles that pack well']!;
    for (final packed in [io.gzip.encode(clear), web.gzip.encode(clear)]) {
      final bent = Uint8List.fromList(packed)..[packed.length ~/ 2] ^= 0x10;
      // The last eight bytes say what the whole should hash to and how long it is.
      final wrongSum = Uint8List.fromList(packed)..[packed.length - 6] ^= 1;
      final wrongLength = Uint8List.fromList(packed)..[packed.length - 2] ^= 1;
      for (final bad in [bent, wrongSum, wrongLength, utf8.encode('not gzip at all')]) {
        expect(() => io.gzip.decode(bad), throwsA(anything));
        expect(() => web.gzip.decode(bad), throwsA(anything));
      }
      // dart:io's hands back what it could read of one cut short, or with more after it; the browser's refuses those
      // too. A backup is unpacked only after its seal has shown it whole, so neither is ever asked.
      for (final bad in [packed.sublist(0, packed.length - 3), packed.sublist(0, packed.length ~/ 2), [...packed, 0], const <int>[]]) {
        expect(() => web.gzip.decode(bad), throwsA(anything));
      }
    }
  });

  test('a backup packed by either half is the same backup to the other', () {
    final backup = AccountBackup(
      words: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'.split(' '),
      identity: NetCrypto.hex(NetKeys.generate().scalar),
      mode: 'bound',
      username: 'maya',
      displayName: 'Maya Chen',
      bio: 'hi',
      keptKey: 'ab' * 32,
      friends: const [{'u': 'sam', 'k': 'cd'}],
      circles: const [{'s': 'seed', 'n': 'Family'}],
      at: DateTime.fromMillisecondsSinceEpoch(1790000000000),
    );
    // As AccountBackup.pack and unpack do it, with the browser's gzip in place of this device's.
    final packedByWeb = Uint8List.fromList(web.gzip.encode(utf8.encode(jsonEncode(backup.toJson()))));
    final here = AccountBackup.unpack(packedByWeb);
    expect(here, isNotNull);
    expect(here!.toJson(), backup.toJson());
    final there = AccountBackup.fromJson(jsonDecode(utf8.decode(web.gzip.decode(backup.pack()))));
    expect(there, isNotNull);
    expect(there!.toJson(), backup.toJson());
    // And what can't be read is no backup, as before.
    expect(AccountBackup.unpack(Uint8List.fromList(packedByWeb)..[packedByWeb.length ~/ 2] ^= 0x10), isNull);
    expect(AccountBackup.unpack(utf8.encode('not gzip at all')), isNull);
  });
}
