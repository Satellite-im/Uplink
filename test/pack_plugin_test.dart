import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/plugins/list.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/sms.dart';

/// A plugin from another developer as the app runs it (lib/plugins/pack/pack_plugin.dart; Matt, 2026-11-20: "I would
/// like users to be able to develop and submit their own plugins to our plugin marketplace"): the docs' Bills and
/// Parcels on the format's sample texts, alone and beside the built-ins; what such a plugin never sees; its rows, its
/// buttons and the host they go through; its rule for texts as they come and its one-shot mute; its settings and the
/// words its page and consent sheet say; and its pause when it slows the app down, timed by a clock the test drives.
PluginPack packOf(String name) => parsePack(File('test/fixtures/packs/$name.ghostplugin').readAsBytesSync(), appVersion: '0.10.1').pack!;

final _noon = DateTime(2026, 11, 20, 12);
DateTime _still() => _noon;

/// A text from [from], not a contact's, theirs, one to one: what a pack sees.
MessageFacts textOf(String words, {int thread = 1, String from = '72975', bool contact = false, bool? outgoing = false, bool group = false, bool encrypted = false, String? network, List<String>? senders, bool unread = false}) =>
    MessageFacts(thread: thread, senders: senders ?? [from], text: words, contact: contact, outgoing: outgoing, group: group, encrypted: encrypted, network: network, unread: unread);

String sample(String id) => packSamples.firstWhere((s) => s.id == id).text;

/// A host that writes down what it was asked.
class Recorder implements PluginHost {
  Recorder([this.prefs = PluginPrefs.none]);
  @override
  final PluginPrefs prefs;
  final did = <String>[];
  @override
  void say(String words) => did.add('say $words');
  @override
  void copy(String text, {String? say}) => did.add('copy $text / $say');
  @override
  void open(int thread) => did.add('open $thread');
  @override
  Future<void> markRead(int thread) async => did.add('read $thread');
  @override
  void move(int thread, String? section) => did.add('move $thread $section');
  @override
  void write(String text) => did.add('write $text');
  @override
  void present(WidgetBuilder page) => did.add('present');
  @override
  Future<void> deleteThread(int thread) async => did.add('delete $thread');
  @override
  Future<void> reload() async => did.add('reload');
}

/// What the plugins' side asked of the phone, counted.
class FakeEffects implements PluginEffects {
  final did = <String>[];
  @override
  Future<void> markRead(int thread) async => did.add('read $thread');
  @override
  Future<void> mute(int thread, bool muted) async => did.add('mute $thread $muted');
  @override
  Future<void> deleteThread(int thread) async => did.add('delete $thread');
  @override
  Future<void> cancelNotification(int thread) async => did.add('cancel $thread');

  /// The conversations with a sign-in code waiting unread under newer words, and those the phone was asked about.
  final codes = <int>{};
  final asked = <int>[];
  @override
  Future<bool> codeWaiting(int thread) async {
    asked.add(thread);
    return codes.contains(thread);
  }

  /// The words still unread in each conversation, newest first, as the phone would say them; a conversation not in it
  /// has nothing unread but the text the rule was asked about. Null: the phone couldn't say.
  final unread = <int, List<String>?>{};
  final askedUnread = <int>[];
  @override
  Future<List<String>?> unreadIncoming(int thread) async {
    askedUnread.add(thread);
    return unread.containsKey(thread) ? unread[thread] : const [];
  }
}

/// The calls of a computer: no phone's channel, so Sms.remote.
class _Computer implements SmsCalls {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;
}

/// A built-in that silences what it tags, to set a pack's mute beside a built-in's.
class _Hush extends GhostPlugin {
  const _Hush();
  @override
  String get id => 'hush';
  @override
  String get name => 'Hush';
  @override
  String get description => 'Silences parcel texts.';
  @override
  List<Classifier> get classifiers => [(f) => f.text.contains('delivery') ? const [Tag('hush')] : const []];
  @override
  List<ListSection> get sections => [ListSection(id: 'hushed', label: 'Hushed', icon: Lucide.bell, takes: (f, tags, prefs) => tags.has('hush'))];
  @override
  List<IncomingRule> get incoming => [(f, tags, section, prefs) => section == 'hushed' ? const [MuteNotification()] : const []];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
  });

  final bills = packOf('bills');
  final parcels = packOf('parcels');

  /// [pack] alone in a registry, switched on, its own choices [prefs] over its defaults.
  (PluginRegistry, PackPlugin, MemoryStore) alone(PluginPack pack, {Map<String, String> prefs = const {}, DateTime Function()? now}) {
    late final PluginRegistry registry;
    final plugin = PackPlugin(pack, source: PluginSource.dev, now: now ?? _still, onError: (p, e) => registry.failed(p, e));
    registry = PluginRegistry([plugin]);
    final store = MemoryStore({'plugin_${plugin.id}': 'on', for (final e in prefs.entries) 'plugin_${plugin.id}_${e.key}': e.value});
    return (registry, plugin, store);
  }

  /// The pack's own tags of [t] (no x<id>. before them) and the section key it is in.
  (Map<String, String?>, String?) run(PluginRegistry registry, MemoryStore store, PluginPack pack, MessageFacts t) {
    final tags = registry.classify(t, store);
    final prefix = 'x${pack.id}.';
    final own = {for (final n in tags.names) if (n.startsWith(prefix)) n.substring(prefix.length): tags.detail(n)};
    final section = registry.sectionOf(t, tags, store)?.id;
    return (own, section?.startsWith('x${pack.id}0') ?? false ? section!.substring('x${pack.id}0'.length) : section);
  }

  group('the A.15 corpus, each pack alone in a registry', () {
    // Each sample's own tags and section: Bills, Bills with extra words, Parcels, Parcels loose.
    const billsTable = <String, (Map<String, String?>, String?)>{
      's01': ({'bill': '\$45.20'}, 'bills'),
      's02': ({'bill': null}, 'bills'),
      's03': ({'paid': null}, 'receipts'),
      's04': ({'paid': '€12,50'}, 'receipts'),
      's05': ({'bill': null}, 'bills'),
    };
    const parcelsTable = <String, (Map<String, String?>, String?)>{
      's07': ({'parcel': null, 'track': '1Z999AA10123456784'}, 'parcels'),
      's08': ({'parcel': null}, 'parcels'),
      's09': ({'parcel': null}, 'parcels'),
      's11': ({'parcel': null, 'track': 'JD014600006295117'}, 'parcels'),
    };
    void corpus(PluginPack pack, Map<String, String> prefs, Map<String, (Map<String, String?>, String?)> want) {
      final (registry, _, store) = alone(pack, prefs: prefs);
      for (final s in packSamples) {
        final (tags, section) = run(registry, store, pack, textOf(s.text, from: s.from));
        final (wantTags, wantSection) = want[s.id] ?? (const <String, String?>{}, null);
        expect(tags, wantTags, reason: '${s.id} tags');
        expect(section, wantSection, reason: '${s.id} section');
      }
    }

    test('Bills at its defaults', () => corpus(bills, const {}, billsTable));
    test('Bills with extra = "council tax, water rates"', () => corpus(bills, const {'extra': 'council tax, water rates'}, {...billsTable, 's06': ({'bill': null}, 'bills')}));
    test('Parcels at its defaults', () => corpus(parcels, const {}, parcelsTable));
    test('Parcels with level = loose', () => corpus(parcels, const {'level': 'loose'}, {...parcelsTable, 's10': ({'parcel': null}, 'parcels')}));

    test('its tags are its own, x<id>.<tag>, never spam or code, and its sections are x<id>0<key>', () {
      final (registry, plugin, store) = alone(bills);
      final tags = registry.classify(textOf(sample('s01')), store);
      expect(tags.names, ['xbills.bill']);
      expect(tags.detail('xbills.bill'), '\$45.20');
      expect(plugin.sections.map((s) => s.id), ['xbills0bills', 'xbills0receipts']);
      expect(plugin.sections.map((s) => s.filter), [false, true]);
      expect(plugin.sections.map((s) => s.hidden), [false, false], reason: 'a pack\'s kinds start shown');
      final code = registry.classify(textOf(sample('s12')), store);
      expect(code.isEmpty, isTrue);
    });
  });

  group('beside the built-ins at their defaults', () {
    test('Kinds of text takes s01 and s07 first, while the packs still tag them; with those kinds off they are the packs\'', () {
      for (final (pack, id, sectionWant, tagWant) in [(bills, 's01', 'reminders', ('xbills.bill', '\$45.20')), (parcels, 's07', 'deliveries', ('xparcels.track', '1Z999AA10123456784'))]) {
        final plugin = PackPlugin(pack, source: PluginSource.reviewed, now: _still);
        final registry = PluginRegistry([...shippedPlugins, plugin]);
        final store = MemoryStore({'plugin_${plugin.id}': 'on'});
        final t = textOf(sample(id));
        final tags = registry.classify(t, store);
        expect(registry.sectionOf(t, tags, store)?.id, sectionWant, reason: id);
        expect(tags.has(tagWant.$1), isTrue);
        expect(tags.detail(tagWant.$1), tagWant.$2);
        final off = MemoryStore({'plugin_${plugin.id}': 'on', 'plugin_kinds_kind_reminders': 'off', 'plugin_kinds_kind_deliveries': 'off'});
        final offTags = registry.classify(t, off);
        expect(registry.sectionOf(t, offTags, off)?.id, pack == bills ? 'xbills0bills' : 'xparcels0parcels', reason: '$id with the kinds off');
        final s12 = textOf(sample('s12'));
        expect(registry.sectionOf(s12, registry.classify(s12, store), store)?.id, 'codes', reason: 'a code is Codes\', whatever pack is added');
      }
    });

    test('tryPack says which built-in takes a text first, given the person\'s choices', () {
      final beside = PluginRegistry(shippedPlugins);
      final trial = tryPack(bills, text: sample('s01'), beside: beside, store: MemoryStore());
      expect(trial.tags, {'bill': '\$45.20'});
      expect(trial.section, 'bills');
      expect(trial.shadowedBy, 'Kinds of text › Payment reminders');
      expect(tryPack(bills, text: sample('s01'), beside: beside, store: MemoryStore({'plugin_kinds_kind_reminders': 'off'})).shadowedBy, isNull);
      expect(tryPack(bills, text: sample('s01'), beside: beside).shadowedBy, isNull, reason: 'no store, no word of it');
      expect(trial.actions, {'row': ['Copy the amount'], 'list.conversation.menu': ['Copy the amount'], 'conversation.message.menu': ['Copy the amount']});
      expect(trial.row!.value, '\$45.20');
      expect(trial.seen, isTrue);
      final receipt = tryPack(bills, text: sample('s03'), switchesOn: true);
      expect(receipt.section, 'receipts');
      expect(receipt.incoming, ['markread']);
      expect(tryPack(bills, text: sample('s03')).incoming, isEmpty, reason: 'its switch is off until switched on');
      expect(tryPack(bills, text: sample('s06'), prefs: const {'extra': 'council tax'}).tags, {'bill': null});
    });
  });

  group('what a pack never sees', () {
    test('A.15\'s cases, with s01\'s text', () {
      final (registry, _, store) = alone(bills);
      final s01 = sample('s01');
      final unseen = <String, MessageFacts>{
        'a contact': textOf(s01, contact: true),
        'the person\'s own words': textOf(s01, outgoing: true),
        'a list row with nothing heard': textOf(s01, outgoing: null),
        'a group of two strangers': textOf(s01, group: true, senders: const ['72975', '72976']),
        'an encrypted text': textOf(s01, encrypted: true),
        'a Telegram chat': textOf(s01, thread: ListPlugins.chatThread('telegram:5')),
        'a space\'s message': textOf(s01, thread: -1, network: 'space'),
        'a friend by username': textOf(s01, senders: const ['@maya']),
        'Telegram by name': textOf(s01, network: 'telegram'),
      };
      for (final e in unseen.entries) {
        expect(registry.classify(e.value, store).isEmpty, isTrue, reason: e.key);
        expect(packSees(e.value), isFalse, reason: e.key);
      }
      final api = MessageFacts(thread: 0, senders: const ['+15555550100'], text: s01, contact: false, outgoing: false);
      expect(registry.classify(api, store).detail('xbills.bill'), '\$45.20', reason: 'filters.classify sees as a stranger\'s text would');
    });

    test('a list row says outgoing: false only where something was heard from a stranger', () {
      Conversation c({String? heard, String snippet = 'Your bill is ready'}) => Conversation.from({'id': 3, 'date': 1, 'people': [{'address': '72975'}], 'snippet': snippet, 'heard': heard});
      expect(MessageFacts.conversation(c(heard: 'Your bill is ready')).outgoing, isFalse);
      expect(MessageFacts.conversation(c()).outgoing, isNull, reason: 'its last words may be the person\'s own');
      expect(packSees(MessageFacts.conversation(c())), isFalse);
      expect(packSees(MessageFacts.conversation(c(heard: 'Your bill is ready'))), isTrue);
      final encrypted = Conversation.from({'id': 3, 'date': 1, 'people': [{'address': '72975'}], 'snippet': 'x', 'heard': 'Your bill is ready', 'encrypted': true});
      expect(MessageFacts.conversation(encrypted).encrypted, isTrue);
      expect(MessageFacts.conversation(encrypted).toJson()['encrypted'], isTrue);
    });

    test('a conversation filed into its section by hand, whose sender became a contact, is in the main list and asks its rule nothing', () {
      final (registry, _, _) = alone(bills);
      final store = MemoryStore({'plugin_xbills': 'on', 'plugin_xbills_autoread': 'on', Filing.key: '5:xbills0receipts,6:xbills0bills'});
      final contact = textOf(sample('s03'), thread: 5, contact: true, unread: true);
      final tags = registry.classify(contact, store);
      expect(registry.sectionOf(contact, tags, store), isNull);
      expect(registry.incoming(contact, tags, store), isEmpty);
      final stranger = textOf(sample('s03'), thread: 5, unread: true);
      expect(registry.sectionOf(stranger, registry.classify(stranger, store), store)?.id, 'xbills0receipts', reason: 'the filing holds again once the facts do');
      expect(registry.incoming(stranger, registry.classify(stranger, store), store).single.action, isA<MarkRead>());
    });

    test('s12 filed into Bills\' tab is in Codes, or the main list with Codes off, and asks no pack\'s rule', () {
      final plugin = PackPlugin(bills, source: PluginSource.reviewed, now: _still);
      final registry = PluginRegistry([const CodesPlugin(), plugin]);
      final on = MemoryStore({'plugin_xbills': 'on', 'plugin_xbills_autoread': 'on', Filing.key: '6:xbills0bills'});
      final code = textOf(sample('s12'), thread: 6, unread: true);
      expect(registry.sectionOf(code, registry.classify(code, on), on)?.id, 'codes');
      final off = MemoryStore({...on.values, 'plugin_codes': 'off'});
      expect(registry.sectionOf(code, registry.classify(code, off), off), isNull);
      expect(registry.incoming(code, registry.classify(code, on), on).where((b) => b.plugin == plugin), isEmpty);
    });
  });

  group('rows', () {
    test('value, caption, face and end, from its tags', () {
      final (registry, plugin, store) = alone(parcels);
      final t = textOf(sample('s07'));
      final tags = registry.classify(t, store);
      final look = plugin.sections.single.row!(t, tags, registry.prefsOf(plugin, store))!;
      expect(look.value, '1Z999AA10123456784');
      expect(look.caption, 'A parcel');
      expect(look.face!.name, 'Parcels');
      expect(look.face!.color, 0x4F46E5);
      expect(look.face!.domain, isNull);
      expect(look.title, isNull, reason: 'a row keeps its conversation\'s own name');
      expect(look.end!.label, 'Copy the tracking number');
      expect(look.tap, isNull);
    });

    test('a tag with no detail leaves the value out, and a copy with nothing to copy isn\'t offered', () {
      final (registry, plugin, store) = alone(parcels);
      final t = textOf(sample('s08'));
      final look = plugin.sections.single.row!(t, registry.classify(t, store), registry.prefsOf(plugin, store))!;
      expect(look.value, isNull);
      expect(look.caption, 'A parcel');
      expect(look.end, isNull);
    });

    test('no row for a text with a sign-in code in it, nor while it is paused', () {
      final (registry, plugin, store) = alone(bills);
      final t = textOf('Your bill is ready. Amount due: \$45.20. Your code is 482913.');
      final tags = registry.classify(t, store);
      expect(tags.has('xbills.bill'), isTrue, reason: 'it can tag a bank\'s code');
      expect(plugin.sections.first.row!(t, tags, registry.prefsOf(plugin, store)), isNull, reason: 'never draw or hide it');
      expect(plugin.sections.first.takes(t, tags, registry.prefsOf(plugin, store)), isFalse);
      final paused = PackPlugin(bills, source: PluginSource.dev, paused: true);
      final s01 = textOf(sample('s01'));
      expect(paused.sections.first.row!(s01, registry.classify(s01, store), PluginPrefs.none), isNull);
    });

    test('a value longer than its room is cut with an ellipsis', () {
      final rules = Map<String, Object?>.of(parcels.json['rules'] as Map<String, Object?>);
      final section = Map<String, Object?>.of((rules['sections'] as List).single as Map<String, Object?>);
      section['row'] = {...section['row'] as Map, 'value': 'Tracking {tag:track}'};
      rules['sections'] = [section];
      final longer = parsePackJson({...parcels.json, 'rules': rules}, appVersion: '0.10.1').pack!;
      final (registry, plugin, store) = alone(longer);
      final t = textOf(sample('s11'));
      final look = plugin.sections.single.row!(t, registry.classify(t, store), registry.prefsOf(plugin, store))!;
      expect(look.value, 'Tracking JD014600006295…');
      expect(look.value, hasLength(24));
    });
  });

  group('buttons', () {
    test('each in the places it names, where its condition holds, its section the place\'s', () {
      final (registry, _, store) = alone(parcels);
      final t = textOf(sample('s07'));
      final tags = registry.classify(t, store);
      List<String> at<P>(ActionSlot<P> slot, P place) => [for (final b in registry.actions(slot, place, store)) b.action.label];
      expect(at(Slots.conversationMenu, ConversationPlace(t, tags, section: 'xparcels0parcels')), ['Copy the tracking number', 'Where\'s my parcel?', 'Not a parcel']);
      expect(at(Slots.conversationMenu, ConversationPlace(t, tags)), ['Copy the tracking number', 'Where\'s my parcel?'], reason: '"Not a parcel" only in its tab');
      expect(at(Slots.conversationHeader, ConversationPlace(t, tags, section: 'xparcels0parcels')), ['Copy the tracking number']);
      expect(at(Slots.messageMenu, MessagePlace(t, tags)), ['Ask for it to go to a neighbour']);
      final s08 = textOf(sample('s08'));
      expect(at(Slots.conversationMenu, ConversationPlace(s08, registry.classify(s08, store), section: 'xparcels0parcels')), ['Where\'s my parcel?', 'Not a parcel'], reason: 'nothing to copy');
      final contact = textOf(sample('s07'), contact: true);
      expect(at(Slots.conversationMenu, ConversationPlace(contact, tags, section: 'xparcels0parcels')), isEmpty, reason: 'never offered on what it doesn\'t see');
      expect(at(Slots.listHeader, const ListPlace()), isEmpty, reason: 'no slot it doesn\'t name');
    });

    test('pressed, each goes through the gated host: copy, write, move, link', () async {
      final links = <String>[];
      late final PluginRegistry registry;
      final plugin = PackPlugin(parcels, source: PluginSource.reviewed, now: _still, onError: (p, e) => registry.failed(p, e), openLink: (url) async {
        links.add(url);
        return true;
      });
      registry = PluginRegistry([plugin]);
      final store = MemoryStore({'plugin_xparcels': 'on'});
      final t = textOf(sample('s07'), thread: 9);
      final tags = registry.classify(t, store);
      final host = Recorder();
      for (final b in [...registry.actions(Slots.conversationMenu, ConversationPlace(t, tags, section: 'xparcels0parcels'), store), ...registry.actions(Slots.messageMenu, MessagePlace(t, tags), store)]) {
        await runPluginAction(registry, b.plugin, b.action, host);
      }
      expect(host.did, ['copy 1Z999AA10123456784 / Tracking number copied', 'move 9 null', 'write If I\'m out, please leave it with a neighbour. Thank you!']);
      expect(links, ['https://example.com/plugins/parcels/help']);
    });

    test('what a button throws is told to its registry, and the screen goes on', () async {
      final heard = <Object>[];
      final registry = PluginRegistry([PackPlugin(bills, source: PluginSource.dev, now: _still)], onError: (p, e) => heard.add(e));
      final plugin = registry.plugins.single as PackPlugin;
      final store = MemoryStore({'plugin_xbills': 'on'});
      final t = textOf(sample('s01'));
      final b = registry.actions(Slots.conversationMenu, ConversationPlace(t, registry.classify(t, store)), store).single;
      await b.action.run(_Throws());
      expect(heard, isEmpty, reason: 'PluginRegistry.instance hears it, as no onError was given to the plugin');
      final told = <Object>[];
      final own = PackPlugin(bills, source: PluginSource.dev, now: _still, onError: (p, e) => told.add(e));
      final b2 = PluginRegistry([own]).actions(Slots.conversationMenu, ConversationPlace(t, registry.classify(t, store)), store).single;
      await b2.action.run(_Throws());
      expect(told.single, isA<StateError>());
      expect(plugin.id, 'xbills');
    });
  });

  group('the gated host', () {
    (GatedHost, Recorder, List<String>, List<Object>) gated(PluginPack pack, {int thread = 4, DateTime Function()? now, Future<bool> Function(String)? openLink}) {
      final trouble = <String>[];
      final errors = <Object>[];
      final plugin = PackPlugin(pack, source: PluginSource.dev, now: now ?? _still, onTrouble: (p, w) => trouble.add(w), onError: (p, e) => errors.add(e));
      final inner = Recorder();
      return (GatedHost(inner, plugin: plugin, thread: thread, openLink: openLink), inner, trouble, errors);
    }

    test('move only this conversation, into Messages or one of its own tabs', () {
      final (host, inner, trouble, errors) = gated(parcels);
      host.move(4, 'xparcels0parcels');
      host.move(4, null);
      host.move(4, 'codes');
      host.move(4, 'xbills0bills');
      host.move(5, null);
      expect(inner.did, ['move 4 xparcels0parcels', 'move 4 null']);
      expect(trouble, ['refused move', 'refused move', 'refused move']);
      expect(errors.map((e) => '$e'), everyElement(contains('move refused for xparcels')));
    });

    test('move to its own filter kind is refused, and so is a move without the permission', () {
      final (host, inner, trouble, _) = gated(bills);
      host.move(4, 'xbills0receipts');
      host.move(4, 'xbills0bills');
      expect(inner.did, isEmpty, reason: 'Bills has no move permission, and receipts is a kind');
      expect(trouble, ['refused move', 'refused move']);
      final withMove = parsePackJson({...bills.json, 'permissions': ['sort', 'copy', 'markread', 'move'], 'rules': {...bills.json['rules'] as Map, 'actions': [...(bills.json['rules'] as Map)['actions'] as List, {'id': 'tobills', 'label': 'It\'s a bill', 'icon': 'calculator', 'slots': ['list.conversation.menu'], 'do': 'move', 'to': 'bills'}]}}, appVersion: '0.10.1').pack!;
      final (moving, moved, refused, _) = gated(withMove);
      moving.move(4, 'xbills0receipts');
      moving.move(4, 'xbills0bills');
      expect(moved.did, ['move 4 xbills0bills']);
      expect(refused, ['refused move']);
    });

    test('markRead of this conversation only; open, present and deleteThread never', () async {
      final (host, inner, trouble, _) = gated(bills);
      await host.markRead(4);
      await host.markRead(5);
      host.open(4);
      host.present((_) => const SizedBox());
      await host.deleteThread(4);
      await host.reload();
      expect(inner.did, ['read 4', 'reload']);
      expect(trouble, ['refused markread', 'refused open', 'refused present', 'refused deleteThread']);
    });

    test('a link only to its one address, and only with the permission', () async {
      final opened = <String>[];
      Future<bool> open(String url) async {
        opened.add(url);
        return true;
      }

      final (host, _, trouble, _) = gated(parcels, openLink: open);
      await host.openLink('https://example.com/plugins/parcels/help');
      await host.openLink('https://example.com/elsewhere');
      expect(opened, ['https://example.com/plugins/parcels/help']);
      expect(trouble, ['refused link']);
      final (billsHost, _, billsTrouble, _) = gated(bills, openLink: open);
      await billsHost.openLink('https://example.com/plugins/parcels/help');
      expect(billsTrouble, ['refused link']);
    });

    test('copy and write need their permissions and are cut; say and copy are held to a pace', () {
      var at = _noon;
      final (host, inner, trouble, _) = gated(parcels, now: () => at);
      host.copy('x' * 250, say: 'y' * 90);
      host.write('w' * 320);
      expect(inner.did, ['copy ${'x' * 200} / ${'y' * 80}', 'write ${'w' * 300}']);
      host.say('Hello');
      host.say('Again');
      at = at.add(const Duration(milliseconds: 1600));
      host.say('z' * 90);
      expect(inner.did.skip(2), ['say Hello', 'say ${'z' * 80}']);
      for (var i = 0; i < 12; i++) {
        host.copy('$i');
      }
      expect(inner.did.where((d) => d.startsWith('copy')), hasLength(10), reason: 'ten a minute, the first among them');
      at = at.add(const Duration(minutes: 1));
      host.copy('later');
      expect(inner.did.last, 'copy later / null');
      expect(trouble, ['refused say', 'refused copy', 'refused copy', 'refused copy']);
      final (billsHost, billsInner, billsTrouble, _) = gated(bills);
      billsHost.write('Hi');
      expect(billsInner.did, isEmpty);
      expect(billsTrouble, ['refused write']);
    });
  });

  group('texts as they come', () {
    test('only with its switch on, only in its section, never for a code text', () {
      final (registry, plugin, _) = alone(bills);
      final rule = plugin.incoming.single;
      final t = textOf(sample('s03'), unread: true);
      final tags = registry.classify(t, MemoryStore({'plugin_xbills': 'on'}));
      final off = registry.prefsOf(plugin, MemoryStore({'plugin_xbills': 'on'}));
      final on = registry.prefsOf(plugin, MemoryStore({'plugin_xbills': 'on', 'plugin_xbills_autoread': 'on'}));
      expect(rule(t, tags, 'xbills0receipts', off), isEmpty);
      expect(rule(t, tags, 'xbills0receipts', on), [isA<MarkRead>()]);
      expect(rule(t, tags, 'xbills0bills', on), isEmpty);
      expect(rule(t, tags, null, on), isEmpty);
      final code = textOf('Thank you for your payment. Your code is 482913.', unread: true);
      expect(rule(code, tags, 'xbills0receipts', on), isEmpty);
      expect(PackPlugin(bills, source: PluginSource.dev, paused: true).incoming.single(t, tags, 'xbills0receipts', on), isEmpty);
    });

    test('its mute takes away one text\'s notification and nothing else; a built-in\'s mutes the conversation', () async {
      for (final builtIn in [false, true]) {
        final effects = FakeEffects();
        final plugin = builtIn ? const _Hush() : PackPlugin(parcels, source: PluginSource.reviewed, now: _still);
        final registry = PluginRegistry([plugin]);
        final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: registry, effects: effects);
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_${plugin.id}', 'on')
          ..set('plugin_${plugin.id}_quiet', 'on');
        list.bind(app);
        list.take([
          Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': sample('s08'), 'heard': sample('s08'), 'unread': true}),
        ]);
        for (var i = 0; i < 20 && effects.did.isEmpty; i++) {
          await pumpEventQueue();
        }
        if (builtIn) {
          expect(effects.did, ['mute 7 true']);
          expect(app.choice(ListPlugins.mutedKey, ''), isNotEmpty);
        } else {
          expect(effects.did, ['cancel 7']);
          expect(app.choice(ListPlugins.mutedKey, ''), isEmpty, reason: 'plugins_muted is never written for a pack');
        }
      }
    });

    test('a code waiting unread under newer words keeps a pack from marking it read, silencing it or sorting it', () async {
      // "Your code is 482913." then "Thank you for your payment" a moment later: the row and its facts hold the second,
      // but Android's one notification for the conversation still holds the code (review, 2026-11-20).
      for (final waiting in [false, true]) {
        final effects = FakeEffects();
        if (waiting) effects.codes.add(7);
        final plugin = PackPlugin(bills, source: PluginSource.reviewed, now: _still);
        final registry = PluginRegistry([plugin]);
        var redrawn = 0;
        final list = ListPlugins(changed: () => redrawn++, open: (_) {}, refresh: () async {}, registry: registry, effects: effects);
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_xbills', 'on')
          ..set('plugin_xbills_autoread', 'on');
        list.bind(app);
        final followUp = Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': sample('s03'), 'heard': sample('s03'), 'unread': true});
        list.take([followUp]);
        for (var i = 0; i < 20 && effects.asked.isEmpty; i++) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
        expect(effects.asked, [7], reason: 'the phone is asked, since a pack would act on it');
        if (waiting) {
          expect(effects.did, isEmpty, reason: 'neither marked read nor its notification taken away');
          expect(list.sort([followUp]).at[7], isNull, reason: 'it stays in Messages, the code with it');
          expect(redrawn, greaterThan(0));
          // Everything classified again (a switch changed): the phone isn't asked again of the same words.
          app.set(PluginRegistry.tunedKey, '1');
          list.bind(app);
          for (var i = 0; i < 5; i++) {
            await pumpEventQueue();
          }
          expect(effects.asked, [7]);
          expect(effects.did, isEmpty);
          // Read, the pack may sort it again.
          final read = Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': sample('s03'), 'heard': sample('s03'), 'unread': false});
          expect(list.sort([read]).at[7]?.id, 'xbills0receipts');
        } else {
          expect(effects.did, ['read 7']);
          expect(list.sort([followUp]).at[7]?.id, 'xbills0receipts');
        }
      }
    });

    test('on a computer the phone is asked too, and a pack sorts nothing a code waits in: nor anything before it answers', () async {
      // The look for a waiting code ran only where incoming rules do, so on a paired computer a pack took a code's
      // conversation into its tab by the words that came after it, while the phone kept it in Messages (review,
      // 2026-11-20).
      final was = Sms.calls;
      Sms.calls = _Computer();
      addTearDown(() => Sms.calls = was);
      MessageFacts.contactsReadable = true;
      addTearDown(MessageFacts.forgetContactsReadable);
      for (final waiting in [false, true]) {
        final effects = FakeEffects();
        if (waiting) effects.codes.add(7);
        final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([PackPlugin(bills, source: PluginSource.reviewed, now: _still)]), effects: effects);
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_xbills', 'on')
          ..set('plugin_xbills_autoread', 'on');
        list.bind(app);
        final bill = Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': sample('s01'), 'heard': sample('s01'), 'unread': true});
        list.take([bill]);
        expect(list.sort([bill]).at[7], isNull, reason: 'held in Messages while the phone is asked');
        for (var i = 0; i < 20 && effects.asked.isEmpty; i++) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
        expect(effects.asked, [7], reason: 'waiting: $waiting');
        expect(effects.did, isEmpty, reason: 'a computer marks nothing read: the phone runs the incoming rules');
        expect(list.sort([bill]).at[7]?.id, waiting ? isNull : 'xbills0bills', reason: 'waiting: $waiting');
      }
    });

    test('a pack marks read or silences a conversation only where every text unread in it is one it would itself', () async {
      // A bank's fraud alert, then a receipt from the same number before the person looks: Android marks the whole
      // conversation read and its one notification lists both, so Bills' "Mark receipts as read" took the alert with it
      // (review, 2026-11-20).
      const alert = 'FRAUD ALERT: did you send \$950 to J SMITH? Reply YES or NO.';
      for (final (unread, expected) in [
        (<String>[sample('s03'), alert], <String>[]),
        (<String>[sample('s03'), sample('s04')], ['read 7']),
        (<String>[sample('s03')], ['read 7']),
        (null, <String>[]),
      ]) {
        final effects = FakeEffects()..unread[7] = unread;
        final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([PackPlugin(bills, source: PluginSource.reviewed, now: _still)]), effects: effects);
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_xbills', 'on')
          ..set('plugin_xbills_autoread', 'on');
        list.bind(app);
        list.take([Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '73981'}], 'snippet': sample('s03'), 'heard': sample('s03'), 'unread': true})]);
        for (var i = 0; i < 20 && effects.askedUnread.isEmpty; i++) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
        expect(effects.askedUnread, [7], reason: '$unread');
        expect(effects.did, expected, reason: '$unread');
      }
      // Silencing as well: Parcels' quiet takes the conversation's one notification, the alert's line in it too.
      for (final (unread, expected) in [
        (<String>[sample('s08'), alert], <String>[]),
        (<String>[sample('s08'), sample('s10')], ['cancel 7']),
      ]) {
        final effects = FakeEffects()..unread[7] = unread;
        final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([PackPlugin(parcels, source: PluginSource.reviewed, now: _still)]), effects: effects);
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_xparcels', 'on')
          ..set('plugin_xparcels_quiet', 'on')
          ..set('plugin_xparcels_level', 'loose');
        list.bind(app);
        list.take([Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '73981'}], 'snippet': sample('s08'), 'heard': sample('s08'), 'unread': true})]);
        for (var i = 0; i < 20 && effects.askedUnread.isEmpty; i++) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
        expect(effects.did, expected, reason: '$unread');
      }
    });

    test('the phone\'s own answer: an unread fraud alert under a receipt is never marked read', () async {
      // The real SmsEffects, Android's side answered here: the newest twenty, newest first.
      final calls = <String>[];
      var messages = <Map<String, Object?>>[];
      final channel = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      channel.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        calls.add('${call.method} ${call.arguments}');
        return call.method == 'messages' ? messages : null;
      });
      addTearDown(() => channel.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
      Map<String, Object?> text(int id, String body, {bool read = false}) => {'id': id, 'kind': 'sms', 'address': '73981', 'body': body, 'date': 1000 + id, 'read': read};
      for (final (given, marked) in [
        ([text(2, 'Thank you for your payment of \$5.00.'), text(1, 'FRAUD ALERT: did you send \$950 to J SMITH? Reply YES or NO.')], false),
        ([text(2, 'Thank you for your payment of \$5.00.'), text(1, 'FRAUD ALERT: did you send \$950 to J SMITH? Reply YES or NO.', read: true)], true),
        ([for (var i = 20; i > 0; i--) text(i, 'Thank you for your payment of \$5.00.')], false),
      ]) {
        calls.clear();
        messages = given;
        final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([PackPlugin(bills, source: PluginSource.reviewed, now: _still)]));
        addTearDown(list.dispose);
        final app = AppState()
          ..set('plugin_xbills', 'on')
          ..set('plugin_xbills_autoread', 'on');
        list.bind(app);
        list.take([Conversation.from({'id': 7, 'date': 1002, 'people': [{'address': '73981'}], 'snippet': 'Thank you for your payment of \$5.00.', 'heard': 'Thank you for your payment of \$5.00.', 'unread': true})]);
        for (var i = 0; i < 40 && calls.where((c) => c.startsWith('messages')).length < 2; i++) {
          await pumpEventQueue();
        }
        await pumpEventQueue();
        expect(calls.where((c) => c.startsWith('messages')), hasLength(2), reason: 'a code looked for, then the unread texts read');
        expect(calls.any((c) => c.startsWith('markRead')), marked, reason: '${given.length} given: $calls');
        expect(calls.any((c) => c.startsWith('cancelChat')), isFalse);
      }
    });

    test('a built-in is never held back by a waiting code, and nobody asks for one where no pack acts', () async {
      final effects = FakeEffects()..codes.add(7);
      final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([const _Hush()]), effects: effects);
      addTearDown(list.dispose);
      final app = AppState()..set('plugin_hush', 'on');
      list.bind(app);
      list.take([Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '72975'}], 'snippet': sample('s08'), 'heard': sample('s08'), 'unread': true})]);
      for (var i = 0; i < 20 && effects.did.isEmpty; i++) {
        await pumpEventQueue();
      }
      expect(effects.did, ['mute 7 true']);
      expect(effects.asked, isEmpty);
    });
  });

  group('without the phone\'s contacts', () {
    tearDown(MessageFacts.forgetContactsReadable);

    test('a pack sees nothing of the phone\'s conversations and messages, while Try it and the API still say who a stranger is', () {
      // Without Contacts no number has a name, so every conversation read as a stranger's and a pack sorted, marked
      // read and silenced contacts' texts (review, 2026-11-20).
      final (registry, plugin, store) = alone(bills, prefs: {'autoread': 'on'});
      final row = Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '+15550100100'}], 'snippet': sample('s03'), 'heard': sample('s03'), 'unread': true});
      final bubble = MessageFacts.message(Message.from({'id': 1, 'kind': 'sms', 'address': '+15550100100', 'body': sample('s03'), 'date': 1000}), thread: 7, people: const [Person(address: '+15550100100')]);
      final before = registry.switches(store);
      MessageFacts.contactsReadable = false;
      expect(registry.switches(store), isNot(before), reason: 'everything is classified again when it changes');
      for (final facts in [MessageFacts.conversation(row), bubble]) {
        expect(packSees(facts), isFalse);
        final tags = registry.classify(facts, store);
        expect(tags.has('xbills.paid'), isFalse);
        expect(registry.sectionOf(facts, tags, store), isNull);
      }
      expect(plugin.incoming.single(MessageFacts.conversation(row), registry.classify(MessageFacts.conversation(row), store), 'xbills0receipts', registry.prefsOf(plugin, store)), isEmpty);
      // Facts that say outright who is a stranger: Try it's, and the API's filters.classify.
      expect(packSees(textOf(sample('s03'))), isTrue);
      expect(tryPack(bills, text: sample('s03')).tags.keys, contains('paid'));
      MessageFacts.contactsReadable = true;
      expect(registry.classify(MessageFacts.conversation(row), store).has('xbills.paid'), isTrue);
    });

    test('the phone\'s permissions say it; a computer, which can\'t ask, learns it from a name on a conversation', () {
      MessageFacts.heardStatus(const SmsStatus(isDefault: true, contacts: false, notifications: true, phone: true));
      expect(MessageFacts.contactsReadable, isFalse);
      MessageFacts.heardStatus(const SmsStatus(isDefault: true, contacts: true, notifications: true, phone: true));
      expect(MessageFacts.contactsReadable, isTrue);
      MessageFacts.forgetContactsReadable();
      final was = Sms.calls;
      Sms.calls = _Computer();
      addTearDown(() => Sms.calls = was);
      expect(MessageFacts.contactsReadable, isFalse, reason: 'a computer starts unsure');
      MessageFacts.heardStatus(const SmsStatus(isDefault: true, contacts: true, notifications: true, phone: true));
      expect(MessageFacts.contactsReadable, isFalse, reason: 'a computer\'s own answer says nothing of its phone\'s');
      final list = ListPlugins(changed: () {}, open: (_) {}, refresh: () async {}, registry: PluginRegistry([PackPlugin(bills, source: PluginSource.dev, now: _still)]), effects: FakeEffects());
      addTearDown(list.dispose);
      list.take([Conversation.from({'id': 7, 'date': 1000, 'people': [{'address': '+15550100100'}], 'snippet': 'hi', 'unread': false})]);
      expect(MessageFacts.contactsReadable, isFalse);
      list.take([Conversation.from({'id': 8, 'date': 1000, 'people': [{'address': '+15550100199', 'name': 'Ada'}], 'snippet': 'hi', 'unread': false})]);
      expect(MessageFacts.contactsReadable, isTrue);
    });
  });

  group('what it is', () {
    test('its settings as their PluginSetting kinds', () {
      final b = PackPlugin(bills, source: PluginSource.dev);
      final autoread = b.settings[0];
      expect([autoread.toggle, autoread.key, autoread.label, autoread.fallback, autoread.icon], [true, 'autoread', 'Mark receipts as read', false, Lucide.checkCheck]);
      expect(autoread.hint, 'As they come: texts that say a payment went through.');
      final extra = b.settings[1];
      expect([extra.words, extra.key, extra.placeholder], [true, 'extra', 'council tax, water rates']);
      final p = PackPlugin(parcels, source: PluginSource.dev);
      final level = p.settings[0];
      expect([level.key, level.choice, level.options.map((o) => o.value).join(',')], ['level', 'strict', 'strict,loose']);
      expect(p.settings[1].toggle, isTrue);
      expect(identical(b.settings, b.settings) && identical(b.sections, b.sections) && identical(b.tuned, b.tuned) && identical(b.slots, b.slots) && identical(b.incoming, b.incoming), isTrue, reason: 'made once');
      expect(b.settingsPage, isNull);
    });

    test('on a computer, a switch an incoming rule names says it does nothing there', () {
      final was = Sms.calls;
      Sms.calls = _Computer();
      addTearDown(() => Sms.calls = was);
      expect(Sms.remote, isTrue);
      final b = PackPlugin(bills, source: PluginSource.dev);
      expect(b.settings[0].hint, 'As they come: texts that say a payment went through. Switch it on in Uplink on your phone: it does nothing here.');
      expect(b.settings[1].hint, 'A text with any of these goes to Bills too.');
      expect(b.adds.last, 'Settings of its own, on its page');
      expect(b.adds, contains('On your phone it can also mark read or silence texts as they come; not on this computer.'));
    });

    test('off until added, on this device alone, its name, its picture, its labels', () {
      final b = PackPlugin(bills, source: PluginSource.reviewed);
      expect(b.onByDefault, isFalse);
      expect(b.scopes, {PluginScope.device});
      expect([b.id, b.name, b.hue, b.shelf, b.developer, b.version, b.source], ['xbills', 'Bills', 'amber', PluginShelf.organise, 'yourname', '1.0.0', PluginSource.reviewed]);
      expect(b.icon, Lucide.calculator);
      expect(b.iconPng, bills.icon);
      expect(b.labels, ['bills', 'money', 'sorting']);
      expect(b.tagline, 'Bills and payment reminders in a tab of their own');
    });

    test('what it reaches and what it adds, word for word, on a phone and on a computer', () {
      String line(PluginReach r) => '${r.label} | ${r.hint}';
      const eye = 'Reads texts from numbers not in your contacts | Their words and who they\'re from, on this phone, to sort them. Never your contacts\' texts, group texts, texts sent with Uplink\'s encryption, your own, chats on other networks, or circles and spaces. Nothing at all while Uplink can\'t read your contacts.';
      const sort = 'Sorts texts into its own tabs and kinds | They leave Messages for its tab while it\'s added. Remove it and they\'re back. Texts with a sign-in code in them are never sorted.';
      const copy = 'Copies to your clipboard when you ask | Only when you press its button.';
      const shield = 'Can\'t reach the internet | It has no way to send anything over the internet itself. A button you press can open its page in your browser or copy words to your clipboard.';
      expect(packReaches(bills, here: 'phone').map(line), [
        eye,
        sort,
        'Can mark texts as read | Only the conversation you press it on, or texts in its own tabs and kinds as they come once you switch that on in its settings. A text marked read loses its notification.',
        copy,
        shield,
      ]);
      expect(packReaches(bills, here: 'computer').map(line), [eye.replaceFirst('this phone', 'this computer'), sort, copy, shield], reason: 'its only mark-read is an incoming rule, which a computer never runs');
      expect(packReaches(parcels, here: 'phone').map(line), [
        eye,
        sort,
        'Moves a conversation when you ask | Only when you press its button, into its own tabs or back to Messages.',
        'Can silence notifications | Only texts in its own tabs and kinds, once you switch that on in its settings. Each one\'s notification is taken away as it comes.',
        copy,
        'Writes a reply for you to send | Only when you press its button. Nothing is sent until you send it.',
        'Opens example.com in your browser | Only when you press its button. The address never changes, and nothing from your texts goes with it.',
        shield,
      ]);
      expect(packReaches(parcels, here: 'iPhone').map((r) => r.label), isNot(contains('Can silence notifications')));
      expect(packReaches(bills, here: 'phone').map((r) => r.icon), [Lucide.eye, Lucide.listFilter, Lucide.checkCheck, Lucide.copy, Lucide.shieldCheck]);
      expect(packAdds(bills, here: 'phone'), ['A Bills tab in the list', 'A kind in the list\'s filter: Receipts', 'Choices in a conversation\'s menu in the list', 'Choices in a message\'s menu', 'Can mark Receipts texts as read as they come, once you switch it on', 'Settings of its own, on its page']);
      expect(packAdds(bills, here: 'computer'), ['A Bills tab in the list', 'A kind in the list\'s filter: Receipts', 'Choices in a conversation\'s menu in the list', 'Choices in a message\'s menu', 'On your phone it can also mark read or silence texts as they come; not on this computer.', 'Settings of its own, on its page']);
      expect(packAdds(parcels, here: 'phone'), ['A Parcels tab in the list', 'Choices in a conversation\'s menu in the list', 'A button in a conversation\'s header', 'Choices in a message\'s menu', 'Can silence Parcels texts as they come, once you switch it on', 'Settings of its own, on its page']);
      final b = PackPlugin(bills, source: PluginSource.dev);
      expect(b.adds, packAdds(bills, here: 'phone'));
      expect(b.reaches.map(line), packReaches(bills, here: 'phone').map(line));
    });
  });

  group('pausing (A.10.9)', () {
    (PluginRegistry, PackPlugin, MemoryStore, List<String>) timed(Clock clock, {bool paused = false}) {
      final trouble = <String>[];
      final plugin = PackPlugin(bills, source: PluginSource.dev, now: clock.read, onTrouble: (p, w) => trouble.add(w), paused: paused);
      return (PluginRegistry([plugin]), plugin, MemoryStore({'plugin_xbills': 'on'}), trouble);
    }

    test('slow twice running is a strike; five in ten minutes pause it, once; the first classification never counts', () {
      final clock = Clock(const Duration(milliseconds: 25));
      final (registry, plugin, store, trouble) = timed(clock);
      final t = textOf(sample('s01'));
      for (var i = 0; i < 5; i++) {
        clock.jump();
        expect(registry.classify(t, store).has('xbills.bill'), isTrue, reason: 'classification ${i + 1}');
      }
      expect(plugin.paused, isFalse, reason: 'four strikes: the first, compiling its phrases, isn\'t one');
      clock.jump();
      expect(registry.classify(t, store).isEmpty, isTrue);
      expect(plugin.paused, isTrue);
      expect(trouble, ['paused']);
      clock.jump();
      registry.classify(t, store);
      expect(trouble, ['paused'], reason: 'told once');
      final tagged = TagSet(const [Tag('xbills.bill', '1')]);
      expect(plugin.sections.first.takes(t, tagged, PluginPrefs.none), isFalse, reason: 'paused, its sections take nothing');
      final fill = plugin.slots.first as ActionFill<ConversationPlace>;
      expect(fill.build(ConversationPlace(t, tagged), PluginPrefs.none), isEmpty, reason: 'nor are its buttons offered');
    });

    test('strikes more than ten minutes apart don\'t add up', () {
      final clock = Clock(const Duration(milliseconds: 25));
      final (registry, plugin, store, _) = timed(clock);
      final t = textOf(sample('s01'));
      registry.classify(t, store);
      for (var i = 0; i < 12; i++) {
        clock.jump(const Duration(minutes: 3));
        registry.classify(t, store);
      }
      expect(plugin.paused, isFalse, reason: 'at most four strikes in any ten minutes');
    });

    test('slow only the first time is not a strike: a busy phone or a garbage collection isn\'t the pack', () {
      final clock = Clock(Duration.zero);
      final (registry, plugin, store, trouble) = timed(clock);
      final t = textOf(sample('s01'));
      registry.classify(t, store);
      for (var i = 0; i < 12; i++) {
        clock.jump();
        // Its start, then 25 ms on at its end: slow. Run again at once, it takes nothing.
        clock.next = [Duration.zero, const Duration(milliseconds: 25), Duration.zero, Duration.zero];
        expect(registry.classify(t, store).has('xbills.bill'), isTrue);
        expect(clock.next, isEmpty, reason: 'a slow run is run again at once');
      }
      expect(plugin.paused, isFalse);
      expect(trouble, isEmpty);
      // And slow both times, it is a strike: five of those pause it.
      for (var i = 0; i < 5; i++) {
        clock.jump();
        clock.next = [Duration.zero, const Duration(milliseconds: 25), Duration.zero, const Duration(milliseconds: 25)];
        registry.classify(t, store);
      }
      expect(plugin.paused, isTrue);
      expect(trouble, ['paused']);
    });

    test('a second spending over 100 ms classifying is a strike, once a second', () {
      final clock = Clock(const Duration(milliseconds: 15));
      final (registry, plugin, store, trouble) = timed(clock);
      final t = textOf(sample('s01'));
      void second() {
        clock.jump();
        // Seven runs of 15 ms each (and the first ever, which doesn't count): 105 ms in the second.
        for (var i = 0; i < 8; i++) {
          registry.classify(t, store);
        }
      }

      for (var s = 0; s < 4; s++) {
        second();
      }
      expect(plugin.paused, isFalse, reason: 'one strike a second, not one a run past the budget');
      second();
      expect(plugin.paused, isTrue);
      expect(trouble, ['paused']);
    });

    test('a pack quick on each text, asked about thousands at once, is never paused for that', () {
      // The list asks every pack about every conversation it holds whenever a switch, a setting or the plugins change:
      // a pack taking some 40 µs a text was charged 120 ms for 3,000 conversations in one second, a strike at each
      // change and a pause after five (review, 2026-11-20). Six such changes, ninety seconds apart.
      final clock = Clock(const Duration(microseconds: 40));
      final (registry, plugin, store, trouble) = timed(clock);
      final t = textOf(sample('s01'));
      for (var change = 0; change < 6; change++) {
        clock.jump(const Duration(seconds: 90));
        for (var i = 0; i < 3000; i++) {
          registry.classify(t, store);
        }
      }
      expect(plugin.paused, isFalse);
      expect(trouble, isEmpty);
    });

    test('a pack just under a millisecond a text, asked about thousands at once, is paused all the same', () {
      // The average above let a pack of 0.9 ms a text hold the app for 2.7 s at every change and never earn a strike
      // (review, 2026-11-20): a second it spends more than half of classifying is one whatever the average. Runs back to
      // back, 3,000 conversations at each change, ninety seconds apart: three strikes a change, paused in the second.
      final clock = _BackToBack(const Duration(microseconds: 900));
      final (registry, plugin, store, trouble) = timed(clock);
      final t = textOf(sample('s01'));
      clock.jump(const Duration(seconds: 90));
      for (var i = 0; i < 3000; i++) {
        registry.classify(t, store);
      }
      expect(plugin.paused, isFalse, reason: 'three strikes');
      clock.jump(const Duration(seconds: 90));
      for (var i = 0; i < 3000; i++) {
        registry.classify(t, store);
      }
      expect(plugin.paused, isTrue);
      expect(trouble, ['paused']);
    });

    test('unpause clears it, and a pack made paused starts paused', () {
      final clock = Clock(const Duration(milliseconds: 25));
      final (registry, plugin, store, _) = timed(clock);
      final t = textOf(sample('s01'));
      for (var i = 0; i < 6; i++) {
        clock.jump();
        registry.classify(t, store);
      }
      expect(plugin.paused, isTrue);
      plugin.unpause();
      expect(plugin.paused, isFalse);
      clock.step = Duration.zero;
      expect(registry.classify(t, store).has('xbills.bill'), isTrue);
      final (pausedRegistry, paused, pausedStore, _) = timed(Clock(Duration.zero), paused: true);
      expect(paused.paused, isTrue);
      expect(pausedRegistry.classify(t, pausedStore).isEmpty, isTrue);
      expect(paused.incoming.single(t, TagSet.none, 'xbills0receipts', PluginPrefs.none), isEmpty);
    });
  });
}

/// A clock that moves on [step] each time it is read, or by the steps [next] gives, one a read, and by [jump] when the
/// test says: a pack's time is what this says it is.
class Clock {
  Clock(this.step);
  Duration step;
  var at = _noon;
  List<Duration> next = [];
  DateTime read() => at = at.add(next.isEmpty ? step : next.removeAt(0));
  void jump([Duration by = const Duration(seconds: 2)]) => at = at.add(by);
}

/// A clock for runs back to back: a run's start is read as the last one ended, and its end [took] later.
class _BackToBack extends Clock {
  _BackToBack(this.took) : super(Duration.zero);
  final Duration took;
  var _ending = false;
  @override
  DateTime read() => at = at.add((_ending = !_ending) ? Duration.zero : took);
}

/// A host whose every call throws: a button's failure must not reach the screen.
class _Throws implements PluginHost {
  @override
  PluginPrefs get prefs => PluginPrefs.none;
  @override
  void say(String words) => throw StateError('say');
  @override
  void copy(String text, {String? say}) => throw StateError('copy');
  @override
  void open(int thread) => throw StateError('open');
  @override
  Future<void> markRead(int thread) => throw StateError('read');
  @override
  void move(int thread, String? section) => throw StateError('move');
  @override
  void write(String text) => throw StateError('write');
  @override
  void present(WidgetBuilder page) => throw StateError('present');
  @override
  Future<void> deleteThread(int thread) => throw StateError('delete');
  @override
  Future<void> reload() => throw StateError('reload');
}
