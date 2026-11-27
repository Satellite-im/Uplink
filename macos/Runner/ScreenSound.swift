import AppKit
import FlutterMacOS
import Foundation
import WebRTC

/// What the Mac plays, sent with a shared screen (lib/voice/screen_sound.dart; GMFB-63, Matt, 2026-11-25: "Screen
/// shares should include audio controls but there are none and users can't hear any audio from the share"): the
/// `ghost/screen_sound` channel.
///
/// flutter_webrtc gives a Mac no sound with a captured screen, so it is taken here as Spotify's is for a call's music:
/// a Core Audio tap (SpotifySound.swift), here of everything the Mac plays but this app's own sound, so the call is
/// never sent back into itself, sent on connections of its own (MusicLink.swift), one to each viewer who asked. The
/// microphone, the call's own connections and its recordings know nothing of it.
///
/// Whichever window is shared, it is everything the Mac plays: an app's sound is often made by a helper that is not
/// its own (a web page's in Safari is WebKit's), and a tap of the window's app alone would be silent for those.
///
/// Nothing here runs until this Mac's person shares a screen with its sound. macOS 14.4 and later, which asks them
/// for "System Audio Recording" the first time; refused, what is sent is silence.
final class ScreenSound: NSObject {
  static let shared = ScreenSound()
  private var channel: FlutterMethodChannel?
  private var link: MusicLink?
  private var sound: AnyObject?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/screen_sound", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) ?? result(nil) }
    self.channel = channel
    // The app closing takes the tap and the connections with it.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.end(nil) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "able":
      if #available(macOS 14.4, *) { result(true) } else { result(false) }
    case "begin":
      begin(result)
    case "end":
      end { result(nil) }
    case "level":
      if #available(macOS 14.4, *) { result((sound as? SpotifySound)?.level() ?? 0) } else { result(0.0) }
    case "offer":
      guard let link, let id = args["id"] as? String else { return result(nil) }
      let servers = (args["servers"] as? [[String: Any]] ?? []).compactMap(Self.server)
      link.offer(to: id, servers: servers, relayOnly: args["relay"] as? Bool ?? false, lossless: false) { sdp in DispatchQueue.main.async { result(sdp) } }
    case "answer":
      guard let link, let id = args["id"] as? String, let sdp = args["sdp"] as? String else { return result(false) }
      link.answer(from: id, sdp: sdp) { ok in DispatchQueue.main.async { result(ok) } }
    case "ice":
      if let link, let id = args["id"] as? String, let c = args["candidate"] as? String {
        link.candidate(from: id, RTCIceCandidate(sdp: c, sdpMLineIndex: Int32(args["sdpMLineIndex"] as? Int ?? 0), sdpMid: args["sdpMid"] as? String))
      }
      result(nil)
    case "close":
      if let id = args["id"] as? String { link?.close(id) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Begins taking what the Mac plays, ready to be sent. Answers nil, or why not.
  private func begin(_ result: @escaping FlutterResult) {
    guard #available(macOS 14.4, *) else { return result("Sharing your Mac's sound needs macOS 14.4 or later.") }
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
    let ours = Bundle.main.bundleIdentifier ?? "com.infamousvague.ghostmessaging"
    let s = sound as? SpotifySound ?? SpotifySound(feed: link!.feed, what: .allBut(ours), name: "Uplink screen sound", cant: "What this Mac plays could not be taken.")
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
