import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/desk.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/main.dart';
import 'package:ghost_messaging/desktop/ui/shell.dart';
import 'package:ghost_messaging/desktop/ui/wizard.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:ghost_messaging/ui/computers.dart';
import 'package:glacier/glacier.dart' show GlacierPressable;
import 'package:integration_test/integration_test.dart';

/// The real Mac app, started and driven here, against the real phone app on an emulator (docs/desktop.md, "Trying
/// it"). It is half of a run: this presses the Mac's buttons and says what it sees, a line at a time, and whoever
/// runs it presses the phone's (adb) as the lines ask:
///
///     flutter test integration_test/desk_live_test.dart -d macos \
///       --dart-define=DESK_MODE=local --dart-define=DESK_PEER=127.0.0.1:47900
///
/// - `DESK-CODE <code>` and `DESK-LINK <link>`: paste the code on the phone (Settings › Computers › Pair a
///   computer), or open the link there as its camera would; then `adb forward` the port
///   the phone says it listens on to DESK_PEER's (local), or `adb reverse` the relay's port (relay).
/// - `DESK-DIGITS <six>`: the phone should show the same; press "They match" there.
/// - `DESK-WAITING-FOR-TEXT <tag>`: send the emulator a text from 5550100 with the tag in it.
/// - `DESK-SENT <words>`: the phone's own store should now hold those words as sent.
/// - `DESK-UNPAIR-ON-THE-PHONE` (with DESK_UNPAIR=false): unpair this Mac in the phone's Settings › Computers.
///
/// DESK_MODE is local, relay or both; DESK_RELAY is the relay's address; DESK_SHOTS is a port on this Mac that
/// pictures of the window are sent to, if one is listening.
const _mode = String.fromEnvironment('DESK_MODE', defaultValue: 'local');
const _peer = String.fromEnvironment('DESK_PEER', defaultValue: '127.0.0.1:47900');
const _relay = String.fromEnvironment('DESK_RELAY', defaultValue: 'ws://127.0.0.1:8787/relay');
const _shots = int.fromEnvironment('DESK_SHOTS', defaultValue: 47990);
const _unpair = bool.fromEnvironment('DESK_UNPAIR', defaultValue: true);

/// Words no text on the phone has yet, so the one that arrives during the run is told from those before it.
final _tag = 'live${DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000}';

/// How the window is drawn while this drives it. `live` (the default): the app draws every frame itself, exactly as
/// when a person runs it, and this only waits, looks and presses. `stepped`: a frame only when this asks for one,
/// every 16 ms, which is a test's own way.
const _frames = String.fromEnvironment('DESK_FRAMES', defaultValue: 'live');

void say(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  // A test's own way is to draw a frame only when it asks for one. Asked for every 150 ms, as this first did, the
  // window jerked along at seven frames a second (Matt, 2026-11-13: "the loading indicator is at a few fps instead
  // of smooth"; integration_test/desk_frames_test.dart counts them). Live, the app draws as it does for a person.
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final live = _frames == 'live';
  if (live) binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('the Mac app pairs with the phone, lists, hears a new text and sends one ($_mode)', (tester) async {
    /// A picture of the window, sent to whoever listens on DESK_SHOTS. Never the reason a run stops: a picture
    /// that cannot be taken in five seconds is said and passed over.
    late final Future<void> Function(String name) shot;

    /// Lets [d] pass. Live, the app is drawing by itself and time simply passes; stepped, frames are asked for.
    Future<void> wait(Duration d) async {
      if (live) {
        await Future<void>.delayed(d);
      } else {
        final end = DateTime.now().add(d);
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
    }

    /// Every piece of text on the screen now, in the order the screen is built: said when something waited for
    /// never comes, so what was there in its place can be read.
    List<String> onScreen() => [
          for (final e in find.byType(Text).evaluate())
            ((e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '').replaceAll('\n', ' '),
        ].where((t) => t.isNotEmpty).toList();

    Future<void> until(bool Function() test, String what, {Duration max = const Duration(minutes: 4)}) async {
      final end = DateTime.now().add(max);
      while (!test()) {
        if (DateTime.now().isAfter(end)) {
          say('DESK-NOTE on the screen when "$what" never came: ${onScreen().join(' | ')}');
          await shot('failed');
          fail('Never happened: $what');
        }
        await wait(const Duration(milliseconds: 50));
      }
      await wait(const Duration(milliseconds: 300));
    }

    shot = (String name) async {
      try {
        await wait(const Duration(milliseconds: 400));
        // The page as it was last painted: the route's own boundary, which fills the window.
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
        final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio).timeout(const Duration(seconds: 5));
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png).timeout(const Duration(seconds: 5)))!;
        final socket = await Socket.connect('127.0.0.1', _shots, timeout: const Duration(seconds: 2));
        socket.add('$name\n'.codeUnits);
        socket.add(bytes.buffer.asUint8List());
        await socket.flush().timeout(const Duration(seconds: 5));
        await socket.close().timeout(const Duration(seconds: 5));
      } catch (e) {
        say('DESK-NOTE no picture of $name: $e');
      }
    };

    final dir = Directory.systemTemp.createTempSync('ghost-desk-live');
    PhoneLink? watched;
    // Said every five seconds whatever else is happening: that the app is alive, and where the pairing stands.
    // And how many frames the window has drawn: a window that macOS has stopped drawing (covered, or the app set
    // aside) shows nothing new however much has arrived, and what this reads off the screen is then stale.
    var frames = 0;
    SchedulerBinding.instance.addPersistentFrameCallback((_) => frames++);
    final heartbeat = Timer.periodic(const Duration(seconds: 5), (_) => say('DESK-TICK phase=${watched?.attempt?.phase} via=${watched?.via} paired=${watched?.phone != null} frames=$frames'));
    addTearDown(heartbeat.cancel);
    await desktopMain(peers: _mode == 'relay' ? const [] : [Peer.parse(_peer)!], folder: dir.path, bonjour: false, updates: false);
    await until(() => find.text('Your texts, on your Mac').evaluate().isNotEmpty, 'the wizard');
    final link = DeskScope.of(tester.element(find.byType(PairWizard))).link;
    watched = link;
    say('DESK-NAME ${link.name}');

    // The wizard: the three ways to connect are all there, and the first is the one chosen to start with.
    for (final m in connectionModes) {
      expect(find.text(m.label), findsOneWidget);
    }
    expect(tester.widget<Pick>(find.byWidgetPredicate((w) => w is Pick && w.label == 'Use local network, then relay')).checked, isTrue);
    await shot('1-wizard');
    final label = connectionModes.firstWhere((m) => m.id == _mode).label;
    await tester.tap(find.byWidgetPredicate((w) => w is Pick && w.label == 'Use ${label.toLowerCase()}'));
    await wait(const Duration(milliseconds: 300));
    // The relay's address is under the choices, out of a short window's view until it is scrolled to.
    await tester.scrollUntilVisible(find.byType(EditableText), 240, scrollable: find.byType(Scrollable).first);
    await tester.enterText(find.byType(EditableText).first, _relay);
    await wait(const Duration(milliseconds: 300));
    await tester.tap(find.text('Show the pairing code'));
    await until(() => link.attempt != null, 'the pairing code');
    expect(link.attempt!.offer.mode, _mode);
    say('DESK-CODE ${link.attempt!.offer.text}');
    // What the QR code holds: opened on the phone as its camera would (adb shell am start -a android.intent.action.VIEW -d <link>).
    say('DESK-LINK ${link.attempt!.offer.link}');
    await shot('2-code');

    await until(() => link.attempt?.phase == 'code', 'the phone', max: const Duration(minutes: 8));
    say('DESK-DIGITS ${link.attempt!.code} via=${link.via} phone=${link.attempt!.phoneName}');
    await shot('3-digits');
    await tester.tap(find.text('They match'));
    await until(() => link.phone != null && link.online, 'being paired', max: const Duration(minutes: 5));
    say('DESK-PAIRED via=${link.via} mode=${link.phone!.mode} phone=${link.phone!.name}');
    if (_mode == 'local') expect(link.via, 'local');
    if (_mode == 'relay') expect(link.via, 'relay');

    // The conversations, read from the phone.
    await until(() => find.textContaining('5550100').evaluate().isNotEmpty, 'the conversations');
    say('DESK-LISTED');
    await shot('4-conversations');
    await tester.tap(find.textContaining('5550100').first);
    // The conversation beside the list: its first text as a bubble, and a field to type in.
    await until(() => find.text('See you at 7').evaluate().isNotEmpty && find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send').evaluate().isNotEmpty, 'the conversation');
    await shot('5-conversation');

    // A text arrives on the phone while the conversation is open here.
    say('DESK-WAITING-FOR-TEXT $_tag');
    // In the list (its last words) and in the conversation (a bubble).
    await until(() => find.textContaining(_tag).evaluate().length >= 2, 'the new text, in the list and in the conversation', max: const Duration(seconds: 40));
    say('DESK-HEARD via=${link.via}');
    await shot('6-new-text');

    // And one is typed here: it goes through the phone.
    final words = 'Sent from the Mac by $_mode at ${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    await tester.enterText(find.byType(EditableText).last, words);
    await wait(const Duration(milliseconds: 300));
    await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send'));
    // Sent means the phone says so: the words among the conversation's own messages, read back from the phone,
    // going out and no longer waiting. (The words on the screen prove nothing: they are in the field as typed.)
    final thread = (await Sms.instance.conversations()).firstWhere((c) => c.title.contains('5550100')).id;
    String state = '';
    final gaveUp = DateTime.now().add(const Duration(minutes: 1));
    while (true) {
      final mine = (await Sms.instance.messages(thread)).where((m) => m.outgoing && m.body.contains(words)).firstOrNull;
      final typed = tester.widget<EditableText>(find.byType(EditableText).last).controller.text;
      final now = 'state=${mine?.state} field=${typed.isEmpty ? 'empty' : 'holds the words'} waiting=${DeskScope.of(tester.element(find.byType(DeskShell))).calls.waiting} via=${link.via}';
      if (now != state) say('DESK-NOTE after Send: $now');
      state = now;
      if (mine != null && mine.state != 'waiting' && mine.state != 'failed') break;
      if (DateTime.now().isAfter(gaveUp)) fail('The text typed on the Mac never left: $now');
      await wait(const Duration(milliseconds: 500));
    }
    await until(() => find.text(words).evaluate().any((e) => e.widget is! EditableText), 'the sent text as a bubble', max: const Duration(seconds: 30));
    say('DESK-SENT $words');
    await wait(const Duration(seconds: 3));
    await shot('7-sent');

    if (_unpair) {
      // Unpaired from here: the wizard is back, and the phone is told.
      await tester.tap(find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == 'Settings'));
      await until(() => find.text('Unpair this phone').evaluate().isNotEmpty, 'Settings');
      await shot('8-settings');
      await tester.ensureVisible(find.text('Unpair this phone'));
      await wait(const Duration(milliseconds: 400));
      await tester.tap(find.text('Unpair this phone'));
      await until(() => find.text('Unpair').evaluate().isNotEmpty, 'the question');
      await tester.tap(find.text('Unpair').last);
      await until(() => link.phone == null && find.text('Your texts, on your Mac').evaluate().isNotEmpty, 'the wizard again');
      say('DESK-UNPAIRED');
    }
    if (!_unpair) {
      // Unpaired on the phone while this Mac is connected: the Mac is told, and is back at its wizard.
      say('DESK-UNPAIR-ON-THE-PHONE');
      await until(() => link.phone == null && find.text('Your texts, on your Mac').evaluate().isNotEmpty, 'being told it was unpaired', max: const Duration(minutes: 5));
      say('DESK-TOLD-UNPAIRED');
    }
    say('DESK-DONE');
    await wait(const Duration(seconds: 2));
  }, timeout: const Timeout(Duration(minutes: 25)));
}
