import AVFoundation
import Cocoa
import FlutterMacOS

/// The app's interface sounds on the Mac (lib/sounds.dart): a sound's WAV, already at the loudness wanted, played
/// once or over and over (ringing).
final class Sounds: NSObject, AVAudioPlayerDelegate {
  static let shared = Sounds()

  /// What is playing now: kept until it ends, or the ring until it is stopped.
  private var playing: [AVAudioPlayer] = []
  private var looping: AVAudioPlayer?

  /// The `ghost/sound` channel: play (a WAV's bytes, once or looped) and stop.
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/sound", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "play":
        let args = call.arguments as? [String: Any] ?? [:]
        if let data = (args["bytes"] as? FlutterStandardTypedData)?.data {
          self.play(data, loop: args["loop"] as? Bool ?? false, output: args["output"] as? String ?? "")
        }
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Plays the WAV in [data] through [output] (a CoreAudio device UID: the speaker chosen for calls, lib/sounds.dart;
  /// empty or "default" for the system's own); a looped one takes the place of the ring before it. One that can't be
  /// read is not heard. A chosen speaker that is not connected: the system's own.
  private func play(_ data: Data, loop: Bool, output: String) {
    guard let player = try? AVAudioPlayer(data: data) else { return }
    if !output.isEmpty && output != "default" { player.currentDevice = output }
    if loop {
      stop()
      player.numberOfLoops = -1
      looping = player
    } else {
      player.delegate = self
      playing.append(player)
    }
    player.prepareToPlay()
    if !player.play() && player.currentDevice != nil {
      player.currentDevice = nil
      player.prepareToPlay()
      player.play()
    }
  }

  /// Ends the ring; sounds played once run to their end.
  private func stop() {
    looping?.stop()
    looping = nil
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    playing.removeAll { $0 === player }
  }
}
