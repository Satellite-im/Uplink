/// What a pack's icon and a submission's screenshots may be (A.5, and the screenshots' rules on the relay): a PNG,
/// read from its chunks alone, with nothing in it but pixels. No animation, no text, no EXIF and no colour profile:
/// a stranger's picture is shown to everyone, and served from gogho.st. The relay has its own copy of these checks.
library;

import 'dart:typed_data';

/// What a PNG says of itself, read from its chunks alone: nothing is decoded or inflated.
class PngInfo {
  const PngInfo({required this.width, required this.height, required this.bitDepth, required this.colorType, required this.interlace, required this.chunks});
  final int width, height, bitDepth, colorType, interlace;
  final List<String> chunks;                     // the chunk types, in order
}

const List<int> _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

int _u32(List<int> b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// Each chunk of [bytes] as (its type, where it starts, where it ends), or null where they aren't a PNG of whole
/// chunks with IHDR (13 bytes) first and IEND last and nothing after it.
List<(String, int, int)>? _chunks(List<int> bytes) {
  if (bytes.length < _signature.length) return null;
  for (var i = 0; i < _signature.length; i++) {
    if (bytes[i] != _signature[i]) return null;
  }
  final out = <(String, int, int)>[];
  var at = _signature.length;
  while (at < bytes.length) {
    // A length, a type, the data and a CRC, every chunk wholly inside the file.
    if (at + 12 > bytes.length) return null;
    final length = _u32(bytes, at);
    final end = at + 12 + length;
    if (length > bytes.length || end > bytes.length) return null;
    final type = String.fromCharCodes(bytes.sublist(at + 4, at + 8));
    if (out.isEmpty && (type != 'IHDR' || length != 13)) return null;
    out.add((type, at, end));
    at = end;
    if (type == 'IEND') return at == bytes.length ? out : null;
  }
  return null;
}

/// Null where [bytes] isn't a PNG of whole chunks with IHDR (13 bytes) first and IEND last and nothing after it.
PngInfo? pngInfo(List<int> bytes) {
  final chunks = _chunks(bytes);
  if (chunks == null) return null;
  return PngInfo(width: _u32(bytes, 16), height: _u32(bytes, 20), bitDepth: bytes[24], colorType: bytes[25], interlace: bytes[28], chunks: [for (final c in chunks) c.$1]);
}

const Set<String> pngChunksAllowed = {'IHDR', 'PLTE', 'tRNS', 'sRGB', 'gAMA', 'pHYs', 'IDAT', 'IEND'};

/// Null where [bytes] is a PNG ([pngInfo]) holding only [pngChunksAllowed], each side between [min] and [max], and
/// square where [square]; else why not, in plain words. A pack's icon: (64, 512, square). A screenshot: (64, 2400).
String? pngProblem(List<int> bytes, {required int min, required int max, bool square = false}) {
  final info = pngInfo(bytes);
  if (info == null) return 'It isn\'t a PNG picture.';
  for (final type in info.chunks) {
    if (!pngChunksAllowed.contains(type)) return 'It holds more than a picture (a "$type" part): save it again as a plain PNG.';
  }
  if (square && info.width != info.height) return 'It must be square: this one is ${info.width} by ${info.height}.';
  if (info.width < min || info.height < min || info.width > max || info.height > max) return 'Each side must be $min to $max pixels: this one is ${info.width} by ${info.height}.';
  return null;
}

/// [bytes] with only IHDR, PLTE, tRNS, IDAT and IEND kept, in order, their CRCs as they were: what Flutter's encoder
/// writes, made to pass [pngProblem] whatever else it adds. ArgumentError where [bytes] isn't a PNG.
Uint8List cleanPng(List<int> bytes) {
  final chunks = _chunks(bytes);
  if (chunks == null) throw ArgumentError('Not a PNG');
  const kept = {'IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'};
  final out = BytesBuilder(copy: false)..add(_signature);
  for (final (type, start, end) in chunks) {
    if (kept.contains(type)) out.add(bytes.sublist(start, end));
  }
  return out.takeBytes();
}
