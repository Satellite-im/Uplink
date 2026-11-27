import 'dart:async';
import 'dart:typed_data';

import 'files_api.dart' show FilesError;
import 'files_http.dart';

/// One request as a page's `fetch` makes it: the status once the headers are in, and the body as it streams. A
/// failure to reach the server at all (a page's fetch says only "TypeError: Failed to fetch", or the browser refused
/// it by the page's policy or CORS) is thrown, whatever it is.
typedef PageFetch = Future<FilesAnswer> Function(String method, Uri url, Map<String, String> headers, Uint8List? body);

/// The relay's files routes from a page in a browser (lib/files/files_http.dart): the page's own fetch
/// (files_http_web.dart hands the real one in; a test its own), with what a browser does differently from dart:io
/// taken care of here, in plain Dart.
///
/// - The length of what is sent is the browser's to say: a page may not set Content-Length (it is dropped).
/// - Nothing the fetch throws gets out as itself: it is a FilesError of status 0, the relay out of reach, as a
///   socket's error is in the app, so an upload waits and tries again as it does there. A body that stops part way
///   comes out of the stream as the same.
/// - [close] stops what is under way: the bodies still being read end with an error, and nothing new is sent.
class FetchFilesHttp implements FilesHttp {
  FetchFilesHttp(this._fetch);
  final PageFetch _fetch;
  bool _closed = false;
  final Set<StreamController<List<int>>> _open = {};

  @override
  Future<FilesAnswer> send(String method, Uri url, Map<String, String> headers, List<int>? body) async {
    if (_closed) throw FilesError(0, 'Stopped.');
    final sent = {
      for (final e in headers.entries)
        if (e.key.toLowerCase() != 'content-length') e.key: e.value,
    };
    final FilesAnswer got;
    try {
      got = await _fetch(method, url, sent, body == null ? null : (body is Uint8List ? body : Uint8List.fromList(body)));
    } on FilesError {
      rethrow;
    } catch (e) {
      throw FilesError(0, 'Can\'t reach the files server (${_said(e)}).');
    }
    // The body passed through, each error in it a FilesError of status 0, and ended with one where [close] came first.
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    out = StreamController<List<int>>(
      onListen: () {
        sub = got.body.listen(
          out.add,
          onError: (Object e) => out.addError(e is FilesError ? e : FilesError(0, 'Can\'t reach the files server (${_said(e)}).')),
          onDone: () {
            _open.remove(out);
            out.close();
          },
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        _open.remove(out);
        return sub?.cancel();
      },
    );
    _open.add(out);
    return (status: got.status, body: out.stream);
  }

  /// What went wrong, in a few words: the first line of it.
  static String _said(Object e) {
    final t = '$e'.split('\n').first;
    return t.length > 120 ? '${t.substring(0, 120)}…' : t;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (!force) return;
    for (final c in [..._open]) {
      c.addError(FilesError(0, 'Stopped.'));
      unawaited(c.close());
    }
    _open.clear();
  }
}
