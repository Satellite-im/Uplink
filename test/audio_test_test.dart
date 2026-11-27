import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaDeviceInfo;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/voice_pane.dart';
import 'package:ghost_messaging/voice/call_sound.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

import 'support/list_harness.dart';

/// GMFB-2 (@kevin, Windows 0.11.3: "When testing voice calls it is difficult to diagnose issues without an in app audio
/// device test"): Settings › Voice and video tests the microphone chosen, as a call opens it, with how loud it hears
/// you, and plays you back through the speaker chosen when asked.
class _TestMedia extends RtcMedia {
  _TestMedia(VoiceSettings s) : super(settings: s);
  bool started = false, stopped = false;
  @override
  Future<void> start() async {
    started = true;
    levels.value = const {'me': 0.5};
  }

  @override
  Future<void> stop() async => stopped = true;
}

Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  testWidgets('the microphone test shows how loud it hears you, plays you back when asked, and lets go when stopped', (tester) async {
    ListPhone(const []).install();
    _TestMedia? made;
    AudioTest.make = (s) => made = _TestMedia(s);
    RtcMedia.enumerate = () async => [MediaDeviceInfo(kind: 'audioinput', label: 'USB mic', deviceId: 'mic-1')];
    addTearDown(() {
      AudioTest.make = null;
      RtcMedia.enumerate = null;
    });
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('voice'), AppState()..set('voice_input', 'mic-1'));
    await settle(tester);
    final start = find.byKey(const ValueKey('audio-test'));
    await tester.scrollUntilVisible(start, 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Test your microphone'), findsOneWidget);
    await tester.tap(find.text('Test your microphone'));
    await settle(tester);
    expect(made?.started, isTrue);
    expect(made!.settings.input, 'mic-1', reason: 'the microphone chosen is the one tested');
    final bar = tester.getSize(find.byKey(const ValueKey('audio-test-level'))).width;
    final track = tester.getSize(find.ancestor(of: find.byKey(const ValueKey('audio-test-level')), matching: find.byType(Stack)).first).width;
    expect(bar / track, closeTo(0.5, 0.05), reason: 'the bar is as loud as the microphone hears');

    expect(made!.hearMyself, isFalse, reason: 'nobody hears themselves unless they ask');
    await tester.tap(find.bySemanticsLabel('Hear yourself').last);
    await settle(tester);
    expect(made!.hearMyself, isTrue);

    await tester.tap(find.text('Stop the test'));
    await settle(tester);
    expect(made!.stopped, isTrue, reason: 'the microphone is let go of');
    expect(find.text('Test your microphone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // GMFB-30, GMFB-51: calls in a browser. Settings › Voice and video there has what a page can do (its microphone, the
  // browser's own noise suppression, everyone's volume up to as loud as they arrive) and says what it leaves out;
  // nothing that needs the app's native halves (the microphone's boost, RNNoise and DeepFilterNet, hearing yourself).
  testWidgets('in a browser with calls, Voice and video has only what a page can do, and says what it leaves out', (tester) async {
    ListPhone(const []).install();
    _TestMedia? made;
    AudioTest.make = (s) => made = _TestMedia(s);
    RtcMedia.enumerate = () async => [MediaDeviceInfo(kind: 'audioinput', label: 'USB mic', deviceId: 'mic-1')];
    Sms.browser = true;
    Sms.browserCalls = true;
    addTearDown(() {
      AudioTest.make = null;
      RtcMedia.enumerate = null;
      Sms.browser = false;
      Sms.browserCalls = false;
    });
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('voice'), AppState());
    await settle(tester);
    expect(find.text(callsInBrowser), findsOneWidget);
    // The microphone as a device, and no volume of its own beside Output's.
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('How loud everyone is in a call. A browser plays nobody louder than they arrive.'), findsOneWidget);
    // The browser's own, whatever was chosen elsewhere; and only it, or none, to choose from.
    expect(find.text('Standard'), findsOneWidget);
    await tester.ensureVisible(find.text('Noise suppression'));
    await settle(tester);
    await tester.tap(find.text('Noise suppression'));
    await settle(tester);
    expect(find.textContaining('Standard ·'), findsOneWidget);
    expect(find.textContaining('Off ·'), findsOneWidget);
    expect(find.textContaining('RNNoise'), findsNothing);
    expect(find.textContaining('DeepFilterNet'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.textContaining('Standard ·'), findsNothing, reason: 'the choices put away');
    await tester.ensureVisible(find.text('Test your microphone'));
    await settle(tester);
    await tester.tap(find.text('Test your microphone'));
    await settle(tester);
    expect(made?.started, isTrue);
    expect(find.bySemanticsLabel('Hear yourself'), findsNothing);
    await tester.tap(find.text('Stop the test'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone or a computer it is all there, as before', (tester) async {
    ListPhone(const []).install();
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('voice'), AppState());
    await settle(tester);
    expect(find.text(callsInBrowser), findsNothing);
    expect(find.text('Microphone'), findsNWidgets(2));
    expect(find.text('Speaker or headset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a microphone chosen that is not connected says the system\'s own is used, and the Mac\'s "default" is offered once', (tester) async {
    ListPhone(const []).install();
    RtcMedia.enumerate = () async => [
          MediaDeviceInfo(kind: 'audioinput', label: 'MacBook Air Microphone', deviceId: 'default'),
          MediaDeviceInfo(kind: 'audioinput', label: 'MacBook Air Microphone', deviceId: 'BuiltInMicrophoneDevice'),
          MediaDeviceInfo(kind: 'audiooutput', label: 'Studio Display Speakers', deviceId: 'display-uid'),
        ];
    addTearDown(() => RtcMedia.enumerate = null);
    final sheet = await loadSheet(tester);
    final app = AppState()
      ..set('voice_input', 'usb-uid')
      ..set('voice_input_name', 'USB Microphone')
      ..set('voice_output', 'display-uid');
    await pumpScreen(tester, sheet, const SettingsSectionScreen('voice'), app);
    await settle(tester);
    expect(find.text('USB Microphone is not connected: using the system\'s own'), findsOneWidget);
    // The devices are listed after the native half is asked what it runs, which answers outside the test's clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await settle(tester);
    expect(find.text('Studio Display Speakers'), findsOneWidget);
    await tester.tap(find.text('USB Microphone is not connected: using the system\'s own'));
    await settle(tester);
    // The system's own, then the one real microphone: "default" is the system's own, not listed twice.
    expect(find.text('The system\'s own'), findsWidgets);
    expect(find.textContaining('MacBook Air Microphone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
