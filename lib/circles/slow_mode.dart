import 'circle.dart';

// Slow mode (Matt, 2026-11-19: "add ... slow mode" as a default feature): a circle's space can let each person write
// only once in so many seconds, as a Discord channel's slow mode does. It is the space's in the circle's signed list
// (`CircleSpace.extra['slow']`: the seconds), so whoever manages spaces sets it and every member's app keeps to it;
// those who manage spaces are not held by it. A build from before passes over the key.

/// The waits a space can have, in seconds; 0 is off.
const slowModeChoices = [0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600];

/// [space]'s slow mode in seconds, 0 where it has none (or one this build doesn't offer).
int slowModeOf(CircleSpace space) {
  final s = space.extra['slow'];
  return s is int && slowModeChoices.contains(s) ? s : 0;
}

/// [seconds] as a person reads it: "Off", "30 seconds", "5 minutes", "1 hour".
String slowModeLabel(int seconds) {
  if (seconds <= 0) return 'Off';
  if (seconds < 60) return '$seconds seconds';
  if (seconds < 3600) return seconds == 60 ? '1 minute' : '${seconds ~/ 60} minutes';
  return seconds == 3600 ? '1 hour' : '${seconds ~/ 3600} hours';
}

/// What is [left] of a wait as a countdown's words, "0:12" or "4:05": part of a second counts as a whole one, so it
/// reads 0:00 only once the wait is over.
String slowModeLeft(Duration left) {
  final s = left.inSeconds + (left.inMilliseconds % 1000 > 0 ? 1 : 0);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
