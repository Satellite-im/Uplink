import Flutter
import UIKit

/// The iPhone app's scene: links opened into the app (ghostmsg:…) go to [DeskLinks], as the Mac's AppDelegate hands
/// them over. Everything else is Flutter's own scene delegate's.
class SceneDelegate: FlutterSceneDelegate {
  /// Started by a link (the app wasn't running): the link comes with the scene's connection.
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    if FlutterSceneDelegate.instancesRespond(to: #selector(UISceneDelegate.scene(_:willConnectTo:options:))) {
      super.scene(scene, willConnectTo: session, options: connectionOptions)
    }
    for context in connectionOptions.urlContexts { DeskLinks.shared.opened(context.url) }
  }

  /// A link opened while the app runs, in front or behind.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if FlutterSceneDelegate.instancesRespond(to: #selector(UISceneDelegate.scene(_:openURLContexts:))) {
      super.scene(scene, openURLContexts: URLContexts)
    }
    for context in URLContexts { DeskLinks.shared.opened(context.url) }
  }
}

/// "ghost_desktop/links" (lib/desktop/links.dart; GMFB-34): someone's add-me link (ghostmsg://add/NAME#KEY, from the
/// add-me page's Open in Uplink, site/add), a circle's invite (ghostmsg://join/#c.…) and a relay's
/// (ghostmsg://relay?a=…), waiting in [pending] until the app takes them ("take"), then handed over as they come
/// ("open"), as on a Mac (macos/Runner/AppDelegate.swift).
final class DeskLinks {
  static let shared = DeskLinks()
  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  /// Whether the app has asked for the links yet: from then on they are handed over as they come.
  private var taken = false

  /// Sets up the channel on the app's engine, once it has one (AppDelegate.didInitializeImplicitFlutterEngine).
  func attach(messenger: FlutterBinaryMessenger) {
    let c = FlutterMethodChannel(name: "ghost_desktop/links", binaryMessenger: messenger)
    c.setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "take" else { return result(FlutterMethodNotImplemented) }
      self.taken = true
      result(self.pending)
      self.pending.removeAll()
    }
    channel = c
  }

  /// A link was opened into the app: one of its own handed over or held; any other is not this channel's.
  func opened(_ url: URL) {
    guard url.scheme?.lowercased() == "ghostmsg" else { return }
    let link = url.absoluteString
    if taken, let channel {
      channel.invokeMethod("open", arguments: link)
    } else {
      pending.append(link)
    }
  }
}
