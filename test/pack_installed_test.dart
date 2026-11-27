import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

import 'support/test_plugins.dart';

/// The packs on this device (lib/plugins/pack/installed.dart; Matt, 2026-11-20: "I would like users to be able to
/// develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the store
/// through a review process", and "a developer setting for users to be able to manually upload plugins for development
/// testing"): installing a reviewed pack and every way it is refused, in order; each load checking them all again;
/// pauses kept; plugins in development, by developer mode, their copies, links and consent; removing; withdrawals and
/// retired keys; and telling listeners only after the call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real sockets for the link tests: the test binding answers every HTTP request with 400 otherwise.
  HttpOverrides.global = null;
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
  });

  final fixture = jsonDecode(File('test/fixtures/packs/bills.ghostplugin').readAsStringSync()) as Map<String, dynamic>;
  final parcelsFixture = jsonDecode(File('test/fixtures/packs/parcels.ghostplugin').readAsStringSync()) as Map<String, dynamic>;
  final reviewer = KeysSigner(NetKeys.generate());
  final key = base64Encode(reviewer.publicKey);

  Map<String, Object?> billsAt({String version = '1.0.0', String id = 'bills', String developer = 'yourname', String name = 'Bills'}) => jsonDecode(jsonEncode({...fixture, 'version': version, 'id': id, 'developer': developer, 'name': name})) as Map<String, Object?>;

  Future<(Uint8List, PackApproval)> reviewed(Map<String, Object?> json, {KeysSigner? by}) async {
    final bytes = canonicalBytes(json);
    return (bytes, await signApproval(by ?? reviewer, plugin: json['id'] as String, version: json['version'] as String, sha256: sha256Hex(bytes)));
  }

  late Directory root;
  late PluginRegistry registry;
  late AppState app;
  late InstalledPlugins installed;
  late InstalledPlugins was;
  var at = DateTime(2026, 11, 20, 12);

  InstalledPlugins make({List<String>? keys, bool storeAllowed = true, bool devAllowed = true, DateTime Function()? now}) => InstalledPlugins(root: root, registry: registry, reviewKeys: keys ?? [key], storeAllowed: storeAllowed, devAllowed: devAllowed, now: now ?? () => at);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('pack-installed-');
    registry = PluginRegistry([TicketsPlugin()]);
    app = AppState();
    at = DateTime(2026, 11, 20, 12);
    was = InstalledPlugins.instance;
    installed = InstalledPlugins.instance = make();
    await installed.load(app, appVersion: '0.10.1');
  });

  tearDown(() {
    InstalledPlugins.instance = was;
    InstalledPlugins.verifyInIsolate = false;
    InstalledPlugins.shipped = (shippedRevocations, shippedRetirements);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  bool running(String registryId) => registry.plugins.any((p) => p.id == registryId);
  String pref(String key) => app.choice(key, '');

  group('installReviewed', () {
    test('writes the files and the indexes, raises the floor, and puts it in the registry, on', () async {
      final (bytes, approval) = await reviewed(billsAt());
      final outcome = await installed.installReviewed(bytes, approval, listing: const {'listedAt': 1763000000000});
      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.plugin!.id, 'xbills');
      final dir = '${root.path}/store/bills/1.0.0';
      expect(File('$dir/package.ghostplugin').readAsBytesSync(), bytes);
      expect(PackApproval.fromJson(jsonDecode(File('$dir/approval.json').readAsStringSync()) as Map).toJson(), approval.toJson());
      final listing = jsonDecode(File('$dir/listing.json').readAsStringSync()) as Map;
      expect(listing, {'v': 1, 'installedAt': at.millisecondsSinceEpoch, 'listedAt': 1763000000000, 'name': 'Bills', 'tagline': 'Bills and payment reminders in a tab of their own', 'hue': 'amber', 'symbol': 'calculator', 'developer': 'yourname'});
      expect(Directory(dir).listSync().where((f) => f.path.endsWith('.tmp')), isEmpty, reason: 'written whole, then renamed');
      expect(pref('plugins_store'), '{"bills":"1.0.0"}');
      expect(jsonDecode(pref('plugins_floor')), {'bills': {'version': '1.0.0', 'sha256': approval.sha256}});
      expect(running('xbills'), isTrue);
      expect(pref('plugin_xbills'), 'on');
      final pack = installed.storeOf('bills')!;
      expect([pack.version, pack.sha256, pack.running, pack.problem, pack.plugin!.source], ['1.0.0', approval.sha256, true, null, PluginSource.reviewed]);
      expect(pack.listing['listedAt'], 1763000000000);
    });

    test('each refusal, in B.9.3\'s order', () async {
      final (bytes, approval) = await reviewed(billsAt());
      Future<String?> code(InstalledPlugins i, List<int> b, PackApproval a) async => (await i.installReviewed(Uint8List.fromList(b), a)).code;

      final ios = make(storeAllowed: false);
      await ios.load(app, appVersion: '0.10.1');
      expect(await code(ios, bytes, approval), 'not_here');
      expect((await ios.installReviewed(bytes, approval)).message, 'Plugins from other developers aren\'t on iPhone.');
      expect(await code(installed, List.filled(262145, 0x20), approval), 'too_large');
      expect(await code(installed, [...bytes, 0x20], approval), 'sha_mismatch');
      final newer = canonicalBytes(billsAt()..['minApp'] = '99.0.0');
      expect(await code(installed, newer, await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha256Hex(newer))), 'needs_newer_app');
      final broken = canonicalBytes(billsAt()..['hue'] = 'teal');
      final brokenOutcome = await installed.installReviewed(broken, await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha256Hex(broken)));
      expect(brokenOutcome.code, 'invalid');
      expect(brokenOutcome.issues.single.code, 'bad_hue');
      final noIcon = canonicalBytes(billsAt()..remove('icon'));
      expect(await code(installed, noIcon, await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha256Hex(noIcon))), 'invalid');
      final pretty = utf8.encode(const JsonEncoder.withIndent('  ').convert(billsAt()));
      expect(await code(installed, pretty, await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha256Hex(pretty))), 'not_canonical');
      expect(await code(installed, bytes, await signApproval(reviewer, plugin: 'bills', version: '1.0.1', sha256: approval.sha256)), 'bad_approval');
      final forged = PackApproval(plugin: 'bills', version: '1.0.0', sha256: approval.sha256, key: key, sig: (await signApproval(KeysSigner(NetKeys.generate()), plugin: 'bills', version: '1.0.0', sha256: approval.sha256)).sig, at: 0);
      expect(await code(installed, bytes, forged), 'bad_approval');
      expect(await code(installed, bytes, await signApproval(KeysSigner(NetKeys.generate()), plugin: 'bills', version: '1.0.0', sha256: approval.sha256)), 'untrusted_key');
      expect(running('xbills'), isFalse);
      expect(Directory('${root.path}/store').existsSync(), isFalse, reason: 'a refusal writes nothing');

      // Withdrawn, it can't be added.
      final revocation = await signRevocation(reviewer, plugin: 'bills', sha256: approval.sha256, why: 'It sorted contacts\' texts.');
      final withdrawn = make();
      await withdrawn.load(AppState(), appVersion: '0.10.1');
      await withdrawn.takeRevocations({'v': 1, 'revoked': [revocation.toJson()]});
      expect(await code(withdrawn, bytes, approval), 'revoked');

      // A development copy of it loaded.
      app.set('dev_mode', 'on');
      expect((await installed.loadDev(bytes, const DevSource('paste'))).ok, isTrue);
      final idInstalled = await installed.installReviewed(bytes, approval);
      expect(idInstalled.code, 'id_installed');
      expect(idInstalled.message, 'Your development copy of Bills is loaded. Remove it in Settings › Developer first.');
      await installed.removeDev('bills');
      expect((await installed.installReviewed(bytes, approval)).ok, isTrue);
    });

    test('not_newer for an older version once a newer was here, even removed; the same copy is taken again', () async {
      final (v1, a1) = await reviewed(billsAt());
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      expect((await installed.installReviewed(v2, a2)).ok, isTrue);
      expect((await installed.installReviewed(v1, a1)).code, 'not_newer');
      expect((await installed.removeStore('bills')).ok, isTrue);
      expect(jsonDecode(pref('plugins_floor'))['bills']['version'], '1.1.0', reason: 'kept after Remove');
      final older = await installed.installReviewed(v1, a1);
      expect(older.code, 'not_newer');
      expect(older.message, 'A newer version of Bills was on this phone already.');
      final otherCopy = canonicalBytes(billsAt(version: '1.1.0')..['tagline'] = 'Another copy of the same version');
      expect((await installed.installReviewed(otherCopy, await signApproval(reviewer, plugin: 'bills', version: '1.1.0', sha256: sha256Hex(otherCopy)))).code, 'not_newer', reason: 'the same version with another SHA-256');
      expect((await installed.installReviewed(v2, a2)).ok, isTrue, reason: 'a reinstall of the same copy');
      expect(installed.storeOf('bills')!.version, '1.1.0');
    });

    test('developer_changed: an update by someone else is refused', () async {
      final (v1, a1) = await reviewed(billsAt());
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0', developer: 'someone'));
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      final outcome = await installed.installReviewed(v2, a2);
      expect(outcome.code, 'developer_changed');
      expect(outcome.message, 'Bills is now by someone else. Remove it first, then add theirs.');
      await installed.removeStore('bills', forget: true);
      expect((await installed.installReviewed(v2, a2)).ok, isTrue, reason: 'once removed, theirs is a plugin like any other');
    });

    test('developer_changed for a copy here that no longer parses: whose it is from listing.json or its file, unknown refused', () async {
      // A stuck copy has no pack to read its developer from: the check was skipped, and another developer's version
      // came in as an "Update", the old switch on and running at once (review, 2026-11-20).
      for (final how in ['listing.json', 'its file', 'unknown']) {
        final json = billsAt(developer: 'maya')..['minApp'] = '0.10.1';
        final (v1, a1) = await reviewed(json);
        expect((await installed.installReviewed(v1, a1)).ok, isTrue, reason: how);
        final dir = '${root.path}/store/bills/1.0.0';
        expect(jsonDecode(File('$dir/listing.json').readAsStringSync())['developer'], 'maya', reason: 'kept at install');
        if (how != 'listing.json') {
          // As a copy installed before listing.json kept its developer.
          final listing = (jsonDecode(File('$dir/listing.json').readAsStringSync()) as Map).cast<String, Object?>()..remove('developer');
          File('$dir/listing.json').writeAsBytesSync(canonicalBytes(listing));
        }
        if (how == 'unknown') File('$dir/package.ghostplugin').writeAsStringSync('{"rules": ');
        app.set('plugin_xbills', 'on');
        // A downgrade below its minApp: it no longer parses here. A registry of its own, as after a restart.
        registry = PluginRegistry([TicketsPlugin()]);
        final later = make();
        await later.load(app, appVersion: '0.10.0');
        final stuck = later.storeOf('bills')!;
        expect([stuck.pack, stuck.running], [null, false], reason: how);
        expect(stuck.developer, how == 'unknown' ? isNull : 'maya', reason: how);
        final (theirs, theirApproval) = await reviewed(billsAt(version: '2.0.0', developer: 'mallory'));
        final out = await later.installReviewed(theirs, theirApproval, on: false);
        expect(out.code, 'developer_changed', reason: how);
        expect(later.storeOf('bills')!.version, '1.0.0', reason: '$how: nothing of theirs is in');
        final (hers, herApproval) = await reviewed(billsAt(version: '2.0.0', developer: 'maya'));
        final update = await later.installReviewed(hers, herApproval, on: false);
        expect(update.code, how == 'unknown' ? 'developer_changed' : isNull, reason: '$how: her own update, where it can be told hers');
        await later.removeStore('bills', forget: true);
        later.dispose();
        installed.dispose();
        registry = PluginRegistry([TicketsPlugin()]);
        installed = InstalledPlugins.instance = make();
        await installed.load(app, appVersion: '0.10.1');
        app.set('plugins_floor', '');
      }
    });

    test('too_many_packs at 17', () async {
      for (var i = 1; i <= 16; i++) {
        final (bytes, approval) = await reviewed(billsAt(id: 'pack${i.toString().padLeft(2, '0')}'));
        expect((await installed.installReviewed(bytes, approval)).ok, isTrue, reason: 'pack $i');
      }
      final (bytes, approval) = await reviewed(billsAt(id: 'pack17'));
      expect((await installed.installReviewed(bytes, approval)).code, 'too_many_packs');
      app.set('dev_mode', 'on');
      expect((await installed.loadDev(canonicalBytes(billsAt(id: 'mine')), const DevSource('paste'))).code, 'too_many_packs', reason: 'store and dev packs together');
      final (again, againApproval) = await reviewed(billsAt(id: 'pack16', version: '1.0.1'));
      expect((await installed.installReviewed(again, againApproval)).ok, isTrue, reason: 'an update replaces its copy: it isn\'t one more');
    });

    test('an update keeps the switch as the person left it, and its place', () async {
      final (v1, a1) = await reviewed(billsAt());
      final (p1, pa1) = await reviewed(jsonDecode(jsonEncode(parcelsFixture)) as Map<String, Object?>);
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      expect((await installed.installReviewed(p1, pa1)).ok, isTrue);
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills');
      registry.setOn(plugin, AppStore(app), false);
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      final outcome = await installed.installReviewed(v2, a2, on: false);
      expect(outcome.ok, isTrue);
      expect(pref('plugin_xbills'), 'off');
      expect(registry.plugins.map((p) => p.id), ['tickets', 'xbills', 'xparcels']);
      expect(installed.store.map((p) => '${p.id} ${p.version}'), ['bills 1.1.0', 'parcels 1.0.0']);
      expect(Directory('${root.path}/store/bills/1.0.0').existsSync(), isFalse, reason: 'the old version\'s folder goes');
      expect(installed.storeOf('bills')!.installedAt, at, reason: 'first installed then');
    });
  });

  group('an incoming rule\'s switch starts off for a job it didn\'t have', () {
    // A switch the person turned on for something else in the copy before (a setting a tag rule reads), or for marking
    // one kind read, kept its 'on' under the same key: the new copy marked texts read or took their notifications away
    // the moment it was in, under sheets that said "once you switch it on" (review, 2026-11-20).
    String receipt() => 'Thank you for your payment of £30.00. It may take 2 days to show.';
    List<String> asItComes(String words) {
      final store = AppStore(app);
      final facts = MessageFacts(thread: 1, senders: const ['72975'], text: words, contact: false, outgoing: false, unread: true);
      return [for (final b in registry.incoming(facts, registry.classify(facts, store), store)) '${b.action.runtimeType}'];
    }

    /// Bills whose autoread switch is an ordinary one, read by its paid rule, with no incoming rule waiting for it.
    Map<String, Object?> plainBills() {
      final j = billsAt();
      final rules = j['rules'] as Map;
      rules.remove('incoming');
      j['permissions'] = ['sort', 'copy'];
      (((rules['tags'] as List)[1]) as Map)['when'] = {'setting': 'autoread'};
      (((j['settings'] as List)[0]) as Map)['label'] = 'Show paid ones too';
      return j;
    }

    test('an update whose incoming rule waits for a switch that was an ordinary one', () async {
      final (v1, a1) = await reviewed(plainBills());
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      app.set('plugin_xbills_autoread', 'on');
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      expect((await installed.installReviewed(v2, a2, on: false)).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), '', reason: 'off until switched on for marking receipts read');
      expect(asItComes(receipt()), isEmpty);
      app.set('plugin_xbills_autoread', 'on');
      expect(asItComes(receipt()), ['MarkRead'], reason: 'once the person switches it on');
    });

    test('an update that keeps each switch\'s job keeps the switch as it was', () async {
      final (v1, a1) = await reviewed(billsAt());
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      app.set('plugin_xbills_autoread', 'on');
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0')..['tagline'] = 'Bills, in a tab of their own');
      expect((await installed.installReviewed(v2, a2, on: false)).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), 'on');
      expect(asItComes(receipt()), ['MarkRead']);
    });

    test('an update that adds silencing to a rule, or points a rule at another switch', () async {
      final (v1, a1) = await reviewed(billsAt());
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      app.set('plugin_xbills_autoread', 'on');
      final muting = billsAt(version: '1.1.0');
      muting['permissions'] = [...(muting['permissions'] as List), 'mute'];
      ((((muting['rules'] as Map)['incoming'] as List)[0]) as Map)['do'] = ['markread', 'mute'];
      final (v2, a2) = await reviewed(muting);
      expect((await installed.installReviewed(v2, a2, on: false)).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), '', reason: 'switched on to mark read, never to silence');
      expect(asItComes(receipt()), isEmpty);
      // 1.2.0 gives its rule a switch of its own the person had on, and keeps autoread for nothing.
      final moved = billsAt(version: '1.2.0');
      (moved['settings'] as List).add({'type': 'toggle', 'key': 'showpaid', 'label': 'Show paid ones', 'default': false});
      ((((moved['rules'] as Map)['incoming'] as List)[0]) as Map)['setting'] = 'showpaid';
      app.set('plugin_xbills_showpaid', 'on');
      final (v3, a3) = await reviewed(moved);
      expect((await installed.installReviewed(v3, a3, on: false)).ok, isTrue);
      expect(pref('plugin_xbills_showpaid'), '');
      expect(asItComes(receipt()), isEmpty);
    });

    test('added again after Remove, a switch that was an ordinary one\'s starts off', () async {
      final (v1, a1) = await reviewed(plainBills());
      expect((await installed.installReviewed(v1, a1)).ok, isTrue);
      app.set('plugin_xbills_autoread', 'on');
      expect((await installed.removeStore('bills')).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), 'on', reason: 'an ordinary choice, kept as removing keeps them');
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      expect((await installed.installReviewed(v2, a2)).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), '');
      expect(asItComes(receipt()), isEmpty);
    });

    test('a copy in development whose incoming rule waits for a switch that was on stays off once agreed to', () async {
      app.set('dev_mode', 'on');
      expect((await installed.loadDev(canonicalBytes(plainBills()), const DevSource('paste'))).ok, isTrue);
      await installed.agreeDev('bills');
      app.set('plugin_xbills_autoread', 'on');
      final again = await installed.loadDev(canonicalBytes(billsAt(version: '1.1.0')), const DevSource('paste'));
      expect([again.ok, again.needsConsent], [true, true]);
      expect((await installed.agreeDev('bills')).ok, isTrue);
      expect(pref('plugin_xbills_autoread'), '');
      expect(asItComes(receipt()), isEmpty);
    });
  });

  group('load checks every pack again', () {
    Future<void> installBills() async {
      final (bytes, approval) = await reviewed(billsAt());
      expect((await installed.installReviewed(bytes, approval)).ok, isTrue);
    }

    Future<InstalledPlugins> reload({List<String>? keys}) async {
      registry = PluginRegistry([TicketsPlugin()]);
      final again = make(keys: keys);
      await again.load(app, appVersion: '0.10.1');
      return again;
    }

    test('as it was: running, on', () async {
      await installBills();
      final again = await reload();
      expect(again.loaded, isTrue);
      expect(again.storeOf('bills')!.running, isTrue);
      expect(running('xbills'), isTrue);
    });

    test('a changed package, a key no longer pinned, a key retired: listed with its problem and its plugin, not running', () async {
      await installBills();
      final file = File('${root.path}/store/bills/1.0.0/package.ghostplugin');
      final good = file.readAsBytesSync();
      file.writeAsBytesSync(utf8.encode(utf8.decode(good).replaceFirst('"Bills"', '"Billz"')));
      var again = await reload();
      expect([again.storeOf('bills')!.problem, again.storeOf('bills')!.running], ['bad_approval', false]);
      expect(running('xbills'), isFalse);
      file.writeAsBytesSync(good);
      again = await reload(keys: const []);
      expect(again.storeOf('bills')!.problem, 'untrusted_key');
      expect(again.storeOf('bills')!.plugin, isNotNull, reason: 'its page can still be drawn from it');
      expect(again.storeOf('bills')!.pack!.name, 'Bills');
      expect(running('xbills'), isFalse);
      InstalledPlugins.shipped = (const [], [(await signRetirement(reviewer)).toJson()]);
      again = await reload();
      expect(again.retiredKeys, {key});
      expect(again.storeOf('bills')!.problem, 'untrusted_key');
      expect(running('xbills'), isFalse);
    });

    test('the highest version that checks out wins', () async {
      await installBills();
      // A second version beside it, as a copy that was being written when the app stopped might leave.
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      final dir = Directory('${root.path}/store/bills/1.1.0')..createSync(recursive: true);
      File('${dir.path}/package.ghostplugin').writeAsBytesSync(v2);
      File('${dir.path}/approval.json').writeAsBytesSync(canonicalBytes(a2.toJson()));
      expect((await reload()).storeOf('bills')!.version, '1.1.0');
      File('${dir.path}/approval.json').writeAsStringSync('{}');
      final again = await reload();
      expect(again.storeOf('bills')!.version, '1.0.0');
      expect(again.storeOf('bills')!.running, isTrue);
    });

    test('verified on an isolate of its own, as in the app', () async {
      await installBills();
      InstalledPlugins.verifyInIsolate = true;
      final again = await reload();
      expect(again.storeOf('bills')!.running, isTrue);
    });

    test('a kept pause holds across a load, and goes with a new version', () async {
      var clock = at;
      DateTime stepping() => clock = clock.add(const Duration(milliseconds: 25));
      installed = InstalledPlugins.instance = make(now: stepping);
      await installed.load(app, appVersion: '0.10.1');
      await installBills();
      final notices = <PackNotice>[];
      final listening = installed.notices.listen(notices.add);
      addTearDown(listening.cancel);
      final store = AppStore(app);
      final text = MessageFacts(thread: 1, senders: const ['72975'], text: 'Your bill is ready', contact: false, outgoing: false);
      for (var i = 0; i < 6; i++) {
        clock = clock.add(const Duration(seconds: 2));
        registry.classify(text, store);
      }
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills') as PackPlugin;
      expect(plugin.paused, isTrue);
      expect(pref('plugins_paused'), isEmpty, reason: 'written after the build that paused it, never during');
      await pumpEventQueue();
      expect(jsonDecode(pref('plugins_paused')), {'xbills': installed.storeOf('bills')!.sha256});
      expect(installed.storeOf('bills')!.problem, 'paused');
      expect(notices.map((n) => '${n.kind} ${n.packId} ${n.words}'), ['paused bills Bills was paused: it was slowing the app down. Turn it back on from its page in the Marketplace.']);
      final again = await reload();
      expect((registry.plugins.firstWhere((p) => p.id == 'xbills') as PackPlugin).paused, isTrue);
      expect(again.storeOf('bills')!.problem, 'paused');
      final (v2, a2) = await reviewed(billsAt(version: '1.1.0'));
      expect((await again.installReviewed(v2, a2, on: false)).ok, isTrue);
      expect((registry.plugins.firstWhere((p) => p.id == 'xbills') as PackPlugin).paused, isFalse);
      expect(jsonDecode(pref('plugins_paused')), isEmpty);
    });

    test('unpause clears it, and what it kept', () async {
      var clock = at;
      installed = InstalledPlugins.instance = make(now: () => clock = clock.add(const Duration(milliseconds: 25)));
      await installed.load(app, appVersion: '0.10.1');
      await installBills();
      final text = MessageFacts(thread: 1, senders: const ['72975'], text: 'Your bill is ready', contact: false, outgoing: false);
      for (var i = 0; i < 6; i++) {
        clock = clock.add(const Duration(seconds: 2));
        registry.classify(text, AppStore(app));
      }
      await pumpEventQueue();
      final tuned = pref(PluginRegistry.tunedKey);
      installed.unpause('bills');
      await pumpEventQueue();
      expect(installed.storeOf('bills')!.problem, isNull);
      expect(jsonDecode(pref('plugins_paused')), isEmpty);
      expect(pref(PluginRegistry.tunedKey), isNot(tuned), reason: 'so the list classifies and sorts again');
    });
  });

  group('plugins in development', () {
    final billsBytes = File('test/fixtures/packs/bills.ghostplugin').readAsBytesSync();

    test('only in developer mode: refused without it, taken out when it goes off, back when it comes on', () async {
      final off = await installed.loadDev(billsBytes, const DevSource('paste'));
      expect(off.code, 'dev_mode_off');
      expect(off.message, 'Turn on developer mode first: tap Settings › About › Version twelve times.');
      app.set('dev_mode', 'on');
      final on = await installed.loadDev(billsBytes, const DevSource('paste'));
      expect(on.ok, isTrue);
      expect(on.needsConsent, isTrue, reason: 'never agreed to');
      expect(pref('plugin_xbills'), 'off');
      expect(installed.devOf('bills')!.problem, 'needs_consent');
      expect(installed.mayTurnOnDev('bills'), isFalse);
      expect((await installed.agreeDev('bills')).ok, isTrue);
      expect(pref('plugin_xbills'), 'on');
      expect(installed.mayTurnOnDev('bills'), isTrue);
      expect(installed.devOf('bills')!.agreed, DevPack.consentLines(installed.devOf('bills')!.pack!));
      expect(running('xbills'), isTrue);
      expect(pref('plugins_dev'), '["bills"]');
      app.set('dev_mode', 'off');
      expect(running('xbills'), isFalse);
      expect(installed.devOf('bills')!.problem, 'dev_mode_off');
      expect(File('${root.path}/dev/bills/package.ghostplugin').existsSync(), isTrue, reason: 'its files stay');
      app.set('dev_mode', 'on');
      expect(running('xbills'), isTrue);
      expect(pref('plugin_xbills'), 'on');
      // And at the next start.
      registry = PluginRegistry([TicketsPlugin()]);
      final again = make();
      await again.load(app, appVersion: '0.10.1');
      expect(again.devOf('bills')!.running, isTrue);
      expect(again.devOf('bills')!.needsConsent, isFalse);
      expect(again.devOf('bills')!.source.kind, 'paste');
    });

    test('none at all where they aren\'t allowed (an App Store build)', () async {
      app.set('dev_mode', 'on');
      final store = make(devAllowed: false);
      await store.load(app, appVersion: '0.10.1');
      expect((await store.loadDev(billsBytes, const DevSource('paste'))).code, 'not_here');
      expect((await installed.loadDev(billsBytes, const DevSource('paste'))).ok, isTrue);
      registry = PluginRegistry([TicketsPlugin()]);
      final appStore = make(devAllowed: false);
      await appStore.load(app, appVersion: '0.10.1');
      expect(appStore.dev, isEmpty, reason: 'a copy on disk isn\'t even read');
      expect(running('xbills'), isFalse);
    });

    test('a load that isn\'t JSON, or has no id, writes nothing and makes no DevPack', () async {
      app.set('dev_mode', 'on');
      for (final bad in [utf8.encode('not json'), utf8.encode('{"name": "Bills"}'), utf8.encode('{"id": "codes"}')]) {
        final outcome = await installed.loadDev(bad, const DevSource('paste'));
        expect(outcome.code, 'invalid');
        expect(outcome.issues, isNotEmpty);
      }
      expect(installed.dev, isEmpty);
      expect(Directory('${root.path}/dev').existsSync(), isFalse);
    });

    test('a broken copy with a good id is kept with its issues, and an older copy that runs goes on running', () async {
      app.set('dev_mode', 'on');
      final file = File('${root.path}/bills.ghostplugin')..writeAsBytesSync(billsBytes);
      expect((await installed.loadDev(billsBytes, DevSource('file', path: file.path, name: 'bills.ghostplugin'))).ok, isTrue);
      await installed.agreeDev('bills');
      final first = registry.plugins.firstWhere((p) => p.id == 'xbills');
      file.writeAsStringSync(utf8.decode(billsBytes).replaceFirst('"amber"', '"teal"'));
      final outcome = await installed.reloadDev('bills');
      expect(outcome.code, 'invalid');
      expect(outcome.issues.map((i) => i.code), ['bad_hue']);
      final dev = installed.devOf('bills')!;
      expect(dev.problem, 'new_copy_invalid');
      expect(dev.issues.single.code, 'bad_hue');
      expect(dev.pack, isNull);
      expect(identical(dev.plugin, first), isTrue);
      expect(registry.plugins.firstWhere((p) => p.id == 'xbills'), same(first), reason: 'the older copy runs on');
      final broken = await installed.loadDev(utf8.encode('{"id": "mine", "version": "1.0"}'), const DevSource('paste'));
      expect(broken.code, 'invalid');
      expect(installed.devOf('mine')!.problem, 'invalid');
      expect(installed.devOf('mine')!.running, isFalse);
    });

    test('a reload that can do something new is off until it is agreed to again', () async {
      app.set('dev_mode', 'on');
      final file = File('${root.path}/bills.ghostplugin')..writeAsBytesSync(billsBytes);
      await installed.loadDev(billsBytes, DevSource('file', path: file.path));
      await installed.agreeDev('bills');
      expect(pref('plugin_xbills'), 'on');
      final same = await installed.reloadDev('bills');
      expect([same.ok, same.needsConsent, pref('plugin_xbills')], [true, false, 'on'], reason: 'nothing new to agree to');
      final json = jsonDecode(utf8.decode(billsBytes)) as Map<String, dynamic>;
      json['permissions'] = [...json['permissions'] as List, 'move'];
      (json['rules']['actions'] as List).add({'id': 'tobills', 'label': 'It\'s a bill', 'icon': 'calculator', 'slots': ['list.conversation.menu'], 'do': 'move', 'to': 'bills'});
      file.writeAsStringSync(jsonEncode(json));
      final more = await installed.reloadDev('bills');
      expect(more.ok, isTrue);
      expect(more.needsConsent, isTrue);
      expect(pref('plugin_xbills'), 'off');
      expect(installed.devOf('bills')!.problem, 'needs_consent');
      expect(installed.mayTurnOnDev('bills'), isFalse);
      expect((await installed.agreeDev('bills')).ok, isTrue);
      expect(pref('plugin_xbills'), 'on');
      expect(installed.devOf('bills')!.needsConsent, isFalse);
    });

    test('id_changed, and not_reloadable for a pasted copy', () async {
      app.set('dev_mode', 'on');
      final file = File('${root.path}/bills.ghostplugin')..writeAsBytesSync(billsBytes);
      await installed.loadDev(billsBytes, DevSource('file', path: file.path));
      file.writeAsStringSync(utf8.decode(billsBytes).replaceFirst('"id": "bills"', '"id": "mybills"'));
      final changed = await installed.reloadDev('bills');
      expect(changed.code, 'id_changed');
      expect(changed.message, 'The copy\'s id is now mybills: load it as a new plugin.');
      await installed.loadDev(canonicalBytes(billsAt(id: 'pasted')), const DevSource('paste'));
      expect((await installed.reloadDev('pasted')).code, 'not_reloadable');
      expect((await installed.reloadDev('nothere')).code, 'not_found');
    });

    test('from a link: http to 127.0.0.1, refused elsewhere, too large refused', () async {
      app.set('dev_mode', 'on');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(server.forEach((request) async {
        switch (request.uri.path) {
          case '/bills.ghostplugin':
            request.response.add(billsBytes);
          case '/moved':
            request.response
              ..statusCode = 302
              ..headers.set('location', '/bills.ghostplugin');
          case '/away':
            request.response
              ..statusCode = 302
              ..headers.set('location', 'http://example.com/bills.ghostplugin');
          case '/big':
            request.response.add(List.filled(300000, 0x20));
          default:
            request.response.statusCode = 404;
        }
        await request.response.close();
      }));
      final base = 'http://127.0.0.1:${server.port}';
      final ok = await installed.loadDevFromLink(Uri.parse('$base/bills.ghostplugin'));
      expect(ok.ok, isTrue, reason: ok.message);
      expect(installed.devOf('bills')!.source.kind, 'link');
      expect(installed.devOf('bills')!.source.url, '$base/bills.ghostplugin');
      expect(installed.devOf('bills')!.source.reloadable, isTrue);
      expect((await installed.reloadDev('bills')).ok, isTrue);
      await installed.removeDev('bills');
      expect((await installed.loadDevFromLink(Uri.parse('$base/moved'))).ok, isTrue, reason: 'a redirect to the same place');
      expect((await installed.loadDevFromLink(Uri.parse('http://example.com/bills.ghostplugin'))).code, 'bad_link');
      expect((await installed.loadDevFromLink(Uri.parse('http://example.com/bills.ghostplugin'))).message, 'Use http://127.0.0.1 with adb reverse, or https.');
      expect((await installed.loadDevFromLink(Uri.parse('$base/away'))).code, 'bad_link', reason: 'each hop is held to the same rule');
      expect((await installed.loadDevFromLink(Uri.parse('$base/big'))).code, 'too_large');
      expect((await installed.loadDevFromLink(Uri.parse('$base/nothing'))).code, 'fetch_failed');
      expect((await installed.loadDevFromLink(Uri.parse('ftp://127.0.0.1/x'))).code, 'bad_link');
    });

    test('what it throws lands in its errors, newest first', () async {
      app.set('dev_mode', 'on');
      await installed.loadDev(billsBytes, const DevSource('paste'));
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills');
      registry.failed(plugin, StateError('first'));
      registry.failed(plugin, StateError('second'));
      expect(installed.devOf('bills')!.errors.map((e) => e.line), ['Bad state: second', 'Bad state: first']);
      registry.failed(TicketsPlugin(), StateError('someone else\'s'));
      expect(installed.devOf('bills')!.errors, hasLength(2));
    });

    test('removeDev takes it out, its switch and its incoming switches with it', () async {
      app.set('dev_mode', 'on');
      await installed.loadDev(billsBytes, const DevSource('paste'));
      await installed.agreeDev('bills');
      app.set('plugin_xbills_autoread', 'on');
      app.set('plugin_xbills_extra', 'rates');
      expect((await installed.removeDev('bills')).ok, isTrue);
      expect([pref('plugin_xbills'), pref('plugin_xbills_autoread'), pref('plugin_xbills_extra')], ['', '', 'rates']);
      expect(running('xbills'), isFalse);
      expect(Directory('${root.path}/dev/bills').existsSync(), isFalse);
      expect(installed.dev, isEmpty);
      expect(pref('plugins_dev'), '[]');
    });

    test('removeDev clears its incoming switches even where its newest copy is broken and nothing of it ran since a restart', () async {
      app.set('dev_mode', 'on');
      await installed.loadDev(billsBytes, const DevSource('paste'));
      await installed.agreeDev('bills');
      app
        ..set('plugin_xbills_autoread', 'on')
        ..set('plugin_xbills_extra', 'rates');
      // A broken copy loaded, then a restart: only that copy is on disk, so nothing of the pack is held.
      expect((await installed.loadDev(utf8.encode(utf8.decode(billsBytes).replaceFirst('"amber"', '"teal"')), const DevSource('paste'))).code, 'invalid');
      installed.dispose();
      registry = PluginRegistry([TicketsPlugin()]);
      installed = InstalledPlugins.instance = make();
      await installed.load(app, appVersion: '0.10.1');
      final d = installed.devOf('bills')!;
      expect([d.pack, d.plugin], [null, null]);
      expect((await installed.removeDev('bills')).ok, isTrue);
      expect([pref('plugin_xbills_autoread'), pref('plugin_xbills_extra')], ['', 'rates'], reason: 'the broken copy still names autoread');
      // Loaded and agreed to again, its incoming rule waits for the person to switch it on.
      await installed.loadDev(billsBytes, const DevSource('paste'));
      await installed.agreeDev('bills');
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills');
      expect(registry.prefsOf(plugin, AppStore(app)).flag('autoread', fallback: false), isFalse);
    });

    test('an id an installed store pack has is refused', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      app.set('dev_mode', 'on');
      final outcome = await installed.loadDev(billsBytes, const DevSource('paste'));
      expect(outcome.code, 'id_installed');
      expect(outcome.message, 'Bills is installed from the Marketplace. Remove it there first, or give your copy another id.');
    });
  });

  group('removing a store pack', () {
    test('clears its switch and its incoming switches, keeps its other choices, and with forget those too', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      app
        ..set('plugin_xbills_autoread', 'on')
        ..set('plugin_xbills_extra', 'council tax');
      final outcome = await installed.removeStore('bills');
      expect(outcome.ok, isTrue);
      expect([pref('plugin_xbills'), pref('plugin_xbills_autoread'), pref('plugin_xbills_extra')], ['', '', 'council tax']);
      expect(running('xbills'), isFalse);
      expect(Directory('${root.path}/store/bills').existsSync(), isFalse);
      expect(installed.store, isEmpty);
      expect(pref('plugins_store'), '{}');
      expect((await installed.removeStore('bills')).code, 'not_found');
      // Added again: asked again, and its incoming switch off.
      await installed.installReviewed(bytes, approval);
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills');
      expect(registry.prefsOf(plugin, AppStore(app)).flag('autoread', fallback: false), isFalse);
      expect(pref('plugin_xbills_extra'), 'council tax');
      await installed.removeStore('bills', forget: true);
      expect(pref('plugin_xbills_extra'), '');
    });

    test('a copy that no longer parses here still has its incoming switches cleared', () async {
      // Each way a store pack stops parsing: a newer app it needs, a package changed on disk, an approval that can't
      // be read. Its switches were cleared only where the pack could be read, so adding it again marked texts read at
      // once (review, 2026-11-20).
      for (final how in ['needs_newer_app', 'changed', 'unreadable']) {
        final json = billsAt();
        if (how == 'needs_newer_app') json['minApp'] = '0.10.1';
        final (bytes, approval) = await reviewed(json);
        expect((await installed.installReviewed(bytes, approval)).ok, isTrue, reason: how);
        app
          ..set('plugin_xbills_autoread', 'on')
          ..set('plugin_xbills_extra', 'council tax');
        final dir = '${root.path}/store/bills/1.0.0';
        if (how == 'changed') File('$dir/package.ghostplugin').writeAsBytesSync([...bytes, 0x20]);
        if (how == 'unreadable') File('$dir/approval.json').writeAsStringSync('not an approval');
        final later = make();
        await later.load(app, appVersion: how == 'needs_newer_app' ? '0.10.0' : '0.10.1');
        final stuck = later.storeOf('bills')!;
        expect([stuck.pack, stuck.running], [null, false], reason: how);
        expect(stuck.problem, switch (how) { 'needs_newer_app' => 'needs_newer_app', 'changed' => 'bad_approval', _ => 'io' });
        expect((await later.removeStore('bills')).ok, isTrue);
        expect([pref('plugin_xbills'), pref('plugin_xbills_autoread'), pref('plugin_xbills_extra')], ['', '', 'council tax'], reason: '$how: its other choices are kept');
        later.dispose();
        installed.dispose();
        // The registry the next round starts from, with nothing of this one's in it.
        registry = PluginRegistry([TicketsPlugin()]);
        installed = InstalledPlugins.instance = make();
        await installed.load(app, appVersion: '0.10.1');
        app.set('plugins_floor', '');
      }
    });

    test('a copy that can\'t be read at all leaves none of its switches on', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      app
        ..set('plugin_xbills_autoread', 'on')
        ..set('plugin_xbills_extra', 'council tax');
      File('${root.path}/store/bills/1.0.0/package.ghostplugin').writeAsStringSync('{"rules": ');
      final later = make();
      await later.load(app, appVersion: '0.10.1');
      expect(later.storeOf('bills')!.pack, isNull);
      await later.removeStore('bills');
      expect([pref('plugin_xbills_autoread'), pref('plugin_xbills_extra')], ['', 'council tax'], reason: 'every switch that was on goes; words stay');
      later.dispose();
    });
  });

  group('withdrawals', () {
    test('takeRevocations keeps only signed entries, withdraws what they name, and says so', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      final notices = <PackNotice>[];
      final listening = installed.notices.listen(notices.add);
      addTearDown(listening.cancel);
      final good = await signRevocation(reviewer, plugin: 'bills', sha256: approval.sha256, why: 'It sorted contacts\' texts.');
      final forged = PackRevocation(plugin: 'parcels', sha256: 'a' * 64, at: 1, why: 'Forged', key: key, sig: good.sig);
      final stranger = await signRevocation(KeysSigner(NetKeys.generate()), plugin: 'other', sha256: 'b' * 64, why: 'Not a reviewer');
      final withdrew = await installed.takeRevocations({'v': 1, 'at': 1, 'revoked': [good.toJson(), forged.toJson(), stranger.toJson(), 'junk', {'v': 1}], 'retired': []});
      expect(withdrew, 1);
      expect(installed.revocations.map((r) => r.sha256), [approval.sha256]);
      expect(installed.isRevoked('bills', approval.sha256), isTrue);
      expect(installed.isRevoked('bills', 'a' * 64), isFalse);
      expect(installed.isRevoked('parcels', approval.sha256), isFalse, reason: 'a withdrawal counts for the plugin it names alone');
      final pack = installed.storeOf('bills')!;
      expect([pack.running, pack.problem, pack.revoked?.why], [false, 'revoked', 'It sorted contacts\' texts.']);
      expect(running('xbills'), isFalse);
      expect(File('${root.path}/store/bills/1.0.0/package.ghostplugin').existsSync(), isTrue, reason: 'kept, so its page can say what happened');
      await pumpEventQueue();
      expect(notices.map((n) => '${n.kind} ${n.packId} ${n.words}'), ['withdrawn bills Bills was withdrawn from the Marketplace and is off.']);
      expect(await installed.takeRevocations({'v': 1, 'revoked': [good.toJson()]}), 0, reason: 'nothing newly withdrawn');
      final saved = jsonDecode(File('${root.path}/revoked.json').readAsStringSync()) as Map;
      expect((saved['revoked'] as List).single['sha256'], approval.sha256);
      // Read again at the next start, and verified again.
      registry = PluginRegistry([TicketsPlugin()]);
      final again = make();
      await again.load(app, appVersion: '0.10.1');
      expect(again.storeOf('bills')!.problem, 'revoked');
      expect(running('xbills'), isFalse);
    });

    test('a withdrawal signed over another plugin\'s package switches nothing off', () async {
      // A relay broken into could hand the review screen another plugin's hash to sign as "the version before" (review,
      // 2026-11-20): the reviewer's signature then names one plugin and another's package, and counts for neither.
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      final crossed = await signRevocation(reviewer, plugin: 'mybills', sha256: approval.sha256, why: 'Replaced by 1.1.0: update it from its page.');
      expect(await installed.takeRevocations({'v': 1, 'revoked': [crossed.toJson()]}), 0);
      expect([installed.storeOf('bills')!.running, installed.storeOf('bills')!.problem], [true, null]);
      expect(running('xbills'), isTrue);
      expect(installed.isRevoked('bills', approval.sha256), isFalse);
      // Nor is the package refused at a fresh install: it was never withdrawn as Bills.
      await installed.removeStore('bills');
      expect((await installed.installReviewed(bytes, approval)).ok, isTrue);
    });

    test('a retired key withdraws every pack it approved; another key\'s retirement means nothing here', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      final notices = <PackNotice>[];
      final listening = installed.notices.listen(notices.add);
      addTearDown(listening.cancel);
      final other = KeysSigner(NetKeys.generate());
      expect(await installed.takeRevocations({'v': 1, 'retired': [(await signRetirement(other)).toJson()]}), 0);
      expect(installed.retiredKeys, isEmpty);
      final forged = PackRetirement(key: key, at: 1, sig: (await signRetirement(other)).sig);
      expect(await installed.takeRevocations({'v': 1, 'retired': [forged.toJson()]}), 0);
      expect(await installed.takeRevocations({'v': 1, 'retired': [(await signRetirement(reviewer)).toJson()]}), 1);
      expect(installed.retiredKeys, {key});
      expect(installed.storeOf('bills')!.problem, 'untrusted_key');
      expect(running('xbills'), isFalse);
      await pumpEventQueue();
      expect(notices.single.kind, 'withdrawn');
      final (b2, a2) = await reviewed(billsAt(version: '1.1.0'));
      expect((await installed.installReviewed(b2, a2)).code, 'untrusted_key', reason: 'its approvals fail from now on');
    });

    test('withdrawals are checked beside the installer\'s queue, each once, and one that failed never again', () async {
      // A relay broken into could hand every device thousands of withdrawals naming a pinned key with bad signatures,
      // each a P-256 check, all inside the queue Add, Update and Remove wait in, and again at every refresh (review,
      // 2026-11-20). Checked on an isolate, as in the app.
      InstalledPlugins.verifyInIsolate = true;
      final (bytes, approval) = await reviewed(billsAt());
      expect((await installed.installReviewed(bytes, approval)).ok, isTrue);
      final good = await signRevocation(reviewer, plugin: 'other', sha256: 'c' * 64, why: 'Withdrawn.');
      final junk = [for (var i = 0; i < 300; i++) PackRevocation(plugin: 'junk$i', sha256: '$i'.padLeft(64, '0'), at: i, why: 'Junk', key: key, sig: good.sig).toJson()];
      final done = <String>[];
      final taking = installed.takeRevocations({'v': 1, 'revoked': [...junk, ...junk, good.toJson()]}).then((_) => done.add('take'));
      final removing = installed.removeStore('bills').then((out) => done.add(out.ok ? 'remove' : out.code!));
      await Future.wait([taking, removing]);
      expect(done, ['remove', 'take'], reason: 'Remove isn\'t held up while they are checked');
      expect(installed.signaturesChecked, 301, reason: 'each once, however often it is sent');
      expect(installed.isRevoked('other', 'c' * 64), isTrue, reason: 'one that holds is kept');
      expect(await installed.takeRevocations({'v': 1, 'revoked': junk}), 0);
      expect(installed.signaturesChecked, 301, reason: 'none that failed is checked again');
      // Nor at the next start: what failed is kept beside the withdrawals.
      registry = PluginRegistry([TicketsPlugin()]);
      final again = make();
      await again.load(app, appVersion: '0.10.1');
      final atLoad = again.signaturesChecked;
      await again.takeRevocations({'v': 1, 'revoked': junk});
      expect(again.signaturesChecked, atLoad);
      expect(again.isRevoked('other', 'c' * 64), isTrue);
      // A key this build doesn't pin isn't checked at all.
      final stranger = await signRevocation(KeysSigner(NetKeys.generate()), plugin: 'x', sha256: 'd' * 64, why: 'Not ours');
      await again.takeRevocations({'v': 1, 'revoked': [stranger.toJson()]});
      expect(again.signaturesChecked, atLoad);
    });

    test('the withdrawals a build ships are merged at load, verified as any other', () async {
      final (bytes, approval) = await reviewed(billsAt());
      await installed.installReviewed(bytes, approval);
      final shippedOne = await signRevocation(reviewer, plugin: 'bills', sha256: approval.sha256, why: 'Withdrawn in this release.');
      final forged = PackRevocation(plugin: 'x', sha256: 'c' * 64, at: 1, why: 'Forged', key: key, sig: shippedOne.sig);
      InstalledPlugins.shipped = ([shippedOne.toJson(), forged.toJson()], const []);
      registry = PluginRegistry([TicketsPlugin()]);
      final again = make();
      await again.load(app, appVersion: '0.10.1');
      expect(again.revocations.map((r) => r.why), ['Withdrawn in this release.']);
      expect(again.storeOf('bills')!.problem, 'revoked');
      expect(running('xbills'), isFalse);
    });
  });

  group('telling listeners', () {
    test('once per microtask, never during the call', () async {
      app.set('dev_mode', 'on');
      await installed.loadDev(File('test/fixtures/packs/bills.ghostplugin').readAsBytesSync(), const DevSource('paste'));
      await pumpEventQueue();
      var told = 0;
      installed.addListener(() => told++);
      final plugin = registry.plugins.firstWhere((p) => p.id == 'xbills');
      registry.failed(plugin, StateError('one'));
      registry.failed(plugin, StateError('two'));
      registry.failed(plugin, StateError('three'));
      expect(told, 0, reason: 'heard during a build, perhaps: told after it');
      await Future<void>.microtask(() {});
      expect(told, 1);
      final outcome = installed.removeDev('bills');
      expect(told, 1);
      await outcome;
      await pumpEventQueue();
      expect(told, 2);
    });

    test('a new InstalledPlugins reads nothing until load, and lists nothing', () {
      final fresh = InstalledPlugins(root: Directory('${root.path}/never'), reviewKeys: [key]);
      expect([fresh.loaded, fresh.store, fresh.dev, fresh.retiredKeys, fresh.revocations], [false, isEmpty, isEmpty, isEmpty, isEmpty]);
      expect(Directory('${root.path}/never').existsSync(), isFalse);
      expect(fresh.reviewKeys, [key]);
      expect(InstalledPlugins(root: root).reviewKeys, marketReviewKeys);
    });
  });
}
