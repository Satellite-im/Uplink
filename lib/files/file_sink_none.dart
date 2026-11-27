import 'dart:typed_data';

import 'file_sink.dart';

/// Files held in memory by address (lib/files/file_sink.dart): what a test of the browser's way reads back.
class HeldFiles {
  HeldFiles._();
  static final Map<String, Uint8List> _held = {};
  static int _n = 0;

  static HeldSink sink() => _MemorySink();

  /// The bytes held under [url] (its first [most], where given); null where it was let go.
  static Future<Uint8List?> bytes(String url, {int? most}) async {
    final b = _held[url];
    if (b == null || most == null || b.length <= most) return b;
    return Uint8List.sublistView(b, 0, most);
  }

  /// Lets [url] go.
  static void release(String url) => _held.remove(url);

  /// How many are held, for a test.
  static int get count => _held.length;
}

class _MemorySink implements HeldSink {
  final _b = BytesBuilder(copy: false);
  @override
  void add(Uint8List plain) => _b.add(plain);
  @override
  String finish(String mime) {
    final url = 'held:${HeldFiles._n++}';
    HeldFiles._held[url] = _b.takeBytes();
    return url;
  }

  @override
  void abort() => _b.clear();
}
