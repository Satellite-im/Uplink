import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart' show defaultEnterNativeFullscreen, defaultExitNativeFullscreen;

import 'window_chrome.dart' show MacChrome;

/// One thing shown alone, full screen: a video being played (lib/ui/video_screen.dart, GMFB-65) and a screen shared
/// in a call (lib/ui/screen_share.dart, GMFB-27) go in and out of it the same way, here.
///
/// On a computer the thing is drawn over the whole window, on the app's outermost overlay (the caller's
/// [OverlayPortalController], whose portal is at `OverlayChildLocation.rootOverlay`), the Mac's title strip is not
/// drawn meanwhile ([MacChrome.covered]), and the window itself goes full screen. On a phone the status and
/// navigation bars are hidden (a swipe from the edge shows them for a moment) and the phone is turned the way the
/// picture is.
abstract final class WholeWindow {
  /// Into full screen ([on]) or out of it. [desk]: this is a computer. [over]: what draws the thing over the whole
  /// window there. [aspect]: the picture's shape, width over height, for a phone: on its side for a wide picture,
  /// upright for a tall one; one whose shape isn't known (0) counts as wide.
  static Future<void> set(bool on, {required bool desk, OverlayPortalController? over, double aspect = 0}) async {
    if (desk) {
      on ? over?.show() : over?.hide();
      MacChrome.covered.value = on;
      await (on ? defaultEnterNativeFullscreen() : defaultExitNativeFullscreen());
      return;
    }
    await (on ? _enterPhone(aspect) : _leavePhone());
  }

  /// Out of it as the thing shown goes away while still full screen (its State's dispose).
  static void gone({required bool desk}) {
    if (desk) {
      // Not during this frame's teardown: the strip is built again by it.
      scheduleMicrotask(() => MacChrome.covered.value = false);
    }
    unawaited(desk ? defaultExitNativeFullscreen() : _leavePhone());
  }

  /// Out of full screen on a phone: the bars shown again, and the phone free to turn as it is held.
  static Future<void> _leavePhone() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
      await SystemChrome.setPreferredOrientations(const []);
    } catch (_) {}
  }

  /// Full screen on a phone (Matt, 2026-11-21: "add the ability to full screen videos played from files").
  static Future<void> _enterPhone(double aspect) async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: const []);
      await SystemChrome.setPreferredOrientations(aspect > 0 && aspect < 1
          ? const [DeviceOrientation.portraitUp]
          : const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    } catch (_) {}
  }
}
