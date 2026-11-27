// A silent check of the music sent without loss (macos/Runner/MusicLink.swift, compiled into this very program): known
// sound goes into the feed in blocks of odd sizes, over real connections on this Mac, and what comes out of each data
// channel, unpacked, must be it bit for bit: ten seconds, two listeners at once, one of whom drops and comes back. The
// Opus beside it goes on all the while. No microphone and no speaker. (What unpacks it is the test's own reader; the
// Mac's decoder and lib/voice/flac.dart read the same frames in native/voicefx/test and test/flac_test.dart.)
//
//   as      as it is: must pass
//   changed one sample of one side one step off, once, on its way in: must fail
//   late    a frame left out on its way in: must fail

import Foundation
import MusicUnpack
import VoiceFxC
import WebRTC

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "as"
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ why: String) -> Never {
  print("FAIL: \(why)")
  exit(1)
}

/// What the music is at frame [n]: two tones with noise over them, loud enough that everything of 16 bits is used.
func sample(_ n: Int, _ side: Int) -> Int16 {
  var x = UInt32(truncatingIfNeeded: n &* 2 &+ side) &* 2_654_435_761
  x ^= x >> 15
  x = x &* 2_246_822_519
  x ^= x >> 13
  let noise = Double(Int32(bitPattern: x) >> 20)
  return Int16(max(-32768, min(32767, 14000 * sin(2 * .pi * (side == 0 ? 440 : 1000) * Double(n) / 48000) + 9000 * sin(2 * .pi * 97.3 * Double(n) / 48000) + noise)))
}

final class Listener: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
  let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: MusicDevice(feed: MusicFeed()))
  var pc: RTCPeerConnection!
  var channel: RTCDataChannel?
  var found: ((RTCIceCandidate) -> Void)?
  private let lock = NSLock()
  private(set) var chunks: [(at: Int, frames: Int)] = []
  private(set) var wrong: [String] = []
  private(set) var bytes = 0
  private var lr = [Int16](repeating: 0, count: Int(MUSIC_PACK_MOST) * 2)

  override init() {
    super.init()
    let config = RTCConfiguration()
    config.sdpSemantics = .unifiedPlan
    pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)!
  }
  func peerConnection(_ p: RTCPeerConnection, didChange s: RTCSignalingState) {}
  func peerConnection(_ p: RTCPeerConnection, didAdd s: RTCMediaStream) {}
  func peerConnection(_ p: RTCPeerConnection, didRemove s: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ p: RTCPeerConnection) {}
  func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceConnectionState) {}
  func peerConnection(_ p: RTCPeerConnection, didChange s: RTCIceGatheringState) {}
  func peerConnection(_ p: RTCPeerConnection, didGenerate c: RTCIceCandidate) { found?(c) }
  func peerConnection(_ p: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
  func peerConnection(_ p: RTCPeerConnection, didOpen d: RTCDataChannel) {
    channel = d
    d.delegate = self
  }
  func dataChannelDidChangeState(_ d: RTCDataChannel) {}
  func dataChannel(_ d: RTCDataChannel, didReceiveMessageWith b: RTCDataBuffer) {
    lock.lock()
    defer { lock.unlock() }
    let m = [UInt8](b.data)
    bytes += m.count
    guard b.isBinary, m.count > 12, m[0] == 1, m[1] == 1 else { return wrong.append("a chunk that is not one") }
    let frames = Int(m[2]) | Int(m[3]) << 8, len = Int(m[10]) | Int(m[11]) << 8
    let at = (0..<6).reduce(0) { $0 | Int(m[4 + $1]) << (8 * $1) }
    guard len == m.count - 12 else { return wrong.append("a chunk of another length than it says") }
    let got = m.withUnsafeBufferPointer { music_unpack($0.baseAddress! + 12, Int32(len), &lr, MUSIC_PACK_MOST) }
    guard Int(got) == frames else { return wrong.append("frame \(at): unpacked \(got) of \(frames)") }
    for i in 0..<frames where lr[i * 2] != sample(at + i, 0) || lr[i * 2 + 1] != sample(at + i, 1) {
      wrong.append("frame \(at + i): \(lr[i * 2]),\(lr[i * 2 + 1]) and not \(sample(at + i, 0)),\(sample(at + i, 1))")
      break
    }
    chunks.append((at, frames))
  }
  var now: (chunks: [(at: Int, frames: Int)], wrong: [String], bytes: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (chunks, wrong, bytes)
  }
}

guard RTCInitializeSSL() else { fail("no SSL") }

// What the drops are made of, without a connection: a pipe that stops taking anything.
final class Stuck: LosslessPipe {
  var isOpen = true, waiting = 0, took: [Data] = []
  func send(_ c: Data) -> Bool {
    waiting += c.count
    took.append(c)
    return true
  }
  func shut() { isOpen = false }
}
do {
  let pipe = Stuck(), way = LosslessWay(pipe)
  way.push(Data(count: 10))
  guard pipe.took.isEmpty else { fail("sent before it was known to go through no relay") }
  way.allowed = true
  for i in 0..<100 { way.push(Data(repeating: UInt8(i), count: 6000)) }
  guard pipe.took.map({ $0[0] }) == Array(0..<8) else { fail("more was given to a channel that is stuck than it may hold: \(pipe.took.count)") }
  guard way.dropped == 100 - 8 - LosslessWay.mostChunks, way.sent == 8, way.bytes == 48000 else { fail("drops counted wrong: \(way.dropped)") }
  pipe.waiting = 0
  way.drain()
  guard pipe.took.suffix(5).map({ $0[0] }) == Array(95..<100) else { fail("the oldest were not the ones dropped") }
  way.allowed = false
  way.push(Data(count: 10))
  way.drain()
  way.allowed = true
  way.drain()
  guard pipe.took.count == 13 else { fail("sent, or kept, while it goes through a relay") }
  pipe.shut()
  way.push(Data(count: 10))
  guard pipe.took.count == 13 else { fail("sent on a channel that is shut") }
}

let link = MusicLink()
var listeners: [String: Listener] = [:]
let book = NSLock()
link.onCandidate = { id, c in
  book.lock()
  let l = listeners[id]
  book.unlock()
  l?.pc.add(c) { _ in }
}

// The music, as the tap gives it: blocks of one odd size after another, by the clock.
let feeder = Thread {
  var n = 0, i = 0
  let sizes = [441, 512, 480, 1, 1024, 333, 2048]
  let began = Date()
  var block = [Int16](repeating: 0, count: 4096)
  while true {
    let size = sizes[i % sizes.count]
    i += 1
    for k in 0..<size {
      block[k * 2] = sample(n + k, 0)
      block[k * 2 + 1] = sample(n + k, 1)
    }
    if mode == "changed", n < 240_000, n + size >= 240_000 { block[1] ^= 1 }
    if mode == "late", n < 240_000, n + size >= 240_000 { block.withUnsafeBufferPointer { link.feed.write($0.baseAddress!, frames: size - 1) } } else { link.feed.write(block, frames: size) }
    n += size
    Thread.sleep(until: began + Double(n) / 48000)
  }
}
feeder.qualityOfService = .userInteractive
feeder.start()

func state() -> [String: (open: Bool, bytes: Int, dropped: Int, relay: Bool?)] {
  var got: [String: (open: Bool, bytes: Int, dropped: Int, relay: Bool?)] = [:]
  let done = DispatchSemaphore(value: 0)
  link.losslessState {
    got = $0
    done.signal()
  }
  if done.wait(timeout: .now() + 5) != .success { fail("no state in 5 s") }
  return got
}

func connect(_ id: String) -> Listener {
  let l = Listener()
  book.lock()
  listeners[id] = l
  book.unlock()
  l.found = { c in link.candidate(from: id, c) }
  let described = DispatchSemaphore(value: 0)
  var wrong: String?
  link.offer(to: id, servers: [], relayOnly: false, lossless: true) { sdp in
    guard let sdp else {
      wrong = "no offer"
      described.signal()
      return
    }
    if !sdp.contains("m=application") { wrong = "no channel offered" }
    l.pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { _ in
      l.pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, e in
        guard let answer else {
          wrong = "no answer: \(String(describing: e))"
          described.signal()
          return
        }
        l.pc.setLocalDescription(answer) { _ in
          link.answer(from: id, sdp: answer.sdp) { ok in
            if !ok { wrong = "answer not taken" }
            described.signal()
          }
        }
      }
    }
  }
  if described.wait(timeout: .now() + 10) != .success { fail("no description in 10 s") }
  if let wrong { fail(wrong) }
  // The app asks each second how it goes, which is what lets it be sent.
  let until = Date() + 10
  while l.now.chunks.isEmpty && Date() < until {
    _ = state()
    Thread.sleep(forTimeInterval: 0.02)
  }
  if l.now.chunks.isEmpty { fail("\(id): nothing came in 10 s") }
  return l
}

/// That everything [l] got was right, whole and in order; the seconds of it.
func judge(_ id: String, _ l: Listener) -> Double {
  let n = l.now
  if let w = n.wrong.first { fail("\(id): \(w)") }
  for (a, b) in zip(n.chunks, n.chunks.dropFirst()) where a.at + a.frames != b.at { fail("\(id): frame \(b.at) came after \(a.at + a.frames - 1)") }
  let frames = n.chunks.reduce(0) { $0 + $1.frames }
  print(String(format: "%@: %d frames from %d, bit for bit; %d bytes, %.0f kbit/s of %.0f", id, frames, n.chunks[0].at, n.bytes, Double(n.bytes) * 8 / (Double(frames) / 48000) / 1000, 1536.0))
  return Double(frames) / 48000
}

let first = connect("first"), second = connect("second")
Thread.sleep(forTimeInterval: 4)
_ = judge("first, before it drops", first)
first.pc.close()
Thread.sleep(forTimeInterval: 1)
let again = connect("first")
Thread.sleep(forTimeInterval: 6.5)
_ = judge("first, come back", again)
let heard = judge("second", second)
if heard < 10 { fail("only \(heard) s") }
let now = state()
print("as the sender has it:", now.keys.sorted().map { "\($0) open \(now[$0]!.open), \(now[$0]!.dropped) dropped, relay \(now[$0]!.relay.map { "\($0)" } ?? "not known")" }.joined(separator: "; "))
if now.count != 2 || now.values.contains(where: { !$0.open || $0.dropped != 0 || $0.relay != false }) { fail("the sender has it otherwise") }

// Ended for one, and begun again on the same connection: nothing is negotiated again, and the other goes on.
link.closeLossless("second")
Thread.sleep(forTimeInterval: 0.5)
let stopped = second.now.chunks.count
Thread.sleep(forTimeInterval: 0.5)
if second.now.chunks.count != stopped { fail("still sent after it was ended") }
if state()["second"] != nil { fail("ended, and still had") }
let reopened = DispatchSemaphore(value: 0)
link.openLossless("second") { ok in
  if !ok { fail("not begun again") }
  reopened.signal()
}
_ = reopened.wait(timeout: .now() + 5)
Thread.sleep(forTimeInterval: 0.3)
if second.now.chunks.count != stopped { fail("sent before it was asked how it goes") }
for _ in 0..<5 {
  _ = state()
  Thread.sleep(forTimeInterval: 0.1)
}
Thread.sleep(forTimeInterval: 1.5)
if second.now.chunks.count < stopped + 20 { fail("nothing came on the channel begun again") }
if let w = second.now.wrong.first { fail("second: \(w)") }
_ = judge("first, all along", again)

let shut = DispatchSemaphore(value: 0)
link.closeAll { shut.signal() }
guard shut.wait(timeout: .now() + 5) == .success else { fail("not closed in 5 s") }
print("PASS")
exit(0)
