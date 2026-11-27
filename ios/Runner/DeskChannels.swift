import Flutter
import PhotosUI
import AVFoundation
import Security
import LocalAuthentication
import UIKit
import UserNotifications
import UniformTypeIdentifiers

/// The Mac's DeskChannels.swift (macos/Runner), for the iPhone (Matt, 2026-11-15: "port the app to work on iOS"): what
/// the app asks of iOS itself (lib/desktop/platform.dart): the iPhone's name, the Keychain for the pairing's key, and
/// Bonjour to find the Android phone on the local network. Everything else, the sealing and the connections, is
/// Dart (lib/desktop/link), so it is the same code the tests run.
final class DeskChannels: NSObject, FlutterStreamHandler, NetServiceBrowserDelegate, NetServiceDelegate, PHPickerViewControllerDelegate {
  private var picked: (([String]) -> Void)?
  private let system: FlutterMethodChannel
  private let found: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var browser: NetServiceBrowser?
  private var services: [NetService] = []

  /// Apple's token for this install, as hex, told to the app (nil: Apple would not give one), with whether it is
  /// Apple's sandbox: a build from Xcode is, one from TestFlight or the App Store is not.
  func pushToken(_ token: Data?) {
    let hex = token.map { $0.map { String(format: "%02x", $0) }.joined() }
    system.invokeMethod("pushToken", arguments: ["token": hex as Any, "sandbox": DeskChannels.pushSandbox])
  }

  /// Whether this build's pushes go through Apple's sandbox: its provisioning profile says (`aps-environment`), and
  /// with none (the Simulator) it is the sandbox.
  static let pushSandbox: Bool = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url) else { return true }
    let text = String(decoding: data, as: UTF8.self)
    guard let key = text.range(of: "<key>aps-environment</key>") else { return true }
    return !text[key.upperBound...].prefix(80).contains("production")
  }()

  init(messenger: FlutterBinaryMessenger) {
    system = FlutterMethodChannel(name: "ghost_desktop/system", binaryMessenger: messenger)
    found = FlutterEventChannel(name: "ghost_desktop/bonjour", binaryMessenger: messenger)
    super.init()
    found.setStreamHandler(self)
    // Where the voice message being played has got to, told to the screens as the phone tells its own.
    DeskSound.shared.heard = { [weak self] state in self?.system.invokeMethod("voice", arguments: state) }
    system.setMethodCallHandler { [weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "videoFrame":
        // A frame of the video at `path` as a PNG, for its preview in a Files space (Matt, 2026-11-18: "videos having a
        // frame from the first minute of the video"): a tenth of the way in, at least a second, never past the first
        // minute; at most 480 across. Nil where AVFoundation can't read it.
        guard let path = args["path"] as? String else { return result(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
          let png = videoFramePNG(path)
          DispatchQueue.main.async { result(png.map { FlutterStandardTypedData(bytes: $0) }) }
        }
      case "openLink":
        // A web address in the iPhone's own browser (lib/desktop/platform.dart MacPlatform.openLink): signing up with
        // Discord, a link in a message.
        guard let text = args["url"] as? String, let url = URL(string: text),
              url.scheme == "https" || url.scheme == "http" else { return result(false) }
        UIApplication.shared.open(url, options: [:]) { result($0) }
      case "name":
        // iOS gives apps "iPhone" rather than the name in Settings › General › About.
        result(UIDevice.current.name)
      case "keptDir":
        // Where the app keeps what no backup takes (lib/net/kept_files_io.dart: the ledger the relay is checked by): its
        // own Caches folder, in its container, which iOS never backs up.
        result(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path)
      case "keyRead":
        result(DeskChannels.keychain(read: args["account"] as? String ?? ""))
      case "keyWrite":
        result(DeskChannels.keychain(write: args["account"] as? String ?? "", value: args["value"] as? String ?? ""))
      case "keyDelete":
        result(DeskChannels.keychain(delete: args["account"] as? String ?? ""))
      // The app's own lock (lib/app_lock/app_lock.dart, GMFB-46): Touch ID or Face ID in the PIN's place, where the
      // person switched that on. Only ever yes or no; the PIN is checked in Dart and always works too.
      case "lockBioCan":
        result(LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil))
      case "lockBioAsk":
        let context = LAContext()
        // No "Enter Password" under it: the app's PIN is the other way in, not the device's passcode.
        context.localizedFallbackTitle = ""
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return result(false) }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: args["reason"] as? String ?? "Unlock Uplink") { ok, _ in
          DispatchQueue.main.async { result(ok) }
        }
      // What the message field has on a Mac that the phone has from Android: pictures to choose, the Mac's own
      // emoji, and a voice message to record and to play (DeskSound.swift).
      case "pickPictures":
        self?.pickPictures(most: args["most"] as? Int ?? 5) { result($0) }
      // Waking the app while it is closed (lib/standalone/wake.dart): asked once, then Apple's token comes to
      // AppDelegate, which hands it to [pushToken].
      case "pushRegister":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          DispatchQueue.main.async {
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            result(granted)
          }
        }
      case "emoji":
        // The iPhone's keyboard has its own emoji key.
        result(nil)
      case "voiceStart":
        DeskSound.shared.start(most: args["bytes"] as? Int ?? 0) { result($0) }
      case "voiceLevel":
        result(DeskSound.shared.level())
      case "voiceCancel":
        DeskSound.shared.cancel()
        result(nil)
      case "voiceStop":
        result(DeskSound.shared.stop().map { FlutterStandardTypedData(bytes: $0) })
      case "voicePlay":
        result(DeskSound.shared.play(part: args["part"] as? Int ?? -1, data: (args["bytes"] as? FlutterStandardTypedData)?.data))
      case "voicePause":
        DeskSound.shared.pause()
        result(nil)
      case "voiceHalt":
        DeskSound.shared.halt()
        result(nil)
      case "voiceLength":
        result((args["bytes"] as? FlutterStandardTypedData).map { DeskSound.length(of: $0.data) } ?? 0)
      // A video in a message (DeskVideo.swift): a picture of where it starts, and a window that plays it.
      case "videoPreview":
        guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else { return result(nil) }
        let id = args["id"] as? Int ?? 0, ext = args["ext"] as? String ?? "mp4"
        DispatchQueue.global(qos: .userInitiated).async {
          let made = DeskVideo.preview(data: bytes, id: id, ext: ext)
          DispatchQueue.main.async { result(made) }
        }
      case "videoPlay":
        guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data else { return result("no video") }
        result(DeskVideo.shared.play(data: bytes, id: args["id"] as? Int ?? 0, ext: args["ext"] as? String ?? "mp4", title: args["title"] as? String ?? "Video"))
      case "browse":
        self?.browse()
        result(nil)
      case "stopBrowsing":
        self?.stopBrowsing()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: Choosing pictures

  /// iOS's own photo picker: each picture chosen copied to the app's own folder, its path given; none where it was
  /// put away. It needs no photo library permission: the picker hands over only what is chosen.
  private func pickPictures(most: Int, done: @escaping ([String]) -> Void) {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = max(1, most)
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    picked = done
    guard let top = DeskVideo.topController() else { return done([]) }
    top.present(picker, animated: true)
  }

  /// The picker is done: each picture is copied out while iOS still lends it, and the paths are given in the order
  /// chosen, once every copy has ended.
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let done = picked
    picked = nil
    guard let done else { return }
    if results.isEmpty { return done([]) }
    let group = DispatchGroup()
    var paths = [String?](repeating: nil, count: results.count)
    for (i, r) in results.enumerated() {
      group.enter()
      r.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
        defer { group.leave() }
        guard let url, let to = try? DeskVideo.place(named: "picked-\(UUID().uuidString)-\(url.lastPathComponent)") else { return }
        if (try? FileManager.default.copyItem(at: url, to: to)) != nil { paths[i] = to.path }
      }
    }
    group.notify(queue: .main) { done(paths.compactMap { $0 }) }
  }

  // MARK: The Keychain: the pairing's key, as a generic password of this app's.

  private static let service = Bundle.main.bundleIdentifier ?? "com.infamousvague.ghostmessaging"

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  private static func keychain(read account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Replaces what was kept. Readable once the device has been unlocked after a restart, and never carried to
  /// another device.
  private static func keychain(write account: String, value: String) -> Bool {
    SecItemDelete(query(account) as CFDictionary)
    var q = query(account)
    q[kSecValueData as String] = value.data(using: .utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }

  /// True where nothing is kept under [account] any more, whether or not anything was.
  private static func keychain(delete account: String) -> Bool {
    let status = SecItemDelete(query(account) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  // MARK: Bonjour: phones announcing _ghostmsg._tcp on this network (android DeskService.kt).

  private func browse() {
    if browser != nil { return }
    let b = NetServiceBrowser()
    b.delegate = self
    browser = b
    b.searchForServices(ofType: "_ghostmsg._tcp.", inDomain: "local.")
  }

  private func stopBrowsing() {
    browser?.stop()
    browser = nil
    services.removeAll()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    publish()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// A phone announced itself: it is told to Dart once its address is known (resolved).
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 5)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    services.removeAll { $0 == service }
    publish()
  }

  func netServiceDidResolveAddress(_ sender: NetService) { publish() }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    // It announced and could not be reached by name: asked again while it is still announced.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self = self, self.services.contains(sender) else { return }
      sender.resolve(withTimeout: 5)
    }
  }

  /// Every phone found and resolved: its name, its port, and its addresses as numbers.
  private func publish() {
    let list: [[String: Any]] = services.compactMap { s in
      guard s.port > 0 else { return nil }
      var addresses: [String] = []
      for data in s.addresses ?? [] {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = data.withUnsafeBytes { raw -> Bool in
          guard let base = raw.baseAddress else { return false }
          return getnameinfo(base.assumingMemoryBound(to: sockaddr.self), socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        }
        if ok { addresses.append(String(cString: host)) }
      }
      if addresses.isEmpty, let name = s.hostName { addresses.append(name) }
      if addresses.isEmpty { return nil }
      return ["name": s.name, "port": s.port, "addresses": addresses]
    }
    sink?(list)
  }
}

/// A frame of the video at [path], a tenth of the way in (at least a second, never past the first minute), as a CGImage
/// at most 480 across.
func videoFrameImage(_ path: String) -> CGImage? {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  let secs = CMTimeGetSeconds(asset.duration)
  let at = secs.isFinite && secs > 0 ? min(max(secs * 0.1, min(1, secs / 2)), 60) : 1
  let gen = AVAssetImageGenerator(asset: asset)
  gen.appliesPreferredTrackTransform = true
  gen.maximumSize = CGSize(width: 480, height: 480)
  gen.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
  gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
  return try? gen.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil)
}

/// The same frame as a PNG's bytes, for Dart; nil where the video can't be read.
func videoFramePNG(_ path: String) -> Data? {
  guard let cg = videoFrameImage(path) else { return nil }
  return UIImage(cgImage: cg).pngData()
}
