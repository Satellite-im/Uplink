// A silent check of the music link (macos/Runner/MusicLink.swift, compiled into this very program): a tone of one pitch
// on the left and another on the right goes into the feed, over a real connection on this Mac, and what the other end
// decodes must be those pitches on those sides. No microphone and no speaker: the other end's sound is taken from its
// decoder, and the system is asked all the while whether this process runs any sound device at all.
//
//   tool/spotify/check.sh            the link as it is: must pass
//   tool/spotify/check.sh swapped    left and right swapped on the way in: must fail
//   tool/spotify/check.sh cut        nothing fed: must fail
//   tool/spotify/check.sh            (with no word, all three, and it fails unless each does as it should)

import AVFoundation
import CoreAudio
import Foundation
import WebRTC

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "right"
let leftHz = 440.0, rightHz = 1000.0

/// What arrived, as floats, left and right, kept for the pitches to be read from.
final class Ears: NSObject, RTCAudioRenderer {
  private let lock = NSLock()
  private var left: [Float] = [], right: [Float] = []
  private(set) var channels = 0, rate = 0.0
  func render(pcmBuffer b: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    channels = Int(b.format.channelCount)
    rate = b.format.sampleRate
    let n = Int(b.frameLength), two = channels > 1, inter = b.format.isInterleaved
    for i in 0..<n {
      if let f = b.floatChannelData {
        left.append(inter ? f[0][i * channels] : f[0][i])
        right.append(two ? (inter ? f[0][i * channels + 1] : f[1][i]) : (inter ? f[0][i * channels] : f[0][i]))
      } else if let s = b.int16ChannelData {
        left.append(Float(inter ? s[0][i * channels] : s[0][i]) / 32768)
        right.append(Float(two ? (inter ? s[0][i * channels + 1] : s[1][i]) : s[0][i]) / 32768)
      }
    }
  }
  func last(_ seconds: Double) -> (left: [Float], right: [Float]) {
    lock.lock()
    defer { lock.unlock() }
    let n = Int(seconds * rate)
    return (Array(left.suffix(n)), Array(right.suffix(n)))
  }
}

/// How much of [hz] is in [x]: the size of a tone of that pitch, 0 to 1 (Goertzel).
func amount(_ x: [Float], _ hz: Double, _ rate: Double) -> Double {
  guard !x.isEmpty, rate > 0 else { return 0 }
  let w = 2 * Double.pi * hz / rate, c = 2 * cos(w)
  var a = 0.0, b = 0.0
  for v in x {
    let s = Double(v) + c * a - b
    b = a
    a = s
  }
  let power = a * a + b * b - c * a * b
  return 2 * sqrt(max(0, power)) / Double(x.count)
}

/// Whether the system says this process is running a sound device for input or output. Asks nothing of the person.
func runningSound() -> (input: Bool, output: Bool)? {
  guard #available(macOS 14.2, *) else { return nil }
  var pid = getpid(), object = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
  var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object) == noErr else { return nil }
  if object == 0 { return (false, false) }
  func on(_ s: AudioObjectPropertySelector) -> Bool {
    var v: UInt32 = 0, size = UInt32(4)
    var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr && v != 0
  }
  return (on(kAudioProcessPropertyIsRunningInput), on(kAudioProcessPropertyIsRunningOutput))
}

func fail(_ why: String) -> Never {
  print("FAIL: \(why)")
  exit(1)
}

/// The listener: an ordinary connection that only receives, with a sound device of the same throwaway kind.
final class Listener: NSObject, RTCPeerConnectionDelegate {
  let device = MusicDevice(feed: MusicFeed())
  let factory: RTCPeerConnectionFactory
  let ears = Ears()
  var pc: RTCPeerConnection!
  var track: RTCAudioTrack?
  var found: ((RTCIceCandidate) -> Void)?
  var playedLeft: [Float] = [], playedRight: [Float] = []

  override init() {
    factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
    super.init()
    // WebRTC decodes only as a device asks for sound to play: it is asked, and what comes is kept here, not played.
    device.played = { [weak self] p, n in
      guard let self else { return }
      for i in 0..<n {
        self.playedLeft.append(Float(p[i * 2]) / 32768)
        self.playedRight.append(Float(p[i * 2 + 1]) / 32768)
      }
    }
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
  func peerConnection(_ p: RTCPeerConnection, didOpen d: RTCDataChannel) {}
  func peerConnection(_ p: RTCPeerConnection, didAdd r: RTCRtpReceiver, streams: [RTCMediaStream]) {
    // Kept: the renderers go with the object they were added to.
    if let t = r.track as? RTCAudioTrack {
      track = t
      t.add(ears)
    }
  }
}

setvbuf(stdout, nil, _IOLBF, 0)
guard RTCInitializeSSL() else { fail("no SSL") }
let link = MusicLink()
var listeners: [String: Listener] = [:]
var states: [String: RTCPeerConnectionState] = [:]
let book = NSLock()
link.onCandidate = { id, c in
  book.lock()
  let l = listeners[id]
  book.unlock()
  l?.pc.add(c) { _ in }
}
link.onState = { id, s in
  book.lock()
  states[id] = s
  book.unlock()
}
var opened = false, heard = false

// The tone, as it would come from the tap: a block at a time, by the clock.
let feeder = Thread {
  var t = 0
  var block = [Int16](repeating: 0, count: 480 * 2)
  var due = Date()
  while true {
    for i in 0..<480 {
      let l = Int16(8000 * sin(2 * Double.pi * leftHz * Double(t) / 48000))
      let r = Int16(8000 * sin(2 * Double.pi * rightHz * Double(t) / 48000))
      block[i * 2] = mode == "swapped" ? r : l
      block[i * 2 + 1] = mode == "swapped" ? l : r
      t += 1
    }
    if mode != "cut" { link.feed.write(block, frames: 480) }
    due += 0.01
    Thread.sleep(until: due)
  }
}
feeder.qualityOfService = .userInteractive
feeder.start()

/// One listener, linked, heard for [seconds], and what it heard held to what went in.
func listen(_ id: String, seconds: Double) -> Listener {
  let listener = Listener()
  book.lock()
  listeners[id] = listener
  book.unlock()
  listener.found = { c in link.candidate(from: id, c) }
  let described = DispatchSemaphore(value: 0)
  var wrong: String?
  link.offer(to: id, servers: [], relayOnly: false) { sdp in
    guard let sdp else {
      wrong = "no offer"
      described.signal()
      return
    }
    print("\(id) offered:", sdp.components(separatedBy: "\r\n").filter { $0.contains("opus") || $0.hasPrefix("a=fmtp:111") || $0.hasPrefix("a=send") }.joined(separator: " | "))
    listener.pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { e in
      if let e { wrong = "offer not taken: \(e)" }
      listener.pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, e in
        guard let answer else {
          wrong = "no answer: \(String(describing: e))"
          described.signal()
          return
        }
        // As the listeners' side does in lib/voice/spotify_link.dart: stereo asked for in its own answer.
        let mine = RTCSessionDescription(type: .answer, sdp: MusicSdp.tuned(answer.sdp))
        listener.pc.setLocalDescription(mine) { e in
          if let e { wrong = "answer not set: \(e)" }
          link.answer(from: id, sdp: mine.sdp) { ok in
            if !ok { wrong = "answer not taken" }
            described.signal()
          }
        }
      }
    }
  }
  if described.wait(timeout: .now() + 10) != .success { fail("no description in 10 s") }
  if let wrong { fail(wrong) }
  for _ in 0..<Int(seconds * 10) {
    Thread.sleep(forTimeInterval: 0.1)
    if let r = runningSound() {
      opened = opened || r.input
      heard = heard || r.output
    }
  }
  book.lock()
  let state = states[id]
  book.unlock()
  guard state == .connected else { fail("\(id) not connected: \(state?.rawValue ?? -1)") }
  let e = listener.ears.last(1.0), rate = listener.ears.rate
  let l440 = amount(e.left, leftHz, rate), l1000 = amount(e.left, rightHz, rate)
  let r440 = amount(e.right, leftHz, rate), r1000 = amount(e.right, rightHz, rate)
  print(String(format: "%@ decoded: %d channels at %.0f Hz; left %.4f at 440 and %.4f at 1000; right %.4f at 440 and %.4f at 1000", id, listener.ears.channels, rate, l440, l1000, r440, r1000))
  let reported = DispatchSemaphore(value: 0)
  listener.pc.statistics { r in
    for s in r.statistics.values where s.type == "inbound-rtp" {
      print("\(id) received:", s.values["bytesReceived"] ?? 0, "bytes,", s.values["packetsReceived"] ?? 0, "packets,", s.values["concealedSamples"] ?? 0, "samples made up")
    }
    reported.signal()
  }
  _ = reported.wait(timeout: .now() + 3)
  // The tones went in at 8000 of 32768: 0.244. Through Opus each should be near that on its own side, and near nothing
  // on the other.
  guard listener.ears.channels == 2 else { fail("not stereo: \(listener.ears.channels) channel") }
  guard l440 > 0.15, r1000 > 0.15 else { fail("the tones did not arrive on their sides") }
  guard l1000 < l440 * 0.05, r440 < r1000 * 0.05 else { fail("one side's tone is on the other") }
  return listener
}

// Two listeners at once, each on a connection of its own.
let one = listen("first", seconds: 4)
let two = listen("second", seconds: 3)
let before = link.feed.starved

// One drops and asks again: its connection is made anew and the other's goes on.
one.pc.close()
let again = listen("first", seconds: 3)
let still = two.ears.last(0.5)
guard amount(still.left, leftHz, 48000) > 0.15 else { fail("the other listener went quiet as one came back") }
print("silence sent for want of music: \(link.feed.starved - before) frames")
guard link.feed.starved - before == 0 else { fail("the feed ran dry") }
print("this process ran a microphone: \(opened), a speaker: \(heard)")
if opened { fail("a microphone was opened") }
if heard { fail("a speaker was opened") }

// Stopped: nothing more arrives.
let shut = DispatchSemaphore(value: 0)
link.closeAll { shut.signal() }
guard shut.wait(timeout: .now() + 5) == .success else { fail("not closed in 5 s") }
guard link.listeners.isEmpty else { fail("a connection was left") }
_ = again
print("PASS")
exit(0)
