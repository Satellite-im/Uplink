import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/platform.dart';
import 'package:integration_test/integration_test.dart';

/// The Mac's half of a video in a message (macos/Runner/DeskVideo.swift), with a real video and the Mac's own
/// AVFoundation: a picture is made of where it starts and its length is read. (It is played in the app's own player
/// since 2026-11-18, lib/ui/video_screen.dart, no longer in a window of DeskVideo's.)
///
///   flutter test integration_test/desk_video_test.dart -d macos --dart-define=DESK_VIDEO=/path/to/clip.mp4
///
/// With --dart-define=DESK_SOUND=/path/to/voice.m4a the Mac's half of a voice message is run too (DeskSound.swift):
/// its length read, and it played, paused and stopped, with where it has got to told back. Give it a silent one:
/// it plays through the Mac's speakers. The recorder is not run here, since macOS would ask the person at the Mac
/// for the microphone.
const _video = String.fromEnvironment('DESK_VIDEO');
const _sound = String.fromEnvironment('DESK_SOUND');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a video\'s picture and length are made', (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(_video, isNotEmpty, reason: 'give a video: --dart-define=DESK_VIDEO=/path/to/clip.mp4');
    final bytes = File(_video).readAsBytesSync();
    final preview = (await MacPlatform.videoPreview(7, bytes, 'mp4'))!;
    final picture = preview['picture'] as List<int>?;
    debugPrint('DESK-VIDEO-PREVIEW ${picture?.length} bytes ${preview['width']}x${preview['height']} ${preview['millis']} ms');
    expect(picture, isNotNull);
    expect(picture!.take(2).toList(), [0xFF, 0xD8], reason: 'a JPEG');
    expect(preview['millis'] as int, greaterThan(500));
    expect(preview['width'] as int, greaterThan(0));
    expect((preview['width'] as int) <= 720 && (preview['height'] as int) <= 720, isTrue);
    // What is not a video has no picture.
    final nothing = (await MacPlatform.videoPreview(8, File(_video).readAsBytesSync().sublist(0, 2000), 'mp4'))!;
    expect(nothing['picture'], isNull);
  });

  testWidgets('a voice message\'s length is read, and it plays, pauses and stops, saying where it has got to', (tester) async {
    await tester.pumpWidget(const SizedBox());
    if (_sound.isEmpty) return;
    final bytes = File(_sound).readAsBytesSync();
    final length = await MacPlatform.voiceLength(bytes);
    debugPrint('DESK-SOUND-LENGTH $length ms');
    expect(length, greaterThan(1500));
    expect(await MacPlatform.voiceLength(bytes.sublist(0, 300)), 0, reason: 'what is no sound has no length');
    final heard = <Map>[];
    MacPlatform.listenToVoice(heard.add);
    expect(await MacPlatform.voicePlay(41, bytes), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(heard, isNotEmpty);
    expect(heard.last['part'], 41);
    expect(heard.last['playing'], isTrue);
    expect(heard.last['position'] as int, greaterThan(300));
    expect(heard.last['duration'] as int, closeTo(length, 60));
    await MacPlatform.voicePause();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(heard.last['playing'], isFalse);
    final paused = heard.last['position'] as int;
    // Going on with it starts from where it was, not from its beginning.
    expect(await MacPlatform.voicePlay(41, bytes), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(heard.last['position'] as int, greaterThan(paused));
    await MacPlatform.voiceHalt();
    // What is no sound is refused in words.
    expect(await MacPlatform.voicePlay(42, bytes.sublist(0, 300)), isNotNull);
    debugPrint('DESK-SOUND-OK ${heard.length} told');
  });
}
