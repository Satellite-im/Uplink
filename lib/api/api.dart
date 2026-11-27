/// Uplink's API (Matt, 2026-11-17: "build an entire API that we can use to interact with every aspect of the
/// app frontend and backend and expose it all through a API section of the settings that shows up when developer mode
/// is enabled it should serve as a complete list of documentation for the API as well as test areas").
///
/// One registry of methods, each named `group.verb` (`conversations.list`), with its parameters, what it answers and
/// an example, and the code that does it. The same methods are called three ways, all off until turned on in
/// Settings › API: from that page's own test area; over HTTP from the phone itself (lib/api/server.dart: USB with
/// `adb forward`, or the Wi-Fi where allowed), with a token; and from anywhere through the relay server
/// (lib/api/remote.dart), sealed end to end with a key the relay never has. tool/ghost-api.mjs is a client for both.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One parameter of a method.
@immutable
class ApiParam {
  const ApiParam(this.name, this.type, this.doc, {this.required = false, this.example});

  final String name;

  /// string, int, bool, list, object.
  final String type;
  final String doc;
  final bool required;
  final Object? example;

  Map<String, Object?> toJson() => {'name': name, 'type': type, 'doc': doc, 'required': required, if (example != null) 'example': example};
}

/// A method of the API.
@immutable
class ApiMethod {
  const ApiMethod({required this.name, required this.summary, this.params = const [], this.returns = 'null', this.danger = false, this.example, required this.run});

  /// `group.verb`.
  final String name;
  final String summary;
  final List<ApiParam> params;

  /// What it answers, in words or as a shape.
  final String returns;

  /// It changes or removes something that cannot be put back by asking again (deletes, sends): Settings asks first.
  final bool danger;

  /// Parameters to try it with.
  final Map<String, Object?>? example;

  /// Does it: given the call's parameters, already checked against [params], gives its answer or throws.
  final Future<Object?> Function(Map<String, Object?> p) run;

  /// The part of [name] before the dot: what the methods are grouped by.
  String get group => name.contains('.') ? name.substring(0, name.indexOf('.')) : name;

  Map<String, Object?> toJson() => {
        'name': name,
        'group': group,
        'summary': summary,
        'params': [for (final p in params) p.toJson()],
        'returns': returns,
        'danger': danger,
        if (example != null) 'example': example,
      };
}

/// A call refused: the method does not exist, a parameter is missing or of the wrong kind, or what it asked failed.
class ApiError implements Exception {
  const ApiError(this.code, this.message);

  /// not_found, bad_params, failed, unauthorized.
  final String code;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'message': message};

  @override
  String toString() => '$code: $message';
}

/// One call, for the log in Settings › API.
@immutable
class ApiCall {
  const ApiCall({required this.method, required this.via, required this.at, required this.ok, required this.ms, this.error});
  final String method;

  /// here (Settings' test area), http, relay.
  final String via;
  final DateTime at;
  final bool ok;
  final int ms;
  final String? error;
}

/// The registry: every method by its name, a call made with its parameters checked, and the log of the last calls.
class Api {
  Api._() {
    // Its own two, always there, whatever else is registered.
    register(ApiMethod(name: 'api.ping', summary: 'Answers at once: whether the API is there and which version it speaks.', returns: '{"pong": true, "version": int}', run: (_) async => {'pong': true, 'version': version}));
    register(ApiMethod(name: 'api.describe', summary: 'Every method, its parameters, what it answers and an example: this documentation as JSON.', returns: '{"api", "version", "methods": [...]}', run: (_) async => describe()));
  }
  static final Api instance = Api._();

  /// The format of what the API says, raised when a method's answer changes shape.
  static const version = 1;

  final Map<String, ApiMethod> _methods = {};

  /// The last calls, newest first: what Settings › API shows.
  final ValueNotifier<List<ApiCall>> calls = ValueNotifier(const []);

  /// Adds a method. Two of one name is a mistake, caught by an assert.
  void register(ApiMethod m) {
    assert(!_methods.containsKey(m.name), 'two methods called ${m.name}');
    _methods[m.name] = m;
  }

  void registerAll(Iterable<ApiMethod> ms) => ms.forEach(register);

  /// Every method, in order of name; and the one called [name].
  List<ApiMethod> get methods => _methods.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  ApiMethod? method(String name) => _methods[name];

  /// The groups, in the order their first method was registered.
  List<String> get groups => {for (final m in _methods.values) m.group}.toList();

  /// Everything the API says of itself: what tool/ghost-api.mjs prints and `GET /api` answers.
  Map<String, Object?> describe() => {'api': 'ghost-messaging', 'version': version, 'methods': [for (final m in methods) m.toJson()]};

  /// Calls [name] with [params]: checked against what the method takes, run, and logged. Throws [ApiError].
  Future<Object?> call(String name, Map<String, Object?> params, {String via = 'here'}) async {
    final m = _methods[name];
    final started = DateTime.now();
    void log(bool ok, [String? error]) {
      final list = [ApiCall(method: name, via: via, at: started, ok: ok, ms: DateTime.now().difference(started).inMilliseconds, error: error), ...calls.value];
      calls.value = list.length > 50 ? list.sublist(0, 50) : list;
    }

    if (m == null) {
      log(false, 'no such method');
      throw ApiError('not_found', 'There is no method called "$name". GET /api lists them.');
    }
    for (final p in m.params) {
      final v = params[p.name];
      if (v == null) {
        if (p.required) {
          log(false, 'missing ${p.name}');
          throw ApiError('bad_params', '"${p.name}" is needed: ${p.doc}');
        }
        continue;
      }
      final fits = switch (p.type) {
        'string' => v is String,
        'int' => v is int || (v is num && v == v.roundToDouble()),
        'bool' => v is bool,
        'list' => v is List,
        'object' => v is Map,
        _ => true,
      };
      if (!fits) {
        log(false, '${p.name} is not a ${p.type}');
        throw ApiError('bad_params', '"${p.name}" should be a ${p.type}, not ${v.runtimeType}.');
      }
    }
    try {
      final result = await m.run(params);
      log(true);
      return result;
    } on ApiError catch (e) {
      log(false, e.message);
      rethrow;
    } catch (e) {
      final said = '$e'.replaceFirst(RegExp(r'^(Bad state|Exception|StateError|PlatformException)[:(]\s*'), '');
      log(false, said);
      throw ApiError('failed', said);
    }
  }

  /// A call as a request and its answer, both JSON: what the HTTP server and the relay link pass along.
  /// `{"method": "...", "params": {...}, "id": ...}` → `{"id": ..., "ok": true, "result": ...}` or
  /// `{"id": ..., "ok": false, "error": {"code", "message"}}`.
  Future<Map<String, Object?>> answer(Map<String, Object?> request, {required String via}) async {
    final id = request['id'];
    final name = request['method'];
    if (name is! String) return {if (id != null) 'id': id, 'ok': false, 'error': const ApiError('bad_params', '"method" is needed').toJson()};
    final params = request['params'];
    try {
      final result = await call(name, params is Map ? params.cast<String, Object?>() : const {}, via: via);
      return {if (id != null) 'id': id, 'ok': true, 'result': jsonSafe(result)};
    } on ApiError catch (e) {
      return {if (id != null) 'id': id, 'ok': false, 'error': e.toJson()};
    }
  }
}

/// [v] made something jsonEncode takes: dates as ISO strings, sets as lists, anything else unknown as its words.
Object? jsonSafe(Object? v) {
  if (v == null || v is String || v is num || v is bool) return v;
  if (v is DateTime) return v.toIso8601String();
  if (v is Map) return {for (final e in v.entries) '${e.key}': jsonSafe(e.value)};
  if (v is Iterable) return [for (final x in v) jsonSafe(x)];
  return '$v';
}

/// [v] as indented JSON, for the screen.
String prettyJson(Object? v) => const JsonEncoder.withIndent('  ').convert(jsonSafe(v));

/// [text] read as a JSON object; throws where it is not one.
Map<String, Object?> jsonDecodeObject(String text) {
  final v = jsonDecode(text);
  if (v is! Map) throw const FormatException('not a JSON object');
  return v.cast<String, Object?>();
}
