/// Files a plugin's developer brings to the app (Matt, 2026-11-20: "a developer setting for users to be able to manually
/// upload plugins for development testing", and "a submission area with a form to accept an icon, description, plugin
/// tags, etc"): a .ghostplugin chosen with the device's own picker, a picture pasted on a computer, a plugin's icon made
/// from any picture, and a screenshot made again as a plain PNG.
///
/// A screenshot is always drawn afresh and encoded here, never passed through: no JPEG's EXIF (where it was taken), no
/// text chunk, nothing but its pixels ever reaches gogho.st, where everyone can see it once it is listed.
library;

import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show FilterQuality, Paint, Rect;

import '../desktop/platform.dart' show MacPlatform;
import '../files/file_platform.dart';
import '../plugins/pack/pack.dart' show PackLimits, cleanPng, pngProblem;
import '../sms.dart';

/// A plugin file as chosen: its name, its bytes (at most a package's limit and one more, so a larger one is said to be
/// too large rather than cut), and its path where it can be read again (a computer's; Android's picked copies are not
/// kept).
typedef PickedPlugin = ({String name, Uint8List bytes, String? path});

/// Where a plugin file can be chosen: Android's picker, a Mac's Open panel and Windows' Open dialog (GMFB-7: Windows
/// had none, so a downloaded plugin file could not be loaded there).
bool get canPickPluginFile => PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isWindows;

/// A .ghostplugin chosen with the device's own picker; null where none was.
Future<PickedPlugin?> pickPluginFile() async {
  if (PlatformInfo.isAndroid) {
    final picked = await Sms.instance.pickFiles();
    if (picked.isEmpty) return null;
    final copy = await Sms.instance.cacheCopy(picked.first);
    final file = File(copy);
    try {
      return (name: _nameOf(picked.first, copy), bytes: await _readAtMost(file, PackLimits.packageBytes + 1), path: null);
    } finally {
      // The picker's copy is the app's to delete: the bytes are what was loaded.
      if (copy != picked.first) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }
  if (PlatformInfo.isMacOS || PlatformInfo.isWindows) {
    final paths = await FilePlatform.pickPaths(most: 1);
    if (paths.isEmpty) return null;
    final path = paths.first;
    return (name: path.split(PlatformInfo.pathSeparator).last, bytes: await _readAtMost(File(path), PackLimits.packageBytes + 1), path: path);
  }
  return null;
}

/// The picked file's own name: the last part of what was [picked] (an address on Android, decoded), else of the
/// [copy] that was read.
String _nameOf(String picked, String copy) {
  final last = Uri.tryParse(picked)?.pathSegments.lastOrNull;
  if (last != null && last.isNotEmpty) {
    try {
      return Uri.decodeComponent(last).split('/').last;
    } catch (_) {}
  }
  return copy.split('/').last;
}

/// The first [most] bytes of [file].
Future<Uint8List> _readAtMost(File file, int most) async {
  final out = BytesBuilder(copy: false);
  await for (final piece in file.openRead(0, most)) {
    out.add(piece);
  }
  return out.takeBytes();
}

/// A picture on a computer's clipboard (MacPlatform.pasteImage, which the Mac and Windows both have): its bytes, or null
/// where there is none or this is a phone.
Future<Uint8List?> pastePicture() async {
  if (!Sms.computer) return null;
  final path = await MacPlatform.pasteImage();
  if (path == null) return null;
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}

/// A plugin's icon made from any picture: its middle square drawn at 256 px (else 192, 160, 128, 96, 64), made a plain
/// PNG (cleanPng), the first within the format's limits (A.5), as base64. Null where it isn't a picture.
Future<String?> pluginIconOf(Uint8List bytes) async {
  ui.Image? image;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final side = image.width < image.height ? image.width : image.height;
    final from = Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble());
    for (final size in const [256, 192, 160, 128, 96, 64]) {
      final png = await _drawn(image, from, size, size);
      if (png == null) continue;
      final b64 = base64Encode(png);
      if (png.length <= PackLimits.iconBytes && b64.length <= PackLimits.iconChars && pngProblem(png, min: PackLimits.iconMin, max: PackLimits.iconMax, square: true) == null) return b64;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

/// [from] of [image] drawn at [w] by [h] and encoded as a PNG of pixels alone.
Future<Uint8List?> _drawn(ui.Image image, Rect from, int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(image, from, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.medium);
  final picture = recorder.endRecording();
  final small = await picture.toImage(w, h);
  picture.dispose();
  try {
    final data = await small.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return cleanPng(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } finally {
    small.dispose();
  }
}

/// A screenshot for a submission: always a new PNG made from [bytes]' pixels, never the bytes passed through. Its size
/// is read first, and it is decoded straight at a long side of at most 2,400 px (a huge picture is never decoded whole),
/// drawn, encoded and made plain (cleanPng), then made smaller (1,800, 1,400, 1,080, 800) until it is at most 1 MiB.
/// Null where none fits, or it isn't a picture.
Future<Uint8List?> shrinkScreenshot(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w <= 0 || h <= 0) return null;
    final long = w > h ? w : h;
    var tried = 0;
    for (final most in const [2400, 1800, 1400, 1080, 800]) {
      final scale = long > most ? most / long : 1.0;
      final tw = (w * scale).round(), th = (h * scale).round();
      if (tw < PackLimits.shotMin || th < PackLimits.shotMin) return null;
      // The same size as the last try would come out the same.
      if (tw == tried) continue;
      tried = tw;
      final codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        final png = await _drawn(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), image.width, image.height);
        if (png != null && png.length <= PackLimits.shotBytes && pngProblem(png, min: PackLimits.shotMin, max: PackLimits.shotMax) == null) return png;
      } finally {
        image.dispose();
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
