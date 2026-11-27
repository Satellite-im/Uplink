import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:integration_test/integration_test.dart';

/// Two calls in one app, connected to each other on the device, each with its camera on: each must draw the other's
/// picture, not only its own (Matt, 2026-11-21: "Video is not working on both ends it only shows our local video").
/// Run on a throwaway device with a camera and the camera and microphone allowed:
/// `flutter test integration_test/call_video_test.dart -d emulator-5554`, then while it waits at the permission prompt:
/// `adb -s emulator-5554 shell pm grant com.infamousvague.ghostmessaging android.permission.CAMERA` (and
/// `android.permission.RECORD_AUDIO`). Against the code before the fix the side that answered drew nothing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each side of a call draws the other\'s camera', (tester) async {
    final a = RtcMedia(), b = RtcMedia();
    await a.start();
    await b.start();
    await a.setVideo(true);
    await b.setVideo(true);
    // Each side's ways through handed straight to the other, as the room would.
    late final dynamic toB, toA;
    toA = a.peer('b', onCandidate: (c) => unawaited(toB.addCandidate(c)));
    toB = b.peer('a', onCandidate: (c) => unawaited(toA.addCandidate(c)));
    final offer = await toA.makeOffer();
    final answer = await toB.takeOffer(offer);
    await toA.takeAnswer(answer);

    Future<MediaStream> seen(RtcMedia m, String id) async {
      for (var i = 0; i < 100; i++) {
        final s = m.remote.value[id];
        if (s != null && s.getVideoTracks().isNotEmpty) return s;
        await tester.pump(const Duration(milliseconds: 100));
      }
      fail('no picture from $id');
    }

    final atA = await seen(a, 'b'), atB = await seen(b, 'a');

    // Drawn: the renderer is given the stream and says the picture's size once frames come.
    Future<Size> drawn(MediaStream s) async {
      final r = RTCVideoRenderer();
      await r.initialize();
      r.srcObject = s;
      try {
        for (var i = 0; i < 150; i++) {
          if (r.videoWidth > 0 && r.videoHeight > 0) return Size(r.videoWidth.toDouble(), r.videoHeight.toDouble());
          await tester.pump(const Duration(milliseconds: 100));
        }
        return Size.zero;
      } finally {
        r.srcObject = null;
        await r.dispose();
      }
    }

    final sizeAtA = await drawn(atA), sizeAtB = await drawn(atB);
    debugPrint('call video: A draws B at $sizeAtA, B draws A at $sizeAtB');
    expect(sizeAtA.width, greaterThan(0), reason: 'A never drew B\'s camera');
    expect(sizeAtB.width, greaterThan(0), reason: 'B never drew A\'s camera');
    await a.stop();
    await b.stop();
  });
}
