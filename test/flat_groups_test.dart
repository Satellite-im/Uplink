import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/plugins/embeds.dart' show EmbedCard;
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/shown_store.dart';
import 'package:ghost_messaging/plugins/translate.dart';
import 'package:ghost_messaging/ui/chat_rail.dart';
import 'package:ghost_messaging/ui/common.dart' show Avatar, clock;
import 'package:ghost_messaging/ui/flat_line.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/message_line.dart';
import 'package:ghost_messaging/ui/reaction_stickers.dart';
import 'package:ghost_messaging/ui/skeleton.dart';
import 'package:ghost_messaging/ui/thread.dart' show LinkedText;
import 'package:ghost_messaging/ui/translated_card.dart';
import 'package:glacier/glacier.dart';

import 'plugins/translate_test.dart' show FakeHost;
import 'support/space_call_harness.dart';

/// A group on another network is drawn as a circle's chat is (Matt, 2026-11-25: "For channels on slack and other groups
/// please use the same chat UI without the bubbles we use with text channels on circles"): everyone on the left,
/// yourself too, no bubbles, a run's face, name and time once (lib/ui/flat_line.dart); a chat with one person keeps its
/// bubbles. Pictures: build/flat-groups/*.png (--update-goldens).
class _Net extends InboxNetwork {
  _Net(this.id, this.name, this._chats, this._messages, {this.ready = true});
  @override
  final String id;
  @override
  final String name;
  final List<InboxChat> _chats;
  final Map<String, List<InboxMessage>> _messages;

  /// Whether it has answered for a chat's messages.
  final bool ready;
  final faces = <String, String>{};
  final reacted = <(String, String, bool)>[];
  final replied = <(String, String)>[];
  final deleted = <(String, bool)>[];
  bool profiles = false;

  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => '@matt';
  @override
  List<InboxChat> get chats => _chats;
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];
  @override
  Future<void> load(String chatId, {bool older = false}) => ready ? Future.value() : Future.delayed(const Duration(days: 1));
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  bool get canSendFiles => true;
  @override
  bool get canReact => true;
  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async => reacted.add((messageId, emoji, remove));
  @override
  bool get canReply => true;
  @override
  Future<void> reply(String chatId, String messageId, String text) async => replied.add((messageId, text));
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine;
  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async => deleted.add((messageId, forEveryone));
  @override
  String? faceOf(String user) => faces[user];
  @override
  bool get hasProfiles => profiles;
  @override
  Future<InboxProfile?> profileOf({String user = '', String username = ''}) async => InboxProfile(network: id, id: user, name: 'Maya Chen', bio: 'Design lead');
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

final _day = DateTime(2026, 11, 24, 9);
DateTime _at(int min) => _day.add(Duration(minutes: min));
String get _picture => File('assets/stickers/mischief/14.png').absolute.path;

/// A channel with one of everything in it.
List<InboxMessage> _mixed() => [
      InboxMessage(id: '1', text: 'Morning all! Standup in ten?', date: _at(0), mine: false, sender: 'Maya Chen', senderId: 'U1', reactions: const [InboxReaction(emoji: '👍', count: 2, mine: true), InboxReaction(emoji: '🎉')]),
      InboxMessage(id: '2', text: 'I put the agenda in the channel files.', date: _at(1), mine: false, sender: 'Maya Chen', senderId: 'U1', edited: true, versions: const ['I put the agenda in Files.']),
      InboxMessage(id: '3', text: 'On my way, grabbing coffee first', date: _at(2), mine: false, sender: 'Kevin Moss', senderId: 'U2', replyTo: '1', replySender: 'Maya Chen', replyText: 'Morning all! Standup in ten?'),
      InboxMessage(id: '4', text: 'Same here. Five minutes.', date: _at(3), mine: true, senderId: 'U9'),
      InboxMessage(id: '5', text: 'Can someone share the notes?', date: _at(4), mine: true, senderId: 'U9'),
      InboxMessage(id: '6', text: '@matt they are pinned to the top of this channel, under the second heading from the end', date: _at(5), mine: false, sender: 'Kevin Moss', senderId: 'U2', mentions: const [InboxMention(start: 0, length: 5, user: 'U9')]),
      InboxMessage(id: 'e', text: 'Priya Shah joined #general', date: _at(6), mine: false, event: true),
      InboxMessage(id: '7', text: 'The new artwork', date: _at(60), mine: false, sender: 'Priya Shah', senderId: 'U3', media: [InboxMedia(kind: 'photo', fileId: 1, path: _picture, width: 800, height: 600)]),
      InboxMessage(id: '8', text: '', date: _at(61), mine: false, sender: 'Priya Shah', senderId: 'U3', media: const [InboxMedia(kind: 'file', fileId: 2, name: 'agenda.pdf', size: 245760)]),
      InboxMessage(id: '9', text: '', date: _at(62), mine: false, sender: 'Maya Chen', senderId: 'U1', media: const [InboxMedia(kind: 'audio', fileId: 3, name: 'Voice message', duration: 14)]),
      InboxMessage(id: '10', text: '', date: _at(63), mine: true, senderId: 'U9', media: [InboxMedia(kind: 'sticker', fileId: 4, path: _picture, width: 512, height: 512)]),
      InboxMessage(id: '11', text: 'Nice work everyone.', date: _at(90), mine: false, sender: 'Maya Chen', senderId: 'U1'),
      InboxMessage(id: '12', text: 'Shipping it now', date: _at(91), mine: true, senderId: 'U9', state: 'failed'),
      InboxMessage(id: '13', text: 'Trying that again', date: _at(92), mine: true, state: 'sending'),
    ];

_Net _slack({List<InboxMessage>? said, bool group = true}) => _Net('slack', 'Slack', [
      InboxChat(network: 'slack', id: 'c', title: group ? '#general' : 'Maya Chen', date: _at(92), group: group),
    ], {'c': said ?? _mixed()});

late TokenSheet _sheet;

Future<void> _show(WidgetTester tester, Widget page, {Size size = const Size(412, 900), bool dark = false, Look? look, Map<String, String> prefs = const {}}) async {
  final state = AppState();
  prefs.forEach(state.set);
  if (look != null) state.setLook(look);
  state.setTheme(dark ? 'dark' : 'light');
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF4F5BD5),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(
        sheet: _sheet,
        attrs: ghostAttrs(state, 'mobile'),
        typography: ghostTypography('noto'),
        child: InkOverrides(child: GlacierToastProvider(child: child!)),
      ),
      home: KeyedSubtree(key: UniqueKey(), child: page),
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // Pictures read and decoded for real, a step of it a turn.
  for (var i = 0; i < (autoUpdateGoldenFiles ? 10 : 3); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _keep(String name) async {
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/flat-groups/$name.png'));
}

/// Anything with a ground of its own behind [of], inside the chat's list: a bubble, or a card.
Finder _ground(Finder of) => find.ancestor(of: of, matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color != null));

Rect _rect(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void main() {
  Future<void> load(WidgetTester tester) async {
    await SpaceHarness.load(tester);
    _sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(_sheet);
  }

  testWidgets('a Slack channel draws no bubble: everyone on the left, yourself too, under your own name and face', (tester) async {
    await load(tester);
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().take(5).toList()), chatId: 'c'));
    expect(find.byType(FlatLine), findsNWidgets(5));
    final theirs = tester.getRect(find.text('On my way, grabbing coffee first'));
    final mine = tester.getRect(find.text('Same here. Five minutes.'));
    expect(mine.left, theirs.left, reason: 'one column, no sides');
    for (final words in ['On my way, grabbing coffee first', 'Same here. Five minutes.', 'Can someone share the notes?']) {
      expect(_ground(find.text(words)), findsNothing, reason: 'no bubble behind "$words"');
    }
    expect(find.text('You'), findsOneWidget);
    expect(find.byType(InboxFace), findsNWidgets(3), reason: 'a face a run, yours among them');
    expect(find.byWidgetPredicate((w) => w is InboxFace && w.mine), findsOneWidget);
    // The name and the time share a line, the time after it.
    expect(tester.getRect(find.text(clock(_at(2)))).left, greaterThan(tester.getRect(find.text('Kevin Moss')).right));
    expect(find.byType(ReactionStickers), findsNothing);
  });

  testWidgets('a chat with one person keeps its bubbles: yours on the right', (tester) async {
    await load(tester);
    final said = [
      InboxMessage(id: '1', text: 'are you coming tonight?', date: _at(0), mine: false, sender: 'Maya Chen', senderId: 'U1', reactions: const [InboxReaction(emoji: '❤️')]),
      InboxMessage(id: '2', text: 'Yes, at eight', date: _at(1), mine: true, senderId: 'U9'),
      InboxMessage(id: '3', text: 'see you there', date: _at(2), mine: false, sender: 'Maya Chen', senderId: 'U1'),
    ];
    for (final dark in [false, true]) {
      for (final (size, label) in [(const Size(1280, 800), '1280'), (const Size(412, 900), '412')]) {
        await _show(tester, InboxChatScreen(network: _slack(said: said, group: false), chatId: 'c'), size: size, dark: dark);
        expect(find.byType(FlatLine), findsNothing);
        expect(find.text('You'), findsNothing);
        expect(tester.getRect(find.text('Yes, at eight')).left, greaterThan(tester.getRect(find.text('are you coming tonight?')).left + 40));
        expect(_ground(find.text('Yes, at eight')), findsWidgets);
        expect(find.byType(ReactionStickers), findsOneWidget, reason: 'reactions stuck on the bubble, as before');
        await _keep('one-to-one-$label-${dark ? 'dark' : 'light'}');
      }
    }
  });

  testWidgets('runs: the face, name and time once, until someone else, five minutes, a day, an event or the New messages line', (tester) async {
    await load(tester);
    InboxMessage m(String id, int min, {String by = 'Maya Chen', String who = 'U1', bool event = false}) => InboxMessage(id: id, text: 'words $id', date: _at(min), mine: false, sender: event ? '' : by, senderId: event ? '' : who, event: event);
    final net = _Net('telegram', 'Telegram', [InboxChat(network: 'telegram', id: 'c', title: 'Crew', date: _at(30), group: true, unread: 1)], {
      'c': [
        m('a', -1440), // the day before
        m('b', 0), m('c', 4), // a run: four minutes
        m('d', 10), // six minutes after
        m('e', 11, event: true),
        m('f', 12), // after something that happened
        m('g', 13, who: 'U7'), // another person of the same name
        m('h', 14, who: 'U7'), // the New messages line stands above it
      ],
    });
    await _show(tester, InboxChatScreen(network: net, chatId: 'c'), size: const Size(412, 1400));
    final firsts = {for (final l in tester.widgetList<FlatLine>(find.byType(FlatLine))) if (l.first) l.at};
    expect(firsts, {_at(-1440), _at(0), _at(10), _at(12), _at(13), _at(14)});
    expect(find.byType(DayTurn), findsNWidgets(2));
    expect(find.byKey(const ValueKey('new-messages')), findsOneWidget);
    expect(find.byKey(const ValueKey('event-e')), findsOneWidget);
    // A line of something that happened is in the middle, with no name over it.
    expect(find.text('Someone'), findsNothing);
  });

  testWidgets('a quote at the head of a reply, as in a circle', (tester) async {
    await load(tester);
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().take(5).toList()), chatId: 'c'));
    final quote = find.byKey(const ValueKey('inbox-quote-3'));
    expect(quote, findsOneWidget);
    expect(tester.widget(quote), isA<FlatQuote>());
    expect(find.descendant(of: quote, matching: find.text('Maya Chen')), findsOneWidget);
    expect(find.descendant(of: quote, matching: find.text('Morning all! Standup in ten?')), findsOneWidget);
    expect(tester.getRect(quote).bottom, lessThan(tester.getRect(find.text('On my way, grabbing coffee first')).top));
  });

  testWidgets('reactions are pills under it: pressed, yours comes off or goes on, and the plus opens the menu', (tester) async {
    await load(tester);
    final net = _slack(said: _mixed().take(5).toList());
    await _show(tester, InboxChatScreen(network: net, chatId: 'c'));
    expect(find.byType(ReactionChips), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reaction-chip-👍')));
    await tester.pump();
    expect(net.reacted.last, ('1', '👍', true), reason: 'mine: off');
    await tester.tap(find.byKey(const ValueKey('reaction-chip-🎉')));
    await tester.pump();
    expect(net.reacted.last, ('1', '🎉', false));
    await tester.tap(find.byKey(const ValueKey('reaction-chip-add')));
    await _settle(tester);
    expect(find.byType(InboxReactionRow), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(InboxReactionRow), matching: find.text('😂')));
    await _settle(tester);
    expect(net.reacted.last, ('1', '😂', false));
  });

  testWidgets('the menu, from a long press and from a mouse\'s other button; a reply, what an edit first said, and a delete', (tester) async {
    await load(tester);
    final net = _slack(said: _mixed().take(5).toList());
    await _show(tester, InboxChatScreen(network: net, chatId: 'c'));
    await tester.longPress(find.text('Same here. Five minutes.'));
    await _settle(tester);
    for (final c in ['Reply', 'Copy', 'Delete for everyone', 'Delete for me']) {
      expect(find.text(c), findsOneWidget, reason: c);
    }
    await tester.tap(find.text('Reply'));
    await _settle(tester);
    expect(find.text('Replying to yourself'), findsOneWidget);
    // "(edited)" pressed shows what it first said.
    await tester.tap(find.byKey(const ValueKey('edited-2')));
    await _settle(tester);
    expect(find.text('First sent as:\nI put the agenda in Files.'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await _settle(tester);
    // The other button, off the words: anywhere on the line.
    await tester.tapAt(tester.getRect(find.text('Can someone share the notes?')).centerRight + const Offset(30, 0), buttons: kSecondaryButton);
    await _settle(tester);
    await tester.tap(find.text('Delete for everyone'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(net.deleted.single, ('5', true));
  });

  testWidgets('media on the page: a picture and a sticker with nothing behind them, a file and a sound on a card', (tester) async {
    await load(tester);
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().sublist(7, 11)), chatId: 'c'), size: const Size(412, 1200));
    expect(find.byType(InboxMediaView), findsNWidgets(4));
    expect(_ground(find.byType(InboxSticker)), findsNothing);
    expect(_ground(find.text('The new artwork')), findsNothing);
    expect(_ground(find.text('agenda.pdf')), findsWidgets, reason: 'a card, as a circle\'s files have');
    expect(_ground(find.text('Voice message')), findsWidgets);
    final left = tester.getRect(find.text('The new artwork')).left;
    for (final e in find.byType(InboxMediaView).evaluate()) {
      expect(_rect(e).left, left, reason: 'all in the one column');
    }
  });

  testWidgets('a message that failed says so, one on its way is fainter and says so; neither takes a reaction', (tester) async {
    await load(tester);
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().sublist(11)), chatId: 'c'));
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Sending…'), findsOneWidget);
    expect(tester.getRect(find.text('Not sent')).left, tester.getRect(find.text('Shipping it now')).left);
    final faint = find.ancestor(of: find.text('Trying that again'), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.6));
    expect(faint, findsOneWidget);
    await _show(tester, InboxChatScreen(network: _slack(said: [InboxMessage(id: 'x', text: 'no', date: _at(0), mine: true, state: 'failed', reactions: const [InboxReaction(emoji: '👍')])]), chatId: 'c'));
    expect(find.byKey(const ValueKey('reaction-chip-add')), findsNothing);
  });

  testWidgets('a message that mentions you is marked, by your id or your username; another\'s is not', (tester) async {
    await load(tester);
    final said = [
      InboxMessage(id: '1', text: 'mine', date: _at(0), mine: true, senderId: 'U9'),
      InboxMessage(id: '2', text: '@Matthew here', date: _at(1), mine: false, sender: 'Maya', senderId: 'U1', mentions: const [InboxMention(start: 0, length: 8, user: 'U9')]),
      InboxMessage(id: '3', text: 'ask @Matt about it', date: _at(2), mine: false, sender: 'Maya', senderId: 'U1'),
      InboxMessage(id: '4', text: 'ask @matthias about it', date: _at(3), mine: false, sender: 'Maya', senderId: 'U1'),
      InboxMessage(id: '5', text: 'I am @matt', date: _at(4), mine: true, senderId: 'U9'),
    ];
    await _show(tester, InboxChatScreen(network: _slack(said: said), chatId: 'c'));
    expect([for (final l in tester.widgetList<FlatLine>(find.byType(FlatLine))) if (l.mentionsMe) l.at], unorderedEquals([_at(1), _at(2)]));
  });

  testWidgets('a face is the network\'s own picture of them; a name pressed opens their card where the network has one', (tester) async {
    await load(tester);
    final net = _slack(said: _mixed().take(5).toList())
      ..faces['U1'] = _picture
      ..faces['U9'] = _picture
      ..profiles = true;
    await _show(tester, InboxChatScreen(network: net, chatId: 'c'));
    String? photo(String id) => tester.widgetList<Avatar>(find.byType(Avatar)).map((a) => a.people.single).where((p) => p.address == 'slack:$id').firstOrNull?.photo;
    expect(photo('U1'), _picture);
    expect(photo('U9'), _picture, reason: 'your own, as the network has you');
    expect(photo('U2'), isNull);
    final name = find.descendant(of: find.byWidgetPredicate((w) => w is FlatLine && w.at == _at(0)), matching: find.text('Maya Chen'));
    await tester.tap(name);
    await _settle(tester);
    expect(find.text('Design lead'), findsOneWidget);
    expect(find.text('Message on Slack'), findsNWidgets(2), reason: 'the card\'s, and the box\'s hint');
    // Where the network says nothing of its people, a press is nothing.
    net.profiles = false;
    await _show(tester, InboxChatScreen(network: net, chatId: 'c'));
    await tester.tap(name);
    await _settle(tester);
    expect(find.text('Design lead'), findsNothing);
    expect(find.text('Message on Slack'), findsOneWidget, reason: 'the box\'s hint alone');
  });

  testWidgets('a translation in place of the words, with the words as they came over it; a link\'s card under them', (tester) async {
    await load(tester);
    final host = PluginRegistry.textHost, registry = PluginRegistry.instance;
    addTearDown(() {
      PluginRegistry.textHost = host;
      PluginRegistry.instance = registry;
      ShownStore.instance = ShownStore();
    });
    TranslatePlugin.asked.clear();
    ShownStore.instance = ShownStore();
    await _show(tester, InboxChatScreen(network: _slack(said: [InboxMessage(id: '1', text: 'look at https://example.com/menu tonight', date: _at(0), mine: false, sender: 'Maya', senderId: 'U1')]), chatId: 'c'));
    expect(find.byType(EmbedCard), findsOneWidget, reason: 'Link previews is on as the app ships');
    expect(_rect(find.byType(EmbedCard).evaluate().single).top, greaterThan(_rect(find.byType(LinkedText).evaluate().single).top));

    const hola = 'Hola, ¿cómo estás? ¿Vienes a la fiesta esta noche?', hello = 'Hi, how are you? Are you coming to the party tonight?';
    PluginRegistry.textHost = FakeHost({hola: const DeviceTranslation('done', text: hello, from: 'es')});
    PluginRegistry.instance = PluginRegistry([const TranslatePlugin()]);
    await _show(tester, InboxChatScreen(network: _slack(said: [InboxMessage(id: '2', text: hola, date: _at(0), mine: false, sender: 'Maya', senderId: 'U1')]), chatId: 'c'), prefs: {'plugin_translate': 'on'});
    expect(find.byType(OriginalCard), findsOneWidget);
    expect(find.text(hello), findsOneWidget);
    expect(find.text(hola), findsOneWidget);
    await _keep('slack-translated-412-light');
  });

  testWidgets('while it loads, a group\'s shapes are a channel\'s lines; one person\'s are bubbles', (tester) async {
    await load(tester);
    for (final group in [true, false]) {
      final net = _Net('slack', 'Slack', [InboxChat(network: 'slack', id: 'c', title: 'x', date: _at(0), group: group)], {}, ready: false);
      await _show(tester, InboxChatScreen(network: net, chatId: 'c'));
      expect(tester.widget<SkeletonChat>(find.byType(SkeletonChat)).flat, group);
      final bones = [for (final e in find.byType(Bone).evaluate()) _rect(e)];
      if (group) expect(bones.every((r) => r.right < 412 - 8), isTrue);
      await _keep('loading-${group ? 'group' : 'one-to-one'}-412-light');
    }
    await tester.pump(const Duration(days: 2));
  });

  testWidgets('the chat\'s map stands at the right, with everyone\'s faces', (tester) async {
    await load(tester);
    await _show(tester, InboxChatScreen(network: _slack(), chatId: 'c'));
    expect(tester.widget<ChatRail>(find.byType(ChatRail)).face, isNotNull);
    await _show(tester, InboxChatScreen(network: _slack(group: false), chatId: 'c'));
    expect(tester.widget<ChatRail>(find.byType(ChatRail)).face, isNull);
  });

  testWidgets('narrow: nothing runs over', (tester) async {
    await load(tester);
    for (final width in [280.0, 320.0, 360.0]) {
      final net = _slack(said: [
        ..._mixed(),
        InboxMessage(id: 'l', text: 'a-very-long-word-that-has-nowhere-to-break-' * 3, date: _at(95), mine: false, sender: 'Someone With A Really Very Long Display Name Indeed', senderId: 'U5', replyTo: '1', replySender: 'Someone Else With A Really Very Long Display Name', replyText: 'x' * 200, reactions: [for (final e in ['❤️', '👍', '👎', '😂', '😮', '😢', '🙏', '🔥', '🎉']) InboxReaction(emoji: e, count: 12)]),
      ]);
      await _show(tester, InboxChatScreen(network: net, chatId: 'c'), size: Size(width, 2400));
      expect(tester.takeException(), isNull);
      for (final e in find.byType(FlatLine).evaluate()) {
        expect(_rect(e).right, lessThanOrEqualTo(width));
      }
      if (width == 320) await _keep('slack-320-light');
    }
  });

  testWidgets('Dial-Up writes a group as it writes a circle: a transcript, with names and mentions pressable and edits said', (tester) async {
    await load(tester);
    final net = _slack()..profiles = true;
    for (final (size, label) in [(const Size(1280, 800), '1280'), (const Size(412, 900), '412')]) {
      await _show(tester, InboxChatScreen(network: net, chatId: 'c'), size: size, look: Look.dialup);
      expect(find.byType(FlatLine), findsNothing);
      expect(find.byType(MessageLine), findsWidgets);
      final lines = tester.widgetList<MessageLine>(find.byType(MessageLine)).toList();
      expect(lines.where((l) => l.mine).every((l) => l.name == 'You' && l.onNameTap == null), isTrue);
      expect(lines.where((l) => !l.mine).every((l) => l.onNameTap != null), isTrue);
      await _keep('slack-dialup-$label');
    }
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().take(6).toList()), chatId: 'c'), size: const Size(412, 900), look: Look.dialup);
    expect(tester.widgetList<MessageLine>(find.byType(MessageLine)).where((l) => l.edited != null).length, 1);
    expect(tester.widgetList<LinkedText>(find.byType(LinkedText)).where((l) => l.mentions.isNotEmpty).length, 1);
    // One to one: as it was.
    await _show(tester, InboxChatScreen(network: _slack(said: _mixed().take(6).toList(), group: false), chatId: 'c'), size: const Size(412, 900), look: Look.dialup);
    expect(tester.widgetList<MessageLine>(find.byType(MessageLine)).where((l) => l.edited != null || l.mentions.isNotEmpty), isEmpty);
  });

  testWidgets('pictures: a Slack channel and a Telegram group, light and dark, on a computer and a phone', (tester) async {
    await load(tester);
    final telegram = _Net('telegram', 'Telegram', [InboxChat(network: 'telegram', id: 'c', title: 'Weekend crew', date: _at(30), group: true, unread: 2)], {
      'c': [
        InboxMessage(id: '1', text: 'who is driving on Saturday?', date: _at(0), mine: false, sender: 'Priya Shah', senderId: '71'),
        InboxMessage(id: '2', text: 'I can. Room for three', date: _at(2), mine: true, senderId: '9', reactions: const [InboxReaction(emoji: '🔥', count: 3), InboxReaction(emoji: '❤️', mine: true)]),
        InboxMessage(id: '3', text: 'Esther joined the group', date: _at(3), mine: false, event: true),
        InboxMessage(id: '4', text: 'tent is packed, and the stove', date: _at(20), mine: false, sender: 'Priya Shah', senderId: '71'),
        InboxMessage(id: '5', text: '', date: _at(21), mine: false, sender: 'Priya Shah', senderId: '71', media: [InboxMedia(kind: 'video', fileId: 8, thumbId: 9, thumbPath: _picture, width: 1280, height: 720, duration: 34)]),
        InboxMessage(id: '6', text: 'leaving at 8 then', date: _at(25), mine: false, sender: 'Dev Rao', senderId: '72', replyTo: '2', replySender: 'You', replyText: 'I can. Room for three'),
        InboxMessage(id: '7', text: 'see https://example.com/trail for the way in', date: _at(26), mine: false, sender: 'Dev Rao', senderId: '72'),
      ],
    });
    for (final dark in [false, true]) {
      for (final (size, label) in [(const Size(1280, 800), '1280'), (const Size(412, 900), '412')]) {
        await _show(tester, InboxChatScreen(network: _slack()..faces['U2'] = _picture, chatId: 'c'), size: size, dark: dark);
        await _keep('slack-$label-${dark ? 'dark' : 'light'}');
        // And its beginning.
        await tester.drag(find.bySubtype<ListView>().first, const Offset(0, 2000));
        await _settle(tester);
        await _keep('slack-$label-top-${dark ? 'dark' : 'light'}');
        await _show(tester, InboxChatScreen(network: telegram, chatId: 'c'), size: size, dark: dark);
        await _keep('telegram-$label-${dark ? 'dark' : 'light'}');
      }
    }
    await _show(tester, InboxChatScreen(network: _slack()..faces['U2'] = _picture, chatId: 'c'), size: const Size(412, 1900));
    await _keep('slack-tall-light');
  });
}
