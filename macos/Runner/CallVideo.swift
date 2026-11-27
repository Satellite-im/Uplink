import AVFoundation
import CoreImage
import Foundation
import WebRTC
import flutter_webrtc
import FlutterMacOS

/// A recording's picture, on the Mac (GMFB-42: "capture the webcams and screenshares in the call, not just the audio
/// tracks"; Matt, 2026-11-23: "One composed video"): the call's cameras and shared screens drawn into one video,
/// 1280 by 720 at fifteen frames a second, encoded as it goes into a file of its own beside the voices' files.
/// CallRecorder's mux copies that file's track into the recording's MP4 at the stop, after the voices.
///
/// What is drawn where is Dart's to say (lib/voice/recording_video.dart): it hands over a plate, the whole picture with
/// every tile's back and name painted on it, and for each camera or screen that may be drawn (only of people whose own
/// app said yes to voice and video) a track and a place. Nothing here decides who is seen.
///
/// - Frames: a renderer on each track (`RTCVideoTrack.add`), found by id through flutter_webrtc as the voices' tracks
///   are. It keeps only the newest frame.
/// - Each fifteenth of a second: the newest frame of each track is scaled into its place over the plate (Core Image)
///   and handed to an H.264 writer, stamped by the same clock the voices' files are held to, so they stay in step.
///
/// On the `ghost/recorder` channel, through CallRecorder: `video.start` (the file, its size, rate and bitrate),
/// `video.layout` (the plate and the tiles; answers the tracks it could not find) and `video.stop` (how many frames).
final class CallVideo: NSObject {
  static let shared = CallVideo()

  /// What WebRTC hands one picture's frames to. Frames come on WebRTC's own threads; the picture is asked for on the
  /// recording's queue.
  final class Tap: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var newest: RTCVideoFrame?
    private var fresh = false
    /// The newest frame as an image, made once a frame; read on the recording's queue alone.
    private var made: CIImage?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
      lock.lock()
      newest = frame
      fresh = true
      lock.unlock()
    }

    /// The newest frame, upright, its corner at zero; nil until one has come.
    func picture() -> CIImage? {
      lock.lock()
      let frame = newest
      let changed = fresh
      fresh = false
      lock.unlock()
      if changed { made = frame.flatMap(CallVideo.image(of:)) }
      return made
    }
  }

  /// One picture's place: where it goes (Core Image's way up, from the bottom left), and whether it is drawn whole
  /// (a screen) or fills its place with its edges cut (a camera).
  private struct Place {
    let tap: Tap
    let rect: CGRect
    let contain: Bool
  }

  /// The picture track flutter_webrtc holds under an id: this device's own camera or screen, or someone else's as
  /// their connection receives it. A variable so a check outside the app can hand over tracks of its own.
  var find: (String) -> RTCVideoTrack? = { id in
    FlutterWebRTCPlugin.sharedSingleton()?.track(forId: id, peerConnectionId: nil) as? RTCVideoTrack
  }

  // On the main thread: the renderers there are, by track id.
  private var taps: [String: (track: RTCVideoTrack, tap: Tap)] = [:]

  // On the recording's queue.
  private let queue = DispatchQueue(label: "ghost.recorder.video")
  private let context = CIContext(options: [.cacheIntermediates: false])
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var timer: DispatchSourceTimer?
  private var bounds = CGRect.zero
  private var plate: CIImage?
  private var places: [Place] = []
  private var frames = 0
  private var last = CMTime.invalid

  /// Takes a `video.` call; false where the call is not one.
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "video.start":
      let ok = start(
        path: args["path"] as? String ?? "",
        width: args["width"] as? Int ?? 1280,
        height: args["height"] as? Int ?? 720,
        fps: args["fps"] as? Int ?? 15,
        bitrate: args["bitrate"] as? Int ?? 1_600_000)
      result(ok)
    case "video.layout":
      result(layout(
        plate: (args["plate"] as? FlutterStandardTypedData)?.data,
        width: args["width"] as? Int ?? 0,
        height: args["height"] as? Int ?? 0,
        tiles: args["tiles"] as? [[String: Any]] ?? []))
    case "video.stop":
      stop { frames in result(["frames": frames]) }
    default:
      return false
    }
    return true
  }

  /// Begins the picture's file at [path]; false where it couldn't be begun.
  private func start(path: String, width: Int, height: Int, fps: Int, bitrate: Int) -> Bool {
    guard !path.isEmpty, width > 0, height > 0, fps > 0 else { return false }
    untap()
    var ok = false
    queue.sync {
      self.endLocked(finished: nil)
      let url = URL(fileURLWithPath: path)
      try? FileManager.default.removeItem(at: url)
      guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
      // Written out every ten seconds, so a crash loses only the file's end, as with the voices' files.
      writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
      let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        // Its colours said in the file: unsaid, one player takes a 720-line video for BT.709 and another for BT.601,
        // and a green or a pink is plainly another colour in one of them. BT.601's matrix, because that is what the
        // writer turns these BGRA frames into whatever is asked: asked for BT.709 it wrote "BT.709" over BT.601
        // numbers (measured 2026-11-26: a pink of 92 green came back 109).
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
        ],
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitrate,
          AVVideoMaxKeyFrameIntervalKey: fps * 2,
          AVVideoExpectedSourceFrameRateKey: fps,
          AVVideoAllowFrameReorderingKey: false,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ] as [String: Any],
      ]
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ])
      guard writer.canAdd(input) else { return }
      writer.add(input)
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: .zero)
      self.writer = writer
      self.input = input
      self.adaptor = adaptor
      self.bounds = CGRect(x: 0, y: 0, width: width, height: height)
      self.plate = nil
      self.places = []
      self.frames = 0
      self.last = .invalid
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(5))
      timer.setEventHandler { [weak self] in self?.tick() }
      timer.resume()
      self.timer = timer
      ok = true
    }
    return ok
  }

  /// What the picture is made of from now on: [plate] (width by height pixels of RGBA, the top row first) under each
  /// of [tiles] (a track, and its place in pixels from the top left). Answers the tracks that could not be found,
  /// for Dart to say again once they are held.
  private func layout(plate: Data?, width: Int, height: Int, tiles: [[String: Any]]) -> [String] {
    var missing: [String] = []
    var next: [String: (track: RTCVideoTrack, tap: Tap)] = [:]
    var placed: [Place] = []
    for t in tiles {
      guard let id = t["track"] as? String, let x = t["x"] as? Int, let y = t["y"] as? Int, let w = t["w"] as? Int, let h = t["h"] as? Int, w > 0, h > 0 else { continue }
      guard let track = find(id) else {
        missing.append(id)
        continue
      }
      let tap: Tap
      if let made = next[id] {
        tap = made.tap
      } else if let had = taps[id], had.track === track {
        tap = had.tap
      } else {
        // A new track, or the same id on a connection made again: a renderer of its own.
        tap = Tap()
        track.add(tap)
      }
      next[id] = (track, tap)
      placed.append(Place(tap: tap, rect: CGRect(x: x, y: height - y - h, width: w, height: h), contain: t["contain"] as? Bool ?? false))
    }
    for (id, had) in taps where next[id]?.tap !== had.tap { had.track.remove(had.tap) }
    taps = next
    let image = CallVideo.plateImage(plate, width: width, height: height)
    queue.async {
      if let image { self.plate = image }
      self.places = placed
    }
    return missing
  }

  /// Ends the file and says how many frames it has.
  private func stop(done: @escaping (Int) -> Void) {
    untap()
    queue.async {
      self.endLocked { frames in DispatchQueue.main.async { done(frames) } }
    }
  }

  /// Takes every renderer off its track. On the main thread.
  private func untap() {
    for (_, had) in taps { had.track.remove(had.tap) }
    taps = [:]
  }

  /// On the queue: stops the clock and closes the file; [finished] is told the frames written once it is closed.
  private func endLocked(finished: ((Int) -> Void)?) {
    timer?.cancel()
    timer = nil
    let written = frames
    let closing = writer
    input?.markAsFinished()
    writer = nil
    input = nil
    adaptor = nil
    plate = nil
    places = []
    frames = 0
    guard let closing, closing.status == .writing else {
      finished?(0)
      return
    }
    if written == 0 {
      closing.cancelWriting()
      finished?(0)
      return
    }
    closing.finishWriting { finished?(closing.status == .completed ? written : 0) }
  }

  /// One frame of the recording: the plate, each picture's newest frame over it, to the writer.
  private func tick() {
    guard let input, let adaptor, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
    // The voices' clock (samples at 48 kHz since the recording began), so the picture stays in step with them.
    let pts = CMTime(value: CallRecorder.shared.due(), timescale: CMTimeScale(CallRecorder.rate))
    if last.isValid && CMTimeCompare(pts, last) <= 0 { return }
    var made: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
    guard let out = made else { return }
    var image = plate ?? CIImage(color: CIColor.black).cropped(to: bounds)
    for p in places {
      guard let picture = p.tap.picture() else { continue }
      image = CallVideo.placed(picture, in: p.rect, contain: p.contain).composited(over: image)
    }
    context.render(image.cropped(to: bounds), to: out, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    if adaptor.append(out, withPresentationTime: pts) {
      frames += 1
      last = pts
    }
  }

  /// [picture] scaled into [rect]: whole, with what is under it showing at its sides, or filling it with its edges cut.
  static func placed(_ picture: CIImage, in rect: CGRect, contain: Bool) -> CIImage {
    let e = picture.extent
    guard e.width > 0, e.height > 0, !e.isInfinite else { return CIImage.empty() }
    let sx = rect.width / e.width, sy = rect.height / e.height
    let s = contain ? min(sx, sy) : max(sx, sy)
    let scaled = picture.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let se = scaled.extent
    return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX, y: rect.midY - se.midY)).cropped(to: rect)
  }

  /// A frame as an image, the way up it is meant to be seen, its corner at zero; nil where it can't be read.
  static func image(of frame: RTCVideoFrame) -> CIImage? {
    var image: CIImage
    if let cv = frame.buffer as? RTCCVPixelBuffer {
      // A camera's frame, or one the Mac's own decoder made: used where it is.
      image = CIImage(cvPixelBuffer: cv.pixelBuffer)
      let full = image.extent
      let cw = CGFloat(cv.cropWidth), ch = CGFloat(cv.cropHeight)
      if cw > 0, ch > 0, cw != full.width || ch != full.height {
        // The part of the buffer that is the picture, said from the top left.
        image = image.cropped(to: CGRect(x: CGFloat(cv.cropX), y: full.height - CGFloat(cv.cropY) - ch, width: cw, height: ch))
      }
    } else {
      // One decoded in software (VP8, VP9) or a captured screen: three planes, copied into a buffer Core Image reads.
      guard let buffer = nv12(frame.buffer.toI420()) else { return nil }
      image = CIImage(cvPixelBuffer: buffer)
    }
    switch frame.rotation {
    case ._90: image = image.oriented(.right)
    case ._180: image = image.oriented(.down)
    case ._270: image = image.oriented(.left)
    default: break
    }
    let e = image.extent
    return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
  }

  /// [b]'s three planes as one buffer of two (its brightness, then its two colours side by side).
  static func nv12(_ b: RTCI420BufferProtocol) -> CVPixelBuffer? {
    let w = Int(b.width), h = Int(b.height)
    guard w > 1, h > 1 else { return nil }
    var made: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &made)
    guard let out = made else { return nil }
    CVPixelBufferLockBaseAddress(out, [])
    defer { CVPixelBufferUnlockBaseAddress(out, []) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(out, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1) else { return nil }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
    let rows = min(h, CVPixelBufferGetHeightOfPlane(out, 0)), across = min(w, yStride)
    for row in 0..<rows {
      memcpy(y + row * yStride, b.dataY + row * Int(b.strideY), across)
    }
    let cw = min((w + 1) / 2, CVPixelBufferGetWidthOfPlane(out, 1), uvStride / 2)
    let ch = min((h + 1) / 2, CVPixelBufferGetHeightOfPlane(out, 1))
    for row in 0..<ch {
      let to = (uv + row * uvStride).assumingMemoryBound(to: UInt8.self)
      let u = b.dataU + row * Int(b.strideU), v = b.dataV + row * Int(b.strideV)
      for i in 0..<cw {
        to[2 * i] = u[i]
        to[2 * i + 1] = v[i]
      }
    }
    return out
  }

  /// Dart's plate (RGBA, the top row first) as an image; nil where it is not width by height.
  static func plateImage(_ data: Data?, width: Int, height: Int) -> CIImage? {
    guard let data, width > 0, height > 0, data.count == width * height * 4, let provider = CGDataProvider(data: data as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return CIImage(cgImage: image)
  }
}
