import '../platform_info.dart';

import '../desktop/platform.dart';
import '../net/net.dart';

/// Waking an iPhone of its own while the app is closed (Matt, 2026-11-16: "Yes, wake-ups"). iOS stops an app's
/// connections soon after it leaves the screen, so a friend's message waits on the relay server until the app is
/// opened again. With Apple's push token, said to the relay server over the hub route (relay/lib/pushes.dart), the
/// server asks Apple to show "New message" when something is held for this iPhone; opening it brings what was held.
/// The notification says only that something came: the server cannot read what.
class IosWake {
  static bool _started = false;

  /// Asks once whether notifications may be shown (iOS asks the person the first time only), then keeps the token
  /// with the routes. Called when the app is past its welcome, so the question comes after a username is chosen.
  static void start() {
    if (_started || !PlatformInfo.isIOS) return;
    _started = true;
    MacPlatform.pushRegister((token, sandbox) {
      Net.instance.setPush(token == null ? null : {'apns': token, 'sandbox': sandbox});
    });
  }
}
