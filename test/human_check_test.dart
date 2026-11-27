import 'dart:math';

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/alerts.dart';
import 'package:ghost_messaging/inbox/human_check.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/plugins/human_check.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// A network signed in whose chats and messages a test changes, as new messages would; what was sent kept in [sent].
class GateNet extends InboxNetwork {
  GateNet(this.id, {this.people = const [], this.strangersMarked = false});
  @override
  final String id;
  @override
  String get name => id == 'telegram' ? 'Telegram' : 'Signal';
  final List<InboxContact> people;
  final bool strangersMarked;
  var chatList = <InboxChat>[];
  final messages = <String, List<InboxMessage>>{};
  final sent = <(String, String)>[];
  final blocked = <String>[];
  var failSends = false;

  void set(List<InboxChat> chats) {
    chatList = chats;
    notifyListeners();
  }

  /// [text] from the other side of [chatId], as the newest message.
  void hear(String chatId, String text, DateTime at) {
    messages[chatId] = [...messagesOf(chatId), InboxMessage(id: 'm${messagesOf(chatId).length}', text: text, date: at, mine: false)];
    final c = chatList.firstWhere((c) => c.id == chatId);
    set([for (final x in chatList) x.id == chatId ? c.copyWith(snippet: text, date: at, unread: c.unread + 1, lastFromMe: false) : x]);
  }

  @override
  bool get marksStrangers => strangersMarked;
  @override
  List<InboxContact> get contacts => people;
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => chatList;
  @override
  List<InboxMessage> messagesOf(String chatId) => messages[chatId] ?? const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {
    if (failSends) throw StateError('refused');
    sent.add((chatId, text));
    messages[chatId] = [...messagesOf(chatId), InboxMessage(id: 's${sent.length}', text: text, date: DateTime.now(), mine: true)];
    final c = chatList.firstWhere((c) => c.id == chatId);
    set([for (final x in chatList) x.id == chatId ? c.copyWith(snippet: text, lastFromMe: true) : x]);
  }

  @override
  Future<void> block(String chatId, {required String name, bool on = true}) async => blocked.add(chatId);
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

/// The Human check (lib/inbox/human_check.dart; GMFB-23, Matt, Mac 0.12.6: "have new messages from that platform stay
/// hidden from notificatoins and my messages until they solve a small challenge").
void main() {
  group('the questions', () {
    test('every question is answered by its own answer, and each kind is made', () {
      final kinds = <String>{};
      for (var seed = 0; seed < 400; seed++) {
        final c = makeChallenge(Random(seed));
        kinds.add(c.kind);
        expect(c.answers, isNotEmpty, reason: c.question);
        expect(passes(c, c.answers.first), isTrue, reason: '${c.question} -> ${c.answers.first}');
        expect(passes(c, 'What are you doing tonight?'), isFalse, reason: 'the opener itself is no answer to ${c.question}');
        expect(passes(c, ''), isFalse);
      }
      expect(kinds, {'sum', 'word', 'riddle'});
    });

    test('a sum takes the number in digits or words, said briefly, and nothing that throws numbers at it', () {
      const c = HumanChallenge(kind: 'sum', question: 'What is seven plus five? Reply with the number.', answers: ['12']);
      expect(passes(c, '12'), isTrue);
      expect(passes(c, 'Twelve!'), isTrue);
      expect(passes(c, "it's 12"), isTrue);
      expect(passes(c, '13'), isFalse);
      expect(passes(c, '11 12 13'), isFalse);
      expect(passes(c, 'hey babe 12 is my favourite number, are you free tonight for a drink'), isFalse);
    });

    test('a word of a sentence, and a riddle, by the word', () {
      const w = HumanChallenge(kind: 'word', question: 'Reply with the second word of this sentence: "Several orange kites circle windy hills."', answers: ['orange']);
      expect(passes(w, 'Orange'), isTrue);
      expect(passes(w, '"orange."'), isTrue);
      expect(passes(w, 'several'), isFalse);
      const r = HumanChallenge(kind: 'riddle', question: 'What has hands but can\'t clap? Reply in a word.', answers: ['clock', 'watch']);
      expect(passes(r, 'A clock!'), isTrue);
      expect(passes(r, 'clocks'), isTrue);
      expect(passes(r, 'a person'), isFalse);
    });

    test('a chat\'s question is the same on every device, and the second try asks something else', () {
      final a = HumanChallenge.forChat('telegram', '42', 0);
      expect(HumanChallenge.forChat('telegram', '42', 0).question, a.question);
      expect(HumanChallenge.fromJson(a.toJson())!.answers, a.answers);
      final tries = {for (var i = 0; i < 6; i++) HumanChallenge.forChat('telegram', '42', i).question};
      expect(tries.length, greaterThan(1));
    });

    test('the message says it is an automatic check from the person\'s app, and is short', () {
      final c = HumanChallenge.forChat('signal', 'x', 0);
      expect(c.message(), startsWith(HumanChallenge.marker));
      expect(c.message(), contains('my messaging app'));
      expect(c.message(), endsWith(c.question));
      expect(c.message().length, lessThan(220));
      expect(c.message(again: true), startsWith(HumanChallenge.marker));
    });
  });

  group('holding and letting in', () {
    final began = DateTime(2026, 11, 22, 12);
    late GateNet net;
    late HumanCheck check;
    late InboxAlerts alerts;
    late List<InboxAlert> told;
    late Map<String, String> kept;
    var choices = const HumanCheckChoices(networks: {'signal'});

    InboxChat chat(String id, {String on = 'signal', int minutes = 5, bool mine = false, bool group = false, bool stranger = false, bool service = false, String text = 'WHat are you doing tonight?', int unread = 1}) =>
        InboxChat(network: on, id: id, title: 'Someone $id', date: began.add(Duration(minutes: minutes)), snippet: text, unread: unread, lastFromMe: mine, group: group, stranger: stranger, service: service);

    /// The check and the notifications watching [n], with [first] the chats there as the network was first guarded.
    void watch(GateNet n, List<InboxChat> first) {
      net = n..chatList = first;
      told = [];
      kept = {};
      check = HumanCheck(choices: () => choices, read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v, now: () => began);
      HumanCheck.instance = check;
      final inbox = Inbox.of([net]);
      check.watch(inbox);
      alerts = InboxAlerts(notify: told.add, cancel: (_) {}, keepAlive: (_) {}, inFront: () => false, now: () => began.subtract(const Duration(minutes: 1)));
      InboxAlerts.instance = alerts;
      alerts.watch(inbox);
    }

    setUp(() => choices = const HumanCheckChoices(networks: {'signal'}));
    tearDown(() {
      HumanCheck.instance = null;
      InboxAlerts.instance = null;
      InboxNetwork.holding = null;
    });

    test('a first message from someone new is held: out of the list, no notification, and one question sent back', () async {
      watch(GateNet('signal'), [chat('old', minutes: -60, unread: 0)]);
      net.set([...net.chatList, chat('new')]);
      expect(net.shownChats.map((c) => c.id), ['old']);
      expect(net.unreadChats, 0);
      expect(told, isEmpty);
      await pumpEventQueue();
      expect(net.sent.single.$1, 'new');
      expect(net.sent.single.$2, startsWith(HumanChallenge.marker));
      expect(check.recordOf('signal', 'new')!.state, HoldState.asked);
      expect(net.shownChats.map((c) => c.id), ['old'], reason: 'its own question does not let it in');
      expect(told, isEmpty);
      expect(check.heldChats(Inbox.of([net])).single.id, 'new');
    });

    test('the right answer lets it in, and it notifies from then on as any chat does', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('new')]);
      await pumpEventQueue();
      final asked = check.recordOf('signal', 'new')!.challenge!;
      net.hear('new', asked.answers.first, began.add(const Duration(minutes: 6)));
      await pumpEventQueue();
      expect(check.recordOf('signal', 'new')!.state, HoldState.passed);
      expect(net.shownChats.map((c) => c.id), ['new']);
      expect(told.single.key, 'signal:new');
      expect(net.sent, hasLength(1), reason: 'nothing more is sent');
      net.hear('new', 'so, what are you doing tonight?', began.add(const Duration(minutes: 7)));
      expect(told, hasLength(2));
    });

    test('a wrong answer is asked once more; a second wrong one stays held with nothing more sent', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('bot')]);
      await pumpEventQueue();
      net.hear('bot', 'hey cutie wanna chat', began.add(const Duration(minutes: 6)));
      await pumpEventQueue();
      expect(net.sent, hasLength(2));
      expect(net.sent.last.$2, startsWith('${HumanChallenge.marker}, one more try'));
      expect(check.recordOf('signal', 'bot')!.tries, 1);
      net.hear('bot', 'click my link', began.add(const Duration(minutes: 7)));
      await pumpEventQueue();
      expect(check.recordOf('signal', 'bot')!.state, HoldState.failed);
      net.hear('bot', 'hello??', began.add(const Duration(minutes: 8)));
      await pumpEventQueue();
      expect(net.sent, hasLength(2));
      expect(net.shownChats, isEmpty);
      expect(told, isEmpty);
    });

    test('never held: contacts, groups (unless chosen), the network\'s own account, a chat written in, chats from before', () async {
      watch(GateNet('signal', people: const [InboxContact(network: 'signal', id: 'friend', name: 'Friend')]), [chat('before', minutes: -5)]);
      net.set([
        ...net.chatList,
        chat('friend'),
        chat('group', group: true),
        chat('codes', service: true),
        chat('replied', mine: true),
        chat('earlier', minutes: -30),
      ]);
      await pumpEventQueue();
      expect(net.sent, isEmpty);
      expect(net.shownChats, hasLength(6));
      // A group, where chosen.
      choices = const HumanCheckChoices(networks: {'signal'}, groups: true);
      net.set([...net.chatList, chat('group2', group: true)]);
      expect(net.shownChats.map((c) => c.id), isNot(contains('group2')));
    });

    test('on Telegram, a chat it does not mark as a stranger\'s is a contact\'s', () async {
      choices = const HumanCheckChoices(networks: {'telegram'});
      watch(GateNet('telegram', strangersMarked: true), const []);
      net.set([chat('known', on: 'telegram'), chat('cold', on: 'telegram', stranger: true)]);
      await pumpEventQueue();
      expect(net.sent.map((s) => s.$1), ['cold']);
    });

    test('a chat whose messages show this account wrote in it before is let through without a question', () async {
      watch(GateNet('signal'), const []);
      net.messages['back'] = [
        InboxMessage(id: '1', text: 'see you then', date: began.subtract(const Duration(days: 30)), mine: true),
        InboxMessage(id: '2', text: 'WHat are you doing tonight?', date: began.add(const Duration(minutes: 5)), mine: false),
      ];
      net.set([chat('back')]);
      expect(net.shownChats, isEmpty, reason: 'held while it is looked at');
      await pumpEventQueue();
      expect(net.sent, isEmpty);
      expect(net.shownChats.map((c) => c.id), ['back']);
      expect(told.single.key, 'signal:back');
    });

    test('a question already sent from another device is taken as this one\'s', () async {
      watch(GateNet('signal'), const []);
      final q = HumanChallenge.forChat('signal', 'twice', 0);
      net.messages['twice'] = [
        InboxMessage(id: '1', text: 'hi', date: began.add(const Duration(minutes: 4)), mine: false),
        InboxMessage(id: '2', text: q.message(), date: began.add(const Duration(minutes: 4)), mine: true),
      ];
      net.set([chat('twice')]);
      await pumpEventQueue();
      expect(net.sent, isEmpty);
      expect(check.recordOf('signal', 'twice')!.state, HoldState.asked);
      expect(check.recordOf('signal', 'twice')!.challenge!.question, q.question);
    });

    test('let in by hand: in the list without a notification; blocked by hand: blocked on the network', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('a'), chat('b', minutes: 6)]);
      await pumpEventQueue();
      check.release(net, 'a');
      expect(net.shownChats.map((c) => c.id), ['a']);
      expect(told, isEmpty);
      await check.block(net, 'b');
      expect(net.blocked, ['b']);
      expect(check.recordOf('signal', 'b')!.state, HoldState.blocked);
      expect(check.heldChats(Inbox.of([net])), isEmpty);
    });

    test('the person writing in a held chat lets it in', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('a')]);
      await pumpEventQueue();
      net.set([chat('a', mine: true, text: 'hi, who is this?')]);
      expect(check.recordOf('signal', 'a')!.state, HoldState.released);
      expect(net.shownChats.map((c) => c.id), ['a']);
    });

    test('a question that cannot be sent leaves it held, for the person to decide', () async {
      watch(GateNet('signal')..failSends = true, const []);
      net.set([chat('a')]);
      await pumpEventQueue();
      expect(check.recordOf('signal', 'a')!.state, HoldState.unsent);
      expect(net.shownChats, isEmpty);
    });

    test('nothing is held on a network not chosen, or with the plugin off; what was held shows again', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('a')]);
      await pumpEventQueue();
      expect(net.shownChats, isEmpty);
      choices = const HumanCheckChoices();
      expect(net.shownChats.map((c) => c.id), ['a']);
      net.set([...net.chatList, chat('b', minutes: 9)]);
      await pumpEventQueue();
      expect(net.sent, hasLength(1));
      expect(net.shownChats, hasLength(2));
    });

    test('a network just chosen takes what is there as there before at once, and holds the next new one', () async {
      choices = const HumanCheckChoices();
      final changed = ValueNotifier(0);
      net = GateNet('signal')..chatList = [chat('there', minutes: 30)];
      kept = {};
      check = HumanCheck(choices: () => choices, read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v, now: () => began.add(const Duration(minutes: 40)));
      check.watch(Inbox.of([net]), choicesChanged: changed);
      choices = const HumanCheckChoices(networks: {'signal'});
      changed.value++;
      net.set([...net.chatList, chat('next', minutes: 41)]);
      await pumpEventQueue();
      expect(net.shownChats.map((c) => c.id), ['there']);
      expect(net.sent.single.$1, 'next');
    });

    test('the state is kept on the device and read back', () async {
      watch(GateNet('signal'), const []);
      net.set([chat('a')]);
      await pumpEventQueue();
      final again = HumanCheck(choices: () => choices, read: (k) => kept[k] ?? '', write: (k, v) => kept[k] = v);
      expect(again.recordOf('signal', 'a')!.state, HoldState.asked);
      expect(again.held(net), {'a'});
    });
  });

  test('the plugin: off until added, each network off until chosen, and in the list of plugins', () {
    expect(shippedPlugins.whereType<HumanCheckPlugin>(), hasLength(1));
    const plugin = HumanCheckPlugin();
    expect(plugin.onByDefault, isFalse);
    final registry = PluginRegistry(const [plugin]);
    final store = MemoryStore();
    expect(HumanCheckPlugin.choicesIn(registry, store), isNull);
    registry.setOn(plugin, store, true);
    expect(HumanCheckPlugin.choicesIn(registry, store)!.networks, isEmpty);
    store.write('plugin_humancheck_net_telegram', 'on');
    expect(HumanCheckPlugin.choicesIn(registry, store)!.networks, {'telegram'});
    expect(HumanCheckPlugin.choicesIn(registry, store)!.groups, isFalse);
    expect(plugin.settings.where((s) => s.toggle).every((s) => !s.fallback), isTrue, reason: 'every switch off until chosen');
  });

  test('the networks it offers are every network offered', () {
    expect(HumanCheckPlugin.networks, [for (final n in Inbox.instance.networks) if (!n.soon) (n.id, n.name)]);
  });
}
