import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/flat_line.dart';

import 'support/list_harness.dart';

/// The name over a channel's line wears its sender's name effect (Matt, 2026-11-25: "the "you" should say my username
/// and show my selected text effect").
void main() {
  Widget line(String effect) => FlatLine(
        name: 'matt',
        at: DateTime(2026, 11, 25, 14, 30),
        first: true,
        face: (size) => SizedBox.square(dimension: size),
        nameEffect: effect,
        body: (context, maxWidth) => const Text('And we need you to QA'),
      );

  testWidgets('a name effect is drawn in the name\'s letters; none leaves the name plain', (tester) async {
    final sheet = await loadSheet(tester);
    final state = AppState();
    await pumpScreen(tester, sheet, line('spectral-glow'), state);
    expect(find.text('matt'), findsOneWidget);
    expect(find.byKey(const ValueKey('name-spectral-glow')), findsOneWidget);

    await pumpScreen(tester, sheet, line(''), state);
    expect(find.text('matt'), findsOneWidget);
    expect(find.byKey(const ValueKey('name-spectral-glow')), findsNothing);
  });
}
