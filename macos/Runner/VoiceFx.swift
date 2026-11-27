import FlutterMacOS
import Accelerate
import Foundation
import os
import VoiceFxC
import WebRTC
import flutter_webrtc

/// What is done to the microphone before Opus, on the Mac (lib/voice/voice_fx.dart; Matt, 2026-11-15: "build in like
/// krisp noise supression or other fancy noise suppression tools, add a volume slider for input ... with
/// overboosting"): RNNoise, DeepFilterNet where its model is in the app, and the gain, from native/voicefx, run in
/// flutter_webrtc's capture post-processing hook on WebRTC's audio thread.
final class VoiceFx: NSObject, ExternalAudioProcessingDelegate {
  static let shared = VoiceFx()
  private let fx = voicefx_create()
  private var attached = false
  private var channel: FlutterMethodChannel?
  private var ducking: FlutterMethodChannel?
  /// The loudest sample since "level" was last asked, on the 0 to 1 scale, and what guards it (WebRTC's audio thread
  /// writes it, the main thread reads it).
  private var peak: Float = 0
  private let peakLock: os_unfair_lock_t = {
    let l = os_unfair_lock_t.allocate(capacity: 1)
    l.initialize(to: os_unfair_lock())
    return l
  }()

  private override init() {
    super.init()
    // DeepFilterNet, where this build has it (native/voicefx/deepfilter): its model is built in, made ready once, off
    // the main thread. A build without it answers 0 and offers RNNoise alone.
    DispatchQueue.global(qos: .utility).async { [fx] in _ = voicefx_deepfilter_model(fx, "") }
  }

  /// The `ghost/voicefx` channel: modes (what this build can do) and configure (the mode and the gain, 1 for as it is).
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/voicefx", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "modes":
        let bits = voicefx_modes(self.fx)
        var modes: [String] = []
        if bits & (1 << 1) != 0 { modes.append("rnnoise") }
        if bits & (1 << 2) != 0 { modes.append("deepfilter") }
        modes.append("live")
        modes.append("effects")
        modes.append("level")
        modes.append("aside")
        result(modes)
      // A voice effect made here as it is said (lib/voice/live_changer.dart, native/voicefx voicefx_effect).
      case "effect":
        let args = call.arguments as? [String: Any] ?? [:]
        voicefx_effect(self.fx, voicefx_effect_id(args["name"] as? String ?? "none"))
        result(self.attach())
      // Live voice changing (lib/voice/live_changer.dart): what was said, taken; the changed voice, fed.
      case "live":
        let args = call.arguments as? [String: Any] ?? [:]
        voicefx_live(self.fx, (args["on"] as? Bool ?? false) ? 1 : 0)
        result(self.attach())
      case "take":
        let args = call.arguments as? [String: Any] ?? [:]
        let most = max(1, args["most"] as? Int ?? 32000)
        var buf = [Int16](repeating: 0, count: most)
        let n = Int(buf.withUnsafeMutableBufferPointer { voicefx_take(self.fx, $0.baseAddress, Int32(most)) })
        result(FlutterStandardTypedData(bytes: buf.prefix(n).withUnsafeBufferPointer { Data(buffer: $0) }))
      case "feed":
        let args = call.arguments as? [String: Any] ?? [:]
        if let pcm = (args["pcm"] as? FlutterStandardTypedData)?.data, pcm.count >= 2 {
          let rate = Int32(args["rate"] as? Int ?? 24000)
          pcm.withUnsafeBytes { raw in
            if let p = raw.bindMemory(to: Int16.self).baseAddress { voicefx_feed(self.fx, p, Int32(pcm.count / 2), rate) }
          }
        }
        result(Int(voicefx_queued_ms(self.fx)))
      case "queued":
        result(Int(voicefx_queued_ms(self.fx)))
      case "level":
        // The loudest the microphone has been since last asked, 0 to 1 (GMFB-20: the microphone test, with no meter).
        os_unfair_lock_lock(self.peakLock)
        let p = self.peak
        self.peak = 0
        os_unfair_lock_unlock(self.peakLock)
        result(Double(min(1, p)))
      // Closing a connection waits for WebRTC to stop its sound, and the system takes seconds over that (the audio
      // engine and its voice processing taken down). flutter_webrtc closes on the main thread, so the window froze as a
      // call ended (Matt, 2026-11-24: "it lagged on the call end"; sampled on his MacBook Air: the main thread 2.6 s
      // in PeerConnection::Close). Closed here first, on another thread; the plugin's own close, asked for right after
      // (lib/voice/rtc.dart, RtcMedia.closeConnection), finds it closed and comes straight back.
      case "closeConnection":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let id = args["id"] as? String,
              let connection = FlutterWebRTCPlugin.sharedSingleton()?.peerConnections?.object(forKey: id) as? RTCPeerConnection
        else {
          result(false)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          connection.close()
          DispatchQueue.main.async { result(true) }
        }
      case "configure":
        let args = call.arguments as? [String: Any] ?? [:]
        let mode: Int32 = switch args["mode"] as? String { case "rnnoise": 1; case "deepfilter": 2; default: 0 }
        voicefx_configure(self.fx, mode, Float(args["gain"] as? Double ?? 1))
        result(self.attach())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel

    // Whether other apps are turned down in a call (lib/voice/ducking.dart; Matt, 2026-11-25: "when i'm playing the audio
    // on spotify while in a call it makes spotify quieter"). Apple's voice processing does it, as WebRTC's sound device
    // asks: left to itself it lowers everything else, and again whenever someone speaks. Told aside: the sound device
    // answers on its own thread, and the window is not kept waiting for it. Nothing to tell before the first call.
    let ducking = FlutterMethodChannel(name: "ghost/ducking", binaryMessenger: messenger)
    ducking.setMethodCallHandler { call, result in
      guard call.method == "set" else { return result(FlutterMethodNotImplemented) }
      let leave = (call.arguments as? [String: Any])?["leaveOthers"] as? Bool ?? true
      guard let sound = FlutterWebRTCPlugin.sharedSingleton()?.peerConnectionFactory?.audioDeviceModule else { return result(0) }
      DispatchQueue.global(qos: .userInitiated).async {
        sound.isAdvancedDuckingEnabled = false
        sound.duckingLevel = leave ? .min : .default
        DispatchQueue.main.async { result(1) }
      }
    }
    self.ducking = ducking
  }

  /// Into flutter_webrtc's capture hook, once.
  private func attach() -> Bool {
    if attached { return true }
    AudioManager.sharedInstance().capturePostProcessingAdapter.addProcessing(self)
    attached = true
    return true
  }

  func audioProcessingInitialize(withSampleRate sampleRateHz: Int, channels: Int) {}

  /// One block of the microphone, on WebRTC's audio thread. WebRTC hands 10 ms at a time, so the rate is a hundred
  /// times the frames in a block.
  func audioProcessingProcess(_ audioBuffer: RTCAudioBuffer) {
    let frames = audioBuffer.frames
    guard frames > 0, audioBuffer.channels > 0 else { return }
    // The first channel is cleaned; any other is given the same, so a stereo microphone stays one voice.
    let first = audioBuffer.rawBuffer(forChannel: 0)
    voicefx_process(fx, first, Int32(frames), Int32(frames * 100))
    // The block's loudest sample, as it is after voicefx, kept for when "level" is next asked.
    var loudest: Float = 0
    vDSP_maxmgv(first, 1, &loudest, vDSP_Length(frames))
    os_unfair_lock_lock(peakLock)
    peak = max(peak, loudest / 32768)
    os_unfair_lock_unlock(peakLock)
    // The voice as it is sent, for a recording of the call being made here (CallRecorder.swift).
    CallRecorder.shared.mic(first, frames: frames, rate: frames * 100)
    // And for the call's captions, where they are on (LiveCaptions.swift).
    LiveCaptions.shared.feed(first, frames: frames, rate: frames * 100)
    for c in 1..<max(1, audioBuffer.channels) {
      audioBuffer.rawBuffer(forChannel: c).update(from: first, count: frames)
    }
  }

  func audioProcessingRelease() {}
}
