import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform_info.dart';
import '../sms.dart' show Sms;
import '../voice/channels.dart' show Voice;

/// The call in a small window over everything (GMFB-41, from the Uplink gap review: "An always-on-top call overlay for
/// games on desktop"): in a call on a computer, Mini window (the call's dock, and a shortcut in Settings › Keyboard
/// shortcuts) makes the app's window small and keeps it above every other window, a game's among them, with the call's
/// faces rippling as they talk and Mute, Deafen and Leave (lib/ui/call_mini.dart). Back to the full window, the
/// shortcut again, or the call ending gives the window its size, place and level back.
///
/// The window is the runner's to change ("ghost_desktop/window", `mini`, with `on` and the size in logical pixels):
/// - Mac (macos/Runner/MainFlutterWindow.swift): the floating level, on every Space and beside a full-screen app, the
///   three buttons hidden and the window moved by its top strip; not while it is itself full screen.
/// - Windows (windows/runner/splash.cpp): HWND_TOPMOST, no maximise button, in the work area's top right corner.
/// - Linux: not offered. Its runner answers nothing on the window's channel, and under Wayland, which most desktops
///   now run, an app can't keep its window above others (GTK's keep-above is a request X11 window managers honour and
///   Wayland ones do not), so it would be a small window that falls behind the game.
///
/// The app under the small window is kept as it was, laid out at its own size and not drawn (lib/ui/call_mini.dart's
/// CallMiniFrame), so the pages open, the list's place and the composer's words are there again afterwards.
class CallMini extends ChangeNotifier {
  /// [inCall] and [calls]: whether there is a call, and what says when that changes; Voice's, but for a test.
  CallMini({bool Function()? inCall, Listenable? calls, MethodChannel channel = const MethodChannel('ghost_desktop/window')})
      : _inCall = inCall,
        _calls = calls,
        _channel = channel;

  static final instance = CallMini();

  final bool Function()? _inCall;
  final Listenable? _calls;
  final MethodChannel _channel;

  /// The small window's size, in logical pixels: the faces in two rows of five, the buttons under them.
  static const size = Size(340, 236);

  /// Whether this device has a mini window: a Mac's or a PC's app ([Sms.computer] and not a browser), with calls.
  static bool get here => offeredForTest ?? (!kIsWeb && Sms.computer && (PlatformInfo.isMacOS || PlatformInfo.isWindows) && Sms.callsHere);

  /// For a test: whether a mini window is offered, in place of the device's answer.
  @visibleForTesting
  static bool? offeredForTest;

  bool _on = false, _busy = false, _listening = false;

  /// The window is small and above the rest now.
  bool get on => _on;

  bool get _calling => (_inCall ?? () => Voice.instance.session != null)();
  Listenable get _voice => _calls ?? Voice.instance;

  /// Makes the window small and keeps it on top: true where it is now. False where there is no call, the device has
  /// none ([here]), or the window would not (a Mac's window at full screen, or a runner from before).
  Future<bool> enter() async {
    if (_on) return true;
    if (_busy || !here || !_calling) return false;
    _busy = true;
    try {
      final ok = await _channel.invokeMethod<bool>('mini', {'on': true, 'width': size.width.round(), 'height': size.height.round()}) ?? false;
      // The call ended while the window was being made small: back at once.
      if (ok && !_calling) {
        await _say(false);
        return false;
      }
      if (!ok) return false;
      _on = true;
      if (!_listening) {
        _listening = true;
        _voice.addListener(_follow);
      }
      notifyListeners();
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } finally {
      _busy = false;
    }
  }

  /// The window's own size, place and level back. Nothing where it is not small.
  Future<void> leave() async {
    if (!_on) return;
    _on = false;
    if (_listening) {
      _listening = false;
      _voice.removeListener(_follow);
    }
    notifyListeners();
    await _say(false);
  }

  /// Small where it is not, and back where it is: what the shortcut and the dock's button do. True where it is small
  /// now.
  Future<bool> toggle() async {
    if (_on) {
      await leave();
      return false;
    }
    return enter();
  }

  Future<void> _say(bool on) async {
    try {
      await _channel.invokeMethod<bool>('mini', {'on': on});
    } catch (_) {}
  }

  /// The call ended (left here, or ended for this device): the window comes back with it.
  void _follow() {
    if (_on && !_calling) unawaited(leave());
  }
}
