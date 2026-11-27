import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/voice_pane.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

import 'support/list_harness.dart';

/// GMFB-68 (Matt): "There is no way to switch or select a video device in the app or actively during a call". The
/// camera chosen in Settings › Voice and video is the one video opens, asked for as each kind of computer's WebRTC
/// takes it; one that is not connected gives way to the system's own; changed in a call, the new camera's picture
/// takes the old one's place and the old camera is let go; a phone keeps its front and back (Flip camera).

/// Stands in for flutter_webrtc's devices: what each opening asked for, and a camera's stream for each.
class _Devices implements SoundDevices {
  _Devices(this.there);
  final List<MediaDeviceInfo> there;
  final opened = <Map<String, dynamic>>[];
  final streams = <_Stream>[];

  /// The next opening fails once (a camera that is already filming, on Windows).
  bool busy = false;

  @override
  Future<void> ready() async {}
  @override
  Future<List<MediaDeviceInfo>> list() async => there;
  @override
  Future<MediaStream> open(Map<String, dynamic> constraints) async {
    opened.add(constraints);
    if (busy) {
      busy = false;
      throw StateError('camera busy');
    }
    final s = _Stream('cam-${streams.length}');
    streams.add(s);
    return s;
  }

  @override
  Future<void> selectInput(String id) async {}
  @override
  Future<void> selectOutput(String id) async {}
  @override
  Future<void> speakerphone(bool on) async {}
}

class _Track implements MediaStreamTrack {
  bool stopped = false;
  @override
  String get kind => 'video';
  @override
  Future<void> stop() async => stopped = true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Stream implements MediaStream {
  _Stream(this.id);
  @override
  final String id;
  final track = _Track();
  @override
  List<MediaStreamTrack> getVideoTracks() => [track];
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

MediaDeviceInfo _d(String kind, String id, String label) => MediaDeviceInfo(kind: kind, deviceId: id, label: label);

final _cameras = [
  _d('audioinput', 'mic', 'Microphone'),
  _d('videoinput', 'facetime', 'FaceTime HD Camera'),
  _d('videoinput', 'usb-cam', 'USB Camera'),
];

Map<String, dynamic> _video(Map<String, dynamic> asked) => (asked['video'] as Map).cast<String, dynamic>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Devices devices;
  setUp(() {
    devices = _Devices(_cameras);
    RtcMedia.sound = devices;
    RtcMedia.platformForTest = 'macos';
  });
  tearDown(() {
    RtcMedia.sound = const SoundDevices();
    RtcMedia.platformForTest = null;
  });

  test('the settings keep the camera chosen and its name', () {
    final app = AppState()
      ..set('voice_camera', 'usb-cam')
      ..set('voice_camera_name', 'USB Camera');
    final v = VoiceSettings.of(app);
    expect((v.camera, v.cameraName), ('usb-cam', 'USB Camera'));
    expect(VoiceSettings.of(AppState()).camera, '');
    expect(v.copyWith(input: 'x').camera, 'usb-cam');
  });

  test('video opens the camera chosen: by deviceId on a Mac, by sourceId on Windows, and the facing one with none chosen', () async {
    final mac = RtcMedia(settings: const VoiceSettings(camera: 'usb-cam', cameraName: 'USB Camera'), light: true);
    await mac.setVideo(true);
    expect(_video(devices.opened.single)['deviceId'], 'usb-cam');
    expect(_video(devices.opened.single).containsKey('facingMode'), isFalse);
    expect(mac.localVideo.value, same(devices.streams.single));

    RtcMedia.platformForTest = 'windows';
    final pc = RtcMedia(settings: const VoiceSettings(camera: 'usb-cam'), light: true);
    await pc.setVideo(true);
    expect(_video(devices.opened.last)['optional'], [
      {'sourceId': 'usb-cam'},
    ]);
    expect(_video(devices.opened.last).containsKey('deviceId'), isFalse);

    final plain = RtcMedia(light: true);
    await plain.setVideo(true);
    expect(_video(devices.opened.last)['facingMode'], 'user');
    expect(_video(devices.opened.last).containsKey('optional'), isFalse);
  });

  test('a camera that is not connected gives way to the system\'s own, and one whose id changed is found by its name', () async {
    final gone = RtcMedia(settings: const VoiceSettings(camera: 'old-cam', cameraName: 'Old Camera'), light: true);
    await gone.setVideo(true);
    expect(_video(devices.opened.last)['facingMode'], 'user');
    expect(gone.cameraMissing, isTrue);
    final renamed = RtcMedia(settings: const VoiceSettings(camera: 'usb-cam-before', cameraName: 'USB Camera'), light: true);
    await renamed.setVideo(true);
    expect(_video(devices.opened.last)['deviceId'], 'usb-cam');
    expect(renamed.cameraMissing, isFalse);
  });

  test('changed in a call, the new camera takes the old one\'s place and the old one is let go', () async {
    final m = RtcMedia(light: true);
    await m.setVideo(true);
    final first = devices.streams.single;
    final seen = <MediaStream?>[];
    m.localVideo.addListener(() => seen.add(m.localVideo.value));
    await m.setCamera('usb-cam', name: 'USB Camera');
    expect(devices.streams, hasLength(2));
    expect(_video(devices.opened.last)['deviceId'], 'usb-cam');
    expect(m.localVideo.value, same(devices.streams.last));
    expect(seen, [devices.streams.last]);
    expect(first.track.stopped, isTrue);
    expect(devices.streams.last.track.stopped, isFalse);
    expect((m.settings.camera, m.settings.cameraName), ('usb-cam', 'USB Camera'));
  });

  test('with video off only the choice changes, and video then opens it', () async {
    final m = RtcMedia(light: true);
    await m.setCamera('usb-cam', name: 'USB Camera');
    expect(devices.opened, isEmpty);
    await m.setVideo(true);
    expect(_video(devices.opened.single)['deviceId'], 'usb-cam');
  });

  test('a camera that opens once only: the old picture is let go, then the new one opened', () async {
    final m = RtcMedia(light: true);
    await m.setVideo(true);
    final first = devices.streams.single;
    devices.busy = true;
    await m.setCamera('facetime', name: 'FaceTime HD Camera');
    expect(first.track.stopped, isTrue);
    expect(devices.opened, hasLength(3));
    expect(m.localVideo.value, same(devices.streams.last));
  });

  test('a phone chooses no camera by name: its front and back are flipped between', () async {
    RtcMedia.platformForTest = 'android';
    expect(RtcMedia.choosesCamera, isFalse);
    final m = RtcMedia(settings: const VoiceSettings(camera: 'usb-cam'), light: true);
    await m.setVideo(true);
    expect(_video(devices.opened.single)['facingMode'], 'user');
    expect(_video(devices.opened.single).containsKey('deviceId'), isFalse);
  });

  testWidgets('Settings › Voice and video has Camera beside the microphone, listing the cameras there are', (tester) async {
    RtcMedia.enumerate = () async => _cameras;
    addTearDown(() => RtcMedia.enumerate = null);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), null));
    final sheet = await loadSheet(tester);
    final app = AppState()
      ..set('voice_camera', 'usb-cam')
      ..set('voice_camera_name', 'USB Camera');
    await pumpScreen(tester, sheet, const SingleChildScrollView(child: VoicePane()), app, size: const Size(900, 1400));
    expect(find.text('Camera'), findsOneWidget);
    // The one chosen is named on the row.
    expect(find.text('USB Camera'), findsOneWidget);
    await tester.tap(find.text('Camera'));
    await settle(tester);
    expect(find.text('FaceTime HD Camera'), findsOneWidget);
    expect(find.text('✓  USB Camera'), findsOneWidget);
    expect(find.text('The system\'s own'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
