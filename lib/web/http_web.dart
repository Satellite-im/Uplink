import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// [method] to [url] with [headers] and [body], from the page (lib/web/http.dart): never with the page's cookies or
/// its address as the referrer, no redirect followed, nothing kept in the browser's cache. Across addresses only where
/// the answer lets this page read it (CORS); a browser that doesn't, or no answer at all, is an error, as a socket's is
/// with dart:io. The answer is refused where it says it is longer than [most]; MarketApi checks what was read too.
Future<({int status, Map<String, String> headers, Uint8List body})> pageHttp(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
  final sent = web.Headers();
  headers.forEach((name, value) => sent.set(name, value));
  final res = await web.window
      .fetch(
        url.toString().toJS,
        web.RequestInit(
          method: method,
          headers: sent,
          body: body.isEmpty ? null : Uint8List.fromList(body).toJS,
          mode: 'cors',
          credentials: 'omit',
          cache: 'no-store',
          redirect: 'error',
          referrerPolicy: 'no-referrer',
        ),
      )
      .toDart;
  final said = int.tryParse(res.headers.get('content-length') ?? '');
  if (said != null && said > most) throw StateError('The answer is longer than $most bytes.');
  final bytes = (await res.arrayBuffer().toDart).toDart.asUint8List();
  // The two a caller reads; a page is shown only the headers an answer across addresses lets it see anyway.
  final got = <String, String>{
    for (final name in const ['content-type', 'etag']) name: ?res.headers.get(name),
  };
  return (status: res.status, headers: got, body: bytes);
}
