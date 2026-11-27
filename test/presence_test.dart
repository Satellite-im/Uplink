import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/telegram.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/common.dart';

import 'support/list_harness.dart';

/// Who is on Telegram now (Matt, 2026-11-17: "activity presence sensing for friends and conacts on telegram and signal
/// to be able to tell if a friend is online on a given plaform anywhere the users avatar is shown").
class _Net extends InboxNetwork {
  final online = <String>{};
  final numbers = <String, String>{};
  @override
  String get id => 'telegram';
  @override
  String get name => 'Telegram';
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
  @override
  InboxPresence? presenceOf(String id) => InboxPresence(network: 'Telegram', online: online.contains(id), lastSeen: online.contains(id) ? null : DateTime(2026, 11, 17, 9));
  @override
  InboxPresence? presenceOfNumber(String digits) => numbers[digits] == null ? null : presenceOf(numbers[digits]!);
}

void main() {
  final now = DateTime(2026, 11, 17, 12);
  int at(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

  test('Telegram\'s statuses: online until it lapses, last seen when, or only roughly', () {
    expect(telegramPresence({'@type': 'userStatusOnline', 'expires': at(now.add(const Duration(minutes: 1)))}, now: now)!.online, isTrue);
    final lapsed = telegramPresence({'@type': 'userStatusOnline', 'expires': at(now.subtract(const Duration(minutes: 3)))}, now: now)!;
    expect(lapsed.online, isFalse);
    expect(lapsed.words(now: now), 'last seen 3 min ago');
    expect(telegramPresence({'@type': 'userStatusOffline', 'was_online': at(now.subtract(const Duration(hours: 5)))})!.words(now: now), 'last seen 5 h ago');
    expect(telegramPresence({'@type': 'userStatusRecently'})!.words(), 'last seen recently');
    expect(telegramPresence({'@type': 'userStatusLastWeek'})!.words(), 'last seen within a week');
    expect(telegramPresence({'@type': 'userStatusEmpty'}), isNull);
    expect(const InboxPresence(network: 'Telegram', online: true).words(), 'online');
  });

  test('found by a network\'s own id, or by a phone number on any network signed in', () {
    final net = _Net()
      ..online.add('42')
      ..numbers['15551230001'] = '42';
    final inbox = Inbox.of([net]);
    expect(inbox.presenceOfAddress('telegram:42')!.online, isTrue);
    expect(inbox.presenceOfAddress('telegram:7')!.online, isFalse);
    expect(inbox.presenceOfAddress('+1 (555) 123-0001')!.online, isTrue, reason: 'a text\'s person, on Telegram by their number');
    expect(inbox.presenceOfAddress('+15559990000'), isNull);
    expect(inbox.presenceOfAddress('signal:abc'), isNull, reason: 'a network not here');
  });

  testWidgets('a face shows a dot while its person is online, and loses it when they go', (tester) async {
    final net = _Net();
    Inbox.instance = Inbox.of([net]);
    addTearDown(() => Inbox.instance = null);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Center(child: Avatar(people: [Person(address: 'telegram:42', name: 'Jo Park')])), AppState());
    expect(find.bySemanticsLabel('Online on Telegram'), findsNothing);
    net.online.add('42');
    net.presenceChanges.changed();
    await tester.pump();
    expect(find.bySemanticsLabel('Online on Telegram'), findsOneWidget);
    net.online.remove('42');
    net.presenceChanges.changed();
    await tester.pump();
    expect(find.bySemanticsLabel('Online on Telegram'), findsNothing);
    // A group's face has none.
    await pumpScreen(tester, sheet, const Center(child: Avatar(people: [Person(address: 'telegram:42'), Person(address: 'telegram:43')])), AppState());
    net.online.add('42');
    net.presenceChanges.changed();
    await tester.pump();
    expect(find.bySemanticsLabel('Online on Telegram'), findsNothing);
  });
}
