import AVFoundation
import CoreAudio
import Foundation

/// The sound of the Spotify app on this Mac, and of nothing else, while a call is being played its music
/// (lib/voice/spotify.dart; Matt, 2026-11-25: "I want it to join a voice chat and stream the music over the voice chat
/// i'm in"): a Core Audio tap on Spotify's own processes, read through a private aggregate device that holds the tap and
/// no other device, so no microphone and no speaker is ever part of it, and handed on as 48 kHz stereo (MusicFeed).
/// Spotify is not muted by it: whoever plays still hears it from Spotify itself.
///
/// The same tap takes what the Mac plays for a shared screen's sound (ScreenSound.swift; GMFB-63): everything but one
/// app's own processes ([What.allBut]), which is this app's, so the call itself is never sent back into it.
///
/// Every call is on [queue]. macOS 14.4 and later, which asks the person for "System Audio Recording" the first time.
@available(macOS 14.4, *)
final class SpotifySound {
  static let bundle = "com.spotify.client"

  /// What is taken: one app's own processes and nothing else (by its bundle: Spotify's), or everything the Mac plays
  /// but one app's.
  enum What: Equatable {
    case app(String)
    case allBut(String)

    var bundle: String {
      switch self {
      case .app(let b), .allBut(let b): return b
      }
    }
  }

  private let what: What
  /// What the tap and its device are called in the system, and what is said where it can't be made.
  private let name: String, cant: String
  private let feed: MusicFeed
  private let queue = DispatchQueue(label: "ghost.spotify.sound", qos: .userInitiated)
  /// Where the sound arrives: one block at a time, in order.
  private let io = DispatchQueue(label: "ghost.spotify.io", qos: .userInteractive)

  private var on = false
  private var tap = AudioObjectID(kAudioObjectUnknown)
  private var device = AudioObjectID(kAudioObjectUnknown)
  private var proc: AudioDeviceIOProcID?
  private var tapped: Set<AudioObjectID> = []
  /// What the tap gives, in frames a second; 0 while there is none. It is the output device's: a Bluetooth headset whose
  /// microphone is in use runs at a call's, and then so does everything taken from it.
  private var hz: Double = 0
  private var listening: AudioObjectPropertyListenerBlock?
  private var rateListening: AudioObjectPropertyListenerBlock?

  /// The loudest sample since it was last asked ([level]), so the app can say that only silence comes: a refusal of
  /// "System Audio Recording" is not an error, it is silence.
  private let peakLock = NSLock()
  private var peak: Float = 0

  init(feed: MusicFeed, what: What = .app(SpotifySound.bundle), name: String = "Uplink music", cant: String = "The sound of Spotify could not be taken on this Mac.") {
    self.feed = feed
    self.what = what
    self.name = name
    self.cant = cant
  }

  /// Begins. nil: begun (or waiting for Spotify to make a sound); else why not.
  func start(done: @escaping (String?) -> Void) {
    queue.async { [self] in
      if !on {
        on = true
        watch()
      }
      done(build() ? nil : cant)
    }
  }

  /// Ends, with nothing left of it in the system.
  func stop(done: (() -> Void)? = nil) {
    queue.async { [self] in
      on = false
      unwatch()
      tearDown()
      feed.clear()
      done?()
    }
  }

  /// The rate it is taken at now, 0 where it isn't.
  func rate(_ done: @escaping (Double) -> Void) {
    queue.async { [self] in done(hz) }
  }

  /// The loudest it has been since last asked, 0 to 1.
  func level() -> Double {
    peakLock.lock()
    defer { peakLock.unlock() }
    let p = peak
    peak = 0
    return Double(min(1, p))
  }

  // --- what is tapped ------------------------------------------------------------------------------------------------

  private static func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  /// An app's processes that the system's sound knows of: the app itself and its helpers, by their bundle.
  private static func processes(of bundle: String) -> Set<AudioObjectID> {
    var a = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    var out: Set<AudioObjectID> = []
    for id in ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
      var b = address(kAudioProcessPropertyBundleID), n = UInt32(MemoryLayout<CFString?>.size)
      var name: Unmanaged<CFString>?
      guard AudioObjectGetPropertyData(id, &b, 0, nil, &n, &name) == noErr, let said = name?.takeRetainedValue() as String? else { continue }
      if said == bundle || said.hasPrefix(bundle + ".") { out.insert(id) }
    }
    return out
  }

  /// The tap on what Spotify is now; the one there is kept where nothing changed. True where it is made, or where there
  /// is nothing of Spotify's to tap yet.
  private func build() -> Bool {
    guard on else { return false }
    let now = Self.processes(of: what.bundle)
    if now == tapped && device != kAudioObjectUnknown { return true }
    tearDown()

    let described: CATapDescription
    switch what {
    case .app:
      // Nothing of the app's to tap yet: it is tapped when it makes a sound ([watch]).
      if now.isEmpty { return true }
      described = CATapDescription(stereoMixdownOfProcesses: Array(now).sorted())
    case .allBut:
      // Everything the Mac plays, but what these play: with none of them known yet, everything.
      described = CATapDescription(stereoGlobalTapButExcludeProcesses: Array(now).sorted())
    }
    described.name = name
    described.uuid = UUID()
    described.isPrivate = true
    described.muteBehavior = .unmuted
    var made = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(described, &made) == noErr, made != kAudioObjectUnknown else { return false }
    tap = made

    // The device holds the tap alone: no other device's sound, and no microphone that a headset would bring with it.
    let holds: [String: Any] = [
      kAudioAggregateDeviceNameKey: name,
      kAudioAggregateDeviceUIDKey: "ghost-sound-\(UUID().uuidString)",
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: described.uuid.uuidString, kAudioSubTapDriftCompensationKey: true] as [String: Any]],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(holds as CFDictionary, &agg) == noErr, agg != kAudioObjectUnknown else {
      tearDown()
      return false
    }
    device = agg

    var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = Self.address(kAudioTapPropertyFormat)
    guard AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &format) == noErr, let from = AVAudioFormat(streamDescription: &format) else {
      tearDown()
      return false
    }
    let turn = Turn(from: from, feed: feed)
    let heard: (Float) -> Void = { [weak self] p in
      guard let self else { return }
      self.peakLock.lock()
      self.peak = max(self.peak, p)
      self.peakLock.unlock()
    }
    var id: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcIDWithBlock(&id, agg, io, { _, input, _, _, _ in
      heard(turn.take(input))
    }) == noErr, let id else {
      tearDown()
      return false
    }
    proc = id
    guard AudioDeviceStart(agg, id) == noErr else {
      tearDown()
      return false
    }
    tapped = now
    hz = format.mSampleRate
    // Its rate changed (the speaker became another): made again.
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.on else { return }
      self.tapped = []
      _ = self.build()
    }
    rateListening = block
    var r = Self.address(kAudioTapPropertyFormat)
    AudioObjectAddPropertyListenerBlock(tap, &r, queue, block)
    return true
  }

  private func tearDown() {
    if tap != kAudioObjectUnknown, let block = rateListening {
      var r = Self.address(kAudioTapPropertyFormat)
      AudioObjectRemovePropertyListenerBlock(tap, &r, queue, block)
    }
    rateListening = nil
    if device != kAudioObjectUnknown {
      if let proc {
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
      }
      AudioHardwareDestroyAggregateDevice(device)
    }
    proc = nil
    device = AudioObjectID(kAudioObjectUnknown)
    if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    tap = AudioObjectID(kAudioObjectUnknown)
    tapped = []
    hz = 0
  }

  /// Spotify's processes as they come and go: one that begins to make sound is tapped too, and one gone (Spotify quit or
  /// crashed) is let go of.
  private func watch() {
    guard listening == nil else { return }
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.on else { return }
      _ = self.build()
    }
    listening = block
    var a = Self.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
  }

  private func unwatch() {
    guard let block = listening else { return }
    listening = nil
    var a = Self.address(kAudioHardwarePropertyProcessObjectList)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
  }

  /// The tap's blocks made 48 kHz stereo 16-bit, and fed. Used on [io] alone.
  private final class Turn {
    private let from: AVAudioFormat
    private let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MusicSound.rate), channels: 2, interleaved: true)!
    private let converter: AVAudioConverter?
    private let feed: MusicFeed
    private var out: [Int16] = []

    init(from: AVAudioFormat, feed: MusicFeed) {
      self.from = from
      self.feed = feed
      converter = from == to ? nil : AVAudioConverter(from: from, to: to)
    }

    /// Feeds [list]; the loudest sample in it.
    func take(_ list: UnsafePointer<AudioBufferList>) -> Float {
      guard let block = AVAudioPCMBuffer(pcmFormat: from, bufferListNoCopy: list), block.frameLength > 0 else { return 0 }
      guard let converter else { return send(block) }
      let room = AVAudioFrameCount(Double(block.frameLength) * to.sampleRate / from.sampleRate) + 64
      guard let made = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: room) else { return 0 }
      var given = false
      var wrong: NSError?
      converter.convert(to: made, error: &wrong) { _, status in
        if given {
          status.pointee = .noDataNow
          return nil
        }
        given = true
        status.pointee = .haveData
        return block
      }
      return wrong == nil ? send(made) : 0
    }

    private func send(_ b: AVAudioPCMBuffer) -> Float {
      guard let f = b.floatChannelData?[0] else { return 0 }
      let n = Int(b.frameLength) * 2
      if n == 0 { return 0 }
      if out.count < n { out = [Int16](repeating: 0, count: n) }
      var most: Float = 0
      for i in 0..<n {
        let v = max(-1, min(1, f[i]))
        most = max(most, abs(v))
        out[i] = Int16(v * 32767)
      }
      out.withUnsafeBufferPointer { feed.write($0.baseAddress!, frames: n / 2) }
      return most
    }
  }
}
