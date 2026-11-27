import 'dart:typed_data';

/// Not in a browser: there the app's own clients (dart:io) send these, and this is never asked (lib/web/http.dart).
Future<({int status, Map<String, String> headers, Uint8List body})> pageHttp(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) =>
    Future.error(UnsupportedError('Only a page in a browser sends with fetch.'));
