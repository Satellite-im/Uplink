import Foundation
import VoiceFxC
import WebRTC
import os

// The music a DJ's Mac sends to the call (lib/voice/spotify.dart; Matt, 2026-11-25: "I want it to join a voice chat and
// stream the music over the voice chat i'm in"). Its own WebRTC beside flutter_webrtc's: a second factory whose "sound
// device" is a buffer of music (MusicDevice), so the microphone, its mute, its noise removal and the call's own
// connections know nothing of it and it never opens a microphone or a speaker. Nothing here is Flutter's, so
// tool/spotify/check.sh compiles this very file and listens to what it sends.

/// 48 kHz stereo, 16-bit, left first: what the music is all the way from here to Opus.
enum MusicSound {
  static let rate = 48000
  static let channels = 2
  /// What WebRTC is given at a time: 10 ms.
  static let frames = 480
}

/// The music waiting to be sent: written as Spotify plays it (SpotifySound.swift) and read 10 ms at a time by
/// [MusicDevice]. Reading gets silence where there is none, and starts again only once a little is waiting, so a late
/// block is one gap and not a stutter.
final class MusicFeed {
  /// How much waits before reading starts, and the most that may wait: past it the oldest goes, so the music a listener
  /// hears never falls behind by more.
  private let prime: Int, most: Int
  private let ring: UnsafeMutablePointer<Int16>
  private let capacity = MusicSound.rate
  private var head = 0, count = 0
  private var primed = false
  private let lock: os_unfair_lock_t = {
    let l = os_unfair_lock_t.allocate(capacity: 1)
    l.initialize(to: os_unfair_lock())
    return l
  }()
  /// Frames read as silence because none were waiting, since the feed was made: what the check reads.
  private(set) var starved = 0

  init(primeMs: Int = 40, mostMs: Int = 200) {
    prime = MusicSound.rate * primeMs / 1000
    most = MusicSound.rate * mostMs / 1000
    ring = .allocate(capacity: MusicSound.rate * MusicSound.channels)
    ring.initialize(repeating: 0, count: MusicSound.rate * MusicSound.channels)
  }

  deinit {
    ring.deallocate()
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  /// The same music whole, for those it is sent to without loss ([LosslessSend]).
  let tee = MusicTee()

  /// Takes [frames] frames of interleaved stereo. Short, and it allocates nothing: it is called on a sound thread.
  func write(_ from: UnsafePointer<Int16>, frames: Int) {
    guard frames > 0 else { return }
    tee.write(from, frames: frames)
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    // More than there is room for: its newest part.
    let n = min(frames, most)
    let start = from + (frames - n) * MusicSound.channels
    let over = count + n - most
    if over > 0 {
      head = (head + over) % capacity
      count -= over
    }
    var at = (head + count) % capacity
    for i in 0..<n {
      ring[at * 2] = start[i * 2]
      ring[at * 2 + 1] = start[i * 2 + 1]
      at += 1
      if at == capacity { at = 0 }
    }
    count += n
  }

  /// Fills [into] with [frames] frames; silence for what is not there.
  func read(into out: UnsafeMutablePointer<Int16>, frames: Int) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    if !primed && count >= prime { primed = true }
    let n = primed ? min(frames, count) : 0
    for i in 0..<n {
      out[i * 2] = ring[head * 2]
      out[i * 2 + 1] = ring[head * 2 + 1]
      head += 1
      if head == capacity { head = 0 }
    }
    count -= n
    if n < frames {
      (out + n * 2).update(repeating: 0, count: (frames - n) * 2)
      starved += frames - n
      primed = false
    }
  }

  /// Forgets what is waiting.
  func clear() {
    os_unfair_lock_lock(lock)
    head = 0
    count = 0
    primed = false
    os_unfair_lock_unlock(lock)
  }
}

/// Every frame the feed was given, as it came and numbered, for a second to come: what is sent without loss is taken from
/// here, where nothing is left out or put in to keep time, as [MusicFeed.read] does for Opus.
final class MusicTee {
  private let capacity = MusicSound.rate
  private let ring: UnsafeMutablePointer<Int16>
  private let lock: os_unfair_lock_t = {
    let l = os_unfair_lock_t.allocate(capacity: 1)
    l.initialize(to: os_unfair_lock())
    return l
  }()
  /// The number of the next frame written, and of the next one taken.
  private var written: UInt64 = 0, taken: UInt64 = 0
  private var on = false

  init() {
    ring = .allocate(capacity: MusicSound.rate * MusicSound.channels)
    ring.initialize(repeating: 0, count: MusicSound.rate * MusicSound.channels)
  }

  deinit {
    ring.deallocate()
    lock.deinitialize(count: 1)
    lock.deallocate()
  }

  /// Whether what is written is kept; from now, where it was not.
  func set(_ keep: Bool) {
    os_unfair_lock_lock(lock)
    if keep && !on { taken = written }
    on = keep
    os_unfair_lock_unlock(lock)
  }

  func write(_ from: UnsafePointer<Int16>, frames: Int) {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    let all = written
    written += UInt64(frames)
    guard on else { return }
    // More than there is room for: its newest part.
    let n = min(frames, capacity), skip = frames - n
    var at = Int((all + UInt64(skip)) % UInt64(capacity)), from = from + skip * MusicSound.channels, left = n
    while left > 0 {
      let run = min(left, capacity - at)
      (ring + at * MusicSound.channels).update(from: from, count: run * MusicSound.channels)
      from += run * MusicSound.channels
      left -= run
      at = at + run == capacity ? 0 : at + run
    }
    if written - taken > UInt64(capacity) { taken = written - UInt64(capacity) }
  }

  /// The next [frames] frames in order, and the number of the first; nil where fewer are waiting.
  func take(into out: UnsafeMutablePointer<Int16>, frames: Int) -> UInt64? {
    os_unfair_lock_lock(lock)
    defer { os_unfair_lock_unlock(lock) }
    guard on, written - taken >= UInt64(frames) else { return nil }
    let first = taken
    let at = Int(first % UInt64(capacity)), run = min(frames, capacity - at)
    out.update(from: ring + at * MusicSound.channels, count: run * MusicSound.channels)
    if run < frames { (out + run * MusicSound.channels).update(from: ring, count: (frames - run) * MusicSound.channels) }
    taken += UInt64(frames)
    return first
  }
}

/// What carries the chunks to one listener: WebRTC's data channel, or the check's stand-in.
protocol LosslessPipe: AnyObject {
  var isOpen: Bool { get }
  /// Bytes given to it and not yet sent.
  var waiting: Int { get }
  func send(_ chunk: Data) -> Bool
  func shut()
}

final class ChannelPipe: LosslessPipe {
  private let channel: RTCDataChannel
  init(_ channel: RTCDataChannel) { self.channel = channel }
  var isOpen: Bool { channel.readyState == .open }
  var waiting: Int { Int(min(channel.bufferedAmount, UInt64(Int32.max))) }
  func send(_ chunk: Data) -> Bool { channel.sendData(RTCDataBuffer(data: chunk, isBinary: true)) }
  func shut() { channel.close() }
}

/// The music on its way to one listener without loss. What can't be sent in time is dropped here, whole chunks and the
/// oldest first, rather than queued: a listener hears a gap filled by Opus and not music that falls behind.
final class LosslessWay {
  /// The most chunks held here, and the most bytes WebRTC may hold, before anything is dropped: together under the 600 ms
  /// a listener has waiting.
  static let mostChunks = 5, mostWaiting = 48 * 1024

  let pipe: LosslessPipe
  private var held: [Data] = []
  private(set) var sent = 0, bytes = 0, dropped = 0

  /// Nothing is sent until the connection is known to go through no relay ([MusicLink.losslessState]), or once it does.
  var allowed = false {
    didSet { if !allowed { held.removeAll() } }
  }

  init(_ pipe: LosslessPipe) { self.pipe = pipe }

  func push(_ chunk: Data) {
    guard allowed, pipe.isOpen else { return }
    held.append(chunk)
    drain()
    while held.count > Self.mostChunks {
      held.removeFirst()
      dropped += 1
    }
  }

  func drain() {
    while let chunk = held.first, allowed, pipe.isOpen, pipe.waiting + chunk.count <= Self.mostWaiting, pipe.send(chunk) {
      held.removeFirst()
      sent += 1
      bytes += chunk.count
    }
  }
}

/// The music packed once and given to everyone who has it without loss. On [MusicLink.queue] alone.
final class LosslessSend {
  /// The label of the channel it goes on.
  static let label = "music"

  private let tee: MusicTee, queue: DispatchQueue
  private var ways: [String: LosslessWay] = [:]
  private var timer: DispatchSourceTimer?
  private let block = UnsafeMutablePointer<Int16>.allocate(capacity: Int(MUSIC_PACK_FRAMES) * 2)
  private let packed = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MUSIC_PACK_MOST) * 4 + 128)

  init(tee: MusicTee, queue: DispatchQueue) {
    self.tee = tee
    self.queue = queue
  }

  deinit {
    timer?.cancel()
    block.deallocate()
    packed.deallocate()
  }

  func way(_ id: String) -> LosslessWay? { ways[id] }

  func open(_ id: String, _ pipe: LosslessPipe) {
    close(id)
    ways[id] = LosslessWay(pipe)
    settle()
  }

  func close(_ id: String) {
    ways.removeValue(forKey: id)?.pipe.shut()
    settle()
  }

  /// The clock that looks for the next chunk, only while anyone is to have one.
  private func settle() {
    if ways.isEmpty {
      timer?.cancel()
      timer = nil
      tee.set(false)
      return
    }
    guard timer == nil else { return }
    tee.set(true)
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
    t.setEventHandler { [weak self] in self?.look() }
    timer = t
    t.resume()
  }

  private func look() {
    while let at = tee.take(into: block, frames: Int(MUSIC_PACK_FRAMES)) {
      let n = music_chunk(block, Int32(MUSIC_PACK_FRAMES), at, packed)
      if n <= 0 { continue }
      let chunk = Data(bytes: packed, count: Int(n))
      for w in ways.values { w.push(chunk) }
    }
    for w in ways.values { w.drain() }
  }
}

/// The "sound device" the music's WebRTC has: what it records is the feed, what it would play is thrown away. No audio
/// unit, no engine, no microphone and no speaker.
final class MusicDevice: NSObject, RTCAudioDevice {
  let feed: MusicFeed
  /// Given what WebRTC decoded to play, where someone wants it (the check alone); the app has none and plays nothing.
  var played: ((UnsafePointer<Int16>, Int) -> Void)?

  private var delegate: RTCAudioDeviceDelegate?
  private var pump: Pump?

  init(feed: MusicFeed) {
    self.feed = feed
    super.init()
  }

  // What it records and plays.
  let deviceInputSampleRate = Double(MusicSound.rate)
  let inputIOBufferDuration: TimeInterval = 0.01
  let inputNumberOfChannels = MusicSound.channels
  let inputLatency: TimeInterval = 0
  let deviceOutputSampleRate = Double(MusicSound.rate)
  let outputIOBufferDuration: TimeInterval = 0.01
  let outputNumberOfChannels = MusicSound.channels
  let outputLatency: TimeInterval = 0

  private(set) var isInitialized = false
  private(set) var isPlayoutInitialized = false
  private(set) var isPlaying = false
  private(set) var isRecordingInitialized = false
  private(set) var isRecording = false

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    self.delegate = delegate
    isInitialized = true
    return true
  }

  func terminateDevice() -> Bool {
    isPlaying = false
    isRecording = false
    settle()
    isInitialized = false
    isPlayoutInitialized = false
    isRecordingInitialized = false
    delegate = nil
    return true
  }

  func initializePlayout() -> Bool {
    isPlayoutInitialized = true
    return true
  }

  func startPlayout() -> Bool {
    isPlaying = true
    settle()
    return true
  }

  func stopPlayout() -> Bool {
    isPlaying = false
    settle()
    return true
  }

  func initializeRecording() -> Bool {
    isRecordingInitialized = true
    return true
  }

  func startRecording() -> Bool {
    isRecording = true
    settle()
    return true
  }

  func stopRecording() -> Bool {
    isRecording = false
    settle()
    return true
  }

  /// The thread that moves the sound, made when there is some to move and stopped when there is none.
  private func settle() {
    pump?.stop()
    pump = nil
    guard let d = delegate, isRecording || isPlaying else { return }
    pump = Pump(recorded: isRecording ? d.deliverRecordedData : nil, playout: isPlaying && played != nil ? d.getPlayoutData : nil, feed: feed, played: played)
  }

  /// A thread that wakes every 10 ms by the clock and hands WebRTC the next 10 ms of music.
  private final class Pump {
    private let lock = NSLock()
    private var on = true
    private let done = DispatchSemaphore(value: 0)

    init(recorded: RTCAudioDeviceDeliverRecordedDataBlock?, playout: RTCAudioDeviceGetPlayoutDataBlock?, feed: MusicFeed, played: ((UnsafePointer<Int16>, Int) -> Void)?) {
      let t = Thread { [self] in
        run(recorded: recorded, playout: playout, feed: feed, played: played)
        done.signal()
      }
      t.name = "ghost.music"
      t.qualityOfService = .userInteractive
      t.start()
    }

    private var going: Bool {
      lock.lock()
      defer { lock.unlock() }
      return on
    }

    /// Ends the thread and waits for it: nothing is handed to WebRTC after this.
    func stop() {
      lock.lock()
      on = false
      lock.unlock()
      _ = done.wait(timeout: .now() + 1)
    }

    private func run(recorded: RTCAudioDeviceDeliverRecordedDataBlock?, playout: RTCAudioDeviceGetPlayoutDataBlock?, feed: MusicFeed, played: ((UnsafePointer<Int16>, Int) -> Void)?) {
      var base = mach_timebase_info_data_t()
      mach_timebase_info(&base)
      let step = UInt64(10_000_000) * UInt64(base.denom) / UInt64(base.numer)
      let samples = MusicSound.frames * MusicSound.channels
      let buf = UnsafeMutablePointer<Int16>.allocate(capacity: samples)
      buf.initialize(repeating: 0, count: samples)
      defer { buf.deallocate() }
      var next = mach_absolute_time()
      var at: Float64 = 0
      while going {
        let now = mach_absolute_time()
        // The Mac slept, or the thread was held up: on from here rather than a burst of everything missed.
        if now > next + step * 20 { next = now }
        if now < next { mach_wait_until(next) }
        next += step
        var flags = AudioUnitRenderActionFlags()
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mSampleTime = at
        stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
        at += Float64(MusicSound.frames)
        if let recorded {
          feed.read(into: buf, frames: MusicSound.frames)
          var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(MusicSound.channels), mDataByteSize: UInt32(samples * 2), mData: buf))
          // Samples, not frames: this WebRTC (flutter_webrtc 1.6.3's) reads that many 16-bit numbers from the buffer,
          // so in stereo a count of frames is half the music (tool/spotify/check.sh fails on it). What it is asked to
          // play is counted in frames, as the header says of both.
          _ = recorded(&flags, &stamp, 0, UInt32(samples), &list, nil, nil)
        }
        if let playout, let played {
          var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(MusicSound.channels), mDataByteSize: UInt32(samples * 2), mData: buf))
          if playout(&flags, &stamp, 0, UInt32(MusicSound.frames), &list) == noErr { played(buf, MusicSound.frames) }
        }
      }
    }
  }
}

/// How the music is sent: Opus in stereo at [kbps], its most, always on (no silence left out), as the call's own sound is asked for.
enum MusicSdp {
  static let kbps = 510

  /// [sdp] with Opus asked for in stereo at [kbps] and nothing left out of silence.
  static func tuned(_ sdp: String) -> String {
    var lines = sdp.components(separatedBy: "\r\n")
    var payload: String?
    for l in lines where l.hasPrefix("a=rtpmap:") && l.lowercased().contains(" opus/48000") {
      payload = l.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
      break
    }
    guard let payload else { return sdp }
    let want = "minptime=10;useinbandfec=0;stereo=1;sprop-stereo=1;maxaveragebitrate=\(kbps * 1000);maxplaybackrate=48000;cbr=1;usedtx=0"
    let head = "a=fmtp:\(payload) "
    if let i = lines.firstIndex(where: { $0.hasPrefix(head) }) {
      lines[i] = head + want
    } else if let i = lines.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(payload) ") }) {
      lines.insert(head + want, at: i + 1)
    }
    return lines.joined(separator: "\r\n")
  }
}

/// The music's connections, one to each listener, each sending and never receiving. Everything here runs on [queue],
/// never the main thread: making, describing and closing a connection waits on WebRTC's own threads.
final class MusicLink {
  let feed = MusicFeed()
  let queue = DispatchQueue(label: "ghost.music.link", qos: .userInitiated)
  private let factory: RTCPeerConnectionFactory
  private let device: MusicDevice
  private let track: RTCAudioTrack
  private var links: [String: Link] = [:]
  private let lossless: LosslessSend

  /// Told each way to connect found for [id], and how each connection stands; on any thread.
  var onCandidate: ((String, RTCIceCandidate) -> Void)?
  var onState: ((String, RTCPeerConnectionState) -> Void)?

  init() {
    device = MusicDevice(feed: feed)
    factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
    // Music as it is: nothing taken for noise, for an echo, or brought to one loudness.
    let raw = ["googEchoCancellation": "false", "googAutoGainControl": "false", "googNoiseSuppression": "false", "googHighpassFilter": "false", "googAudioMirroring": "false"]
    let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: raw, optionalConstraints: nil))
    track = factory.audioTrack(with: source, trackId: "ghost-music")
    _ = track.setAudioProcessingOptions(RTCAudioProcessingOptions.raw())
    lossless = LosslessSend(tee: feed.tee, queue: queue)
  }

  /// One listener's connection and what it finds, told on.
  private final class Link: NSObject, RTCPeerConnectionDelegate {
    var pc: RTCPeerConnection?
    let found: (RTCIceCandidate) -> Void
    let stands: (RTCPeerConnectionState) -> Void
    init(found: @escaping (RTCIceCandidate) -> Void, stands: @escaping (RTCPeerConnectionState) -> Void) {
      self.found = found
      self.stands = stands
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { found(candidate) }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) { stands(newState) }
  }

  /// The ones there is a connection to.
  var listeners: [String] { queue.sync { Array(links.keys) } }

  /// A connection to [id], made anew (one there already was is closed), and its offer. [servers] as the call has them;
  /// [relayOnly] for a second try; [lossless] with a channel beside the Opus for the music without loss. Answers nil where
  /// it could not be made.
  func offer(to id: String, servers: [RTCIceServer], relayOnly: Bool, lossless: Bool = false, done: @escaping (String?) -> Void) {
    queue.async { [self] in
      closeNow(id)
      let config = RTCConfiguration()
      config.sdpSemantics = .unifiedPlan
      config.iceServers = servers
      config.continualGatheringPolicy = .gatherContinually
      if relayOnly { config.iceTransportPolicy = .relay }
      let link = Link(found: { [weak self] c in self?.onCandidate?(id, c) }, stands: { [weak self] s in self?.onState?(id, s) })
      let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      guard let pc = factory.peerConnection(with: config, constraints: none, delegate: link) else { return done(nil) }
      link.pc = pc
      links[id] = link
      let how = RTCRtpTransceiverInit()
      how.direction = .sendOnly
      how.streamIds = ["ghost-music"]
      let rate = RTCRtpEncodingParameters()
      rate.maxBitrateBps = NSNumber(value: MusicSdp.kbps * 1000)
      how.sendEncodings = [rate]
      guard pc.addTransceiver(with: track, init: how) != nil else {
        closeNow(id)
        return done(nil)
      }
      if lossless { _ = openChannel(id, pc) }
      pc.offer(for: none) { [weak self] sdp, _ in
        guard let self, let sdp else { return done(nil) }
        let mine = RTCSessionDescription(type: .offer, sdp: MusicSdp.tuned(sdp.sdp))
        pc.setLocalDescription(mine) { [weak self] error in
          guard self != nil, error == nil else { return done(nil) }
          done(mine.sdp)
        }
      }
    }
  }

  /// [id]'s answer. The bit rate and the stereo it is sent at are what the answer asks for, so they are put in it here:
  /// a listener that said less than it can take (a phone's plain answer) would otherwise have it sent in mono.
  func answer(from id: String, sdp: String, done: @escaping (Bool) -> Void) {
    queue.async { [self] in
      guard let pc = links[id]?.pc else { return done(false) }
      pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: MusicSdp.tuned(sdp))) { done($0 == nil) }
    }
  }

  /// A way to connect that [id] found.
  func candidate(from id: String, _ c: RTCIceCandidate) {
    queue.async { [self] in
      links[id]?.pc?.add(c) { _ in }
    }
  }

  func close(_ id: String) {
    queue.async { [self] in closeNow(id) }
  }

  /// Every connection closed and nothing left waiting to be sent.
  func closeAll(done: (() -> Void)? = nil) {
    queue.async { [self] in
      for id in Array(links.keys) { closeNow(id) }
      feed.clear()
      done?()
    }
  }

  // --- without loss ----------------------------------------------------------------------------------------------------

  private func openChannel(_ id: String, _ pc: RTCPeerConnection) -> Bool {
    let how = RTCDataChannelConfiguration()
    how.isOrdered = true
    guard let channel = pc.dataChannel(forLabel: LosslessSend.label, configuration: how) else { return false }
    lossless.open(id, ChannelPipe(channel))
    return true
  }

  /// Sends [id] the music without loss too, on the connection there is: only one that was offered with a channel, and
  /// answered with one, has room for another.
  func openLossless(_ id: String, done: @escaping (Bool) -> Void) {
    queue.async { [self] in
      guard let pc = links[id]?.pc, pc.remoteDescription?.sdp.contains("m=application") == true else { return done(false) }
      done(openChannel(id, pc))
    }
  }

  /// Ends it for [id], whose Opus goes on.
  func closeLossless(_ id: String) {
    queue.async { [self] in lossless.close(id) }
  }

  /// How it goes for each who has it: whether the channel is open, the bytes sent, the chunks dropped, and whether the
  /// connection goes through a relay (nil: not known yet). Asking is what lets it be sent, or stops it.
  func losslessState(done: @escaping ([String: (open: Bool, bytes: Int, dropped: Int, relay: Bool?)]) -> Void) {
    queue.async { [self] in
      var out: [String: (open: Bool, bytes: Int, dropped: Int, relay: Bool?)] = [:]
      let group = DispatchGroup()
      for (id, link) in links {
        guard let way = lossless.way(id), let pc = link.pc else { continue }
        out[id] = (way.pipe.isOpen, way.bytes, way.dropped, nil)
        group.enter()
        pc.statistics { [self] report in
          let relay = Self.relayed(report)
          queue.async {
            out[id]?.relay = relay
            if let relay { way.allowed = !relay }
            group.leave()
          }
        }
      }
      group.notify(queue: queue) { done(out) }
    }
  }

  /// Whether either end of the way the connection goes now is a relay's.
  static func relayed(_ report: RTCStatisticsReport) -> Bool? {
    let all = report.statistics
    guard let way = all.values.first(where: { $0.type == "transport" && $0.values["selectedCandidatePairId"] != nil })?.values["selectedCandidatePairId"] as? String, let pair = all[way] else { return nil }
    let ends = ["localCandidateId", "remoteCandidateId"].map { (pair.values[$0] as? String).flatMap { all[$0]?.values["candidateType"] as? String } }
    if ends.contains("relay") { return true }
    return ends.contains(nil) ? nil : false
  }

  private func closeNow(_ id: String) {
    lossless.close(id)
    guard let link = links.removeValue(forKey: id) else { return }
    link.pc?.delegate = nil
    link.pc?.close()
    link.pc = nil
  }
}
