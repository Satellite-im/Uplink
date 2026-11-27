import 'dart:typed_data';

/// Not in a browser (lib/account/argon2_browser.dart): null, always.
Future<Uint8List>? browserArgon2id(Uint8List password, Uint8List salt, {required int memoryKiB, required int passes, required int lanes, int length = 32}) => null;
