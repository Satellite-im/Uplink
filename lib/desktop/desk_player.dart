import 'dart:async';
import 'dart:io';
import '../platform_info.dart';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart' as mk;

/// Playing a voice message on a computer with no native player for one (GMFB-32): Windows and Linux, by libmpv through
/// media_kit, which the app's video player already carries (lib/ui/video_engine.dart). The Mac and the iPhone play with
/// DeskSound.swift. It tells where it has got to as theirs does (`{part, position, duration, playing}` in
/// milliseconds), to [heard], which lib/desktop/platform.dart hands on to the screens.
class DeskPlayer {
  DeskPlayer._();

  // The one player there is at a time and the part it plays (-1: none), what it is listened to with, where it has
  // got to, and when [heard] was last told (so a moving position tells it only a few times a second).
  static mk.Player? _player;
  static int _part = -1;
  static final List<StreamSubscription<Object?>> _subs = [];
  static Duration _at = Duration.zero, _length = Duration.zero;
  static bool _playing = false;
  static DateTime _said = DateTime.fromMillisecondsSinceEpoch(0);

  /// Where it has got to, each time it moves.
  static void Function(Map<String, Object?> state)? heard;

  /// Tells [heard] where it stands; [ended] puts the position back at the start.
  static void _say({bool ended = false}) {
    heard?.call({'part': _part, 'position': ended ? 0 : _at.inMilliseconds, 'duration': _length.inMilliseconds, 'playing': _playing});
  }

  /// Plays part [part]'s sound ([bytes] the first time; null goes on with the one paused): null, or why it can't.
  static Future<String?> play(int part, Uint8List? bytes) async {
    final had = _player;
    if (had != null && _part == part) {
      await had.play();
      return null;
    }
    await halt();
    if (bytes == null || bytes.isEmpty) return 'the sound isn\'t here';
    try {
      mk.MediaKit.ensureInitialized();
      final dir = Directory('${Directory.systemTemp.path}${PlatformInfo.pathSeparator}ghost-voice-play')..createSync(recursive: true);
      final file = File('${dir.path}${PlatformInfo.pathSeparator}part-$part.m4a');
      await file.writeAsBytes(bytes, flush: true);
      final player = mk.Player();
      _player = player;
      _part = part;
      _at = Duration.zero;
      _length = Duration.zero;
      final s = player.stream;
      _subs
        ..add(s.playing.listen((p) {
          _playing = p;
          _say();
        }))
        ..add(s.duration.listen((d) => _length = d))
        ..add(s.position.listen((p) {
          _at = p;
          // A few times a second is enough for the line under the button.
          final now = DateTime.now();
          if (now.difference(_said) >= const Duration(milliseconds: 120)) {
            _said = now;
            _say();
          }
        }))
        ..add(s.completed.listen((done) {
          if (!done) return;
          _playing = false;
          _say(ended: true);
          unawaited(halt());
        }));
      await player.open(mk.Media(file.path));
      return null;
    } catch (e) {
      await halt();
      return 'this computer can\'t play it ($e)';
    }
  }

  /// Pauses it where it is: [play] with the same part goes on from there.
  static Future<void> pause() async {
    await _player?.pause();
    _playing = false;
    _say();
  }

  /// Stops it and lets the player go: the sound ended, another part is to play, or it could not be played.
  static Future<void> halt() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _player;
    _player = null;
    _part = -1;
    _playing = false;
    await p?.dispose();
  }
}
