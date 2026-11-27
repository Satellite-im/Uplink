import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/tag_store.dart';
import 'package:ghost_messaging/sms.dart';

import 'support/test_plugins.dart';

/// The plugin contract and its registry (Matt, 2026-11-14: "prime the whole app to have plugin support for placing UI
/// elements and doing things like filtering out spam messages separating OTPs into their own section and more"),
/// with a plugin made up for the purpose (test/support/test_plugins.dart): what a plugin adds while it is on, that
/// it adds nothing while it is off, where a conversation is filed, and that tags are worked out once and never all
/// at once.
MessageFacts _facts(int thread, String text, {bool contact = false, bool unread = false}) => MessageFacts(thread: thread, senders: const ['+15550001111'], text: text, contact: contact, unread: unread);

Conversation _c(int id, String snippet, {int date = 1000, String? name, bool unread = false}) => Conversation.from({
      'id': id,
      'date': date,
      'people': [
        {'address': '+1555000${1000 + id}', 'name': name},
      ],
      'snippet': snippet,
      'unread': unread,
    });

/// A host that writes down what it was asked.
class _Host implements PluginHost {
  _Host(this.prefs);
  @override
  final PluginPrefs prefs;
  final did = <String>[];
  @override
  void say(String words) => did.add('say $words');
  @override
  void copy(String text, {String? say}) => did.add('copy $text');
  @override
  void open(int thread) => did.add('open $thread');
  @override
  Future<void> markRead(int thread) async => did.add('read $thread');
  @override
  void move(int thread, String? section) => did.add('move $thread $section');
  @override
  void write(String text) => did.add('write $text');

  @override
  void present(WidgetBuilder page) {}

  @override
  Future<void> deleteThread(int thread) async {}

  @override
  Future<void> reload() async {}
}

void main() {
  group('the registry', () {
    test('a plugin is on or off as it says until it is switched, and the switch is kept with the person\'s choices', () {
      final on = TicketsPlugin();
      final store = MemoryStore();
      final registry = PluginRegistry([on]);
      expect(registry.isOn(on, store), isTrue);
      registry.setOn(on, store, false);
      expect(store.values, {'plugin_tickets': 'off'});
      expect(registry.isOn(on, store), isFalse);

      final off = TicketsPlugin(onByDefault: false);
      final other = PluginRegistry([off]);
      expect(other.isOn(off, MemoryStore()), isFalse);
      expect(other.isOn(off, MemoryStore({'plugin_tickets': 'on'})), isTrue);
    });

    test('a plugin that is on is asked: tags, a section, its row, slots, rules', () {
      final plugin = TicketsPlugin();
      final registry = PluginRegistry([plugin]);
      final store = MemoryStore({'plugin_tickets_read': 'on'});
      final facts = _facts(7, 'Your ticket 4411 is ready', unread: true);

      final tags = registry.classify(facts, store);
      expect(tags.has('ticket'), isTrue);
      expect(tags.detail('ticket'), '4411');
      expect(registry.classify(_facts(8, 'See you at 7'), store).isEmpty, isTrue);

      final section = registry.sectionOf(facts, tags, store)!;
      expect(section.id, 'tickets');
      expect(section.plugin, same(plugin));
      expect(registry.sectionOf(_facts(9, 'ticket 12', contact: true), registry.classify(_facts(9, 'ticket 12', contact: true), store), store), isNull, reason: 'the section does not take a contact\'s');

      final look = registry.look(section, facts, tags, store)!;
      expect(look.value, '4411');
      expect(look.end!.label, 'Copy 4411');

      expect(registry.actions(Slots.listHeader, const ListPlace(shown: 3), store).map((b) => b.action.label), ['Ticket desk']);
      expect(registry.actions(Slots.conversationMenu, ConversationPlace(facts, tags, section: 'tickets'), store).map((b) => b.action.label), ['Keep in Messages']);
      expect(registry.actions(Slots.conversationMenu, ConversationPlace(facts, tags), store).map((b) => b.action.label), ['Move to Tickets']);
      expect(registry.actions(Slots.messageMenu, MessagePlace(facts, tags), store).map((b) => b.action.label), ['Copy 4411']);
      expect(registry.actions(Slots.composer, const ComposerPlace(thread: 7, senders: ['+15550001111']), store).map((b) => b.action.label), ['Ask for a ticket']);

      expect(registry.incoming(facts, tags, store).map((b) => b.action), [isA<MarkRead>()]);
      expect(registry.settingsOf(plugin).map((s) => s.label), ['Mark tickets as read', 'What a ticket is']);
    });

    test('a slot gives what was put in it and nothing put in another, though both are told of a conversation', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      final store = MemoryStore();
      final facts = _facts(7, 'ticket 4411');
      final place = ConversationPlace(facts, registry.classify(facts, store));
      expect(registry.actions(Slots.conversationHeader, place, store).map((b) => b.action.label), ['Copy 4411']);
      expect(registry.actions(Slots.conversationMenu, place, store).map((b) => b.action.label), ['Move to Tickets']);
      expect(Slots.all.map((s) => s.name).toSet(), hasLength(Slots.all.length), reason: 'every slot has a name of its own');
    });

    test('an action is run with a host that has its plugin\'s own choices', () async {
      final plugin = TicketsPlugin();
      final registry = PluginRegistry([plugin]);
      final store = MemoryStore();
      final facts = _facts(7, 'ticket 4411');
      final bound = registry.actions(Slots.conversationMenu, ConversationPlace(facts, registry.classify(facts, store), section: 'tickets'), store).single;
      final host = _Host(registry.prefsOf(bound.plugin, store));
      await bound.action.run(host);
      expect(host.did, ['move 7 null']);
      host.prefs.setFlag('read', true);
      expect(store.values['plugin_tickets_read'], 'on');
    });

    test('a plugin that is off adds nothing', () {
      final plugin = TicketsPlugin();
      final registry = PluginRegistry([plugin]);
      final store = MemoryStore({'plugin_tickets': 'off', 'plugin_tickets_read': 'on'});
      final facts = _facts(7, 'Your ticket 4411 is ready', unread: true);
      expect(registry.classify(facts, store).isEmpty, isTrue);
      expect(plugin.asked, 0, reason: 'it is not even asked');
      expect(registry.sections(store), isEmpty);
      expect(registry.sectionOf(facts, TagSet(const [Tag('ticket', '4411')]), store), isNull);
      for (final slot in [Slots.listHeader]) {
        expect(registry.actions(slot, const ListPlace(), store), isEmpty);
      }
      expect(registry.actions(Slots.conversationMenu, ConversationPlace(facts, TagSet.none), store), isEmpty);
      expect(registry.incoming(facts, TagSet.none, store), isEmpty);
    });

    test('where two classifiers give one tag the first is kept, and the first section that takes a conversation has it', () {
      final registry = PluginRegistry([_Says('one', 'first'), _Says('two', 'second')]);
      final store = MemoryStore();
      final facts = _facts(1, 'anything');
      final tags = registry.classify(facts, store);
      expect(tags.detail('same'), 'first');
      expect(tags.names, ['same']);
      expect(registry.sectionOf(facts, tags, store)!.id, 'one');
      // With the first switched off the second has it.
      store.write('plugin_one', 'off');
      expect(registry.sectionOf(facts, registry.classify(facts, store), store)!.id, 'two');
    });

    test('a conversation filed by hand stays where it was filed, and what is filed where it would be anyway is forgotten', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      final store = MemoryStore();
      final ticket = _facts(7, 'ticket 4411');
      final plain = _facts(8, 'See you at 7');
      final tags = registry.classify(ticket, store);

      // Kept in the main list, whatever its tags say.
      registry.move(ticket, tags, null, store);
      expect(store.values[Filing.key], '7:');
      expect(registry.sectionOf(ticket, tags, store), isNull);
      // Put in a section its words would never put it in.
      registry.move(plain, TagSet.none, 'tickets', store);
      expect(store.values[Filing.key], '7:,8:tickets');
      expect(registry.sectionOf(plain, TagSet.none, store)!.id, 'tickets');
      // Each put back where it would be anyway: nothing is filed any more.
      registry.move(ticket, tags, 'tickets', store);
      registry.move(plain, TagSet.none, null, store);
      expect(store.read(Filing.key), isNull);
      expect(registry.sectionOf(ticket, tags, store)!.id, 'tickets');
      expect(registry.sectionOf(plain, TagSet.none, store), isNull);
      // Filed in a section whose plugin is then switched off: it is in the main list.
      registry.move(plain, TagSet.none, 'tickets', store);
      store.write('plugin_tickets', 'off');
      expect(registry.sectionOf(plain, TagSet.none, store), isNull);
    });

    test('what is filed is read back as it was written', () {
      final filed = Filing.parse('12:codes,40:,77:spam,nonsense,:x');
      expect(filed.of(12), 'codes');
      expect(filed.of(40), Filing.main);
      expect(filed.of(77), 'spam');
      expect(filed.of(1), isNull);
      expect(Filing.parse(null).of(12), isNull);
      expect(Filing.parse('').of(12), isNull);
    });

    test('a rule for a message that has just come is told the section, and may file the conversation', () {
      final registry = PluginRegistry([TicketsPlugin()]);
      final store = MemoryStore({'plugin_tickets_quiet': 'on'});
      final facts = _facts(7, 'ticket 4411', unread: true);
      expect(registry.incoming(facts, registry.classify(facts, store), store).map((b) => b.action), [isA<MuteNotification>()]);
      final urgent = _facts(8, 'an urgent ticket, no number', unread: true);
      final asked = registry.incoming(urgent, registry.classify(urgent, store), store);
      expect((asked.single.action as MoveToSection).section, 'tickets');
      expect(asked.single.plugin.id, 'tickets');
    });

    test('a plugin that throws is left out and said, and the others are still asked', () {
      final said = <String>[];
      final registry = PluginRegistry([const BrokenPlugin(), TicketsPlugin()], onError: (plugin, error) => said.add('${plugin.id}: $error'));
      final store = MemoryStore();
      final facts = _facts(7, 'ticket 4411', unread: true);
      final tags = registry.classify(facts, store);
      expect(tags.detail('ticket'), '4411');
      expect(registry.sectionOf(facts, tags, store)!.id, 'tickets');
      expect(registry.look(registry.sections(store).first, facts, tags, store), isNull);
      expect(registry.actions(Slots.listHeader, const ListPlace(), store).map((b) => b.action.label), ['Ticket desk']);
      expect(registry.incoming(facts, tags, store), isEmpty);
      expect(said, hasLength(6), reason: 'the classifier, the section (asked for the list and again for the rule), its row, the slot, the rule');
      expect(said.first, 'broken: Bad state: classifier');
    });

    test('two plugins, or two sections, cannot share a name', () {
      expect(() => PluginRegistry([TicketsPlugin(), TicketsPlugin()]), throwsArgumentError);
      expect(() => PluginRegistry([_Says('one', 'a'), _Says('two', 'b', section: 'one')]), throwsArgumentError);
      expect(() => PluginRegistry([_Says('Not A Name', 'a')]), throwsArgumentError);
    });

    test('the app ships no plugin that is not listed, and no two with one name', () {
      expect(() => PluginRegistry(shippedPlugins), returnsNormally);
      expect(PluginRegistry.instance.plugins, shippedPlugins);
    });
  });

  group('what a plugin is shown', () {
    test('a conversation: its people, its last words, whether anyone is a contact', () {
      final known = MessageFacts.conversation(_c(3, 'Call me', name: 'Dad', unread: true));
      expect(known.thread, 3);
      expect(known.senders, ['+15550001003']);
      expect(known.text, 'Call me');
      expect(known.contact, isTrue);
      expect(known.unread, isTrue);
      expect(known.outgoing, isNull, reason: 'the list does not know whose the last words are');
      expect(MessageFacts.conversation(_c(4, 'Hi')).contact, isFalse);
      expect(known.toJson()['senders'], ['+15550001003']);
      expect(known.toJson().keys, containsAll(['thread', 'senders', 'text', 'contact', 'group', 'date', 'unread', 'muted', 'outgoing']));
    });

    test('a message: who sent it, and whether they are a contact', () {
      const people = [Person(address: '+15550001111', name: 'Maya'), Person(address: '+15550002222')];
      Message message(String address, {bool outgoing = false}) => Message(id: 1, kind: 'sms', address: address, body: 'ticket 9', date: DateTime(2026), outgoing: outgoing, state: 'received');
      final hers = MessageFacts.message(message('+15550001111'), thread: 5, people: people);
      expect(hers.senders, ['+15550001111']);
      expect(hers.contact, isTrue);
      expect(hers.group, isTrue);
      expect(hers.outgoing, isFalse);
      expect(MessageFacts.message(message('+15550002222'), thread: 5, people: people).contact, isFalse);
      final mine = MessageFacts.message(message('', outgoing: true), thread: 5, people: people);
      expect(mine.outgoing, isTrue);
      expect(mine.senders, ['+15550001111', '+15550002222']);
    });
  });

  group('the tags the list keeps', () {
    Future<void> rest(TagStore tags) async {
      while (tags.waiting > 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('a conversation is classified once, and again only when its words change', () {
      final plugin = TicketsPlugin();
      final tags = TagStore(PluginRegistry([plugin]))..bind(MemoryStore());
      addTearDown(tags.dispose);
      tags.take([_c(1, 'ticket 4411'), _c(2, 'See you at 7')]);
      expect(plugin.asked, 2);
      expect(tags.of(1).detail('ticket'), '4411');
      expect(tags.of(2).isEmpty, isTrue);
      expect(tags.of(99).isEmpty, isTrue, reason: 'one never handed over has no tags');
      // Read again as it was (now unread): kept, not asked again; what else is held of it is the newer.
      tags.take([_c(1, 'ticket 4411', unread: true), _c(2, 'See you at 7')]);
      expect(plugin.asked, 2);
      expect(tags.facts(1)!.unread, isTrue);
      // A new text in it.
      tags.take([_c(1, 'ticket 5522', date: 2000)]);
      expect(plugin.asked, 3);
      expect(tags.of(1).detail('ticket'), '5522');
    });

    test('the first lot is classified at once and the rest between frames, with a word when that changes something', () async {
      final plugin = TicketsPlugin();
      final tags = TagStore(PluginRegistry([plugin]), atOnce: 4, slice: Duration.zero)..bind(MemoryStore());
      addTearDown(tags.dispose);
      var told = 0;
      tags.addListener(() => told++);
      tags.take([for (var i = 1; i <= 10; i++) _c(i, 'ticket $i', date: 2000 - i)]);
      // The first four, which the screen is about to draw, are done; the caller is not told what it already holds.
      expect(plugin.asked, 4);
      expect(tags.waiting, 6);
      expect([for (var i = 1; i <= 10; i++) tags.of(i).has('ticket')], [true, true, true, true, false, false, false, false, false, false]);
      expect(told, 0);
      final before = tags.version;
      await rest(tags);
      expect(plugin.asked, 10);
      expect([for (var i = 1; i <= 10; i++) tags.of(i).has('ticket')], everyElement(isTrue));
      expect(told, greaterThan(0));
      expect(tags.version, greaterThan(before));
    });

    test('nothing is classified before the person\'s choices are known, and all of it again when a plugin is switched', () async {
      final plugin = TicketsPlugin();
      final store = MemoryStore();
      final registry = PluginRegistry([plugin]);
      final tags = TagStore(registry);
      addTearDown(tags.dispose);
      tags.take([_c(1, 'ticket 4411')]);
      expect(plugin.asked, 0);
      tags.bind(store);
      expect(tags.of(1).has('ticket'), isTrue);
      // The same choices given again change nothing, and nor does a choice that is not a plugin's switch: a
      // classifier is told none of them.
      tags.bind(store);
      store.write('plugin_tickets_read', 'on');
      store.write(Filing.key, '1:');
      tags.bind(store);
      expect(plugin.asked, 1);
      // Switched off: what it tagged is no longer tagged.
      registry.setOn(plugin, store, false);
      tags.bind(store);
      await rest(tags);
      expect(tags.of(1).isEmpty, isTrue);
      registry.setOn(plugin, store, true);
      tags.bind(store);
      await rest(tags);
      expect(tags.of(1).detail('ticket'), '4411');
    });

    test('whoever asks is told of each conversation as it is classified, once', () {
      final seen = <String>[];
      final tags = TagStore(PluginRegistry([TicketsPlugin()]), onTagged: (facts, tags) => seen.add('${facts.thread} $tags'))..bind(MemoryStore());
      addTearDown(tags.dispose);
      tags.take([_c(1, 'ticket 4411'), _c(2, 'See you at 7')]);
      tags.take([_c(1, 'ticket 4411'), _c(2, 'See you at 7')]);
      expect(seen, ['1 ticket (4411)', '2 no tags']);
    });

    test('five thousand conversations: handing them over takes a few milliseconds, whatever is left to classify', () async {
      final plugin = TicketsPlugin();
      final tags = TagStore(PluginRegistry([plugin]))..bind(MemoryStore());
      addTearDown(tags.dispose);
      final all = [for (var i = 0; i < 5000; i++) _c(i, i % 9 == 0 ? 'Your ticket $i is ready, reply STOP to end' : 'A text of ordinary words, number $i of five thousand', date: 9000 - i)];
      final clock = Stopwatch()..start();
      tags.take(all);
      final handed = clock.elapsedMicroseconds;
      // The first screen is done whatever the clock says.
      expect(plugin.asked, greaterThanOrEqualTo(64));
      expect(tags.of(0).has('ticket'), isTrue);
      await rest(tags);
      final whole = clock.elapsedMicroseconds;
      expect(plugin.asked, 5000);
      expect(tags.of(4995).has('ticket'), isTrue);
      // ignore: avoid_print
      print('5000 conversations: handed over in ${(handed / 1000).toStringAsFixed(1)} ms, all classified ${(whole / 1000).toStringAsFixed(1)} ms after');
      // Two milliseconds of classifying is the most it does there and then; the rest is making the 5000 facts. A
      // generous bound, so a slow machine does not fail it: a frame at 60 a second is 16 ms.
      expect(handed, lessThan(60000));
    });
  });
}

/// A plugin that tags everything `same` with [detail], and has a section that takes everything.
class _Says extends GhostPlugin {
  _Says(this.id, this.detail, {String? section}) : _section = section ?? id;
  @override
  final String id;
  final String detail;
  final String _section;
  @override
  String get name => id;
  @override
  String get description => 'Says $detail.';
  @override
  List<Classifier> get classifiers => [(facts) => [Tag('same', detail)]];
  @override
  List<ListSection> get sections => [ListSection(id: _section, label: id, icon: Lucide.tag, takes: (facts, tags, prefs) => true)];
  @override
  List<SlotFill> get slots => [Slots.aboveList.fill((context, place, prefs) => const <Widget>[])];
}
