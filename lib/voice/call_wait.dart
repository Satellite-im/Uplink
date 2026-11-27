/// What a call is waiting for before everyone in it can be heard, in the words the screens say it in (Matt,
/// 2026-11-24: "show better loading states with skeletal loaders and a connecting banner so it doesn't just seem like
/// the app is frozen"). Coming into a call is several waits one after another, each of which can take seconds: the
/// chat's room on the relay server, the microphone (about three seconds on a Mac, where Apple's audio engine starts
/// slowly: docs/performance-audit.md), the call's own room, and then a way through to each person. Until now the call
/// stood on the screen through all of them looking as it does once connected, with nobody in it.
///
/// [CallWait.of] reads it from the call as it stands; lib/ui/connecting_banner.dart draws it.
library;

import 'package:flutter/foundation.dart';

import 'rtc.dart' show PeerLink;
import 'voice.dart';

@immutable
class CallWait {
  const CallWait(this.title, this.detail);

  /// `Connecting…` or `Reconnecting…`.
  final String title;

  /// What exactly is being waited for: `Starting the microphone`.
  final String detail;

  /// Both, for a place with one line and for reading aloud.
  String get line => '$title $detail';

  /// How long after coming in the microphone is still said to be starting where nothing has been heard from it. Its
  /// level is not read while the app is out of sight, so it may never be said to have started: the line goes anyway.
  static const micPatience = Duration(seconds: 8);

  /// What [s] is waiting for now; null when it is through, and for a call nothing is bringing in.
  ///
  /// [joining]: this call is being come into (Voice.joining), which is what makes a call not yet joined one that is
  /// connecting. [links]: how the way through to each person stands (RtcMedia.links). [micLive]: the microphone has
  /// been heard (RtcMedia.micLive). [nameOf] names the one person still being reached.
  static CallWait? of(VoiceSession s, {required bool joining, Map<String, PeerLink> links = const {}, bool micLive = true, DateTime? now, String Function(String id)? nameOf}) {
    if (!s.joined) {
      if (!joining) return null;
      return CallWait('Connecting…', switch (s.step) {
        JoinStep.room => 'Reaching the relay server',
        JoinStep.microphone => 'Starting the microphone',
        JoinStep.relay || JoinStep.done => 'Joining the call',
      });
    }
    // Out of the room until the relay server is back; whoever was connected is still heard.
    if (s.reconnecting) return const CallWait('Reconnecting…', 'The relay server was lost');
    // Others are here and nobody can be heard yet. With anyone through, each face says how its own way stands
    // (LinkBadge) and the call as a whole is connected.
    final waiting = [for (final id in s.members.keys) if (links[id] == PeerLink.connecting || links[id] == PeerLink.reconnecting) id];
    final through = s.members.keys.any((id) => links[id] == PeerLink.connected || links[id] == PeerLink.poor);
    if (waiting.isNotEmpty && !through) {
      final again = waiting.every((id) => links[id] == PeerLink.reconnecting);
      final who = waiting.length == 1 ? (nameOf?.call(waiting.single) ?? '').trim() : '';
      return CallWait(again ? 'Reconnecting…' : 'Connecting…', waiting.length > 1 ? 'Reaching ${waiting.length} people' : (who.isEmpty ? 'Reaching the other person' : 'Reaching $who'));
    }
    final since = s.since;
    if (!micLive && since != null && (now ?? DateTime.now()).difference(since) < micPatience) return const CallWait('Connecting…', 'Starting the microphone');
    return null;
  }

  @override
  bool operator ==(Object other) => other is CallWait && other.title == title && other.detail == detail;

  @override
  int get hashCode => Object.hash(title, detail);

  @override
  String toString() => line;
}
