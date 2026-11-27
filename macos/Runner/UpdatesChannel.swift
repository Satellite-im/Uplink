import Cocoa
import CryptoKit
import FlutterMacOS
import Security

/// The Mac app's own updates (lib/desktop/updates.dart), so a copy that is installed is never installed again by
/// hand (Matt, 2026-11-13: "install the app on my mac and make sure it has OTA updates so we don't need to reinstall
/// again"). This is Ghost.md's Mac updater (macos/Runner/UpdatesChannel.swift at the repository's root, proven there
/// since 2026-10-24) with this app's names and places; the steps are the same.
///
/// WHAT IT IS HANDED is the zip `https://gogho.st/mac.json` describes (tool/release-mac.mjs), which Dart
/// downloaded, with the size and SHA-256 that description gives. Here it is first held to both. Then what only the
/// Mac can answer is asked of what came out of the zip, before the running app is touched at all:
/// - that it is one app, with this app's bundle id, and a `CFBundleVersion` above this one's (never a step back);
/// - that its signature is whole (every architecture, every nested framework and library, strictly) and is this
///   app's team's: `anchor apple generic and certificate leaf[subject.OU] = <this app's team>`. That is what makes an
///   update believed: only Matt's Developer ID signs as that team, whatever the server or the network say. A debug
///   build signed ad hoc, which has no team, takes any whole signature, so a local test can be run; a release with
///   no team takes nothing, since it could not tell a real update from any other app.
///
/// HOW IT IS PUT IN PLACE: unpacked beside the running app, in a hidden folder of the same folder
/// (`/Applications/.Uplink.app-update`, named for the installed copy's own file, whatever that is called), so the swap is a rename on one volume. `restart` swaps the two
/// bundles in one step (`renamex_np` with `RENAME_SWAP`: there is never a moment with no app at the path), starts a
/// small shell helper, and quits. The helper waits for this process to end, opens the app at the same path (now the
/// new version), and waits for it to say it opened (it writes `launched-<build>` as this file's `settle` runs). Only
/// then is the old version, kept in the hidden folder until now, removed; if the new one has not opened in two
/// minutes, the helper puts the old one back and opens that. Quitting the app while an update is in place swaps it
/// in the same way, and the next launch is the new version; that launch removes the old one.
///
/// WHERE IT CANNOT: an app running from a read-only volume, from where it was downloaded (App Translocation), or
/// from a folder this account cannot write to is not replaced. `install` answers `manual: <why>`.
///
/// The app is not sandboxed (Runner/Release.entitlements): a sandboxed app cannot replace itself.
final class UpdatesChannel: NSObject {
  private var channel: FlutterMethodChannel?

  /// The new version, unpacked and checked, waiting for a restart or a quit.
  private var staged: Staged?

  /// Whether this launch is the first of a version this app put in place itself (`settle`).
  private let justUpdated: Bool

  struct Staged {
    /// The hidden folder beside the app: the new version until the swap, the old one after it.
    let folder: URL
    /// The new app inside [folder].
    let app: URL
    let version: String
    let build: Int
  }

  init(messenger: FlutterBinaryMessenger) {
    justUpdated = UpdatesChannel.settle()
    super.init()
    let channel = FlutterMethodChannel(name: "ghost_desktop/updates", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in self?.asked(call, result) }
    self.channel = channel
    NotificationCenter.default.addObserver(self, selector: #selector(quitting), name: NSApplication.willTerminateNotification, object: nil)
  }

  // MARK: where things are

  /// This app's version and build, as its Info.plist has them.
  static var ownVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
  static var ownBuild: Int { build(of: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")) }

  /// A `CFBundleVersion` as a number: 2003016, or 2003016 for "2003016.2" (a store upload's), 0 for nothing.
  static func build(of value: Any?) -> Int {
    guard let said = value as? String else { return 0 }
    return Int(said.split(separator: ".").first ?? "") ?? 0
  }

  /// `~/Library/Caches/<bundle id>`: this app's own folder for what an update leaves.
  static var cache: URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.infamousvague.ghostmessaging.mac", isDirectory: true)
  }

  /// `<cache>/updates`: where Dart keeps the download (Dart empties it before each).
  static var downloads: URL? { cache?.appendingPathComponent("updates", isDirectory: true) }

  /// `<cache>/update-install`: what an install leaves for the next launch and for its helper. Not [downloads], which
  /// Dart empties.
  static var state: URL? { cache?.appendingPathComponent("update-install", isDirectory: true) }

  /// The hidden folder an update is unpacked into, beside [app]: `.Uplink.app-update`, or `.Ghost Messaging.app-update` beside a copy installed under that name.
  static func folder(beside app: URL) -> URL {
    app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent)-update", isDirectory: true)
  }

  // MARK: the launch after an install

  /// Says this version opened (`launched-<build>`, which the helper waits for), and tidies what an install left:
  /// the old version once the new one is the one running, or a new one that never became it. Answers whether this
  /// is the first launch of a version this app put in place.
  static func settle() -> Bool {
    guard let state = state else { return false }
    let manager = FileManager.default
    try? manager.createDirectory(at: state, withIntermediateDirectories: true)
    let build = ownBuild
    try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: state.appendingPathComponent("launched-\(build)"), atomically: true, encoding: .utf8)
    let pending = state.appendingPathComponent("pending.json")
    guard let data = try? Data(contentsOf: pending), let said = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    try? manager.removeItem(at: pending)
    // Only ever the folder an install made, beside this very app: nothing else is removed by what a file says.
    if let path = said["folder"] as? String, URL(fileURLWithPath: path).standardizedFileURL == folder(beside: Bundle.main.bundleURL).standardizedFileURL {
      try? manager.removeItem(atPath: path)
    }
    let updated = (said["build"] as? Int) == build
    log(updated ? "opened as \(ownVersion) (\(build)), the version put in place" : "opened as \(ownVersion) (\(build)), not the \(said["build"] ?? "?") put in place: it was left")
    return updated
  }

  // MARK: the channel

  /// `installed` (this version, and where a download goes), `install` (check and unpack a download, off the main
  /// thread: "ready", "manual: <why>", or why not) and `restart`.
  private func asked(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "installed":
      guard let dir = UpdatesChannel.downloads else { return result(nil) }
      result(["version": UpdatesChannel.ownVersion, "versionCode": UpdatesChannel.ownBuild, "dir": dir.path, "updated": justUpdated])
    case "install":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let path = args["path"] as? String, let sha256 = args["sha256"] as? String, let bytes = args["bytes"] as? Int else { return result("no file") }
      DispatchQueue.global(qos: .userInitiated).async {
        let answer = Result { () throws -> Staging in
          let zip = URL(fileURLWithPath: path)
          if let why = UpdatesChannel.downloadRefused(zip, sha256: sha256, bytes: bytes) { throw Refusal(why) }
          return try UpdatesChannel.stage(zip: zip)
        }
        DispatchQueue.main.async { [weak self] in
          switch answer {
          case .success(.ready(let staged)):
            self?.staged = staged
            result("ready")
          case .success(.manual(let why)):
            result("manual: \(why)")
          case .failure(let failure):
            UpdatesChannel.log("not put in place: \(failure)")
            result("\(failure)")
          }
        }
      }
    case "restart":
      result(restart())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: putting it in place

  /// How unpacking ended: the new version waiting to be swapped in, or why the person must replace the app by hand.
  enum Staging {
    case ready(Staged)
    case manual(String)
  }

  /// Why an update was not put in place, in words: they are the answer Dart gets.
  struct Refusal: Error, CustomStringConvertible {
    let description: String
    init(_ words: String) { description = words }
  }

  /// Why the file at [zip] is not the one the release describes, or nil when it is: its size, then its SHA-256.
  static func downloadRefused(_ zip: URL, sha256: String, bytes: Int) -> String? {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? Int else { return "the download is gone" }
    guard size == bytes else { return "the download is \(size) bytes, not the \(bytes) the release says" }
    guard let handle = try? FileHandle(forReadingFrom: zip) else { return "the download could not be read" }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = handle.readData(ofLength: 1 << 20)
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    let found = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return found == sha256.lowercased() ? nil : "the download is not the file the release describes"
  }

  /// Whether this app can replace itself where it is, or why not, in a sentence for the update card.
  static func cannotReplace(_ app: URL) -> String? {
    let parent = app.deletingLastPathComponent()
    if app.path.contains("/AppTranslocation/") { return "Uplink is running from where it was downloaded. Move it to Applications first." }
    if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return "Uplink is running from a disk that can’t be written to." }
    let manager = FileManager.default
    if !manager.isWritableFile(atPath: parent.path) || !manager.isWritableFile(atPath: app.path) { return "Uplink can’t write to \(parent.path)." }
    return nil
  }

  /// Unpacks [zip] beside the running app and checks what came out (the header). Never touches the running app.
  static func stage(zip: URL) throws -> Staging {
    let target = Bundle.main.bundleURL.standardizedFileURL
    if let why = cannotReplace(target) { return .manual(why) }
    let manager = FileManager.default
    let folder = folder(beside: target)
    try? manager.removeItem(at: folder)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false)
    // Every refusal from here takes the hidden folder with it: nothing half unpacked is left beside the app.
    func refuse(_ words: String) -> Refusal {
      try? manager.removeItem(at: folder)
      return Refusal(words)
    }
    guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else { throw refuse("the download would not unpack") }
    let inside = (try? manager.contentsOfDirectory(atPath: folder.path))?.filter { $0 != "__MACOSX" } ?? []
    guard inside.count == 1, let name = inside.first, name.hasSuffix(".app") else { throw refuse("the download is not one app") }
    let app = folder.appendingPathComponent(name, isDirectory: true)
    // The plist read from the file, not through `Bundle(url:)`, which keeps what it read of a path for good.
    guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { throw refuse("the download has no Info.plist") }
    guard plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw refuse("the download is another app") }
    let build = build(of: plist["CFBundleVersion"]), version = plist["CFBundleShortVersionString"] as? String ?? "?"
    guard build > ownBuild else { throw refuse("the download is not newer than this version") }
    if let why = signatureRefused(app) { throw refuse(why) }
    if hasQuarantine(app) { _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path]) }
    // For the next launch: which build was put in place, and the folder to tidy.
    if let state = state {
      try? manager.createDirectory(at: state, withIntermediateDirectories: true)
      let pending: [String: Any] = ["build": build, "version": version, "folder": folder.path]
      if let data = try? JSONSerialization.data(withJSONObject: pending) { try? data.write(to: state.appendingPathComponent("pending.json"), options: .atomic) }
    }
    log("\(version) (\(build)) unpacked and checked beside \(target.path)")
    return .ready(Staged(folder: folder, app: app, version: version, build: build))
  }

  /// Why [app]'s signature is not this app's team's, or nil when it is (the header).
  static func signatureRefused(_ app: URL) -> String? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return "the download’s signature could not be read" }
    var requirement: SecRequirement?
    if let team = ownTeam() {
      guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess else { return "the team’s requirement could not be made" }
    } else {
      #if !DEBUG
      return "this copy of Uplink is not signed by its developer, so it can’t tell a real update from another app"
      #endif
    }
    let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
    var error: Unmanaged<CFError>?
    let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
    guard status == errSecSuccess else {
      // A whole signature by somebody else is the requirement failing; anything else is a signature that is not whole.
      if status == errSecCSReqFailed { return "the download is not signed by Uplink’s developer" }
      log("the download's signature: \(error?.takeRetainedValue().localizedDescription ?? "") (\(status))")
      return "the download’s signature is not whole (\(status))"
    }
    return nil
  }

  /// The team this running app is signed by, or nil for an ad hoc signature.
  static func ownTeam() -> String? {
    var running: SecCode?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return nil }
    var code: SecStaticCode?
    guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }

  /// Whether macOS marked [url] as downloaded (quarantined), which would have Gatekeeper ask before it opens.
  static func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
  }

  // MARK: swapping it in

  /// Swaps the new version in for the running one, if one is in place and was not swapped yet. Answers where the
  /// old one now is, or why nothing moved.
  private func swap() -> Result<URL, Refusal> {
    guard let staged = staged else { return .failure(Refusal("nothing is in place to restart into")) }
    let target = Bundle.main.bundleURL.standardizedFileURL
    let manager = FileManager.default
    guard manager.fileExists(atPath: staged.app.path) else { return .failure(Refusal("the new version is gone from \(staged.folder.path)")) }
    self.staged = nil
    // One step, where the volume can (APFS): the two paths trade places.
    if renamex_np(staged.app.path, target.path, UInt32(RENAME_SWAP)) == 0 {
      UpdatesChannel.log("swapped in \(staged.version) (\(staged.build)); the old version is kept at \(staged.app.path)")
      return .success(staged.app)
    }
    // Two, where it cannot: the old aside, then the new in, and the old back if the new would not go.
    let aside = staged.folder.appendingPathComponent("previous.app", isDirectory: true)
    do {
      try manager.moveItem(at: target, to: aside)
    } catch {
      return .failure(Refusal("the old version could not be moved aside (\(error.localizedDescription))"))
    }
    do {
      try manager.moveItem(at: staged.app, to: target)
    } catch {
      try? manager.moveItem(at: aside, to: target)
      return .failure(Refusal("the new version could not be moved in (\(error.localizedDescription))"))
    }
    UpdatesChannel.log("moved in \(staged.version) (\(staged.build)); the old version is kept at \(aside.path)")
    return .success(aside)
  }

  /// "Restart to update": swap, start the helper that opens the new version, and quit.
  private func restart() -> String {
    guard let staged = staged, let state = UpdatesChannel.state else { return "nothing is in place to restart into" }
    let target = Bundle.main.bundleURL.standardizedFileURL
    switch swap() {
    case .failure(let refusal):
      return refusal.description
    case .success(let old):
      let script = state.appendingPathComponent("install.sh")
      do {
        try UpdatesChannel.helper.write(to: script, atomically: true, encoding: .utf8)
      } catch {
        // The new version is in place already; with no helper it is simply not opened for the person.
        UpdatesChannel.log("no helper: \(error)")
      }
      let marker = state.appendingPathComponent("launched-\(staged.build)")
      let helper = Process()
      helper.executableURL = URL(fileURLWithPath: "/bin/sh")
      helper.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", target.path, old.path, staged.folder.path, marker.path, state.appendingPathComponent("install.log").path]
      helper.standardInput = FileHandle.nullDevice
      helper.standardOutput = FileHandle.nullDevice
      helper.standardError = FileHandle.nullDevice
      do {
        try helper.run()
      } catch {
        UpdatesChannel.log("the helper did not start: \(error)")
      }
      // A beat for the answer to reach Dart, which draws "Restarting", then the quit every Mac app has.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
      return "restarting"
    }
  }

  /// The app is quitting with an update in place: it is swapped in now, and the next launch is the new version.
  @objc private func quitting() {
    guard staged != nil else { return }
    _ = swap()
  }

  /// What waits for the old process, opens the new one, and keeps the old until the new has said it opened.
  /// Arguments: the old process, the app's path, where the old version is kept, the hidden folder, the marker the
  /// new version writes, the log.
  static let helper = """
    #!/bin/sh
    pid="$1"; target="$2"; old="$3"; folder="$4"; marker="$5"
    exec >>"$6" 2>&1
    say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
    say "waiting for $pid to quit"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -lt 300 ] || { say "it did not quit in a minute: the new version stays in place, unopened"; exit 1; }
      sleep 0.2
    done
    rm -f "$marker"
    /usr/bin/open "$target" || say "open did not start it"
    i=0
    while [ ! -f "$marker" ]; do
      i=$((i + 1))
      if [ "$i" -ge 240 ]; then
        say "the new version did not open in two minutes: putting the old one back"
        mv "$target" "$folder/did-not-open.app" && mv "$old" "$target" && /usr/bin/open "$target"
        exit 1
      fi
      sleep 0.5
    done
    say "the new version opened; the old one is removed"
    rm -rf "$folder"
    """

  // MARK: small things

  /// Runs [tool] to its end, its output thrown away: its exit status, or -1 where it would not start.
  @discardableResult
  static func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// A line in `<cache>/update-install/install.log`, beside the helper's own.
  static func log(_ words: String) {
    guard let state = state else { return }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(words)\n"
    let file = state.appendingPathComponent("install.log")
    if let handle = try? FileHandle(forWritingTo: file) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? line.write(to: file, atomically: true, encoding: .utf8)
    }
  }
}
