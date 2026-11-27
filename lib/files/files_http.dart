/// How [FilesApi] (lib/files/files_api.dart) puts a request to the relay's files routes and reads the answer: the one
/// thing about the files layer that differs between the app and a page in a browser (docs/OPEN_NETWORK.md, part 6).
/// Everything the relay is told and how its answer is read (the paths, the token, the signing, the errors, a Range a
/// server ignored) stays in FilesApi, for both.
///
/// - On a phone or a computer, dart:io's HttpClient (files_http_io.dart), as it always was.
/// - In a browser, the page's own `fetch`, its answer read as it streams (files_http_web.dart), through
///   files_http_fetch.dart, plain Dart a test drives with a stand-in fetch.
library;

import 'dart:async';

export 'files_http_io.dart' if (dart.library.js_interop) 'files_http_web.dart';

/// An answer from the relay: its status, and its body as it comes.
typedef FilesAnswer = ({int status, Stream<List<int>> body});

/// What [FilesApi] asks of HTTP: [send] a request and hand back the answer once its status is known, the body still
/// to read. Every way of not reaching the relay comes out as a FilesError of status 0.
abstract class FilesHttp {
  /// [method] to [url] with [headers] and, where there is one, [body] (its length said by the transport itself).
  Future<FilesAnswer> send(String method, Uri url, Map<String, String> headers, List<int>? body);

  /// Lets its connections go: at once, whatever is under way ([force]), or once what is under way is done.
  void close({bool force = false});
}
