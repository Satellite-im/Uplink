import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'files_http.dart';
import 'files_http_fetch.dart';

/// The relay's files routes from a page in a browser (lib/files/files_http.dart): the page's own `fetch`, as
/// lib/web/http_web.dart sends a report or feedback: never with the page's cookies or its address as the referrer, no
/// redirect followed, nothing kept in the browser's cache. Across addresses (app.gogho.st to gogho.st) only where the
/// relay lets this page read the answer (GHOST_APP_ORIGIN, relay/lib/relay.dart) and the page's policy names it.
///
/// The answer's body is read as it comes, a piece at a time from its stream, never as one buffer: a file coming down
/// is opened and handed on chunk by chunk (FilesStore), as the app does from its socket. Stopping a read cancels the
/// stream, which ends that request.
Future<FilesAnswer> pageFetch(String method, Uri url, Map<String, String> headers, Uint8List? body) async {
  final sent = web.Headers();
  headers.forEach((name, value) => sent.set(name, value));
  final res = await web.window
      .fetch(
        url.toString().toJS,
        web.RequestInit(
          method: method,
          headers: sent,
          body: body?.toJS,
          mode: 'cors',
          credentials: 'omit',
          cache: 'no-store',
          redirect: 'error',
          referrerPolicy: 'no-referrer',
        ),
      )
      .toDart;
  final stream = res.body;
  if (stream == null) return (status: res.status, body: const Stream<List<int>>.empty());
  final reader = stream.getReader() as web.ReadableStreamDefaultReader;
  late final StreamController<List<int>> out;
  var reading = false, stopped = false;
  Future<void> pump() async {
    if (reading) return;
    reading = true;
    try {
      while (!stopped && !out.isPaused) {
        final r = await reader.read().toDart;
        if (r.done) {
          await out.close();
          return;
        }
        final v = r.value;
        if (v != null) out.add((v as JSUint8Array).toDart);
      }
    } catch (e) {
      if (!stopped) {
        out.addError(e);
        await out.close();
      }
    } finally {
      reading = false;
    }
  }

  out = StreamController<List<int>>(
    onListen: () => unawaited(pump()),
    onResume: () => unawaited(pump()),
    onCancel: () {
      stopped = true;
      try {
        unawaited(reader.cancel().toDart.then((_) {}, onError: (_) {}));
      } catch (_) {}
    },
  );
  return (status: res.status, body: out.stream);
}

/// The way to the relay in a page: its fetch.
FilesHttp defaultFilesHttp() => FetchFilesHttp(pageFetch);
