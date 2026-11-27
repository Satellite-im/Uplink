import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../voice/channels.dart';
import '../voice/voice.dart' show VoiceSession;
import 'call_float.dart';
import 'tile_grid.dart' show VideoShapes;
import 'voice_screen.dart' show StreamView;

/// Android's picture in picture for a call (GMFB-64; Matt, 2026-11-25, approving the ticket's second half): with the
/// phone sent home or to another app during a call with a picture (a camera or a shared screen), the app shrinks to a
/// small window of its own over everything, the picture filling it at the picture's own shape, with Mute and Leave
/// under it. Out of such a call it never does.
///
/// Dart says what there is to show over `ghost_messaging/pip` as it changes (`pip`: `on`, and while on the picture's
/// shape as `w` by `h`, whether this device is `muted` for the Mute button's look, and whether it is a `screen`);
/// MainActivity.kt keeps it, sets it as the window's parameters (going in by itself on Android 12 and later, asked for
/// as the app is left below that), and says back when the window goes in and out of picture in picture (`changed`,
/// `in`) and when its buttons are pressed (`action`, `do`: `mute` or `leave`). While in, the app draws the picture
/// alone ([CallPipFrame]): no bars, no buttons, nothing else of the app's.
class CallPip {
  CallPip._();
  static final instance = CallPip._();

  static const channel = MethodChannel('ghost_messaging/pip');

  /// Whether the app is in picture in picture now.
  final inPip = ValueNotifier<bool>(false);

  bool _on = false;

  /// The call followed, for its mute.
  VoiceSession? _s;

  /// What was last told, so nothing is told twice; null until anything has been (and nothing is, out of a call).
  Map<String, Object?>? _said;

  /// Begins saying what there is to show, and hearing the window, once: on Android's phone app (lib/main.dart).
  void follow() {
    if (_on) return;
    _on = true;
    channel.setMethodCallHandler(_heard);
    CallPictures.instance.addListener(_sync);
    VideoShapes.changes.addListener(_sync);
    Voice.instance.addListener(_sync);
    _sync();
  }

  /// For a test: stops following, and forgets what was said.
  @visibleForTesting
  void stop() {
    if (!_on) return;
    _on = false;
    channel.setMethodCallHandler(null);
    CallPictures.instance.removeListener(_sync);
    VideoShapes.changes.removeListener(_sync);
    Voice.instance.removeListener(_sync);
    _s?.removeListener(_sync);
    _s = null;
    _said = null;
    inPip.value = false;
  }

  /// The window's shape for [p], as whole numbers: the picture's own once a frame of it has come (VideoShapes), else a
  /// screen's 16:9 or a camera's 4:3, held within what Android allows (2.39:1 either way).
  static ({int w, int h}) shapeOf(CallPicture p) {
    final shape = (VideoShapes.of(p.stream.id) ?? (p.screen ? 16 / 9 : 4 / 3)).clamp(1 / 2.39, 2.39);
    return (w: (shape * 100).round(), h: 100);
  }

  void _sync() {
    final s = Voice.instance.session;
    if (!identical(s, _s)) {
      _s?.removeListener(_sync);
      _s = s?..addListener(_sync);
    }
    final p = s == null ? null : CallPictures.instance.current;
    final Map<String, Object?> want;
    if (s == null || p == null) {
      // Nothing to show: said once where something was, and never where nothing ever was.
      if (_said == null || _said!['on'] == false) return;
      want = const {'on': false};
    } else {
      final shape = shapeOf(p);
      want = {'on': true, 'w': shape.w, 'h': shape.h, 'muted': s.muted, 'screen': p.screen};
    }
    if (mapEquals(want, _said)) return;
    _said = want;
    unawaited(channel.invokeMethod<void>('pip', want).catchError((Object _) {}));
  }

  Future<Object?> _heard(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'changed':
        inPip.value = args['in'] == true;
      case 'action':
        final s = Voice.instance.session;
        if (s == null) return null;
        switch (args['do']) {
          case 'mute':
            // A locked microphone (GMFB-49) stays muted: setMuted will not unmute it.
            s.setMuted(!s.muted);
          case 'leave':
            await Voice.instance.leave();
        }
    }
    return null;
  }
}

/// The app, and in picture in picture only the call's picture over it: the app stays built under it, still and
/// unseen, so it is where it was when the window comes back.
class CallPipFrame extends StatelessWidget {
  const CallPipFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: CallPip.instance.inPip,
        child: child,
        builder: (context, inPip, child) => Stack(fit: StackFit.expand, children: [
          TickerMode(enabled: !inPip, child: Offstage(offstage: inPip, child: child)),
          if (inPip) const Positioned.fill(child: PipPicture()),
        ]),
      );
}

/// The picture alone, filling the window: a camera's cut to it, a screen's whole on black. Black where the call or
/// its picture has ended, until Android puts the window away.
class PipPicture extends StatelessWidget {
  const PipPicture({super.key});

  @override
  Widget build(BuildContext context) => ColoredBox(
        key: const ValueKey('pip-picture'),
        color: const Color(0xFF000000),
        child: ListenableBuilder(
          listenable: CallPictures.instance,
          builder: (context, _) {
            final p = CallPictures.instance.current;
            final s = Voice.instance.session;
            if (p == null || s == null) return const SizedBox.expand();
            return StreamView(key: ObjectKey(p.stream), stream: p.stream, claim: true, contain: p.screen, mirror: p.me && !p.screen && !s.backCamera);
          },
        ),
      );
}
