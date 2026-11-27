import AVFoundation
import Foundation
import os
#if canImport(FlutterMacOS)
import FlutterMacOS
#elseif canImport(Flutter)
import Flutter
#endif
#if os(macOS)
import CoreAudio
#endif

// A player of this device's own for a circle's music sent without loss (lib/voice/music_sink.dart; Matt, 2026-11-25: "I'd
// like it to stream lossless audio"), on the Mac and the iPhone: the `ghost/music` channel. What it is given is played as
// it is, 48 kHz stereo 16-bit, by an AVAudioEngine that has an output and nothing else: its input is never touched, so it
// asks for no microphone. This file is macos/Runner's and ios/Runner's alike; tool/spotify/check.sh sink plays it to
// nobody (an engine rendering into memory).

/// What waits to be played, and how loud: written by the app, read on the sound thread.
final class MusicRing {
  static let rate = 48000
  /// Three seconds: lib/voice/spotify_lossless.dart never has more than two waiting.
  private let capacity = MusicRing.rate * 3
  private let ring: UnsafeMutablePointer<Int16>
  private var head = 0, count = 0, dry = 0
  private var running = false
  private var gain: Float = 0, toward: Float = 0
  private let lock: os_unfair_lock_t = {
    let l = os_unfair_lock_t.allocate(capacity: 1)
    l.initialize(to: os_unfair_lock())
    return l
  }()
  /// From silent to as loud as can be in 30 ms.
  private let step: Float = 1 / (0.03 * Float(MusicRing.rate))

  init() {
    ring = .allocate(capacity: capacity * 2)
    ring.initialize(repeating: 0, count: capacity * 2)
  }

  deinit {
    ring.deallocate()
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  /// Takes 16-bit samples, interleaved: the frames that wait now, and how often it has run out.
  func write(_ data: Data) -> (waiting: Int, dry: Int) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    let frames = min(data.count / 4, capacity - count)
    data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
      var at = (head + count) % capacity
      for i in 0..<frames {
        ring[at * 2] = Int16(littleEndian: p.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
        ring[at * 2 + 1] = Int16(littleEndian: p.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
        at += 1
        if at == capacity { at = 0 }
      }
    }
    count += frames
    if frames > 0 { running = true }
    return (count, dry)
  }

  func clear() {
    os_unfair_lock_lock(lock)
    head = 0
    count = 0
    running = false
    os_unfair_lock_unlock(lock)
  }

  func set(_ to: Float) {
    os_unfair_lock_lock(lock)
    toward = max(0, min(4, to))
    os_unfair_lock_unlock(lock)
  }

  /// The next [frames], left and right; silence for what is not there.
  func read(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    let n = min(frames, count)
    for i in 0..<n {
      if gain != toward { gain = gain < toward ? min(toward, gain + step) : max(toward, gain - step) }
      left[i] = max(-1, min(1, Float(ring[head * 2]) / 32768 * gain))
      right[i] = max(-1, min(1, Float(ring[head * 2 + 1]) / 32768 * gain))
      head += 1
      if head == capacity { head = 0 }
    }
    count -= n
    for i in n..<max(n, frames) {
      left[i] = 0
      right[i] = 0
    }
    if n < frames {
      if running { dry += 1 }
      running = false
      gain = toward
    }
  }
}

/// The engine and the device it plays to.
final class MusicPlayer {
  let ring = MusicRing()
  let engine = AVAudioEngine()
  private let source: AVAudioSourceNode
  private var changed: NSObjectProtocol?
  private var device = ""
  private var on = false
  /// Starting and stopping an engine waits on the system's sound: never on the main thread.
  private let work = DispatchQueue(label: "ghost.music.sink", qos: .userInitiated)
  #if os(macOS)
  private var following: AudioObjectPropertyListenerBlock?
  #endif

  init() {
    let ring = self.ring
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(MusicRing.rate), channels: 2)!
    source = AVAudioSourceNode(format: format) { _, _, frames, list in
      let b = UnsafeMutableAudioBufferListPointer(list)
      guard b.count == 2, let l = b[0].mData, let r = b[1].mData else { return noErr }
      ring.read(l.assumingMemoryBound(to: Float.self), r.assumingMemoryBound(to: Float.self), frames: Int(frames))
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
  }

  /// Plays to [to] ('' or "default" for the system's own). False where it can't.
  func open(_ to: String, done: @escaping (Bool) -> Void) {
    work.async { [self] in
      device = to
      on = true
      // The device went, or runs at another rate: begun again on what there is.
      changed = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.again() }
      #if os(macOS)
      // And the system's own became another.
      let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.again() }
      following = block
      var a = MusicOut.own
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, work, block)
      #endif
      done(run())
    }
  }

  private func again() {
    work.async { [weak self] in
      guard let self, self.on else { return }
      _ = self.run()
    }
  }

  /// On [work].
  private func run() -> Bool {
    engine.stop()
    #if os(macOS)
    guard var id = MusicOut.device(device), let unit = engine.outputNode.audioUnit else { return false }
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    #endif
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      NSLog("music: not playing: \(error.localizedDescription)")
      return false
    }
    return true
  }

  func output(_ to: String) {
    work.async { [self] in
      if to == device || !on { return }
      device = to
      _ = run()
    }
  }

  func close() {
    ring.clear()
    work.async { [self] in
      on = false
      if let changed { NotificationCenter.default.removeObserver(changed) }
      changed = nil
      #if os(macOS)
      if let following {
        var a = MusicOut.own
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, work, following)
      }
      following = nil
      #endif
      engine.stop()
    }
  }
}

/// Where sound goes, without opening anything.
enum MusicOut {
  #if os(macOS)
  private static func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func number(_ of: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = address(s, scope), v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(of, &a, 0, nil, &size, &v) == noErr ? v : nil
  }

  private static func streams(_ of: AudioObjectID) -> [AudioObjectID] {
    var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(of, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(of, &a, 0, nil, &size, &out) == noErr ? out : []
  }

  /// Which the system's own is.
  static let own = address(kAudioHardwarePropertyDefaultOutputDevice)

  /// The device the call's WebRTC calls [id]: its UID, or its number; the system's own for none. One that plays nothing,
  /// or is gone, is the system's own too, as the call does with it.
  static func device(_ id: String) -> AudioDeviceID? {
    if !id.isEmpty && id != "default" {
      var a = address(kAudioHardwarePropertyTranslateUIDToDevice), found = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
      var uid = id as CFString
      let got = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &found) }
      if got == noErr, found != kAudioObjectUnknown, !streams(found).isEmpty { return found }
      if let n = AudioDeviceID(id), !streams(n).isEmpty { return n }
    }
    guard let own = number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), own != kAudioObjectUnknown else { return nil }
    return own
  }

  static func way(_ id: String) -> [String: Any] {
    guard let d = device(id) else { return ["to": "none", "rate": 0] }
    var a = address(kAudioDevicePropertyNominalSampleRate), rate: Float64 = 0, size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectGetPropertyData(d, &a, 0, nil, &size, &rate)
    let transport = number(d, kAudioDevicePropertyTransportType) ?? 0
    let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    if bluetooth && rate > 0 && rate < 44100 { return ["to": "call", "rate": rate] }
    var u = address(kAudioDevicePropertyDeviceUID), uid: Unmanaged<CFString>?, n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let name = AudioObjectGetPropertyData(d, &u, 0, nil, &n, &uid) == noErr ? uid?.takeRetainedValue() as String? ?? "" : ""
    // The jack says so by its source ("hdpn"); others by what their stream ends in, where they say.
    let jack = number(d, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) == 0x6864_706e
    let worn = streams(d).contains { number($0, kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeHeadphones }
    // The Mac's own speakers; anything else (a screen, a USB box, a Bluetooth device) may be worn or stand in the room.
    return ["to": jack || worn ? "headphones" : transport == kAudioDeviceTransportTypeBuiltIn ? "speakers" : "unknown", "rate": rate, "id": name]
  }
  #else
  static func way(_ id: String) -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    guard let port = session.currentRoute.outputs.first else { return ["to": "none", "rate": 0] }
    let to: String
    switch port.portType {
    case .headphones: to = "headphones"
    case .bluetoothHFP: to = "call"
    case .builtInSpeaker, .builtInReceiver: to = "speakers"
    // A Bluetooth or USB device may be worn or stand in the room: not said, so asked.
    default: to = "unknown"
    }
    return ["to": to, "rate": session.sampleRate, "id": port.uid]
  }
  #endif
}

#if canImport(FlutterMacOS) || canImport(Flutter)
final class MusicSink: NSObject {
  static let shared = MusicSink()
  private var channel: FlutterMethodChannel?
  private var player: MusicPlayer?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/music", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) ?? result(nil) }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let device = args["device"] as? String ?? ""
    switch call.method {
    case "way":
      result(MusicOut.way(device))
    case "open":
      player?.close()
      let p = MusicPlayer()
      player = p
      p.open(device) { ok in
        DispatchQueue.main.async {
          if !ok {
            p.close()
            if self.player === p { self.player = nil }
          }
          result(ok)
        }
      }
    case "write":
      guard let player, let data = (call.arguments as? FlutterStandardTypedData)?.data else { return result(nil) }
      let now = player.ring.write(data)
      result([now.waiting, now.dry])
    case "set":
      let volume = args["volume"] as? Double ?? 1, silent = args["silent"] as? Bool ?? false
      player?.ring.set(silent ? 0 : Float(volume))
      result(nil)
    case "output":
      player?.output(device)
      result(nil)
    case "clear":
      player?.ring.clear()
      result(nil)
    case "close":
      player?.close()
      player = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
#endif
