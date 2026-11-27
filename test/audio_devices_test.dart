import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

/// Matt, 2026-11-23: "switching input and output devices doesn't work we have to switch them on the physical settings
/// on the operating system for them to change, it seems to only use the default device". The microphone and the
/// speaker chosen are told to WebRTC when a call starts and when changed in one, the new microphone's track takes the
/// old one's place in every connection, a device that is not connected gives way to the system's own (and says so),
/// and going back to the system's own is told to WebRTC too. The real devices on a Mac: integration_test/audio_devices_test.dart.

/// Stands in for flutter_webrtc's sound devices, writing down each thing asked of it in order.
class _Sound implements SoundDevices {
  _Sound(this.there);
  List<MediaDeviceInfo> there;
  final asked = <String>[];
  final opened = <Map<String, dynamic>>[];
  final streams = <_Stream>[];

  @override
  Future<void> ready() async => asked.add('ready');

  @override
  Future<List<MediaDeviceInfo>> list() async {
    asked.add('list');
    return there;
  }

  @override
  Future<MediaStream> open(Map<String, dynamic> constraints) async {
    asked.add('open');
    opened.add(constraints);
    final s = _Stream('mic-${streams.length}');
    streams.add(s);
    return s;
  }

  @override
  Future<void> selectInput(String id) async => asked.add('input:$id');

  @override
  Future<void> selectOutput(String id) async => asked.add('output:$id');

  @override
  Future<void> speakerphone(bool on) async => asked.add('speakerphone:$on');
}

class _Track implements MediaStreamTrack {
  _Track(this.id);
  @override
  final String id;
  @override
  bool enabled = true;
  bool stopped = false;
  @override
  String get kind => 'audio';
  @override
  Future<void> stop() async => stopped = true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Stream implements MediaStream {
  _Stream(this.name) : track = _Track('$name-track');
  final String name;
  final _Track track;
  @override
  String get id => name;
  @override
  List<MediaStreamTrack> getAudioTracks() => [track];
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Sender implements RTCRtpSender {
  _Sender(this._track);
  MediaStreamTrack? _track;
  final replaced = <MediaStreamTrack?>[];
  @override
  MediaStreamTrack? get track => _track;
  @override
  Future<void> replaceTrack(MediaStreamTrack? t) async {
    replaced.add(t);
    _track = t;
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Connection implements RTCPeerConnection {
  _Connection(this._senders);
  final List<_Sender> _senders;
  @override
  Future<List<RTCRtpSender>> getSenders() async => _senders;
  @override
  Future<void> close() async {}
  // A closed connection is also let go of by the platform (rtc.dart's close, GMFB-52).
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

MediaDeviceInfo _d(String kind, String id, String label) => MediaDeviceInfo(kind: kind, deviceId: id, label: label);

/// The Mac's devices once WebRTC's sound has started: the system's own as "default", then each one.
final _mac = [
  _d('audioinput', 'default', 'MacBook Air Microphone'),
  _d('audioinput', 'BuiltInMicrophoneDevice', 'MacBook Air Microphone'),
  _d('audioinput', 'usb-mic-uid', 'USB Microphone'),
  _d('audiooutput', 'default', 'MacBook Air Speakers'),
  _d('audiooutput', 'BuiltInSpeakerDevice', 'MacBook Air Speakers'),
  _d('audiooutput', 'headset-uid', 'USB Headset'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Sound sound;
  setUp(() {
    sound = _Sound(_mac);
    RtcMedia.sound = sound;
    RtcMedia.platformForTest = 'macos';
  });
  tearDown(() {
    RtcMedia.sound = const SoundDevices();
    RtcMedia.platformForTest = null;
    RtcMedia.connect = null;
  });

  test('a call starts with the microphone and the speaker chosen, each told to WebRTC once it knows every device', () async {
    final m = RtcMedia(settings: const VoiceSettings(input: 'usb-mic-uid', output: 'headset-uid'), light: true);
    await m.start();
    expect(sound.asked, containsAllInOrder(['list', 'input:usb-mic-uid', 'open', 'list', 'output:headset-uid']));
    expect((sound.opened.single['audio'] as Map)['deviceId'], 'usb-mic-uid');
    expect(m.inputMissing, isFalse);
    expect(m.outputMissing, isFalse);
    await m.stop();
  });

  test('the system\'s own is chosen as the Mac\'s "default", so it follows System Settings, and nothing is asked of the track', () async {
    final m = RtcMedia(settings: const VoiceSettings(), light: true);
    await m.start();
    expect(sound.asked, containsAllInOrder(['input:default', 'open', 'output:default']));
    expect((sound.opened.single['audio'] as Map).containsKey('deviceId'), isFalse);
    await m.stop();
  });

  test('a device that is not connected gives way to the system\'s own, and says so', () async {
    final m = RtcMedia(settings: const VoiceSettings(input: 'gone-mic', inputName: 'Old Mic', output: 'gone-out'), light: true);
    await m.start();
    expect(sound.asked, containsAllInOrder(['input:default', 'open', 'output:default']));
    expect(sound.asked, isNot(contains('input:gone-mic')));
    expect(m.inputMissing, isTrue);
    expect(m.outputMissing, isTrue);
    await m.stop();
  });

  test('a device whose id changed is found again by its name', () {
    final there = [_d('audioinput', '17', 'Blue Yeti'), _d('audioinput', 'microphone-bottom', 'Built-in Microphone (bottom)')];
    expect(DeviceChoice.resolve('12', 'Blue Yeti', there).id, '17');
    expect(DeviceChoice.resolve('12', 'Blue Yeti', there).missing, isFalse);
    expect(DeviceChoice.resolve('12', 'Nothing here', there).missing, isTrue);
    expect(DeviceChoice.resolve('', '', there).id, '');
    // The Mac's "default" carries the name of the device it is now: never taken for the one chosen.
    expect(DeviceChoice.resolve('old', 'MacBook Air Microphone', _mac).id, 'BuiltInMicrophoneDevice');
  });

  test('a microphone chosen in a call takes the old one\'s place in every connection, without leaving the call', () async {
    final senders = <_Sender>[];
    RtcMedia.connect = (config) async {
      final s = _Sender(_Track('old-track'));
      senders.add(s);
      return _Connection([s]);
    };
    final m = RtcMedia(settings: const VoiceSettings(), light: true);
    await m.start();
    final first = sound.streams.single;
    first.track.enabled = false; // muted: stays muted on the new microphone
    for (final id in ['a', 'b']) {
      await (m.peer(id, onCandidate: (_) {}) as dynamic).pc;
    }
    sound.asked.clear();
    await m.setInput('usb-mic-uid', name: 'USB Microphone');
    expect(sound.asked, containsAllInOrder(['list', 'input:usb-mic-uid', 'open']));
    expect((sound.opened.last['audio'] as Map)['deviceId'], 'usb-mic-uid');
    final fresh = sound.streams.last.track;
    expect(senders, hasLength(2));
    for (final s in senders) {
      expect(s.replaced, [fresh], reason: 'each connection sends the new microphone');
    }
    expect(fresh.enabled, isFalse, reason: 'muted stays muted');
    expect(first.track.stopped, isTrue, reason: 'the old microphone is let go');
    expect(m.settings.inputName, 'USB Microphone');

    // Back to the system's own, in the call.
    sound.asked.clear();
    await m.setInput('');
    expect(sound.asked, containsAllInOrder(['input:default', 'open']));
    await m.stop();
  });

  test('a speaker chosen in a call is told to WebRTC at once, and so is going back to the system\'s own', () async {
    final m = RtcMedia(settings: const VoiceSettings(), light: true);
    await m.start();
    sound.asked.clear();
    await m.setOutput('headset-uid', name: 'USB Headset');
    expect(sound.asked, ['list', 'output:headset-uid']);
    sound.asked.clear();
    await m.setOutput('');
    expect(sound.asked, ['list', 'output:default']);
    await m.stop();
  });

  test('Windows: the microphone by sourceId and the speaker by deviceId, and the system\'s own is the first listed', () async {
    RtcMedia.platformForTest = 'windows';
    sound.there = [
      _d('audioinput', '{mic-1}', 'Microphone (Realtek)'),
      _d('audioinput', '{mic-2}', 'Headset Microphone'),
      _d('audiooutput', '{out-1}', 'Speakers (Realtek)'),
      _d('audiooutput', '{out-2}', 'Headphones'),
    ];
    final m = RtcMedia(settings: const VoiceSettings(input: '{mic-2}', output: '{out-2}'), light: true);
    await m.start();
    final audio = sound.opened.single['audio'] as Map;
    expect(audio['optional'], [
      {'sourceId': '{mic-2}'},
    ]);
    expect(audio['deviceId'], '{out-2}');
    expect(sound.asked, containsAllInOrder(['input:{mic-2}', 'output:{out-2}', 'open']));
    sound.asked.clear();
    await m.setOutput('');
    expect(sound.asked, ['list', 'output:{out-1}']);
    await m.stop();
  });

  test('Android: the chosen microphone is told to WebRTC (a track\'s deviceId is not read there), the system\'s own speaker is the loudspeaker', () async {
    RtcMedia.platformForTest = 'android';
    sound.there = [
      _d('audioinput', 'audio-1', 'Audio'),
      _d('audioinput', 'microphone-bottom', 'Built-in Microphone (bottom)'),
      _d('audioinput', '23', 'USB Audio'),
      _d('audiooutput', 'speaker', 'Speakerphone'),
      _d('audiooutput', 'wired-headset', 'Wired headset'),
    ];
    final m = RtcMedia(settings: const VoiceSettings(input: '23'), light: true);
    await m.start();
    expect(sound.asked, containsAllInOrder(['input:23', 'open', 'speakerphone:true']));
    sound.asked.clear();
    await m.setOutput('wired-headset', name: 'Wired headset');
    expect(sound.asked, ['list', 'output:wired-headset']);
    sound.asked.clear();
    // Back to the system's own after one was chosen: the built-in microphone, as WebRTC keeps the one it was told.
    await m.setInput('');
    expect(sound.asked, containsAllInOrder(['input:microphone-bottom', 'open']));
    await m.stop();
  });
}
