/// The recording on top of the whole app while a call is being recorded (Matt, 2026-11-20: "expand on the recording
/// plugin, I'd like to show the different audio tracks being recorded and the sound waves from each audio track,
/// collapse it to a button that can be moved around the app when expanded the tracks and stuff should appear similar
/// to adobe premiere or something like that").
///
/// Collapsed it is a small pill, a red dot, the time and a live level, that can be dragged anywhere and stays where it
/// is put. Pressed, it opens into a panel shaped as a video editor's timeline: a ruler of time across the top, a
/// header for each track at the left (its colour, A1, A2…, its name, live or left, and a level meter), and each track's
/// clip growing to the right with its waveform in it, the playhead at the live end. Everyone's mix is the first track,
/// as the file's first track is. The timeline follows the live end; dragged back, it stays where it is until Live.
/// Stop and the way back to the pill are in the panel's header.
///
/// No longer a pill (Matt, 2026-11-20: "make the recording plugin banner have a button for "mixer" and have it open a
/// drawer full screen with the audio tracks and whatnot instead of the floating pill"): the recording's banner over the
/// call has Mixer, which opens this panel as a drawer filling the window ([showRecordingMixer]).
///
/// Reworked the same day (Matt: "show audio tracks being recorded in real time with meters and whatnot as well as
/// voice level changing and more"): every track has a real meter (recording_mixer.dart) and mute and solo; the panel
/// has a second face, the mixer, with a fader per voice for how loud it is in the mix; the mix's lane is what the
/// faders made of the voices at each moment; and a moment can be marked, a flag on the ruler kept with the recording.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../voice/recorder.dart';
import '../voice/recording_playback.dart';
import '../voice/channels.dart' show Voice;
import 'common.dart';
import 'plugins_page/plugin_art.dart' show PluginHues;
import 'recording_ui.dart' show RecordingsScreen;
import '../l10n/words.dart';

part 'recording_mixer.dart';

/// The key 'Everyone' is drawn under: the mix of every track, as the file's first track is.
const _mixKey = '*mix';

/// The recording's mixer as a drawer over the whole app, opened from the recording's banner over the call (Matt,
/// 2026-11-20: "make the recording plugin banner have a button for "mixer" and have it open a drawer full screen with
/// the audio tracks and whatnot instead of the floating pill"). It slides up over everything and fills the window; its
/// own button closes it, and it closes by itself a moment after the recording ends (long enough for the toast that the
/// recording was saved to show over the app).
Future<void> showRecordingMixer(BuildContext context, {CallRecorder? recorder}) {
  final nav = Navigator.of(context, rootNavigator: true);
  return nav.push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) => RecordingMixerDrawer(recorder: recorder ?? CallRecorder.instance, navigator: nav),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  ));
}

/// A recording kept on this device opened in the timeline and the mixer, to play and mix again (Matt, 2026-11-21: "I'd
/// like to be able to open recordings saved from calls in the multi track view with the mixer"): the same drawer as
/// while recording, filling the window, with a play button and a playhead in place of Stop and the live end.
///
/// Also what a recording opens in from a Files space or a chat (lib/ui/files_space/file_preview.dart; Matt,
/// 2026-11-23: "i want to see the mixer when viewing sounds recordings but it just loads the media player view").
/// There [plain] is given: the way to the app's video player for the same file, a button in the drawer's header and
/// under the words where the voices couldn't be opened; the drawer is closed first. And [passing] is true: the file
/// is in no list here, so what is decoded of it goes when the drawer closes (RecordingPlayback.passing).
Future<void> showRecordingPlayback(BuildContext context, Recording recording, {VoidCallback? plain, bool passing = false}) {
  final nav = Navigator.of(context, rootNavigator: true);
  return nav.push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) => RecordingPlaybackDrawer(recording: recording, plain: plain, passing: passing),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  ));
}

/// The drawer [showRecordingPlayback] opens: the recording's voices decoded (with how far), then its timeline.
class RecordingPlaybackDrawer extends StatefulWidget {
  const RecordingPlaybackDrawer({super.key, required this.recording, this.playback, this.plain, this.passing = false});
  final Recording recording;

  /// Opens the same file in the app's video player, once this drawer has closed; null where the drawer was opened
  /// from somewhere that offers the player itself (the recordings' list).
  final VoidCallback? plain;

  /// Opened from a file in no list here: its decoded voices are deleted on closing (RecordingPlayback.passing).
  final bool passing;

  /// Given already open, for a test or a picture.
  final RecordingPlayback? playback;

  @override
  State<RecordingPlaybackDrawer> createState() => _RecordingPlaybackDrawerState();
}

class _RecordingPlaybackDrawerState extends State<RecordingPlaybackDrawer> {
  late final RecordingPlayback _p = widget.playback ?? (RecordingPlayback(widget.recording)
    ..passing = widget.passing
    ..open());

  @override
  void dispose() {
    if (widget.playback == null) _p.dispose();
    super.dispose();
  }

  /// Pauses what is playing and closes the drawer.
  void _close() {
    unawaited(_p.pause());
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  /// Closes the drawer and opens the file in the video player instead.
  void _plain() {
    final plain = widget.plain;
    _close();
    plain?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      key: const ValueKey('recording-playback'),
      color: _Studio.panel,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _p,
          builder: (context, _) {
            if (_p.ready) return RecordingTimeline(recorder: _p, fullScreen: true, onClose: _close, onPlain: widget.plain == null ? null : _plain);
            return Stack(children: [
              Center(
                child: Padding(
                  padding: EdgeInsets.all(t.space(6)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _p.error ?? 'Opening each voice… ${((_p.opening ?? 0) * 100).round()}%',
                      key: const ValueKey('recording-playback-status'),
                      textAlign: TextAlign.center,
                      style: pageText(t, t.fontSize('sm'), color: _Studio.ink2),
                    ),
                    if (_p.error == null) ...[
                      SizedBox(height: t.space(3)),
                      SizedBox(width: t.lenOf('12rem'), child: GlacierProgressBar(value: (_p.opening ?? 0) * 100, ariaLabel: 'Opening each voice')),
                    ],
                    // The voices couldn't be opened, or are slow to: the file still plays in the player, as everyone
                    // mixed (its first track).
                    if (widget.plain != null) ...[
                      SizedBox(height: t.space(4)),
                      _ToolButton(key: const ValueKey('recording-plain'), icon: Lucide.film, label: 'Open in the player', text: 'Open in the player', onPressed: _plain),
                    ],
                  ]),
                ),
              ),
              PositionedDirectional(top: t.space(2), end: t.space(2), child: _ToolButton(key: const ValueKey('recording-collapse'), icon: Lucide.chevronDown, label: 'Close the mixer', onPressed: _close)),
            ]);
          },
        ),
      ),
    );
  }
}

/// The drawer [showRecordingMixer] opens: the timeline and the mixer, the whole window.
class RecordingMixerDrawer extends StatefulWidget {
  const RecordingMixerDrawer({super.key, required this.recorder, this.navigator});
  final CallRecorder recorder;

  /// The app's own navigator, for the page a saved recording opens once this is closed.
  final NavigatorState? navigator;

  @override
  State<RecordingMixerDrawer> createState() => _RecordingMixerDrawerState();
}

class _RecordingMixerDrawerState extends State<RecordingMixerDrawer> {
  Timer? _clock, _closing;

  @override
  void initState() {
    super.initState();
    widget.recorder.addListener(_changed);
    // Opened with nothing recorded on this device (another's recording, or it ended as it opened): closed again.
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
    // The time moves on even when nobody speaks.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    widget.recorder.removeListener(_changed);
    _clock?.cancel();
    _closing?.cancel();
    super.dispose();
  }

  void _changed() {
    final r = widget.recorder;
    // Ended, from here or anywhere (the call left, someone else's Stop): closed a moment later.
    if (r.recording == null && !r.finishing) {
      _closing ??= Timer(const Duration(milliseconds: 900), _close);
    }
    if (mounted) setState(() {});
  }

  void _close() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        key: const ValueKey('recording-drawer'),
        color: _Studio.panel,
        child: SafeArea(
          child: widget.recorder.recording == null && !widget.recorder.finishing && widget.recorder.since == null
              ? const SizedBox.expand()
              : RecordingTimeline(recorder: widget.recorder, navigator: widget.navigator, fullScreen: true, onClose: _close),
        ),
      );
}

/// The red dot, breathing.
class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
        child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: _Studio.rec, shape: BoxShape.circle)),
      );
}

/// The open panel: a video editor's timeline of the recording.
class RecordingTimeline extends StatefulWidget {
  const RecordingTimeline({super.key, required this.recorder, required this.onClose, this.navigator, this.fullScreen = false, this.onPlain});

  /// A recording opened from a file: opens it in the app's video player instead ([showRecordingPlayback]'s `plain`).
  final VoidCallback? onPlain;

  /// The app's own navigator, for the page a saved recording opens.
  final NavigatorState? navigator;

  /// The recording being made, or one kept on this device opened again ([RecordingPlayback]).
  final RecordingDesk recorder;
  final VoidCallback onClose;

  /// Filling the window (the mixer's drawer): no rounded edge, no shadow.
  final bool fullScreen;

  @override
  State<RecordingTimeline> createState() => _RecordingTimelineState();
}

class _RecordingTimelineState extends State<RecordingTimeline> {
  /// How wide a second is, in points.
  double _perSecond = 24;

  /// How far back from the live end the view is, in seconds; zero follows the live end.
  double _back = 0;
  bool _stopping = false;

  /// The mixer rather than the timeline; kept between runs.
  bool? _mixer;
  static const _viewPref = 'rec_float_view';

  /// Everyone mixed, by step, as the faders stood at each: worked out as the steps come, and again from the start
  /// when a fader, a mute or a solo has moved.
  final List<double> _mixLevels = [];
  int _mixRevision = -1;

  /// Where the view starts, in seconds, for a recording played: it follows the playhead while it plays.
  double _viewStart = 0;
  bool _saving = false;

  /// [_mixLevels] brought up to the steps [rec] has now, each at most 1; started over where the mix has changed.
  List<double> _mixed(RecordingDesk rec) {
    final levels = rec.meter.levels;
    final n = _stepsOf(levels);
    if (rec.mix.revision != _mixRevision || n < _mixLevels.length) {
      _mixLevels.clear();
      _mixRevision = rec.mix.revision;
    }
    for (var i = _mixLevels.length; i < n; i++) {
      var sum = 0.0;
      for (final e in levels.entries) {
        // Played again, the mix is the faders as they stand now over the whole recording (what Save mix makes);
        // while recording, each step as the faders stood then.
        if (i < e.value.length) sum += e.value[i] * (rec is RecordingPlayback ? rec.mix.gain(e.key) : rec.mix.gainAt(e.key, i * RecordingMeter.step));
      }
      _mixLevels.add(math.min(1.0, sum));
    }
    return _mixLevels;
  }

  /// Stops the call's recording and says where it was saved, with a way to the recordings' page.
  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    // Taken now: by the time it is saved the drawer may be closing.
    final nav = widget.navigator ?? Navigator.maybeOf(context, rootNavigator: true);
    final live = widget.recorder as CallRecorder;
    final r = await live.stop();
    if (!mounted) return;
    if (r == null) {
      toast(context, 'The recording couldn\'t be saved');
    } else {
      toast(context, live.savedTo ?? 'Recording saved', action: GlacierToastAction(label: 'Open', onPress: () {
            if (nav != null && nav.mounted) pushOn(nav, nav.context, (_) => const RecordingsScreen());
          }));
    }
  }

  /// Saves the mix as it stands as a new recording beside the one opened.
  Future<void> _saveMix(RecordingPlayback p) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await p.save();
      if (mounted) toast(context, 'Saved as a new recording, mixed as it is now');
    } catch (e) {
      if (mounted) toast(context, 'The mix couldn\'t be saved ($e)');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rec = widget.recorder;
    final live = rec is CallRecorder ? rec : null;
    final played = rec is RecordingPlayback ? rec : null;
    final small = pageText(t, t.fontSize('xs'), weight: 'semibold', color: _Studio.ink2);
    return Container(
      key: const ValueKey('recording-timeline'),
      decoration: widget.fullScreen
          ? const BoxDecoration(color: _Studio.panel)
          : BoxDecoration(
              color: _Studio.panel,
              borderRadius: BorderRadius.circular(t.radius('xl')),
              border: Border.all(color: _Studio.edge),
              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 28, offset: Offset(0, 10))],
            ),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: Listenable.merge([rec, rec.meter, rec.mix]),
        builder: (context, _) {
          final since = live?.since;
          final elapsed = played != null ? Duration(microseconds: (played.at * 1e6).round()) : (since == null ? Duration.zero : DateTime.now().difference(since));
          final tracks = [
            (key: _mixKey, name: 'Everyone', live: true),
            ...rec.tracks,
          ];
          final levels = {...rec.meter.levels, _mixKey: _mixed(rec)};
          final app = AppState.maybeOf(context);
          final mixer = _mixer ??= app?.choice(_viewPref, 'timeline') == 'mixer';
          final space = played != null ? played.recording.space : (Voice.instance.session?.channel.name ?? '');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // The header: the time as a timecode, what is recorded, the zoom, Live, Stop and the way out of the mixer.
            Container(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(2), t.space(2)),
              color: _Studio.bar,
              child: LayoutBuilder(builder: (context, head) {
                // On a phone the header keeps what it must: the time, the zoom, Stop and the way back.
                final narrow = head.maxWidth < t.lenOf('34rem');
                return Row(children: [
                if (played != null)
                  _ToolButton(
                    key: const ValueKey('recording-play'),
                    icon: played.playing ? Lucide.pause : Lucide.play,
                    label: played.playing ? 'Pause' : 'Play',
                    onPressed: () => unawaited(played.toggle()),
                  )
                else ...[
                  const _RecDot(),
                  SizedBox(width: t.space(2)),
                ],
                if (!narrow && played == null) ...[
                  Text('REC', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: _Studio.rec, tracking: 1)),
                  SizedBox(width: t.space(3)),
                ],
                Text(narrow ? _short(elapsed) : _timecode(elapsed), key: const ValueKey('recording-timecode'), style: pageText(t, narrow ? t.fontSize('sm') : t.fontSize('md'), weight: 'semibold', color: _Studio.ink, mono: true)),
                SizedBox(width: t.space(narrow ? 2 : 3)),
                Expanded(
                  child: Text(
                    [if (space.isNotEmpty) '# $space', '${tracks.length - 1} ${tracks.length == 2 ? 'track' : 'tracks'}'].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: pageText(t, t.fontSize('sm'), color: _Studio.ink2),
                  ),
                ),
                if (live != null)
                  _ToolButton(
                    key: const ValueKey('recording-mark'),
                    icon: Lucide.flag,
                    label: 'Mark this moment',
                    onPressed: () {
                      final at = live.mark();
                      if (at != null) toast(context, 'Marked ${_rulerTime(at.floor())}');
                    },
                  ),
                if (!mixer) ...[
                  _ToolButton(icon: Lucide.zoomOut, label: 'Zoom out', onPressed: () => setState(() => _perSecond = math.max(4, _perSecond / 1.5))),
                  _ToolButton(icon: Lucide.zoomIn, label: 'Zoom in', onPressed: () => setState(() => _perSecond = math.min(160, _perSecond * 1.5))),
                  if (_back > 0 && live != null) _ToolButton(icon: Lucide.chevronRight, label: 'Live', text: narrow ? null : 'Live', onPressed: () => setState(() => _back = 0)),
                ],
                // The panel's other face: the mixer's faders, or the timeline's lanes.
                _ToolButton(
                  key: const ValueKey('recording-view'),
                  icon: mixer ? LucideMore.audioLines : LucideMore.slidersHorizontal,
                  label: mixer ? 'Show the timeline' : 'Show the mixer',
                  text: narrow ? null : (mixer ? 'Timeline' : 'Mixer'),
                  onPressed: () => setState(() {
                    _mixer = !mixer;
                    app?.set(_viewPref, mixer ? 'timeline' : 'mixer');
                  }),
                ),
                if (played != null && widget.onPlain != null) _ToolButton(key: const ValueKey('recording-plain'), icon: Lucide.film, label: 'Open in the player', onPressed: widget.onPlain!),
                SizedBox(width: t.space(1)),
                if (played != null)
                  GlacierPressable(
                    key: const ValueKey('recording-save-mix'),
                    onPressed: _saving ? null : () => unawaited(_saveMix(played)),
                    semanticLabel: 'Save this mix as a new recording',
                    builder: (context, state) => Container(
                      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 2),
                      decoration: BoxDecoration(color: state.pressed ? const Color(0xFF5BC283) : _Studio.wave, borderRadius: BorderRadius.circular(999)),
                      child: Text(_saving ? 'Saving…' : (narrow ? 'Save' : 'Save mix'), style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: _Studio.panel)),
                    ),
                  )
                else
                GlacierPressable(
                  key: const ValueKey('recording-stop'),
                  onPressed: _stopping ? null : () => unawaited(_stop()),
                  semanticLabel: 'Stop recording',
                  builder: (context, state) => Container(
                    padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 2),
                    decoration: BoxDecoration(color: state.pressed ? const Color(0xFFB3261E) : _Studio.rec, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 9, height: 9, decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(2))),
                      SizedBox(width: t.space(2)),
                      Text(_stopping ? 'Saving…' : 'Stop', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF))),
                    ]),
                  ),
                ),
                _ToolButton(key: const ValueKey('recording-collapse'), icon: Lucide.chevronDown, label: 'Close the mixer', onPressed: widget.onClose),
              ]);
              }),
            ),
            Container(height: 1, color: _Studio.edge),
            if (mixer)
              Expanded(child: MixerView(key: const ValueKey('recording-mixer'), recorder: rec, tracks: tracks))
            else
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final headerW = math.min(t.lenOf('12.5rem'), box.maxWidth * 0.42);
                final rulerH = t.lenOf('1.6rem');
                final rows = tracks.length;
                final laneH = math.max(t.lenOf('2.5rem'), math.min(t.lenOf('3.75rem'), (box.maxHeight - rulerH) / rows));
                return SingleChildScrollView(
                  child: SizedBox(
                    height: rulerH + laneH * rows,
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // The tracks' headers.
                      SizedBox(
                        width: headerW,
                        child: Column(children: [
                          Container(
                            height: rulerH,
                            alignment: AlignmentDirectional.centerStart,
                            padding: EdgeInsets.symmetric(horizontal: t.space(3)),
                            color: _Studio.bar,
                            child: Tr('TRACKS', style: small),
                          ),
                          for (var i = 0; i < rows; i++)
                            _TrackHeader(
                              key: ValueKey('recording-track-${tracks[i].key}'),
                              label: i == 0 ? 'Mix' : 'A$i',
                              name: tracks[i].name,
                              live: tracks[i].live,
                              colour: _colourOf(t, tracks[i].key),
                              recorder: rec,
                              trackKey: tracks[i].key,
                              height: laneH,
                            ),
                        ]),
                      ),
                      Container(width: 1, color: _Studio.edge),
                      // The timeline: dragged sideways to look back, Live to follow the end again.
                      Expanded(
                        child: LayoutBuilder(builder: (context, lanes) {
                          final total = played?.seconds ?? _stepsOf(levels) / RecordingMeter.perSecond;
                          final shown = lanes.maxWidth / _perSecond;
                          final maxBack = math.max(0.0, total - shown);
                          final back = _back.clamp(0.0, maxBack);
                          var start = math.max(0.0, total - shown - back);
                          if (played != null) {
                            // Played: the view stays where it is put, and turns the page when the playhead reaches its end.
                            final head = played.at;
                            if (played.playing && (head < _viewStart || head > _viewStart + shown * 0.92)) _viewStart = math.max(0.0, head - shown * 0.1);
                            _viewStart = _viewStart.clamp(0.0, maxBack);
                            start = _viewStart;
                          }
                          return GestureDetector(
                            onHorizontalDragUpdate: (d) => setState(() {
                              if (played != null) {
                                _viewStart = (_viewStart - d.delta.dx / _perSecond).clamp(0.0, maxBack);
                              } else {
                                _back = (_back + d.delta.dx / _perSecond).clamp(0.0, maxBack);
                              }
                            }),
                            // Played: pressed anywhere, the playhead goes there.
                            onTapUp: played == null ? null : (d) => unawaited(played.seek(start + d.localPosition.dx / _perSecond)),
                            child: CustomPaint(
                              key: const ValueKey('recording-lanes'),
                              size: Size(lanes.maxWidth, rulerH + laneH * rows),
                              painter: _TimelinePainter(
                                tracks: [
                                  for (final tr in tracks)
                                    (levels: levels[tr.key] ?? const <double>[], colour: _colourOf(t, tr.key), name: tr.name, out: tr.key != _mixKey && rec.mix.gain(tr.key) == 0),
                                ],
                                markers: rec.markers,
                                start: start,
                                perSecond: _perSecond,
                                total: played?.at ?? total,
                                rulerH: rulerH,
                                laneH: laneH,
                                label: pageText(t, 10, weight: 'semibold', color: _Studio.ink2, mono: true),
                                clipLabel: pageText(t, 10, weight: 'semibold', color: _Studio.ink),
                              ),
                            ),
                          );
                        }),
                      ),
                    ]),
                  ),
                );
              }),
            ),
          ]);
        },
      ),
    );
  }
}

/// A track's header: its colour, its name, A1… (or Left), mute and solo in the mix, and its meter.
class _TrackHeader extends StatelessWidget {
  const _TrackHeader({super.key, required this.label, required this.name, required this.live, required this.colour, required this.recorder, required this.trackKey, required this.height});
  final String label;
  final String name;
  final bool live;
  final Color colour;
  final RecordingDesk recorder;
  final String trackKey;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rec = recorder;
    final mix = rec.mix;
    final isMix = trackKey == _mixKey;
    final out = !isMix && mix.gain(trackKey) == 0;
    final fader = isMix ? 1.0 : mix.fader(trackKey);
    return Container(
      height: height,
      decoration: const BoxDecoration(color: _Studio.header, border: Border(bottom: BorderSide(color: _Studio.edge))),
      child: Row(children: [
        Container(width: 4, color: out ? colour.withValues(alpha: 0.35) : colour),
        SizedBox(width: t.space(2)),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: live && !out ? _Studio.ink : _Studio.ink3)),
            const SizedBox(height: 3),
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: _Studio.bar, borderRadius: BorderRadius.circular(4), border: Border.all(color: _Studio.edge)),
                child: Text(live ? label : 'Left', style: pageText(t, 9, weight: 'bold', color: _Studio.ink2, mono: true)),
              ),
              if (!isMix) ...[
                const SizedBox(width: 4),
                _StripButton(key: ValueKey('recording-lane-mute-$trackKey'), letter: 'M', label: mix.muted(trackKey) ? 'Unmute $name in the mix' : 'Mute $name in the mix', on: mix.muted(trackKey), lit: _muteLit, size: 18, onPressed: () => rec.setMuted(trackKey, !mix.muted(trackKey))),
                const SizedBox(width: 3),
                _StripButton(key: ValueKey('recording-lane-solo-$trackKey'), letter: 'S', label: mix.soloed(trackKey) ? 'Stop soloing $name' : 'Solo $name in the mix', on: mix.soloed(trackKey), lit: _soloLit, size: 18, onPressed: () => rec.setSolo(trackKey, !mix.soloed(trackKey))),
                // A fader that has been moved says by how much.
                if (fader != 1) ...[
                  const SizedBox(width: 4),
                  Flexible(child: Text(_gainWords(fader), maxLines: 1, overflow: TextOverflow.clip, style: pageText(t, 9, weight: 'semibold', color: _Studio.ink2, mono: true))),
                ],
              ],
            ]),
          ]),
        ),
        // Its level now, after its fader: the average solid, the peaks light, the loudest held, a lamp when it clips.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 5),
          child: Opacity(
            opacity: out || !live ? 0.45 : 1,
            child: LevelMeter(
              key: ValueKey('recording-lane-meter-$trackKey'),
              listenable: Listenable.merge([rec.meter, rec.mix]),
              read: () => _trackNow(rec, trackKey, live: live),
              clipped: !isMix && rec.meter.clipped.contains(trackKey),
              onClearClip: () => rec.meter.clearClip(trackKey),
              thickness: 7,
            ),
          ),
        ),
      ]),
    );
  }
}

/// A round button in the panel's header: an icon, with [text] before it where there is room for a word.
class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.label, required this.onPressed, this.text});
  final LucideIcon icon;
  final String label;
  final VoidCallback onPressed;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        height: t.lenOf('2rem'),
        constraints: BoxConstraints(minWidth: t.lenOf('2rem')),
        padding: EdgeInsets.symmetric(horizontal: text == null ? 0 : t.space(2)),
        decoration: BoxDecoration(color: state.hovered || state.pressed ? _Studio.header : null, borderRadius: BorderRadius.circular(999)),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (text != null) Text(text!, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: _Studio.ink)),
          AppIcon(icon, size: 16, color: _Studio.ink),
        ]),
      ),
    );
  }
}

/// The ruler, each track's clip with its waveform, and the playhead at the live end.
class _TimelinePainter extends CustomPainter {
  _TimelinePainter({required this.tracks, this.markers = const [], required this.start, required this.perSecond, required this.total, required this.rulerH, required this.laneH, required this.label, required this.clipLabel});

  final List<({List<double> levels, Color colour, String name, bool out})> tracks;

  /// The moments marked, in seconds.
  final List<double> markers;

  /// The second at the left edge.
  final double start;
  final double perSecond;

  /// How long it has been recording, in seconds (where the playhead is).
  final double total;
  final double rulerH;
  final double laneH;
  final TextStyle label;
  final TextStyle clipLabel;

  /// Where a moment of the recording is across the painting, in points from its left edge.
  double _x(double second) => (second - start) * perSecond;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    // The lanes' ground, a line under each.
    canvas.drawRect(Rect.fromLTWH(0, rulerH, size.width, size.height - rulerH), Paint()..color = _Studio.lane);
    final rule = Paint()..color = _Studio.edge;
    for (var i = 0; i < tracks.length; i++) {
      final bottom = rulerH + laneH * (i + 1);
      canvas.drawRect(Rect.fromLTWH(0, bottom - 1, size.width, 1), rule);
    }
    // The ruler: a tick each second, longer ones with the time where they are far enough apart to be read.
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, rulerH), Paint()..color = _Studio.bar);
    final every = _labelEvery(perSecond);
    final tick = Paint()..color = _Studio.tick;
    final small = perSecond >= 6 ? 1 : (perSecond >= 2 ? 5 : 10);
    for (var s = (start ~/ small) * small; s <= start + size.width / perSecond + 1; s += small) {
      final x = _x(s.toDouble());
      if (x < -1 || x > size.width + 1) continue;
      final big = s % every == 0;
      canvas.drawRect(Rect.fromLTWH(x, rulerH - (big ? 9 : 4), 1, big ? 9 : 4), tick);
      if (big) {
        final tp = TextPainter(text: TextSpan(text: _rulerTime(s), style: label), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(x + 3, (rulerH - 9 - tp.height) / 2 + 1));
      }
    }
    canvas.drawRect(Rect.fromLTWH(0, rulerH - 1, size.width, 1), rule);
    // Each track's clip: from where its sound starts to the live end, its waveform inside.
    for (var i = 0; i < tracks.length; i++) {
      final tr = tracks[i];
      if (tr.levels.isEmpty) continue;
      final top = rulerH + laneH * i + 3;
      final h = laneH - 7;
      final left = math.max(_x(0), -4.0);
      final right = math.min(_x(tr.levels.length / RecordingMeter.perSecond), size.width + 4);
      if (right <= left) continue;
      final clip = RRect.fromRectAndRadius(Rect.fromLTRB(left, top, right, top + h), const Radius.circular(4));
      // A voice that is out of the mix (muted, or another soloed) is still recorded: its clip is drawn faint.
      final dim = tr.out ? 0.4 : 1.0;
      canvas.drawRRect(clip, Paint()..color = tr.colour.withValues(alpha: 0.22 * dim));
      canvas.drawRRect(clip, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = tr.colour.withValues(alpha: 0.6 * dim));
      // The clip's name along its top, as an editor names a clip.
      final nameH = 13.0;
      canvas.save();
      canvas.clipRRect(clip);
      canvas.drawRect(Rect.fromLTWH(left, top, right - left, nameH), Paint()..color = tr.colour.withValues(alpha: 0.45 * dim));
      final tp = TextPainter(text: TextSpan(text: tr.name, style: clipLabel), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')..layout(maxWidth: math.max(0, right - left - 8));
      tp.paint(canvas, Offset(math.max(left, 0) + 4, top + (nameH - tp.height) / 2));
      // The waveform: each point of width the loudest step in it, mirrored about the middle of the space under the
      // name.
      final mid = top + nameH + (h - nameH) / 2;
      final half = (h - nameH) / 2 - 2;
      final wave = Paint()..color = tr.colour.withValues(alpha: dim);
      final stepW = perSecond / RecordingMeter.perSecond;
      final from = math.max(0, ((start) * RecordingMeter.perSecond).floor());
      final to = math.min(tr.levels.length, ((start + size.width / perSecond) * RecordingMeter.perSecond).ceil() + 1);
      if (stepW >= 2) {
        for (var k = from; k < to; k++) {
          final x = _x(k / RecordingMeter.perSecond);
          final a = math.max(0.75, _shape(tr.levels[k]) * half);
          canvas.drawRect(Rect.fromLTRB(x + 0.5, mid - a, x + stepW - 0.5, mid + a), wave);
        }
      } else {
        // Zoomed out: a column a point wide, the loudest of the steps under it.
        for (var px = math.max(0, left.floor()); px < math.min(size.width, right).ceil(); px++) {
          final a0 = ((start + px / perSecond) * RecordingMeter.perSecond).floor();
          final a1 = math.min(tr.levels.length, ((start + (px + 1) / perSecond) * RecordingMeter.perSecond).ceil());
          var peak = 0.0;
          for (var k = math.max(0, a0); k < a1; k++) {
            if (tr.levels[k] > peak) peak = tr.levels[k];
          }
          final a = math.max(0.75, _shape(peak) * half);
          canvas.drawRect(Rect.fromLTRB(px.toDouble(), mid - a, px + 1.0, mid + a), wave);
        }
      }
      canvas.restore();
    }
    // The moments marked: a flag in the ruler and a line down the lanes.
    const flag = Color(0xFFFFD60A);
    for (final m in markers) {
      final x = _x(m);
      if (x < -8 || x > size.width + 8) continue;
      canvas.drawRect(Rect.fromLTWH(x - 0.5, 0, 1, size.height), Paint()..color = flag.withValues(alpha: 0.55));
      canvas.drawPath(
        Path()
          ..moveTo(x, 2)
          ..lineTo(x + 8, 5.5)
          ..lineTo(x, 9)
          ..close(),
        Paint()..color = flag,
      );
    }
    // The playhead at the live end, its head in the ruler.
    final px = _x(total);
    if (px >= -2 && px <= size.width + 2) {
      final head = Paint()..color = _Studio.rec;
      canvas.drawRect(Rect.fromLTWH(px - 0.75, 0, 1.5, size.height), head);
      final path = Path()
        ..moveTo(px - 6, 0)
        ..lineTo(px + 6, 0)
        ..lineTo(px + 6, rulerH - 10)
        ..lineTo(px, rulerH - 4)
        ..lineTo(px - 6, rulerH - 10)
        ..close();
      canvas.drawPath(path, head);
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => true;
}

/// The studio's colours: dark whatever the app's look, as an editor's timeline is.
abstract final class _Studio {
  static const panel = Color(0xFF17171A);
  static const bar = Color(0xFF1F1F23);
  static const header = Color(0xFF242428);
  static const lane = Color(0xFF1B1B1E);
  static const edge = Color(0xFF2E2E33);
  static const tick = Color(0xFF6B6B73);
  static const ink = Color(0xFFF2F2F5);
  static const ink2 = Color(0xFFA9A9B2);
  static const ink3 = Color(0xFF6E6E78);
  static const rec = Color(0xFFFF3B30);
  static const wave = Color(0xFF7EE0A1);
}

/// A track's colour: the mix in the app's accent green, each voice in the colour the app gives that person.
Color _colourOf(Tokens t, String key) {
  if (key == _mixKey) return _Studio.wave;
  if (key == 'me') return const Color(0xFFB79CFF);
  return PluginHues.of(t.child(attrs: {'theme': 'dark'}), hueFor(key)).accent;
}

/// How many steps the longest track has.
int _stepsOf(Map<String, List<double>> levels) => levels.values.fold<int>(0, (n, l) => l.length > n ? l.length : n);

/// A level as it is drawn: speech sits low on a straight scale, so it is lifted (a square root) as editors draw it.
double _shape(double level) => math.sqrt(level.clamp(0.0, 1.0));

/// Seconds between the ruler's numbered ticks, so the numbers stand at least 56 points apart.
int _labelEvery(double perSecond) {
  for (final s in const [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]) {
    if (s * perSecond >= 56) return s;
  }
  return 1200;
}

String _rulerTime(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

/// The time as an editor writes it: hours, minutes, seconds and tenths.
String _timecode(Duration d, {bool tenths = true}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final base = '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return tenths ? '$base.${(d.inMilliseconds % 1000) ~/ 100}' : base;
}

/// The time as the pill shows it: minutes and seconds, hours only once there are any.
String _short(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
}

