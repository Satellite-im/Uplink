import 'dart:async';
import 'dart:io';

import 'files_api.dart' show FilesError;
import 'files_http.dart';

/// The app's way to the relay's files routes: dart:io's HttpClient (lib/files/files_http.dart). What it always was,
/// moved out of FilesApi so a browser can put its own `fetch` in its place.
class IoFilesHttp implements FilesHttp {
  IoFilesHttp([HttpClient? client]) : _http = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));
  final HttpClient _http;

  @override
  Future<FilesAnswer> send(String method, Uri url, Map<String, String> headers, List<int>? body) async {
    try {
      final req = await _http.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      } else if (method != 'GET') {
        req.contentLength = 0;
      }
      final res = await req.close();
      // A connection cut while the answer is read is the relay out of reach too, as it was before the split (the review
      // of web-files, F1): an upload then waits and tries again rather than standing still.
      return (status: res.statusCode, body: res.transform<List<int>>(StreamTransformer.fromHandlers(handleError: (e, st, sink) => sink.addError(_offline(e), st))));
    } on SocketException catch (e) {
      throw FilesError(0, 'Can\'t reach the files server (${e.osError?.message ?? e.message}).');
    } on HttpException catch (e) {
      throw FilesError(0, 'Can\'t reach the files server (${e.message}).');
    } on TimeoutException {
      throw FilesError(0, 'The files server didn\'t answer.');
    } on HandshakeException {
      throw FilesError(0, 'Can\'t reach the files server securely.');
    }
  }

  /// What went wrong reaching the relay, as FilesError's status 0 where it is the connection's.
  static Object _offline(Object e) => switch (e) {
        FilesError() => e,
        SocketException() => FilesError(0, 'Can\'t reach the files server (${e.osError?.message ?? e.message}).'),
        HttpException() => FilesError(0, 'Can\'t reach the files server (${e.message}).'),
        TimeoutException() => FilesError(0, 'The files server didn\'t answer.'),
        HandshakeException() => FilesError(0, 'Can\'t reach the files server securely.'),
        _ => e,
      };

  @override
  void close({bool force = false}) => _http.close(force: force);
}

/// The way to the relay here: dart:io's.
FilesHttp defaultFilesHttp() => IoFilesHttp();
