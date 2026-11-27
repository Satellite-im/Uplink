import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/ui/conversations.dart' show QuickRow;

import 'support/space_call_harness.dart';

/// Mark all read's count is a small circle, not a pill as tall as the row (Matt, 2026-11-20: "make the mark all read
/// pill a small circle it's tall and ugly right now").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  testWidgets('a count of 2 is a 20-point circle; 12 a short pill as tall', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(
      tester,
      ColoredBox(
        color: const Color(0xFF000000),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 80),
          QuickRow(key: const ValueKey('two'), icon: Lucide.checkCheck, label: 'Mark all read', count: 2, onPress: () {}),
          QuickRow(key: const ValueKey('twelve'), icon: Lucide.checkCheck, label: 'Mark all read', count: 12, onPress: () {}),
        ]),
      ),
      'quick-row-count',
      dark: true,
    );
    final two = tester.getSize(find.descendant(of: find.byKey(const ValueKey('two')), matching: find.byKey(const ValueKey('quick-row-count'))));
    expect(two, const Size(20, 20));
    final twelve = tester.getSize(find.descendant(of: find.byKey(const ValueKey('twelve')), matching: find.byKey(const ValueKey('quick-row-count'))));
    expect(twelve.height, 20);
    expect(twelve.width, greaterThanOrEqualTo(20));
  });
}
