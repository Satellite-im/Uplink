import Cocoa
import FlutterMacOS

/// The Mac app's one window: it holds the Flutter view, sets up every channel the app has to macOS (awakeFromNib),
/// and does what only a window can: its top bar and three buttons, the launch splash's size, files dropped on it
/// and a picture pasted with ⌘V.
class MainFlutterWindow: NSWindow, NSDraggingDestination {
  /// The app's own top bar, with the three buttons folded down into it; false would put the Mac's own title bar back
  /// (see awakeFromNib). The app draws the top of the window: its title strip (lib/desktop/ui/desk_title_bar.dart; Matt, 2026-11-19: "we can
  /// roll a custom titlebar if we need to that's a bit thicker to fit the content").
  static let ownTopBar = true
  private var desk: DeskChannels?
  /// Files dropped on the window (lib/files/file_platform.dart): taken only while a Files space is on the screen, which
  /// says so with "target"; then "over" as files are dragged over the window and "dropped" with their paths.
  private var drops: FlutterMethodChannel?
  private var dropTarget = false

  /// Pasting a picture into a message field (Matt, 2026-11-20: "pasting a screenshot into the compose bar isn't adding
  /// attachements"): the Edit menu's Paste holds ⌘V, and macOS gives a menu's key to the menu before the app sees it, so
  /// the field's own picture paste (lib/ui/paste_images.dart) never ran and only words came in. This looks at ⌘V first:
  /// while a message field says it has the cursor ([pasteTarget]) and the clipboard holds a picture, the picture goes to
  /// that field and the key goes no further; otherwise the key goes on to the menu as ever.
  private var paste: FlutterMethodChannel?
  private var pasteTarget = false
  private var pasteMonitor: Any?
  private var updates: UpdatesChannel?
  /// "ghost_desktop/window": what the app asks of its window (the header's height and look, the splash and sign-in
  /// sizes, a drag or a double click on a top bar).
  private var chrome: FlutterMethodChannel?
  /// The app's header, which the three buttons sit centred in, and how far in from the left the first one is.
  private var barHeight: CGFloat = 56
  private var lightsX: CGFloat = 20

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Two panes side by side need room: the list and a conversation.
    self.minSize = NSSize(width: 760, height: 520)
    self.title = "Uplink"
    // The window draws edge to edge: no title strip of the Mac's own above the app. Each page's header is the top
    // bar, in the theme's colours, with the three buttons folded down into it and the window dragged by it (Matt,
    // 2026-11-17: "move the toolbar top bar into our own topbar component so it can match themes on mac make it fold
    // the traffic lights down and shift over the chat list on the sidebar and make the top bars draggable areas").
    // The app says how tall its header is and whether its look is dark (lib/desktop/window_chrome.dart).
    // With ownTopBar off, the Mac's own title bar is back, above the app, with the three buttons where the Mac puts them (Matt,
    // 2026-11-17: "let's bring back the native top bar and remove the thing where we have the traffic lights pushed
    // down until I work on the UI a bit more"): black, as before the app's own top bar (lib/ui/window_chrome.dart
    // MacChrome.own says the same to the app).
    if MainFlutterWindow.ownTopBar {
      self.styleMask.insert(.fullSizeContentView)
      self.titlebarAppearsTransparent = true
      self.titleVisibility = .hidden
    } else {
      self.titlebarAppearsTransparent = true
      self.appearance = NSAppearance(named: .darkAqua)
    }
    self.isMovableByWindowBackground = false
    self.backgroundColor = .black
    // The launch splash first (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20: "add a checking for updates splash
    // window that shows before the app launches and load the app on this screen too similar to how discord does on
    // launch"): a small window of its own while it looks for an update and the app loads; "splash" false from the app
    // gives the window its size back.
    enterSplash()
    chrome = FlutterMethodChannel(name: "ghost_desktop/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    chrome?.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "chrome":
        let a = call.arguments as? [String: Any] ?? [:]
        if let h = a["height"] as? Double { self.barHeight = CGFloat(h) }
        if let x = a["x"] as? Double { self.lightsX = CGFloat(x) }
        if MainFlutterWindow.ownTopBar, let dark = a["dark"] as? Bool { self.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        self.placeLights()
        result(nil)
      case "splash":
        if (call.arguments as? Bool) == false { self.leaveSplash() }
        result(nil)
      case "compact":
        // Signing up or in (lib/desktop/window_size.dart; Matt, 2026-11-20: "make the sign up / sign in window
        // smaller"): a small window of its own, as Discord's sign-in is; false gives the window its own size back.
        if (call.arguments as? Bool) == true { self.enterCompact() } else { self.leaveSplash() }
        result(nil)
      case "mini":
        // The call's mini window (lib/desktop/mini_window.dart): `on` with its size, or the window as it was.
        let a = call.arguments as? [String: Any] ?? [:]
        if (a["on"] as? Bool) == true {
          let w = (a["width"] as? NSNumber)?.doubleValue ?? 340, h = (a["height"] as? NSNumber)?.doubleValue ?? 236
          result(self.enterMini(width: CGFloat(w), height: CGFloat(h)))
        } else {
          self.leaveMini()
          result(true)
        }
      case "title":
        // What the app's title strip names (lib/ui/window_title.dart: the circle or conversation that is open): the
        // window's own title too, which is not drawn but is what the Window menu and Mission Control call it.
        self.title = (call.arguments as? String) ?? "Uplink"
        result(nil)
      case "drag":
        // The press that began on a top bar moves the window, as a title bar does.
        if let e = NSApp.currentEvent ?? self.currentEvent { self.performDrag(with: e) }
        result(nil)
      case "zoom":
        // A double click on a top bar does what the Mac is set to (Desktop & Dock › Double-click a window's title bar).
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": self.performMiniaturize(nil)
        case "None": break
        default: self.performZoom(nil)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
      NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in self?.placeLights() }
    }
    placeLights()
    DispatchQueue.main.async { [weak self] in self?.placeLights() }

    // Nothing of a video played in an earlier run is left on the disk (DeskVideo.swift), nor after this one.
    DeskVideo.sweep()
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in DeskVideo.sweep() }

    drops = FlutterMethodChannel(name: "ghost_desktop/drop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    drops?.setMethodCallHandler { [weak self] call, result in
      if call.method == "target" { self?.dropTarget = (call.arguments as? [String: Any])?["on"] as? Bool ?? false }
      result(nil)
    }
    registerForDraggedTypes([.fileURL])

    paste = FlutterMethodChannel(name: "ghost_desktop/paste", binaryMessenger: flutterViewController.engine.binaryMessenger)
    paste?.setMethodCallHandler { [weak self] call, result in
      if call.method == "target" { self?.pasteTarget = (call.arguments as? [String: Any])?["on"] as? Bool ?? false }
      result(nil)
    }
    pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.pasteTarget, event.window === self,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "v",
            let path = DeskChannels.pasteImage() else { return event }
      self.paste?.invokeMethod("image", arguments: ["path": path])
      return nil
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    desk = DeskChannels(messenger: flutterViewController.engine.binaryMessenger)
    // The microphone's processing in calls (VoiceFx.swift).
    VoiceFx.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // Spotify played to a circle's call (Spotify.swift).
    Spotify.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // What the Mac plays, sent with a shared screen (ScreenSound.swift).
    ScreenSound.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // And its music played here without loss (MusicSink.swift).
    MusicSink.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // Recording a call (CallRecorder.swift, lib/voice/recorder.dart).
    CallRecorder.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // Words from a recorded call (Scribe.swift, lib/voice/scribe.dart).
    Scribe.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // Replies and summaries by the device's own model (LocalAi.swift, lib/local_ai.dart).
    LocalAi.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // A call's captions (LiveCaptions.swift, lib/voice/captions.dart).
    LiveCaptions.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    Sounds.shared.register(messenger: flutterViewController.engine.binaryMessenger)
    // The app's own updates (UpdatesChannel.swift): its first act is to say this version opened, which an update
    // put in place a moment ago is waiting to hear.
    updates = UpdatesChannel(messenger: flutterViewController.engine.binaryMessenger)
    // Circles' invite links opened into the app (AppDelegate).
    DeskLinks.shared.attach(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // MARK: Files dragged onto the window
  //
  // The window is the drop's destination (registerForDraggedTypes above): the Flutter view under it takes no drags of
  // its own, so AppKit asks the window, and these answer it.

  /// The files in a drag, as paths; folders are left out.
  private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }.map { $0.path }
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard dropTarget, !droppedPaths(sender).isEmpty else { return [] }
    drops?.invokeMethod("over", arguments: ["on": true])
    return .copy
  }

  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropTarget && !droppedPaths(sender).isEmpty ? .copy : []
  }

  func draggingExited(_ sender: NSDraggingInfo?) {
    drops?.invokeMethod("over", arguments: ["on": false])
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = droppedPaths(sender)
    drops?.invokeMethod("over", arguments: ["on": false])
    guard dropTarget, !paths.isEmpty else { return false }
    drops?.invokeMethod("dropped", arguments: ["paths": paths])
    return true
  }

  /// The window's own frame and least size, kept while the splash is shown.
  private var fullFrame: NSRect?
  private var fullMin = NSSize(width: 760, height: 520)

  /// The window as it was before it was made the call's mini window (lib/desktop/mini_window.dart, GMFB-41: "An
  /// always-on-top call overlay for games on desktop"): its frame, least size, level and how it is on Spaces.
  private var miniWas: (frame: NSRect, min: NSSize, level: NSWindow.Level, spaces: NSWindow.CollectionBehavior, resizable: Bool)?

  /// The call's mini window: [width] by [height] in the screen's top right corner, above every other window (the
  /// floating level), on every Space and beside an app at full screen, the three buttons hidden, moved by its top
  /// strip (the app's WindowDragArea asks with "drag"). False where it can't be: at full screen, or while the splash
  /// or the sign-in's small window is up.
  private func enterMini(width: CGFloat, height: CGFloat) -> Bool {
    if miniWas != nil { return true }
    guard !styleMask.contains(.fullScreen), fullFrame == nil else { return false }
    miniWas = (frame: frame, min: minSize, level: level, spaces: collectionBehavior, resizable: styleMask.contains(.resizable))
    let size = NSSize(width: width, height: height)
    minSize = size
    styleMask.remove(.resizable)
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
    level = .floating
    collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    let screen = (self.screen ?? NSScreen.main)?.visibleFrame ?? frame
    setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16, width: size.width, height: size.height), display: true, animate: true)
    return true
  }

  /// The window as it was before the mini window: where it was, its size, level and buttons.
  private func leaveMini() {
    guard let was = miniWas else { return }
    miniWas = nil
    level = was.level
    collectionBehavior = was.spaces
    if was.resizable { styleMask.insert(.resizable) }
    minSize = was.min
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = false }
    setFrame(was.frame, display: true, animate: true)
    placeLights()
  }

  /// Small, centred, without the three buttons or a resize edge, and moved by any part of it, as Discord's splash is.
  private func enterSplash() {
    guard fullFrame == nil else { return }
    fullFrame = frame
    fullMin = minSize
    let size = NSSize(width: 300, height: 340)
    minSize = size
    styleMask.remove(.resizable)
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
    isMovableByWindowBackground = true
    let screen = (self.screen ?? NSScreen.main)?.visibleFrame ?? frame
    setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
  }

  /// Signing up or in: smaller than the app, not resizable, the close and minimise buttons kept.
  private func enterCompact() {
    if fullFrame == nil {
      fullFrame = frame
      fullMin = minSize
    }
    let size = NSSize(width: 480, height: 720)
    minSize = size
    styleMask.remove(.resizable)
    standardWindowButton(.closeButton)?.isHidden = false
    standardWindowButton(.miniaturizeButton)?.isHidden = false
    standardWindowButton(.zoomButton)?.isHidden = true
    isMovableByWindowBackground = false
    let screen = (self.screen ?? NSScreen.main)?.visibleFrame ?? frame
    let h = min(size.height, screen.height)
    setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - h / 2, width: size.width, height: h), display: true, animate: frame.width > size.width + 40)
    placeLights()
  }

  /// The app is ready: the window as it was meant to be, centred where the splash was.
  private func leaveSplash() {
    guard let full = fullFrame else { return }
    fullFrame = nil
    styleMask.insert(.resizable)
    minSize = fullMin
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = false }
    isMovableByWindowBackground = false
    let screen = (self.screen ?? NSScreen.main)?.visibleFrame ?? full
    let w = min(full.width, screen.width), h = min(full.height, screen.height)
    setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: true, animate: true)
    placeLights()
  }

  /// Puts the three buttons centred in the app's header, [lightsX] in from the left: their strip made as tall as the
  /// header, each button placed in it. Nothing in full screen, or with the Mac's own title bar. AppKit puts them back
  /// at its own height on some changes, so this runs again after each.
  func placeLights() {
    guard MainFlutterWindow.ownTopBar, !styleMask.contains(.fullScreen),
          let close = standardWindowButton(.closeButton),
          let mini = standardWindowButton(.miniaturizeButton),
          let zoom = standardWindowButton(.zoomButton),
          let strip = close.superview?.superview else { return }
    let size = close.frame.height
    var f = strip.frame
    f.size.height = barHeight
    f.origin.y = frame.height - barHeight
    strip.frame = f
    let gap = mini.frame.minX - close.frame.minX
    let step = gap > 0 ? gap : 20
    for (i, b) in [close, mini, zoom].enumerated() {
      b.setFrameOrigin(NSPoint(x: lightsX + CGFloat(i) * step, y: (barHeight - size) / 2))
    }
  }
}
