import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ghost_messaging/platform_info.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_video.dart';
import 'package:integration_test/integration_test.dart';

/// A recording with video made by the app itself, on a Mac or on Windows, from a real connection (GMFB-42: "Stays In progress until a Mac
/// has recorded a real call"): a browser sends this app a voice, a camera and a second picture standing in for a
/// shared screen over WebRTC, and the recorder's native half (macos/Runner/CallRecorder.swift and CallVideo.swift, or
/// windows/runner/call_recorder.cpp and call_video.cpp) is
/// told what lib/voice/recorder.dart tells it in a call: the voice tapped, the picture begun, laid out three ways
/// (a grid, a screen large, a grid of three), ended and put into the MP4 after the voices.
///
/// On Windows it is run by GitHub (.github/workflows/messaging-windows-video-check.yml: push the branch
/// `windows-video-check`), which keeps the recording to be looked at.
///
/// Nothing of the person's is used: no camera or microphone of this computer (it only receives), no account, no relay, and
/// the files go where REC_DIR says. It is half of a run; the other half is tool/voicebench/video_peer.mjs, a
/// Chromium with stand-in devices, which opens the page this serves:
///
///     node tool/voicebench/video_peer.mjs 47931 &
///     flutter test integration_test/recording_video_native_test.dart -d macos \
///       --dart-define=REC_DIR=<a scratch folder> --dart-define=REC_PORT=47931        (-d windows on a PC)
///
/// It prints `REC-VIDEO-FILE <path>`: read it with ffprobe, and look at frames of it
/// (`ffmpeg -ss 2 -i <path> -frames:v 1 a.png`, and at 6 and 10 seconds for the other two layouts).
const _dir = String.fromEnvironment('REC_DIR');
const _port = int.fromEnvironment('REC_PORT', defaultValue: 47931);

const _page = r'''<!doctype html><meta charset="utf-8"><title>peer</title><body><script>
(async () => {
  const say = (s) => fetch('/say', {method: 'POST', body: s}).catch(() => {});
  try {
    const cam = await navigator.mediaDevices.getUserMedia({video: {width: 640, height: 480}, audio: true});
    // A second picture, of another shape, as a shared screen is: words and a bar that moves.
    const c = document.createElement('canvas');
    c.width = 1600; c.height = 900;
    const g = c.getContext('2d');
    let n = 0;
    setInterval(() => {
      n++;
      g.fillStyle = '#12303f'; g.fillRect(0, 0, c.width, c.height);
      g.fillStyle = '#ffd24a'; g.fillRect((n * 12) % c.width, 700, 160, 120);
      g.fillStyle = '#ffffff'; g.font = '120px sans-serif'; g.fillText('SHARED SCREEN ' + n, 120, 400);
      g.strokeStyle = '#ff5c8a'; g.lineWidth = 12; g.strokeRect(6, 6, c.width - 12, c.height - 12);
    }, 66);
    const screen = c.captureStream(15);
    const pc = new RTCPeerConnection();
    for (const t of cam.getTracks()) pc.addTrack(t, cam);
    pc.addTrack(screen.getVideoTracks()[0], screen);
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise((done) => {
      if (pc.iceGatheringState === 'complete') return done();
      pc.addEventListener('icegatheringstatechange', () => pc.iceGatheringState === 'complete' && done());
      setTimeout(done, 5000);
    });
    const r = await fetch('/offer', {method: 'POST', body: JSON.stringify({
      sdp: pc.localDescription.sdp,
      voice: cam.getAudioTracks()[0].id, camera: cam.getVideoTracks()[0].id, screen: screen.getVideoTracks()[0].id,
    })});
    await pc.setRemoteDescription({type: 'answer', sdp: (await r.json()).sdp});
    pc.addEventListener('connectionstatechange', () => say('peer ' + pc.connectionState));
    // Open until the recording is made.
    for (;;) {
      await new Promise((d) => setTimeout(d, 1000));
      const done = await fetch('/done').then((r) => r.text()).catch(() => 'yes');
      if (done === 'yes') { document.title = 'done'; break; }
    }
  } catch (e) { say('peer failed: ' + e); document.title = 'done'; }
})();
</script>''';

void _say(String what) {
  // ignore: avoid_print
  print('REC-VIDEO $what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost/recorder');

  testWidgets('a voice, a camera and a screen received from a browser are recorded into one MP4', (tester) async {
    expect(_dir, isNotEmpty, reason: 'REC_DIR names the folder the recording is made in');
    final dir = Directory('$_dir/take-${DateTime.now().millisecondsSinceEpoch}')..createSync(recursive: true);

    // The page, and what it and this say to each other.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, _port);
    final offered = Completer<Map<String, dynamic>>();
    final answered = Completer<String>();
    var done = false;
    server.listen((q) async {
      final r = q.response;
      switch (q.uri.path) {
        case '/':
          r.headers.contentType = ContentType.html;
          r.write(_page);
        case '/offer':
          offered.complete(jsonDecode(await utf8.decoder.bind(q).join()) as Map<String, dynamic>);
          r.headers.contentType = ContentType.json;
          r.write(jsonEncode({'sdp': await answered.future}));
        case '/say':
          _say(await utf8.decoder.bind(q).join());
        case '/done':
          r.write(done ? 'yes' : 'no');
        default:
          r.statusCode = 404;
      }
      await r.close();
    });
    _say('waiting for the browser at http://127.0.0.1:$_port/');
    final offer = await offered.future.timeout(const Duration(minutes: 5));

    // This app's side: it sends nothing, and takes what comes.
    final pc = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    final got = <String, String>{};
    pc.onTrack = (e) => got[e.track.id ?? ''] = e.track.kind ?? '';
    final connected = Completer<void>();
    pc.onConnectionState = (s) {
      _say('here $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && !connected.isCompleted) connected.complete();
    };
    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !gathered.isCompleted) gathered.complete();
    };
    await pc.setRemoteDescription(RTCSessionDescription(offer['sdp'] as String, 'offer'));
    await pc.setLocalDescription(await pc.createAnswer());
    await gathered.future.timeout(const Duration(seconds: 6), onTimeout: () {});
    answered.complete((await pc.getLocalDescription())!.sdp!);
    await connected.future.timeout(const Duration(seconds: 30));

    final voice = offer['voice'] as String, camera = offer['camera'] as String, screen = offer['screen'] as String;
    _say('tracks received: $got');
    expect(got[voice], 'audio');
    expect(got[camera], 'video');
    expect(got[screen], 'video');
    // Frames on their way before anything is recorded.
    await Future<void>.delayed(const Duration(seconds: 2));

    // The recording, told as lib/voice/recorder.dart tells it.
    final mine = '${dir.path}/me.pcm', hers = '${dir.path}/maya.pcm';
    // As lib/voice/recorder.dart names it: an MP4 on Windows, whose writer goes by the name's ending.
    final picture = PlatformInfo.isWindows ? '${dir.path}/video.mp4' : '${dir.path}/video.mov';
    expect(await channel.invokeMethod('start', {'mic': mine, 'muted': true}), isTrue);
    expect(await channel.invokeMethod('add', {'key': 'maya', 'track': voice, 'path': hers}), isTrue);
    expect(
      await channel.invokeMethod('video.start', {'path': picture, 'width': RecordingVideo.width, 'height': RecordingVideo.height, 'fps': RecordingVideo.fps, 'bitrate': RecordingVideo.bitrate}),
      isTrue,
    );

    Future<List<Object?>> lay(List<VideoFace> faces) async {
      final layout = RecordingVideo.layout(faces);
      final plate = await RecordingVideo.plate(layout);
      final missing = await channel.invokeMethod<Object?>('video.layout', {'plate': plate, 'width': layout.width, 'height': layout.height, 'tiles': layout.toNative()});
      return missing is List ? missing : const [];
    }

    const me = VideoFace(key: 'me', name: 'Matt');
    // Four seconds each: the two in a grid, her camera on; her screen large; three in a grid with both pictures.
    expect(await lay([me, VideoFace(key: 'maya', name: 'Maya', track: camera, mark: '1')]), isEmpty);
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(await lay([me, VideoFace(key: 'maya', name: 'Maya', track: screen, mark: '1', screen: true)]), isEmpty);
    await Future<void>.delayed(const Duration(seconds: 4));
    final missing = await lay([
      me,
      VideoFace(key: 'maya', name: 'Maya', track: camera, mark: '1'),
      VideoFace(key: 'sam', name: 'Sam', track: screen, mark: '2'),
      const VideoFace(key: 'ana', name: 'Ana', track: 'no-such-track', mark: '3'),
    ]);
    // A track the app does not hold is said back, and its tile is its name.
    expect(missing, ['no-such-track']);
    await Future<void>.delayed(const Duration(seconds: 4));

    final ended = await channel.invokeMethod<Object?>('video.stop');
    final frames = ended is Map ? (ended['frames'] as num?)?.toInt() ?? 0 : 0;
    final counts = await channel.invokeMethod<Map>('stop');
    _say('frames $frames, samples $counts');
    // Twelve seconds at fifteen a second, less what a busy Mac drops.
    expect(frames, greaterThan(120));
    expect((counts?['maya'] as num?)?.toInt() ?? 0, greaterThan(48000 * 10));

    final mix = '${dir.path}/mix.pcm';
    mixPcm([mine, hers], mix);
    final out = '${dir.path}/recording.mp4';
    final pictured = await CallRecorder.makeMp4([mix, mine, hers], out, ['Everyone', 'Matt', 'Maya'], work: dir.path, video: picture);
    expect(pictured, isTrue, reason: 'the picture went into the MP4');
    expect(File(out).lengthSync(), greaterThan(100000));
    _say('her voice: ${_loud(hers)} of its samples are not silence');
    // ignore: avoid_print
    print('REC-VIDEO-FILE $out ${File(out).lengthSync()}');

    done = true;
    await Future<void>.delayed(const Duration(seconds: 2));
    await pc.close();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// The share of [path]'s samples (16-bit) that are not near silence, as a percentage in words.
String _loud(String path) {
  final b = File(path).readAsBytesSync().buffer.asInt16List();
  if (b.isEmpty) return 'none';
  var n = 0;
  for (final s in b) {
    if (s.abs() > 200) n++;
  }
  return '${(100 * n / b.length).toStringAsFixed(1)}%';
}
