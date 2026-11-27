import 'dart:convert';
import 'dart:typed_data';


import 'crypto.dart';
import 'fast_gcm.dart';

/// A Files space's files sealed end to end (Matt, 2026-11-17: "add full functionality for filesharing in a space when
/// the space is designated a Files Space"). The relay keeps them (relay/lib/files.dart) and never has a key to them.
///
/// - Each file has a key of its own (32 random bytes) and is sealed in chunks of [chunk] bytes, each with AES-256-GCM.
///   Chunks let a file go up and come down a piece at a time, without being read into memory whole, pick up where a
///   lost connection stopped, and be fetched from the middle with a Range.
/// - A chunk's nonce is the file's eight random bytes then the chunk's number (four bytes): never the same twice under
///   one key. What each chunk is bound to (the AAD) is the file's id, its number and whether it is the last, so chunks
///   can't be swapped, reordered or a file cut short without its opening failing.
/// - The file's key and those eight bytes travel in its description, which is sealed with the space's own files key
///   ([filesKey]), made from the space's seed: whoever has the space can open its files, and nobody else.
class FileSeal {
  FileSeal._();

  /// The plain bytes in each chunk; each sealed chunk is 16 bytes more (GCM's tag).
  static const chunk = 256 * 1024;
  static const tag = 16;

  /// The words every chunk's binding starts with.
  static final _label = utf8.encode('ghost-file v1');

  /// The key a space's file descriptions are sealed with, from its seed (64 hex digits).
  static Uint8List filesKey(String seed) => NetCrypto.derive(NetCrypto.unhex(seed), 'files key');

  /// The relay's name for the space's files, and the token to reach them: made from the seed as a hub room's are, under
  /// words of their own, so neither says anything of the space's chat or call.
  static String filesRoom(String seed) => NetCrypto.hex(NetCrypto.derive(NetCrypto.unhex(seed), 'files room').sublist(0, 16));
  static String filesToken(String seed) => NetCrypto.hex(NetCrypto.derive(NetCrypto.unhex(seed), 'files token'));

  /// How many chunks a file of [size] plain bytes is: at least one, so an empty file is one empty sealed chunk.
  static int chunks(int size, {int chunkSize = chunk}) => size <= 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize;

  /// The sealed size of a file of [size] plain bytes.
  static int sealedSize(int size, {int chunkSize = chunk}) => (size < 0 ? 0 : size) + tag * chunks(size, chunkSize: chunkSize);

  /// Where chunk [index] starts in the sealed file.
  static int sealedOffset(int index, {int chunkSize = chunk}) => index * (chunkSize + tag);

  /// The plain length of chunk [index] of a file of [size].
  static int plainLength(int index, int size, {int chunkSize = chunk}) {
    final n = chunks(size, chunkSize: chunkSize);
    if (index < n - 1) return chunkSize;
    return size - (n - 1) * chunkSize;
  }

  // A chunk's nonce: the file's eight bytes, then the chunk's number. And what it is bound to: the label, the
  // file's id, the chunk's number, and whether it is the last.
  static Uint8List nonceOf(List<int> prefix, int index) => _nonce(prefix, index);
  static Uint8List aadOf(String fileId, int index, bool last) => _aad(fileId, index, last);

  static Uint8List _nonce(List<int> prefix, int index) => Uint8List.fromList([...prefix, (index >> 24) & 0xff, (index >> 16) & 0xff, (index >> 8) & 0xff, index & 0xff]);

  static Uint8List _aad(String fileId, int index, bool last) =>
      Uint8List.fromList([..._label, ...NetCrypto.unhex(fileId), (index >> 24) & 0xff, (index >> 16) & 0xff, (index >> 8) & 0xff, index & 0xff, last ? 1 : 0]);

  /// Chunk [index] of a file, sealed: its bytes then GCM's tag.
  static Uint8List sealChunk(List<int> key, List<int> prefix, String fileId, int index, bool last, List<int> plain) {
    // FastGcm: the same bytes as pointycastle's GCM at about ten times the speed (lib/net/fast_gcm.dart).
    return FastGcm(key).seal(_nonce(prefix, index), _aad(fileId, index, last), plain is Uint8List ? plain : Uint8List.fromList(plain));
  }

  /// Chunk [index] opened, or null where it was changed, moved, cut short or sealed under another key.
  static Uint8List? openChunk(List<int> key, List<int> prefix, String fileId, int index, bool last, List<int> sealed) {
    if (sealed.length < tag) return null;
    try {
      return FastGcm(key).open(_nonce(prefix, index), _aad(fileId, index, last), sealed is Uint8List ? sealed : Uint8List.fromList(sealed));
    } catch (_) {
      return null;
    }
  }

  /// The chunks of a run: each one's number, whether it is the file's last, and where its bytes are in the run (its
  /// plain bytes for [sealRun], its sealed bytes for [openRun], [sealed] saying which). What lib/net/file_seal_async.dart
  /// walks too, so a browser seals and opens exactly these chunks. Throws (sealing) or stops short with a null end
  /// (opening) where the run's bytes don't hold its last chunk whole.
  static Iterable<({int index, bool last, int start, int end})> runChunks({required int size, required int first, required int length, required int chunkSize, required bool sealed}) sync* {
    final n = chunks(size, chunkSize: chunkSize);
    var at = 0, i = first;
    do {
      final len = plainLength(i, size, chunkSize: chunkSize) + (sealed ? tag : 0);
      if (at + len > length) {
        if (!sealed) throw ArgumentError('chunk $i is short');
        yield (index: i, last: i == n - 1, start: at, end: -1);
        return;
      }
      yield (index: i, last: i == n - 1, start: at, end: at + len);
      at += len;
      i++;
    } while (at < length);
  }

  /// Seals chunks [first] onward of [plain] (the plain bytes of those chunks, one after another): what an upload sends
  /// in one piece. Plain data, so it may be run on another isolate.
  static Uint8List sealRun(SealRun run) {
    final out = BytesBuilder(copy: false);
    for (final c in runChunks(size: run.size, first: run.first, length: run.plain.length, chunkSize: run.chunkSize, sealed: false)) {
      out.add(sealChunk(run.key, run.prefix, run.fileId, c.index, c.last, Uint8List.sublistView(run.plain, c.start, c.end)));
    }
    return out.takeBytes();
  }

  /// Opens chunks [first] onward of [sealed]: null where any fails.
  static Uint8List? openRun(OpenRun run) {
    if (run.sealed.isEmpty) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    for (final c in runChunks(size: run.size, first: run.first, length: run.sealed.length, chunkSize: run.chunkSize, sealed: true)) {
      if (c.end < 0) return null;
      final plain = openChunk(run.key, run.prefix, run.fileId, c.index, c.last, Uint8List.sublistView(run.sealed, c.start, c.end));
      if (plain == null) return null;
      out.add(plain);
    }
    return out.takeBytes();
  }
}

/// What [FileSeal.sealRun] needs: plain, so it crosses to another isolate.
class SealRun {
  const SealRun({required this.key, required this.prefix, required this.fileId, required this.size, required this.first, required this.plain, this.chunkSize = FileSeal.chunk});
  final Uint8List key;
  final Uint8List prefix;
  final String fileId;

  /// The whole file's plain size, and the number of the first chunk in [plain].
  final int size;
  final int first;
  final Uint8List plain;
  final int chunkSize;
}

/// What [FileSeal.openRun] needs: the sealed chunks from [first] on, plain for the same reason.
class OpenRun {
  const OpenRun({required this.key, required this.prefix, required this.fileId, required this.size, required this.first, required this.sealed, this.chunkSize = FileSeal.chunk});
  final Uint8List key;
  final Uint8List prefix;
  final String fileId;
  final int size;
  final int first;
  final Uint8List sealed;
  final int chunkSize;
}
