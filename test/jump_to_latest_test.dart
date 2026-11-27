
import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/chat_rows.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/jump_to_latest.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

// The down arrow back to the newest message, and each chat opening where it was left (lib/ui/jump_to_latest.dart; Matt,
// 2026-11-17: "add a down arrow that pops up when we enter a chat and we're not scrolled to the bottom or after we
// scroll up a certain amount, remember the scroll position when switching between chats"), in all three chats: a
// Telegram chat, a conversation of texts, and a space's chat whose page stays as the room changes.

const _label = 'Jump to the newest message';

/// A Telegram signed in, held in memory: [count] messages in each chat, a long line each, so the list is many screens.
class _Network extends InboxNetwork {
  _Network(List<String> chats, {int count = 60})
      : _messages = {
          for (final c in chats)
            c: [
              for (var i = 0; i < count; i++)
                InboxMessage(id: '$c-$i', text: 'Message $i in $c, long enough to take a line or two of the bubble', date: DateTime(2026, 11, 17, 9).add(Duration(minutes: i)), mine: i.isOdd),
            ],
        };
  final Map<String, List<InboxMessage>> _messages;

  /// [n] older messages come in at the top, as a network's next page back does.
  void older(String chat, int n) {
    final list = _messages[chat]!;
    list.insertAll(0, [
      for (var i = n; i > 0; i--) InboxMessage(id: '$chat-old-$i', text: 'Older $i in $chat, long enough to take a line or two of the bubble', date: DateTime(2026, 11, 16, 9).add(Duration(minutes: -i)), mine: false),
    ]);
    notifyListeners();
  }

  /// Something about the network changed that is not a message (presence, typing): the chat is built again.
  void poke() => notifyListeners();

  void arrive(String chat, String text) {
    final list = _messages[chat]!;
    list.add(InboxMessage(id: '$chat-${list.length}', text: text, date: DateTime(2026, 11, 17, 12).add(Duration(minutes: list.length)), mine: false));
    notifyListeners();
  }

  @override
  String get id => 'telegram';
  @override
  String get name => 'Telegram';
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => '@matt';
  @override
  List<InboxChat> get chats => [for (final c in _messages.keys) InboxChat(network: 'telegram', id: c, title: 'Chat $c', date: DateTime(2026, 11, 17, 12), snippet: '')];
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

/// The phone, answering for a conversation of texts with [count] messages in each thread.
void _phone({int count = 60}) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'status':
        return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      case 'messages':
        final thread = (args['thread'] as num).toInt();
        final base = DateTime(2026, 11, 17, 9).millisecondsSinceEpoch;
        return [
          for (var i = count - 1; i >= 0; i--)
            {'id': thread * 1000 + i, 'kind': 'sms', 'address': '+1555123000$thread', 'body': 'Text $i in thread $thread, long enough to take a line or two', 'date': base + i * 60000, 'outgoing': i.isOdd, 'state': i.isOdd ? 'delivered' : 'received', 'read': true},
        ];
      case 'e2e':
        return {'address': args['address'], 'state': 'none', 'verified': false, 'changed': false};
      case 'prefs':
        return <String, String>{};
      case 'ghostPeers':
      case 'netSmsAvailable':
        return false;
      default:
        return null;
    }
  });
}

/// The message list's own scroll position (the composer has one too).
ScrollPosition _list(WidgetTester tester) {
  final scrollable = find.descendant(of: find.bySubtype<ListView>(), matching: find.byType(Scrollable)).first;
  return tester.state<ScrollableState>(scrollable).position;
}

/// Whether the arrow is up: its fade aimed at showing it. (A semantics finder still sees a node a frame after it is
/// excluded, so the fade is what is read; the label is checked where the arrow is pressed.)
bool _arrow() {
  final fade = find.ancestor(of: find.byKey(const ValueKey('jump-to-latest')), matching: find.byType(AnimatedOpacity));
  return fade.evaluate().any((e) => (e.widget as AnimatedOpacity).opacity == 1);
}

/// Leaves whatever chat was open (its page goes, as switching chats does) and opens [screen].
Future<void> _open(WidgetTester tester, TokenSheet sheet, Widget screen, AppState state) async {
  await tester.pumpWidget(const SizedBox());
  await pumpScreen(tester, sheet, screen, state);
}

Future<void> _up(WidgetTester tester, double by) async {
  _list(tester).jumpTo(_list(tester).pixels + by);
  await settle(tester);
}

void main() {
  keyboardTests();
  late TokenSheet sheet;
  setUp(ScrollMemory.clear);

  testWidgets('a Telegram chat: hidden at the foot, up past a screen it comes, pressed it goes back to the newest', (tester) async {
    final semantics = tester.ensureSemantics();
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a']);
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse, reason: 'at the newest message there is nothing to go back to');

    // A little way up (under a screen) is still near enough: no arrow.
    await _up(tester, 200);
    expect(_arrow(), isFalse);

    // Past a screen and a half.
    await _up(tester, _list(tester).viewportDimension * 1.5);
    expect(_arrow(), isTrue);

    await tester.tap(find.bySemanticsLabel(_label));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse);
    semantics.dispose();
  });

  testWidgets('what others write while the person reads back is counted on the arrow', (tester) async {
    final semantics = tester.ensureSemantics();
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a']);
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    await _up(tester, 300);
    expect(_arrow(), isFalse);
    n.arrive('a', 'are you there?');
    n.arrive('a', 'hello?');
    await settle(tester);
    expect(_arrow(), isTrue, reason: 'new messages bring it even under a screen up');
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(_label));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('2'), findsNothing);
    expect(_arrow(), isFalse);
    semantics.dispose();
  });

  testWidgets('a chat opens where it was left, with the arrow; each chat keeps its own place', (tester) async {
    final semantics = tester.ensureSemantics();
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a', 'b']);
    final state = AppState();
    await _open(tester, sheet, InboxChatScreen(key: const ValueKey('a'), network: n, chatId: 'a'), state);
    await _up(tester, 900);
    final left = _list(tester).pixels;
    expect(left, 900);

    // Chat b, read a little way up (under the arrow's line) and left there.
    await _open(tester, sheet, InboxChatScreen(key: const ValueKey('b'), network: n, chatId: 'b'), state);
    expect(_list(tester).pixels, 0, reason: 'a chat opened for the first time opens at its newest');
    expect(_arrow(), isFalse);
    await _up(tester, 250);

    // Back to a: where it was, and the arrow up at once, though it is under a screen and a half up.
    await _open(tester, sheet, InboxChatScreen(key: const ValueKey('a2'), network: n, chatId: 'a'), state);
    expect(_list(tester).pixels, left);
    expect(_arrow(), isTrue);

    // And b where it was.
    await _open(tester, sheet, InboxChatScreen(key: const ValueKey('b2'), network: n, chatId: 'b'), state);
    expect(_list(tester).pixels, 250);
    expect(_arrow(), isTrue, reason: 'opened away from the newest');

    // Pressed, b is at its newest, and opens there next time.
    await tester.tap(find.bySemanticsLabel(_label));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await _open(tester, sheet, InboxChatScreen(key: const ValueKey('b3'), network: n, chatId: 'b'), state);
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse);
    semantics.dispose();
  });

  testWidgets('a chat that does not yet hold as far back as its spot gets there as its older messages come', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a'], count: 6);
    ScrollMemory.keep('inbox:telegram:a', 2000, seen: 'a-4');
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    expect(_list(tester).pixels, lessThan(2000), reason: 'six messages do not reach that far');
    n.older('a', 60);
    await settle(tester);
    expect(_list(tester).pixels, 2000);
    expect(_arrow(), isTrue);
  });

  testWidgets('a mouse wheel leaves a spot the list cannot reach: messages that come later do not take it back up', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a'], count: 24);
    ScrollMemory.keep('inbox:telegram:a', 5000, seen: 'a-22');
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    final most = _list(tester).maxScrollExtent;
    expect(most, greaterThan(300), reason: 'the chat runs past a screen, but nowhere near 5000');
    // As far back as it goes, give or take the composer settling its height a frame later (the one composer for every
    // conversation, 2026-11-17), which moves the end of the list by a few pixels.
    expect(_list(tester).pixels, closeTo(most, 24), reason: 'as far back as it goes');

    // The wheel, down toward the newest (a mouse on the Mac).
    tester.binding.handlePointerEvent(PointerScrollEvent(position: tester.getCenter(find.bySubtype<ListView>()), scrollDelta: const Offset(0, 200)));
    await settle(tester);
    final read = _list(tester).pixels;
    expect(read, lessThan(most));
    // What the person is reading: the first of the chat's messages on the screen, and where.
    final reading = [for (var i = 0; i < 24; i++) find.textContaining('Message $i in a')].firstWhere((f) => f.evaluate().isNotEmpty);
    final was = tester.getTopLeft(reading).dy;

    n.arrive('a', 'are you there?');
    await settle(tester);
    // Read this far back, a message that comes moves nothing on the screen (lib/ui/chat_rows.dart): the chat is one
    // message further from its newest, and that is all.
    expect(tester.getTopLeft(reading).dy, closeTo(was, 0.5), reason: 'what was being read is where it was');
    final after = _list(tester).pixels;
    expect(after, greaterThan(read + 20));
    expect(after, lessThan(read + 400), reason: 'further from the newest by the message that came, not taken back up to 5000');
    n.older('a', 60);
    await settle(tester);
    expect(tester.getTopLeft(reading).dy, closeTo(was, 0.5), reason: 'the person moved it: it stays where they put it');
    expect(_list(tester).pixels, after);
  });

  testWidgets('a spot past the end of everything the chat holds is given up once the list stops growing', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a'], count: 24);
    ScrollMemory.keep('inbox:telegram:a', 5000, seen: 'a-22');
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    final most = _list(tester).maxScrollExtent;
    expect(_list(tester).pixels, closeTo(most, 24));
    // Built again and again with nothing further back (presence, typing), for a couple of seconds.
    for (var i = 0; i < 5; i++) {
      n.poke();
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_arrow(), isTrue);
    // Older messages coming now (a page read later) no longer take the list up to the old spot.
    n.older('a', 60);
    await settle(tester);
    expect(_list(tester).pixels, most);
  });

  testWidgets('a spot taken at another width (the Fold\'s cover screen, then its inner one) opens at the newest', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a']);
    final state = AppState();
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(tester, sheet, InboxChatScreen(key: const ValueKey('cover'), network: n, chatId: 'a'), state, size: const Size(360, 780));
    await _up(tester, 1200);
    expect(ScrollMemory.of('inbox:telegram:a')?.offset, 1200, reason: 'kept as it goes, not only as the screen goes');

    await tester.pumpWidget(const SizedBox());
    await pumpScreen(tester, sheet, InboxChatScreen(key: const ValueKey('inner'), network: n, chatId: 'a'), state, size: const Size(880, 780));
    expect(_list(tester).pixels, 0, reason: 'every bubble wraps afresh: 1200 would be some other message');
    expect(_arrow(), isFalse);

    // The same width again keeps its place.
    await _up(tester, 700);
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(tester, sheet, InboxChatScreen(key: const ValueKey('inner2'), network: n, chatId: 'a'), state, size: const Size(880, 780));
    expect(_list(tester).pixels, 700);
    expect(_arrow(), isTrue);
  });

  testWidgets('no count where the message last seen is no longer held, however many came', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a'], count: 300);
    ScrollMemory.keep('inbox:telegram:a', 900, seen: 'a-gone');
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    expect(_arrow(), isTrue);
    expect(find.text('99+'), findsNothing);
    expect(find.text('100'), findsNothing);

    // Seen one that is held, more than 99 back: 99+. (The chat is left first, since leaving keeps its spot.)
    await tester.pumpWidget(const SizedBox());
    ScrollMemory.keep('inbox:telegram:a', 900, seen: 'a-10');
    await pumpScreen(tester, sheet, InboxChatScreen(key: const ValueKey('again'), network: n, chatId: 'a'), AppState());
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('signing out of a network forgets where its chats were left', (tester) async {
    ScrollMemory.keep('inbox:telegram:a', 900);
    ScrollMemory.keep('inbox:signal:a', 900);
    ScrollMemory.keep('sms:4', 900);
    ScrollMemory.forgetAll('inbox:telegram:');
    expect(ScrollMemory.of('inbox:telegram:a'), isNull);
    expect(ScrollMemory.of('inbox:signal:a'), isNotNull);
    expect(ScrollMemory.of('sms:4'), isNotNull);
  });

  testWidgets('a conversation of texts keeps its place across leaving and opening it again, apart from another', (tester) async {
    final semantics = tester.ensureSemantics();
    sheet = await loadSheet(tester);
    _phone();
    final state = AppState();
    Widget thread(int id) => ThreadScreen(key: ValueKey('thread-$id-${DateTime.now().microsecondsSinceEpoch}'), thread: id, people: [Person(address: '+1555123000$id', name: 'Person $id')]);
    await _open(tester, sheet, thread(1), state);
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse);
    await _up(tester, _list(tester).viewportDimension * 1.6);
    expect(_arrow(), isTrue);
    final left = _list(tester).pixels;

    await _open(tester, sheet, thread(2), state);
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse);

    await _open(tester, sheet, thread(1), state);
    expect(_list(tester).pixels, left);
    expect(_arrow(), isTrue);

    await tester.tap(find.bySemanticsLabel(_label));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(_list(tester).pixels, 0);
    expect(_arrow(), isFalse);
    semantics.dispose();
  });

  testWidgets('a space\'s chat, its page moved from room to room, puts each room back where it was', (tester) async {
    final semantics = tester.ensureSemantics();
    sheet = await loadSheet(tester);
    _phone();
    final one = _room('Friday hang'), two = _room('Book club');
    final pick = ValueNotifier(one);
    addTearDown(pick.dispose);
    await _open(tester, sheet, ValueListenableBuilder(valueListenable: pick, builder: (_, room, _) => HangoutChat(room: room)), AppState());
    expect(_list(tester).pixels, 0);
    await _up(tester, 1000);
    expect(_arrow(), isTrue);

    pick.value = two;
    await settle(tester);
    expect(_list(tester).pixels, 0, reason: 'the other room had no place kept: its newest');
    expect(_arrow(), isFalse);

    pick.value = one;
    await settle(tester);
    expect(_list(tester).pixels, 1000);
    expect(_arrow(), isTrue);
    semantics.dispose();
  });

  // docs/performance-audit.md, finding 3: a conversation's messages are built a row at a time as they come near the
  // screen, where every message held was built at every build.
  testWidgets('a long conversation builds only the rows near the screen, and the rest as they are scrolled to', (tester) async {
    _phone(count: 120);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, ThreadScreen(key: const ValueKey('long'), thread: 3, people: const [Person(address: '+15551230003', name: 'Person 3')]), AppState());
    await settle(tester);
    int rows() => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('row-'), skipOffstage: false).evaluate().length;
    final first = rows();
    expect(first, greaterThan(3));
    expect(first, lessThan(60), reason: '120 messages held, and only those near the screen built');
    expect(find.textContaining('Text 119 in thread 3'), findsOneWidget, reason: 'the newest is at the foot');
    expect(find.textContaining('Text 0 in thread 3', skipOffstage: false), findsNothing);
    // Scrolled to the oldest: it is built then.
    _list(tester).jumpTo(_list(tester).maxScrollExtent);
    await settle(tester);
    _list(tester).jumpTo(_list(tester).maxScrollExtent);
    await settle(tester);
    expect(find.textContaining('Text 0 in thread 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The chat's list reads where its rows are from how tall they are, measured or taken to be (lib/ui/chat_rows.dart),
  // and corrects the scroll offset under what is on the screen as rows turn out taller or shorter. Nothing that
  // listens to the controller heard of a correction, and a run to somewhere wrote over it a frame later.
  group('the list corrects the offset under what is on the screen', () {
    /// A chat's list as the screens nest it, the arrow round it: messages by number (the newest is [newest], which
    /// can be given more), each a row of its own height, 28 to 320, keyed 'bare-<message>'.
    Widget chat(ScrollController c, String name, {ValueNotifier<int>? newest}) => ValueListenableBuilder<int>(
          valueListenable: newest ?? ValueNotifier(899),
          builder: (context, top, _) => JumpToLatest(
            controller: c,
            chat: name,
            child: ChatListView.builder(
              controller: c,
              reverse: true,
              chat: name,
              idOf: (i) => top - i,
              itemCount: top + 1,
              itemBuilder: (context, i) => SizedBox(key: ValueKey('bare-${top - i}'), height: 28.0 + ((top - i) * 7919 % 293)),
            ),
          ),
        );

    /// Where the rows on the screen are, by message.
    Map<int, double> tops(WidgetTester tester) => {
          for (var m = 0; m < 920; m++)
            if (find.byKey(ValueKey('bare-$m')).evaluate().isNotEmpty) m: tester.getTopLeft(find.byKey(ValueKey('bare-$m'))).dy,
        };

    testWidgets('where the chat is left is kept through them: sent far and read down over rows never measured, it opens again on the same message', (tester) async {
      sheet = await loadSheet(tester);
      final c = ScrollMemory.controllerFor(() => 'sms:rows');
      addTearDown(c.dispose);
      await pumpScreen(tester, sheet, chat(c, 'sms:rows'), AppState());
      var heard = 0;
      c.addListener(() => heard++);
      // Straight to a row far up: nothing under it has been laid out.
      RenderChatRows.under(c.position)!
        ..hold(c.position, 700)
        ..release();
      await tester.pump();
      final from = c.offset;
      heard = 0;
      for (var k = 0; k < 6; k++) {
        c.jumpTo(c.offset - 250);
        await tester.pump();
      }
      await tester.pump();
      final left = c.offset;
      expect((left - (from - 6 * 250)).abs(), greaterThan(1), reason: 'the rows that came in were not as tall as they were taken to be: the offset was corrected under them');
      expect(heard, greaterThan(6), reason: 'and those who listen were told');
      expect(ScrollMemory.of('sms:rows')?.offset, left, reason: 'what is kept is where the chat stands, not where it stood before the list corrected it');
      final was = tops(tester);
      await tester.pumpWidget(const SizedBox());
      final again = ScrollMemory.controllerFor(() => 'sms:rows');
      addTearDown(again.dispose);
      await pumpScreen(tester, sheet, chat(again, 'sms:rows'), AppState());
      expect(again.offset, left);
      final now = tops(tester);
      expect(was.keys.where((m) => was[m]! > 0 && was[m]! < 700), isNotEmpty);
      for (final m in was.keys.where((m) => was[m]! > 0 && was[m]! < 700)) {
        expect(now[m], closeTo(was[m]!, 0.01), reason: 'message $m where it was left');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a run to the newest goes on through them: nothing on the screen jolts, and it ends at the newest', (tester) async {
      sheet = await loadSheet(tester);
      final c = ScrollMemory.controllerFor(() => 'sms:run');
      addTearDown(c.dispose);
      final newest = ValueNotifier(899);
      await pumpScreen(tester, sheet, chat(c, 'sms:run', newest: newest), AppState());
      RenderChatRows.under(c.position)!
        ..hold(c.position, 700)
        ..release();
      await tester.pump();
      // Eight messages come while the person reads far back: nothing has laid them out, and each is taken to be as
      // tall as the others on the whole. Then the arrow's own way down: a screen over the newest at once, and a run
      // from there.
      newest.value = 907;
      await tester.pump();
      c.jumpTo(600);
      await tester.pump();
      unawaited(c.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic));
      var before = tops(tester), at = c.offset, corrected = 0;
      final moved = <double>[];
      for (var f = 0; f < 60 && (c.offset > 0 || f < 3); f++) {
        final set = <double>[];
        void note() => set.add(c.offset);
        c.addListener(note);
        await tester.pump(const Duration(milliseconds: 16));
        c.removeListener(note);
        final now = tops(tester);
        // How far what is on the screen moved in this frame, by a row that was there before and after.
        final shared = now.keys.where(before.containsKey);
        if (shared.isNotEmpty) moved.add(now[shared.first]! - before[shared.first]!);
        // Corrected in this frame's layout: the offset is not where the run set it.
        if (set.isNotEmpty && (c.offset - set.first).abs() > 0.5) corrected++;
        before = now;
        at = c.offset;
      }
      // ignore: avoid_print
      if (const bool.fromEnvironment('RUN_SAYS')) print('RUN moved $moved');
      expect(corrected, greaterThan(0), reason: 'rows came in that were not as tall as they were taken to be');
      expect(at, 0, reason: 'at the newest');
      expect(tester.getRect(find.byKey(const ValueKey('bare-907'))).bottom, closeTo(tester.getRect(find.bySubtype<ListView>()).bottom, 0.01));
      // Toward the newest the page goes up the screen, each frame a little less than the last as the run eases out:
      // never back down, and never a jolt of the size of a correction.
      // (Its first frame is its start: nothing moves in that one.)
      final run = moved.skipWhile((m) => m == 0).toList();
      expect(run.length, greaterThan(8));
      for (var k = 0; k < run.length; k++) {
        expect(run[k], lessThan(0.5), reason: 'frame $k went back: $run');
        if (k == 0) continue;
        // (A correction written over by the run's next frame is a step half as long again as the one before it. One
        // carried through is a step a little longer at most: there is that much further to go in the time left.)
        expect(run[k].abs(), lessThan(run[k - 1].abs() * 1.15 + 3), reason: 'frame $k jolted: $run');
        expect(run[k].abs(), greaterThan(run[k - 1].abs() * 0.4 - 6), reason: 'frame $k stood still: $run');
      }
      expect(tester.takeException(), isNull);
    });
  });

  // The arrow stood at the list's right edge, over the map's lowest lines, and took the presses meant for them.
  testWidgets('the arrow stands clear of the chat\'s map', (tester) async {
    sheet = await loadSheet(tester);
    _phone();
    final n = _Network(['a']);
    await _open(tester, sheet, InboxChatScreen(network: n, chatId: 'a'), AppState());
    await _up(tester, _list(tester).viewportDimension * 1.5);
    expect(_arrow(), isTrue);
    final map = tester.getRect(find.byKey(const ValueKey('chat-rail')));
    final arrow = tester.getRect(find.byKey(const ValueKey('jump-to-latest')));
    expect(arrow.right, lessThanOrEqualTo(map.left + 0.01), reason: 'left of the map\'s gutter');
    expect(arrow.overlaps(map), isFalse);
  });
}

/// Matt, 2026-11-18: "when typing in a space the chat and chatbar don't slide up above the keyboard".
void keyboardTests() {
  testWidgets('with the keyboard up, a space\'s composer and newest message are above it', (tester) async {
    final sheet = await loadSheet(tester);
    final room = _room('Lounge');
    await _open(tester, sheet, Builder(builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)), child: HangoutChat(room: room))), AppState());
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final field = tester.getRect(find.byType(EditableText));
    expect(field.bottom, lessThanOrEqualTo(screen - 300), reason: 'the field is over the keyboard');
    final newest = tester.getRect(find.textContaining('Line 59 in Lounge'));
    expect(newest.bottom, lessThanOrEqualTo(field.top), reason: 'the newest message is above the composer, in view');
  });
}

/// A space with 60 messages in its chat, this device in it.
HangoutRoom _room(String name) {
  final keys = NetKeys.generate();
  final channel = VoiceChannel.make(name, owner: NetCrypto.hex(keys.public));
  final store = MemoryHangoutStore();
  final at = DateTime(2026, 11, 16, 19).millisecondsSinceEpoch;
  store.keepMessages(channel.chatRoom, [
    for (var i = 0; i < 60; i++) HangoutMessage(id: '$i', from: i.isOdd ? keys.id : 'a', name: i.isOdd ? 'Me' : 'Maya', text: 'Line $i in $name, long enough to take a line or two of the bubble', at: at + i * 60000),
  ]);
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
}

class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
  @override
  final String me;
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}
