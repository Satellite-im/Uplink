import AVFoundation
import Cocoa
import FlutterMacOS

/// A video in a message, on the Mac (Matt, 2026-11-14: "mp4 files are not loading it just shows up as a string of
/// text for the filename"): a picture of where it starts and how long it runs, for the conversation to draw. It is
/// played in the app's own player (lib/ui/video_screen.dart, libmpv), no longer in a window of AVKit's here, which
/// could not open an .mkv and was not in the app's look (Matt, 2026-11-18: "add support for playing mkv video files
/// and mp4's within the app in a player themed by glacier UI").
///
/// The video is the phone's: the app brings its bytes over the link (lib/desktop/remote.dart) and hands them here.
/// AVFoundation reads a file, so the bytes are written to this app's own folder in the temporary directory, readable
/// by this account alone, for as long as they are needed and no longer: until the picture is made. The player's own
/// copy goes in the same folder (remote.dart videoCopy) and is removed when the player closes. The folder is removed
/// as the app opens and as it quits, so nothing of a conversation stays on the Mac's disk (docs/desktop.md: the Mac
/// keeps no texts).
final class DeskVideo {

  /// Every run's folders are in here; this run's is named by its process, so two copies of the app open at once
  /// never touch each other's.
  private static var folders: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ghost-messaging-video", isDirectory: true)
  }

  private static var folder: URL {
    folders.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
  }

  /// Nothing of a video is left from an earlier run, or after this one: this run's folder goes, and any left by a
  /// run that is no longer running (one that was stopped before it could tidy).
  static func sweep() {
    let manager = FileManager.default
    try? manager.removeItem(at: folder)
    for name in (try? manager.contentsOfDirectory(atPath: folders.path)) ?? [] {
      guard let pid = Int32(name) else { continue }
      // kill with signal 0 asks only whether the process is there.
      if kill(pid, 0) != 0 && errno == ESRCH { try? manager.removeItem(at: folders.appendingPathComponent(name)) }
    }
  }

  /// A place in this run's folder for a file named [name], for this account alone (a recording: DeskSound.swift).
  static func place(named name: String) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder.appendingPathComponent(name)
  }

  /// A file's ending AVFoundation knows the kind by; anything else is tried as an mp4.
  private static func ending(_ said: String) -> String {
    let known = ["mp4", "m4v", "mov", "3gp", "3g2"]
    return known.contains(said.lowercased()) ? said.lowercased() : "mp4"
  }

  /// The video's bytes as a file in this run's folder, under a name no other has, readable by this account alone.
  private static func write(_ data: Data, id: Int, ext: String) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent("\(id)-\(UUID().uuidString).\(ending(ext))")
    guard manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return file
  }

  /// `picture` (a JPEG of where the video starts, or nil where none can be made), `millis`, and the picture's size.
  static func preview(data: Data, id: Int, ext: String) -> [String: Any?] {
    let nothing: [String: Any?] = ["picture": nil, "millis": 0, "width": 0, "height": 0, "videoWidth": 0, "videoHeight": 0]
    guard let file = try? write(data, id: id, ext: ext) else { return nothing }
    defer { try? FileManager.default.removeItem(at: file) }
    let asset = AVURLAsset(url: file)
    let seconds = CMTimeGetSeconds(asset.duration)
    let millis = seconds.isFinite && seconds > 0 ? Int(seconds * 1000) : 0
    // The video's own size as it plays (one filmed upright is kept on its side): the conversation says how small a
    // video came (lib/ui/video.dart). The file's size is known to the caller, which holds its bytes.
    var own = CGSize.zero
    if let track = asset.tracks(withMediaType: .video).first {
      let turned = track.naturalSize.applying(track.preferredTransform)
      own = CGSize(width: abs(turned.width), height: abs(turned.height))
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 720, height: 720)
    guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil),
          let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    else { return ["picture": nil, "millis": millis, "width": 0, "height": 0, "videoWidth": Int(own.width), "videoHeight": Int(own.height)] }
    return ["picture": FlutterStandardTypedData(bytes: jpeg), "millis": millis, "width": image.width, "height": image.height, "videoWidth": Int(own.width), "videoHeight": Int(own.height)]
  }
}
