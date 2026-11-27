// A silent check of the Mac's player for the music without loss (macos/Runner/MusicSink.swift, compiled into this very
// program): its engine renders into memory and no device is opened. What it was given must come out as it was, and how
// loud, running out and starting again as they should.

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var wrong = 0
func check(_ ok: Bool, _ what: String) {
  if !ok {
    print("FAIL: \(what)")
    wrong += 1
  }
}

func sample(_ n: Int, _ side: Int) -> Int16 { Int16(truncatingIfNeeded: (n &* 2 &+ side) &* 40503 &+ (n >> 3)) }
func block(_ from: Int, _ frames: Int) -> Data {
  var d = Data(capacity: frames * 4)
  for i in from..<from + frames {
    for side in 0..<2 { withUnsafeBytes(of: sample(i, side).littleEndian) { d.append(contentsOf: $0) } }
  }
  return d
}

let player = MusicPlayer()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try player.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
try player.engine.start()
let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
func render(_ frames: Int) -> (l: [Float], r: [Float]) {
  var l: [Float] = [], r: [Float] = []
  while l.count < frames {
    let n = min(512, frames - l.count)
    guard try! player.engine.renderOffline(AVAudioFrameCount(n), to: out) == .success else { fatalError("not rendered") }
    l += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
    r += UnsafeBufferPointer(start: out.floatChannelData![1], count: Int(out.frameLength))
  }
  return (l, r)
}
func same(_ got: (l: [Float], r: [Float]), from: Int, times: Float = 1) -> Bool {
  for i in 0..<got.l.count where got.l[i] != Float(sample(from + i, 0)) / 32768 * times || got.r[i] != Float(sample(from + i, 1)) / 32768 * times { return false }
  return true
}

check(render(1000).l.allSatisfy { $0 == 0 }, "nothing given is silence")
var now = player.ring.write(block(0, 20000))
check(now.waiting == 20000 && now.dry == 0, "what waits is counted, and not having begun is not running out")
check(render(1024).l.allSatisfy { $0 == 0 }, "silent until it is heard")
player.ring.set(1)
let rise = render(2048)
check(abs(rise.l[0]) < 0.01 && !same((Array(rise.l[0..<1000]), Array(rise.r[0..<1000])), from: 1024), "it rises, and does not start")
check(same((Array(rise.l[1500...]), Array(rise.r[1500...])), from: 1024 + 1500), "and then it is bit for bit what it was given")
check(same(render(8192), from: 1024 + 2048), "and goes on so")
player.ring.set(0.5)
_ = render(2048)
check(same(render(1024), from: 1024 + 2048 + 8192 + 2048, times: 0.5), "half as loud")
player.ring.set(0)
_ = render(2048)
check(render(512).l.allSatisfy { $0 == 0 }, "silent: deafened, or proved first")
player.ring.set(1)
_ = render(2048)
now = player.ring.write(block(20000, 100))
let left = now.waiting
let tail = render(left + 500)
check(same((Array(tail.l[0..<left]), Array(tail.r[0..<left])), from: 20100 - left), "to the last of it")
check(tail.l[left...].allSatisfy { $0 == 0 }, "then silence")
now = player.ring.write(block(0, 480))
check(now.dry == 1 && now.waiting == 480, "that it ran out is counted, once")
check(same(render(480), from: 0), "and it begins again at once, as loud as it was")
_ = render(480)
_ = player.ring.write(block(0, 48000))
now = player.ring.write(block(48000, 480000))
check(now.waiting == 144000, "no more than three seconds is ever held")
player.ring.clear()
now = player.ring.write(Data())
check(now.waiting == 0, "forgotten")
let dry = now.dry
_ = render(1000)
check(player.ring.write(Data([1, 2, 3])).dry == dry, "forgetting is not running out, and part of a frame is nothing")
let way = MusicOut.way("")
print("where this Mac's sound goes, as the app would have it:", way)
check(["headphones", "speakers", "unknown", "call", "none"].contains(way["to"] as? String), "where it goes is said")
check(MusicOut.device("no such device") == MusicOut.device(""), "a device that is gone is the system's own")
player.engine.stop()
print(wrong == 0 ? "PASS" : "\(wrong) wrong")
exit(wrong == 0 ? 0 : 1)
