/// The API from anywhere, through the relay server (relay/lib/relay.dart), while Settings › API has it on. The phone
/// holds a channel on the relay, named by the connection string's secret (lib/api/seal.dart), as the "phone" end; a
/// client (tool/ghost-api.mjs --remote) dials the same channel as the other end with the same secret. Each request is
/// a binary frame sealed with the secret's key: `{"method", "params", "id"}`; each answer comes back the same way. The
/// relay passes frames while both ends are there, keeps none, and cannot open them.
///
/// The app must be running for it to answer (on Android it is kept while Signal or Telegram is signed in; otherwise
/// while it is open or recently was).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../net/net.dart';
import 'api.dart';
import 'seal.dart';

/// The phone's end of the link: one connection to the relay, kept up and made again while the choice is on.
class ApiRemote {
  ApiRemote._();
  static final ApiRemote instance = ApiRemote._();

  // The connection; the next try, and how many have failed; the secret and relay wanted now; whether the link is on.
  WebSocket? _ws;
  Timer? _retry;
  int _tries = 0;
  String? _wantKey;
  bool _wanted = false;

  /// off, connecting, waiting (for a client), connected (a client is there), or a problem in words.
  final ValueNotifier<String> state = ValueNotifier('off');

  static bool on(AppState app) => app.flag('api_remote', fallback: false);

  /// The connection string a client needs, made the first time it is asked for.
  static String connection(AppState app) {
    final c = app.choice('api_secret', '');
    if (ApiSeal.secretOf(c) != null) return c;
    final made = ApiSeal.newSecret();
    app.set('api_secret', made);
    return made;
  }

  /// A new secret: the old connection string stops working at once.
  static void newConnection(AppState app) => app.set('api_secret', ApiSeal.newSecret());

  /// Another relay to use, for a test.
  @visibleForTesting
  static String? relayOverride;

  /// The relay's address: the hub's own server, at /relay.
  static String relayBase() {
    if (relayOverride != null) return relayOverride!;
    final hub = Net.instance.hubUrl;
    return hub.endsWith('/hub') ? '${hub.substring(0, hub.length - 4)}/relay' : 'wss://gogho.st/relay';
  }

  /// Brings the link in line with the person's choices: closed where off, made again where the secret or the relay
  /// changed, left alone where it is as wanted.
  Future<void> apply(AppState app) async {
    final want = on(app);
    final conn = want ? connection(app) : null;
    final key = conn == null ? null : '$conn ${relayBase()}';
    if (!want) {
      _wanted = false;
      _wantKey = null;
      await _close();
      state.value = 'off';
      return;
    }
    if (_wanted && key == _wantKey && _ws != null) return;
    _wanted = true;
    _wantKey = key;
    _tries = 0;
    await _close();
    unawaited(_connect(ApiSeal(ApiSeal.secretOf(conn!)!)));
  }

  Future<void> _close() async {
    _retry?.cancel();
    _retry = null;
    final ws = _ws;
    _ws = null;
    await ws?.close();
  }

  /// Dials the secret's channel on the relay as its phone end, and says the token.
  Future<void> _connect(ApiSeal seal) async {
    if (!_wanted) return;
    state.value = 'connecting';
    final mine = _wantKey;
    try {
      final ws = await WebSocket.connect('${relayBase()}/${seal.channel}', compression: CompressionOptions.compressionOff).timeout(const Duration(seconds: 15));
      if (!_wanted || mine != _wantKey) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 25);
      _ws = ws;
      ws.add(jsonEncode({'auth': seal.token, 'role': 'phone'}));
      ws.listen(
        (data) => unawaited(_heard(ws, seal, data)),
        onDone: () => _lost(seal, ws, 'the relay closed the link'),
        onError: (Object e) => _lost(seal, ws, '$e'),
      );
    } catch (e) {
      _lost(seal, null, '$e');
    }
  }

  /// What comes down the link. Text is the relay's own word (refused, or whether a client is there); bytes are a
  /// client's sealed request, answered sealed.
  Future<void> _heard(WebSocket ws, ApiSeal seal, Object? data) async {
    if (data is String) {
      Map? m;
      try {
        m = jsonDecode(data) as Map;
      } catch (_) {}
      if (m == null) return;
      if (m['ok'] == false) {
        state.value = 'The relay refused the link: ${m['err'] ?? 'no reason given'}';
        return;
      }
      if (m.containsKey('peer')) {
        _tries = 0;
        state.value = m['peer'] == true ? 'connected' : 'waiting';
      }
      return;
    }
    if (data is! List<int>) return;
    final clear = seal.open(data);
    if (clear == null) return; // not sealed with this key: ignored
    Map<String, Object?> answer;
    try {
      final request = (jsonDecode(utf8.decode(clear)) as Map).cast<String, Object?>();
      answer = await Api.instance.answer(request, via: 'relay');
    } catch (_) {
      answer = {'ok': false, 'error': const ApiError('bad_params', 'The request is not JSON.').toJson()};
    }
    if (identical(_ws, ws)) ws.add(seal.seal(Uint8List.fromList(utf8.encode(jsonEncode(answer)))));
  }

  /// The link went, or was never made: tried again after four seconds, then twice as long each time, a minute at most.
  void _lost(ApiSeal seal, WebSocket? ws, String why) {
    if (ws != null && !identical(_ws, ws)) return;
    _ws = null;
    if (!_wanted) return;
    _tries++;
    final wait = Duration(seconds: (2 << (_tries.clamp(1, 5))).clamp(4, 60));
    state.value = 'Not connected (${why.length > 80 ? '${why.substring(0, 80)}…' : why}); trying again in ${wait.inSeconds} s';
    _retry?.cancel();
    _retry = Timer(wait, () => unawaited(_connect(seal)));
  }
}
