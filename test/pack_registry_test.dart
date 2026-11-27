import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/list.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/tag_store.dart';
import 'package:ghost_messaging/sms.dart';

import 'support/test_plugins.dart';

/// The registry as plugins from other developers come and go while the app runs (lib/plugins/registry.dart; Matt,
/// 2026-11-20: "I would like users to be able to develop and submit their own plugins to our plugin marketplace"):
/// install, replace and uninstall never throw; the mark that says when to classify again moves with them; a filing
/// into a pack's section holds only while the pack may act; and what a plugin throws is heard, never thrown at a
/// screen or a build.
class _Made extends GhostPlugin {
  _Made(this.id, {this.sectionIds = const [], this.throws = false});
  @override
  final String id;
  final List<String> sectionIds;
  final bool throws;
  @override
  PluginSource get source => PluginSource.dev;
  @override
  String get name => 'Made $id';
  @override
  String get description => 'A plugin made up for the test.';
  @override
  bool get onByDefault => true;
  @override
  List<ListSection> get sections {
    if (throws) throw StateError('its sections can\'t be read');
    return [for (final s in sectionIds) ListSection(id: s, label: s, icon: Lucide.puzzle, takes: (f, tags, prefs) => false)];
  }
}

/// A plugin whose classifier throws: what the registry asks of it is heard, not thrown.
class _Broken extends GhostPlugin {
  @override
  String get id => 'broken';
  @override
  String get name => 'Broken';
  @override
  String get description => 'Throws.';
  @override
  List<Classifier> get classifiers => [(f) => throw StateError('no tags today')];
}

/// Senders that can't be counted: a pack asked about them throws inside the registry's own guard.
class _Boom extends ListBase<String> {
  @override
  int get length => throw StateError('boom');
  @override
  set length(int n) {}
  @override
  String operator [](int i) => throw StateError('boom');
  @override
  void operator []=(int i, String v) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
  });

  final billsBytes = File('test/fixtures/packs/bills.ghostplugin').readAsBytesSync();
  final bills = parsePack(billsBytes, appVersion: '0.10.1').pack!;
  MessageFacts textOf(String words, {int thread = 1, bool contact = false}) => MessageFacts(thread: thread, senders: const ['72975'], text: words, contact: contact, outgoing: false);

  test('the app\'s own registry has an onError from the start: its plugins\' errors reach the Developer log', () {
    expect(PluginRegistry.instance.onError, isNotNull);
    expect(PluginRegistry.instance.onError, same(logPluginError));
  });

  group('install, replace, uninstall', () {
    test('never throw, and give their codes', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      expect(registry.install(_Made('Bad')), 'bad_id');
      expect(registry.install(_Made('a' * 33)), 'bad_id');
      expect(registry.install(_Made('tickets')), 'id_taken');
      expect(registry.install(_Made('xone', sectionIds: ['Bad'])), 'bad_section');
      expect(registry.install(_Made('xone', sectionIds: ['other'])), 'bad_section');
      expect(registry.install(_Made('xone', sectionIds: ['a' * 49])), 'bad_section');
      expect(registry.install(_Made('xone', sectionIds: ['tickets'])), 'section_taken');
      expect(registry.install(_Made('xone', sectionIds: ['xone0a', 'xone0a'])), 'section_taken');
      expect(registry.install(_Made('xone', throws: true)), 'threw');
      expect(registry.plugins.map((p) => p.id), ['tickets']);
      expect(registry.install(_Made('xone', sectionIds: ['xone0a'])), isNull);
      expect(registry.plugins.map((p) => p.id), ['tickets', 'xone']);
      expect(registry.replace(_Made('xtwo')), 'missing');
      expect(registry.replace(_Made('xone', sectionIds: ['tickets'])), 'section_taken');
      expect(registry.replace(_Made('xone', throws: true)), 'threw');
      expect(registry.replace(_Made('xone', sectionIds: ['xone0a', 'xone0b'])), isNull, reason: 'its own old sections are no one else\'s');
      expect(registry.sections(MemoryStore()).map((s) => s.id), ['tickets', 'xone0a', 'xone0b']);
      expect(PluginRegistry(shippedPlugins).replace(_Made('codes')), 'built_in');
      expect(PluginRegistry(shippedPlugins).uninstall('spam'), isFalse);
      expect(registry.uninstall('xnone'), isFalse);
      expect(registry.uninstall('xone'), isTrue);
      expect(registry.plugins.map((p) => p.id), ['tickets']);
      expect(registry.uninstall('tickets'), isTrue, reason: 'only the shipped plugins stay whatever is asked');
    });

    test('an update keeps its place, so its sections keep their precedence', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      registry.install(_Made('xone', sectionIds: ['xone0a']));
      registry.install(_Made('xtwo', sectionIds: ['xtwo0a']));
      registry.replace(_Made('xone', sectionIds: ['xone0a']));
      expect(registry.plugins.map((p) => p.id), ['tickets', 'xone', 'xtwo']);
    });

    test('version and listeners: each change is told, and only a change', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      var told = 0;
      registry.addListener(() => told++);
      expect(registry.version, 0);
      registry.install(_Made('xone'));
      registry.replace(_Made('xone'));
      registry.uninstall('xone');
      expect(registry.version, 3);
      expect(told, 3);
      registry.install(_Made('Bad'));
      registry.uninstall('xone');
      expect([registry.version, told], [3, 3]);
    });

    test('switches changes on install, replace and uninstall: what was worked out is worked out again', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      final store = MemoryStore();
      final marks = <String>{registry.switches(store)};
      registry.install(_Made('xone'));
      expect(marks.add(registry.switches(store)), isTrue);
      registry.replace(_Made('xone'));
      expect(marks.add(registry.switches(store)), isTrue, reason: 'the same switches, another copy');
      registry.uninstall('xone');
      expect(marks.add(registry.switches(store)), isTrue);
    });

    test('a TagStore bound before a replace holds the new copy\'s tags after the next bind', () {
      final registry = PluginRegistry([PackPlugin(bills, source: PluginSource.dev)]);
      final store = MemoryStore({'plugin_xbills': 'on'});
      final tags = TagStore(registry);
      addTearDown(tags.dispose);
      tags.bind(store);
      tags.take([Conversation.from({'id': 4, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': 'Your council tax is due next week.', 'heard': 'Your council tax is due next week.'})]);
      expect(tags.of(4).has('xbills.bill'), isFalse);
      final rules = Map<String, Object?>.of(bills.json['rules'] as Map<String, Object?>);
      final first = Map<String, Object?>.of((rules['tags'] as List).first as Map<String, Object?>);
      first['any'] = [...first['any'] as List, 'council tax'];
      rules['tags'] = [first, (rules['tags'] as List)[1]];
      final newer = parsePackJson({...bills.json, 'version': '1.1.0', 'rules': rules}, appVersion: '0.10.1').pack!;
      expect(registry.replace(PackPlugin(newer, source: PluginSource.dev)), isNull);
      tags.bind(store);
      expect(tags.of(4).has('xbills.bill'), isTrue);
    });

    test('a list made before an install sorts into the new sections once it is bound again, as every build binds it', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: registry);
      addTearDown(list.dispose);
      final app = AppState();
      list.bind(app);
      final all = [
        Conversation.from({'id': 1, 'date': 2000, 'people': [{'address': '72975'}], 'snippet': 'Your bill is ready', 'heard': 'Your bill is ready'}),
        Conversation.from({'id': 2, 'date': 1000, 'people': [{'address': '72976'}], 'snippet': 'Dinner?', 'heard': 'Dinner?'}),
      ];
      list.take(all);
      expect(list.sort(all).counts, isEmpty);
      final plugin = PackPlugin(bills, source: PluginSource.dev);
      expect(registry.install(plugin), isNull);
      registry.setOn(plugin, AppStore(app), true);
      list.bind(app);
      expect(list.sort(all).counts, {'xbills0bills': 1});
      expect(list.pick(all, 'xbills0bills', searching: false).map((c) => c.id), [1]);
    });
  });

  group('filings', () {
    test('a filing into a pack\'s section holds only while the pack may act; a built-in\'s holds whatever', () {
      final pack = PackPlugin(bills, source: PluginSource.dev);
      final registry = PluginRegistry([TicketsPlugin(), pack]);
      final store = MemoryStore({'plugin_xbills': 'on', Filing.key: '5:xbills0bills,6:tickets,7:xbills0bills'});
      final contact = textOf('Your bill is ready', thread: 5, contact: true);
      expect(registry.sectionOf(contact, registry.classify(contact, store), store), isNull, reason: 'a contact\'s texts never stay in a pack\'s tab');
      final code = textOf('Your code is 482913', thread: 7);
      expect(registry.sectionOf(code, registry.classify(code, store), store), isNull, reason: 'nor a sign-in code');
      final stranger = textOf('Dinner at 8?', thread: 5);
      expect(registry.sectionOf(stranger, registry.classify(stranger, store), store)?.id, 'xbills0bills', reason: 'filed, a stranger\'s text stays where it was put');
      final ticket = textOf('Dinner at 8?', thread: 6, contact: true);
      expect(registry.sectionOf(ticket, registry.classify(ticket, store), store)?.id, 'tickets', reason: 'a built-in\'s filing is as it was');
      final paused = PackPlugin(bills, source: PluginSource.dev, paused: true);
      final pausedRegistry = PluginRegistry([paused]);
      expect(pausedRegistry.sectionOf(stranger, TagSet.none, store), isNull, reason: 'a paused pack\'s filings are passed over');
    });
  });

  test('no shipped plugin\'s id or section id starts with x or is other, and every built-in\'s labels are store tags', () {
    for (final p in shippedPlugins) {
      expect(p.id.startsWith('x'), isFalse, reason: p.id);
      expect(p.id, isNot('other'));
      for (final s in p.sections) {
        expect(s.id.startsWith('x'), isFalse, reason: s.id);
        expect(s.id, isNot('other'));
      }
      for (final l in p.labels) {
        expect(packLabels.keys, contains(l), reason: '${p.id}: $l');
      }
      expect(p.source, PluginSource.builtIn);
    }
    final labels = {for (final p in shippedPlugins) if (p.labels.isNotEmpty) p.id: p.labels};
    expect(labels, {
      'codes': ['codes'],
      'kinds': ['sorting', 'filters'],
      'spam': ['safety', 'filters'],
      'quiet': ['quiet'],
      'translate': ['language'],
      'replies': ['replies'],
      'strangers': ['safety'],
      'humancheck': ['safety', 'filters'],
      'cleaner': ['sorting'],
    });
    expect(PluginRegistry.shippedIds, {for (final p in shippedPlugins) p.id});
  });

  group('errors', () {
    test('runPluginAction catches what a button throws and tells the registry', () async {
      final heard = <String>[];
      final registry = PluginRegistry([TicketsPlugin()], onError: (p, e) => heard.add('${p.id} $e'));
      final plugin = registry.plugins.single;
      await runPluginAction(registry, plugin, PluginAction(label: 'Fail', icon: Lucide.x, run: (_) => throw StateError('pressed')), PluginHostThatSays());
      await runPluginAction(registry, plugin, PluginAction(label: 'Fail later', icon: Lucide.x, run: (_) async => throw StateError('later')), PluginHostThatSays());
      expect(heard, ['tickets Bad state: pressed', 'tickets Bad state: later']);
    });

    test('error listeners hear what the registry asks and what it is told failed, each on its own', () {
      final heard = <String>[];
      final registry = PluginRegistry([_Broken()], onError: (p, e) => heard.add('onError'));
      void first(GhostPlugin p, Object e) => heard.add('first');
      void throwing(GhostPlugin p, Object e) => throw StateError('a listener that breaks');
      void last(GhostPlugin p, Object e) => heard.add('last');
      registry
        ..addErrorListener(first)
        ..addErrorListener(throwing)
        ..addErrorListener(last);
      expect(registry.classify(textOf('hello'), MemoryStore()).isEmpty, isTrue);
      expect(heard, ['onError', 'first', 'last']);
      registry.failed(registry.plugins.single, StateError('later'));
      expect(heard, ['onError', 'first', 'last', 'onError', 'first', 'last']);
      registry.removeErrorListener(first);
      registry.failed(registry.plugins.single, StateError('again'));
      expect(heard.skip(6), ['onError', 'last']);
    });

    testWidgets('a pack in development that throws in takes while a ListenableBuilder on InstalledPlugins.instance is mounted raises no FlutterError', (tester) async {
      final root = Directory.systemTemp.createTempSync('pack-registry-');
      addTearDown(() => root.deleteSync(recursive: true));
      final registry = PluginRegistry([TicketsPlugin()]);
      final installed = InstalledPlugins(root: root, registry: registry, reviewKeys: const [], storeAllowed: true, devAllowed: true);
      final was = InstalledPlugins.instance;
      InstalledPlugins.instance = installed;
      addTearDown(() => InstalledPlugins.instance = was);
      final app = AppState()..set('dev_mode', 'on');
      await installed.load(app, appVersion: '0.10.1');
      expect((await installed.loadDev(billsBytes, const DevSource('paste'))).ok, isTrue);
      expect((await installed.agreeDev('bills')).ok, isTrue);
      final store = AppStore(app);
      final boom = MessageFacts(thread: 3, senders: _Boom(), text: 'Your bill is ready', contact: false, outgoing: false);
      var builds = 0;
      await tester.pumpWidget(ListenableBuilder(
        listenable: InstalledPlugins.instance,
        builder: (context, _) {
          builds++;
          // As the list does while it builds: the pack throws in its section's takes, and the registry hears it.
          registry.sectionOf(boom, TagSet.none, store);
          return const SizedBox();
        },
      ));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final errors = installed.devOf('bills')!.errors;
      expect(errors, hasLength(1), reason: 'the same error again at once is one line');
      expect(errors.single.line, contains('boom'));
      expect(builds, lessThan(4), reason: 'told once, after the build, and not again for the same error');
    });
  });
}

/// A host that does nothing: what a button that throws is run with.
class PluginHostThatSays implements PluginHost {
  @override
  PluginPrefs get prefs => PluginPrefs.none;
  @override
  void say(String words) {}
  @override
  void copy(String text, {String? say}) {}
  @override
  void open(int thread) {}
  @override
  Future<void> markRead(int thread) async {}
  @override
  void move(int thread, String? section) {}
  @override
  void write(String text) {}
  @override
  void present(WidgetBuilder page) {}
  @override
  Future<void> deleteThread(int thread) async {}
  @override
  Future<void> reload() async {}
}
