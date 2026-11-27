import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/ui.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// The filter's menu stays on the screen (Matt, 2026-11-20: "the filter popover goes off screen it should make sure
/// it renders on screen"). The kit turned a menu up only where it fitted there whole and never made one shorter, so
/// a long one under the button ran off the window's foot: 5 points on a 360 x 640 phone, 55 in a window 520 high.
/// Now it goes where there is more room, no taller or wider than that room, its rows scrolling.

/// The menu's panel, as drawn.
Rect _panel(WidgetTester tester) => tester.getRect(find.ancestor(of: find.byType(GlacierMenuItem).first, matching: find.byType(IntrinsicWidth)).first);

/// [panel] is inside [screen] less [inset], with the kit's 8 to spare.
void _onScreen(Rect panel, Size screen, {EdgeInsets inset = EdgeInsets.zero}) {
  const margin = 8.0, slack = 1.0;
  expect(panel.left, greaterThanOrEqualTo(inset.left + margin - slack), reason: 'left of $panel');
  expect(panel.top, greaterThanOrEqualTo(inset.top + margin - slack), reason: 'top of $panel');
  expect(panel.right, lessThanOrEqualTo(screen.width - inset.right - margin + slack), reason: 'right of $panel');
  expect(panel.bottom, lessThanOrEqualTo(screen.height - inset.bottom - margin + slack), reason: 'bottom of $panel');
}

/// A filter button alone, its corner at [at], on a screen [size] with [rows] rows in its menu, and the menu opened.
/// [padding] is the system's bars and [keyboard] the keyboard's height, in points.
Future<Rect> _open(WidgetTester tester, {required Size size, required Offset at, int rows = 20, EdgeInsets padding = EdgeInsets.zero, double keyboard = 0}) async {
  final sheet = await loadSheet(tester);
  tester.view.padding = FakeViewPadding(left: padding.left * 2, top: padding.top * 2, right: padding.right * 2, bottom: padding.bottom * 2);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2);
  await pumpScreen(
    tester,
    sheet,
    Stack(children: [
      Positioned(
        left: at.dx,
        top: at.dy,
        child: FilterButton(hidden: 0, rows: (_) => [for (var i = 0; i < rows; i++) GlacierMenuItem(closes: false, onSelect: () {}, child: Text('Row $i'))]),
      ),
    ]),
    AppState(),
    size: size,
  );
  final button = tester.getRect(find.byType(FilterButton));
  await tester.tap(find.byType(FilterButton));
  await settle(tester);
  return button;
}

void main() {
  testWidgets('on a short phone the list\'s filter menu stays on the screen, and scrolls to its last kind', (tester) async {
    ListPhone([ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4)]).install();
    final sheet = await loadSheet(tester);
    const screen = Size(360, 640);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState(), size: screen);
    final button = tester.getRect(find.byType(FilterButton));
    await tester.tap(find.byType(FilterButton));
    await settle(tester);
    final panel = _panel(tester);
    _onScreen(panel, screen);
    expect(panel.top, greaterThan(button.bottom), reason: 'under the button, where there is more room');
    expect(find.byType(GlacierMenuItem), findsNWidgets(12), reason: 'All, Personal & other and every kind');
    final last = find.byType(GlacierMenuItem).last;
    await tester.ensureVisible(last);
    await settle(tester);
    expect(panel.contains(tester.getRect(last).center), isTrue, reason: 'the last kind scrolled into the menu');
  });

  testWidgets('in a window 520 high it stays inside the window', (tester) async {
    ListPhone([ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7', name: 'Maya Chen', minutes: 4)]).install();
    final sheet = await loadSheet(tester);
    const screen = Size(1100, 520);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState(), size: screen, platform: 'desktop');
    await tester.tap(find.byType(FilterButton));
    await settle(tester);
    _onScreen(_panel(tester), screen);
  });

  testWidgets('a long menu under the button is as tall as the room below it', (tester) async {
    const screen = Size(400, 600);
    final button = await _open(tester, size: screen, at: const Offset(300, 200));
    final panel = _panel(tester);
    _onScreen(panel, screen);
    expect(panel.top, moreOrLessEquals(button.bottom + 8, epsilon: 1));
    expect(panel.bottom, moreOrLessEquals(screen.height - 8, epsilon: 1), reason: 'all the room there is');
    await tester.ensureVisible(find.text('Row 19'));
    await settle(tester);
    expect(panel.contains(tester.getRect(find.text('Row 19')).center), isTrue);
  });

  testWidgets('low in the window it opens over the button, where there is more room', (tester) async {
    const screen = Size(400, 600);
    final button = await _open(tester, size: screen, at: const Offset(300, 480));
    final panel = _panel(tester);
    _onScreen(panel, screen);
    expect(panel.bottom, lessThanOrEqualTo(button.top - 8 + 1), reason: 'over the button');
  });

  testWidgets('a short menu with room under the button opens under it, as it always did', (tester) async {
    const screen = Size(400, 600);
    final button = await _open(tester, size: screen, at: const Offset(300, 200), rows: 3);
    final panel = _panel(tester);
    expect(panel.top, moreOrLessEquals(button.bottom + 8, epsilon: 1));
    expect(panel.bottom, lessThan(screen.height - 100), reason: 'as tall as its rows');
  });

  testWidgets('it stays clear of the system\'s bars and the keyboard', (tester) async {
    const screen = Size(412, 892);
    const bars = EdgeInsets.only(top: 24, bottom: 48);
    final button = await _open(tester, size: screen, at: const Offset(340, 200), padding: bars, keyboard: 300);
    final panel = _panel(tester);
    _onScreen(panel, screen, inset: const EdgeInsets.only(top: 24, bottom: 300));
    expect(panel.top, greaterThan(button.bottom));
  });

  testWidgets('in a narrow window it is no wider than the window', (tester) async {
    const screen = Size(220, 600);
    await _open(tester, size: screen, at: const Offset(160, 100));
    final panel = _panel(tester);
    _onScreen(panel, screen);
    expect(panel.width, lessThanOrEqualTo(screen.width - 16 + 1));
  });

  testWidgets('when the window grows shorter while it is open, it is measured again', (tester) async {
    final button = await _open(tester, size: const Size(400, 800), at: const Offset(300, 200));
    expect(_panel(tester).bottom, greaterThan(500), reason: 'room for it at first');
    tester.view.physicalSize = const Size(400, 500) * 2;
    await settle(tester);
    final panel = _panel(tester);
    _onScreen(panel, const Size(400, 500));
    expect(panel.top, moreOrLessEquals(button.bottom + 8, epsilon: 1));
  });
}
