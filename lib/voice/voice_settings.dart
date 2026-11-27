import 'package:flutter/foundation.dart';

import '../app_state.dart';

/// How calls sound and look on this device (Matt, 2026-11-15: "voice settings to change all kinds of things like
/// bitrates and sound input devices etc etc"; then "can we support 4k? and flac audio? also build in like krisp noise
/// supression or other fancy noise suppression tools, add a volume slider for input and output volume with
/// overboosting", and RNNoise with DeepFilterNet chosen for the noise): the microphone and speaker and how loud each
/// is, Opus's bit rate and stereo, Music mode, the microphone's processing, and the picture's quality. Kept with the
/// device's choices (`voice_*`).
@immutable
class VoiceSettings {
  const VoiceSettings({
    this.input = '',
    this.output = '',
    this.inputName = '',
    this.outputName = '',
    this.camera = '',
    this.cameraName = '',
    this.audioKbps = 510,
    this.stereo = true,
    this.echo = true,
    this.noise = NoiseMode.rnnoise,
    this.gain = false,
    this.music = false,
    this.inputVolume = 100,
    this.outputVolume = 100,
    this.video = 1080,
    this.duckOthers = false,
  });

  /// The microphone's and the speaker's device ids; empty for the system's own.
  final String input;
  final String output;

  /// The names the system gave them when they were chosen: a device whose id has changed since (Android numbers a USB
  /// microphone afresh each time it is plugged in) is found again by its name ([SoundChoice.resolve]).
  final String inputName;
  final String outputName;

  /// The camera's device id and the system's name for it, as the microphone's are kept (GMFB-68, Matt: "There is no
  /// way to switch or select a video device in the app or actively during a call"); empty for the system's own. A
  /// phone's front and back are changed between in the call instead (Flip camera).
  final String camera;
  final String cameraName;
  final int audioKbps;
  final bool stereo;
  final bool echo;

  /// What quiets the room: nothing, WebRTC's own, RNNoise, or DeepFilterNet (computers).
  final NoiseMode noise;
  final bool gain;

  /// Music mode: the microphone as it is (no echo cancellation, noise suppression or gain control), 510 kb/s
  /// stereo at a constant rate. What a lossless-sounding voice app sends; FLAC is not something WebRTC can carry.
  final bool music;

  /// How loud the microphone is sent and how loud others are heard, in percent: 0 to [maxVolume], over 100 boosted.
  final int inputVolume;
  final int outputVolume;

  /// The tallest picture sent: 2160 (4K), 1080, 720 or 480.
  final int video;

  /// On Windows: whether Windows may lower every other sound on the computer during a call, as it does to talking
  /// apps unless they say not to. Off unless switched on (Matt, 2026-11-21; lib/voice/ducking.dart).
  final bool duckOthers;

  static const kbpsChoices = [510, 256, 128, 64, 32];
  static const videoChoices = [2160, 1080, 720, 480];
  static const maxVolume = 200;

  /// The settings as kept in [app]'s choices, each with its default where never set.
  factory VoiceSettings.of(AppState app) => VoiceSettings(
        input: app.choice('voice_input', ''),
        output: app.choice('voice_output', ''),
        inputName: app.choice('voice_input_name', ''),
        outputName: app.choice('voice_output_name', ''),
        camera: app.choice('voice_camera', ''),
        cameraName: app.choice('voice_camera_name', ''),
        audioKbps: int.tryParse(app.choice('voice_kbps', '510')) ?? 510,
        stereo: app.flag('voice_stereo', fallback: true),
        echo: app.flag('voice_echo', fallback: true),
        // Before there was a choice of how, noise suppression was a switch for WebRTC's own.
        noise: NoiseMode.named(app.choice('voice_noise_mode', '')) ?? (app.flag('voice_noise', fallback: false) ? NoiseMode.webrtc : NoiseMode.standard),
        gain: app.flag('voice_gain', fallback: false),
        music: app.flag('voice_music', fallback: false),
        inputVolume: (int.tryParse(app.choice('voice_in_volume', '100')) ?? 100).clamp(0, maxVolume),
        outputVolume: (int.tryParse(app.choice('voice_out_volume', '100')) ?? 100).clamp(0, maxVolume),
        video: int.tryParse(app.choice('voice_video', '1080')) ?? 1080,
        duckOthers: app.flag('voice_duck_others', fallback: false),
      );

  /// With another device or volume; everything else as it is.
  VoiceSettings copyWith({String? input, String? output, String? inputName, String? outputName, String? camera, String? cameraName, int? inputVolume, int? outputVolume}) => VoiceSettings(
        input: input ?? this.input,
        output: output ?? this.output,
        inputName: inputName ?? this.inputName,
        outputName: outputName ?? this.outputName,
        camera: camera ?? this.camera,
        cameraName: cameraName ?? this.cameraName,
        audioKbps: audioKbps,
        stereo: stereo,
        echo: echo,
        noise: noise,
        gain: gain,
        music: music,
        inputVolume: inputVolume ?? this.inputVolume,
        outputVolume: outputVolume ?? this.outputVolume,
        video: video,
        duckOthers: duckOthers,
      );

  // What is used, Music mode taken into account.
  int get sendKbps => music ? 510 : audioKbps;
  bool get sendStereo => music || stereo;
  bool get useEcho => echo && !music;
  bool get useGain => gain && !music;

  /// The noise suppression used, given what this device can run ([available], VoiceFx.modes): one it cannot run
  /// falls back to WebRTC's own, and Music mode uses none.
  NoiseMode noiseOn(Set<NoiseMode> available) {
    if (music || noise == NoiseMode.off) return NoiseMode.off;
    if (noise == NoiseMode.webrtc || available.contains(noise)) return noise;
    // DeepFilterNet where it cannot run: RNNoise, the next best, before WebRTC's own.
    if (noise == NoiseMode.deepfilter && available.contains(NoiseMode.rnnoise)) return NoiseMode.rnnoise;
    return NoiseMode.webrtc;
  }

  /// The most a copy of the picture is sent at, by the quality chosen.
  int get videoCap => switch (video) { <= 480 => 1500000, <= 720 => 4000000, <= 1080 => 12000000, _ => 25000000 };

  /// The camera asked for: [video] tall at 16:9.
  ({int width, int height}) get videoSize => switch (video) {
        <= 480 => (width: 854, height: 480),
        <= 720 => (width: 1280, height: 720),
        <= 1080 => (width: 1920, height: 1080),
        _ => (width: 3840, height: 2160),
      };

  /// How a picture is sent to [others] people: one other gets the whole picture at up to [videoCap]; with more, each
  /// copy is the size it would be from 1080p (videoFor), so a 4K camera is scaled down that much further.
  ({double scale, int bitrate}) sendTo(int others, ({double scale, int bitrate, String preference}) base) {
    final tall = videoSize.height;
    if (others <= 1) return (scale: 1.0, bitrate: tall > 1080 ? videoCap : (base.bitrate < videoCap ? base.bitrate : videoCap));
    final extra = tall > 1080 ? tall / 1080 : 1.0;
    return (scale: base.scale * extra, bitrate: base.bitrate < videoCap ? base.bitrate : videoCap);
  }

  // How a bit rate and a picture height are written in Settings.
  static String kbpsLabel(int k) => k >= 510 ? '510 kb/s · the most Opus carries' : '$k kb/s';
  static String videoLabel(int q) => q >= 2160 ? '4K' : '${q}p';
}

/// Ways to quiet the room around the microphone.
enum NoiseMode {
  off('Off', 'The room as it is'),
  webrtc('Standard', 'WebRTC\'s own: steady noise like fans'),
  rnnoise('RNNoise', 'A small neural network: fans, keyboards, traffic'),
  deepfilter('DeepFilterNet', 'A larger network, near studio quality; computers');

  /// The one used until another is chosen (Matt, 2026-11-15: "on desktop use DeepFilter as default and on mobile use
  /// the RNN as default"): DeepFilterNet on a computer, which has the room for the larger network; RNNoise on a phone.
  static NoiseMode get standard => switch (defaultTargetPlatform) {
        TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => NoiseMode.deepfilter,
        _ => NoiseMode.rnnoise,
      };

  const NoiseMode(this.label, this.hint);
  final String label;
  final String hint;

  /// The mode kept or said under [name]; null for none or one this build doesn't know.
  static NoiseMode? named(String name) {
    for (final m in values) {
      if (m.name == name) return m;
    }
    return null;
  }
}
