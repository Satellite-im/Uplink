import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Pictures unpacked no larger than they are drawn, and not unpacked again for nothing
/// (docs/performance-audit.md, finding 6): a face 40 points across was the whole photograph unpacked, and a picture
/// kept as base64 was a new run of bytes at every build, which the image cache takes for a new picture.

/// How wide to unpack a picture drawn [size] points across and cropped to fill a square (a face): its pixels on this
/// screen, and as many again, so a wide photograph cropped to its middle is still sharp. Never made larger than it is.
int faceDecodeWidth(BuildContext context, double size) => (size * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2) * 2).ceil().clamp(1, 4096);

/// How wide to unpack a picture that fills [width] points (a message's photograph, a banner); the screen's own width
/// where none is given (a chat's background).
int fillDecodeWidth(BuildContext context, [double? width]) {
  final w = width ?? MediaQuery.maybeSizeOf(context)?.width ?? 1280;
  return (w * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 2)).ceil().clamp(1, 8192);
}

/// The bytes a base64 picture is, the same run of bytes each time it is asked for (the newest [_most] kept): what the
/// image cache knows a picture by. Null where it is not base64.
Uint8List? pictureBytes(String base64) {
  final had = _pictures.remove(base64);
  if (had != null) {
    _pictures[base64] = had;
    return had;
  }
  final Uint8List bytes;
  try {
    bytes = base64Decode(base64);
  } catch (_) {
    return null;
  }
  _pictures[base64] = bytes;
  if (_pictures.length > _most) _pictures.remove(_pictures.keys.first);
  return bytes;
}

const _most = 96;
final LinkedHashMap<String, Uint8List> _pictures = LinkedHashMap();

/// A file's bytes, read once for as long as the file is as it was (its size and when it changed): for a picture
/// shown from its bytes on the first frame, which was read from the disk again at every build. The newest few kept.
Uint8List? fileBytes(String path) {
  try {
    final stat = File(path).statSync();
    final key = '$path|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    final had = _files[key];
    if (had != null) return had;
    final bytes = File(path).readAsBytesSync();
    _files[key] = bytes;
    if (_files.length > 4) _files.remove(_files.keys.first);
    return bytes;
  } catch (_) {
    return null;
  }
}

final LinkedHashMap<String, Uint8List> _files = LinkedHashMap();
