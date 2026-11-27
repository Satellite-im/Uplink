import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/cleaner.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

import 'support/list_harness.dart';

/// The Cleaner (lib/plugins/cleaner.dart). Matt, 2026-11-14: "add a "Cleaner" plugin that allows us to bulk delete
/// messages by category and shows deletion progress in real time".
void main() {
  const groups = [
    ListGroup(id: 'spam', label: 'Spam', icon: Lucide.triangleAlert, threads: [1, 2, 3]),
    ListGroup(id: 'sales', label: 'Sales & solicitors', icon: Lucide.megaphone, threads: [4, 5]),
    ListGroup(id: ListGroup.othersId, label: 'Personal & other', icon: Lucide.messageSquare, threads: [6, 7, 8]),
  ];

  test('it ships, on, in place of Your day', () {
    expect(shippedPlugins.whereType<CleanerPlugin>(), hasLength(1));
    expect(shippedPlugins.map((p) => p.id), isNot(contains('day')));
    expect(const CleanerPlugin().onByDefault, isTrue);
  });

  testWidgets('tick kinds, say yes, and watch it go one at a time; Stop leaves the rest', (tester) async {
    final deleted = <int>[];
    final gate = <int, Completer<void>>{};
    var reloads = 0;
    Future<void> delete(int t) {
      final c = gate[t] = Completer<void>();
      return c.future.then((_) => deleted.add(t));
    }

    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, CleanerSheet(groups: groups, delete: delete, reload: () async => reloads++), AppState());
    await settle(tester);
    // Each group with its count; nothing ticked, so nothing to delete.
    expect(find.text('Spam'), findsOneWidget);
    expect(find.text('Personal & other'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Spam'));
    await tester.tap(find.text('Sales & solicitors'));
    await settle(tester);
    expect(find.text('Delete 5 conversations'), findsOneWidget);
    // A second press says it can't be undone.
    await tester.tap(find.text('Delete 5 conversations'));
    await settle(tester);
    expect(find.text('Delete 5 conversations?'), findsOneWidget);
    expect(find.textContaining('can\'t be undone'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    // In real time: the count and the bar move as each goes.
    expect(find.text('Deleting 1 of 5'), findsOneWidget);
    gate[1]!.complete();
    await settle(tester);
    expect(find.text('Deleting 2 of 5'), findsOneWidget);
    expect(find.text('1 deleted'), findsOneWidget);
    gate[2]!.complete();
    await settle(tester);
    expect(find.text('2 deleted'), findsOneWidget);
    // Stop: the one under way finishes, the rest stay.
    await tester.tap(find.text('Stop'));
    await settle(tester);
    gate[3]!.complete();
    await settle(tester);
    expect(deleted, [1, 2, 3]);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.textContaining('2 left as they were'), findsOneWidget);
    expect(reloads, greaterThan(0), reason: 'the list is read again');
  });

  testWidgets('to the end: Done says how many', (tester) async {
    final deleted = <int>[];
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, CleanerSheet(groups: groups, delete: (t) async => deleted.add(t), reload: () async {}), AppState());
    await settle(tester);
    await tester.tap(find.text('Personal & other'));
    await settle(tester);
    await tester.tap(find.text('Delete 3 conversations'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(deleted, [6, 7, 8]);
    expect(find.text('Done'), findsNWidgets(2), reason: 'the title and its button');
    expect(find.text('3 conversations deleted.'), findsOneWidget);
  });
}
