import 'dart:async';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../backgrounds.dart' show strongFill;
import '../files/file_platform.dart';
import '../files/file_stream.dart' show StreamedMedia;
import '../kit/settings_type.dart';
import 'common.dart';
import 'dialup/bevel.dart';
import 'dialup/parts.dart' show DialupTool;
import 'dialup/retro_button.dart';
import 'dialup/title_bar.dart';
import 'video_engine.dart';
import 'whole_window.dart';
import 'video_tracks.dart';

/// A video, the whole screen, in the app's own look (Matt, 2026-11-15: "id like a video player built with glacier UI
/// right now it looks like a very old android core system player"): the picture on black, a way back at the top, and
/// at the foot a dock in the look's own colours (play and pause, where it has got to, how long it runs, the sound).
/// A tap shows the controls or puts them away; they go by themselves after a few seconds while it plays. A double tap
/// on either half goes back or on ten seconds.
///
/// It plays MP4 and MKV alike on every device (Matt, 2026-11-18: "add support for playing mkv video files and mp4's
/// within the app in a player themed by glacier UI"): what plays it is a [VideoEngine] (ExoPlayer on Android,
/// AVFoundation on an iPhone, libmpv on a computer), and these controls drive whichever it is. On a computer they also
/// answer the keyboard (space, the arrows, F for full screen, Esc to leave it or go back), show a volume slider, and come back as
/// the mouse moves. A file that can't be played says so and offers the app the device would open it with.
class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required String this.path, this.title, this.poster, this.desk, this.dropFile = false, this.sync})
      : file = null,
        stream = null;

  /// Opened at once, while its file is still being made or brought down ([file]): a spinner over [poster] until it is
  /// here (Matt, 2026-11-17: "The app has gotten pretty laggy, especially when opening videos and exiting them").
  const VideoScreen.coming({super.key, required Future<String?> this.file, this.title, this.poster, this.desk, this.dropFile = false, this.sync})
      : path = null,
        stream = null;

  /// Played as it comes down (a Files-space file, lib/files/file_stream.dart), not waited for whole (Matt, 2026-11-18:
  /// "do we need to download the whole file to play? would it be possible to setup streaming and buffering of the
  /// file?"). Let go when the screen goes; what of it has come stays for next time.
  const VideoScreen.stream({super.key, required StreamedMedia this.stream, this.title, this.poster, this.desk, this.sync})
      : path = null,
        file = null,
        dropFile = false;

  final String? path;
  final Future<String?>? file;
  final StreamedMedia? stream;

  /// How long the player has to become ready (and a stream to give its address) before it is taken as one that can't
  /// be played here: never a spinner for ever (Matt, 2026-11-18, of MKV files: "right now they load forever in the
  /// app").
  static Duration openPatience = const Duration(seconds: 20);

  /// Who sent it, or the file's name: said at the top.
  final String? title;

  /// Kept in step with others watching the same file (lib/voice/watch_together.dart); null to play alone.
  final VideoSync? sync;

  /// Its picture, shown until the video itself is ready.
  final Uint8List? poster;

  /// Drawn for a computer (keys, volume slider, full screen); by the device when null.
  final bool? desk;

  /// The file is a copy made only to be played here (a computer's copy of a video on the phone, lib/desktop/remote.dart):
  /// removed once the screen has gone, so nothing of a conversation stays on the computer's disk (docs/desktop.md).
  final bool dropFile;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

/// The route a video opens in: up from the foot, quickly. Slid, not faded: a whole page faded is drawn apart and laid
/// over what is under it on every frame of the fade.
Route<void> videoRoute(Widget screen) => PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) => screen,
      transitionsBuilder: (context, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
        child: child,
      ),
    );

/// Whether this device is a computer, for the controls a computer gets.
bool get _deskDevice => !kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);

class _VideoScreenState extends State<VideoScreen> {
  VideoEngine? _engine;
  String? _path;
  String? _problem;
  String? _problemWhy;
  bool _controls = true;
  bool _muted = false;
  double _volume = 1;
  bool _fullscreen = false;
  bool _handedOn = false;

  /// Full screen on a computer (GMFB-65, Matt, Windows: "i expect the video itself to be fullscreend but the whole app
  /// is fullscreened and I still see the sidebar"): the player opens in the pane beside the list, so making the
  /// window full screen left the list, the rail and the title bar round it. While full screen the player is drawn
  /// over the whole window instead ([_over], on the app's outermost overlay), the same player moved there and back
  /// ([_player]), so the video plays on.
  final _over = OverlayPortalController(debugLabel: 'video full screen');
  final _player = GlobalKey(debugLabel: 'video player');

  /// The whole of a streamed file coming down for another app to open: how much is here, 0 to 1; null while it isn't.
  double? _getting;
  Timer? _hide;
  final _focus = FocusNode(debugLabel: 'video');

  /// Dragging the scrubber: where it is held, as a part of the whole.
  double? _held;

  /// A skip's ten seconds, shown for a moment on its side.
  String? _skipped;
  bool _skippedRight = false;
  Timer? _skipShown;

  /// What was last drawn of the player, so a change it reports that shows nothing new draws nothing.
  (bool, bool, int, int, String?, int, bool, VideoTracks)? _shown;

  /// The list of sounds and subtitles, open over the dock (Matt, 2026-11-18: "on the video player add support for
  /// switching audio and subtitles for files that support dual languages").
  bool _tracksOpen = false;

  /// The languages last chosen, matched once this video says what it carries.
  TrackMemory? _memory;
  bool _tracksMatched = false;

  bool get _desk => widget.desk ?? _deskDevice;
  VideoNow get _now => _engine?.value ?? const VideoNow();

  @override
  void initState() {
    super.initState();
    // After the first frame: the route is asked about, which initState may not do.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  /// The player is made once the screen has come in: its making is work on the thread that draws, and the slide-in
  /// would stutter under it. The file is waited for meanwhile, where it is still coming.
  Future<void> _start() async {
    final stream = widget.stream;
    String? path;
    if (stream != null) {
      stream.changes.addListener(_streamChanged);
      try {
        path = await stream.open().timeout(VideoScreen.openPatience);
      } catch (e) {
        if (mounted) _failed('$e', loading: stream.failure ?? (e is TimeoutException ? null : '$e'));
        return;
      }
    } else {
      path = widget.path ?? await widget.file;
    }
    if (!mounted) return;
    _path = path;
    if (path == null) {
      setState(() => _problem = 'This video couldn\'t be opened.');
      return;
    }
    final animation = ModalRoute.of(context)?.animation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      final came = Completer<void>();
      void listener(AnimationStatus s) {
        if (s == AnimationStatus.completed && !came.isCompleted) came.complete();
      }

      animation.addStatusListener(listener);
      await came.future.timeout(const Duration(milliseconds: 600), onTimeout: () {});
      animation.removeStatusListener(listener);
    }
    if (!mounted) return;
    final engine = VideoEngine.make();
    _engine = engine;
    engine.addListener(_changed);
    try {
      await engine.open(path).timeout(VideoScreen.openPatience);
    } on TimeoutException {
      if (mounted && _problem == null) _failed('it was not ready in ${VideoScreen.openPatience.inSeconds} s', loading: stream?.failure);
      return;
    }
    if (!mounted) return;
    if (engine.value.error != null || !engine.value.ready) {
      if (_problem == null) _failed(engine.value.error ?? 'it did not start', loading: stream?.failure);
      return;
    }
    setState(() {});
    // Watched together: where the others are, playing or not; alone: from the start.
    if (widget.sync != null) {
      widget.sync!.attach(engine);
    } else {
      unawaited(engine.play());
    }
    _soon();
  }

  /// Can't be played: said plainly, with the engine's own words kept for the log only. [loading] is why a streamed
  /// file stopped coming (the relay away, a chunk that didn't open), said where that is the reason.
  void _failed(String why, {String? loading}) {
    debugPrint('video: $why${loading == null ? '' : ' ($loading)'}');
    setState(() {
      _problem = loading != null ? 'This video couldn\'t be loaded.' : 'This video can\'t be played here.';
      _problemWhy = loading ?? 'This ${_desk ? 'computer' : 'phone'} can\'t read what\'s inside it. Another app may.';
      _controls = true;
    });
  }

  /// More of a streamed file is here (the scrubber shows it), or it stopped coming before the player was ready.
  void _streamChanged() {
    if (!mounted) return;
    final failure = widget.stream?.failure;
    if (failure != null && !_now.ready && _problem == null) {
      _failed('the stream stopped', loading: failure);
      return;
    }
    if (_now.ready) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppState.maybeOf(context);
    _memory = app == null ? null : TrackMemory.of(app);
  }

  @override
  void dispose() {
    _hide?.cancel();
    _skipShown?.cancel();
    _focus.dispose();
    if (_fullscreen) WholeWindow.gone(desk: _desk);
    final engine = _engine;
    final drop = widget.dropFile && !_handedOn ? _path : null;
    final stream = widget.stream;
    stream?.changes.removeListener(_streamChanged);
    if (engine != null) {
      widget.sync?.detach(engine);
      engine.removeListener(_changed);
      // Quiet at once; let go once the screen has gone: ExoPlayer's release waits on its own thread, and done now it
      // would hold up the frames that take the screen away.
      unawaited(engine.pause().catchError((_) {}));
      unawaited(engine.setVolume(0).catchError((_) {}));
      Timer(const Duration(milliseconds: 400), () async {
        try {
          await engine.release();
        } catch (_) {}
        engine.dispose();
        _drop(drop);
        // The stream's server goes once the player that read from it has (what has come down stays on the disk).
        stream?.close();
      });
    } else {
      _drop(drop);
      stream?.close();
    }
    super.dispose();
  }

  static void _drop(String? path) {
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  /// The engine reported something (several times a second while it plays).
  void _changed() {
    if (!mounted) return;
    final v = _now;
    if (v.error != null && _problem == null) {
      // A streamed file that stopped coming is said as that, not as a file this device can't read.
      _failed(v.error!, loading: widget.stream?.failure);
      return;
    }
    // At its end: the controls come back, to play it again.
    if (v.ended) _controls = true;
    if (v.ready && !_tracksMatched && (v.tracks.audio.isNotEmpty || v.tracks.subtitles.isNotEmpty)) _matchTracks(v.tracks);
    // Drawn again only where what shows has changed: the second it is at, playing or not, loaded, its length, its
    // sounds and subtitles.
    final now = (v.ready, v.playing, v.position.inSeconds, v.duration.inSeconds, v.error, v.buffered.inSeconds, v.buffering, v.tracks);
    if (now == _shown && _held == null) return;
    _shown = now;
    setState(() {});
  }

  /// The sound and subtitles in the languages last chosen, once, as the video first says what it carries.
  void _matchTracks(VideoTracks tracks) {
    _tracksMatched = true;
    final engine = _engine;
    final plan = _memory?.plan(tracks);
    if (engine == null || plan == null || plan.isEmpty) return;
    if (plan.audio != null) unawaited(engine.chooseAudio(plan.audio!));
    if (plan.subtitle != null || plan.subtitlesOff) unawaited(engine.chooseSubtitle(plan.subtitle));
  }

  void _chooseAudio(MediaTrack track) {
    unawaited(_engine?.chooseAudio(track.id));
    _memory?.choseAudio(track);
    setState(() => _tracksOpen = false);
    _soon();
  }

  /// Subtitles shown, or off (null).
  void _chooseSubtitle(MediaTrack? track) {
    unawaited(_engine?.chooseSubtitle(track?.id));
    _memory?.choseSubtitle(track);
    setState(() => _tracksOpen = false);
    _soon();
  }

  void _toggleTracks() {
    setState(() => _tracksOpen = !_tracksOpen);
    if (_tracksOpen) {
      _hide?.cancel();
    } else {
      _soon();
    }
  }

  /// The controls go by themselves a few seconds after the last touch, while it plays (not while the list of sounds
  /// and subtitles is open).
  void _soon() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && _now.playing && _held == null && _problem == null && !_tracksOpen) setState(() => _controls = false);
    });
  }

  /// Brings the controls back and starts the wait to hide them again.
  void _show() {
    if (!_controls) setState(() => _controls = true);
    _soon();
  }

  void _toggleControls() {
    // A tap on the picture puts the open list away first.
    if (_tracksOpen) {
      _toggleTracks();
      return;
    }
    setState(() => _controls = !_controls);
    if (_controls) _soon();
  }

  /// Plays or pauses, and tells whoever is watching together what the person did.
  void _playPause() {
    final engine = _engine;
    if (engine == null || !_now.ready) return;
    final playing = !_now.playing;
    if (_now.playing) {
      engine.pause();
    } else {
      engine.play();
    }
    widget.sync?.user(playing: playing, position: _now.position);
    _show();
  }

  /// Ten seconds on ([right]) or back, kept inside the video, with "+10 s" or "−10 s" shown for a moment.
  void _skip(bool right) {
    final engine = _engine;
    if (engine == null || !_now.ready) return;
    final v = _now;
    final to = v.position + Duration(seconds: right ? 10 : -10);
    final at = to < Duration.zero ? Duration.zero : (to > v.duration ? v.duration : to);
    engine.seek(at);
    widget.sync?.user(playing: v.playing, position: at);
    _skipShown?.cancel();
    setState(() {
      _skipped = right ? '+10 s' : '−10 s';
      _skippedRight = right;
    });
    _skipShown = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _skipped = null);
    });
  }

  void _setVolume(double v) {
    setState(() {
      // Near either end is the end: a click at the slider's very start is silence, not almost.
      _volume = v < 0.03 ? 0 : (v > 0.97 ? 1 : v);
      _muted = _volume == 0;
    });
    _engine?.setVolume(_volume);
    _show();
  }

  void _toggleMute() {
    setState(() {
      _muted = !_muted;
      if (!_muted && _volume == 0) _volume = 1;
    });
    _engine?.setVolume(_muted ? 0 : _volume);
    _show();
  }

  /// Full screen and back (lib/ui/whole_window.dart, which a screen shared in a call uses too). On a computer the
  /// player is drawn over the whole window, and back in its pane after (GMFB-65); the keys stay the player's. On a
  /// phone (Matt, 2026-11-21: "add the ability to full screen videos played from files") the bars are hidden and the
  /// phone turned the way the picture is; going back, or the button again, puts both back.
  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    final done = WholeWindow.set(_fullscreen, desk: _desk, over: _over, aspect: _desk ? 0 : _now.aspect);
    if (_desk) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
    await done;
  }

  Future<void> _back() async {
    if (_fullscreen) await _toggleFullscreen();
    if (mounted) await Navigator.of(context).maybePop();
  }

  /// Hands the video to another app, for one this player can't play. A file handed on is not removed when the player
  /// goes, since the other app is reading it.
  void _openElsewhere() {
    final stream = widget.stream;
    if (stream != null) {
      // Another app needs the whole file: what has come is kept, the rest brought down with its progress shown.
      if (_getting != null) return;
      setState(() => _getting = 0);
      unawaited(stream.whole((done, size) {
        if (mounted) setState(() => _getting = size <= 0 ? 1 : done / size);
      }).then((path) {
        if (!mounted) return;
        setState(() => _getting = null);
        unawaited(FilePlatform.open(path, widget.title ?? path.split(PlatformInfo.pathSeparator).last));
      }, onError: (Object e) {
        if (mounted) {
          setState(() {
            _getting = null;
            _problemWhy = stream.failure ?? '$e';
          });
        }
      }));
      return;
    }
    final path = _path;
    if (path == null) return;
    _handedOn = true;
    unawaited(FilePlatform.open(path, path.split(PlatformInfo.pathSeparator).last));
  }

  /// A computer's keys (Matt, 2026-11-18): space plays and pauses, the arrows go back and on and turn the sound, F is
  /// full screen and Esc goes back (out of full screen first).
  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    if (k == LogicalKeyboardKey.escape && !repeat && _tracksOpen) {
      _toggleTracks();
    } else if (k == LogicalKeyboardKey.escape && !repeat && _fullscreen) {
      // Esc leaves full screen, and the video stays (GMFB-65); Esc again goes back.
      unawaited(_toggleFullscreen());
    } else if (k == LogicalKeyboardKey.escape && !repeat) {
      unawaited(_back());
    } else if (k == LogicalKeyboardKey.space && !repeat) {
      _playPause();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _skip(false);
      _show();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _skip(true);
      _show();
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume((_muted ? 0 : _volume) + 0.1);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume((_muted ? 0 : _volume) - 0.1);
    } else if (k == LogicalKeyboardKey.keyF && !repeat) {
      unawaited(_toggleFullscreen());
    } else if (k == LogicalKeyboardKey.keyM && !repeat) {
      _toggleMute();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final pad = MediaQuery.paddingOf(context);
    final v = _now;
    final ready = v.ready && _problem == null;
    final total = v.duration;
    final at = _held != null ? total * _held! : v.position;
    final part = total.inMilliseconds == 0 ? 0.0 : (at.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final look = _DockLook.of(t, bevel);
    // What is ready to play, on the scrubber: the engine's buffer ahead of where it is, and a streamed file's parts
    // already on this device.
    final held = <(double, double)>[
      ...?widget.stream?.held(),
      if (total.inMilliseconds > 0 && v.buffered > v.position) (v.position.inMilliseconds / total.inMilliseconds, (v.buffered.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)),
    ];

    final dock = _Dock(
      look: look,
      desk: _desk,
      playing: v.playing,
      at: _clock(at),
      total: _clock(total),
      part: part,
      held: held,
      muted: _muted,
      volume: _muted ? 0 : _volume,
      fullscreen: _fullscreen,
      onPlayPause: _playPause,
      onHold: (p) {
        _hide?.cancel();
        setState(() => _held = p);
      },
      onLet: (p) {
        _engine?.seek(total * p);
        widget.sync?.user(playing: _now.playing, position: total * p);
        setState(() => _held = null);
        _soon();
      },
      onMute: _toggleMute,
      onVolume: _setVolume,
      onFullscreen: () => unawaited(_toggleFullscreen()),
      onTracks: v.tracks.choosable ? _toggleTracks : null,
      tracksOpen: _tracksOpen,
    );

    final top = bevel
        ? TitleBar(
            title: widget.title ?? 'Video',
            onClose: () => unawaited(_back()),
            actions: [
              DialupTool(icon: _fullscreen ? LucideMore.minimize : Lucide.maximize, label: _fullscreen ? 'Leave full screen' : 'Full screen', onPressed: () => unawaited(_toggleFullscreen()), size: 16, box: 32),
            ],
          )
        : Row(children: [
            _Round(look: look, icon: Lucide.arrowLeft, label: 'Back', onPressed: () => unawaited(_back())),
            SizedBox(width: t.space(3)),
            if (widget.title != null)
              Flexible(
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
                  decoration: look.panel(t),
                  child: Text(widget.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: look.ink)),
                ),
              ),
          ]);

    // A phone's back gesture leaves full screen first, as Esc does on a computer.
    final player = KeyedSubtree(key: _player, child: PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _fullscreen) unawaited(_toggleFullscreen());
      },
      child: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: MouseRegion(
        // The pointer goes with the controls while it plays, and brings them back as it moves.
        cursor: _controls || !ready ? MouseCursor.defer : SystemMouseCursors.none,
        onHover: (_) {
          if (_desk) _show();
        },
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: Stack(children: [
            // The picture, and the taps on it: one shows or hides the controls, two go back or on ten seconds.
            Positioned.fill(
              child: LayoutBuilder(builder: (context, box) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTapDown: (d) => _skippedRight = d.localPosition.dx > box.maxWidth / 2,
                  onDoubleTap: () => _skip(_skippedRight),
                  child: _problem != null
                      ? Center(
                          child: _Problem(look: look, words: _problem!, why: _problemWhy, getting: _getting, onOpen: (_path != null || widget.stream != null) && !PlatformInfo.isIOS ? _openElsewhere : null),
                        )
                      : !ready
                          // Its picture under the spinner until the video is ready: the screen is there at once.
                          ? Stack(alignment: Alignment.center, fit: StackFit.expand, children: [
                              if (widget.poster != null) Image.memory(widget.poster!, fit: BoxFit.contain, gaplessPlayback: true),
                              const Center(child: GhostSpinner(size: 30)),
                            ])
                          // The engine's own picture, which fits the video to the screen itself.
                          : _engine!.view(),
                );
              }),
            ),
            // Waiting for more of it (a streamed file not yet here, a slow disk): a small spinner, only while it waits.
            if (ready && v.buffering) const Positioned.fill(child: IgnorePointer(child: Center(child: GhostSpinner(size: 26)))),
            if (_skipped != null)
              PositionedDirectional(
                top: 0,
                bottom: 0,
                start: _skippedRight ? null : t.space(8),
                end: _skippedRight ? t.space(8) : null,
                child: Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
                      decoration: look.panel(t),
                      child: Text(_skipped!, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: look.ink)),
                    ),
                  ),
                ),
              ),
            // The controls, faded in and out together.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Stack(children: [
                    // A shade at the top and the foot, so the controls stand off a bright picture.
                    if (!bevel) ...[
                      const PositionedDirectional(top: 0, start: 0, end: 0, height: 140, child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x99000000), Color(0x00000000)]))))),
                      const PositionedDirectional(bottom: 0, start: 0, end: 0, height: 200, child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xAA000000), Color(0x00000000)]))))),
                    ],
                    PositionedDirectional(
                      top: bevel ? 0 : pad.top + t.space(3),
                      start: bevel ? 0 : t.space(4),
                      end: bevel ? 0 : t.space(4),
                      // Dial-Up's title bar runs the width, from under the status bar, as its windows' do.
                      child: bevel ? ColoredBox(color: DialupColors.of(t).titlebar, child: Padding(padding: EdgeInsets.only(top: pad.top), child: top)) : top,
                    ),
                    if (ready)
                      PositionedDirectional(
                        start: bevel ? 0 : t.space(4),
                        end: bevel ? 0 : t.space(4),
                        bottom: bevel ? 0 : pad.bottom + t.space(4),
                        child: Center(
                          child: ConstrainedBox(
                            // On a wide computer window the dock keeps to a width a hand can cross.
                            constraints: BoxConstraints(maxWidth: bevel ? double.infinity : t.lenOf('56rem')),
                            child: bevel ? dock.withFoot(pad.bottom) : dock,
                          ),
                        ),
                      ),
                    // The sounds and subtitles, over the dock's right end.
                    if (ready && _tracksOpen && v.tracks.choosable)
                      PositionedDirectional(
                        end: bevel ? t.space(2) : t.space(4),
                        bottom: (bevel ? pad.bottom : pad.bottom + t.space(4)) + 72,
                        child: _TrackPanel(look: look, tracks: v.tracks, maxHeight: MediaQuery.sizeOf(context).height * 0.6, onAudio: _chooseAudio, onSubtitle: _chooseSubtitle),
                      ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    ),
    ));
    if (!_desk) return player;
    // On a computer, full screen draws the player over the whole window: the list, the rail and the title bar are
    // under it (GMFB-65). Black stands in its pane meanwhile.
    final whole = _fullscreen && _over.isShowing;
    return OverlayPortal(
      controller: _over,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (_) => Positioned.fill(child: whole ? player : const SizedBox.shrink()),
      child: whole ? const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand()) : player,
    );
  }
}

/// The colours the controls draw in, from the look's own tokens: the page's paper, frosted over the picture, with its
/// ink and the look's one strong fill for play and for how far it has got; Dial-Up's silver, bevels and navy instead.
class _DockLook {
  _DockLook._({required this.bevel, required this.ground, required this.ink, required this.soft, required this.strong, required this.onStrong, required this.track, required this.rim});

  factory _DockLook.of(Tokens t, bool bevel) {
    if (bevel) {
      final c = DialupColors.of(t);
      return _DockLook._(bevel: true, ground: c.chrome, ink: c.onChrome, soft: c.onChrome, strong: c.titlebar, onStrong: c.titlebarInk, track: c.paper, rim: c.dark);
    }
    final (strong, onStrong) = strongFill(t);
    final ink = t.color('app-ink');
    return _DockLook._(
      bevel: false,
      ground: t.color('app-paper').withValues(alpha: 0.9),
      ink: ink,
      soft: t.color('app-ink-3'),
      strong: strong,
      onStrong: onStrong,
      track: ink.withValues(alpha: 0.18),
      rim: ink.withValues(alpha: 0.12),
    );
  }

  final bool bevel;
  final Color ground, ink, soft, strong, onStrong, track, rim;

  BoxDecoration panel(Tokens t) => BoxDecoration(color: ground, borderRadius: BorderRadius.circular(t.radius('full')), border: Border.all(color: rim));
}

/// A round button in the look's colours (the way back, mute, full screen); filled with the strong colour for play.
class _Round extends StatelessWidget {
  const _Round({required this.look, required this.icon, required this.label, required this.onPressed, this.size = 44, this.filled = false, this.flat = false});
  final _DockLook look;
  final LucideIcon icon;
  final String label;
  final VoidCallback onPressed;
  final double size;
  final bool filled;

  /// Inside the dock: no ground of its own, only a shade while pressed.
  final bool flat;

  @override
  Widget build(BuildContext context) {
    if (look.bevel) return RetroButton(onPressed: onPressed, icon: icon, semanticLabel: label, faceHeight: 32, minFaceWidth: 36, padding: const EdgeInsets.symmetric(horizontal: 6));
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      // A flat fill, not a blur of the video behind it: a blur over a playing video is drawn again for every one of
      // its frames, and needs pictures of its own made as the screen opens (the hitch on opening and closing).
      builder: (context, state) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? look.strong.withValues(alpha: state.pressed ? 0.82 : 1) : (flat ? look.ink.withValues(alpha: state.pressed ? 0.12 : (state.hovered ? 0.06 : 0)) : look.ground),
          border: filled || flat ? null : Border.all(color: look.rim),
        ),
        alignment: Alignment.center,
        child: AppIcon(icon, size: size * 0.42, wash: false, color: filled ? look.onStrong : look.ink),
      ),
    );
  }
}

/// The dock at the foot: play, the time, where it has got to, how long, the sound; on a computer a volume slider and
/// full screen beside them.
class _Dock extends StatelessWidget {
  const _Dock({
    required this.look,
    required this.desk,
    required this.playing,
    required this.at,
    required this.total,
    required this.part,
    this.held = const [],
    required this.muted,
    required this.volume,
    required this.fullscreen,
    required this.onPlayPause,
    required this.onHold,
    required this.onLet,
    required this.onMute,
    required this.onVolume,
    required this.onFullscreen,
    this.onTracks,
    this.tracksOpen = false,
    this.foot = 0,
  });

  final _DockLook look;
  final bool desk, playing, muted, fullscreen;
  final String at, total;
  final double part, volume;

  /// The parts ready to play, as fractions of the whole.
  final List<(double, double)> held;
  final VoidCallback onPlayPause, onMute, onFullscreen;
  final ValueChanged<double> onHold, onLet, onVolume;

  /// Opens the list of sounds and subtitles; null (no button) for a video with one sound and no subtitles.
  final VoidCallback? onTracks;
  final bool tracksOpen;

  /// Room under it for the phone's own bar (Dial-Up's panel runs to the foot of the screen).
  final double foot;

  /// This dock again with [foot] of room under it.
  _Dock withFoot(double foot) => _Dock(look: look, desk: desk, playing: playing, at: at, total: total, part: part, held: held, muted: muted, volume: volume, fullscreen: fullscreen, onPlayPause: onPlayPause, onHold: onHold, onLet: onLet, onMute: onMute, onVolume: onVolume, onFullscreen: onFullscreen, onTracks: onTracks, tracksOpen: tracksOpen, foot: foot);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _row(context, box.maxWidth));

  Widget _row(BuildContext context, double width) {
    final t = context.tokens;
    final time = pageText(t, t.fontSize('sm'), weight: 'semibold', color: look.ink, mono: true);
    // A computer's window made narrow keeps the scrubber long enough to use: the volume slider goes first (the arrows
    // and mute still turn the sound).
    final slider = desk && width >= t.lenOf('34rem');
    final row = Row(children: [
      _Round(look: look, icon: playing ? Lucide.pause : Lucide.play, label: playing ? 'Pause' : 'Play', onPressed: onPlayPause, size: 48, filled: true),
      SizedBox(width: t.space(3)),
      Text(at, style: time),
      SizedBox(width: t.space(3)),
      Expanded(child: _Track(look: look, part: part, held: held, label: 'Where the video is', onHold: onHold, onLet: onLet)),
      SizedBox(width: t.space(3)),
      Text(total, style: time.copyWith(color: look.soft, fontWeight: FontWeight.w400)),
      SizedBox(width: t.space(2)),
      if (onTracks != null) _Round(look: look, icon: LucideMore.languages, label: tracksOpen ? 'Close audio and subtitles' : 'Audio and subtitles', onPressed: onTracks!, size: 40, flat: true),
      _Round(look: look, icon: muted ? LucideMore.volumeX : Lucide.volume2, label: muted ? 'Sound on' : 'Mute', onPressed: onMute, size: 40, flat: true),
      if (slider) ...[
        SizedBox(width: t.lenOf('6rem'), child: _Track(look: look, part: volume, label: 'Volume', onHold: onVolume, onLet: onVolume)),
        SizedBox(width: t.space(2)),
      ],
      // Full screen on a computer and a phone alike.
      if (!look.bevel) _Round(look: look, icon: fullscreen ? LucideMore.minimize : Lucide.maximize, label: fullscreen ? 'Leave full screen' : 'Full screen', onPressed: onFullscreen, size: 40, flat: true),
    ]);
    if (look.bevel) {
      // Dial-Up: the window's silver panel along the foot, raised, its buttons the era's square ones.
      return Bevel(padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(3), t.space(2) + foot), child: row);
    }
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(3), t.space(2)),
      decoration: look.panel(t),
      child: row,
    );
  }
}

/// A line to drag along (where the video is, or the volume): the strong colour up to where it is, on a faint line, and
/// a knob that grows while held. A mouse drags it, or clicks a place on it, as a finger does. Dial-Up's is a white
/// well sunk into the panel with navy filling it and a raised silver knob.
class _Track extends StatefulWidget {
  const _Track({required this.look, required this.part, required this.label, required this.onHold, required this.onLet, this.held = const []});
  final _DockLook look;
  final double part;

  /// Parts drawn a shade stronger than the line: what is ready to play (Matt, 2026-11-18, streaming and buffering).
  final List<(double, double)> held;
  final String label;
  final ValueChanged<double> onHold;
  final ValueChanged<double> onLet;

  @override
  State<_Track> createState() => _TrackState();
}

class _TrackState extends State<_Track> {
  bool _holding = false;
  bool _hover = false;
  double _at = 0;

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      double partOf(double x) => (x / w).clamp(0.0, 1.0);
      final shown = _holding ? _at : widget.part;
      final big = _holding || _hover;
      final Widget line;
      if (look.bevel) {
        final knob = 12.0;
        line = Stack(alignment: AlignmentDirectional.centerStart, clipBehavior: Clip.none, children: [
          SizedBox(
            width: w,
            height: 10,
            child: Sunken(
              color: look.track,
              child: Stack(fit: StackFit.expand, children: [
                for (final (a, b) in widget.held) PositionedDirectional(start: (w - 4) * a, width: ((w - 4) * (b - a)).clamp(0.0, w), top: 0, bottom: 0, child: ColoredBox(color: look.strong.withValues(alpha: 0.3))),
                FractionallySizedBox(alignment: AlignmentDirectional.centerStart, widthFactor: shown, child: ColoredBox(color: look.strong)),
              ]),
            ),
          ),
          PositionedDirectional(start: (w * shown - knob / 2).clamp(0.0, w - knob), child: SizedBox(width: knob, height: 20, child: const Bevel())),
        ]);
      } else {
        final knob = big ? 16.0 : 12.0;
        line = Stack(alignment: AlignmentDirectional.centerStart, clipBehavior: Clip.none, children: [
          Container(height: 4, decoration: BoxDecoration(color: look.track, borderRadius: BorderRadius.circular(2))),
          for (final (a, b) in widget.held)
            PositionedDirectional(start: w * a, child: Container(width: (w * (b - a)).clamp(0.0, w), height: 4, decoration: BoxDecoration(color: look.ink.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)))),
          Container(width: w * shown, height: 4, decoration: BoxDecoration(color: look.strong, borderRadius: BorderRadius.circular(2))),
          PositionedDirectional(
            start: (w * shown - knob / 2).clamp(-knob / 2, w - knob / 2),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: knob,
              height: knob,
              decoration: BoxDecoration(shape: BoxShape.circle, color: look.strong, border: Border.all(color: look.ground, width: 1.5)),
            ),
          ),
        ]);
      }
      return Semantics(
        slider: true,
        label: widget.label,
        value: '${(shown * 100).round()}%',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => setState(() {
              _holding = true;
              _at = partOf(d.localPosition.dx);
              widget.onHold(_at);
            }),
            onHorizontalDragUpdate: (d) => setState(() {
              _at = partOf(d.localPosition.dx);
              widget.onHold(_at);
            }),
            onHorizontalDragEnd: (_) {
              setState(() => _holding = false);
              widget.onLet(_at);
            },
            onTapUp: (d) => widget.onLet(partOf(d.localPosition.dx)),
            child: SizedBox(height: 36, child: line),
          ),
        ),
      );
    });
  }
}

/// The sounds and subtitles a video carries, to choose from: each named by its language and title, the one on marked,
/// Off first among the subtitles. In the look's own card (Dial-Up's raised silver panel).
class _TrackPanel extends StatelessWidget {
  const _TrackPanel({required this.look, required this.tracks, required this.maxHeight, required this.onAudio, required this.onSubtitle});
  final _DockLook look;
  final VideoTracks tracks;
  final double maxHeight;
  final ValueChanged<MediaTrack> onAudio;
  final ValueChanged<MediaTrack?> onSubtitle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = look.bevel ? DialupColors.of(t).ink : look.ink;
    final soft = look.bevel ? DialupColors.of(t).inkSoft : look.soft;
    Widget heading(String words) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(1)),
          child: Text(words.toUpperCase(), style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: soft)),
        );
    Widget row(String words, bool on, VoidCallback pick) => GlacierPressable(
          onPressed: pick,
          semanticLabel: words,
          selected: on,
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
            decoration: BoxDecoration(
              color: look.bevel
                  ? (state.pressed || state.hovered ? DialupColors.of(t).titlebar.withValues(alpha: 0.15) : null)
                  : ink.withValues(alpha: state.pressed ? 0.12 : (state.hovered ? 0.06 : 0)),
              borderRadius: BorderRadius.circular(look.bevel ? 0 : t.radius('md')),
            ),
            child: Row(children: [
              SizedBox(width: 20, child: on ? AppIcon(Lucide.check, size: 16, color: ink, wash: false) : null),
              SizedBox(width: t.space(2)),
              Flexible(child: ExcludeSemantics(child: Text(words, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: on ? 'semibold' : 'regular', color: ink)))),
            ]),
          ),
        );
    final audioNames = trackLabels(tracks.audio);
    final subtitleNames = trackLabels(tracks.subtitles);
    final audioOn = tracks.audioShown;
    final subtitleOn = tracks.subtitleShown;
    final body = SingleChildScrollView(
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (tracks.audio.length > 1) ...[
          heading('Audio'),
          for (var i = 0; i < tracks.audio.length; i++) row(audioNames[i], tracks.audio[i].id == audioOn, () => onAudio(tracks.audio[i])),
        ],
        if (tracks.subtitles.isNotEmpty || !tracks.innerSubtitles) heading('Subtitles'),
        if (tracks.subtitles.isNotEmpty) ...[
          row('Off', subtitleOn == null, () => onSubtitle(null)),
          for (var i = 0; i < tracks.subtitles.length; i++) row(subtitleNames[i], tracks.subtitles[i].id == subtitleOn, () => onSubtitle(tracks.subtitles[i])),
        ],
        // The phone's player shows only a subtitle file beside the video, never those inside it: said, not hidden.
        if (!tracks.innerSubtitles)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(1)),
            child: Text('Subtitles inside a video can\'t be shown on this device yet.', style: pageText(t, t.fontSize('xs'), color: soft, height: 1.4)),
          ),
      ]),
    );
    final box = ConstrainedBox(constraints: BoxConstraints(maxWidth: t.lenOf('18rem'), minWidth: t.lenOf('12rem'), maxHeight: maxHeight), child: body);
    if (look.bevel) return Bevel(padding: EdgeInsets.all(t.space(1)), child: box);
    return Container(
      decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: look.rim)),
      padding: EdgeInsets.symmetric(horizontal: t.space(1)),
      child: box,
    );
  }
}

/// A video that can't be played: what is wrong in a card of the look's own, and the device's own app for it.
class _Problem extends StatelessWidget {
  const _Problem({required this.look, required this.words, this.why, this.onOpen, this.getting});
  final _DockLook look;
  final String words;
  final String? why;
  final VoidCallback? onOpen;

  /// The whole file coming down for another app, 0 to 1: shown in place of the button while it comes.
  final double? getting;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = look.bevel ? DialupColors.of(t).ink : look.ink;
    final soft = look.bevel ? DialupColors.of(t).inkSoft : look.soft;
    final body = Column(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(Lucide.film, size: 28, color: soft, wash: false),
      SizedBox(height: t.space(3)),
      Text(words, textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink)),
      if (why != null) ...[
        SizedBox(height: t.space(1)),
        Text(why!, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: soft, height: 1.4)),
      ],
      if (getting != null) ...[
        SizedBox(height: t.space(4)),
        SizedBox(width: 220, child: GlacierProgressBar(value: getting! * 100, ariaLabel: 'Getting the whole file')),
        SizedBox(height: t.space(2)),
        Text('Getting the whole file… ${(getting! * 100).floor()}%', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: soft)),
      ] else if (onOpen != null) ...[
        SizedBox(height: t.space(4)),
        if (look.bevel)
          RetroButton(onPressed: onOpen, icon: Lucide.externalLink, label: 'Open with another app', primary: true)
        else
          GlacierPressable(
            onPressed: onOpen,
            semanticLabel: 'Open with another app',
            excludeSemantics: true,
            builder: (context, state) => Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
              decoration: BoxDecoration(color: look.strong.withValues(alpha: state.pressed ? 0.85 : 1), borderRadius: BorderRadius.circular(t.radius('full'))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AppIcon(Lucide.externalLink, size: 16, color: look.onStrong, wash: false),
                SizedBox(width: t.space(2)),
                Flexible(child: Text('Open with another app', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: look.onStrong))),
              ]),
            ),
          ),
      ],
    ]);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: t.lenOf('24rem')),
      child: Padding(
        padding: EdgeInsets.all(t.space(4)),
        child: look.bevel
            ? Bevel(padding: EdgeInsets.all(t.space(5)), child: Sunken(padding: EdgeInsets.all(t.space(5)), child: body))
            : Container(
                padding: EdgeInsets.all(t.space(6)),
                decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: look.rim)),
                child: body,
              ),
      ),
    );
  }
}
