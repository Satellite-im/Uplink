/// The app's side of the Marketplace on the relay (relay/lib/market.dart; Matt, 2026-11-20: "I would like users to be
/// able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the
/// store through a review process"): the catalog and the withdrawals anyone may read, the packages and screenshots
/// they name, a report, and a developer's own submissions, each signed with this install's hub key.
///
/// What it reads is bounded before it is decoded, and nothing it reads is trusted for what it says a plugin is: a
/// listing is drawn from its package once the package's SHA-256 and approval check out (market_state.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../net/hub_carrier.dart' show NetSigner;
import '../net/net.dart';
import '../platform_info.dart';
import '../plugins/pack/pack.dart' show InstalledPlugins, PackIssue, PackLimits, PackRevocation, packHere, packIdPattern, sha256Hex;
import '../web/http.dart' show pageHttp;
import 'market_models.dart';

/// Whether [hubUrl] is Uplink's own relay: its host is gogho.st or ghost-sms.com.
bool marketIsOwn(String hubUrl) {
  final host = Uri.tryParse(hubUrl.trim())?.host.toLowerCase() ?? '';
  return host == 'gogho.st' || host == 'ghost-sms.com';
}

const Set<String> _loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};

/// Where the Marketplace is on the relay at [hubUrl]: the same server, /market in place of /hub (as feedbackUrlFor).
/// https only, unless the host is 127.0.0.1, localhost or [::1] (a test's server): MarketError('not_https') otherwise.
Uri marketUrlFor(String hubUrl, [List<String> segments = const []]) {
  final u = Uri.parse(hubUrl.trim());
  final scheme = switch (u.scheme) { 'wss' => 'https', 'ws' => 'http', final s => s };
  if (scheme != 'https' && !(scheme == 'http' && _loopback.contains(u.host))) {
    throw const MarketError('not_https', 'The Marketplace is reached over https only.');
  }
  final path = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (path.isNotEmpty && path.last == 'hub') path.removeLast();
  return u.replace(scheme: scheme, pathSegments: [...path, 'market', ...segments], query: null, fragment: null);
}

/// Why a call to the Marketplace didn't go: the relay's own error (C.3) with its words, or 'unreachable', 'no_identity',
/// 'too_large' or 'not_https'.
class MarketError implements Exception {
  const MarketError(this.code, this.message, {this.status = 0, this.issues = const []});
  final String code;
  final String message;
  final int status;
  final List<PackIssue> issues;

  @override
  String toString() => message;
}

/// How a call reaches the relay: a method, an address, headers and a body, read back no further than [most] bytes.
/// The app's own goes through dart:io, and in a browser through the page's own fetch (lib/web/http.dart: a report is
/// the one call made there); a test passes one of its own.
typedef MarketTransport = Future<({int status, Map<String, String> headers, Uint8List body})> Function(String method, Uri url, Map<String, String> headers, List<int> body, {required int most});

const String _unreachable = 'Couldn\'t reach the Marketplace. Try again in a moment.';

/// The most of each answer that is read: a catalog of 8 MiB, a revoked list of 8 MiB, a package, a screenshot, and
/// 2 MiB of anything else. The revoked list's limits are the relay's own (relay/lib/market.dart withdrawalsMost), so it
/// never serves a list every app refuses whole: at 1 MiB, some 3,200 withdrawals in, it did, and none reached a device
/// after (review, 2026-11-20).
abstract final class MarketReads {
  static const int catalog = 8 * 1024 * 1024, catalogEntries = 2000;
  static const int revoked = 8 * 1024 * 1024, revocations = InstalledPlugins.revocationsTaken, retirements = InstalledPlugins.retirementsTaken;
  static const int package = PackLimits.packageBytes, shot = PackLimits.shotBytes, other = 2 * 1024 * 1024;
}

/// The Marketplace's routes on one relay, a method each, numbered as the relay numbers them. Reading the catalog, the
/// withdrawals, packages and screenshots needs no identity; reporting, submitting and reviewing are signed by [signer].
/// Every failure is a [MarketError].
class MarketApi {
  MarketApi({required this.hubUrl, this.signer, MarketTransport? transport, DateTime Function()? now})
      : _transport = transport ?? (PlatformInfo.isWeb ? pageHttp : _http),
        _now = now ?? DateTime.now;

  /// Uplink's own relay whatever net_hub says (Net.instance.hubUrl where marketIsOwn, else Net.defaultHub):
  /// plugins are reviewed there, and withdrawals are read from there; signer: Net.instance.hub?.signer.
  factory MarketApi.live() {
    final hub = Net.instance.hubUrl;
    return MarketApi(hubUrl: marketIsOwn(hub) ? hub : Net.defaultHub, signer: Net.instance.hub?.signer);
  }

  final String hubUrl;
  final NetSigner? signer;
  final MarketTransport _transport;
  final DateTime Function() _now;

  /// The same, at another relay: Uplink's own, for its withdrawals, where this one is another of ours.
  MarketApi at(String hub) => MarketApi(hubUrl: hub, signer: signer, transport: _transport, now: _now);

  /// The last signed time sent: two requests in one millisecond would replay each other.
  int _last = 0;

  // --- the routes ------------------------------------------------------------------------------------------------------

  Future<MarketInfo> info() async => MarketInfo.fromJson(await _json('GET', const []));                                                      // route 1

  /// Route 2: null where the catalog is still [etag]'s (304).
  Future<Catalog?> catalog({String? etag}) async {
    final r = await _ask('GET', const ['catalog'], most: MarketReads.catalog, headers: {'if-none-match': ?etag});
    if (r.status == 304) return null;
    final j = _decode(r);
    if (j['plugins'] is List && (j['plugins'] as List).length > MarketReads.catalogEntries) throw _tooLarge;
    return Catalog.fromJson(j, etag: r.headers['etag']);
  }

  /// Route 3: null where the list is still [etag]'s (304).
  Future<RevokedList?> revoked({String? etag}) async {
    final r = await _ask('GET', const ['revoked'], most: MarketReads.revoked, headers: {'if-none-match': ?etag});
    if (r.status == 304) return null;
    final j = _decode(r);
    if ((j['revoked'] is List && (j['revoked'] as List).length > MarketReads.revocations) || (j['retired'] is List && (j['retired'] as List).length > MarketReads.retirements)) throw _tooLarge;
    return RevokedList(j.cast<String, Object?>(), etag: r.headers['etag']);
  }

  Future<Uint8List> package(String sha256) => _bytes('GET', ['packages', _sha(sha256)], most: MarketReads.package);               // route 4
  Future<Uint8List> shot(String sha256) => _bytes('GET', ['shots', _sha(sha256)], most: MarketReads.shot);                        // route 6

  /// Route 7: the report's id. Signed with [signer] where given (the person's hub key, or their spaces' where they have
  /// no hub), else this api's.
  Future<String> report(PluginReport r, {NetSigner? signer}) async {
    final j = await _json('POST', const ['report'], body: r.toJson(), signer: signer ?? this.signer, who: _reporting);
    return _text(j['id']);
  }

  /// Route 8: the submission as the relay keeps it.
  Future<SubmissionView> submit(SubmissionRequest r) async {
    final j = await _json('POST', const ['submissions'], body: r.toJson(), who: _submitting, answer: const Duration(seconds: 60));
    return SubmissionView.fromJson(j['submission'] is Map ? j['submission'] as Map : const {});
  }

  /// Route 8 with `check: true`: throws the relay's refusal, if any (id_taken, not_owner, name_used, ...).
  Future<void> check(String packageBase64) async {
    await _json('POST', const ['submissions'], body: {'package': packageBase64, 'check': true}, who: _submitting);
  }

  Future<MyMarket> mine() async => MyMarket.fromJson(await _json('GET', const ['mine'], who: _submitting));                                  // route 9
  Future<SubmissionView> submission(String sid) async => _submission(await _json('GET', ['submissions', _sid(sid)], who: _submitting));     // route 10
  Future<Uint8List> submissionPackage(String sid) => _bytes('GET', ['submissions', _sid(sid), 'package'], most: MarketReads.package, who: _submitting);   // route 11
  Future<Uint8List> submissionShot(String sid, int n) => _bytes('GET', ['submissions', _sid(sid), 'shots', '$n'], most: MarketReads.shot, who: _submitting);   // route 12
  Future<SubmissionView> withdraw(String sid) async => _submission(await _json('DELETE', ['submissions', _sid(sid)], who: _submitting));     // route 13

  // --- the review (routes 14 to 21): the admin signed in on this device's hub, by its own key -----------------------

  Future<ReviewQueue> reviewQueue() async => ReviewQueue.fromJson(await _json('GET', const ['review'], who: _reviewing));                       // route 14
  Future<ReviewItem> reviewItem(String sid) async => ReviewItem.fromJson(await _json('GET', ['review', _sid(sid)], who: _reviewing));         // route 15

  /// Route 16: start, approve, ask for changes or reject. An approval in [d] must be signed by this api's own signer,
  /// the key the request is signed with (the relay wants the two to be one).
  Future<ReviewRow> decide(String sid, ReviewDecision d) async {
    final j = await _json('POST', ['review', _sid(sid)], body: d.toJson(), who: _reviewing);
    return ReviewRow.fromJson(j['submission'] is Map ? j['submission'] as Map : const {});
  }

  /// Route 17: a plugin taken off the Marketplace, or listed again, by its owner (My submissions) or the reviewer. Its
  /// words with no identity are the review's, as the routes from 14 on are; My submissions never gets that far without
  /// one, since it says so before anything.
  Future<PluginState> setListed(String plugin, bool listed, {String? note}) async {
    final j = await _json('POST', ['plugins', _id(plugin), 'listing'], body: {'listed': listed, 'note': ?note}, who: _reviewing);
    return PluginState.fromJson(j['plugin'] is Map ? j['plugin'] as Map : const {});
  }

  /// Route 18: one approved version of [plugin] withdrawn, its reason signed in [r].
  Future<PluginState> revoke(String plugin, PackRevocation r) async {
    final j = await _json('POST', ['plugins', _id(plugin), 'revoke'], body: r.toJson(), who: _reviewing);
    return PluginState.fromJson(j['plugin'] is Map ? j['plugin'] as Map : const {});
  }

  /// Route 19: the reports, newest first.
  Future<List<ReportView>> reports() async {
    final j = await _json('GET', const ['reports'], who: _reviewing);
    return [for (final r in (j['reports'] is List ? j['reports'] as List : const [])) if (r is Map) ReportView.fromJson(r)];
  }

  /// Route 20: a report dealt with.
  Future<void> resolveReport(String rid) async {
    await _json('POST', ['reports', _rid(rid)], body: const {'done': true}, who: _reviewing);
  }

  /// Route 21: a developer blocked from submitting (their plugins unlisted too, with [unlist]), or let back.
  Future<DeveloperView> block(String developerId, {required bool blocked, String? note, bool unlist = false}) async {
    final j = await _json('POST', ['developers', _dev(developerId), 'block'], body: {'blocked': blocked, 'note': ?note, if (unlist) 'unlist': true}, who: _reviewing);
    return DeveloperView.fromJson(j['developer'] is Map ? j['developer'] as Map : const {});
  }

  // --- reports of people and messages (routes 23 to 25; GMFB-40) ------------------------------------------------------

  /// Route 23: a report of a person or a message, already sealed to the review keys (lib/safety/abuse_report.dart);
  /// its id on the relay. Signed with [signer] where given, else this api's.
  Future<String> reportPerson(String sealed, {NetSigner? signer}) async {
    final j = await _json('POST', const ['abuse'], body: {'sealed': sealed}, signer: signer ?? this.signer, who: _reporting);
    return _text(j['id']);
  }

  /// Route 24: the reports of people, newest first, sealed: the reviewer opens them with this device's own key.
  Future<List<SealedReportRow>> sealedReports() async {
    final j = await _json('GET', const ['abuse'], who: _reviewing, most: 16 * 1024 * 1024);
    return [for (final r in (j['reports'] is List ? j['reports'] as List : const [])) if (r is Map) ?SealedReportRow.fromJson(r)];
  }

  /// Route 25: a report of a person dealt with.
  Future<void> resolveSealedReport(String rid) async {
    await _json('POST', ['abuse', _rid(rid)], body: const {'done': true}, who: _reviewing);
  }

  // --- how a call is made --------------------------------------------------------------------------------------------

  static String get _submitting => 'Submitting needs your Uplink identity on this ${packHere()}. Become the same you as your phone in Settings › Me, or submit from your phone.';
  static String get _reporting => 'Reporting needs your Uplink identity on this ${packHere()}. Become the same you as your phone in Settings › Me.';
  static String get _reviewing => 'Reviewing needs your Uplink identity on this ${packHere()}. Become the same you as your phone in Settings › Me.';

  static const _tooLarge = MarketError('too_large', 'The Marketplace sent more than the app reads.');

  // Each name that goes into a path is held to its shape first, so nothing else can ever be put into one.
  static String _text(Object? v) => v is String ? v : '';
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _hex24 = RegExp(r'^[0-9a-f]{24}$');
  static String _sha(String s) => _hex64.hasMatch(s) ? s : throw const MarketError('bad_request', 'That isn\'t a package\'s or a picture\'s name.');
  static String _sid(String s) => _hex24.hasMatch(s) ? s : throw const MarketError('bad_request', 'That isn\'t a submission\'s name.');
  static final _hex16 = RegExp(r'^[0-9a-f]{16}$');
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');
  static String _rid(String s) => _hex16.hasMatch(s) ? s : throw const MarketError('bad_request', 'That isn\'t a report\'s name.');
  static String _dev(String s) => _hex32.hasMatch(s) ? s : throw const MarketError('bad_request', 'That isn\'t a developer\'s name.');
  static String _id(String s) => packIdPattern.hasMatch(s) ? s : throw const MarketError('bad_request', 'That isn\'t a plugin\'s id.');
  static SubmissionView _submission(Map j) => SubmissionView.fromJson(j['submission'] is Map ? j['submission'] as Map : const {});

  /// Asks and reads a JSON answer: `ok: true`, or the relay's refusal thrown as a [MarketError].
  Future<Map> _json(String method, List<String> path, {Object? body, String? who, NetSigner? signer, Duration answer = const Duration(seconds: 20), int most = MarketReads.other}) async => _decode(await _ask(method, path, body: body, who: who, signer: signer, most: most, answer: answer));

  /// Asks for a file: its bytes where the answer is 200, else the relay's refusal.
  Future<Uint8List> _bytes(String method, List<String> path, {required int most, String? who}) async {
    final r = await _ask(method, path, who: who, most: most);
    if (r.status == 200) return r.body;
    _decode(r);
    throw const MarketError('unreachable', _unreachable);
  }

  /// [r]'s JSON, where it is `ok: true`; else what the relay said, or that it couldn't be read.
  Map _decode(({int status, Map<String, String> headers, Uint8List body}) r) {
    Map j;
    try {
      final decoded = jsonDecode(utf8.decode(r.body));
      if (decoded is! Map) throw const FormatException('Not an object');
      j = decoded;
    } catch (_) {
      throw MarketError('unreachable', _unreachable, status: r.status);
    }
    if (j['ok'] == true) return j;
    final issues = <PackIssue>[for (final i in (j['issues'] is List ? j['issues'] as List : const [])) if (i is Map) PackIssue.fromJson(i)];
    final message = _text(j['message']);
    throw MarketError(_text(j['error']).isEmpty ? 'broken' : _text(j['error']), message.isEmpty ? 'The Marketplace said no.' : message, status: r.status, issues: issues);
  }

  /// One call: signed where [who] says why it needs the identity (the words thrown where there is none), its body as
  /// JSON with its hash and length headers, read no further than [most].
  Future<({int status, Map<String, String> headers, Uint8List body})> _ask(String method, List<String> path, {Object? body, String? who, NetSigner? signer, required int most, Map<String, String> headers = const {}, Duration answer = const Duration(seconds: 20)}) async {
    final url = marketUrlFor(hubUrl, path);
    final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
    final sent = <String, String>{...headers, if (body != null) 'content-type': 'application/json; charset=utf-8'};
    if (who != null) {
      final by = signer ?? this.signer;
      if (by == null) throw MarketError('no_identity', who);
      // Signed over what the relay sees: the method, the path as asked, the time and the body's hash (the empty body's
      // for a GET or a DELETE). A body says its hash and length too, so the relay checks all of it before reading any.
      final sha = sha256Hex(bytes);
      final time = _last = math.max(_now().millisecondsSinceEpoch, _last + 1);
      final sig = await by.sign(utf8.encode('ghost-market v1\n$method\n${url.path}\n$time\n$sha'));
      sent
        ..['x-ghost-key'] = base64Encode(by.publicKey)
        ..['x-ghost-time'] = '$time'
        ..['x-ghost-sig'] = base64Encode(sig);
      if (body != null) {
        sent
          ..['x-ghost-body-sha256'] = sha
          ..['x-ghost-body-length'] = '${bytes.length}';
      }
    }
    final ({int status, Map<String, String> headers, Uint8List body}) r;
    try {
      r = await _transport(method, url, sent, bytes, most: most).timeout(answer);
    } on MarketError {
      rethrow;
    } catch (_) {
      // A socket, a handshake, a timeout: the same words whichever.
      throw const MarketError('unreachable', _unreachable);
    }
    // A transport that read past the limit (a test's, or a relay that ignored it) is still refused.
    if (r.body.length > most) throw _tooLarge;
    return r;
  }

  /// The app's own way to the relay: 15 s to connect, the body read as it comes and no further than [most].
  static Future<({int status, Map<String, String> headers, Uint8List body})> _http(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body.isNotEmpty) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close();
      if (res.contentLength > most) throw _tooLarge;
      final read = BytesBuilder(copy: false);
      await for (final piece in res) {
        read.add(piece);
        if (read.length > most) throw _tooLarge;
      }
      final got = <String, String>{};
      res.headers.forEach((name, values) => got[name.toLowerCase()] = values.join(','));
      return (status: res.statusCode, headers: got, body: read.takeBytes());
    } finally {
      client.close(force: true);
    }
  }
}
