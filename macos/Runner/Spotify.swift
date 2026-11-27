import AppKit
import FlutterMacOS
import Foundation
import WebRTC

/// Spotify in a circle's calls, the Mac's half (lib/voice/spotify_app.dart; Matt, 2026-11-25: "add a spotify plugin for
/// circles that allows a user to add songs to a queue and play them from spotify"): the `ghost/spotify` channel.
///
/// - Spotify's own buttons, pressed by AppleScript: play a song, pause, go on, seek, and what it is playing. Nothing of
///   Spotify's is decoded or signed in to here, and it is never opened: where it is not running, that is what is said.
///   The only thing ever put into a script is a track's id, and only one of 22 letters and digits.
/// - Its sound (SpotifySound.swift), and the connections that send it (MusicLink.swift).
///
/// Nothing here runs until this Mac's person pressed Start (lib/ui/spotify_panel.dart).
final class Spotify: NSObject {
  static let shared = Spotify()
  private var channel: FlutterMethodChannel?
  /// Where the scripts run, one at a time and never on the main thread: Spotify can take its time to answer.
  private let scripts = DispatchQueue(label: "ghost.spotify.script", qos: .userInitiated)
  private var link: MusicLink?
  private var sound: AnyObject?
  private var quitting: NSObjectProtocol?

  private static let bundle = "com.spotify.client"
  private static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/spotify", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) ?? result(nil) }
    self.channel = channel
    // The app closing takes the tap and the connections with it.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.end(nil) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "able":
      var new = false
      if #available(macOS 14.4, *) { new = true }
      result(["system": new, "installed": NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle) != nil, "running": Self.running])

    // Spotify's buttons. Each answers what Spotify then is, or throws: closed, denied, or failed.
    case "now":
      run(Self.reading, result)
    case "play":
      guard let id = args["id"] as? String, Self.isTrack(id) else { return result(FlutterError(code: "bad", message: "not a track", details: nil)) }
      run("play track \"spotify:track:\(id)\"\nreturn {}", result)
    case "pause":
      run("pause\nreturn {}", result)
    case "resume":
      run("play\nreturn {}", result)
    case "seek":
      let ms = max(0, args["ms"] as? Int ?? 0)
      run("set player position to \(ms / 1000)\nreturn {}", result)

    // Its sound, and the connections.
    case "begin":
      begin(result)
    case "end":
      end { result(nil) }
    case "level":
      if #available(macOS 14.4, *) { result((sound as? SpotifySound)?.level() ?? 0) } else { result(0.0) }
    case "offer":
      guard let link, let id = args["id"] as? String else { return result(nil) }
      let servers = (args["servers"] as? [[String: Any]] ?? []).compactMap(Self.server)
      link.offer(to: id, servers: servers, relayOnly: args["relay"] as? Bool ?? false, lossless: args["lossless"] as? Bool ?? false) { sdp in DispatchQueue.main.async { result(sdp) } }
    case "answer":
      guard let link, let id = args["id"] as? String, let sdp = args["sdp"] as? String else { return result(false) }
      link.answer(from: id, sdp: sdp) { ok in DispatchQueue.main.async { result(ok) } }
    case "ice":
      if let link, let id = args["id"] as? String, let c = args["candidate"] as? String {
        link.candidate(from: id, RTCIceCandidate(sdp: c, sdpMLineIndex: Int32(args["sdpMLineIndex"] as? Int ?? 0), sdpMid: args["sdpMid"] as? String))
      }
      result(nil)
    // Without loss, beside the Opus on the same connection.
    case "lossless":
      guard let link, let id = args["id"] as? String else { return result(false) }
      if args["on"] as? Bool ?? false {
        link.openLossless(id) { ok in DispatchQueue.main.async { result(ok) } }
      } else {
        link.closeLossless(id)
        result(true)
      }
    case "losslessState":
      guard let link else { return result([:] as [String: Any]) }
      link.losslessState { all in
        let said = all.mapValues { s in
          var m: [String: Any] = ["open": s.open, "bytes": s.bytes, "dropped": s.dropped]
          if let relay = s.relay { m["relay"] = relay }
          return m
        }
        DispatchQueue.main.async { result(said) }
      }
    // The rate Spotify's sound is taken at, 0 where it isn't yet: below 44,100 it is not the music whole.
    case "rate":
      if #available(macOS 14.4, *), let s = sound as? SpotifySound { s.rate { hz in DispatchQueue.main.async { result(hz) } } } else { result(0.0) }
    case "close":
      if let id = args["id"] as? String { link?.close(id) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // --- Spotify's buttons -----------------------------------------------------------------------------------------------

  /// A track's id: 22 letters and digits, and nothing else.
  static func isTrack(_ id: String) -> Bool { id.utf8.count == 22 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) } }

  /// What it is playing: its state, then the track's id, name, artist, picture, length in milliseconds and where it is
  /// in seconds. The state alone where there is no track.
  private static let reading = """
  set s to player state as string
  if s is "stopped" then return {s}
  set t to current track
  return {s, id of t, name of t, artist of t, artwork url of t, duration of t, player position}
  """

  /// Runs [body] told to Spotify, where Spotify is running, off the main thread.
  private func run(_ body: String, _ result: @escaping FlutterResult) {
    func answer(_ v: Any?) { DispatchQueue.main.async { result(v) } }
    scripts.async {
      // `tell` would open Spotify where it is closed; it is never opened from here.
      guard Self.running else { return answer(FlutterError(code: "closed", message: "Spotify isn't open.", details: nil)) }
      let source = "with timeout of 4 seconds\ntell application id \"\(Self.bundle)\"\n\(body)\nend tell\nend timeout"
      var wrong: NSDictionary?
      let said = autoreleasepool { NSAppleScript(source: source)?.executeAndReturnError(&wrong) }
      if let wrong {
        let code = wrong[NSAppleScript.errorNumber] as? Int ?? 0
        // errAEEventNotPermitted: the person said no to macOS's question, or switched it off in Privacy › Automation.
        return answer(FlutterError(code: code == -1743 ? "denied" : code == -600 || code == -609 ? "closed" : "failed", message: wrong[NSAppleScript.errorMessage] as? String, details: code))
      }
      answer(Self.read(said))
    }
  }

  private static func read(_ d: NSAppleEventDescriptor?) -> [String: Any] {
    guard let d, d.numberOfItems >= 1 else { return [:] }
    var out: [String: Any] = ["state": d.atIndex(1)?.stringValue ?? "stopped"]
    guard d.numberOfItems >= 7 else { return out }
    out["id"] = d.atIndex(2)?.stringValue ?? ""
    out["name"] = d.atIndex(3)?.stringValue ?? ""
    out["artist"] = d.atIndex(4)?.stringValue ?? ""
    out["art"] = d.atIndex(5)?.stringValue ?? ""
    out["length"] = Int(d.atIndex(6)?.doubleValue ?? 0)
    out["position"] = Int((d.atIndex(7)?.doubleValue ?? 0) * 1000)
    return out
  }

  // --- its sound, and the connections ------------------------------------------------------------------------------------

  /// Begins taking Spotify's sound, ready to be sent. Answers nil, or why not.
  private func begin(_ result: @escaping FlutterResult) {
    guard #available(macOS 14.4, *) else { return result("Playing Spotify to a call needs macOS 14.4 or later.") }
    if link == nil {
      let l = MusicLink()
      l.onCandidate = { [weak self] id, c in
        DispatchQueue.main.async { self?.channel?.invokeMethod("ice", arguments: ["id": id, "candidate": c.sdp, "sdpMid": c.sdpMid ?? "", "sdpMLineIndex": Int(c.sdpMLineIndex)]) }
      }
      l.onState = { [weak self] id, s in
        let word = switch s { case .connected: "connected"; case .disconnected: "disconnected"; case .failed: "failed"; case .closed: "closed"; default: "connecting" }
        DispatchQueue.main.async { self?.channel?.invokeMethod("link", arguments: ["id": id, "state": word]) }
      }
      link = l
    }
    if quitting == nil {
      quitting = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.bundle { self?.channel?.invokeMethod("quit", arguments: nil) }
      }
    }
    let s = sound as? SpotifySound ?? SpotifySound(feed: link!.feed)
    sound = s
    s.start { why in
      DispatchQueue.main.async {
        if why != nil { self.end(nil) }
        result(why)
      }
    }
  }

  /// Ends all of it: no tap, no device, no connection left.
  private func end(_ done: (() -> Void)?) {
    if let quitting { NSWorkspace.shared.notificationCenter.removeObserver(quitting) }
    quitting = nil
    let l = link
    link = nil
    if #available(macOS 14.4, *) { (sound as? SpotifySound)?.stop() }
    sound = nil
    guard let l else {
      done?()
      return
    }
    // Held until it is closed: the factory goes off the main thread, after its connections.
    l.closeAll { DispatchQueue.main.async { done?() } }
    l.queue.async { _ = l }
  }

  /// A server to find a way through by, as the call has it (lib/voice/rtc.dart, RtcMedia.iceServers).
  private static func server(_ m: [String: Any]) -> RTCIceServer? {
    let urls = m["urls"] as? [String] ?? (m["urls"] as? String).map { [$0] } ?? (m["url"] as? String).map { [$0] } ?? []
    if urls.isEmpty { return nil }
    guard let name = m["username"] as? String, let word = m["credential"] as? String else { return RTCIceServer(urlStrings: urls) }
    return RTCIceServer(urlStrings: urls, username: name, credential: word)
  }
}
