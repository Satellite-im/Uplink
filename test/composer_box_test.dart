import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:ghost_messaging/ui/composer_box.dart';

import 'support/list_harness.dart';

class _Box extends StatelessWidget {
  const _Box({required this.typing});
  final bool typing;

  @override
  Widget build(BuildContext context) {
    final send = IconTap(icon: Lucide.arrowUp, label: 'Send', filled: true, size: 16, box: 36, onPressed: typing ? () {} : null);
    final mic = IconTap(icon: Lucide.mic, label: 'Mic', size: 19, box: 36, onPressed: () {});
    return Align(
      alignment: Alignment.bottomCenter,
      child: ComposerBox(
        typing: typing,
        plus: IconTap(icon: Lucide.plus, label: 'Plus', size: 19, box: 36, onPressed: () {}),
        ends: [typing ? send : mic],
        below: [mic, send],
        field: SizedBox(height: 36, child: Text(typing ? 'On my way' : '')),
      ),
    );
  }
}

/// The composer's buttons go straight down into the row under the words as typing starts, and straight back up
/// (Matt, 2026-11-15: "The animation on the compose is a bit weird thr buttons don't slide straight down they move out
/// first").
void main() {
  testWidgets('as typing starts the + only goes down: its left edge stays where it was every frame', (tester) async {
    final sheet = await loadSheet(tester);
    Future<void> show(bool typing) => pumpScreen(tester, sheet, _Box(typing: typing), AppState());
    await show(false);
    await tester.pump(const Duration(milliseconds: 400));
    final plus = find.byWidgetPredicate((w) => w is IconTap && w.label == 'Plus');
    final start = tester.getTopLeft(plus);
    final boxTop = tester.getTopLeft(find.byType(ComposerBox)).dy;
    await show(true);
    final path = <Offset>[];
    final sends = <Offset>[];
    final send = find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      path.add(tester.getTopLeft(plus));
      // Send, where it is drawn this frame: its right edge stays on the box's right edge as it comes in.
      for (final e in send.evaluate()) {
        final box = e.renderObject as RenderBox;
        sends.add(box.localToGlobal(box.size.bottomRight(Offset.zero)));
      }
    }
    final right = tester.getTopRight(find.byType(ComposerBox)).dx;
    for (final s in sends) {
      expect(s.dx, closeTo(right - 4 - 4, 6), reason: 'Send keeps to the right edge: it never slides in sideways');
    }
    for (final p in path) {
      expect(p.dx, closeTo(start.dx, 0.01), reason: 'sideways it never moves');
      // Held at the page's foot, the box grows upward: the + stays on the bottom line every frame while the words rise
      // above it (the old composer shrank it out of the words' line and faded a new one in from above).
      expect(p.dy, closeTo(start.dy, 0.5), reason: 'it never leaves the bottom line');
      expect(plus, findsOneWidget);
    }
    final rise = tester.getTopLeft(find.byType(ComposerBox)).dy;
    expect(rise, lessThan(boxTop), reason: 'the box grew by a row');
    expect(path.last.dy, closeTo(start.dy, 0.5), reason: 'held to the bottom corner');
    // The words' room reached the box's edges: no space kept for buttons beside them.
    await tester.pump(const Duration(milliseconds: 300));
    final words = tester.getTopLeft(find.text('On my way')).dx;
    expect(words, lessThan(start.dx + 36), reason: 'the words start at the box\'s own edge, not after the +');
    await tester.pumpWidget(const SizedBox());
  });
}
