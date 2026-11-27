import AVFoundation
import Foundation
import WebRTC
import flutter_webrtc
#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif

/// A call's voices, each to a file of its own, and the MP4 made of them, on the Mac and the iPhone (the same file in
/// macos/Runner and ios/Runner; lib/voice/recorder.dart; Matt, 2026-11-19: "a "record call" plugin where it records the
/// call to an MP4 with multiple named audio tracks"). As android CallRecorder.kt: 48 kHz mono 16-bit, each held to the
/// clock, silence where a voice came late or stopped.
///
/// - This device's own voice: the block VoiceFx has just cleaned ([mic], from VoiceFx's capture hook), silence while
///   muted.
/// - Someone else's: WebRTC's renderer on their decoded track (`RTCAudioTrack.addRenderer`), before this device's
///   volume for them.
/// - The call's picture, on the Mac alone (GMFB-42): CallVideo.swift makes a file of video while the call runs, and
///   [mux] copies its track in after the voices. Its `video.` calls come through this channel.
final class CallRecorder: NSObject {
  static let shared = CallRecorder()
  static let rate = 48000

  /// One voice's file.
  final class Track {
    private let handle: FileHandle
    private(set) var written: Int64 = 0
    private let lock = NSLock()

    init?(path: String) {
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: path, contents: nil)
      guard let h = FileHandle(forWritingAtPath: path) else { return nil }
      handle = h
    }

    /// Writes [frames] samples given at [rate] in [channels] channels, held to [due] samples.
    func write(due: Int64, frames: Int, rate: Int, channels: Int, read: (Int, Int) -> Float) {
      guard frames > 0, rate > 0 else { return }
      lock.lock()
      defer { lock.unlock() }
      let n = frames * CallRecorder.rate / rate
      if due - written > Int64(CallRecorder.rate / 10) { padLocked(to: due - Int64(n)) }
      if written - due > Int64(CallRecorder.rate / 10) { return }
      var out = [Int16](repeating: 0, count: n)
      for i in 0..<n {
        let pos = Double(i) * Double(rate) / Double(CallRecorder.rate)
        let a = min(Int(pos), frames - 1)
        let b = min(a + 1, frames - 1)
        let f = Float(pos - Double(a))
        var v: Float = 0
        for c in 0..<max(1, channels) { v += read(a, c) * (1 - f) + read(b, c) * f }
        v /= Float(max(1, channels))
        out[i] = Int16(max(-32768, min(32767, v)))
      }
      out.withUnsafeBytes { handle.write(Data($0)) }
      written += Int64(n)
    }

    /// Silence up to sample [to]; nothing when the file is already that long.
    func pad(to: Int64) {
      lock.lock()
      defer { lock.unlock() }
      padLocked(to: to)
    }

    private func padLocked(to: Int64) {
      var gap = to - written
      guard gap > 0 else { return }
      let zeros = Data(count: CallRecorder.rate * 2)
      while gap > 0 {
        let n = min(gap, Int64(CallRecorder.rate))
        handle.write(zeros.prefix(Int(n) * 2))
        gap -= n
      }
      written = to
    }

    func close() {
      lock.lock()
      defer { lock.unlock() }
      try? handle.close()
    }
  }

  /// What WebRTC hands someone else's decoded sound to.
  final class Renderer: NSObject, RTCAudioRenderer {
    let track: Track
    init(track: Track) { self.track = track }

    /// One block of their sound, floats or 16-bit, interleaved or not: read as floats on the 16-bit scale.
    func render(pcmBuffer buffer: AVAudioPCMBuffer) {
      let frames = Int(buffer.frameLength)
      let channels = Int(buffer.format.channelCount)
      let rate = Int(buffer.format.sampleRate)
      let interleaved = buffer.format.isInterleaved
      let due = CallRecorder.shared.due()
      if let f = buffer.floatChannelData {
        track.write(due: due, frames: frames, rate: rate, channels: channels) { i, c in
          (interleaved ? f[0][i * channels + c] : f[c][i]) * 32768
        }
      } else if let s = buffer.int16ChannelData {
        track.write(due: due, frames: frames, rate: rate, channels: channels) { i, c in
          Float(interleaved ? s[0][i * channels + c] : s[c][i])
        }
      }
    }
  }

  private let lock = NSLock()
  /// When the recording began, in uptime nanoseconds; 0 while nothing is recorded.
  private var started: UInt64 = 0
  private var muted = false
  private var micTrack: Track?
  /// Everyone else by Dart's key: their file, and the track and renderer tapping it (nil once the tap is taken off).
  private var others: [String: (track: Track, rtc: RTCAudioTrack?, renderer: Renderer?)] = [:]
  private var channel: FlutterMethodChannel?

  /// Samples due now, by the clock since the recording began.
  func due() -> Int64 {
    let s = started
    guard s != 0 else { return 0 }
    return Int64((DispatchTime.now().uptimeNanoseconds &- s) / 1000) * Int64(CallRecorder.rate) / 1_000_000
  }

  /// The `ghost/recorder` channel: start (this device's file), muted, add and remove (someone else's voice), stop (the
  /// samples in each file) and mux (the files into one MP4, off the main thread).
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/recorder", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":
        _ = self.stopAll()
        self.lock.lock()
        self.started = DispatchTime.now().uptimeNanoseconds
        self.muted = args["muted"] as? Bool ?? false
        self.micTrack = Track(path: args["mic"] as? String ?? "")
        self.lock.unlock()
        result(self.micTrack != nil)
      case "muted":
        self.muted = args["on"] as? Bool ?? false
        result(true)
      case "add":
        result(self.add(key: args["key"] as? String ?? "", trackId: args["track"] as? String ?? "", path: args["path"] as? String ?? ""))
      case "remove":
        self.remove(key: args["key"] as? String ?? "")
        result(true)
      case "stop":
        result(self.stopAll())
      case "mux":
        let out = args["out"] as? String ?? ""
        let inputs = args["inputs"] as? [String] ?? []
        // A file of video to put in after the voices (GMFB-42); the answer then says whether it went in.
        let video = args["video"] as? String
        DispatchQueue.global(qos: .userInitiated).async {
          let made = CallRecorder.mux(inputs: inputs, out: out, video: video)
          DispatchQueue.main.async {
            if let error = made.error {
              result(FlutterError(code: "mux", message: error, details: nil))
            } else if video != nil {
              result(["out": out, "video": made.video])
            } else {
              result(out)
            }
          }
        }
      default:
        #if os(macOS)
        // The recording's picture (CallVideo.swift): video.start, video.layout, video.stop.
        if CallVideo.shared.handle(call, result: result) { return }
        #endif
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// From VoiceFx's capture hook, on WebRTC's audio thread: one block of this device's voice, floats on the 16-bit
  /// scale.
  func mic(_ samples: UnsafeMutablePointer<Float>, frames: Int, rate: Int) {
    guard let t = micTrack else { return }
    let silent = muted
    t.write(due: due(), frames: frames, rate: rate, channels: 1) { i, _ in silent ? 0 : samples[i] }
  }

  /// Taps the remote track [trackId] into [key]'s file at [path]. Someone who comes back (a new track for the same key)
  /// goes on in the file they had. False when nothing is being recorded or the track is not a known voice.
  private func add(key: String, trackId: String, path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard started != 0, let rtc = FlutterWebRTCPlugin.sharedSingleton()?.remoteTrack(forId: trackId) as? RTCAudioTrack else { return false }
    let had = others[key]
    if let r = had?.renderer { had?.rtc?.remove(r) }
    guard let track = had?.track ?? Track(path: path) else { return false }
    let renderer = Renderer(track: track)
    rtc.add(renderer)
    others[key] = (track, rtc, renderer)
    return true
  }

  /// Takes the tap off [key]'s track. The file is kept, so it is filled with silence to the end at the stop.
  private func remove(key: String) {
    lock.lock()
    defer { lock.unlock() }
    guard let had = others[key] else { return }
    if let r = had.renderer { had.rtc?.remove(r) }
    others[key] = (had.track, nil, nil)
  }

  /// Stops every tap, fills each file to the end with silence, and says how many samples each has.
  private func stopAll() -> [String: Int64] {
    lock.lock()
    defer { lock.unlock() }
    guard started != 0 else { return [:] }
    let end = due()
    var counts: [String: Int64] = [:]
    if let m = micTrack {
      m.pad(to: end)
      m.close()
      counts["me"] = m.written
    }
    micTrack = nil
    for (key, had) in others {
      if let r = had.renderer { had.rtc?.remove(r) }
      had.track.pad(to: end)
      had.track.close()
      counts[key] = had.track.written
    }
    others = [:]
    started = 0
    return counts
  }

  /// Encodes each of [inputs] (48 kHz mono 16-bit) as AAC into one MP4 at [out], a track each in their order; the
  /// reason in words where it couldn't.
  ///
  /// [video] is a file whose video track is copied in as the last track, as it is, with its own times (GMFB-42: the
  /// call's picture, encoded while the call ran; frames can't wait as raw files the way the voices do, and this writer
  /// is not open until the stop). Last, so every voice keeps its place among the tracks. Where it can't be read the
  /// recording is made of the voices alone, and `video` in the answer is false.
  static func mux(inputs: [String], out: String, video: String? = nil) -> (error: String?, video: Bool) {
    let made = muxed(inputs: inputs, out: out, video: video)
    return (made.error, made.error == nil && made.video)
  }

  private static func muxed(inputs: [String], out: String, video: String?) -> (error: String?, video: Bool) {
    func no(_ why: String) -> (error: String?, video: Bool) { (why, false) }
    let url = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return no("no writer") }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
    var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    guard let format else { return no("no format") }
    var feeds: [(input: AVAssetWriterInput, file: FileHandle, at: Int64, done: Bool)] = []
    for path in inputs {
      guard let h = FileHandle(forReadingAtPath: path) else { return no("can't read \(path)") }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = false
      guard writer.canAdd(input) else { return no("too many tracks") }
      writer.add(input)
      feeds.append((input, h, 0, false))
    }
    // The picture: read as it was encoded and handed on untouched.
    var picture: (reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
    if let video, FileManager.default.fileExists(atPath: video) {
      let asset = AVURLAsset(url: URL(fileURLWithPath: video))
      if let track = asset.tracks(withMediaType: .video).first, let first = track.formatDescriptions.first, let reader = try? AVAssetReader(asset: asset) {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: (first as! CMFormatDescription))
        input.expectsMediaDataInRealTime = false
        if reader.canAdd(output) {
          reader.add(output)
          if reader.startReading(), writer.canAdd(input) {
            writer.add(input)
            picture = (reader, output, input)
          }
        }
      }
    }
    var pictureDone = picture == nil
    guard writer.startWriting() else { return no(writer.error?.localizedDescription ?? "couldn't start writing") }
    writer.startSession(atSourceTime: .zero)
    // A second of each track in turn, so the file is interleaved and no input waits on another.
    while feeds.contains(where: { !$0.done }) || !pictureDone {
      var moved = false
      // About two seconds of the picture a turn.
      if let p = picture, !pictureDone {
        var n = 0
        while n < 30, p.input.isReadyForMoreMediaData {
          guard let sample = p.output.copyNextSampleBuffer() else {
            p.input.markAsFinished()
            pictureDone = true
            break
          }
          guard p.input.append(sample) else { return no(writer.error?.localizedDescription ?? "couldn't add the picture") }
          n += 1
          moved = true
        }
      }
      for i in feeds.indices where !feeds[i].done && feeds[i].input.isReadyForMoreMediaData {
        let data = feeds[i].file.readData(ofLength: rate * 2)
        if data.isEmpty {
          feeds[i].input.markAsFinished()
          feeds[i].done = true
          continue
        }
        let n = data.count / 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard let block else { return no("no memory") }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: n, presentationTimeStamp: CMTime(value: feeds[i].at, timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample, feeds[i].input.append(sample) else { return no(writer.error?.localizedDescription ?? "couldn't add sound") }
        feeds[i].at += Int64(n)
        moved = true
      }
      if !moved { usleep(5000) }
      if writer.status == .failed { return no(writer.error?.localizedDescription ?? "the writer failed") }
    }
    for f in feeds { try? f.file.close() }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed ? (nil, picture != nil) : no(writer.error?.localizedDescription ?? "couldn't finish the file")
  }
}
