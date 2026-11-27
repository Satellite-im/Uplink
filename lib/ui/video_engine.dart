import 'dart:async';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:video_player/video_player.dart';

import 'video_tracks.dart';

/// What the player shows of a video, from whichever engine plays it (lib/ui/video_screen.dart draws its controls from
/// this alone, so they are the same over either).
@immutable
class VideoNow {
  const VideoNow({this.ready = false, this.playing = false, this.position = Duration.zero, this.duration = Duration.zero, this.aspect = 0, this.error, this.buffered = Duration.zero, this.buffering = false, this.tracks = const VideoTracks()});
  final bool ready;
  final bool playing;
  final Duration position;
  final Duration duration;

  /// Width over height; 0 until known (or for sound alone).
  final double aspect;

  /// Why it cannot be played, in the engine's words; null while it can.
  final String? error;

  /// How far the engine has it ready to play from where it is (Duration.zero where it doesn't say), and whether it is
  /// waiting for more (Matt, 2026-11-18: "would it be possible to setup streaming and buffering of the file?"): the
  /// scrubber shows the one, a small spinner the other.
  final Duration buffered;
  final bool buffering;

  /// The sounds and subtitles it carries, and which are on (lib/ui/video_tracks.dart).
  final VideoTracks tracks;

  /// It played to its end and stopped there.
  bool get ended => ready && !playing && duration > Duration.zero && position >= duration;

  VideoNow copyWith({bool? ready, bool? playing, Duration? position, Duration? duration, double? aspect, String? error, Duration? buffered, bool? buffering, VideoTracks? tracks}) => VideoNow(
        ready: ready ?? this.ready,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        aspect: aspect ?? this.aspect,
        error: error ?? this.error,
        buffered: buffered ?? this.buffered,
        buffering: buffering ?? this.buffering,
        tracks: tracks ?? this.tracks,
      );

  @override
  bool operator ==(Object other) =>
      other is VideoNow && other.ready == ready && other.playing == playing && other.position == position && other.duration == duration && other.aspect == aspect && other.error == error && other.buffered == buffered && other.buffering == buffering && other.tracks == tracks;

  @override
  int get hashCode => Object.hash(ready, playing, position, duration, aspect, error, buffered, buffering, tracks);
}

/// Keeps a player in step with others (lib/voice/watch_together.dart; Matt, 2026-11-19: "watch together"): handed the
/// engine once it plays, told what the person does with it, and let go when the screen goes. What it does to the engine
/// itself is never told back.
abstract class VideoSync {
  void attach(VideoEngine engine);

  /// The person played, paused or moved it: [playing] and [position] as they left it.
  void user({required bool playing, required Duration position});
  void detach(VideoEngine engine);
}

/// What plays a video under the app's own controls (Matt, 2026-11-18: "add support for playing mkv video files and
/// mp4's within the app in a player themed by glacier UI"). Two engines, because no one engine is right everywhere:
///
/// - Android, Mac and Windows: [MediaKitEngine], libmpv by way of media_kit, which reads MKV, WebM, HEVC, AV1 and the
///   rest, and shows the subtitles inside a file and every sound it carries. AVFoundation (the Mac's old DeskVideo
///   window) could not open an .mkv at all, and Windows had no player. Android had ExoPlayer (video_player), which
///   plays an .mkv but shows no subtitle carried inside it, so a show's subtitles could not be turned on (Matt,
///   2026-11-18: "I still don't see subtitle or audio track selection options"; "Yes switch it").
/// - iPhone: [VideoPlayerEngine], the video_player package: AVFoundation, which reads MP4 and MOV but not Matroska: an
///   .mkv there says it can't be played and offers another app.
abstract class VideoEngine extends ValueNotifier<VideoNow> {
  VideoEngine() : super(const VideoNow());

  /// The engine for this device; a test puts its own stand-in here.
  static VideoEngine Function() make = defaultEngine;

  static VideoEngine defaultEngine() => usesMediaKit ? MediaKitEngine() : VideoPlayerEngine();

  /// Whether this device plays through libmpv: the computers and the Android phone.
  static bool get usesMediaKit => !kIsWeb && (PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);

  /// Opens [path], a file or an http address (a Files-space file served as it comes down, lib/files/file_stream.dart);
  /// once it is ready [value] says so, or says why not in [VideoNow.error]. Never throws.
  Future<void> open(String path);

  /// Whether [path] is an http(s) address to stream from, not a file on this device.
  /// In a browser, a file that came down is held in the tab under a `blob:` one (lib/files/file_sink.dart).
  static bool isAddress(String path) => path.startsWith('http://') || path.startsWith('https://') || path.startsWith('blob:');
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);

  /// From 0 (silent) to 1.
  Future<void> setVolume(double volume);

  /// Plays the sound [id] of [VideoNow.tracks]; nothing where the engine can't choose.
  Future<void> chooseAudio(String id) async {}

  /// Shows the subtitles [id] of [VideoNow.tracks], or none (null).
  Future<void> chooseSubtitle(String? id) async {}

  /// The picture, filling the box it is given and fitting the video inside it on black.
  Widget view();

  /// Lets the engine go. Quiet first ([pause], [setVolume]) where the screen is still going.
  Future<void> release();

  /// Sets [value] only while the engine is still held: a late report after [release] would be a call on a disposed
  /// notifier.
  bool _released = false;
  void _set(VideoNow now) {
    if (!_released && now != value) value = now;
  }

  @override
  void dispose() {
    _released = true;
    super.dispose();
  }
}

/// video_player under the controls: ExoPlayer on Android, AVFoundation on an iPhone.
///
/// Its sound can be chosen (video_player 2.14: ExoPlayer and AVFoundation both list a file's audio tracks), but it
/// can't show subtitles carried inside the file; a .srt or .vtt beside it is read and drawn over the picture instead.
class VideoPlayerEngine extends VideoEngine {
  VideoPlayerController? _video;
  String? _path;

  @override
  Future<void> open(String path) async {
    final video = VideoEngine.isAddress(path) ? VideoPlayerController.networkUrl(Uri.parse(path)) : VideoPlayerController.file(File(path));
    _video = video;
    _path = path;
    video.addListener(_changed);
    try {
      await video.initialize();
      _changed();
    } catch (e) {
      _set(value.copyWith(error: _words(e)));
      return;
    }
    // Not waited for: a slow folder never holds up the picture.
    unawaited(_readTracks());
  }

  /// The file's sounds, where the platform lists them, and the subtitle files beside it.
  Future<void> _readTracks() async {
    final video = _video;
    if (video == null) return;
    var audio = const <MediaTrack>[];
    String? on;
    try {
      if (video.isAudioTrackSupportAvailable()) {
        final found = await video.getAudioTracks();
        audio = [for (final t in found) MediaTrack(id: t.id, kind: TrackKind.audio, language: t.language, title: t.label)];
        on = found.where((t) => t.isSelected).firstOrNull?.id;
      }
    } catch (_) {}
    final path = _path;
    final subtitles = path == null || VideoEngine.isAddress(path) ? const <MediaTrack>[] : await subtitleFilesBeside(path, extensions: const ['srt', 'vtt']);
    if (_video != video) return;
    _set(value.copyWith(tracks: VideoTracks(audio: audio, audioOn: on, subtitles: subtitles, innerSubtitles: false)));
  }

  @override
  Future<void> chooseAudio(String id) async {
    final video = _video;
    if (video == null) return;
    try {
      await video.selectAudioTrack(id);
      _set(value.copyWith(tracks: value.tracks.copyWith(audioOn: id)));
    } catch (e) {
      debugPrint('video: audio track $id: $e');
    }
  }

  @override
  Future<void> chooseSubtitle(String? id) async {
    final video = _video;
    if (video == null) return;
    try {
      if (id == null) {
        await video.setClosedCaptionFile(null);
      } else {
        // Here a subtitle track's id is its file's path: read whole, as WebVTT or SubRip by its ending.
        final text = await File(id).readAsString();
        await video.setClosedCaptionFile(Future.value(id.toLowerCase().endsWith('.vtt') ? WebVTTCaptionFile(text) : SubRipCaptionFile(text)));
      }
      _set(value.copyWith(tracks: value.tracks.copyWith(subtitleOn: () => id)));
    } catch (e) {
      debugPrint('video: subtitles $id: $e');
    }
  }

  /// The controller changed: its state again as a [VideoNow]. The tracks are read apart ([_readTracks]) and chosen
  /// apart, so they are carried over as they stand, not made empty again by every tick.
  void _changed() {
    final v = _video?.value;
    if (v == null) return;
    _set(VideoNow(
      ready: v.isInitialized,
      playing: v.isPlaying,
      position: v.position,
      duration: v.duration,
      aspect: v.isInitialized ? v.aspectRatio : 0,
      error: v.hasError ? (v.errorDescription ?? 'unknown') : null,
      buffered: _bufferedFrom(v.buffered, v.position),
      buffering: v.isBuffering,
      tracks: value.tracks,
    ));
  }

  static String _words(Object e) => e is Exception ? e.toString() : '$e';

  /// The end of the buffered range the position is in (or the first one past it, just begun): how far it can play on.
  static Duration _bufferedFrom(List<DurationRange> ranges, Duration at) {
    var end = Duration.zero;
    for (final r in ranges) {
      if (r.end >= at && r.start <= at + const Duration(seconds: 1) && r.end > end) end = r.end;
    }
    return end;
  }

  @override
  Future<void> play() async => _video?.play();
  @override
  Future<void> pause() async => _video?.pause();
  @override
  Future<void> seek(Duration to) async => _video?.seekTo(to);
  @override
  Future<void> setVolume(double volume) async => _video?.setVolume(volume);

  @override
  Widget view() {
    final video = _video;
    if (video == null) return const SizedBox.expand();
    return Center(
      child: AspectRatio(
        aspectRatio: value.aspect == 0 ? 16 / 9 : value.aspect,
        child: Stack(fit: StackFit.expand, children: [
          VideoPlayer(video),
          // The subtitle file's line for this moment, drawn here (video_player's own ClosedCaption is Material's).
          if (value.tracks.subtitleOn != null)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: video,
              builder: (context, v, _) => SubtitleLine(v.caption.text),
            ),
        ]),
      ),
    );
  }

  @override
  Future<void> release() async {
    final video = _video;
    _video = null;
    if (video == null) return;
    video.removeListener(_changed);
    await video.dispose();
  }
}

/// libmpv under the controls, by way of media_kit: the computers and Android ([VideoEngine.usesMediaKit]). It draws
/// through a texture (media_kit_video) the controls lie over as they do over ExoPlayer's.
class MediaKitEngine extends VideoEngine {
  mk.Player? _player;
  mkv.VideoController? _controller;
  final _listening = <StreamSubscription<Object?>>[];

  /// How long a file has to say how long it runs before it is taken as one libmpv can't read; longer for one served as
  /// it comes down, whose first chunks (and, for an MKV, its index at the end) come from the relay first.
  static const _patience = Duration(seconds: 12);
  static const _patienceStreamed = Duration(seconds: 20);

  @override
  Future<void> open(String path) async {
    try {
      mk.MediaKit.ensureInitialized();
      final player = mk.Player();
      _player = player;
      _controller = mkv.VideoController(player);
      final s = player.stream;
      final loaded = Completer<void>();
      _listening
        ..add(s.playing.listen((p) => _set(value.copyWith(playing: p))))
        ..add(s.position.listen((p) => _set(value.copyWith(position: p))))
        ..add(s.duration.listen((d) {
          _set(value.copyWith(duration: d));
          if (d > Duration.zero && !loaded.isCompleted) loaded.complete();
        }))
        ..add(s.buffer.listen((b) => _set(value.copyWith(buffered: b))))
        ..add(s.buffering.listen((b) => _set(value.copyWith(buffering: b))))
        ..add(s.tracks.listen(_tracks))
        ..add(s.track.listen(_track))
        ..add(s.width.listen((_) => _aspect()))
        ..add(s.height.listen((_) => _aspect()))
        ..add(s.completed.listen((done) {
          // At its end libmpv stops where it is; it is shown as ended, to be played again.
          if (done) _set(value.copyWith(playing: false, position: value.duration));
        }))
        ..add(s.error.listen((e) {
          // An error before it has loaded is the file itself; one after is a moment's (a frame it skips).
          if (!loaded.isCompleted) {
            loaded.completeError(e);
          }
        }));
      final address = VideoEngine.isAddress(path);
      await player.open(mk.Media(address ? path : Uri.file(path).toString()), play: false);
      await loaded.future.timeout(address ? _patienceStreamed : _patience);
      _aspect();
      _set(value.copyWith(ready: true));
    } on TimeoutException {
      _set(value.copyWith(error: 'it did not start'));
    } catch (e) {
      _set(value.copyWith(error: '$e'));
    }
  }

  /// libmpv's lists, less its own 'auto' and 'no' entries. A subtitle file beside the video (name.srt, name.en.ass) is
  /// among them: libmpv loads those itself (its sub-auto).
  mk.Tracks _all = const mk.Tracks();
  void _tracks(mk.Tracks all) {
    _all = all;
    bool real(String id) => id != 'auto' && id != 'no';
    _set(value.copyWith(
      tracks: value.tracks.copyWith(
        audio: [for (final t in all.audio) if (real(t.id)) MediaTrack(id: t.id, kind: TrackKind.audio, language: t.language, title: t.title)],
        subtitles: [for (final t in all.subtitle) if (real(t.id)) MediaTrack(id: t.id, kind: TrackKind.subtitle, language: t.language, title: t.title, external: t.uri)],
      ),
    ));
    final on = _on;
    if (on != null) _track(on);
  }

  mk.Track? _on;

  /// Which sound and subtitles are playing. libmpv's own choice says 'auto': that is the file's default subtitles where
  /// it marks one (what libmpv then shows), and none where it marks none, so the list marks what is on screen (it had
  /// said Off over subtitles being shown).
  void _track(mk.Track on) {
    _on = on;
    final sub = on.subtitle.id;
    final shown = switch (sub) {
      'no' => null,
      'auto' => _all.subtitle.where((t) => t.id != 'auto' && t.id != 'no' && t.isDefault == true).firstOrNull?.id,
      _ => sub,
    };
    _set(value.copyWith(tracks: value.tracks.copyWith(audioOn: on.audio.id, subtitleOn: () => shown)));
  }

  @override
  Future<void> chooseAudio(String id) async {
    final player = _player;
    final track = _all.audio.where((t) => t.id == id).firstOrNull;
    if (player == null || track == null) return;
    await player.setAudioTrack(track);
  }

  @override
  Future<void> chooseSubtitle(String? id) async {
    final player = _player;
    if (player == null) return;
    final track = id == null ? mk.SubtitleTrack.no() : _all.subtitle.where((t) => t.id == id).firstOrNull;
    if (track == null) return;
    await player.setSubtitleTrack(track);
  }

  void _aspect() {
    final st = _player?.state;
    if (st == null) return;
    final w = st.width, h = st.height;
    if (w != null && h != null && w > 0 && h > 0) _set(value.copyWith(aspect: w / h));
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    // Played again from its end: libmpv starts it over from where it stopped, which is the end.
    if (value.ended) await player.seek(Duration.zero);
    await player.play();
  }

  @override
  Future<void> pause() async => _player?.pause();
  @override
  Future<void> seek(Duration to) async => _player?.seek(to);

  /// libmpv's volume runs 0 to 100.
  @override
  Future<void> setVolume(double volume) async => _player?.setVolume(volume * 100);

  @override
  Widget view() {
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    return mkv.Video(controller: controller, controls: mkv.NoVideoControls, fill: const Color(0xFF000000));
  }

  @override
  Future<void> release() async {
    for (final l in _listening) {
      unawaited(l.cancel());
    }
    _listening.clear();
    final player = _player;
    _player = null;
    _controller = null;
    await player?.dispose();
  }
}

/// Subtitle files beside [video]: its own name with a subtitle ending, and a language or a word between
/// ("film.srt", "film.en.srt", "film.forced.vtt"), each a track whose id is its path.
Future<List<MediaTrack>> subtitleFilesBeside(String video, {List<String> extensions = const ['srt', 'vtt', 'ass', 'ssa']}) async {
  final file = File(video);
  final name = file.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final stem = (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
  final found = <MediaTrack>[];
  try {
    await for (final e in file.parent.list(followLinks: false)) {
      if (e is! File) continue;
      final other = e.uri.pathSegments.last;
      final lower = other.toLowerCase();
      final end = lower.lastIndexOf('.');
      if (end <= 0 || !extensions.contains(lower.substring(end + 1))) continue;
      final base = lower.substring(0, end);
      if (base != stem && !base.startsWith('$stem.')) continue;
      final middle = base == stem ? '' : base.substring(stem.length + 1);
      // "film.en.forced" → 'en'; a word that isn't a language is kept only as the title.
      final first = middle.split('.').first;
      final language = knownLanguage(first) ? first : null;
      found.add(MediaTrack(id: e.path, kind: TrackKind.subtitle, language: language, title: other, external: true));
      if (found.length >= 20) break;
    }
  } catch (_) {}
  found.sort((a, b) => a.id.compareTo(b.id));
  return found;
}

/// A line of subtitles at the foot of the picture: white on a soft dark shade, as players draw them.
class SubtitleLine extends StatelessWidget {
  const SubtitleLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: const Alignment(0, 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(4)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 18, height: 1.3, shadows: [Shadow(blurRadius: 3, color: Color(0xCC000000))]),
            ),
          ),
        ),
      ),
    );
  }
}
