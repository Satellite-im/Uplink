import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/thread.dart';

import 'support/list_harness.dart';

/// A text to someone nobody has texted yet, beside Google Messages (Matt, 2026-11-26: "I can't open a new text message
/// conversation"; the phone said "Unable to find or allocate a thread ID"). Android lets only the default SMS app make
/// a conversation, so the phone opens a stand-in (below zero, empty: android Store.threadFor), and the page gives its
/// place to the real conversation the first text made.

/// The phone: [sent] what it was asked to send; its answer is the conversation [madeThread].
List<String> _phone({required int madeThread, List<Map<String, Object?>> Function(int thread)? messages}) {
  final sent = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    final a = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'status':
        return const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true};
      case 'messages':
        return messages?.call((a['thread'] as num).toInt()) ?? const [];
      case 'send':
        sent.add('${a['body']}');
        return madeThread;
      case 'e2e':
        return {'address': a['address'], 'state': 'none', 'verified': false, 'changed': false};
      case 'prefs':
        return <String, String>{};
      case 'ghostPeers':
      case 'netSmsAvailable':
        return false;
      default:
        return null;
    }
  });
  return sent;
}

Future<void> _send(WidgetTester tester, String words) async {
  await tester.showKeyboard(find.byType(EditableText));
  tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('composer-send')));
  await settle(tester);
}

void main() {
  const maya = Person(address: '+15551230042', name: 'Maya Chen');

  testWidgets('the first text from a stand-in conversation moves the page to the conversation it made', (tester) async {
    final sent = _phone(madeThread: 412);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: -991, people: [maya]), AppState());
    expect(find.byType(ThreadScreen), findsOneWidget, reason: 'it opens, empty, instead of failing');
    await _send(tester, 'yo');
    expect(sent, ['yo']);
    expect(tester.widget<ThreadScreen>(find.byType(ThreadScreen)).thread, 412);
  });

  testWidgets('a conversation that is already real, or a bridged one with messages in it, stays where it is', (tester) async {
    _phone(madeThread: 412, messages: (t) => [
          {'id': 1, 'kind': 'sms', 'address': maya.address, 'body': 'earlier', 'date': 1, 'outgoing': false, 'state': 'received', 'read': true, 'thread': t},
        ]);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: -55, people: [maya]), AppState());
    await _send(tester, 'again');
    expect(tester.widget<ThreadScreen>(find.byType(ThreadScreen)).thread, -55);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: 9, people: [maya]), AppState());
    await _send(tester, 'hello');
    expect(tester.widget<ThreadScreen>(find.byType(ThreadScreen)).thread, 9);
  });
}
