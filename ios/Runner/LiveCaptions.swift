import AVFoundation
import Foundation
import Speech
#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif

/// This device's own voice in a call, written out as it is said, for the call's captions, on the Mac and the iPhone
/// (the same file in macos/Runner and ios/Runner; lib/voice/captions.dart; Matt, 2026-11-19: "Live captions"). The
/// voice VoiceFx has just cleaned is handed here ([feed]) and appended to an on-device speech request; what it hears
/// goes to Dart as it comes and as each line ends. A request is ended and a new one begun every 50 seconds (Apple's
/// speech requests run about a minute).
final class LiveCaptions: NSObject {
  static let shared = LiveCaptions()
  private var channel: FlutterMethodChannel?
  private let lock = NSLock()
  private var on = false
  private var muted = false
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  /// When the request now open was begun: [feed] ends one older than 50 seconds.
  private var began = Date()
  private var format: AVAudioFormat?

  /// The `ghost/captions` channel: available, start (in a language, once speech recognition is allowed), stop and
  /// muted; `heard` goes back to Dart.
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/captions", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "available":
        result(SFSpeechRecognizer()?.supportsOnDeviceRecognition ?? false)
      case "start":
        let language = args["language"] as? String
        SFSpeechRecognizer.requestAuthorization { status in
          DispatchQueue.main.async { result(status == .authorized && self.start(language: language)) }
        }
      case "stop":
        self.stop()
        result(true)
      case "muted":
        self.lock.lock()
        self.muted = args["on"] as? Bool ?? false
        self.lock.unlock()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Turns captions on, in [language] where the device knows it, else its own; false with no on-device recognition.
  private func start(language: String?) -> Bool {
    let r = (language.map { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()) ?? SFSpeechRecognizer()
    guard let r, r.supportsOnDeviceRecognition else { return false }
    lock.lock()
    recognizer = r
    on = true
    lock.unlock()
    begin()
    return true
  }

  private func stop() {
    lock.lock()
    on = false
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    lock.unlock()
  }

  /// A new request, the one before ended.
  private func begin() {
    lock.lock()
    defer { lock.unlock() }
    guard on, let recognizer else { return }
    request?.endAudio()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = true
    request = req
    began = Date()
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self else { return }
      if let result {
        let words = result.bestTranscription.formattedString
        if !words.isEmpty { self.say(words, done: result.isFinal) }
      }
      if error != nil || (result?.isFinal ?? false) {
        // Ended: a fresh one, while captions are on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          guard let self else { return }
          self.lock.lock()
          let ended = self.request === req
          self.lock.unlock()
          if ended { self.begin() }
        }
      }
    }
  }

  /// Tells Dart what was heard: [done] false for a line still being said, true once it has ended.
  private func say(_ words: String, done: Bool) {
    DispatchQueue.main.async { self.channel?.invokeMethod("heard", arguments: ["text": words, "done": done]) }
  }

  /// From VoiceFx's capture hook, on WebRTC's audio thread: one block of this device's voice, floats on the 16-bit
  /// scale.
  func feed(_ samples: UnsafeMutablePointer<Float>, frames: Int, rate: Int) {
    lock.lock()
    guard on, let req = request, frames > 0, rate > 0 else { lock.unlock(); return }
    let silent = muted
    let long = Date().timeIntervalSince(began) > 50
    if format?.sampleRate != Double(rate) { format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) }
    let fmt = format
    lock.unlock()
    guard let fmt, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    let dst = buffer.floatChannelData![0]
    for i in 0..<frames { dst[i] = silent ? 0 : samples[i] / 32768 }
    req.append(buffer)
    if long {
      // The words so far come back as a finished line, and a new request goes on.
      begin()
    }
  }
}
