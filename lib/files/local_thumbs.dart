/// Small pictures made here for files in a Files space that came without one (Matt, 2026-11-18: "Please make the files
/// have previews in the files page in the app like gifs images and videos"): a picture or GIF sent from a device that
/// made none, or bigger than one is made for at upload, and every video sent before videos had one. Once the file's
/// own copy is on this device, its preview is made from it (a picture's first frame, a video's frame from its first
/// minute) and kept beside that copy, so it is made once. Never sent anywhere: the others make their own.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'file_kinds.dart';
import 'files_model.dart';
import 'files_store.dart';

/// The previews made on this device, and the queue of those still to make; listeners are told as each is made.
class LocalThumbs extends ChangeNotifier {
  LocalThumbs._();
  static final instance = LocalThumbs._();

  /// Each file's made preview by its id; null where one was tried and none could be made.
  final Map<String, Uint8List?> _made = {};

  // The files waiting their turn, the ids already asked for, and how many are being made now.
  final List<SpaceFile> _waiting = [];
  final Set<String> _asked = {};
  int _running = 0;

  /// [f]'s preview made here, where there is one; asks for it to be made (once) where its copy is here and it is a
  /// picture or a video. Told (notifyListeners) when one is made.
  Uint8List? of(SpaceFile f) {
    if (f.thumb != null) return f.thumb;
    if (_made.containsKey(f.id)) return _made[f.id];
    if (f.kind != FileKind.image && f.kind != FileKind.video) return null;
    if (f.kind == FileKind.image && f.size > 40 << 20) return null;
    if (_asked.add(f.id)) {
      final kept = _keptFile(f);
      if (kept != null && kept.existsSync()) {
        try {
          return _made[f.id] = kept.readAsBytesSync();
        } catch (_) {}
      }
      _waiting.add(f);
      _next();
    }
    return null;
  }

  /// Where [f]'s made preview is kept: beside its copy's folder, as its part file is.
  File? _keptFile(SpaceFile f) {
    try {
      final copy = File(FilesStore.instance.cachedPath(f));
      return File('${copy.parent.parent.path}/${f.id}.thumb.png');
    } catch (_) {
      return null;
    }
  }

  /// Two at a time, so a folder of videos does not start a player each at once.
  void _next() {
    while (_running < 2 && _waiting.isNotEmpty) {
      final f = _waiting.removeAt(0);
      final path = FilesStore.instance.cached(f);
      if (path == null) {
        // Not here yet: asked again the next time it is drawn.
        _asked.remove(f.id);
        continue;
      }
      _running++;
      FilesStore.thumbnailOfFile(path, f.kind).then((made) {
        _made[f.id] = made?.png;
        final kept = _keptFile(f);
        if (made != null && kept != null) {
          try {
            kept.writeAsBytesSync(made.png);
          } catch (_) {}
        }
        notifyListeners();
      }).whenComplete(() {
        _running--;
        _next();
      });
    }
  }

  /// For a test: everything forgotten.
  @visibleForTesting
  void reset() {
    _made.clear();
    _waiting.clear();
    _asked.clear();
    _running = 0;
  }
}
