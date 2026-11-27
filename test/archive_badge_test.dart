import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/shell.dart';

import 'support/list_harness.dart';

/// GMFB-14 (@kevin, Windows 0.11.4: "I have notifications showing on my archive but I have read all of the messages in
/// the archive to try to clear it and nothing happens"): the number on the Archive ring was how many conversations
/// are archived, so reading them never moved it. It is how many of them are unread now.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  testWidgets('the Archive ring counts unread archived conversations, and clears once they are read', (tester) async {
    final phone = ListPhone([
      ListPhone.conversation(1, '+15550001', 'hey', name: 'Maya'),
      ListPhone.conversation(2, '+15550002', 'old news', name: 'Sam', archived: true),
      ListPhone.conversation(3, '+15550003', 'did you see?', name: 'Riley', archived: true, unread: true),
      ListPhone.conversation(4, '+15550004', 'later', name: 'Jo', archived: true),
    ])..install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.dock.name));
    await settle(tester);
    final ring = find.byKey(const ValueKey('nav-archive'));
    expect(ring, findsOneWidget);
    expect(find.descendant(of: ring, matching: find.text('1')), findsOneWidget, reason: 'one archived conversation is unread, not three archived');
    expect(find.descendant(of: ring, matching: find.text('3')), findsNothing);

    // Riley's is read (from the archive, or on another device): the ring has nothing to say.
    phone.conversations.firstWhere((c) => c['id'] == 3)['unread'] = false;
    final shell = tester.state<AppShellState>(find.byType(AppShell));
    await shell.countArchivedUnread();
    await settle(tester);
    expect(find.descendant(of: ring, matching: find.text('1')), findsNothing, reason: 'read, so nothing on the ring');
    expect(shell.archived.value, 3, reason: 'the menu still says how many are archived');
    expect(tester.takeException(), isNull);
  });
}
