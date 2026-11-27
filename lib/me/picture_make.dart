import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'pictures.dart';

/// A profile picture as this person's own is kept and sent: [sharp], the one shown (up to [ProfilePictures.sharpSide]
/// square), and [small], a stand-in that builds from before 0.10.4 take (at most [ProfilePictures.oldMost]) and whose
/// [ProfilePictures.hashOf] a space's greeting carries. Both square base64 JPEG (an older picture: PNG).
class ProfilePicture {
  const ProfilePicture({required this.sharp, required this.small, this.full = ''});
  final String sharp;
  final String small;

  /// The same picture larger (up to [ProfilePictures.fullSide] square), for this person's own screens: kept on this
  /// device and never sent. '' where the picture chosen was no larger than [sharp].
  final String full;
}

/// [bytes] (any picture Flutter decodes) as a profile picture: the middle square, as JPEG, at the largest of a few
/// sizes and qualities that fits (Matt, 2026-11-20: "my uploaded profile picture is super blurry": a photo made a PNG
/// of at most 24000 characters came out 72 pixels across, drawn at up to 96 points). Null where it can't be read.
///
/// [crop] is the square of it to keep, as shares of its width and height (0 to 1 each way; lib/ui/picture_crop.dart);
/// the middle square where none is given.
Future<ProfilePicture?> profilePictureOf(Uint8List bytes, {ui.Rect? crop}) async {
  final sharp = await _square(bytes, sizes: const [ProfilePictures.sharpSide, 224, 192, 160, 128], qualities: const [84, 74, 64], most: ProfilePictures.sharpMost, crop: crop);
  if (sharp == null) return null;
  final small = await _square(bytes, sizes: const [128, 112, 96, 80, 64], qualities: const [72, 60], most: ProfilePictures.smallMost, crop: crop);
  final full = await _square(bytes, sizes: const [ProfilePictures.fullSide, 512, 384], qualities: const [90, 82], most: ProfilePictures.fullMost, crop: crop, larger: false);
  return ProfilePicture(sharp: sharp, small: small ?? '', full: full ?? '');
}

/// The middle square of [bytes] as a base64 JPEG of at most [most] characters: the first of [sizes] (pixels a side,
/// largest first) that fits at one of [qualities] (best first). Null where it can't be read or none fits.
///
/// [crop]: the part to keep, as shares of the picture ([profilePictureOf]). [larger] false: never made larger than the
/// part kept is, and null where it is smaller than every one of [sizes].
Future<String?> _square(Uint8List bytes, {required List<int> sizes, required List<int> qualities, required int most, ui.Rect? crop, bool larger = true}) async {
  ui.Image? image;
  try {
    // Decoded near the size wanted (a phone's photo is 12 million pixels or more), by the platform.
    final probe = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(probe);
    final whole = desc.width < desc.height ? desc.width : desc.height;
    final part = crop == null ? 1.0 : (crop.width * desc.width < crop.height * desc.height ? crop.width * desc.width : crop.height * desc.height) / whole;
    final short = whole * part.clamp(0.02, 1.0);
    final scale = short > sizes.first * 2 ? sizes.first * 2 / short : 1.0;
    final codec = await desc.instantiateCodec(targetWidth: (desc.width * scale).round(), targetHeight: (desc.height * scale).round());
    image = (await codec.getNextFrame()).image;
    codec.dispose();
    desc.dispose();
    probe.dispose();
    final ui.Rect from;
    if (crop == null) {
      final side = image.width < image.height ? image.width : image.height;
      from = ui.Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble());
    } else {
      // The part chosen, square, and inside the picture.
      final w = crop.width * image.width, h = crop.height * image.height;
      final side = (w < h ? w : h).clamp(1.0, (image.width < image.height ? image.width : image.height).toDouble());
      final left = (crop.left * image.width).clamp(0.0, image.width - side), top = (crop.top * image.height).clamp(0.0, image.height - side);
      from = ui.Rect.fromLTWH(left, top, side, side);
    }
    for (final size in sizes) {
      if (!larger && size > from.width + 0.5) continue;
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, from, ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
      final square = await recorder.endRecording().toImage(size, size);
      final rgba = await square.toByteData(format: ui.ImageByteFormat.rawRgba);
      square.dispose();
      if (rgba == null) continue;
      final pixels = img.Image.fromBytes(width: size, height: size, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
      for (final q in qualities) {
        final b64 = base64.encode(img.encodeJpg(pixels, quality: q, chroma: img.JpegChroma.yuv420));
        if (b64.length <= most) return b64;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

/// [bytes] (any picture Flutter decodes) as a profile's banner picture (GMFB-34): a band [ProfilePictures.bannerShape]
/// wide to one high, as base64 JPEG, at the largest of a few widths and qualities that fits [most] characters
/// ([ProfilePictures.bannerMost] where none is given; less where the profile's packet has less room). Null where it
/// can't be read or none fits.
///
/// [crop] is the band of it to keep, as shares of its width and height (lib/ui/picture_crop.dart, with its wide
/// window); the middle band where none is given.
Future<String?> bannerPictureOf(Uint8List bytes, {ui.Rect? crop, int most = ProfilePictures.bannerMost}) async {
  const shape = ProfilePictures.bannerShape;
  const widths = [ProfilePictures.bannerWide, 420, 360, 300, 240, 192];
  ui.Image? image;
  try {
    // Decoded near the size wanted, by the platform, as a profile picture is ([_square]).
    final probe = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(probe);
    final across = crop == null ? desc.width.toDouble() : (crop.width * desc.width).clamp(1.0, desc.width.toDouble());
    final scale = across > widths.first * 2 ? widths.first * 2 / across : 1.0;
    final codec = await desc.instantiateCodec(targetWidth: (desc.width * scale).round().clamp(1, desc.width), targetHeight: (desc.height * scale).round().clamp(1, desc.height));
    image = (await codec.getNextFrame()).image;
    codec.dispose();
    desc.dispose();
    probe.dispose();
    final iw = image.width.toDouble(), ih = image.height.toDouble();
    // The part chosen (the whole picture where none was), then the widest band of the shape inside it, about its middle.
    final part = crop == null ? ui.Rect.fromLTWH(0, 0, iw, ih) : ui.Rect.fromLTWH(crop.left * iw, crop.top * ih, crop.width * iw, crop.height * ih).intersect(ui.Rect.fromLTWH(0, 0, iw, ih));
    if (part.width < 1 || part.height < 1) return null;
    final w = part.width / part.height > shape ? part.height * shape : part.width, h = w / shape;
    final from = ui.Rect.fromLTWH(part.left + (part.width - w) / 2, part.top + (part.height - h) / 2, w, h);
    for (final width in widths) {
      final height = (width / shape).round();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, from, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
      final band = await recorder.endRecording().toImage(width, height);
      final rgba = await band.toByteData(format: ui.ImageByteFormat.rawRgba);
      band.dispose();
      if (rgba == null) continue;
      final pixels = img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
      for (final q in const [80, 68, 56]) {
        final b64 = base64.encode(img.encodeJpg(pixels, quality: q, chroma: img.JpegChroma.yuv420));
        if (b64.length <= most) return b64;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

// --- a circle's picture and banner (lib/ui/circles/circle_picture.dart) ----------------------------------------------
//
// Matt, 2026-11-27: "uploading the pictures for banners and the circle profile picture should use a cropping /
// zooming tool and upload at full resolution, right now they're super low resolution". Both were made a PNG small
// enough for the circle's manifest, and a PNG of anything with detail in it is large: a photo's banner came out 150
// pixels across and its picture 72. Each is now two things: a stand-in for the manifest, a JPEG (several times the
// pixels in the same room), and the part chosen cut at the picture's own resolution, which goes up as a file.

/// How large [bytes] is as a picture, in its own pixels; null where this device can't read it as one.
Future<ui.Size?> pictureSizeOf(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    final size = ui.Size(desc.width.toDouble(), desc.height.toDouble());
    desc.dispose();
    buffer.dispose();
    return size.isEmpty ? null : size;
  } catch (_) {
    return null;
  }
}

/// The part of a picture [w] by [h] that is kept: [crop] of it (shares of its width and height; all of it where
/// null), then the widest band [shape] wide to one high inside that, about its middle.
ui.Rect _kept(double w, double h, ui.Rect? crop, double shape) {
  final all = ui.Rect.fromLTWH(0, 0, w, h);
  final part = crop == null ? all : ui.Rect.fromLTWH(crop.left * w, crop.top * h, crop.width * w, crop.height * h).intersect(all);
  if (part.width < 1 || part.height < 1) return ui.Rect.zero;
  final bw = part.width / part.height > shape ? part.height * shape : part.width, bh = bw / shape;
  return ui.Rect.fromLTWH(part.left + (part.width - bw) / 2, part.top + (part.height - bh) / 2, bw, bh);
}

/// [bytes] decoded so that the part kept ([crop], [shape]) is about [across] pixels wide, and no larger than it is:
/// by the platform, which reads a phone's twelve million pixels at the size asked for.
Future<ui.Image> _decodedFor(Uint8List bytes, ui.Rect? crop, double shape, double across) async {
  final probe = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(probe);
  try {
    final kept = _kept(desc.width.toDouble(), desc.height.toDouble(), crop, shape);
    final scale = kept.width > across ? across / kept.width : 1.0;
    final codec = await desc.instantiateCodec(targetWidth: (desc.width * scale).round().clamp(1, desc.width), targetHeight: (desc.height * scale).round().clamp(1, desc.height));
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    return image;
  } finally {
    desc.dispose();
    probe.dispose();
  }
}

/// Whether any of [rgba]'s pixels can be seen through: a logo on no ground, which a JPEG would put on black.
bool _seeThrough(ByteData rgba) {
  for (var i = 3; i < rgba.lengthInBytes; i += 4) {
    if (rgba.getUint8(i) < 250) return true;
  }
  return false;
}

/// [bytes] (any picture this device reads) as a stand-in for a circle's manifest: the part chosen, [shape] wide to one
/// high, as base64 of at most [most] characters, at the largest of [widths] (pixels across, largest first) that fits.
/// A JPEG, at the best of [qualities] that fits; a PNG where the part kept can be seen through, so a logo keeps its
/// ground. Never made larger than the part kept is. Null where it can't be read or nothing fits.
Future<String?> pictureStandIn(Uint8List bytes, {ui.Rect? crop, required double shape, required List<int> widths, List<int> qualities = const [84, 74, 64, 54], required int most}) async {
  ui.Image? image;
  try {
    image = await _decodedFor(bytes, crop, shape, widths.first * 2.0);
    final from = _kept(image.width.toDouble(), image.height.toDouble(), crop, shape);
    if (from.isEmpty) return null;
    // The sizes to try: the part's own where it is smaller than the largest of [widths] (a small logo is sent as it
    // is, never blown up), then each of [widths] it is at least as large as.
    final own = from.width.round().clamp(1, widths.first);
    final sizes = [if (own < widths.first) own, for (final w in widths) if (w < own || (w == own && own == widths.first)) w];
    for (final width in sizes) {
      final height = (width / shape).round().clamp(1, width);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, from, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
      final made = await recorder.endRecording().toImage(width, height);
      try {
        final rgba = await made.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) continue;
        if (_seeThrough(rgba)) {
          final png = await made.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) continue;
          final b64 = base64.encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
          if (b64.length <= most) return b64;
          continue;
        }
        final pixels = img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
        for (final q in qualities) {
          final b64 = base64.encode(img.encodeJpg(pixels, quality: q, chroma: img.JpegChroma.yuv420));
          if (b64.length <= most) return b64;
        }
      } finally {
        made.dispose();
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

/// The part of a picture chosen, cut out of it at the picture's own resolution: what goes up as a circle's banner or
/// picture in full. [kind] is its file's ending: `jpg`, or `png` where it can be seen through.
class CutPicture {
  const CutPicture({required this.bytes, required this.kind, required this.width, required this.height});
  final Uint8List bytes;
  final String kind;
  final int width, height;
}

/// [bytes] cut to the part chosen ([crop], then the widest band [shape] wide to one high in it): every pixel the
/// picture has there, and nothing made up, so never larger than it is. A picture larger than [mostAcross] pixels
/// across the part is brought down to that (a phone's 12 million pixels as a banner 4000 across is more than any
/// screen shows). A JPEG of quality [quality]; a PNG where it can be seen through. Null where it can't be read.
Future<CutPicture?> cutPictureOf(Uint8List bytes, {ui.Rect? crop, required double shape, required int mostAcross, int quality = 90}) async {
  ui.Image? image;
  try {
    image = await _decodedFor(bytes, crop, shape, mostAcross.toDouble());
    final from = _kept(image.width.toDouble(), image.height.toDouble(), crop, shape);
    if (from.isEmpty) return null;
    final width = from.width.round().clamp(1, mostAcross), height = (width / shape).round().clamp(1, width);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(image, from, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
    final made = await recorder.endRecording().toImage(width, height);
    try {
      final rgba = await made.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      if (_seeThrough(rgba)) {
        final png = await made.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) return null;
        return CutPicture(bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes), kind: 'png', width: width, height: height);
      }
      // Off the page's own thread: a banner 3840 across is five million pixels to squeeze.
      final jpg = await compute(_jpegOf, (rgba: rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes), width: width, height: height, quality: quality));
      return CutPicture(bytes: jpg, kind: 'jpg', width: width, height: height);
    } finally {
      made.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

Uint8List _jpegOf(({Uint8List rgba, int width, int height, int quality}) of) =>
    img.encodeJpg(img.Image.fromBytes(width: of.width, height: of.height, bytes: of.rgba.buffer, bytesOffset: of.rgba.offsetInBytes, numChannels: 4, order: img.ChannelOrder.rgba), quality: of.quality);
