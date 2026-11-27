import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../plugins/auto_leveler.dart';
import 'channels.dart';
import 'rtc.dart';

/// The auto leveler (Matt, 2026-11-20: "build the auto leveler plugin that levels everyone's voice levels"): in a call,
/// each person is turned up or down on this device so everyone is heard at about the same loudness: the quiet friend
/// brought up, the one shouting into their microphone brought down. Nothing is sent and nobody else's call changes;
/// it is this device's playback, on top of each person's own volume and the output volume (RtcMedia._apply).
///
/// How loud someone is comes from WebRTC's own reading of what arrives from them (the audio level the screens'
/// ripples already use), which is measured before this device's volume: turning someone up does not make them read
/// louder, so the leveler cannot chase itself.
///
/// [LevelerCore] is the arithmetic, kept apart so it can be tested on numbers alone; [AutoLeveler] runs it on the call
/// there is while the plugin is on (lib/plugins/auto_leveler.dart).
class LevelerCore {
  LevelerCore({this.targetDb = -22, this.mostUp = 9.5, this.mostDown = 9});

  /// The loudness everyone is brought to, in dB below full scale while speaking.
  final double targetDb;

  /// How far anyone is turned up or down at most, in dB: past that a voice is left as it is (a whisper stays a
  /// whisper; nobody is boosted into noise).
  final double mostUp, mostDown;

  /// A reading over this is speech; under it, silence or breath, which says nothing about how loud someone talks.
  static const speaking = 0.03;

  /// How quickly a voice's loudness is learned and a gain follows it, per reading (about every 150 ms): a few seconds
  /// of talk to settle, so a laugh or a cough does not swing anyone.
  static const learn = 0.06, follow = 0.12;

  // By person: how loud they are while speaking, as learned so far (dB), and the gain they are played at now.
  final Map<String, double> _heardDb = {};
  final Map<String, double> _gain = {};

  /// Each person's gain now: 1 is as they arrive.
  Map<String, double> get gains => Map.unmodifiable(_gain);

  /// What has been learned of [id]'s voice, in dB while speaking; null until they have spoken.
  double? heardDb(String id) => _heardDb[id];

  /// One reading of everyone's level (0 to 1, as WebRTC gives it; "me" is this device and is never levelled). Returns
  /// the gains after it.
  Map<String, double> feed(Map<String, double> levels) {
    for (final e in levels.entries) {
      if (e.key == 'me') continue;
      final level = e.value;
      if (level > speaking) {
        final db = 20 * math.log(level) / math.ln10;
        final was = _heardDb[e.key];
        _heardDb[e.key] = was == null ? db : was + (db - was) * learn;
      }
      final heard = _heardDb[e.key];
      if (heard == null) continue;
      final wantDb = (targetDb - heard).clamp(-mostDown, mostUp);
      final want = math.pow(10, wantDb / 20).toDouble();
      final g = _gain[e.key] ?? 1.0;
      _gain[e.key] = g + (want - g) * follow;
    }
    // Whoever left the call is forgotten.
    _gain.removeWhere((id, _) => !levels.containsKey(id));
    _heardDb.removeWhere((id, _) => !levels.containsKey(id));
    return gains;
  }

  /// Forgets everyone: the call was left, or the plugin switched off.
  void reset() {
    _gain.clear();
    _heardDb.clear();
  }
}

/// The leveler on the call there is, while the plugin is on in it.
class AutoLeveler extends ChangeNotifier {
  AutoLeveler._();
  static final AutoLeveler instance = AutoLeveler._();

  /// Whether the plugin is on in the call there is (AutoLevelerPlugin.onInCall), asked at every reading so turning it
  /// off in the middle of a call puts everyone back at once.
  bool Function() isOn = AutoLevelerPlugin.onInCall;

  final LevelerCore core = LevelerCore();

  // The call's levels being followed, and its player where it is one that can be told a gain (WebRTC's).
  ValueListenable<Map<String, double>>? _levels;
  RtcMedia? _media;

  /// The gain the player was last told for each person ([_heard]).
  final Map<String, double> _told = {};
  void Function(String id, double gain)? _toldForTest;

  /// What [id] is turned by now, in dB; 0 where nothing is done.
  double dbOf(String id) {
    final g = core.gains[id];
    return g == null || g <= 0 ? 0 : 20 * math.log(g) / math.ln10;
  }

  /// Levelling now: in a call, with the plugin on in it.
  bool get active => _levels != null && isOn();

  /// Follows the call there is (called as one is joined and left, as the soundboard is).
  void follow() {
    final media = Voice.instance.media;
    final levels = media?.levels;
    if (identical(levels, _levels)) return;
    _levels?.removeListener(_heard);
    _clear();
    _levels = levels;
    _media = media is RtcMedia ? media : null;
    _levels?.addListener(_heard);
  }

  /// For a test: follows [levels] as it would a call's, with no player to tell; [told] hears what a player would be.
  @visibleForTesting
  void attachForTest(ValueListenable<Map<String, double>>? levels, {void Function(String id, double gain)? told}) {
    _levels?.removeListener(_heard);
    _clear();
    _media = null;
    _toldForTest = told;
    _levels = levels;
    _levels?.addListener(_heard);
  }

  /// A reading of the call's levels: fed to [core], and the gains that moved told to the player.
  void _heard() {
    final levels = _levels;
    if (levels == null) return;
    if (!isOn()) {
      if (core.gains.isNotEmpty) _clear();
      return;
    }
    final after = core.feed(levels.value);
    _told.removeWhere((id, _) => !after.containsKey(id));
    var moved = false;
    for (final e in after.entries) {
      // Told to the player only when it has moved enough to hear: not 7 times a second for every person. Measured
      // from what the player was last told, not from the reading before: a gain easing in moves less than this at
      // each reading, and would else be left well short of where it settles.
      final told = _told[e.key];
      if (told != null && (told - e.value).abs() < 0.03) continue;
      _told[e.key] = e.value;
      _media?.setLevelGain(e.key, e.value);
      _toldForTest?.call(e.key, e.value);
      moved = true;
    }
    if (moved) notifyListeners();
  }

  /// Puts everyone back as they arrive and forgets what was learned.
  void _clear() {
    for (final id in core.gains.keys) {
      _media?.setLevelGain(id, 1);
    }
    core.reset();
    _told.clear();
    notifyListeners();
  }
}
