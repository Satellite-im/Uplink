import 'package:flutter/foundation.dart';

import 'app_state.dart';

/// Why an Android phone keeps Uplink running after its screen is closed (android NetworksService.kt), and
/// telling Android so as the reasons change. Two reasons, each with or without the other:
///
/// - **Networks signed in** (Signal, Telegram and the like): their connections live in the app, so their messages
///   come only while it runs (lib/inbox/alerts.dart tells [networks]).
/// - **Calls from friends** (GMFB-28: "The other person's devices ring with accept/decline"; checked against the code
///   on 2026-11-25: "a fully closed app is not woken for a call, so it usually shows as missed"). There is no push
///   service behind this app: a friend's call reaches a phone only while the app is connected to the relay, and an
///   app Android has put away is not. With **Ring when the app is closed** on ([key], off unless switched on), the
///   app is kept running and goes on hearing, so the call rings, full screen on a locked phone as a phone's call is.
///
/// What it costs is said where it is switched on (lib/ui/settings_panes.dart, [reachHint]): a quiet notification that
/// Android asks for, some battery, and Android's leave to run while the phone sleeps ([sleepHint]). It keeps a running
/// app; it can't start one, so after the phone restarts the app is opened once (android Reach.kt says so then).
///
/// Seen on an emulator (Android 16, 2026-11-26), a made-up friend calling through a local relay two minutes after the
/// app was swiped away, the screen off: with the choice off the app was gone and the relay kept the call; with it on
/// the phone woke and rang, Answer and Decline. A phone where the app reads Google Messages' notifications is kept
/// running by Android for that already, and rang either way.
class KeepRunning {
  KeepRunning({required this.keep});

  /// The app's own, once made (lib/main.dart).
  static KeepRunning? instance;

  /// Tells Android: the networks' names, and whether calls are kept for. Nothing at all stops it.
  final void Function(List<String> names, {required bool calls}) keep;

  /// The choice: 'on' to ring while the app is closed.
  static const key = 'stay_reachable';

  /// Whether the person chose it.
  static bool wanted(AppState app) => app.flag(key, fallback: false);

  /// The switch's name, and what is said under it and under Android's question beside it.
  static const reachLabel = 'Ring when the app is closed';
  static const reachHint =
      'Uplink stays connected after you close it, so a friend\'s call rings and their messages come at once. Android shows a quiet notification while it does, and it uses some battery. After your phone restarts, open Uplink once.';
  static const sleepLabel = 'Run while the phone sleeps';
  static const sleepHint = 'To save battery a phone holds back apps while it sleeps, and a call may then ring late or not at all. Tap to let Uplink run unrestricted.';
  static const sleepAllowedHint = 'Android lets Uplink run while the phone sleeps, so a call can ring then too.';

  List<String> _networks = const [];
  bool _calls = false;
  List<String>? _saidNetworks;
  bool? _saidCalls;

  /// The networks signed in, by name, as they change.
  void networks(List<String> names) {
    _networks = List.of(names);
    _say();
  }

  /// Whether calls are to ring while the app is closed, as the choice changes.
  void calls(bool on) {
    _calls = on;
    _say();
  }

  /// Follows [app]'s choice from now on.
  void follow(AppState app) {
    void look() => calls(wanted(app));
    app.addListener(look);
    look();
  }

  void _say() {
    if (listEquals(_networks, _saidNetworks) && _calls == _saidCalls) return;
    // Nothing kept for, and nothing ever was: nothing to stop.
    if (_saidNetworks == null && _networks.isEmpty && !_calls) {
      _saidNetworks = const [];
      _saidCalls = false;
      return;
    }
    _saidNetworks = _networks;
    _saidCalls = _calls;
    keep(_networks, calls: _calls);
  }
}
