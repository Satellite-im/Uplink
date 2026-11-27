import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/ui/thread.dart';

import 'support/list_harness.dart';

/// A friend by username has no number, so what the routes couldn't take is never handed to the phone's texting (found
/// in review, 2026-11-23). It was: with no connection, words to "@maya" went to the phone's `send`, which writes them
/// unsealed into Android's own store of texts (or opens Google Messages beside it) for an address no carrier can
/// deliver; a picture to a friend by username always went that way.
void main() {
  late List<MethodCall> sent;

  setUp(() {
    sent = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'status':
          return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
        case 'messages':
          return const [];
        case 'e2e':
          return {'address': (call.arguments as Map)['address'], 'state': 'none', 'verified': false, 'changed': false};
        case 'prefs':
          return <String, String>{};
        case 'ghostPeers':
        case 'netSmsAvailable':
          return false;
        case 'send' || 'sendSticker':
          sent.add(call);
          return 1;
        default:
          return null;
      }
    });
  });

  Future<void> write(WidgetTester tester, String words) async {
    await tester.showKeyboard(find.byType(EditableText));
    tester.testTextInput.updateEditingValue(TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length)));
    await tester.pump();
  }

  String field(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).controller.text;

  testWidgets('words to a friend by username with no connection are not texted: they are put back, with why', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: 41, people: [Person(address: '@maya', name: 'Maya')]), AppState());
    await write(tester, 'Dinner at 8?');
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await settle(tester);
    expect(sent, isEmpty, reason: 'an "@name" was handed to the phone\'s texting: ${sent.map((c) => c.arguments)}');
    expect(field(tester), 'Dinner at 8?', reason: 'nothing went, so what was written is put back');
    expect(find.textContaining('through the relay'), findsOneWidget);
  });

  testWidgets('a number is still texted as before', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ThreadScreen(thread: 42, people: [Person(address: '+15551230042', name: 'Dad')]), AppState());
    await write(tester, 'On my way');
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await settle(tester);
    expect(sent.map((c) => (c.arguments as Map)['addresses']), [
      ['+15551230042'],
    ]);
  });
}
