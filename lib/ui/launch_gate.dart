import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../art/loading_logo.dart';

/// A phone's loading splash (Matt, 2026-11-27: "also on the phone add a loading splash screen using the same logo"):
/// the logo turning (lib/art/loading_logo.dart) on the page from the app's first frame, the app put under it as soon
/// as what it starts with has been read (the stylesheets, the person's choices, the language, the plugins, the lock:
/// lib/main.dart), and the splash faded away over it once the logo has been seen for a moment. A computer has had one
/// since 2026-11-20 (lib/desktop/ui/launch_splash.dart), in a small window of its own, which also looks for an update.
///
/// **Before anything is read.** The splash is up before the choices are, so it can't know the look or the theme
/// chosen: it is black on white or white on black by the phone's own setting, which is also what Android shows
/// before the app draws at all (the launch theme's window), so the two meet without a flash.
///
/// **Counted from when the logo is seen** ([LaunchGate.least]). Android starts the app's Dart while it is still
/// making the screen (MainActivity.provideFlutterEngine), so most of the reading is over before a frame of the
/// app's can be shown at all: on the emulator the reading took 0.72 s and the first frame came 0.68 s in. A splash
/// timed from the app's start was seen for a blink. So its time runs from the frame the logo is first in, on a screen
/// that has drawn.
///
/// **The app loads under it.** The app is put under the splash the moment it can be, and draws its first page
/// there (the heaviest frames it has, and the list filling in), so what the splash leaves is the app as it stands,
/// not as it is still arriving. Nothing under the splash can be pressed or read out until it starts to go.
///
/// **Never in the way of somewhere to go.** Opened to show something (a notification pressed, something shared in, a
/// link), the app says so ([LaunchGate.hurry]) and the splash goes at once. And whatever happens or doesn't, it is
/// gone [LaunchGate.longest] after the app is under it.
class PhoneSplash extends StatelessWidget {
  const PhoneSplash({super.key, this.onShown});

  /// [LoadingLogo.onShown]: told once the logo is on the page, or can't be.
  final ValueChanged<bool>? onShown;

  /// The page and the ink where the phone is [dark] or not: Android's own launch window's, and its opposite.
  static ({Color page, Color ink}) colours(bool dark) => dark ? (page: const Color(0xFF000000), ink: const Color(0xFFFFFFFF)) : (page: const Color(0xFFFFFFFF), ink: const Color(0xFF000000));

  @override
  Widget build(BuildContext context) {
    final dark = (MediaQuery.maybePlatformBrightnessOf(context) ?? PlatformDispatcher.instance.platformBrightness) == Brightness.dark;
    final c = colours(dark);
    final marks = dark ? Brightness.light : Brightness.dark;
    // The clock and the bars' marks read on this page while it is up, whatever the app under it would have them.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0x00000000),
        statusBarIconBrightness: marks,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarIconBrightness: marks,
      ),
      child: ColoredBox(
        color: c.page,
        child: Center(
          child: LayoutBuilder(builder: (context, box) {
            // Most of the way across a phone, and no wider than reads as a logo on a tablet or an unfolded one.
            final width = (box.maxWidth * 0.62).clamp(160.0, 340.0);
            return LoadingLogo(key: const ValueKey('launch-logo'), width: width, color: c.ink, onShown: onShown);
          }),
        ),
      ),
    );
  }
}

/// What is on the screen from the first frame: [PhoneSplash], with the app under it once [LaunchHandle.open] is
/// given it, and then the app alone.
class LaunchGate extends StatefulWidget {
  const LaunchGate._(this._launch);
  final LaunchHandle _launch;

  /// The least the logo is seen for, from the frame it is first in.
  static const least = Duration(milliseconds: 900);

  /// How long the splash takes to fade away over the app.
  static const fade = Duration(milliseconds: 260);

  /// How long the app has under the splash before the splash may start to go: its first frames are its heaviest,
  /// and a fade drawn through them is a jump.
  static const settle = Duration(milliseconds: 200);

  /// The longest the splash stays once the app is under it, whatever has or hasn't happened: a logo that was never
  /// seen (no screen yet, as when the app is started with none) doesn't leave it up for good.
  static const longest = Duration(seconds: 3);

  static LaunchHandle? _up;

  /// Puts the splash up as the app's first frame, and answers with what opens the app under it.
  static LaunchHandle show({Duration least = least}) {
    final launch = LaunchHandle._(least);
    _up = launch;
    runApp(LaunchGate._(launch));
    // A frame of the app's is on the screen: before that, nothing of the splash has been seen however long ago it
    // was built.
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) => launch._drawn()));
    return launch;
  }

  /// The app was opened to show something: the splash that is up, if one is, goes as soon as the app is under it.
  static void hurry() => _up?.hurry();

  /// For a test: the gate itself, to pump, and its handle. The screen counts as drawn from the start unless
  /// [drawn] says not, and then from [LaunchHandle.screenDrawn].
  @visibleForTesting
  static (Widget, LaunchHandle) forTest({Duration least = least, bool drawn = true}) {
    final launch = LaunchHandle._(least);
    if (drawn) launch._drawn();
    return (LaunchGate._(launch), launch);
  }

  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  @override
  void initState() {
    super.initState();
    widget._launch.addListener(_changed);
  }

  @override
  void dispose() {
    widget._launch.removeListener(_changed);
    // Taken off the screen whole (something else drawn in its place): nothing of it is left waiting.
    widget._launch._stop();
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final launch = widget._launch;
    final app = launch.app;
    // The app keeps its place for good (the first of the stack, by its key), so the splash coming off it changes
    // nothing of it; each fills the screen, as the app did when it stood here alone.
    return Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
      if (app != null) KeyedSubtree(key: const ValueKey('launch-app'), child: app),
      if (!launch.gone)
        IgnorePointer(
          key: const ValueKey('launch-splash'),
          // Whole, it takes every press (the app under it is not there to be pressed yet); going, none.
          ignoring: launch.leaving,
          child: BlockSemantics(
            blocking: !launch.leaving,
            child: AnimatedOpacity(
              opacity: launch.leaving ? 0 : 1,
              duration: LaunchGate.fade,
              onEnd: launch._faded,
              child: PhoneSplash(onShown: launch._logo),
            ),
          ),
        ),
    ]);
  }
}

/// Opens the app under the splash [LaunchGate.show] put up, and knows where the splash stands.
class LaunchHandle extends ChangeNotifier {
  LaunchHandle._(this._least);
  final Duration _least;
  final Stopwatch _clock = Stopwatch()..start();

  /// The app, once it is under the splash.
  Widget? get app => _app;
  Widget? _app;

  /// The splash is fading away over the app.
  bool get leaving => _leaving;
  bool _leaving = false;

  /// The splash is gone: the app stands alone.
  bool get gone => _gone;
  bool _gone = false;

  /// For anyone measuring a start, from when the splash went up: how long the reading took, when the logo was first
  /// seen, and when the splash was gone.
  Duration? took, seenAt, leftAt;

  /// Done once the splash is gone.
  Future<void> get left => _left.future;
  final Completer<void> _left = Completer<void>();

  bool _screen = false, _hurried = false, _settled = false, _had = false;
  bool? _there;
  Timer? _settling, _having, _giveUp;

  /// For a test: a frame of the app's has reached the screen.
  @visibleForTesting
  void screenDrawn() => _drawn();

  /// A frame of the app's is on the screen.
  void _drawn() {
    if (_screen) return;
    _screen = true;
    _seen();
  }

  /// The logo is in a frame ([there]), or this build can't read it.
  void _logo(bool there) {
    _there ??= there;
    _seen();
  }

  /// The logo is seen once it is in a frame and a frame has reached the screen: its least runs from here. One that
  /// can't be read has no least to have.
  void _seen() {
    if (seenAt != null || !_screen || _there == null) return;
    seenAt = _clock.elapsed;
    if (_there!) {
      _having = Timer(_least, () {
        _had = true;
        _consider();
      });
    } else {
      _had = true;
      _consider();
    }
  }

  /// [app] under the splash, from now on; the splash goes once the app has settled there and the logo has been seen
  /// for its least (already, where the reading took longer than that).
  void open(Widget app) {
    if (_app != null) return;
    _app = app;
    took = _clock.elapsed;
    _settling = Timer(LaunchGate.settle, () {
      _settled = true;
      _consider();
    });
    _giveUp = Timer(LaunchGate.longest, _leave);
    notifyListeners();
  }

  /// The app has somewhere to go: the splash doesn't wait for the logo's least.
  void hurry() {
    if (_hurried) return;
    _hurried = true;
    _consider();
  }

  void _consider() {
    if (_app != null && _settled && (_had || _hurried)) _leave();
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    _stop();
    notifyListeners();
  }

  void _stop() {
    for (final timer in [_settling, _having, _giveUp]) {
      timer?.cancel();
    }
    if (identical(LaunchGate._up, this) && !_leaving) LaunchGate._up = null;
  }

  void _faded() {
    if (_gone || !_leaving) return;
    _gone = true;
    leftAt = _clock.elapsed;
    if (identical(LaunchGate._up, this)) LaunchGate._up = null;
    notifyListeners();
    _left.complete();
  }
}
