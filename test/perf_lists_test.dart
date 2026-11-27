import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/scams.dart';
import 'package:ghost_messaging/kit/fold.dart';

/// docs/performance-audit.md, finding 2: what the list of conversations asks of a network at every build is worked
/// out once for each change, not at every asking.
class _Counting extends InboxNetwork {
  int made = 0;
  final List<InboxChat> held = [
    InboxChat(network: 'fake', id: 'a', title: 'Ada', date: DateTime(2026, 11, 20, 10)),
    InboxChat(network: 'fake', id: 'b', title: 'Bo', date: DateTime(2026, 11, 20, 9)),
  ];

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => 'me';
  @override
  List<InboxChat> get chats {
    made++;
    return [...held];
  }

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
  void tell() => notifyListeners();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null));

  test('the chats shown are made once for each change, and again when a list of Uplink\'s own changes', () async {
    final n = _Counting()..listStore = AppState();
    for (var i = 0; i < 6; i++) {
      expect(n.shownChats.map((c) => c.id), ['a', 'b']);
      expect(n.archivedChats, isEmpty);
    }
    expect(n.made, 1, reason: 'six askings, one making');
    n.tell();
    n.shownChats;
    n.shownChats;
    expect(n.made, 2, reason: 'told of a change: made again, once');
    await n.archive('a', true);
    expect(n.shownChats.map((c) => c.id), ['b']);
    expect(n.archivedChats.map((c) => c.id), ['a']);
    await n.archive('a', false);
    expect(n.shownChats.map((c) => c.id), ['a', 'b']);
    expect(n.archivedChats, isEmpty);
  });

  test('one of Uplink\'s lists is read from its kept form once, and is not the caller\'s to change', () {
    final n = _Counting()..listStore = AppState();
    n.setLocal('notspam', 'a', true);
    final first = n.localList('notspam');
    expect(identical(first, n.localList('notspam')), isTrue);
    expect(() => first.add('x'), throwsUnsupportedError);
    n.setLocal('notspam', 'b', true);
    expect(n.localList('notspam'), {'a', 'b'});
    n.setLocal('notspam', 'a', false);
    expect(n.localList('notspam'), {'b'});
  });

  test('a chat\'s scam signs follow the chat as it changes', () {
    InboxChat chat(String snippet) => InboxChat(network: 'telegram', id: '9', title: 'Stranger', date: DateTime(2026), snippet: snippet, stranger: true, cold: true);
    final clean = scamOf(chat('see you at seven'));
    expect(clean, isNull);
    expect(scamOf(chat('see you at seven')), isNull);
    // The same chat with other words is looked at again, not answered from what was remembered.
    final bad = scamOf(chat('I can help you invest in crypto with guaranteed profit, send USDT to my wallet'));
    expect(bad, isNotNull);
    expect(scamOf(chat('see you at seven')), isNull);
  });

  test('fold straightens quotes as before', () {
    expect(fold('It’s “Fine”'), 'it\'s "fine"');
  });
}
