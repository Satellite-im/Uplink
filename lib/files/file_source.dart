import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../net/crypto.dart';

/// A file to go up that is no path on this device (FilesStore.uploadSources): in a browser, the `File` a person
/// picked or dropped on the page (lib/files/browser_files_web.dart), read a piece at a time, never whole. The app's
/// own uploads are paths, read as they always were.
abstract class FileSource {
  /// Its name as the person's computer has it, its size, its kind (empty where the browser doesn't say) and when it
  /// was last changed (milliseconds; 0 where unknown).
  String get name;
  int get size;
  String get mime;
  int get modified;

  /// [length] bytes from [from]: fewer only where the file is shorter than it said, which the upload refuses.
  Future<Uint8List> read(int from, int length);
}

/// Bytes in memory as a [FileSource]: for a test, and for what is already held whole.
class BytesSource implements FileSource {
  BytesSource(this.name, this.bytes, {this.mime = '', this.modified = 0});
  @override
  final String name;
  final Uint8List bytes;
  @override
  final String mime;
  @override
  final int modified;
  @override
  int get size => bytes.length;

  /// How many reads were asked of it, and the most bytes any one asked: for a test that nothing reads it whole.
  int reads = 0, most = 0;

  @override
  Future<Uint8List> read(int from, int length) async {
    reads++;
    if (length > most) most = length;
    final end = (from + length).clamp(0, bytes.length);
    return Uint8List.fromList(Uint8List.sublistView(bytes, from.clamp(0, bytes.length), end));
  }
}

/// The SHA-256 of [source] in hex, read [piece] bytes at a time (4 MB): each read waits for the browser, so the page
/// draws between them. [told] hears how many bytes are read.
Future<String> shaOfSource(FileSource source, {void Function(int read)? told, int piece = 4 << 20}) async {
  late crypto.Digest digest;
  final sink = crypto.sha256.startChunkedConversion(_Sink((d) => digest = d));
  var at = 0;
  while (at < source.size) {
    final want = source.size - at < piece ? source.size - at : piece;
    final got = await source.read(at, want);
    if (got.length != want) throw StateError('The file changed while it was going up.');
    sink.add(got);
    at += want;
    told?.call(at);
  }
  sink.close();
  return NetCrypto.hex(Uint8List.fromList(digest.bytes));
}

class _Sink implements Sink<crypto.Digest> {
  _Sink(this._then);
  final void Function(crypto.Digest) _then;
  @override
  void add(crypto.Digest data) => _then(data);
  @override
  void close() {}
}
