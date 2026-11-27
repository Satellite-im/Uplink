/// Scribe: a recorded call's words, written out with who said each line and when (Matt, 2026-11-19: "Start with the
/// recording plugin, then scribe").
///
/// A recording's MP4 has a track for each voice (lib/voice/recorder.dart), so who said what needs no guessing: each
/// track is heard on its own by the device's own speech recognition (android Scribe.kt, macos/ios Scribe.swift), cut
/// where its person pauses, and the lines of every track are put in order of time. Where the phone has its own summary
/// model (lib/summaries.dart's), a line sums the call up. Nothing leaves the device; the transcript is kept beside the
/// recording, as words (.txt) and as subtitles (.srt) the app's player shows over it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../sms.dart';
import 'recorder.dart';

/// One line someone said.
@immutable
class SaidLine {
  const SaidLine({required this.who, required this.start, required this.end, required this.text});
  final String who;
  final Duration start, end;
  final String text;

  Map<String, Object> toJson() => {'who': who, 'start': start.inMilliseconds, 'end': end.inMilliseconds, 'text': text};

  static SaidLine? fromJson(Object? j) {
    if (j is! Map || j['who'] is! String || j['text'] is! String || j['start'] is! int || j['end'] is! int) return null;
    return SaidLine(who: j['who'] as String, start: Duration(milliseconds: j['start'] as int), end: Duration(milliseconds: j['end'] as int), text: j['text'] as String);
  }
}

/// A recording's words.
@immutable
class Transcript {
  const Transcript({required this.lines, this.summary});
  final List<SaidLine> lines;

  /// One line on what the call was about, by the phone's own model; null where there is none.
  final String? summary;

  Map<String, Object?> toJson() => {'lines': [for (final l in lines) l.toJson()], 'summary': summary};

  static Transcript? fromJson(Object? j) {
    if (j is! Map || j['lines'] is! List) return null;
    return Transcript(lines: [for (final l in j['lines'] as List) ?SaidLine.fromJson(l)], summary: j['summary'] as String?);
  }

  /// As plain words: a line each, the time and who, then what they said.
  String get text => [if (summary != null) '$summary\n', for (final l in lines) '[${clock(l.start)}] ${l.who}: ${l.text}'].join('\n');

  /// As subtitles: each line its own, named.
  String get srt {
    String t(Duration d) {
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)},${(d.inMilliseconds % 1000).toString().padLeft(3, '0')}';
    }

    return [for (final (i, l) in lines.indexed) '${i + 1}\n${t(l.start)} --> ${t(l.end)}\n${l.who}: ${l.text}\n'].join('\n');
  }

  /// A time into the recording as m:ss, or h:mm:ss from an hour on.
  static String clock(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    return m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// Lines from each track, in order of time; lines that start together keep the tracks' order.
List<SaidLine> mergeLines(List<List<SaidLine>> perTrack) {
  final all = [
    for (final (t, lines) in perTrack.indexed)
      for (final (i, l) in lines.indexed) (l, t, i),
  ]..sort((a, b) {
      final c = a.$1.start.compareTo(b.$1.start);
      if (c != 0) return c;
      final d = a.$2.compareTo(b.$2);
      return d != 0 ? d : a.$3.compareTo(b.$3);
    });
  return [for (final x in all) x.$1];
}

/// Writes recordings out through the platform's speech recognition (channel 'ghost/scribe') and keeps the result in
/// files beside each recording.
class CallScribe extends ChangeNotifier {
  CallScribe._();
  static final CallScribe instance = CallScribe._();
  static const _channel = MethodChannel('ghost/scribe');

  bool? _available;

  /// Whether this device can write out words: a phone with on-device speech recognition (Android 13 and up), a Mac or
  /// an iPhone whose speech recognition runs on the device, or Windows with a speech language installed
  /// (windows/runner/speech.cpp).
  Future<bool> available() async {
    if (kIsWeb || !(PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isIOS || PlatformInfo.isWindows)) return false;
    try {
      return _available ??= await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return _available = false;
    }
  }

  /// The recordings being written out now, by id, and how far each is (0 to 1).
  final Map<String, double> working = {};

  /// The file beside [r]'s MP4 with [ext] in place of `mp4`.
  static File _file(Recording r, String ext) => File(r.path.replaceFirst(RegExp(r'\.mp4$'), '.$ext'));

  /// [r]'s words, where they were written out already.
  Transcript? of(Recording r) {
    try {
      return Transcript.fromJson(jsonDecode(_file(r, 'transcript.json').readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  /// Where [r]'s subtitles are, once written out: what the player shows over it.
  String? subtitlesOf(Recording r) {
    final f = _file(r, 'srt');
    return f.existsSync() ? f.path : null;
  }

  /// Writes out [r]'s words; the transcript, or the reason it couldn't.
  Future<(Transcript?, String?)> transcribe(Recording r) async {
    if (!await available()) return (null, 'This device can\'t write out speech yet.');
    if (working.containsKey(r.id)) return (null, 'Already writing it out.');
    working[r.id] = 0;
    notifyListeners();
    try {
      final language = PlatformDispatcher.instance.locale.toLanguageTag();
      final per = <List<SaidLine>>[];
      // Track 0 is everyone together; each after it is one person's (Recording.people).
      for (final (i, who) in r.people.indexed) {
        final got = await _channel.invokeMethod<List>('transcribe', {'path': r.path, 'track': i + 1, 'language': language}) ?? const [];
        per.add([
          for (final g in got)
            if (g is Map) SaidLine(who: who, start: Duration(milliseconds: (g['start'] as num).toInt()), end: Duration(milliseconds: (g['end'] as num).toInt()), text: '${g['text']}'),
        ]);
        working[r.id] = (i + 1) / r.people.length;
        notifyListeners();
      }
      final lines = mergeLines(per);
      // Only the Android phone has a summary model of its own.
      String? summary;
      if (lines.isNotEmpty && !kIsWeb && PlatformInfo.isAndroid) {
        summary = await Sms.instance.summarize([for (final l in lines) '${l.who}: ${l.text}'].join('\n'));
      }
      final t = Transcript(lines: lines, summary: summary);
      _file(r, 'transcript.json').writeAsStringSync(jsonEncode(t.toJson()));
      _file(r, 'txt').writeAsStringSync(t.text);
      _file(r, 'srt').writeAsStringSync(t.srt);
      return (t, null);
    } on PlatformException catch (e) {
      return (null, e.message ?? 'The words couldn\'t be written out.');
    } catch (e) {
      return (null, 'The words couldn\'t be written out: $e');
    } finally {
      working.remove(r.id);
      notifyListeners();
    }
  }

  /// Forgets [r]'s words (with the recording, or on their own).
  void forget(Recording r) {
    for (final ext in ['transcript.json', 'txt', 'srt']) {
      try {
        _file(r, ext).deleteSync();
      } catch (_) {}
    }
    notifyListeners();
  }
}
