/// The API over HTTP, served by the app itself (lib/api/api.dart), while Settings › API has it on. On this device
/// alone by default: from a computer over USB with `adb forward tcp:8765 tcp:8765`, then `http://127.0.0.1:8765`.
/// "Allow from Wi-Fi" serves it on the phone's own address on the network too. Every request carries the token:
/// `Authorization: Bearer <token>`.
///
///     GET  /api               everything the API says of itself (api.describe)
///     GET  /api/<method>      one method's documentation
///     POST /api/<method>      calls it, its parameters a JSON object in the body
///     POST /api               {"method": "...", "params": {...}, "id": ...}: the same, as the relay link sends it
///
/// Answers are JSON: `{"ok": true, "result": ...}` or `{"ok": false, "error": {"code", "message"}}`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../desktop/link/crypto.dart' show DeskCrypto;
import 'api.dart';

/// The HTTP server itself: started and stopped by [apply], as the choices in Settings › API change.
class ApiServer {
  ApiServer._();
  static final ApiServer instance = ApiServer._();

  static const defaultPort = 8765;

  HttpServer? _server;

  /// What the server now running was started with (Wi-Fi or not, and the port): started again when that changes.
  String? _servingKey;

  /// Where it is served ("127.0.0.1:8765", or the phone's addresses on the network too), null while off; or why not.
  final ValueNotifier<List<String>?> addresses = ValueNotifier(null);
  final ValueNotifier<String?> problem = ValueNotifier(null);

  // The person's choices: served at all (`api_local`), on the network too (`api_lan`), and on which port.
  static bool on(AppState app) => app.flag('api_local', fallback: false);
  static bool lan(AppState app) => app.flag('api_lan', fallback: false);
  static int port(AppState app) => int.tryParse(app.choice('api_port', '')) ?? defaultPort;

  /// The token requests carry, made the first time it is asked for.
  static String token(AppState app) {
    final t = app.choice('api_token', '');
    if (t.length >= 32) return t;
    final made = DeskCrypto.hex(DeskCrypto.randomBytes(24));
    app.set('api_token', made);
    return made;
  }

  /// Whether [a] is [b], taking as long wherever they first differ: how long a wrong token took to refuse says nothing
  /// of how much of it was right (it matters with "Allow from Wi-Fi" on, where anyone on the network may try).
  @visibleForTesting
  static bool sameText(String a, String b) {
    final x = utf8.encode(a), y = utf8.encode(b);
    var differs = x.length ^ y.length;
    for (var i = 0; i < y.length; i++) {
      differs |= (i < x.length ? x[i] : 0) ^ y[i];
    }
    return differs == 0;
  }

  /// A new token; whoever had the old one is shut out.
  static void newToken(AppState app) => app.set('api_token', DeskCrypto.hex(DeskCrypto.randomBytes(24)));

  /// Serving as the person's choices say: started, stopped, or started again where the port or Wi-Fi changed.
  Future<void> apply(AppState app) async {
    final want = on(app);
    final key = '${lan(app)}:${port(app)}';
    if (!want) {
      await stop();
      return;
    }
    if (_server != null && _servingKey == key) return;
    await stop();
    try {
      final server = await HttpServer.bind(lan(app) ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, port(app), shared: true);
      _server = server;
      _servingKey = key;
      problem.value = null;
      server.listen((r) => unawaited(_handle(app, r)), onError: (_) {});
      final list = ['127.0.0.1:${server.port}'];
      if (lan(app)) {
        try {
          for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
            for (final a in i.addresses) {
              if (!a.isLoopback) list.add('${a.address}:${server.port}');
            }
          }
        } catch (_) {}
      }
      addresses.value = list;
    } catch (e) {
      addresses.value = null;
      problem.value = 'Couldn\'t serve the API on port ${port(app)}: $e';
    }
  }

  /// Stops serving, closing the connections that are open.
  Future<void> stop() async {
    final s = _server;
    _server = null;
    _servingKey = null;
    addresses.value = null;
    await s?.close(force: true);
  }

  /// One request: the token checked, then the documentation (GET) or a call (POST), answered as JSON with a status
  /// to match.
  Future<void> _handle(AppState app, HttpRequest r) async {
    final res = r.response;
    Future<void> send(int status, Object? body) async {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
      await res.close();
    }

    try {
      final path = r.uri.path;
      if (path == '/' || path.isEmpty) {
        res.headers.contentType = ContentType.text;
        res.write('Uplink API. GET /api with "Authorization: Bearer <token>" (Settings › API) lists every method.\n');
        await res.close();
        return;
      }
      final auth = r.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (!sameText(auth, 'Bearer ${token(app)}')) {
        await send(401, {'ok': false, 'error': const ApiError('unauthorized', 'The token (Settings › API) is needed: "Authorization: Bearer <token>".').toJson()});
        return;
      }
      if (!path.startsWith('/api')) {
        await send(404, {'ok': false, 'error': const ApiError('not_found', 'Everything is under /api.').toJson()});
        return;
      }
      final name = path == '/api' || path == '/api/' ? null : Uri.decodeComponent(path.substring(5));
      if (r.method == 'GET') {
        if (name == null) {
          await send(200, {'ok': true, 'result': Api.instance.describe()});
          return;
        }
        final m = Api.instance.method(name);
        await send(m == null ? 404 : 200, m == null ? {'ok': false, 'error': ApiError('not_found', 'No method called "$name".').toJson()} : {'ok': true, 'result': m.toJson()});
        return;
      }
      if (r.method != 'POST') {
        await send(405, {'ok': false, 'error': const ApiError('bad_params', 'GET to read the documentation, POST to call.').toJson()});
        return;
      }
      final text = await utf8.decoder.bind(r).join();
      Object? body;
      try {
        body = text.trim().isEmpty ? const <String, Object?>{} : jsonDecode(text);
      } catch (_) {
        await send(400, {'ok': false, 'error': const ApiError('bad_params', 'The body is not JSON.').toJson()});
        return;
      }
      if (body is! Map) {
        await send(400, {'ok': false, 'error': const ApiError('bad_params', 'The body should be a JSON object.').toJson()});
        return;
      }
      final request = name == null ? body.cast<String, Object?>() : {'method': name, 'params': body};
      final answer = await Api.instance.answer(request, via: 'http');
      final error = answer['error'] as Map?;
      await send(answer['ok'] == true ? 200 : (error?['code'] == 'not_found' ? 404 : (error?['code'] == 'bad_params' ? 400 : 500)), answer);
    } catch (e) {
      try {
        await send(500, {'ok': false, 'error': ApiError('failed', '$e').toJson()});
      } catch (_) {}
    }
  }
}
