import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_models.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/ui/settings_panes.dart' show appVersion;

/// The Marketplace for the tests (test/market_*.dart, test/marketplace_test.dart, test/dev_plugins_settings_test.dart,
/// test/themes_test.dart, test/souls_test.dart). Everything a plugin from another developer is and does is the runtime's
/// own (lib/plugins/pack): the docs' Bills (test/fixtures/packs/bills.ghostplugin, SPEC A.15), changed as a test needs
/// and read by parsePack; approvals, withdrawals and retirements signed for real by the tests' review key; the device's
/// packs in a real InstalledPlugins in a folder of the test's own. Only the relay is made up: [FakeRelay] answers the
/// Marketplace's routes from memory.
///
/// An InstalledPlugins keeps its work in one queue of futures, made where it is made: a widget test makes its own inside
/// the test ([installedFor]), never in setUp, whose zone is not the test's, and a refresh it waits for with
/// tester.runAsync never hands the installer anything (an empty revoked list is not handed over), so the queue is only
/// ever used from the test's own zone.

/// The docs' Bills as the fixture holds it.
final Map<String, Object?> _fixture = (jsonDecode(File('test/fixtures/packs/bills.ghostplugin').readAsStringSync()) as Map).cast<String, Object?>();

/// The 64 px glyph Bills carries (SPEC A.15): a PNG of pixels alone.
final Uint8List billsIcon = base64Decode(_fixture['icon'] as String);

/// The tests' reviewer: the one review key their InstalledPlugins pin, whose approvals install and verify.
final NetKeys reviewKeys = NetKeys.generate();
final NetSigner reviewer = KeysSigner(reviewKeys);
final String reviewKey = base64Encode(reviewKeys.public);

/// A developer's identity, signing their own requests.
final NetSigner devSigner = KeysSigner(NetKeys.generate());

/// The docs' Bills (test/fixtures/packs/bills.ghostplugin, SPEC A.15) as decoded JSON: the example's id is refused for a
/// submission, so the tests give it one of their own.
Map<String, Object?> billsJson({String id = 'mybills'}) => (jsonDecode(jsonEncode(_fixture)) as Map).cast<String, Object?>()..['id'] = id;

/// The docs' Bills as a test wants it, read by the runtime's parsePack: [id], [name], [version] and the rest in place of
/// the docs' own, made by @maya. [link] gives it a page its header's button opens, with the permission that needs;
/// [icon] another picture, [noIcon] none (as a pack in development may be). A pack that doesn't parse throws, saying why.
PluginPack billsPack({String id = 'bills', String name = 'Bills', String version = '1.0.0', String? developer = 'maya', Uint8List? icon, bool noIcon = false, List<String> shots = const [], String? whatsNew, String? minApp, String? support, String? link, String? description}) {
  final json = billsJson(id: id)
    ..['name'] = name
    ..['version'] = version;
  if (description != null) json['description'] = description;
  if (developer == null) {
    json.remove('developer');
  } else {
    json['developer'] = developer;
  }
  if (noIcon) {
    json.remove('icon');
  } else if (icon != null) {
    json['icon'] = base64Encode(icon);
  }
  if (shots.isNotEmpty) json['shots'] = shots;
  if (whatsNew != null) json['whatsNew'] = whatsNew;
  if (minApp != null) json['minApp'] = minApp;
  if (support != null) json['support'] = support;
  if (link != null) {
    json['links'] = [link];
    json['permissions'] = [...(json['permissions'] as List).cast<String>(), 'links'];
    ((json['rules'] as Map)['actions'] as List).add({'id': 'openpage', 'label': 'Open the page', 'icon': 'link', 'slots': ['conversation.header'], 'do': 'link', 'url': link});
  }
  return parsed(json);
}

/// [json] read by the runtime's parsePack, its minApp left for the Marketplace to judge (as a listing is read); throws
/// with its errors where it isn't a pack.
PluginPack parsed(Map<String, Object?> json) {
  final parse = parsePack(canonicalBytes(json), appVersion: appVersion, checkMinApp: false);
  final pack = parse.pack;
  if (pack == null) throw StateError('Not a pack: ${[for (final e in parse.errors) '${e.code} at ${e.path}: ${e.message}'].join('; ')}');
  return pack;
}

/// [pack]'s bytes as the store holds them: canonical, so each pack has a SHA-256 of its own.
Uint8List packBytes(PluginPack pack) => canonicalBytes(pack.json);

/// [pack] as a file a developer would load: its JSON made canonical, with [change] made to it first.
Uint8List packFile(Map<String, Object?> json, [void Function(Map<String, Object?> json)? change]) {
  final copy = (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();
  change?.call(copy);
  return canonicalBytes(copy);
}

/// [pack]'s approval, signed for real by [by] (the tests' reviewer where not given) over its id, version and SHA-256;
/// [plugin] signs another id over the same bytes. [forged] keeps the reviewer's key but takes another key's signature,
/// so it reads as theirs and doesn't verify.
Future<PackApproval> approvalOf(PluginPack pack, {NetSigner? by, String? plugin, bool forged = false}) async {
  final sha = sha256Hex(packBytes(pack));
  if (!forged) return signApproval(by ?? reviewer, plugin: plugin ?? pack.id, version: pack.version, sha256: sha);
  final other = await signApproval(KeysSigner(NetKeys.generate()), plugin: plugin ?? pack.id, version: pack.version, sha256: sha);
  return PackApproval(plugin: other.plugin, version: other.version, sha256: other.sha256, key: base64Encode((by ?? reviewer).publicKey), sig: other.sig, at: other.at);
}

/// The catalog's entry for [pack], its approval [approvalOf]'s; [approvedId] lists it, and signs it, under another id.
Future<CatalogEntry> entryOf(PluginPack pack, {NetSigner? by, bool forged = false, int updatedAt = 1763600000000, String? approvedId}) async {
  final bytes = packBytes(pack);
  final approval = await approvalOf(pack, by: by, plugin: approvedId, forged: forged);
  return CatalogEntry(id: approvedId ?? pack.id, version: pack.version, sha256: sha256Hex(bytes), size: bytes.length, approval: approval, listedAt: updatedAt, updatedAt: updatedAt);
}

/// A PNG whose chunks are all a pack's icon may hold (so the format takes it) and whose pixels don't decode: what a
/// tile falls back from.
Uint8List brokenPng() {
  Uint8List chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    final crc = _crc32(body);
    return Uint8List.fromList([...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(), ...body, ...(ByteData(4)..setUint32(0, crc)).buffer.asUint8List()]);
  }

  final ihdr = (ByteData(13)
        ..setUint32(0, 64)
        ..setUint32(4, 64)
        ..setUint8(8, 8)
        ..setUint8(9, 6))
      .buffer
      .asUint8List();
  return Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...chunk('IHDR', ihdr), ...chunk('IDAT', List.filled(24, 7)), ...chunk('IEND', const [])]);
}

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

/// The device's packs for real, in [root], pinning the tests' review key (or [keys]), read for [app]: the installers
/// answer not_loaded before that. Made inside a widget test, never in setUp (see the top of this file).
Future<InstalledPlugins> installedFor(AppState app, Directory root, {List<String>? keys, bool storeAllowed = true, bool devAllowed = true, HttpClient Function()? http}) async {
  final installed = InstalledPlugins(root: root, reviewKeys: keys ?? [reviewKey], storeAllowed: storeAllowed, devAllowed: devAllowed, http: http);
  await installed.load(app, appVersion: appVersion);
  return installed;
}

/// [pack] added from the Marketplace for real: its canonical bytes and its approval by [by] (the tests' reviewer),
/// switched [on]. Throws where the installer refuses it, saying why.
Future<PackOutcome> addStore(InstalledPlugins installed, PluginPack pack, {bool on = true, NetSigner? by}) async {
  final out = await installed.installReviewed(packBytes(pack), await approvalOf(pack, by: by), listing: const {'listedAt': 1763600000000}, on: on);
  if (!out.ok) throw StateError('${pack.id} wasn\'t added: ${out.code}: ${out.message}');
  return out;
}

/// [pack] loaded in development for real, as pasting it would load it (or from [source]); [agree] switches it on as
/// its consent sheet would. Developer mode must be on in the app [installed] was read for. Throws where it isn't loaded.
Future<PackOutcome> addDev(InstalledPlugins installed, PluginPack pack, {DevSource source = const DevSource('paste'), bool agree = false}) async {
  final out = await installed.loadDev(packBytes(pack), source);
  if (!out.ok) throw StateError('${pack.id} wasn\'t loaded: ${out.code}: ${out.message}');
  if (agree) await installed.agreeDev(pack.id);
  return out;
}

/// [pack] withdrawn by the tests' reviewer, [why] its signed reason, handed over as the revoked list would hand it.
Future<PackRevocation> withdraw(InstalledPlugins installed, PluginPack pack, String why) async {
  final r = await signRevocation(reviewer, plugin: pack.id, sha256: sha256Hex(packBytes(pack)), why: why);
  await installed.takeRevocations({'revoked': [r.toJson()], 'retired': const []});
  return r;
}

/// [by]'s key retired by its own signature, handed over as the revoked list would hand it: what it approved stops
/// running, and whatever it signs is no longer a review here.
Future<void> retire(InstalledPlugins installed, NetSigner by) async {
  final r = await signRetirement(by);
  await installed.takeRevocations({'revoked': const [], 'retired': [r.toJson()]});
}

/// One request the relay was asked.
typedef FakeRequest = ({String method, Uri url, Map<String, String> headers, List<int> body});

/// The relay, answered from memory: the catalog, the revoked list, the packages and screenshots by SHA-256, and
/// whatever a test sets in [answers] by path. Every request is kept in [asked], and how many were in flight at once.
class FakeRelay {
  final asked = <FakeRequest>[];
  Catalog catalog = const Catalog();
  final packages = <String, Uint8List>{};
  final shots = <String, Uint8List>{};
  Map<String, Object?> revoked = const {'ok': true, 'v': 1, 'at': 0, 'revoked': [], 'retired': []};

  /// The revoked list one host answers in place of [revoked] (Uplink's own, read beside another market).
  final revokedOf = <String, Map<String, Object?>>{};
  final answers = <String, ({int status, Object? body})>{};

  /// A catalog's bytes in place of the one above (a test's too large one).
  Uint8List? catalogBytes;
  int inFlight = 0, mostInFlight = 0;

  /// Unreachable: every request fails as a socket would.
  bool down = false;

  /// While set, packages are answered only once it completes: a refresh caught while it checks.
  Future<void>? hold;

  /// Lists [pack] with its package, as an approved plugin is: its entry [entry], else one the tests' reviewer signed.
  Future<CatalogEntry> list(PluginPack pack, {CatalogEntry? entry}) async {
    final e = entry ?? await entryOf(pack);
    catalog = Catalog(plugins: [...catalog.plugins.where((p) => p.id != e.id), e]);
    packages[e.sha256] = packBytes(pack);
    return e;
  }

  static ({int status, Map<String, String> headers, Uint8List body}) _json(int status, Object? body) => (status: status, headers: const {'content-type': 'application/json'}, body: utf8.encode(jsonEncode(body)));

  Future<({int status, Map<String, String> headers, Uint8List body})> call(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
    asked.add((method: method, url: url, headers: headers, body: body));
    if (down) throw const SocketException('down');
    final path = url.path;
    final own = answers['$method $path'];
    if (own != null) return _json(own.status, own.body);
    if (path.endsWith('/market/catalog')) {
      if (catalogBytes != null) return (status: 200, headers: const <String, String>{}, body: catalogBytes!);
      return _json(200, {'ok': true, ...catalog.toJson()});
    }
    if (path.endsWith('/market/revoked')) return _json(200, revokedOf[url.host] ?? revoked);
    final package = RegExp(r'/market/packages/([0-9a-f]{64})$').firstMatch(path);
    if (package != null) {
      inFlight++;
      if (inFlight > mostInFlight) mostInFlight = inFlight;
      // A turn of the event loop, so the other fetches can start before this one ends.
      await Future<void>.delayed(Duration.zero);
      final held = hold;
      if (held != null) await held;
      inFlight--;
      final bytes = packages[package.group(1)];
      return bytes == null ? _json(404, {'ok': false, 'error': 'not_found', 'message': 'There\'s nothing here by that name.'}) : (status: 200, headers: const <String, String>{}, body: bytes);
    }
    final shot = RegExp(r'/market/shots/([0-9a-f]{64})$').firstMatch(path);
    if (shot != null) {
      final bytes = shots[shot.group(1)];
      return bytes == null ? _json(404, {'ok': false, 'error': 'not_found', 'message': 'There\'s nothing here by that name.'}) : (status: 200, headers: const <String, String>{}, body: bytes);
    }
    if (path.endsWith('/market/report')) return _json(201, {'ok': true, 'id': '0123456789abcdef'});
    final kept = store.answer(method, path, headers, body);
    if (kept != null) return kept.bytes != null ? (status: kept.status, headers: const <String, String>{}, body: kept.bytes!) : _json(kept.status, kept.body);
    return _json(404, {'ok': false, 'error': 'not_found', 'message': 'There\'s nothing here by that name.'});
  }

  /// The developers' and the reviewer's routes (8 to 21), answered from memory.
  final store = FakeMarketStore();

  /// The paths asked for, in order.
  List<String> get paths => [for (final r in asked) '${r.method} ${r.url}'];
}

/// A MarketState over [relay], its cache in [cache], reading the device's packs from [installed] (else whatever
/// InstalledPlugins.instance is when it asks, so a test can put its own in place after this is made), checking
/// approvals with the runtime's own verifyApproval ([verify] may wrap it, to count).
MarketState marketOver(FakeRelay relay, Directory cache, {InstalledPlugins? installed, DateTime Function()? now, NetSigner? signer, MarketVerify? verify}) {
  final api = MarketApi(hubUrl: 'https://relay.test', signer: signer ?? devSigner, transport: relay.call, now: now);
  return MarketState(api: () => api, cache: cache, installed: installed, now: now, verify: verify, appVersion: appVersion);
}

/// The Marketplace's submissions, plugins, reports and review as a relay would keep them (SPEC C.4 to C.6), in memory:
/// enough of the relay for the submission form, My submissions and the review screens to run against.
class FakeMarketStore {
  final submissions = <String, Map<String, Object?>>{};
  final plugins = <String, Map<String, Object?>>{};
  final reports = <String, Map<String, Object?>>{};
  final shotBytes = <String, Uint8List>{};

  /// What each decision, listing, revocation and block asked, in order.
  final decided = <Map<String, Object?>>[];

  /// Who sent the submissions, as the relay names them, and whether they're verified, blocked or signed in as the admin.
  String developerId = 'd' * 32;
  bool verified = true, blocked = false, admin = true;

  /// Who route 17 says took a plugin off: the developer from My submissions, the admin from the review.
  String unlistedBy = 'owner';

  /// What the next check (route 8 with `check: true`) and the next submit answer, where not ok.
  ({int status, Map<String, Object?> body})? checkRefusal, submitRefusal;

  /// What the next decision answers, where not ok (a `not_admin`, then the real answer).
  final decideRefusals = <({int status, Map<String, Object?> body})>[];
  int checks = 0;
  int _n = 0;
  int now = 1763600000000;

  static String _hex(int n, int width) => n.toRadixString(16).padLeft(width, '0');

  /// A submission put in place as if it had been sent: [package] the pack's canonical bytes.
  String put(Uint8List package, {String status = 'submitted', List<Uint8List> shots = const [], String notes = '', String list = 'now', List<Map<String, Object?>> reviewerNotes = const []}) {
    final pack = (jsonDecode(utf8.decode(package)) as Map).cast<String, Object?>();
    final sid = _hex(++_n, 24);
    final shas = <String>[];
    for (final b in shots) {
      final sha = sha256Hex(b);
      shotBytes[sha] = b;
      shas.add(sha);
    }
    submissions[sid] = {
      'sid': sid, 'plugin': pack['id'], 'version': pack['version'], 'sha256': sha256Hex(package), 'size': package.length, 'status': status,
      'name': pack['name'], 'tagline': pack['tagline'], 'description': pack['description'], 'symbol': pack['symbol'] ?? 'puzzle', 'hue': pack['hue'], 'shelf': pack['shelf'],
      'labels': pack['labels'] ?? const [], 'permissions': pack['permissions'] ?? const [], 'links': pack['links'] ?? const [], 'developer': pack['developer'], 'support': pack['support'], 'whatsNew': pack['whatsNew'], 'minApp': pack['minApp'],
      'submittedAt': now + _n, 'updatedAt': now + _n,
      'notes': [if (notes.isNotEmpty) {'at': now + _n, 'by': 'developer', 'text': notes, 'status': null}, ...reviewerNotes],
      'shots': [for (final sha in shas) {'sha256': sha, 'mime': 'image/png'}], 'list': list, 'listing': null, 'revoked': null,
      'package': base64Encode(package),
    };
    plugins.putIfAbsent(pack['id'] as String, () => {'id': pack['id'], 'listing': 'none', 'current': null, 'by': null, 'note': null, 'noteAt': null});
    if (status == 'approved') _approve(sid);
    return sid;
  }

  void _approve(String sid) {
    final s = submissions[sid]!;
    final p = plugins[s['plugin']]!;
    // The version before stops being current, and its listing with it.
    for (final other in submissions.values) {
      if (other['plugin'] == s['plugin'] && other['sid'] != sid) other['listing'] = null;
    }
    s['status'] = 'approved';
    final listed = s['list'] == 'now' && p['by'] != 'owner';
    s['listing'] = listed ? 'listed' : 'unlisted';
    p['current'] = s['version'];
    p['listing'] = listed ? 'listed' : 'unlisted';
    p['by'] = listed ? null : 'owner';
  }

  Map<String, Object?> _view(Map<String, Object?> s) => {for (final e in s.entries) if (e.key != 'package') e.key: e.value};

  Map<String, Object?> _row(Map<String, Object?> s) {
    final current = submissions.values.where((x) => x['plugin'] == s['plugin'] && x['listing'] != null && x['sid'] != s['sid']).firstOrNull;
    final had = {...?(current?['permissions'] as List?)?.cast<String>()};
    return {
      ..._view(s),
      'developerId': developerId, 'verified': verified, 'blocked': blocked,
      'isUpdate': current != null || (s['listing'] == null && plugins[s['plugin']]?['current'] != null && s['status'] != 'approved'),
      'newPermissions': current == null ? const <String>[] : [for (final p in (s['permissions'] as List).cast<String>()) if (!had.contains(p)) p],
      'again': submissions.values.any((x) => x['plugin'] == s['plugin'] && x['sid'] != s['sid'] && ((x['notes'] as List).any((n) => (n as Map)['by'] == 'reviewer'))),
    };
  }

  static const _notAdmin = {'ok': false, 'error': 'not_admin', 'message': 'Sign in on Settings › Admin again to do that.'};
  static const _notFound = {'ok': false, 'error': 'not_found', 'message': 'There\'s nothing here by that name.'};

  /// The answer to one request, or null where it isn't one of these routes.
  ({int status, Object? body, Uint8List? bytes})? answer(String method, String path, Map<String, String> headers, List<int> body) {
    ({int status, Object? body, Uint8List? bytes}) json(int status, Object? b) => (status: status, body: b, bytes: null);
    Map<String, Object?> read() => body.isEmpty ? const {} : (jsonDecode(utf8.decode(body)) as Map).cast<String, Object?>();
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty || parts.first != 'market') return null;
    final rest = parts.sublist(1);
    // Route 8: a check, or a submission.
    if (method == 'POST' && rest.length == 1 && rest[0] == 'submissions') {
      final j = read();
      if (j['check'] == true) {
        checks++;
        final r = checkRefusal;
        return r == null ? json(200, {'ok': true, 'checked': true}) : json(r.status, r.body);
      }
      final refused = submitRefusal;
      if (refused != null) return json(refused.status, refused.body);
      if (blocked) return json(403, {'ok': false, 'error': 'blocked', 'message': 'This account can\'t submit plugins.'});
      final package = base64Decode(j['package'] as String);
      final shots = <Uint8List>[];
      final keptShas = <String>[];
      for (final s in (j['shots'] as List? ?? const [])) {
        final m = s as Map;
        if (m['keep'] is String) {
          keptShas.add(m['keep'] as String);
        } else {
          shots.add(base64Decode(m['data'] as String));
        }
      }
      // Earlier open submissions of the plugin are replaced by this one.
      final id = (jsonDecode(utf8.decode(package)) as Map)['id'];
      for (final s in submissions.values) {
        if (s['plugin'] == id && (s['status'] == 'submitted' || s['status'] == 'in_review' || s['status'] == 'changes_requested')) s['status'] = 'superseded';
      }
      final sid = put(package, shots: shots, notes: '${j['notes'] ?? ''}', list: '${j['list'] ?? 'now'}');
      // Kept screenshots in the order the package names them.
      final names = ((jsonDecode(utf8.decode(package)) as Map)['shots'] as List? ?? const []).cast<String>();
      submissions[sid]!['shots'] = [for (final sha in names) if (shotBytes.containsKey(sha) || keptShas.contains(sha)) {'sha256': sha, 'mime': 'image/png'}];
      return json(201, {'ok': true, 'submission': _view(submissions[sid]!)});
    }
    if (method == 'GET' && rest.length == 1 && rest[0] == 'mine') {
      final mine = submissions.values.toList()..sort((a, b) => (b['submittedAt'] as int).compareTo(a['submittedAt'] as int));
      return json(200, {'ok': true, 'blocked': blocked, 'submissions': [for (final s in mine) _view(s)], 'plugins': plugins.values.toList()});
    }
    if (rest.length >= 2 && rest[0] == 'submissions') {
      final s = submissions[rest[1]];
      if (s == null) return json(404, _notFound);
      if (rest.length == 2 && method == 'GET') return json(200, {'ok': true, 'submission': _view(s)});
      if (rest.length == 2 && method == 'DELETE') {
        s['status'] = 'withdrawn';
        decided.add({'withdraw': s['sid']});
        return json(200, {'ok': true, 'submission': _view(s)});
      }
      if (rest.length == 3 && rest[2] == 'package') return (status: 200, body: null, bytes: base64Decode(s['package'] as String));
      if (rest.length == 4 && rest[2] == 'shots') {
        final n = int.tryParse(rest[3]) ?? -1;
        final shots = s['shots'] as List;
        if (n < 0 || n >= shots.length) return json(404, _notFound);
        final bytes = shotBytes[(shots[n] as Map)['sha256']];
        return bytes == null ? json(404, _notFound) : (status: 200, body: null, bytes: bytes);
      }
    }
    // The review: the admin's alone.
    final review = rest.isNotEmpty && (rest[0] == 'review' || rest[0] == 'reports' || rest[0] == 'developers' || (rest[0] == 'plugins' && rest.length == 3 && rest[2] == 'revoke'));
    if (review && !admin) return json(403, _notAdmin);
    if (method == 'GET' && rest.length == 1 && rest[0] == 'review') {
      final all = submissions.values.toList()..sort((a, b) => (a['submittedAt'] as int).compareTo(b['submittedAt'] as int));
      final open = [for (final s in all) if (s['status'] == 'submitted' || s['status'] == 'in_review' || s['status'] == 'changes_requested') _row(s)];
      final recent = [for (final s in all.reversed) if (!(s['status'] == 'submitted' || s['status'] == 'in_review' || s['status'] == 'changes_requested')) _row(s)];
      int count(String st) => all.where((s) => s['status'] == st).length;
      return json(200, {'ok': true, 'open': open, 'recent': recent, 'counts': {'submitted': count('submitted'), 'in_review': count('in_review'), 'changes_requested': count('changes_requested'), 'reports': reports.values.where((r) => r['done'] != true).length}});
    }
    if (rest.length == 2 && rest[0] == 'review') {
      final s = submissions[rest[1]];
      if (s == null) return json(404, _notFound);
      if (method == 'GET') {
        final current = submissions.values.where((x) => x['plugin'] == s['plugin'] && x['listing'] != null && x['sid'] != s['sid']).firstOrNull;
        final asked = (submissions.values.toList()..sort((a, b) => (b['submittedAt'] as int).compareTo(a['submittedAt'] as int)))
            .where((x) => x['plugin'] == s['plugin'] && x['sid'] != s['sid'] && (x['notes'] as List).any((n) => (n as Map)['by'] == 'reviewer'))
            .firstOrNull;
        return json(200, {
          'ok': true,
          'submission': _row(s),
          'package': s['package'],
          'previous': current == null ? null : {'version': current['version'], 'sha256': current['sha256'], 'package': current['package']},
          'asked': asked == null ? null : {'sid': asked['sid'], 'version': asked['version'], 'sha256': asked['sha256'], 'package': asked['package'], 'note': ((asked['notes'] as List).lastWhere((n) => (n as Map)['by'] == 'reviewer') as Map)['text'], 'status': asked['status']},
          'history': [for (final x in submissions.values) if (x['plugin'] == s['plugin'] && x['sid'] != s['sid']) _view(x)],
          'developer': {'id': developerId, 'username': s['developer'], 'blocked': blocked, 'plugins': plugins.length, 'submissions': submissions.length, 'firstAt': now},
        });
      }
      if (method == 'POST') {
        if (decideRefusals.isNotEmpty) {
          final r = decideRefusals.removeAt(0);
          decided.add({'refused': r.body['error'], ...read()});
          return json(r.status, r.body);
        }
        final d = read();
        decided.add({'sid': s['sid'], 'key': headers['x-ghost-key'], ...d});
        final decision = d['decision'];
        final note = d['note'];
        void noted(String status) => (s['notes'] as List).add({'at': now, 'by': 'reviewer', 'text': note ?? '', 'status': status});
        switch (decision) {
          case 'start':
            s['status'] = 'in_review';
          case 'approve':
            final a = d['approval'] as Map;
            if (a['key'] != headers['x-ghost-key'] || a['sha256'] != s['sha256'] || a['plugin'] != s['plugin'] || a['version'] != s['version']) return json(400, {'ok': false, 'error': 'bad_approval', 'message': 'The approval\'s signature or its words don\'t match this plugin.'});
            _approve(s['sid'] as String);
            for (final r in (d['revokes'] as List? ?? const [])) {
              final sha = (r as Map)['sha256'];
              for (final x in submissions.values) {
                if (x['sha256'] == sha) x['revoked'] = {'at': r['at'], 'why': r['why']};
              }
            }
            if (note is String && note.isNotEmpty) noted('approved');
          case 'changes' || 'reject':
            if (note is! String || note.isEmpty) return json(400, {'ok': false, 'error': 'bad_request', 'message': 'Something in that isn\'t right.'});
            s['status'] = decision == 'changes' ? 'changes_requested' : 'rejected';
            noted(s['status'] as String);
        }
        return json(200, {'ok': true, 'submission': _row(s)});
      }
    }
    if (method == 'POST' && rest.length == 3 && rest[0] == 'plugins') {
      final p = plugins[rest[1]];
      if (p == null) return json(404, _notFound);
      final d = read();
      decided.add({'plugin': rest[1], 'route': rest[2], ...d});
      if (rest[2] == 'listing') {
        final listed = d['listed'] == true;
        p['listing'] = listed ? 'listed' : 'unlisted';
        p['by'] = listed ? null : unlistedBy;
        p['note'] = d['note'];
        for (final s in submissions.values) {
          if (s['plugin'] == rest[1] && s['listing'] != null) s['listing'] = p['listing'];
        }
        return json(200, {'ok': true, 'plugin': p});
      }
      if (rest[2] == 'revoke') {
        for (final s in submissions.values) {
          if (s['sha256'] == d['sha256']) s['revoked'] = {'at': d['at'], 'why': d['why']};
        }
        return json(200, {'ok': true, 'revoked': d, 'plugin': p});
      }
    }
    if (method == 'GET' && rest.length == 1 && rest[0] == 'reports') return json(200, {'ok': true, 'reports': reports.values.toList()});
    if (method == 'POST' && rest.length == 2 && rest[0] == 'reports') {
      final r = reports[rest[1]];
      if (r == null) return json(404, _notFound);
      r['done'] = true;
      r['doneAt'] = now;
      decided.add({'resolved': rest[1]});
      return json(200, {'ok': true});
    }
    if (method == 'POST' && rest.length == 3 && rest[0] == 'developers' && rest[2] == 'block') {
      final d = read();
      decided.add({'block': rest[1], ...d});
      blocked = d['blocked'] == true;
      return json(200, {'ok': true, 'developer': {'id': rest[1], 'username': 'maya', 'blocked': blocked, 'plugins': plugins.length, 'submissions': submissions.length, 'firstAt': now}});
    }
    return null;
  }
}
