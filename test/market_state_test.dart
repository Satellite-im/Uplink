import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/market/listing_plugin.dart';
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_models.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/market/png_view.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/codes.dart';

import 'support/market_fakes.dart';

/// The Marketplace as the device knows it (lib/market/market_state.dart; Matt, 2026-11-20: "I would like users to be
/// able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for
/// the store through a review process"): what the relay sends is bounded, every listed package is fetched and checked
/// before it is a listing, the withdrawals are read from Uplink's own relay too, signatures that verified are
/// not checked again, and the catalog's three problems. The packs, their approvals and the installer are the
/// runtime's own (lib/plugins/pack); only the relay is made up (test/support/market_fakes.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeRelay relay;
  late AppState app;
  late InstalledPlugins installed;
  final logged = <String>[];
  final oldRegistry = PluginRegistry.instance;
  var verified = 0;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('market-state-');
    relay = FakeRelay();
    PluginRegistry.instance = PluginRegistry([const CodesPlugin()]);
    logged.clear();
    verified = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      if (call.method == 'devLog') logged.add('${(call.arguments as Map)['tag']} ${(call.arguments as Map)['line']}');
      return null;
    });
    app = AppState();
    installed = await installedFor(app, Directory('${dir.path}/plugins'));
  });
  tearDown(() {
    PluginRegistry.instance = oldRegistry;
    MarketState.verifyInIsolate = false;
    dir.deleteSync(recursive: true);
  });

  /// The runtime's own check of each approval, counted.
  Future<List<bool>> counted(List<ApprovalCheck> checks) {
    verified += checks.length;
    return MarketState.verifyApprovals(checks);
  }

  MarketState market({InstalledPlugins? on}) => marketOver(relay, Directory('${dir.path}/market'), installed: on ?? installed, verify: counted);

  test('a catalog of 9 MiB is too large, and the app keeps answering', () async {
    relay.catalogBytes = Uint8List(9 * 1024 * 1024)..fillRange(0, 9 * 1024 * 1024, 0x20);
    final api = MarketApi(hubUrl: 'https://relay.test', transport: relay.call);
    await expectLater(api.catalog(), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'too_large')));
    final m = market();
    await m.refresh(force: true);
    expect(m.problem?.code, 'unreachable', reason: 'nothing was kept from before');
    // The next answer is read as ever.
    relay.catalogBytes = null;
    await relay.list(billsPack());
    expect((await api.catalog())!.plugins.single.id, 'bills');
    await m.refresh(force: true);
    expect(m.problem, isNull);
    expect([for (final l in m.listings) l.id], ['xbills']);
  });

  test('a catalog of 2,001 entries is refused', () async {
    final e = await entryOf(billsPack());
    relay.catalog = Catalog(plugins: List.filled(2001, e));
    final api = MarketApi(hubUrl: 'https://relay.test', transport: relay.call);
    await expectLater(api.catalog(), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'too_large')));
    relay.catalog = Catalog(plugins: List.filled(2000, e));
    expect((await api.catalog())!.plugins, hasLength(2000));
  });

  test('the withdrawals are read from Uplink\'s own relay too, where the market is another, and each is checked', () async {
    final bills = billsPack();
    await addStore(installed, bills);
    final good = await signRevocation(reviewer, plugin: 'bills', sha256: sha256Hex(packBytes(bills)), why: 'It copied texts it shouldn\'t have');
    final forged = await signRevocation(KeysSigner(NetKeys.generate()), plugin: 'bills', sha256: 'f' * 64, why: 'Nobody pinned signed this');
    // The market's own relay keeps it back; Uplink's says it.
    relay.revokedOf['gogho.st'] = {'ok': true, 'v': 1, 'at': 0, 'revoked': [good.toJson(), forged.toJson()], 'retired': []};
    final m = market();
    await m.refresh(force: true);
    expect(relay.paths, containsAll(['GET https://relay.test/market/revoked', 'GET https://gogho.st/market/revoked']));
    expect([for (final r in installed.revocations) r.why], ['It copied texts it shouldn\'t have'], reason: 'only what a pinned key signed is kept');
    expect(installed.storeOf('bills')!.problem, 'revoked');
    expect(PluginRegistry.instance.plugins.any((p) => p.id == 'xbills'), isFalse, reason: 'withdrawn, it is off');
  });

  test('a withdrawals list longer than 1 MiB and 5,000 is read whole, and its newest withdrawal is taken', () async {
    // The app read 1 MiB and 5,000 at most and refused a longer list whole, taking nothing, while the relay kept adding to
    // it: past some 3,200 withdrawals none reached a device but by a release (review, 2026-11-20).
    final bills = billsPack();
    await addStore(installed, bills);
    final junkKey = base64Encode(KeysSigner(NetKeys.generate()).publicKey);
    Map<String, Object?> old(int i) => {'v': 1, 'plugin': 'old$i', 'sha256': sha256Hex(utf8.encode('$i')), 'at': i, 'why': 'Withdrawn long ago, for reasons of its own: $i.', 'key': junkKey, 'sig': base64Encode(List.filled(64, 1))};
    final newest = await signRevocation(reviewer, plugin: 'bills', sha256: sha256Hex(packBytes(bills)), why: 'It marked bank texts read');
    final list = {'ok': true, 'v': 1, 'at': 0, 'revoked': [for (var i = 0; i < 6000; i++) old(i), newest.toJson()], 'retired': const []};
    expect(utf8.encode(jsonEncode(list)).length, greaterThan(1024 * 1024));
    relay.revoked = list;
    final m = market();
    await m.refresh(force: true);
    expect(logged.where((l) => l.contains('revoked')), isNot(contains(contains('too_large'))));
    expect(installed.storeOf('bills')!.problem, 'revoked', reason: 'the newest withdrawal, at the end of a list of 6,001');
  });

  test('a listing is only what checked out: its package\'s hash, its id and version, its approval, not withdrawn', () async {
    final bills = billsPack();
    final parcels = billsPack(id: 'parcels', name: 'Parcels');
    final unsigned = billsPack(id: 'receipts', name: 'Receipts');
    final pulled = billsPack(id: 'tickets', name: 'Tickets');
    await relay.list(bills);
    // An entry for "lookalike" whose package is Parcels': its approval, the reviewer's own, is for lookalike, and the
    // bytes are another plugin's.
    await relay.list(parcels, entry: await entryOf(parcels, approvedId: 'lookalike'));
    await relay.list(unsigned, entry: await entryOf(unsigned, forged: true));
    await relay.list(pulled);
    await withdraw(installed, pulled, 'Pulled by the review');
    final m = market();
    await m.refresh(force: true);
    expect([for (final l in m.listings) l.id], ['xbills']);
    expect(logged, contains('market lookalike left out: listing_mismatch'));
    expect(logged, contains('market receipts left out: bad_approval'));
    expect(logged, contains('market tickets left out: revoked'));
    expect(m.problem, isNull);
    // Drawn from its package alone.
    final l = m.listings.single;
    expect(l.name, 'Bills');
    expect(l.developer, 'maya');
    expect(l.reaches.first.label, 'Reads texts from numbers not in your contacts');
    expect(l.iconPng, billsIcon);
  });

  test('a signature that verified is not checked again, even by a new start; in the app, on an isolate of its own', () async {
    await relay.list(billsPack());
    // As the app checks them: on an isolate.
    MarketState.verifyInIsolate = true;
    await market().refresh(force: true);
    expect(verified, 1);
    final again = market();
    await again.refresh(force: true);
    expect(again.listings, hasLength(1));
    expect(verified, 1, reason: 'verified.json spared it');
    expect(File('${dir.path}/market/verified.json').existsSync(), isTrue);
  });

  test('the catalog\'s problems: unreachable, off and untrusted', () async {
    relay.down = true;
    final m = market();
    await m.refresh(force: true);
    expect(m.problem?.code, 'unreachable');
    relay.down = false;
    relay.answers['GET /market/catalog'] = (status: 503, body: {'ok': false, 'error': 'off', 'message': 'The Marketplace isn\'t open on this server.'});
    await m.refresh(force: true);
    expect(m.problem?.code, 'off');
    relay.answers.clear();
    final bills = billsPack();
    await relay.list(bills, entry: await entryOf(bills, by: KeysSigner(NetKeys.generate())));
    await m.refresh(force: true);
    expect(m.problem?.code, 'untrusted', reason: 'an entry, and its approval is by a key this build doesn\'t pin');
    expect(m.listings, isEmpty);
    // A build that pins no key at all (marketReviewKeys before Matt gives his) trusts none.
    final none = await installedFor(AppState(), Directory('${dir.path}/none'), keys: const []);
    await relay.list(bills);
    final m2 = market(on: none);
    await m2.refresh(force: true);
    expect(m2.problem?.code, 'untrusted');
    expect(relay.paths.where((p) => p.contains('/packages/')), isEmpty, reason: 'nothing is fetched that couldn\'t verify');
    // Unreachable once something is kept: what was kept is still shown.
    final m3 = market();
    await m3.refresh(force: true);
    expect(m3.listings, hasLength(1));
    relay.down = true;
    await m3.refresh(force: true);
    expect(m3.problem, isNull);
    expect(m3.listings, hasLength(1));
  });

  test('an approval is checked before its package is fetched: signatures that don\'t hold cost a fetch, a write and a read nothing', () async {
    // A relay broken into could list 200 entries a refresh naming the pinned key with junk signatures, each package made
    // to be slow to read: every one was downloaded, kept on disk and parsed on the UI isolate (review, 2026-11-20).
    final good = billsPack();
    await relay.list(good);
    for (var i = 0; i < 6; i++) {
      final junk = billsPack(id: 'junk$i', name: 'Junk $i');
      await relay.list(junk, entry: await entryOf(junk, forged: true));
    }
    final m = market();
    await m.refresh(force: true);
    expect([for (final l in m.listings) l.id], ['xbills']);
    final fetched = [for (final p in relay.paths) if (p.contains('/packages/')) p];
    expect(fetched, [contains(sha256Hex(packBytes(good)))], reason: 'only the one whose signature holds');
    expect(verified, 7, reason: 'each signature checked once');
    for (var i = 0; i < 6; i++) {
      expect(logged, contains('market junk$i left out: bad_approval'));
    }
    final kept = Directory('${dir.path}/market/packages');
    expect([for (final f in kept.listSync()) f.uri.pathSegments.last], [sha256Hex(packBytes(good))], reason: 'only a listing\'s package is kept on disk');
    expect(m.problem, isNull);
    // In the app, read on an isolate of its own.
    MarketState.verifyInIsolate = true;
    await relay.list(billsPack(id: 'parcels', name: 'Parcels'));
    await m.refresh(force: true);
    expect([for (final l in m.listings) l.id]..sort(), ['xbills', 'xparcels']);
  });

  test('an update that needs a newer Uplink isn\'t offered until the app is updated', () async {
    // Counted on the ring and offered on Updates and its page, it was refused at every press (review, 2026-11-20).
    await addStore(installed, billsPack());
    await relay.list(billsPack(version: '1.1.0', minApp: '9.0.0'));
    final m = market();
    await m.refresh(force: true);
    expect(m.listings.single.needsNewerApp, isTrue);
    expect(m.updates, isEmpty);
    await relay.list(billsPack(version: '1.1.0', minApp: '0.10.1'));
    await m.refresh(force: true);
    expect([for (final u in m.updates) u.listing.version], ['1.1.0']);
  });

  test('packages are fetched four at a time', () async {
    for (var i = 0; i < 10; i++) {
      final p = billsPack(id: 'pack$i', name: 'Pack $i');
      await relay.list(p, entry: await entryOf(p, updatedAt: 1763600000000 + i));
    }
    final m = market();
    await m.refresh(force: true);
    expect(relay.mostInFlight, 4);
    expect(m.listings, hasLength(10));
    expect(m.listings.first.id, 'xpack9', reason: 'the newest change first');
    expect(m.checking, 0);
  });

  test('updates: a newer listing by the same developer; by another, a new plugin', () async {
    await addStore(installed, billsPack());
    await relay.list(billsPack(version: '1.1.0', whatsNew: 'Receipts in a kind of their own.'));
    final m = market();
    await m.refresh(force: true);
    expect([for (final u in m.updates) '${u.installed.version} → ${u.listing.version}'], ['1.0.0 → 1.1.0']);
    expect(m.developerChanged('bills'), isNull);
    await relay.list(billsPack(version: '1.2.0', developer: 'someoneelse'));
    await m.refresh(force: true);
    expect(m.updates, isEmpty, reason: 'never an update by another developer');
    expect(m.developerChanged('bills')?.developer, 'someoneelse');
  });

  test('a copy here that no longer parses: an update only where it can be told whose it is, else a new plugin', () async {
    // Its developer was read from its pack alone, so a stuck copy counted as anyone's and another developer's version
    // was offered as its Update (review, 2026-11-20).
    await addStore(installed, billsPack());
    final file = File('${dir.path}/plugins/store/bills/1.0.0/package.ghostplugin');
    file.writeAsBytesSync([...file.readAsBytesSync(), 0x20]);
    var here = await installedFor(app, Directory('${dir.path}/plugins'));
    expect([here.storeOf('bills')!.problem, here.storeOf('bills')!.pack, here.storeOf('bills')!.developer], ['bad_approval', null, 'maya'], reason: 'from listing.json');
    await relay.list(billsPack(version: '1.1.0'));
    var m = market(on: here);
    await m.refresh(force: true);
    expect([for (final u in m.updates) '${u.installed.version} → ${u.listing.version}'], ['1.0.0 → 1.1.0']);
    expect(m.developerChanged('bills'), isNull);
    await relay.list(billsPack(version: '1.2.0', developer: 'mallory'));
    await m.refresh(force: true);
    expect(m.updates, isEmpty);
    expect(m.developerChanged('bills')?.developer, 'mallory');
    // Nothing here says whose it is: never an update, even one that says it is hers.
    final listing = File('${dir.path}/plugins/store/bills/1.0.0/listing.json');
    listing.writeAsBytesSync(canonicalBytes((jsonDecode(listing.readAsStringSync()) as Map).cast<String, Object?>()..remove('developer')));
    file.writeAsStringSync('{"rules": ');
    here = await installedFor(app, Directory('${dir.path}/plugins'));
    expect(here.storeOf('bills')!.developer, isNull);
    await relay.list(billsPack(version: '1.3.0'));
    m = market(on: here);
    await m.refresh(force: true);
    expect(m.updates, isEmpty);
    expect(m.developerChanged('bills')?.version, '1.3.0', reason: 'offered as a new plugin, Add removing the copy here first');
    expect(StuckPackPlugin(here.storeOf('bills')!).developer, isNull);
  });

  test('install hands the checked bytes to the installer with the approval, switched on; update leaves the switch', () async {
    final bills = billsPack();
    final entry = await relay.list(bills);
    final m = market();
    await m.refresh(force: true);
    final out = await m.install(m.listings.single);
    expect(out.ok, isTrue, reason: out.message);
    final here = installed.storeOf('bills')!;
    expect(File('${dir.path}/plugins/store/bills/1.0.0/package.ghostplugin').readAsBytesSync(), packBytes(bills), reason: 'the bytes that were checked');
    expect(here.approval!.toJson(), entry.approval.toJson());
    expect(here.listing['listedAt'], 1763600000000);
    expect(app.flag('plugin_xbills', fallback: false), isTrue);
    // Switched off, then updated: still off, the new version in the old one's place.
    app.set('plugin_xbills', 'off');
    await relay.list(billsPack(version: '1.1.0'));
    await m.refresh(force: true);
    final update = await m.update(m.updates.single.listing);
    expect(update.ok, isTrue, reason: update.message);
    expect(installed.storeOf('bills')!.version, '1.1.0');
    expect(app.choice('plugin_xbills', ''), 'off');
    expect(m.updates, isEmpty);
  });

  test('the developer hears of each decision once, never of what was there the first time', () async {
    Map<String, Object?> mine(String status, {String? listing}) => {'ok': true, 'blocked': false, 'submissions': [{'sid': 'a' * 24, 'plugin': 'bills', 'version': '1.0.0', 'name': 'Bills', 'status': status, 'list': 'now', 'listing': ?listing}], 'plugins': []};
    final m = market();
    final told = <String>[];
    final sub = m.notices.listen((n) => told.add(n.words));
    addTearDown(sub.cancel);
    relay.answers['GET /market/mine'] = (status: 200, body: mine('submitted'));
    await m.readMine();
    await pumpEventQueue();
    expect(told, isEmpty, reason: 'the first read only records');
    relay.answers['GET /market/mine'] = (status: 200, body: mine('changes_requested'));
    await m.readMine();
    await m.readMine();
    await pumpEventQueue();
    expect(told, ['Bills 1.0.0: changes asked for. See Marketplace › My submissions.']);
    relay.answers['GET /market/mine'] = (status: 200, body: mine('approved', listing: 'listed'));
    await m.readMine();
    await pumpEventQueue();
    expect(told.last, 'Bills 1.0.0 was approved and is listed.');
    expect(m.mine?.submissions.single.status, 'approved');
    // A submission still waiting asks for mine() at each refresh.
    relay.answers['GET /market/mine'] = (status: 200, body: mine('submitted'));
    await m.readMine();
    relay.asked.clear();
    await m.refresh(force: true);
    expect(relay.paths, contains('GET https://relay.test/market/mine'));
  });

  test('a draft is kept on disk with its screenshots, and goes once sent', () async {
    final m = market();
    await m.saveDraft(SubmitDraft(packId: 'bills', name: 'Bills, mine', changed: const {'name', 'shots'}, shots: [DraftShot(bytes: billsIcon), const DraftShot(keep: 'f00d')]));
    expect(m.draftOf('bills')?.name, 'Bills, mine');
    expect(File('${dir.path}/market/drafts/bills/shot-0.png').readAsBytesSync(), billsIcon);
    final later = market();
    expect(later.draftOf('bills'), isNull);
    await later.loadDrafts();
    final d = later.draftOf('bills')!;
    expect(d.changed, {'name', 'shots'});
    expect(d.shots.first.bytes, billsIcon);
    expect(d.shots.last.keep, 'f00d');
    await later.dropDraft('bills');
    expect(later.draftOf('bills'), isNull);
    expect(Directory('${dir.path}/market/drafts/bills').existsSync(), isFalse);
  });

  test('signed calls sign the method, the path, the time and the body\'s hash, and say the body\'s headers', () async {
    var t = DateTime.fromMillisecondsSinceEpoch(1763600000000);
    final keys = NetKeys.generate();
    final api = MarketApi(hubUrl: 'wss://relay.test/hub', signer: KeysSigner(keys), transport: relay.call, now: () => t);
    await api.report(const PluginReport(plugin: 'bills', version: '1.0.0', reason: ReportReason.spam, text: 'Every text.'));
    await api.report(const PluginReport(plugin: 'bills', version: '1.0.0', reason: ReportReason.spam));
    final a = relay.asked[0], b = relay.asked[1];
    expect(a.url.toString(), 'https://relay.test/market/report');
    expect(a.headers['x-ghost-body-sha256'], sha256Hex(a.body));
    expect(a.headers['x-ghost-body-length'], '${a.body.length}');
    final words = utf8.encode('ghost-market v1\nPOST\n/market/report\n${a.headers['x-ghost-time']}\n${sha256Hex(a.body)}');
    expect(NetCrypto.verify(base64Decode(a.headers['x-ghost-key']!), words, base64Decode(a.headers['x-ghost-sig']!)), isTrue);
    expect(int.parse(b.headers['x-ghost-time']!), int.parse(a.headers['x-ghost-time']!) + 1, reason: 'two in one millisecond never replay each other');
    // A GET is signed over the empty body's hash, with no body headers.
    t = t.add(const Duration(seconds: 1));
    await api.mine();
    final c = relay.asked.last;
    expect(c.headers.containsKey('x-ghost-body-sha256'), isFalse);
    final get = utf8.encode('ghost-market v1\nGET\n/market/mine\n${c.headers['x-ghost-time']}\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(NetCrypto.verify(base64Decode(c.headers['x-ghost-key']!), get, base64Decode(c.headers['x-ghost-sig']!)), isTrue);
    // With no identity, a signed call says why in the words of what it was for.
    final nobody = MarketApi(hubUrl: 'https://relay.test', transport: relay.call);
    await expectLater(nobody.mine(), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'no_identity').having((e) => e.message, 'message', startsWith('Submitting needs your Uplink identity'))));
  });

  test('a PNG decoded in Dart alone: the plain ones drawn, an interlaced one or a broken one not', () {
    final rgba = pngPixelsInDart(billsIcon)!;
    final info = pngInfo(billsIcon)!;
    expect(rgba.length, info.width * info.height * 4);
    // The glyph is white on clear: some pixels white and whole, some not there at all.
    final alphas = {for (var i = 3; i < rgba.length; i += 4) rgba[i]};
    expect(alphas, containsAll([0, 255]));
    // Bit 28 is IHDR's interlace: Adam7 is left alone.
    final interlaced = Uint8List.fromList(billsIcon)..[28] = 1;
    expect(pngPixelsInDart(interlaced), isNull);
    expect(pngPixelsInDart(Uint8List.fromList([...billsIcon.take(60), ...List.filled(40, 0)])), isNull);
    expect(pngPixelsInDart(billsIcon, most: 32), isNull, reason: 'larger than asked for');
  });

  test('only https, but for a test\'s own server; the market beside the hub; our own relays known', () {
    expect(marketUrlFor('wss://gogho.st/hub').toString(), 'https://gogho.st/market');
    expect(marketUrlFor('wss://ghost-sms.com/hub', ['catalog']).toString(), 'https://ghost-sms.com/market/catalog');
    expect(marketUrlFor('ws://127.0.0.1:8787/hub').toString(), 'http://127.0.0.1:8787/market');
    expect(() => marketUrlFor('ws://relay.example/hub'), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'not_https')));
    expect(marketIsOwn('wss://gogho.st/hub'), isTrue);
    expect(marketIsOwn('wss://ghost-sms.com/hub'), isTrue);
    expect(marketIsOwn('wss://relay.example/hub'), isFalse);
  });

  test('a refusal comes back as the relay said it, with its issues; garbage as unreachable', () async {
    relay.answers['POST /market/submissions'] = (status: 400, body: {'ok': false, 'error': 'invalid_package', 'message': 'The plugin has problems.', 'issues': [{'code': 'bad_text', 'path': 'name', 'message': 'name: a character that isn\'t allowed.'}]});
    final api = MarketApi(hubUrl: 'https://relay.test', signer: devSigner, transport: relay.call);
    await expectLater(api.check('e30='), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'invalid_package').having((e) => e.issues.single.path, 'path', 'name')));
    final broken = MarketApi(hubUrl: 'https://relay.test', transport: (m, u, h, b, {required most}) async => (status: 200, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode('Ghost Messaging relay'))));
    await expectLater(broken.info(), throwsA(isA<MarketError>().having((e) => e.code, 'code', 'unreachable')));
  });
}
