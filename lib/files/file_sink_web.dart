import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_sink.dart';

/// Files held in the tab as Blobs (lib/files/file_sink.dart), each under a `blob:` address for the page's own video
/// element and its download link; gone when the tab closes, or once let go.
class HeldFiles {
  HeldFiles._();
  static final Map<String, web.Blob> _held = {};

  static HeldSink sink() => _BlobSink();

  /// The bytes held under [url] (a picture shown in the page: read back from the Blob, not fetched, which the page's
  /// policy would refuse); null where it was let go.
  static Future<Uint8List?> bytes(String url, {int? most}) async {
    final b = _held[url];
    if (b == null) return null;
    // Only what is to be shown read out of the Blob: the first [most] bytes of words, never the whole.
    final part = most == null || b.size <= most ? b : b.slice(0, most);
    return (await part.arrayBuffer().toDart).toDart.asUint8List();
  }

  static void release(String url) {
    if (_held.remove(url) != null) web.URL.revokeObjectURL(url);
  }

  static int get count => _held.length;
}

class _BlobSink implements HeldSink {
  // Each chunk a Blob of its own as it comes, so the bytes leave the app's memory for the browser's at once.
  final List<web.BlobPart> _parts = [];
  @override
  void add(Uint8List plain) => _parts.add(web.Blob([plain.toJS].toJS));
  @override
  String finish(String mime) {
    final blob = web.Blob(_parts.toJS, web.BlobPropertyBag(type: heldType(mime)));
    final url = web.URL.createObjectURL(blob);
    HeldFiles._held[url] = blob;
    return url;
  }

  @override
  void abort() => _parts.clear();
}
