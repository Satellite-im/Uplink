import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/ui/blocking.dart';
import 'package:ghost_messaging/ui/common.dart' show PaneRoot;

import 'support/space_call_harness.dart';

/// The one Blocked list, numbers and Telegram and Signal people together (lib/ui/blocking.dart): drawn to
/// test/shots/blocked-* with --update-goldens.
void main() {
  testWidgets('the Blocked list', (tester) async {
    final h = await SpaceHarness.load(tester);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'blockedNumbers'
        ? [
            {'address': '+15550100123', 'name': 'Unknown caller'},
            {'address': '+15550100456'},
          ]
        : null);
    final store = AppState();
    for (final n in Inbox.instance.networks) {
      n.listStore = store;
    }
    Inbox.instance.named('telegram')?.keepBlocked('7', name: 'Jo Park');
    Inbox.instance.named('signal')?.keepBlocked('aci-sam', name: 'Sam Rivera');
    for (final dark in [false, true]) {
      await h.shoot(tester, const BlockedScreen(), 'blocked', dark: dark);
    }
    expect(find.text('Jo Park'), findsOneWidget);
    expect(find.text('Sam Rivera'), findsOneWidget);
  });

  // Matt, 2026-11-17: "include a back arrow when clicking blocked to go back to the main contacts page". Opened from
  // Contacts it takes Contacts' place in the pane, where a page has no back arrow of its own: given where back goes,
  // it has one, beside the list too.
  testWidgets('Blocked opened in Contacts\' place has a back arrow to Contacts', (tester) async {
    final h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    var back = 0;
    for (final dark in [false, true]) {
      await h.shoot(tester, PaneRoot(isBeside: true, child: BlockedScreen(onBack: () => back++)), 'blocked-back', dark: dark);
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pump();
    }
    expect(back, 2);
  });
}
