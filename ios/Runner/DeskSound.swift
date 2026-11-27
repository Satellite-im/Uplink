// The Mac's DeskSound.swift (macos/Runner), for the iPhone: the same recorder and player, with iOS's audio session.
import AVFoundation
import Flutter
import UIKit

/// Voice messages on the iPhone, as the Mac's are (Matt, 2026-11-14: "Add an emoji picker, file upload, voice memo and
/// sticker selector to the desktop app as well"): recording one with the microphone, and playing one. What is
/// recorded here is what Android's half records (android/.../Voice.kt): AAC in an `.m4a`, speech at 24 kbit/s.
///
/// The microphone is open only between `start` and `stop` or `cancel`. iOS asks for it the first time
/// (NSMicrophoneUsageDescription). A recording is written to this
/// run's folder in the temporary directory (DeskVideo's, removed as the app opens and quits), read back when it
/// stops, and removed at once.
final class DeskSound: NSObject, AVAudioPlayerDelegate {
  static let shared = DeskSound()

  // MARK: recording

  private var recorder: AVAudioRecorder?
  private var file: URL?
  /// The most bytes a recording may weigh (0 for no limit), and whether this one has reached it.
  private var most = 0
  private var full = false

  /// Starts recording, asking iOS for the microphone first where it has not been asked: `ok`, or `denied`.
  func start(most bytes: Int, done: @escaping ([String: Any]) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      done(begin(most: bytes))
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { allowed in
        DispatchQueue.main.async { done(allowed ? self.begin(most: bytes) : ["ok": false, "denied": true]) }
      }
    default:
      done(["ok": false, "denied": true])
    }
  }

  /// The recording itself, once the microphone is allowed: AAC in an .m4a, 16 kHz mono at 24 kbit/s.
  private func begin(most bytes: Int) -> [String: Any] {
    cancel()
    guard let url = try? DeskVideo.place(named: "voice-\(UUID().uuidString).m4a") else { return ["ok": false, "error": "The recording has nowhere to go"] }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 24000,
    ]
    // iOS records only once the session allows it; a call (WebRTC) sets its own and is not in the way here.
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
    try? AVAudioSession.sharedInstance().setActive(true)
    guard let made = try? AVAudioRecorder(url: url, settings: settings) else { return ["ok": false, "error": "The microphone could not be started"] }
    made.isMeteringEnabled = true
    guard made.record() else { return ["ok": false, "error": "The microphone could not be started"] }
    recorder = made
    file = url
    most = bytes
    full = false
    return ["ok": true]
  }

  /// How loud it is now (0 to 1), and whether the recording has reached what a message may weigh: it records no
  /// more from there, as the phone's own stops itself.
  func level() -> [String: Any] {
    guard let recorder else { return ["level": 0.0, "full": full] }
    recorder.updateMeters()
    let heard = Double(pow(10, recorder.averagePower(forChannel: 0) / 20))
    if !full, most > 0, let file, let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size >= most - 4096 {
      full = true
      recorder.pause()
    }
    return ["level": min(1, max(0, heard)), "full": full]
  }

  /// Ends the recording: its bytes, or nil where there is nothing worth keeping (under a second).
  func stop() -> Data? {
    guard let recorder, let file else { return nil }
    let ran = recorder.currentTime
    recorder.stop()
    self.recorder = nil
    self.file = nil
    defer { try? FileManager.default.removeItem(at: file) }
    guard ran >= 0.9, let data = try? Data(contentsOf: file), data.count > 512 else { return nil }
    return data
  }

  /// Ends the recording and keeps nothing of it.
  func cancel() {
    guard let recorder else { return }
    recorder.stop()
    self.recorder = nil
    if let file { try? FileManager.default.removeItem(at: file) }
    file = nil
  }

  // MARK: playing

  private var player: AVAudioPlayer?
  /// The message part whose sound is in [player].
  private var playing = -1
  private var ticker: Timer?

  /// Told where the one playing has got to: its part, where it is and how long it is in milliseconds, whether it plays.
  var heard: (([String: Any]) -> Void)?

  private func say(playing now: Bool, ended: Bool = false) {
    guard let player else { return }
    heard?(["part": playing, "position": ended ? 0 : Int(player.currentTime * 1000), "duration": Int(player.duration * 1000), "playing": now])
  }

  /// Plays the sound of a message's part (or goes on with it where it was paused). Nil, or why it cannot.
  func play(part: Int, data: Data?) -> String? {
    if let player, playing == part {
      player.play()
      tick()
      return nil
    }
    halt()
    guard let data, let made = try? AVAudioPlayer(data: data) else { return "this iPhone can’t play this kind of sound" }
    made.delegate = self
    player = made
    playing = part
    guard made.play() else {
      halt()
      return "it would not play"
    }
    tick()
    return nil
  }

  /// Tells [heard] where the sound has got to, about eight times a second while it plays.
  private func tick() {
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
      guard let self, let player = self.player else { return }
      self.say(playing: player.isPlaying)
    }
  }

  /// Holds the sound where it is; [play] with the same part goes on from there.
  func pause() {
    player?.pause()
    ticker?.invalidate()
    say(playing: false)
  }

  /// Stops the sound and lets it go, saying nothing more about it.
  func halt() {
    ticker?.invalidate()
    ticker = nil
    player?.stop()
    player = nil
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    say(playing: false, ended: true)
    halt()
  }

  /// How long a sound runs, in milliseconds; 0 where it cannot be read.
  static func length(of data: Data) -> Int {
    guard let made = try? AVAudioPlayer(data: data) else { return 0 }
    return Int(made.duration * 1000)
  }
}
