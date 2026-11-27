import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// The Circles tab lists circles and nothing else (lib/ui/conversations.dart). Matt, 2026-11-17: "there are spaces
/// listed under the circles tab it shouldn't be circles and spaces it should only be circles". A space of one's own
/// stays in Messages among the conversations.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);
  setUp(() => ListPhone(const []).install());
  tearDown(() async {
    await Circles.instance.clear();
    Voice.instance.own = [];
  });

  Finder circlesTab() => find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.circleDot);

  testWidgets('a space of one\'s own is in Messages, not in the Circles tab; the circle is', (tester) async {
    final keys = NetKeys.generate();
    final circle = Circle(
      seed: '7' * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: [CircleSpace.make('General', kind: SpaceKind.text)]),
    );
    Circles.instance.join(circle);
    Voice.instance.own = [VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public))];

    final sheet = await loadSheet(tester);
    // The Circles tab is the dock's; the rail shows circles itself and has none (Matt, 2026-11-20).
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.dock.name));
    await settle(tester);
    expect(find.text('Friday hang'), findsOneWidget, reason: 'Messages lists the space among the conversations');
    expect(find.text('Night Owls'), findsNothing, reason: 'a circle is not in Messages');

    await tester.tap(circlesTab().first);
    await settle(tester);
    expect(find.byKey(ValueKey('circle-row-${circle.seed}')), findsOneWidget);
    expect(find.text('Friday hang'), findsNothing, reason: 'only circles in the Circles tab');
    expect(tester.takeException(), isNull);
  });

  testWidgets('with spaces of one\'s own and no circle, the Circles tab says there are no circles yet', (tester) async {
    final keys = NetKeys.generate();
    Voice.instance.own = [VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public))];
    final sheet = await loadSheet(tester);
    // The Circles tab is the dock's; the rail shows circles itself and has none (Matt, 2026-11-20).
    await pumpScreen(tester, sheet, const AppShell(), AppState()..set(NavStyle.pref, NavStyle.dock.name));
    await tester.tap(circlesTab().first);
    await settle(tester);
    expect(find.text('No circles yet'), findsOneWidget);
    expect(find.text('Friday hang'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
