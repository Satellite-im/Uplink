/// What a call shows of a recording, and the recordings kept on this device (lib/voice/recorder.dart; Matt, 2026-11-19:
/// "a "record call" plugin where it records the call to an MP4 with multiple named audio tracks").
///
/// The line over the call is drawn whatever plugins are on: everyone in a call being recorded is told, and asked
/// whether their voice may be in it; until they say yes it is not.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../files/file_platform.dart';
import '../files/files_store.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../voice/channels.dart';
import '../plugins/scribe.dart' show ScribePlugin;
import '../voice/recorder.dart';
import '../voice/scribe.dart';
import '../voice/voice.dart';
import 'common.dart';
import 'recording_float.dart' show showRecordingMixer, showRecordingPlayback;
import 'video_screen.dart';
import '../l10n/words.dart';

/// The red line over a call that is being recorded: who records, whose voices are in it, and this device's answer.
class RecordingBanner extends StatefulWidget {
  const RecordingBanner({super.key});

  static const red = Color(0xFFDD3A30);

  /// Whether there is anything to show for [s].
  static bool shows(VoiceSession s) => s.recording != null || s.recordingsByOthers.isNotEmpty || CallRecorder.instance.finishing;

  @override
  State<RecordingBanner> createState() => _RecordingBannerState();

  /// Stops this device's recording and says it was saved, with a way to the recordings; or that it couldn't be.
  static Future<void> _stop(BuildContext context) async {
    final r = await CallRecorder.instance.stop();
    if (!context.mounted) return;
    if (r == null) {
      toast(context, 'The recording couldn\'t be saved');
      return;
    }
    toast(context, 'Recording saved', action: GlacierToastAction(label: 'Open', onPress: () => push(context, (_) => const RecordingsScreen())));
  }
}

class _RecordingBannerState extends State<RecordingBanner> {
  static const red = RecordingBanner.red;

  /// The time said moves on each second while this device records (nothing else says a second has passed).
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    CallRecorder.instance.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    CallRecorder.instance.removeListener(_changed);
    _tick?.cancel();
    super.dispose();
  }

  /// The recorder changed: [_tick] runs while this device records, and not otherwise.
  void _changed() {
    final on = CallRecorder.instance.since != null;
    if (on) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _stop(BuildContext context) => RecordingBanner._stop(context);

  @override
  Widget build(BuildContext context) {
    final v = Voice.instance;
    final s = v.session;
    if (s == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([s, CallRecorder.instance]),
      builder: (context, _) {
        final t = context.tokens;
        final rec = CallRecorder.instance;
        final lines = <Widget>[];
        // [icon] before the words: Stop has its square (Matt, 2026-11-19: "use icons for starting and stopping recording").
        Widget pill(String label, VoidCallback onPressed, {bool solid = false, LucideIcon? icon}) => Padding(
              padding: EdgeInsetsDirectional.only(start: t.space(2)),
              child: GlacierPressable(
                onPressed: onPressed,
                semanticLabel: label,
                builder: (context, state) => Container(
                  padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
                  decoration: BoxDecoration(color: solid ? const Color(0xFFFFFFFF) : const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(999)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[AppIcon(icon, size: 13, strokeWidth: 2.4, color: solid ? red : const Color(0xFFFFFFFF)), SizedBox(width: t.space(1))],
                    Text(label, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: solid ? red : const Color(0xFFFFFFFF))),
                  ]),
                ),
              ),
            );
        Widget line(String words, List<Widget> buttons, {String? key}) => Container(
              key: key == null ? null : ValueKey(key),
              margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(t.radius('lg'))),
              child: Row(children: [
                const AppIcon(Lucide.circleDot, size: 16, strokeWidth: 2.4, color: Color(0xFFFFFFFF)),
                SizedBox(width: t.space(2)),
                Expanded(child: Text(words, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF)))),
                ...buttons,
              ]),
            );
        if (s.recording != null) {
          final since = rec.since;
          final clock = since == null ? '' : ' · ${_clock(DateTime.now().difference(since))}';
          final names = rec.recordedNames;
          final others = names.length <= 1 ? 'only your voice so far' : names.skip(1).join(', ');
          // Mixer opens the tracks, their meters and faders full screen (Matt, 2026-11-20: "make the recording plugin
          // banner have a button for "mixer" and have it open a drawer full screen with the audio tracks and whatnot").
          // With the cameras and shared screens of those who said yes to both (GMFB-42).
          lines.add(line('Recording${rec.recordingVideo ? ' with video' : ''}$clock · $others', [
            pill('Mixer', () => unawaited(showRecordingMixer(context)), icon: Lucide.slidersHorizontal),
            pill('Stop', () => _stop(context), solid: true, icon: Lucide.square),
          ], key: 'recording-mine'));
        } else if (rec.finishing) {
          lines.add(line('Saving the recording…', const [], key: 'recording-saving'));
        }
        for (final e in s.recordingsByOthers.entries) {
          final who = v.nameOf(e.value);
          final yes = s.agreed.contains(e.key), no = s.declined.contains(e.key);
          // A recording that takes pictures asks for both at once, and says both afterwards (GMFB-42); the yes covers
          // the picture only where this was the question (VoiceSession.pictured).
          final video = s.takesVideo(e.key);
          final what = (yes ? s.pictured.contains(e.key) : video) ? 'voice and video' : 'voice';
          final are = what == 'voice' ? 'is' : 'are', not = what == 'voice' ? 'isn\'t' : 'aren\'t';
          if (!yes && !no) {
            lines.add(line('$who is recording this call. Include your $what?', [pill('Leave me out', () => s.answerRecording(e.key, false)), pill('Include me', () => s.answerRecording(e.key, true), solid: true)], key: 'recording-ask'));
          } else {
            lines.add(line(yes ? '$who is recording · your $what $are in it' : '$who is recording · your $what $not in it', [pill(yes ? 'Leave me out' : 'Include me', () => s.answerRecording(e.key, !yes))], key: 'recording-other'));
          }
        }
        if (lines.isEmpty) return const SizedBox.shrink();
        return Semantics(liveRegion: true, child: Column(mainAxisSize: MainAxisSize.min, children: lines));
      },
    );
  }

}

/// A length as m:ss, or h:mm:ss from an hour.
String _clock(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
}

/// The recordings kept on this device: played in the app's player (each voice a track to choose), shared, saved, sent
/// to the space they were made in, or deleted.
class RecordingsScreen extends StatelessWidget {
  const RecordingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([CallRecorder.instance, CallScribe.instance]),
      builder: (context, _) {
        final kept = CallRecorder.instance.kept;
        return GhostPage(
          title: 'Recordings',
          body: kept.isEmpty
              ? ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(10), t.space(4), 0), children: [
                  SettingsEmpty(
                    icon: AppIcon(Lucide.circleDot, size: 28, color: t.color('app-ink-3')),
                    title: 'No recordings yet',
                    body: const Tr('Record a call from its menu. Each voice is a track of its own, named, and only the voices of people who say yes are in it.'),
                  ),
                ])
              : ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)), children: [
                  PaneSection(children: [
                    for (final r in kept)
                      SettingRow(
                        key: ValueKey('recording-${r.id}'),
                        icon: AppIcon(r.video ? Lucide.video : Lucide.audioLines, size: 18),
                        label: '${r.space.isEmpty ? 'A call' : r.space} · ${_date(r.at)}${r.mixedFrom == null ? '' : ' · mixed again'}${r.video ? ' · with video' : ''}',
                        hint: Text('${_clock(Duration(seconds: r.seconds))} · ${r.people.join(', ')}${r.markers.isEmpty ? '' : ' · marked at ${r.markers.map((m) => _clock(Duration(seconds: m.floor()))).join(', ')}'}${_wordsNote(r)}'),
                        onPress: () => _actions(context, r),
                      ),
                  ]),
                ]),
        );
      },
    );
  }

  static String _date(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour, m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]}, ${h % 12 == 0 ? 12 : h % 12}:$m ${h < 12 ? 'am' : 'pm'}';
  }

  /// What the row says of a recording's words: being written out, or there.
  static String _wordsNote(Recording r) {
    final w = CallScribe.instance.working[r.id];
    if (w != null) return ' · writing out the words, ${(w * 100).round()}%';
    return CallScribe.instance.of(r) != null ? ' · words' : '';
  }

  /// A recording pressed: what can be done with it.
  static void _actions(BuildContext context, Recording r) {
    final name = 'Recording ${r.space.isEmpty ? '' : '${r.space} '}${r.at.toIso8601String().substring(0, 16).replaceAll(':', '.')}.mp4';
    final space = [for (final c in Voice.instance.channels) if (c.seed == r.seed) c].firstOrNull;
    final room = space == null ? null : Voice.instance.hangoutFor(space);
    showChoices(context, title: r.space.isEmpty ? 'Recording' : r.space, choices: [
      // Every voice a track of the timeline and a strip of the mixer, to play and mix again (lib/voice/recording_playback.dart).
      // First, before the player (Matt, 2026-11-23: "i want to see the mixer when viewing sounds recordings but it
      // just loads the media player view").
      // One with video is played first, since only the player shows its picture (GMFB-42); the mixer has its voices.
      if (r.video) Choice('Play', Lucide.play, () => push(context, (_) => VideoScreen(path: r.path, title: r.space.isEmpty ? 'Recording' : r.space))),
      if (r.people.isNotEmpty) Choice('Open in the mixer', Lucide.slidersHorizontal, () => unawaited(showRecordingPlayback(context, r))),
      if (!r.video) Choice('Play', Lucide.play, () => push(context, (_) => VideoScreen(path: r.path, title: r.space.isEmpty ? 'Recording' : r.space))),
      // Scribe's (lib/plugins/scribe.dart): the words, where it is on for this recording.
      if (CallScribe.instance.of(r) != null)
        Choice('Read the words', Lucide.scrollText, () => push(context, (_) => TranscriptScreen(recording: r)))
      else if (ScribePlugin.onFor(r) && !CallScribe.instance.working.containsKey(r.id))
        Choice('Write out the words', Lucide.scrollText, () async {
          final (t, why) = await CallScribe.instance.transcribe(r);
          if (!context.mounted) return;
          if (t == null) {
            toast(context, why ?? 'The words couldn\'t be written out');
          } else {
            push(context, (_) => TranscriptScreen(recording: r));
          }
        }),
      if (room != null && room.mayWrite)
        Choice('Send to ${r.space.isEmpty ? 'the space' : r.space}', Lucide.send, () {
          final o = room.sendFiles([(path: r.path, owned: false)], FilesStore.instance, text: 'Recording of the call, ${_clock(Duration(seconds: r.seconds))}: ${r.people.join(', ')}');
          if (context.mounted) toast(context, o == null ? 'It couldn\'t be sent there' : 'Sending to ${r.space}');
        }),
      if (FilePlatform.canShare) Choice('Share', Lucide.share2, () => FilePlatform.share(r.path, name, 'video/mp4')),
      if (FilePlatform.canSave) Choice('Save a copy', Lucide.download, () => FilePlatform.save(r.path, name, 'video/mp4')),
      Choice('Delete', Lucide.trash2, () => showChoices(context, title: 'Delete this recording? It can\'t be undone.', choices: [Choice('Delete recording', Lucide.trash2, () => CallRecorder.instance.delete(r), danger: true)]), danger: true),
    ]);
  }
}

/// A recording's words: a line each, who and when, and the line summing it up where there is one.
class TranscriptScreen extends StatelessWidget {
  const TranscriptScreen({super.key, required this.recording});
  final Recording recording;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = recording;
    final words = CallScribe.instance.of(r);
    final space = [for (final c in Voice.instance.channels) if (c.seed == r.seed) c].firstOrNull;
    final room = space == null ? null : Voice.instance.hangoutFor(space);
    return GhostPage(
      title: 'Words',
      actions: [
        if (words != null)
          IconTap(
            icon: Lucide.copy,
            label: 'Copy the words',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: words.text));
              toast(context, 'Words copied');
            },
          ),
        if (words != null && room != null && room.mayWrite)
          IconTap(
            icon: Lucide.send,
            label: 'Send the words to ${r.space}',
            onPressed: () {
              final file = r.path.replaceFirst(RegExp(r'\.mp4\$'), '.txt');
              final o = room.sendFiles([(path: file, owned: false)], FilesStore.instance, text: words.summary ?? 'The words of the call');
              toast(context, o == null ? 'They couldn\'t be sent there' : 'Sending to ${r.space}');
            },
          ),
      ],
      body: words == null
          ? const Center(child: Tr('No words written out yet.'))
          : ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)), children: [
              if (words.summary != null) ...[SettingsCallout(child: Text(words.summary!)), SizedBox(height: t.space(4))],
              if (words.lines.isEmpty) const Tr('Nobody\'s words could be made out.'),
              for (final l in words.lines)
                Padding(
                  padding: EdgeInsets.only(bottom: t.space(3)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${l.who} · ${Transcript.clock(l.start)}', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'))),
                    SizedBox(height: t.space(1)),
                    Text(l.text, style: pageText(t, t.fontSize('md'))),
                  ]),
                ),
            ]),
    );
  }
}
