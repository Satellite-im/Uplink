import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'p256.dart';

/// Waking an app that is closed when something is held for it (Matt, 2026-11-16: "Yes, wake-ups"; Android checks
/// every fifteen minutes on its own, hub.dart's `peek`): an iPhone says, over its connection, the token Apple gave it
/// for push notifications, and when a packet is held for it this asks Apple to show "New message".
///
/// - **What is kept** (`pushes.json`): per device of an install (the `device` its hello says: two iPhones signed in to
///   one account are one install to the hub, each with a token of its own), the token and whether it is Apple's sandbox
///   (a build from Xcode) or production, and the day. Nothing about who sent what: the notification says only that
///   something came. An app from before devices says none, and is kept as the install's device '' as it always was.
///   One device saying `{"push": null}` (a wiped or signed-out iPhone) takes its own token alone, never a sibling's
///   (third review); what is held wakes every device of the install that gave one.
/// - **How often**: at most once a minute per install ([quiet]), however much is held.
/// - **Apple's side** needs a key from the Apple Developer account (an APNs .p8 file, its key id, the team id and the
///   app's bundle id: [ApnsConfig.fromEnvironment]). Without one nothing is sent and registrations are still kept.
class Pushes {
  Pushes({this.dataDir, ApnsConfig? config, this.send, DateTime Function()? now, this.quiet = const Duration(minutes: 1)})
      : config = config ?? const ApnsConfig(),
        _now = now ?? DateTime.now {
    _load();
  }

  final Directory? dataDir;
  final ApnsConfig config;
  final Duration quiet;
  final DateTime Function() _now;

  /// Sends one notification to a token; Apple's by default ([Apns.send]). A test gives its own.
  final Future<bool> Function(String token, bool sandbox)? send;

  /// `install|device` -> its token (a key from before devices, the install alone, is read as `install|`).
  final Map<String, ({String token, bool sandbox, String day})> _tokens = {};

  /// The key a device's token is kept under, and the install such a key belongs to.
  static String _key(String id, String device) => '$id|$device';
  static String _idOf(String key) => key.contains('|') ? key.substring(0, key.indexOf('|')) : key;
  final Map<String, DateTime> _last = {};
  Apns? _apns;

  File? get _file => dataDir == null ? null : File('${dataDir!.path}/pushes.json');

  int get registered => _tokens.length;

  /// Reads pushes.json: `{<name>: {t: token, s: sandbox, d: day}}`. One that can't be read is started empty.
  void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map;
      for (final e in j.entries) {
        final v = e.value as Map;
        final key = '${e.key}';
        _tokens[key.contains('|') ? key : _key(key, '')] = (token: '${v['t']}', sandbox: v['s'] == true, day: '${v['d']}');
      }
    } catch (_) {}
  }

  /// Writes every token to a file beside and renames it over, after each change.
  void _save() {
    final f = _file;
    if (f == null) return;
    f.parent.createSync(recursive: true);
    final temp = File('${f.path}.new')..writeAsStringSync(jsonEncode({for (final e in _tokens.entries) e.key: {'t': e.value.token, 's': e.value.sandbox, 'd': e.value.day}}));
    temp.renameSync(f.path);
  }

  /// What an install's [device] says about its token (`{"push": {"apns": "<hex>", "sandbox": true}}`, or
  /// `{"push": null}` to forget it). Said over its own connection, so only it can set its own; and its own device's
  /// alone. The same token kept under another of the install's devices (the same iPhone before it said which device it
  /// is) is taken off there.
  void said(String id, Object? what, {String device = ''}) {
    final key = _key(id, device);
    if (what is Map && what['apns'] is String && RegExp(r'^[0-9a-fA-F]{32,200}$').hasMatch(what['apns'] as String)) {
      final token = (what['apns'] as String).toLowerCase();
      _tokens.removeWhere((k, v) => k != key && _idOf(k) == id && v.token == token);
      _tokens[key] = (token: token, sandbox: what['sandbox'] == true, day: _now().toIso8601String().substring(0, 10));
    } else {
      _tokens.remove(key);
    }
    _save();
  }

  /// Something was held for [id], who is not connected: each of their devices that gave a token is asked to wake, if
  /// it can be.
  void held(String id) {
    final mine = [for (final e in _tokens.entries) if (_idOf(e.key) == id) e];
    if (mine.isEmpty) return;
    final now = _now();
    final last = _last[id];
    if (last != null && now.difference(last) < quiet) return;
    _last[id] = now;
    for (final e in mine) {
      unawaited(_deliver(e.key, e.value.token, e.value.sandbox));
    }
  }

  /// One wake to the token kept under [key] (`install|device`).
  Future<void> _deliver(String key, String token, bool sandbox) async {
    final s = send;
    bool ok;
    if (s != null) {
      ok = await s(token, sandbox);
    } else if (config.ready) {
      ok = await (_apns ??= Apns(config)).send(token, sandbox: sandbox);
    } else {
      return;
    }
    // A token Apple no longer knows (the app was deleted) is forgotten; [Apns.send] says so by false with gone.
    if (!ok && _apns?.lastGone == true) {
      _tokens.remove(key);
      _save();
    }
  }
}

/// Apple's push service: what is needed to speak to it (from the environment on the server).
class ApnsConfig {
  const ApnsConfig({this.keyFile = '', this.keyId = '', this.teamId = '', this.topic = ''});

  factory ApnsConfig.fromEnvironment(Map<String, String> env) => ApnsConfig(
        keyFile: env['GHOST_APNS_KEY_FILE'] ?? '',
        keyId: env['GHOST_APNS_KEY_ID'] ?? '',
        teamId: env['GHOST_APNS_TEAM_ID'] ?? '',
        topic: env['GHOST_APNS_TOPIC'] ?? 'com.infamousvague.ghostmessaging',
      );

  /// The .p8 file Apple gave for the key.
  final String keyFile;
  final String keyId;
  final String teamId;

  /// The app's bundle id.
  final String topic;

  /// Whether everything needed is set and the key's file is there; where not, nothing is sent.
  bool get ready => keyFile.isNotEmpty && keyId.isNotEmpty && teamId.isNotEmpty && topic.isNotEmpty && File(keyFile).existsSync();
}

/// Sends to Apple: a token signed with the key (ES256, made again every fifty minutes), over HTTP/2, which Dart's
/// own client does not speak, so by `curl --http2` (the server has it); nothing fetched into the relay.
class Apns {
  Apns(this.config);
  final ApnsConfig config;
  String? _jwt;
  DateTime? _made;

  /// Whether the last [send] was told the token is no longer one Apple knows (410, BadDeviceToken, Unregistered).
  bool lastGone = false;

  /// The private key's 32 bytes, from the PKCS#8 the .p8 holds: the OCTET STRING after the version inside the
  /// ECPrivateKey (04 20 then the key).
  static List<int> scalarOf(String pem) {
    final der = base64Decode(pem.split('\n').where((l) => !l.startsWith('-----') && l.trim().isNotEmpty).join());
    for (var i = 0; i + 34 <= der.length; i++) {
      // ECPrivateKey: 02 01 01 (version 1), then 04 20 (32 bytes).
      if (der[i] == 0x02 && der[i + 1] == 0x01 && der[i + 2] == 0x01 && der[i + 3] == 0x04 && der[i + 4] == 0x20) {
        return der.sublist(i + 5, i + 37);
      }
    }
    throw const FormatException('No P-256 private key in that .p8');
  }

  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// A provider token for Apple: header and claims, signed ES256 with the key.
  static String token(List<int> scalar, {required String keyId, required String teamId, required int issuedAt, Random? random}) {
    final header = _b64(utf8.encode(jsonEncode({'alg': 'ES256', 'kid': keyId})));
    final claims = _b64(utf8.encode(jsonEncode({'iss': teamId, 'iat': issuedAt})));
    final signed = '$header.$claims';
    final rnd = random ?? Random.secure();
    final nonce = [for (var i = 0; i < 32; i++) rnd.nextInt(256)];
    return '$signed.${_b64(P256.sign(scalar, utf8.encode(signed), nonce))}';
  }

  /// The provider token in use, made again once it is fifty minutes old (Apple takes one for an hour).
  String _jwtNow() {
    final now = DateTime.now();
    if (_jwt == null || _made == null || now.difference(_made!) > const Duration(minutes: 50)) {
      final scalar = scalarOf(File(config.keyFile).readAsStringSync());
      _jwt = token(scalar, keyId: config.keyId, teamId: config.teamId, issuedAt: now.millisecondsSinceEpoch ~/ 1000);
      _made = now;
    }
    return _jwt!;
  }

  /// The notification itself: words only, since the relay cannot read what came.
  static const payload = '{"aps":{"alert":{"title":"Uplink","body":"New message"},"sound":"default","thread-id":"ghost"}}';

  /// What curl is run with to post [payload] to [url], and what it is given on its standard input: the headers, one
  /// a line (`-H @-`), so the provider token [jwt] is never among the arguments, which anyone on the machine can read
  /// in the list of processes.
  static (List<String>, String) curlFor(String url, {required String jwt, required String topic}) => (
        ['--http2', '-s', '-o', '/dev/stderr', '-w', '%{http_code}', '--max-time', '15', '-H', '@-', '-d', payload, url],
        'authorization: bearer $jwt\napns-topic: $topic\napns-push-type: alert\napns-priority: 10\n',
      );

  /// Runs curl with [args], [input] on its standard input: what it printed on stdout and on stderr.
  static Future<(String, String)> curl(List<String> args, String input) async {
    final p = await Process.start('curl', args);
    final out = p.stdout.transform(utf8.decoder).join(), err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    try {
      p.stdin.write(input);
      await p.stdin.close();
    } catch (_) {
      // curl ended before it read them: its status says what happened.
    }
    await p.exitCode;
    return (await out, await err);
  }

  /// Asks Apple to show [payload] on the device with [token]; true where Apple took it (200). curl prints the status
  /// on stdout and Apple's answer on stderr, which is read for why a token was refused ([lastGone]).
  Future<bool> send(String token, {bool sandbox = false}) async {
    final host = sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    try {
      final (args, input) = curlFor('https://$host/3/device/$token', jwt: _jwtNow(), topic: config.topic);
      final (out, err) = await curl(args, input);
      final status = out.trim();
      lastGone = status == '410' || err.contains('BadDeviceToken') || err.contains('Unregistered');
      return status == '200';
    } catch (_) {
      return false;
    }
  }
}
