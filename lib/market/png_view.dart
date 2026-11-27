/// A PNG decoded in Dart alone, for the reviewer's screen (SPEC D.10): every submission's screenshots are a stranger's
/// bytes, and the device that reviews them holds the review key and the admin session, so they never reach the
/// platform's image codecs there. Only the plainest PNGs are drawn (8 bits a channel, not interlaced, the five colour
/// types), the inflated data is bounded before it is held, and anything else is "Can't show this picture here".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../plugins/pack/pack.dart' show pngInfo, pngProblem;

int _u32(List<int> b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// [bytes] as an image, decoded here rather than by the platform; null where it isn't a PNG [pngProblem] passes with
/// sides of 1 to [most], or it is one this decoder leaves alone (16-bit, interlaced) or its data doesn't hold.
Future<ui.Image?> decodePngInDart(Uint8List bytes, {int most = 2400}) async {
  final rgba = pngPixelsInDart(bytes, most: most);
  if (rgba == null) return null;
  final info = pngInfo(bytes)!;
  final done = Completer<ui.Image?>();
  try {
    ui.decodeImageFromPixels(rgba, info.width, info.height, ui.PixelFormat.rgba8888, done.complete);
  } catch (_) {
    return null;
  }
  return done.future;
}

/// The RGBA pixels of [bytes], or null: [decodePngInDart]'s work, without the image (a test reads it).
Uint8List? pngPixelsInDart(Uint8List bytes, {int most = 2400}) {
  try {
    if (pngProblem(bytes, min: 1, max: most) != null) return null;
    final info = pngInfo(bytes)!;
    if (info.bitDepth != 8 || info.interlace != 0) return null;
    final channels = switch (info.colorType) { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4, _ => 0 };
    if (channels == 0) return null;
    final w = info.width, h = info.height;
    Uint8List? palette;
    Uint8List? trns;
    final idat = BytesBuilder(copy: false);
    var at = 8;
    while (at + 12 <= bytes.length) {
      final length = _u32(bytes, at);
      final type = ascii.decode(bytes.sublist(at + 4, at + 8));
      final data = Uint8List.sublistView(bytes, at + 8, at + 8 + length);
      if (type == 'PLTE') palette = data;
      if (type == 'tRNS') trns = data;
      if (type == 'IDAT') idat.add(data);
      at += 12 + length;
      if (type == 'IEND') break;
    }
    if (info.colorType == 3 && (palette == null || palette.length % 3 != 0)) return null;
    final stride = w * channels;
    final want = h * (stride + 1);
    // Inflated a piece at a time, stopping past what an image this size could need: no bomb is ever held whole.
    final raw = _inflate(idat.takeBytes(), most: w * h * 4 + h);
    if (raw == null || raw.length < want) return null;
    final pixels = _unfilter(raw, w, h, channels);
    if (pixels == null) return null;
    return _rgba(pixels, w, h, info.colorType, palette, trns);
  } catch (_) {
    return null;
  }
}

/// [data] inflated, or null where it is broken or comes to more than [most] bytes.
Uint8List? _inflate(Uint8List data, {required int most}) {
  final out = BytesBuilder(copy: false);
  var over = false;
  final inflating = ZLibDecoder().startChunkedConversion(_Counting(out, most, () => over = true));
  try {
    const piece = 16384;
    for (var i = 0; i < data.length && !over; i += piece) {
      inflating.add(Uint8List.sublistView(data, i, i + piece > data.length ? data.length : i + piece));
    }
    if (!over) inflating.close();
  } catch (_) {
    return null;
  }
  return over ? null : out.takeBytes();
}

/// Takes what is inflated until there is more than [most] of it, then says so and stops it.
class _Counting implements Sink<List<int>> {
  _Counting(this.out, this.most, this.over);
  final BytesBuilder out;
  final int most;
  final void Function() over;
  var _n = 0;

  @override
  void add(List<int> chunk) {
    _n += chunk.length;
    if (_n > most) {
      over();
      throw const FormatException('Too large');
    }
    out.add(chunk);
  }

  @override
  void close() {}
}

/// The five filters undone, a row at a time: the pixels' bytes, [channels] a pixel.
Uint8List? _unfilter(Uint8List raw, int w, int h, int channels) {
  final stride = w * channels;
  final out = Uint8List(stride * h);
  var r = 0;
  for (var y = 0; y < h; y++) {
    final filter = raw[r++];
    final row = y * stride;
    final up = row - stride;
    for (var x = 0; x < stride; x++) {
      final v = raw[r++];
      final a = x >= channels ? out[row + x - channels] : 0;
      final b = y > 0 ? out[up + x] : 0;
      final c = x >= channels && y > 0 ? out[up + x - channels] : 0;
      final f = switch (filter) {
        0 => v,
        1 => v + a,
        2 => v + b,
        3 => v + ((a + b) >> 1),
        4 => v + _paeth(a, b, c),
        _ => -1,
      };
      if (f < 0) return null;
      out[row + x] = f & 0xFF;
    }
  }
  return out;
}

// PNG's Paeth predictor: whichever of left ([a]), above ([b]) and above-left ([c]) is nearest to a + b - c, ties
// going in that order.
int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// [pixels] as RGBA, by their colour type: grey, RGB, a palette's, grey with alpha, or RGBA; tRNS where given.
Uint8List? _rgba(Uint8List pixels, int w, int h, int colorType, Uint8List? palette, Uint8List? trns) {
  final n = w * h;
  final out = Uint8List(n * 4);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    switch (colorType) {
      case 0:
        final g = pixels[i];
        out[o] = out[o + 1] = out[o + 2] = g;
        // A grey key in 16 bits: at 8 bits deep, its low byte is the grey that is clear.
        out[o + 3] = trns != null && trns.length >= 2 && trns[1] == g && trns[0] == 0 ? 0 : 255;
      case 2:
        final r = pixels[i * 3], g = pixels[i * 3 + 1], b = pixels[i * 3 + 2];
        out[o] = r;
        out[o + 1] = g;
        out[o + 2] = b;
        out[o + 3] = trns != null && trns.length >= 6 && trns[1] == r && trns[3] == g && trns[5] == b && trns[0] == 0 && trns[2] == 0 && trns[4] == 0 ? 0 : 255;
      case 3:
        final p = pixels[i];
        if (p * 3 + 2 >= palette!.length) return null;
        out[o] = palette[p * 3];
        out[o + 1] = palette[p * 3 + 1];
        out[o + 2] = palette[p * 3 + 2];
        out[o + 3] = trns != null && p < trns.length ? trns[p] : 255;
      case 4:
        final g = pixels[i * 2];
        out[o] = out[o + 1] = out[o + 2] = g;
        out[o + 3] = pixels[i * 2 + 1];
      case 6:
        out[o] = pixels[i * 4];
        out[o + 1] = pixels[i * 4 + 1];
        out[o + 2] = pixels[i * 4 + 2];
        out[o + 3] = pixels[i * 4 + 3];
    }
  }
  return out;
}
