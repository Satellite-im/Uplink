import Flutter
import UIKit

/// The iPhone app's delegate: clears what a previous run left, passes Apple's push token on, and sets up the channels
/// to Dart once the Flutter engine is there.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// What the app asks of iOS (DeskChannels.swift): kept for as long as the app runs.
  private var desk: DeskChannels?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // What a previous run left of videos and recordings goes first (DeskVideo.swift).
    DeskVideo.sweep()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Apple's push token (lib/standalone/wake.dart), handed to the app as it comes.
  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NSLog("Uplink: push token from Apple, \(deviceToken.count) bytes")
    desk?.pushToken(deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NSLog("Uplink: no push token: \(error.localizedDescription)")
    desk?.pushToken(nil)
  }

  /// The engine is ready: the plugins, then each of the app's own channels on its messenger.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GhostMessaging") else { return }
    let messenger = registrar.messenger()
    desk = DeskChannels(messenger: messenger)
    // Links opened into the app, handed over by the scene (SceneDelegate.swift, lib/desktop/links.dart).
    DeskLinks.shared.attach(messenger: messenger)
    // The microphone's processing in calls (VoiceFx.swift).
    VoiceFx.shared.register(messenger: messenger)
    // A circle's music played here without loss (MusicSink.swift).
    MusicSink.shared.register(messenger: messenger)
    // Recording a call (CallRecorder.swift, lib/voice/recorder.dart).
    CallRecorder.shared.register(messenger: messenger)
    // Words from a recorded call (Scribe.swift, lib/voice/scribe.dart).
    Scribe.shared.register(messenger: messenger)
    // Replies and summaries by the device's own model (LocalAi.swift, lib/local_ai.dart).
    LocalAi.shared.register(messenger: messenger)
    // A call's captions (LiveCaptions.swift, lib/voice/captions.dart).
    LiveCaptions.shared.register(messenger: messenger)
  }
}
