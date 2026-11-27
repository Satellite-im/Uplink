import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';

import 'support/space_call_harness.dart';

/// In a short window with cameras on, the call's people and its Leave button can be reached: a name under the call's
/// buttons is scrolled into view and then takes the press itself (not a button drawn over it). The coordinator,
/// 2026-11-23: the web e2e's tap on Maya's row landed on Mute after the tiles went 4:3; the row was below the list's
/// fold (reachable by scrolling), and the e2e pressed where it lay without scrolling to it.
void main() {
  bool reachable(WidgetTester tester, Element e) {
    final box = e.renderObject! as RenderBox;
    final c = box.localToGlobal(box.size.center(Offset.zero));
    final hits = tester.hitTestOnBinding(c);
    return hits.path.any((h) => identical(h.target, box));
  }

  {
    testWidgets('in short windows with cameras on, everyone and Leave can be reached', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      final bad = <String>[];
      // A computer's usual short windows, and the web e2e's (tool/web/e2e.mjs).
      for (final size in const [Size(1280, 720), Size(1024, 640), Size(1180, 780)]) {
        for (final others in [1, 3, 8]) {
          await h.shoot(tester, TelegramCall(call: h.call(people: others, video: const {'a', 'c'}, myVideo: true)), 'probe', size: size, dir: '../build/call-short');
          final where = '${size.width.round()}x${size.height.round()} with ${others + 1}';
          for (final name in ['Maya Chen', 'Sam Ortiz', 'Riley', 'Hana Sato'].take(others)) {
            final f = find.textContaining(name);
            final n = f.evaluate().length;
            if (n == 0) continue;
            var any = false;
            for (var i = 0; i < n; i++) {
              final all = find.textContaining(name).evaluate().toList();
              if (i >= all.length) break;
              final e = all[i];
              final r0 = tester.getRect(find.byElementPredicate((x) => identical(x, e)));
              if (r0.left >= size.width) continue; // a panel slid away off the side
              try {
                await tester.ensureVisible(find.byElementPredicate((x) => identical(x, e)));
                await tester.pump(const Duration(milliseconds: 300));
              } catch (_) {}
              final ok = e.mounted && reachable(tester, e);
              any = any || ok;
              if (!ok) bad.add('$where: "$name" #$i unreachable at ${e.mounted ? tester.getRect(find.byElementPredicate((x) => identical(x, e))) : 'gone'}');
            }
            if (!any) bad.add('$where: NO reachable "$name"');
          }
          final leave = find.bySemanticsLabel(RegExp(r'^Leave')).evaluate().toList();
          if (leave.isEmpty) bad.add('$where: no Leave button');
          for (final e in leave) {
            if (!reachable(tester, e)) bad.add('$where: Leave unreachable');
          }
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    });
  }
}
