import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:typed_data';

import '../net/crypto.dart';
import '../net/hub_carrier.dart' show NetSigner;
import '../web/http.dart' show pageHttp;

/// Share feedback (Matt, 2026-11-19: "add a "share feedback" button hovering in the topbar of the app it should be a
/// simple form which allows the user to upload screenshots and explain a bug, suggest a feature or a few other options
/// from a select dropdown and optionally provide their username automatically so we can give out bug bounties"): what
/// is sent, and the relay it goes to (relay/, which files it as a ticket on the feedback board).

/// What kind of feedback it is, as the relay names it.
enum FeedbackType {
  bug('bug', 'Bug'),
  feature('feature', 'Feature idea'),
  confusing('confusing', 'Something confusing'),
  praise('praise', 'Praise'),
  other('other', 'Other');

  const FeedbackType(this.wire, this.label);
  final String wire;
  final String label;
}

/// A screenshot going with the feedback: its name, kind and bytes.
class FeedbackShot {
  const FeedbackShot({required this.name, required this.mime, required this.bytes});
  final String name;
  final String mime;
  final Uint8List bytes;

  /// The kinds of picture the relay takes.
  static const mimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};
}

/// One piece of feedback: its kind, an optional title, the words, the username to be known by (for a bug bounty;
/// null where the person chose not to say it), and up to [mostShots] screenshots.
class FeedbackReport {
  const FeedbackReport({required this.type, this.title = '', required this.text, this.username, required this.platform, required this.version, this.shots = const []});
  final FeedbackType type;
  final String title;
  final String text;
  final String? username;
  final String platform;
  final String version;
  final List<FeedbackShot> shots;

  /// The app's version as feedback and reports say it: in a browser, that it was one (the relay files a browser with
  /// no platform of its own).
  static String thisVersion(String version) => PlatformInfo.isWeb ? '$version (browser)' : version;

  /// The relay's limits: what it would refuse is not sent.
  static const titleMost = 120, textMost = 5000, mostShots = 3, shotMost = 3 * 1024 * 1024, bodyMost = 10 * 1024 * 1024;

  /// What this device is, in the relay's words: 'web' in a browser, which the relay files with no platform (the
  /// version says it, [thisVersion]).
  static String get thisPlatform {
    if (PlatformInfo.isWeb) return 'web';
    if (PlatformInfo.isAndroid) return 'android';
    if (PlatformInfo.isIOS) return 'iphone';
    if (PlatformInfo.isMacOS) return 'mac';
    if (PlatformInfo.isWindows) return 'windows';
    return 'linux';
  }

  /// The request's body: the words trimmed, the username without its @, each screenshot's bytes as base64.
  Map<String, Object?> toJson() {
    final name = username?.trim().replaceFirst(RegExp(r'^@'), '');
    return {
      'type': type.wire,
      'title': title.trim(),
      'text': text.trim(),
      // The username itself, only where the person said to include it; the relay checks it is this key's.
      if (name != null && name.isNotEmpty) 'username': name,
      'platform': platform,
      'version': version,
      'shots': [for (final s in shots) {'name': s.name, 'mime': s.mime, 'data': base64Encode(s.bytes)}],
    };
  }
}

/// Why the feedback didn't go: the relay's words, or that it could not be reached.
class FeedbackError implements Exception {
  FeedbackError(this.message, {this.status = 0});
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// Whether a relay's answer says it takes no feedback at all: none set up there (503, relay/lib/feedback.dart), or a
/// relay from before it took any (404).
bool feedbackNotTaken(FeedbackError e) => e.status == 503 || e.status == 404;

/// Sends feedback by [send] to the relay in use ([hubUrl]) and, where that is a relay of someone's own that takes none
/// ([feedbackNotTaken]), to Uplink's ([ours]) instead: the feedback is about the app, and on a relay with no
/// board of its own it was answered "Feedback isn't set up on this server yet" and lost (GMFB-25: "features that only
/// exist on gogho.st ... fall back cleanly"). The ticket's id. Never from a page in a browser ([mayLeave] false), which
/// may speak only to the relay it came from. Any other failure is the relay's own to say.
Future<String> sendFeedbackOrOurs({required String hubUrl, required String ours, required bool mayLeave, required Future<String> Function(String hubUrl) send}) async {
  try {
    return await send(hubUrl);
  } on FeedbackError catch (e) {
    if (!mayLeave || hubUrl == ours || !feedbackNotTaken(e)) rethrow;
    return send(ours);
  }
}

/// Where feedback goes on the relay at [hubUrl]: the same server, `/feedback` in place of `/hub` (as FilesApi.baseFor
/// finds `/files`).
Uri feedbackUrlFor(String hubUrl) {
  final u = Uri.parse(hubUrl.trim());
  final segments = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isNotEmpty && segments.last == 'hub') segments.removeLast();
  return u.replace(scheme: u.scheme == 'ws' ? 'http' : (u.scheme == 'wss' ? 'https' : u.scheme), pathSegments: [...segments, 'feedback'], query: null, fragment: null);
}

/// How feedback reaches the relay in a browser: the page's own fetch (lib/web/http.dart), or a test's.
typedef FeedbackTransport = Future<({int status, Map<String, String> headers, Uint8List body})> Function(String method, Uri url, Map<String, String> headers, List<int> body, {required int most});

/// Sends [r] to the relay at [hubUrl], signed with this install's hub key [signer] (as a Files space's writes are):
/// the ticket's id the relay answers ("GMFB-12"). Throws a [FeedbackError] with the relay's words otherwise. With
/// dart:io's HttpClient ([client]), or in a browser, which hasn't got it, with the page's own fetch ([transport]).
Future<String> sendFeedback(FeedbackReport r, {required NetSigner signer, required String hubUrl, HttpClient? client, FeedbackTransport? transport}) async {
  final shots = r.shots;
  if (shots.length > FeedbackReport.mostShots) throw FeedbackError('Up to ${FeedbackReport.mostShots} screenshots go with feedback.');
  if (shots.any((s) => s.bytes.length > FeedbackReport.shotMost)) throw FeedbackError('A screenshot is larger than 3 MB.');
  final text = r.text.trim();
  if (text.isEmpty) throw FeedbackError('Say what happened first.');
  if (text.length > FeedbackReport.textMost) throw FeedbackError('That\'s more than ${FeedbackReport.textMost} characters.');
  final body = utf8.encode(jsonEncode(r.toJson()));
  if (body.length > FeedbackReport.bodyMost) throw FeedbackError('The screenshots are too large together.');
  final url = feedbackUrlFor(hubUrl);
  final page = transport ?? (client == null && PlatformInfo.isWeb ? pageHttp : null);
  if (page != null) return _sendFromPage(page, url, body, signer);
  final http = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 15));
  try {
    final req = await http.postUrl(url);
    // Signed over what the relay sees: the method, the path, the time and the body's hash.
    final time = DateTime.now().millisecondsSinceEpoch;
    final sha = NetCrypto.hex(NetCrypto.sha256(body));
    final sig = await signer.sign(utf8.encode('ghost-feedback v1\nPOST\n${url.path}\n$time\n$sha'));
    req.headers
      ..contentType = ContentType.json
      ..set('x-ghost-key', base64Encode(signer.publicKey))
      ..set('x-ghost-time', '$time')
      ..set('x-ghost-sig', base64Encode(sig));
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 60));
    final words = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(words) as Map).cast<String, dynamic>();
    } catch (_) {
      m = {};
    }
    if (res.statusCode >= 300 || m['ok'] != true) {
      final said = m['error'];
      throw FeedbackError(said is String && said.trim().isNotEmpty ? said : 'The server said ${res.statusCode}.', status: res.statusCode);
    }
    return '${m['id'] ?? ''}';
  } on FeedbackError {
    rethrow;
  } on SocketException {
    throw FeedbackError('Couldn\'t reach the server. Check your connection and try again.');
  } on HttpException {
    throw FeedbackError('Couldn\'t reach the server. Try again in a moment.');
  } on HandshakeException {
    throw FeedbackError('Couldn\'t reach the server securely.');
  } on TimeoutException {
    throw FeedbackError('The server didn\'t answer. Try again in a moment.');
  } finally {
    if (client == null) http.close();
  }
}

/// [body] to [url] from a page, signed as [sendFeedback] signs it: the ticket's id, or the relay's words as a
/// [FeedbackError]. No answer, or one the browser won't let the page read (the relay not letting this page's address,
/// GHOST_APP_ORIGIN), is "couldn't reach".
Future<String> _sendFromPage(FeedbackTransport send, Uri url, List<int> body, NetSigner signer) async {
  final time = DateTime.now().millisecondsSinceEpoch;
  final sha = NetCrypto.hex(NetCrypto.sha256(body));
  final sig = await signer.sign(utf8.encode('ghost-feedback v1\nPOST\n${url.path}\n$time\n$sha'));
  final ({int status, Map<String, String> headers, Uint8List body}) res;
  try {
    res = await send(
      'POST',
      url,
      {'content-type': 'application/json; charset=utf-8', 'x-ghost-key': base64Encode(signer.publicKey), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(sig)},
      body,
      most: 64 * 1024,
    ).timeout(const Duration(seconds: 90));
  } on TimeoutException {
    throw FeedbackError('The server didn\'t answer. Try again in a moment.');
  } catch (_) {
    throw FeedbackError('Couldn\'t reach the server. Check your connection and try again.');
  }
  Map<String, dynamic> m;
  try {
    m = (jsonDecode(utf8.decode(res.body)) as Map).cast<String, dynamic>();
  } catch (_) {
    m = {};
  }
  if (res.status >= 300 || m['ok'] != true) {
    final said = m['error'];
    throw FeedbackError(said is String && said.trim().isNotEmpty ? said : 'The server said ${res.status}.', status: res.status);
  }
  return '${m['id'] ?? ''}';
}
