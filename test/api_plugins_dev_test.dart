import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/api/api.dart';
import 'package:ghost_messaging/api/methods.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// Loading a plugin being made from the app's API (lib/api/methods.dart; Matt, 2026-11-20: "please add a developer
/// setting for users to be able to manually upload plugins for development testing"): plugins.devInstall with the
/// file's JSON or its words, a dry run, what it says where the phone hasn't agreed yet, developer mode, a broken file,
/// plugins.devRemove, and the plugin list and the filters as they see plugins from other developers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  final billsText = File('test/fixtures/packs/bills.ghostplugin').readAsStringSync();
  final parcelsText = File('test/fixtures/packs/parcels.ghostplugin').readAsStringSync();
  late Directory root;
  late InstalledPlugins was;
  late PluginRegistry wasRegistry;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    // The registry the methods hold for the app's life, made fresh for this file before they are.
    wasRegistry = PluginRegistry.instance;
    PluginRegistry.instance = PluginRegistry(shippedPlugins, onError: logPluginError);
    Api.instance.registerAll(appMethods(app));
  });

  tearDownAll(() => PluginRegistry.instance = wasRegistry);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('api-plugins-');
    was = InstalledPlugins.instance;
    InstalledPlugins.instance = InstalledPlugins(root: root, reviewKeys: const []);
    await InstalledPlugins.instance.load(app, appVersion: '0.10.1');
    app.set('dev_mode', 'on');
  });

  tearDown(() async {
    for (final d in InstalledPlugins.instance.dev) {
      await InstalledPlugins.instance.removeDev(d.id);
    }
    InstalledPlugins.instance = was;
    root.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, Map<String, Object?> params) => Api.instance.call(method, params);
  Matcher apiError(String code) => throwsA(isA<ApiError>().having((e) => e.code, 'code', code));

  test('neither method is in the API of an App Store build: this one has both', () {
    expect(packAppStoreBuild, isFalse);
    expect(Api.instance.method('plugins.devInstall')!.danger, isTrue);
    expect(Api.instance.method('plugins.devRemove')!.danger, isTrue);
    expect(Api.instance.method('ui.openSettings')!.summary, 'Opens Settings, at one of its sections where given (messages, sounds, developer, api, ...). plugins and plugin-<id> open the Marketplace instead.');
  });

  test('devInstall with the file\'s JSON loads it, off, and says what it is', () async {
    final answer = await call('plugins.devInstall', {'pack': jsonDecode(billsText)});
    expect(answer, {'ok': true, 'id': 'bills', 'plugin': 'xbills', 'on': false, 'issues': []});
    expect(InstalledPlugins.instance.devOf('bills')!.source.kind, 'api');
    expect(PluginRegistry.instance.plugins.any((p) => p.id == 'xbills'), isTrue);
  });

  test('devInstall with the file\'s words, its warnings with it', () async {
    final answer = await call('plugins.devInstall', {'text': parcelsText}) as Map;
    expect([answer['ok'], answer['id'], answer['plugin'], answer['on']], [true, 'parcels', 'xparcels', false]);
    expect([for (final i in answer['issues'] as List) '${(i as Map)['code']} ${i['severity']}'], ['opens_links warning']);
  });

  test('a dry run checks it and loads nothing', () async {
    final good = await call('plugins.devInstall', {'text': billsText, 'dryRun': true});
    expect(good, {'ok': true, 'id': 'bills', 'plugin': 'xbills', 'on': false, 'issues': []});
    final bad = await call('plugins.devInstall', {'text': billsText.replaceFirst('"amber"', '"teal"'), 'dryRun': true}) as Map;
    expect(bad['ok'], isFalse);
    expect([for (final i in bad['issues'] as List) (i as Map)['code']], ['bad_hue']);
    expect(InstalledPlugins.instance.dev, isEmpty);
  });

  test('on: true for a pack the phone never agreed to stays off, says so, and the phone is told it was loaded', () async {
    final notices = <PackNotice>[];
    final listening = InstalledPlugins.instance.notices.listen(notices.add);
    addTearDown(listening.cancel);
    final answer = await call('plugins.devInstall', {'text': billsText, 'on': true});
    expect(answer, {'ok': true, 'id': 'bills', 'plugin': 'xbills', 'on': false, 'needs': 'consent on the phone', 'issues': []});
    await pumpEventQueue();
    expect(notices.map((n) => '${n.kind} ${n.packId} ${n.words}'), ['api_loaded bills Bills was loaded from the API']);
    // Agreed to on the phone, the next load from the API may switch it on.
    await InstalledPlugins.instance.agreeDev('bills');
    expect(await call('plugins.devInstall', {'text': billsText, 'on': true}), {'ok': true, 'id': 'bills', 'plugin': 'xbills', 'on': true, 'issues': []});
  });

  test('developer mode off, and nothing given', () async {
    app.set('dev_mode', 'off');
    await expectLater(call('plugins.devInstall', {'text': billsText}), throwsA(isA<ApiError>().having((e) => e.message, 'message', 'Turn on developer mode first: tap Settings › About › Version twelve times.')));
    await expectLater(call('plugins.devRemove', {'id': 'bills'}), apiError('failed'));
    app.set('dev_mode', 'on');
    await expectLater(call('plugins.devInstall', {}), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'bad_params').having((e) => e.message, 'message', 'Give the plugin as pack (its JSON) or text (its words).')));
  });

  test('a broken pack is not an error: the answer is ok: false with every issue', () async {
    final answer = await call('plugins.devInstall', {'text': billsText.replaceFirst('"amber"', '"teal"').replaceFirst('"organise"', '"fun"')}) as Map;
    expect(answer['ok'], isFalse);
    expect(answer['id'], 'bills');
    expect(answer['on'], isFalse);
    expect({for (final i in answer['issues'] as List) (i as Map)['code']}, {'bad_hue', 'bad_shelf'});
    final notJson = await call('plugins.devInstall', {'text': 'not a plugin'}) as Map;
    expect([notJson['ok'], notJson['id']], [false, null]);
    expect((notJson['issues'] as List).single['code'], 'bad_json');
  });

  test('devRemove takes it away, and an id not loaded is not_found', () async {
    await call('plugins.devInstall', {'text': billsText});
    expect(await call('plugins.devRemove', {'id': 'bills'}), isNull);
    expect(InstalledPlugins.instance.dev, isEmpty);
    expect(PluginRegistry.instance.plugins.any((p) => p.id == 'xbills'), isFalse);
    await expectLater(call('plugins.devRemove', {'id': 'bills'}), apiError('not_found'));
  });

  test('plugins.list gives each plugin\'s source and version; filters.classify gives a pack\'s tags', () async {
    await call('plugins.devInstall', {'text': billsText});
    await InstalledPlugins.instance.agreeDev('bills');
    final list = (await call('plugins.list', {}) as List).cast<Map>();
    final codes = list.firstWhere((p) => p['id'] == 'codes');
    expect([codes['source'], codes['version']], ['builtIn', null]);
    final bills = list.firstWhere((p) => p['id'] == 'xbills');
    expect([bills['source'], bills['version'], bills['on'], bills['name']], ['dev', '1.0.0', true, 'Bills']);
    final classified = await call('filters.classify', {'text': 'Your bill is ready. Amount due: \$45.20 by 3 Dec. Pay at example.com/pay', 'from': '72975'}) as Map;
    expect((classified['tags'] as Map)['xbills.bill'], '\$45.20', reason: 'a text someone sent, which a pack sees');
    expect(classified['section'], 'reminders', reason: 'Kinds of text sorts it first');
  });
}
