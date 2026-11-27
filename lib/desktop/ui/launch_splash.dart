import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../kit/settings_type.dart' show pageText;
import '../../ui/common.dart' show GhostLogo;
import '../updates.dart';
import '../window_size.dart';

/// What the launch splash says, and how far a download has got (0 to 1; null for no bar).
typedef SplashStep = ({String words, double? progress});

/// The launch splash (Matt, 2026-11-20: "add a checking for updates splash window that shows before the app launches
/// and load the app on this screen too similar to how discord does on launch"): a small window with the logo, which
/// looks for a newer version first, brings it down and restarts into it where there is one, and otherwise loads the
/// app, then gives the window its size back and opens the app in it (lib/desktop/main.dart). The window is made small
/// by the Mac's and Windows' own halves (MainFlutterWindow.swift, splash.cpp) before anything is drawn.
class LaunchSplash extends StatelessWidget {
  const LaunchSplash({super.key, required this.step});

  final ValueListenable<SplashStep> step;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: ValueListenableBuilder<SplashStep>(
          valueListenable: step,
          builder: (context, now, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            _Breathing(child: GhostLogo(size: t.lenOf('5rem'))),
            SizedBox(height: t.space(5)),
            Text(
              now.words,
              key: const ValueKey('splash-words'),
              textAlign: TextAlign.center,
              style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink-2')),
            ),
            SizedBox(height: t.space(3)),
            // Room for the bar always, so the words don't jump when a download starts.
            SizedBox(
              width: t.lenOf('10rem'),
              height: t.lenOf('0.375rem'),
              child: now.progress == null ? null : GlacierProgressBar(value: now.progress! * 100, ariaLabel: 'Downloading the update'),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The logo growing and shrinking a little while the splash waits, as Discord's does.
class _Breathing extends StatefulWidget {
  const _Breathing({required this.child});
  final Widget child;

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: Tween(begin: 0.94, end: 1.04).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)), child: widget.child);
}

/// Looks for an update while [step] says so: a few seconds for the look itself, as long as a download takes once one
/// is found. A version put in place is restarted into; the app goes on loading if that fails or nothing is found.
/// [updates] keeps looking every few hours afterwards, as it always has.
Future<void> checkAtLaunch(MacUpdates updates, ValueNotifier<SplashStep> step, {Duration lookFor = const Duration(seconds: 8), Duration downloadFor = const Duration(minutes: 10), Duration restartWait = const Duration(seconds: 20)}) async {
  // What the splash says for where the update stands, each time it moves.
  void said() {
    step.value = switch (updates.phase) {
      MacUpdatePhase.downloading => (words: updates.release == null ? 'Downloading the update' : 'Downloading ${updates.release!.version}', progress: updates.progress),
      MacUpdatePhase.ready || MacUpdatePhase.restarting => (words: 'Restarting to update', progress: null),
      _ => (words: 'Checking for updates', progress: null),
    };
  }

  step.value = (words: 'Checking for updates', progress: null);
  updates.addListener(said);
  try {
    var done = false;
    final first = updates.startChecking().whenComplete(() => done = true);
    final started = DateTime.now();
    while (!done) {
      final waited = DateTime.now().difference(started);
      // The look alone is not waited on for long: offline, the app opens and the look goes on behind it.
      if (updates.phase != MacUpdatePhase.downloading && waited > lookFor) break;
      if (waited > downloadFor) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    unawaited(first.catchError((_) {}));
    // Not where restarting would have the computer ask for a password (Linux from the .deb, GMFB-32): that window
    // comes only of a press, on the update's banner or in Settings, never of opening the app.
    if (updates.phase == MacUpdatePhase.ready && !updates.asksPassword) {
      await updates.restart();
      // The app quits as it restarts; still here, it couldn't, and opens as it is.
      if (updates.phase == MacUpdatePhase.restarting) await Future<void>.delayed(restartWait);
    }
  } finally {
    updates.removeListener(said);
  }
}

/// Gives the window its own size back, or the small one for signing up ([compact]): the Mac's and Windows' halves made
/// it the splash's.
Future<void> leaveSplashWindow({bool compact = false}) => DeskWindow.leaveSplash(compact: compact);
