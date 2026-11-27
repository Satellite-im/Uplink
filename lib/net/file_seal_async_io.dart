import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../aside.dart';
import 'file_seal.dart';

/// FileSeal on another isolate (lib/net/file_seal_async.dart): the app's own way.
class SealAsync {
  SealAsync._();

  static Future<Uint8List> sealRun(SealRun run) => runAside(() => FileSeal.sealRun(run));
  static Future<Uint8List?> openRun(OpenRun run) => runAside(() => FileSeal.openRun(run));
  static Future<Uint8List> sha256(Uint8List bytes) => runAside(() => Uint8List.fromList(crypto.sha256.convert(bytes).bytes));
}
