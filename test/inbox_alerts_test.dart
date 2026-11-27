import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/alerts.dart';
import 'package:ghost_messaging/inbox/inbox.dart';

/// A network whose chats a test changes, as new messages would.
class _Net extends InboxNetwork {
  _Net(this.id, this.name);
  @override
  final String id;
  @override
  final String name;
  var chatList = <InboxChat>[];
  var signedIn = true;

  void set(List<InboxChat> chats) {
    chatList = chats;
    notifyListeners();
  }

  @override
  InboxState get state => signedIn ? InboxState.ready : InboxState.signedOut;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => chatList;
  @override
  List<InboxMessage> messagesOf(String chatId) => const [];
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

/// Uplink's notifications for Signal and Telegram (lib/inbox/alerts.dart; Matt, 2026-11-16: "Yes, build them").
void main() {
  final began = DateTime(2026, 11, 16, 12);
  InboxChat chat(String id, {int unread = 1, int minutes = 5, bool mine = false, bool muted = false, bool group = false, String text = 'are you around later?', bool stranger = false}) =>
      InboxChat(network: 'signal', id: id, title: 'Sam $id', date: began.add(Duration(minutes: minutes)), snippet: text, unread: unread, lastFromMe: mine, muted: muted, group: group, stranger: stranger);

  late _Net signal;
  late List<InboxAlert> told;
  late List<String> cancelled;
  late List<List<String>> kept;
  var front = false;

  InboxAlerts watch(List<InboxChat> first) {
    signal = _Net('signal', 'Signal')..chatList = first;
    told = [];
    cancelled = [];
    kept = [];
    front = false;
    return InboxAlerts(notify: told.add, cancel: cancelled.add, keepAlive: kept.add, inFront: () => front, now: () => began)..watch(Inbox.of([signal]));
  }

  tearDown(() => InboxAlerts.showing = null);

  test('a new message from someone is told, with the chat\'s name, the network and the words', () {
    watch([chat('1', unread: 0)]);
    signal.set([chat('1', unread: 1)]);
    expect(told.single.key, 'signal:1');
    expect(told.single.title, 'Sam 1');
    expect(told.single.network, 'Signal');
    expect(told.single.body, 'are you around later?');
    // Another in the same chat is told again; reading it takes the notification away.
    signal.set([chat('1', unread: 2, text: 'ok call me')]);
    expect(told.map((a) => a.body), ['are you around later?', 'ok call me']);
    signal.set([chat('1', unread: 0)]);
    expect(cancelled, ['signal:1']);
  });

  test('what was unread before Uplink watched is not news, nor a chat loaded later with old messages', () {
    watch([chat('1', unread: 4)]);
    expect(told, isEmpty, reason: 'unread on the first look');
    signal.set([chat('1', unread: 4), chat('2', unread: 3, minutes: -60)]);
    expect(told, isEmpty, reason: 'a chat loaded later whose newest message is older than the watching');
    signal.set([chat('1', unread: 4), chat('2', unread: 3, minutes: -60), chat('3', unread: 1)]);
    expect(told.single.key, 'signal:3', reason: 'a chat new since, with a new message');
  });

  test('not your own, not muted, not spam, not the chat on the screen while Uplink is in front', () {
    watch([chat('1', unread: 0), chat('2', unread: 0), chat('3', unread: 0), chat('4', unread: 0)]);
    InboxAlerts.showing = 'signal:4';
    front = true;
    signal.set([
      chat('1', unread: 1, mine: true),
      chat('2', unread: 1, muted: true),
      chat('3', unread: 1, stranger: true, text: 'Hiya! ✨ What a pleasant 😍 surprise!'),
      chat('4', unread: 1),
    ]);
    expect(told, isEmpty);
    // The same chat with Uplink out of sight is told.
    front = false;
    signal.set([chat('1', unread: 1, mine: true), chat('2', unread: 1, muted: true), chat('3', unread: 1, stranger: true, text: 'Hiya! ✨ What a pleasant 😍 surprise!'), chat('4', unread: 2)]);
    expect(told.single.key, 'signal:4');
  });

  test('the phone is kept connected while a network is signed in, and let go when none is', () {
    watch([]);
    expect(kept, [
      ['Signal'],
    ]);
    signal.signedIn = false;
    signal.set([]);
    expect(kept.last, isEmpty);
    // Signed in again: nothing unread before then is told.
    signal.signedIn = true;
    signal.set([chat('1', unread: 2, minutes: -5)]);
    expect(kept.last, ['Signal']);
    expect(told, isEmpty);
  });
}
