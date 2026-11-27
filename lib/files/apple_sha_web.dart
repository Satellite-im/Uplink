import 'dart:typed_data';

/// CommonCrypto in a browser (lib/files/apple_sha.dart): there is none, so [open] finds nothing, as it finds nothing on
/// Android and Windows. Nothing makes one of these.
abstract final class AppleSha {
  /// Always null here.
  static AppleSha? open() => null;

  void add(Uint8List bytes, int length);
  Uint8List end();
  void close();
}
