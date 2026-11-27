import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/ui/blocking.dart';
import 'package:ghost_messaging/ui/person_reach.dart';

/// A new chat with someone from the menu on their name (Matt, 2026-11-18: "add a way to start a new chat with a contact
/// from the contact menu right now it just says "block contact""): the other ways they can be reached.
class _Net extends InboxNetwork {
  _Net(this.id, this.name, this.people);
  @override
  final String id;
  @override
  final String name;
  final List<InboxContact> people;
  @override
  List<InboxContact> get contacts => people;
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => const [];
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Net telegram, signal;
  setUp(() {
    telegram = _Net('telegram', 'Telegram', const [InboxContact(network: 'telegram', id: '77', name: 'Kevin Moss', number: '+1 555 000 1234')]);
    signal = _Net('signal', 'Signal', const [InboxContact(network: 'signal', id: 'aci-k', name: 'Kevin Moss')]);
    Inbox.instance = Inbox.of([telegram, signal]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => const []);
  });
  tearDown(() => Inbox.instance = null);

  test('from a conversation of texts: their Telegram and Signal', () async {
    final r = await otherReaches(const BlockTarget.number('5550001234', 'Kevin Moss'));
    expect([for (final x in r) x.kind]..sort(), ['signal', 'telegram']);
  });

  test('from a Telegram chat: their number and their Signal, not Telegram again', () async {
    final r = await otherReaches(BlockTarget.network(telegram, '77', 'Kevin Moss'));
    expect([for (final x in r) x.kind]..sort(), ['phone', 'signal']);
    expect(r.firstWhere((x) => x.kind == 'phone').address, '+1 555 000 1234');
  });

  test('someone reachable no other way: nothing but Block', () async {
    expect(await otherReaches(const BlockTarget.number('5559998888', 'Nobody')), isEmpty);
  });
}
