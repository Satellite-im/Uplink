import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/screen_share.dart';
import 'package:ghost_messaging/voice/voice.dart' show ScreenSource;

import 'support/space_call_harness.dart';

/// A space's call page (lib/ui/space_designs) draws without fault on a phone and on a computer, in a full call, in a
/// call alone (this device's own level still moving its face), and in a group's channel with no chat; and what the
/// call shares of a screen: the choice of screen or window, and someone's screen drawn large. The page's own test
/// (space_design_telegram_test.dart) looks closer. It was one of seven ways a space's call could look (Matt,
/// 2026-11-16: "give me 6 alternate designs for the calling chat and video screens for spaces"); the others are gone
/// (Matt, 2026-11-24: "remove the other video call layouts from the codebase we only use the default one now").
void main() {
  testWidgets('a space\'s call draws on a phone and a computer, full, alone, and without a chat', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    for (final size in [SpaceHarness.phone, SpaceHarness.computer]) {
      await h.shoot(tester, TelegramCall(call: h.call()), 'smoke-call', size: size);
      expect(tester.takeException(), isNull);
      await h.shoot(tester, TelegramCall(call: h.call(people: 0, video: const {})), 'smoke-call-alone', size: size);
      expect(tester.takeException(), isNull);
      await h.shoot(tester, TelegramCall(call: h.call(withChat: false)), 'smoke-call-nochat', size: size);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the computer\'s choice of screen or window: screens, then windows, and a press picks one', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    String? picked;
    await h.shoot(
      tester,
      // As wide as the sheet it opens in (30rem).
      Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: 480, child: ScreenPicker(
          sources: const [
            ScreenSource(id: 'screen:0', name: 'Entire screen', window: false),
            ScreenSource(id: 'window:1', name: 'Notes', window: true),
            ScreenSource(id: 'window:2', name: 'Safari', window: true),
          ],
          onPick: (id) => picked = id,
        )),
      ),
      'share-picker',
      size: SpaceHarness.computer,
    );
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Entire screen')).dy, lessThan(tester.getTopLeft(find.text('Notes')).dy));
    await tester.tap(find.text('Notes'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(picked, 'window:1');
    await tester.pumpWidget(const SizedBox());
  });

  // Matt, 2026-11-23: "screen sharing on mac and pc doesn't show anything to select". The default design (Voice
  // chat) and Meeting share from a menu that closes as the row is pressed; the picker asked for the screens before
  // opening, and by the time they came the menu's context was gone, so nothing opened.
  const shareable = [
    ScreenSource(id: 'screen:0', name: 'Entire screen', window: false),
    ScreenSource(id: 'window:1', name: 'Notes', window: true),
  ];

  testWidgets('the picker opens from a menu that closes as it is pressed, and what is picked comes back', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    String? picked = 'unset';
    await h.shoot(
      tester,
      _ClosingMenu(onShare: (context) async {
        picked = await pickScreen(context, () => Future.delayed(const Duration(milliseconds: 200), () => shareable));
      }),
      'share-from-menu',
      size: SpaceHarness.computer,
    );
    await tester.tap(find.text('Share screen'));
    await tester.pump();
    // Said at once, before the system has answered: never a blank sheet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Share screen'), findsNothing, reason: 'the menu has closed');
    expect(find.text('Looking for your screens and windows…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Entire screen'), findsOneWidget);
    await tester.tap(find.text('Notes'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(picked, 'window:1');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('screens that come after an empty first answer appear by themselves', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    var asked = 0;
    await h.shoot(
      tester,
      _ClosingMenu(onShare: (context) => pickScreen(context, () async => asked++ == 0 ? const <ScreenSource>[] : shareable)),
      'share-late',
      size: SpaceHarness.computer,
    );
    await tester.tap(find.text('Share screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Entire screen'), findsNothing);
    expect(find.textContaining('No screens or windows'), findsNothing, reason: 'one empty answer is not believed');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Entire screen'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with nothing to share the sheet says why and what to do, and Try again looks again', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    var found = const <ScreenSource>[];
    for (final mac in [true, false]) {
      found = const [];
      await h.shoot(
        tester,
        _ClosingMenu(onShare: (context) => pickScreen(context, () async => found, mac: mac)),
        'share-none-${mac ? 'mac' : 'pc'}',
        size: SpaceHarness.computer,
      );
      await tester.tap(find.text('Share screen'));
      await tester.pump();
      for (var i = 0; i < ScreenChoices.tries + 1; i++) {
        await tester.pump(ScreenChoices.soon);
      }
      expect(find.textContaining('No screens or windows were found'), findsOneWidget);
      expect(find.textContaining('Screen & System Audio Recording'), mac ? findsOneWidget : findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
      if (autoUpdateGoldenFiles) await h.again(tester, 'share-none-${mac ? 'mac' : 'pc'}-said');
      found = shareable;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Entire screen'), findsOneWidget);
      expect(find.textContaining('No screens or windows'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('someone\'s screen, large: their name over it, waiting until it arrives, and Back to call', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    var back = 0;
    await h.shoot(tester, ScreenStage(name: 'Maya Chen', stream: null, onBack: () => back++), 'share-stage', size: SpaceHarness.phone);
    expect(find.text('Maya Chen\'s screen'), findsOneWidget);
    expect(find.text('Waiting for Maya Chen\'s screen…'), findsOneWidget);
    await tester.tap(find.text('Back to call'));
    expect(back, 1);
    await tester.pumpWidget(const SizedBox());
  });

  // GMFB-63 (Matt, 2026-11-25): "Screen shares should include audio controls but there are none and users can't hear
  // any audio from the share".
  testWidgets('the computer\'s sound with its screen: a switch where the device can send it, left as it is set, and none where it can\'t', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final sound = ValueNotifier(true);
    Widget choices({required bool can, required bool mac}) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 480, child: ScreenChoices(key: ValueKey('$can-$mac'), sources: () async => shareable, sound: sound, canSound: Future.value(can), mac: mac, onPick: (_) {})),
        );
    await h.shoot(tester, choices(can: true, mac: false), 'share-picker-sound', size: SpaceHarness.computer);
    expect(find.text('Share sound too'), findsOneWidget);
    expect(find.textContaining('everything your PC plays apart from this call'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Share sound too')).dy, lessThan(tester.getTopLeft(find.text('Screens')).dy), reason: 'said before anything is picked');
    await tester.tap(find.byKey(const ValueKey('share-sound')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(sound.value, isFalse);
    await tester.tap(find.byKey(const ValueKey('share-sound')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(sound.value, isTrue);
    // A Mac says what a Mac does: everything it plays, and its own question.
    await h.shoot(tester, choices(can: true, mac: true), 'share-picker-sound-mac', size: SpaceHarness.computer);
    expect(find.textContaining('What your Mac plays goes with your screen, apart from this call'), findsOneWidget);
    // Where the device can't send it (Linux, a Mac before 14.4, a phone): no switch, and the screens as ever.
    await h.shoot(tester, choices(can: false, mac: false), 'share-picker-no-sound', size: SpaceHarness.computer);
    expect(find.text('Share sound too'), findsNothing);
    expect(find.text('Entire screen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a screen shared with its sound: a button on it opens how loud it is on this device, and silences it', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    var volume = 100;
    await h.shoot(
      tester,
      StatefulBuilder(
        builder: (context, set) => ScreenStage(
          name: 'Maya Chen',
          stream: null,
          picture: const ColoredBox(color: Color(0xFF1D2B3A)),
          desk: true,
          onBack: () {},
          sound: (volume: volume, hearing: true, onVolume: (v) => set(() => volume = v)),
        ),
      ),
      'share-stage-sound',
      size: SpaceHarness.computer,
    );
    expect(find.byKey(const ValueKey('stage-sound')), findsOneWidget);
    expect(find.byKey(const ValueKey('stage-sound-strip')), findsNothing, reason: 'out of the way until asked for');
    await tester.tap(find.byKey(const ValueKey('stage-sound')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('stage-sound-strip')), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    await h.again(tester, 'share-stage-sound-open');
    // Silenced, and back.
    await tester.tap(find.byKey(const ValueKey('stage-sound-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    expect([volume, find.text('0%').evaluate().length], [0, 1]);
    await tester.tap(find.byKey(const ValueKey('stage-sound-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(volume, 100);
    // Its loudness, pressed half way along.
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('stage-sound-volume'))));
    await tester.pump(const Duration(milliseconds: 300));
    expect(volume, inInclusiveRange(45, 55));
    // The button again puts it away.
    await tester.tap(find.byKey(const ValueKey('stage-sound')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('stage-sound-strip')), findsNothing);
    // A screen shared without its sound has no button for it.
    await h.shoot(tester, ScreenStage(name: 'Maya Chen', stream: null, picture: const ColoredBox(color: Color(0xFF1D2B3A)), desk: true, onBack: () {}), 'share-stage-silent', size: SpaceHarness.computer);
    expect(find.byKey(const ValueKey('stage-sound')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // Nothing is left of the other ways a space's call could look, nor of the switch between them.
  test('there is one way a space\'s call is drawn, and no switch', () {
    final here = Directory('lib/ui/space_designs').listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(here, ['call_plugins.dart', 'space_design.dart', 'telegram.dart']);
    final all = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('changelog.dart'));
    for (final f in all) {
      final src = f.readAsStringSync();
      for (final gone in ['SpaceDesign.', 'dev_space_design', 'DiscordCall', 'ZoomCall', 'FaceTimeCall', 'MeetCall', 'StageCall', 'HangoutPeople']) {
        expect(src.contains(gone), isFalse, reason: '${f.path} still has $gone');
      }
    }
  });
}

/// A menu as the call's page has (telegram.dart's _Menu): pressing its
/// row closes it, then runs the row with the menu's own context, which is gone a frame later.
class _ClosingMenu extends StatefulWidget {
  const _ClosingMenu({required this.onShare});
  final void Function(BuildContext context) onShare;

  @override
  State<_ClosingMenu> createState() => _ClosingMenuState();
}

class _ClosingMenuState extends State<_ClosingMenu> {
  bool _open = true;

  @override
  Widget build(BuildContext context) => Center(
        child: !_open
            ? const SizedBox()
            : Builder(
                builder: (menu) => GestureDetector(
                  onTap: () {
                    setState(() => _open = false);
                    widget.onShare(menu);
                  },
                  child: const Text('Share screen'),
                ),
              ),
      );
}
