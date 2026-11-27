import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/bubble.dart';
import 'package:ghost_messaging/sms.dart' show SmsStatus;
import 'package:ghost_messaging/ui/settings_panes.dart' show bubbleSettingHint, bubbleSettingWords, bubblesKey;

import 'support/list_harness.dart';

// Conversation bubbles (lib/bubble.dart, android Bubbles.kt; GMFB-8, from @kevin: "It would be nice to have message
// bubbles that just sit on the side of the screen like google messages and facebook messenger"): the bubble's own
// engine opens on one conversation, with no way back to a list that is not there and a way into the whole app.

/// The phone, answering what a conversation's page asks; every call kept in [asked] with its arguments.
List<MethodCall> _phone() {
  final asked = <MethodCall>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    asked.add(call);
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'status':
        return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      case 'people':
        return [
          {'address': '+15551230004', 'name': 'Kevin', 'photo': null},
        ];
      case 'messages':
        final thread = (args['thread'] as num).toInt();
        return [
          {'id': thread * 1000, 'kind': 'sms', 'address': '+15551230004', 'body': 'Bubbles would be nice', 'date': DateTime(2026, 11, 21, 9).millisecondsSinceEpoch, 'outgoing': false, 'state': 'received', 'read': false},
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
  return asked;
}

void main() {
  test('the bubble opens on the thread it was given, and on none where it was given none', () {
    expect(bubbleThread(['42']), 42);
    expect(bubbleThread([' 7 ']), 7);
    expect(bubbleThread(['-5']), -5, reason: 'a conversation bridged from Google Messages');
    expect(bubbleThread(['-1']), isNull, reason: '-1 is the list, never a conversation');
    expect(bubbleThread([]), isNull);
    expect(bubbleThread(['thread']), isNull);
  });

  test('Android\'s bubble setting comes with the status, and is said in words', () {
    expect(SmsStatus.from(const {'bubbles': 'selected'}).bubbles, 'selected');
    expect(SmsStatus.from(const {'bubbles': null}).bubbles, isNull, reason: 'before Android 11');
    expect(SmsStatus.from(const {}).bubbles, isNull, reason: 'an older phone, or a computer');
    expect(bubbleSettingWords('all'), 'All conversations');
    expect(bubbleSettingWords('selected'), 'Chosen conversations');
    expect(bubbleSettingWords('none'), 'Off');
    expect(bubbleSettingHint('none', on: true), contains('turn them on'));
    expect(bubbleSettingHint('all', on: false), contains('off above'));
  });

  test('the switch is on until it is switched off', () {
    final state = AppState();
    expect(state.flag(bubblesKey), isTrue);
  });

  testWidgets('a bubble is the one conversation, with no way back and a way into the app', (tester) async {
    final semantics = tester.ensureSemantics();
    final sheet = await loadSheet(tester);
    final asked = _phone();
    await pumpScreen(tester, sheet, const BubbleConversation(thread: 4), AppState());
    await settle(tester);

    expect(find.text('Kevin'), findsWidgets, reason: 'its people read by the page itself');
    expect(find.text('Bubbles would be nice'), findsOneWidget);
    expect(find.bySemanticsLabel('Back'), findsNothing, reason: 'there is no list behind a bubble');
    expect(asked.where((c) => c.method == 'setOpenThread').map((c) => (c.arguments as Map)['thread']), contains(4));

    await tester.tap(find.bySemanticsLabel('Open in Uplink'));
    await tester.pump();
    final open = asked.where((c) => c.method == 'openInApp').toList();
    expect(open, hasLength(1));
    expect((open.single.arguments as Map)['thread'], 4);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    semantics.dispose();
  });

  testWidgets('a bubble with no conversation says so', (tester) async {
    final sheet = await loadSheet(tester);
    _phone();
    await pumpScreen(tester, sheet, const BubbleConversation(thread: null), AppState());
    expect(find.text('This conversation couldn\'t be opened.'), findsOneWidget);
  });
}
