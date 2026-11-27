import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'file_source.dart';

/// A browser's `File` as a [FileSource]: read with `slice`, a piece at a time, so a big file is never in the page's
/// memory whole. A file changed or moved on the computer after it was picked can't be read any more (the browser
/// says NotReadableError): the upload stops saying so, as the app's does for a file that changed.
class BlobSource implements FileSource {
  BlobSource(this._file);
  final web.File _file;
  @override
  String get name => _file.name;
  @override
  int get size => _file.size;
  @override
  String get mime => _file.type;
  @override
  int get modified => _file.lastModified;
  @override
  Future<Uint8List> read(int from, int length) async => (await _file.slice(from, from + length).arrayBuffer().toDart).toDart.asUint8List();
}

/// The page's picker, the files dropped on it, and its downloads (lib/files/browser_files.dart).
class BrowserFiles {
  BrowserFiles._();

  /// Files chosen with the browser's own picker; none where it was put away.
  static Future<List<FileSource>> pick() {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..multiple = true
      ..style.display = 'none';
    final done = Completer<List<FileSource>>();
    void settle() {
      if (done.isCompleted) return;
      final files = input.files;
      done.complete([for (var i = 0; i < (files?.length ?? 0); i++) BlobSource(files!.item(i)!)]);
      input.remove();
    }

    input.addEventListener('change', ((web.Event _) => settle()).toJS);
    // Put away without choosing (the browsers that say so).
    input.addEventListener('cancel', ((web.Event _) => settle()).toJS);
    web.document.body?.append(input);
    input.click();
    return done.future;
  }

  static final _dropped = StreamController<List<FileSource>>.broadcast();

  /// True while files are dragged over the page, with a Files space showing.
  static final ValueNotifier<bool> over = ValueNotifier(false);

  /// Files dropped on the page while a Files space is showing.
  static Stream<List<FileSource>> get dropped => _dropped.stream;

  static int _targets = 0;
  static JSFunction? _onOver, _onLeave, _onDrop;

  /// Whether what is dragged is files (not words or a link from the page).
  static bool _files(web.DragEvent e) {
    final types = e.dataTransfer?.types.toDart ?? const <JSString>[];
    return types.any((t) => t.toDart == 'Files');
  }

  /// A Files space on the screen takes drops ([on]), and stops when it goes. While none is showing, the page takes no
  /// drop at all, so a file let go over it is the browser's to deal with as ever.
  static void dropTarget(bool on) {
    _targets = (_targets + (on ? 1 : -1)).clamp(0, 1 << 20);
    final doc = web.document;
    if (_targets > 0 && _onDrop == null) {
      _onOver = ((web.DragEvent e) {
        if (!_files(e)) return;
        // Taken here: never opened by the browser, in this tab, as it does a file let go over a page.
        e.preventDefault();
        e.dataTransfer?.dropEffect = 'copy';
        over.value = true;
      }).toJS;
      _onLeave = ((web.DragEvent e) {
        // Left the page itself (not one of its parts for another).
        if (e.relatedTarget == null) over.value = false;
      }).toJS;
      _onDrop = ((web.DragEvent e) {
        if (!_files(e)) return;
        e.preventDefault();
        over.value = false;
        final files = e.dataTransfer?.files;
        final got = [for (var i = 0; i < (files?.length ?? 0); i++) BlobSource(files!.item(i)!)];
        if (got.isNotEmpty) _dropped.add(got);
      }).toJS;
      doc.addEventListener('dragover', _onOver);
      doc.addEventListener('dragenter', _onOver);
      doc.addEventListener('dragleave', _onLeave);
      doc.addEventListener('drop', _onDrop);
    } else if (_targets == 0 && _onDrop != null) {
      doc.removeEventListener('dragover', _onOver);
      doc.removeEventListener('dragenter', _onOver);
      doc.removeEventListener('dragleave', _onLeave);
      doc.removeEventListener('drop', _onDrop);
      _onOver = _onLeave = _onDrop = null;
      over.value = false;
    }
  }

  /// Saves the file held at [url] (lib/files/file_sink.dart) to the browser's downloads under [name]: a link with
  /// `download`, so it is saved and never opened in a tab of the app's address.
  static void save(String url, String name) {
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = name.isEmpty ? 'file' : name
      ..rel = 'noopener'
      ..style.display = 'none';
    web.document.body?.append(a);
    a.click();
    a.remove();
  }
}
