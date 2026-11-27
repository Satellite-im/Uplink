# voicefx

What Uplink does to the microphone in a call before Opus (Matt, 2026-11-15: "build in like krisp noise
supression or other fancy noise suppression tools, add a volume slider for input and output volume with
overboosting"; RNNoise + DeepFilterNet chosen). One C library for every platform, run inside flutter_webrtc's capture
post-processing hook, 10 ms at a time, in place, on WebRTC's own floats (the 16-bit scale):

- **Noise**: RNNoise 0.2 (Xiph, BSD-3-Clause; `rnnoise/`, its `COPYING` kept), or DeepFilterNet where built with
  `VOICEFX_DEEPFILTER` and given its model; else none.
- **Gain**: 0 to 200%, a soft limiter over full scale.

Where it runs:

| Platform | Hook | Built by |
| --- | --- | --- |
| Android | `AudioProcessingController.capturePostProcessing` (android VoiceFx.kt, JNI in app/src/main/cpp) | the app's CMake |
| Mac | `AudioManager.capturePostProcessingAdapter` (macos/Runner/VoiceFx.swift) | this folder as a Swift package (Package.swift) |
| Windows | `FlutterWebRTCPluginSharedInstance()->audio_processing()` (windows/runner/voice_fx.cpp) | the runner's CMake |

`rnnoise/src/os_support.h` is ours: RNNoise 0.2's release leaves it out though vec_neon.h includes it.

Test on this computer: `native/voicefx/test/run.sh` (noise down, gain, the limiter, odd block sizes).

**music_pack** (`music_pack.c`) is not of the microphone: it packs a circle's music without loss, as FLAC frames, where it
is played from (macos/Runner/MusicLink.swift, windows/runner/spotify_sound.cpp), and lib/voice/flac.dart reads it. Test:
`native/voicefx/test/run_pack.sh` (bit for bit, and by the Mac's own FLAC decoder).
