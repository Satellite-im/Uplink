import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-25: "when switching chats show the sidebar immediately as it animates in from the right and briefly
// shows the main chat sidebar when switching between spaces". From one circle to another its list is in place on the
// next frame; the circle left slid away as the next slid in, with the conversations seen between them.

Circle _circle(String d, String name) => Circle(
      seed: d * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: name, hue: 'indigo', icon: 'sparkles', spaces: [
        CircleSpace(seed: '${d}a' * 32, name: 'General', kind: SpaceKind.text),
      ]),
    );

final _one = _circle('7', 'OnlyGhosts'), _two = _circle('8', 'Book club');

void main() {
  tearDown(() async {
    await Circles.instance.clear();
  });

  Future<AppShellState> open(WidgetTester tester, Size size, String platform) async {
    ListPhone([ListPhone.conversation(1, '+15550100', 'Call me when you land', name: 'Dad')]).install();
    Circles.instance.join(_one);
    Circles.instance.join(_two);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState(), size: size, platform: platform);
    return AppShellState.live!;
  }

  double left(WidgetTester tester, Circle c) => tester.getTopLeft(find.byKey(ValueKey('circle-${c.seed}'))).dx;

  testWidgets('on a computer a circle\'s list is in place at once, from the conversations and from another circle', (tester) async {
    final shell = await open(tester, const Size(1100, 760), 'desktop');
    shell.openCircle(_one);
    await tester.pump();
    await tester.pump();
    final at = left(tester, _one);
    await settle(tester);
    expect(left(tester, _one), at, reason: 'it did not slide in');

    shell.openCircle(_two);
    await tester.pump();
    await tester.pump();
    expect(left(tester, _two), at, reason: 'the next circle is where the last was, on the next frame');
    expect(find.byKey(ValueKey('circle-${_one.seed}')), findsNothing, reason: 'the circle left is gone, not sliding away');
    await settle(tester);
    expect(left(tester, _two), at);

    // Back to the conversations: gone at once too.
    shell.home();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(ValueKey('circle-${_two.seed}')), findsNothing);
    await settle(tester);
  });

  testWidgets('on a phone a circle slides in over the conversations, and the next circle takes its place at once', (tester) async {
    final shell = await open(tester, const Size(390, 800), 'android');
    shell.openCircle(_one);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final sliding = left(tester, _one);
    await settle(tester);
    // Beside the strip of circles, where a phone has one.
    final at = left(tester, _one);
    expect(sliding, greaterThan(at), reason: 'it slid in');

    shell.openCircle(_two);
    await tester.pump();
    await tester.pump();
    expect(left(tester, _two), at, reason: 'in place on the next frame');
    await settle(tester);
    expect(left(tester, _two), at);
  });
}
