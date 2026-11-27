/// A call's captions (Matt, 2026-11-19: "Live captions"): each device writes out its own voice as it is said, on the
/// device (android LiveCaptions.kt, macos/ios LiveCaptions.swift, windows/runner/speech.cpp), and says the words in the call's room; whoever wants
/// captions sees everyone's, named, translated into their own language where Translate is on.
///
/// A device writes out its voice only while someone in the call wants captions ('cw' in their state,
/// VoiceSession.anyoneWantsCaptions), and never while muted. Only the words go out, sealed as everything in a call.
library;

import 'dart:async';
import '../platform_info.dart';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'channels.dart';
import 'voice.dart';

/// One line in the captions.
@immutable
class CaptionLine {
  const CaptionLine({required this.from, required this.words, required this.done, required this.at, this.shown});
  final String from;
  final String words;
  final bool done;
  final DateTime at;

  /// The words as shown, where they were translated.
  final String? shown;

  CaptionLine translated(String to) => CaptionLine(from: from, words: words, done: done, at: at, shown: to);
}

/// The captions of the call this device is in: starts and stops the platform's speech recogniser (channel
/// 'ghost/captions'), says this device's words in the call, and keeps everyone's lines for the overlay.
class CallCaptions extends ChangeNotifier {
  CallCaptions._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'heard') {
        final a = (call.arguments as Map).cast<String, Object?>();
        _ownHeard('${a['text'] ?? ''}', a['done'] == true);
      }
      return null;
    });
  }
  static final CallCaptions instance = CallCaptions._();
  static const _channel = MethodChannel('ghost/captions');

  /// Whether this platform writes out a voice as it is said.
  static bool get supported => !kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isIOS || PlatformInfo.isWindows);

  /// What a line from someone is shown as, where Translate would have it in another language (set by the plugin).
  static Future<String?> Function(String words)? translate;

  VoiceSession? _session;
  bool _writing = false;

  /// The lines now: the newest few finished ones, and each person's line still being said.
  final List<CaptionLine> lines = [];
  final Map<String, CaptionLine> _going = {};

  /// What to show: finished lines from the last half minute, then lines still being said, the newest last.
  List<CaptionLine> get shown {
    final now = DateTime.now();
    return [
      for (final l in lines) if (now.difference(l.at) < const Duration(seconds: 30)) l,
      ..._going.values,
    ].reversed.take(4).toList().reversed.toList();
  }

  /// Follows the call [Voice] is in: writes this device's voice out while anyone wants captions.
  void follow() {
    final s = Voice.instance.session;
    if (!identical(s, _session)) {
      _session?.removeListener(_check);
      _session?.onCaption = null;
      _session = s;
      lines.clear();
      _going.clear();
      s?.addListener(_check);
      s?.onCaption = _heard;
    }
    _check();
  }

  /// Starts or stops the recogniser as the call's wish for captions changes, and tells it whether the mic is muted
  /// (deafened counts as muted). Runs on every change of the session.
  void _check() {
    final s = _session;
    final want = s != null && s.joined && s.anyoneWantsCaptions && supported;
    if (want != _writing) {
      _writing = want;
      if (want) {
        unawaited(_channel.invokeMethod('start', {'language': PlatformDispatcher.instance.locale.toLanguageTag()}).catchError((_) => null));
      } else {
        unawaited(_channel.invokeMethod('stop').catchError((_) => null));
      }
    }
    if (want) unawaited(_channel.invokeMethod('muted', {'on': s.muted || s.deafened}).catchError((_) => null));
    notifyListeners();
  }

  /// Words the recogniser heard from this device's own voice: said in the call and shown here as 'me'. Dropped while
  /// muted or deafened.
  void _ownHeard(String words, bool done) {
    final s = _session;
    if (s == null || words.trim().isEmpty || s.muted || s.deafened) return;
    s.sayCaption(words, done: done);
    _put('me', words, done, mine: true);
  }

  void _heard(String from, String words, bool done) => _put(from, words, done);

  /// Takes a line from [from]: an unfinished one replaces that person's line in progress; a finished one joins
  /// [lines] (the newest 20 are kept) and, where it is someone else's, is translated in place once [translate] answers.
  void _put(String from, String words, bool done, {bool mine = false}) {
    final line = CaptionLine(from: from, words: words, done: done, at: DateTime.now());
    if (done) {
      _going.remove(from);
      lines.add(line);
      if (lines.length > 20) lines.removeAt(0);
      final t = translate;
      if (!mine && t != null) {
        unawaited(t(words).then((to) {
          if (to == null || to == words) return;
          final i = lines.indexOf(line);
          if (i >= 0) {
            lines[i] = line.translated(to);
            notifyListeners();
          }
        }));
      }
    } else {
      _going[from] = line;
    }
    notifyListeners();
  }

  /// Turns captions on or off for this device's person in the call.
  void setOn(bool on) {
    _session?.setWantsCaptions(on);
    follow();
  }

  /// Whether this device's person asked for captions in the call.
  bool get on => _session?.wantsCaptions ?? false;
}
