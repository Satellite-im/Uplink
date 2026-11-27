/// A file of a Files space opened: brought down (with its progress) and shown as its kind is (Matt, 2026-11-17: "add
/// full functionality for filesharing in a space"). A picture to zoom, sound to play, words to read (the first 256 KB,
/// in the page's monospace for code); a video plays in the app's own player (lib/ui/video_screen.dart). Anything else,
/// a PDF among them, shows its mark, name and size with Open, Save and Share: the app the device reads it with does
/// the rest.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../platform_info.dart';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../backgrounds.dart' show strongFill;
import '../../files/file_platform.dart';
import '../../files/files_store.dart';
import '../../kit/settings_kit.dart' show SettingsCallout;
import '../../kit/settings_type.dart';
import '../../voice/recorder.dart' show Recording;
import '../../voice/recording_playback.dart' show RecordingPlayback, namedAsRecording, recordingIn;
import '../../voice/voice.dart';
import '../circles/circle_face.dart' show TitleBarMark;
import '../common.dart';
import '../skeleton.dart';
import '../dialup/bevel.dart';
import '../dialup/retro_button.dart';
import '../recording_float.dart' show showRecordingPlayback;
import '../video_engine.dart';
import '../video_screen.dart';
import 'file_badge.dart';
import 'files_screen.dart' show fileAction, fileWho, showFileMenu;
import '../../kit/picture_decode.dart';

/// Whether this device plays video in the app's own player (lib/ui/video_engine.dart): every one, Windows too since
/// libmpv came in (Matt, 2026-11-18: "add support for playing mkv video files and mp4's within the app").
bool get playsVideo => true;

/// Whether a page in a browser brings [f] into the tab to show it when it is opened (FilesStore.browser holds what
/// comes down in the tab, and Safari holds that in memory): a picture of 8 MB at most (the app's own bound for one read
/// whole), words of 16 MB at most (the first 256 KB shown), a sound or a video of 512 MB at most. Anything else is
/// downloaded only when the person asks (the review of web-files, F2).
bool browserShowsHere(SpaceFile f) => switch (f.kind) {
      FileKind.image => f.size <= 8 << 20,
      FileKind.text || FileKind.code => f.size <= 16 << 20,
      FileKind.audio || FileKind.video => f.size <= 512 << 20,
      _ => false,
    };

/// Opens [f]: a video straight into the player, played as it comes down (lib/files/file_stream.dart; Matt, 2026-11-18:
/// "do we need to download the whole file to play? would it be possible to setup streaming and buffering of the
/// file?"), or from the disk where it is here already; anything else in its preview.
///
/// A call's recording opens in the mixer, each voice a track with its meter, fader, mute and solo (Matt, 2026-11-23:
/// "i want to see the mixer when viewing sounds recordings but it just loads the media player view": to this it was a
/// video as any MP4 is). It is known by its tracks (recordingIn), so by the file itself: one here already is looked
/// into and opened as what it is; one not here yet is brought down first only when it is named as recordings are
/// ([namedAsRecording]: its preview, with the progress, and then the mixer over it), since the mixer needs the whole
/// file and its track names are at its end. Any other video, and any on a device whose mixer opens no file, plays as
/// before. The mixer has a button back to the player.
void openSpaceFile(BuildContext context, VoiceChannel c, SpaceFile f, {FilesStore? store, bool chat = false}) {
  final s = store ?? FilesStore.instance;
  // In a browser a video comes down first, its progress in the preview, then plays from the tab (FilesStore.browser).
  if (f.kind == FileKind.video && playsVideo && !s.browser) {
    final have = s.cached(f);
    void play() => Navigator.of(context).push(videoRoute(have != null ? VideoScreen(path: have, title: f.name, poster: f.thumb) : VideoScreen.stream(stream: s.stream(c, f), title: f.name, poster: f.thumb)));
    if (RecordingPlayback.opensHere && f.name.toLowerCase().endsWith('.mp4')) {
      if (have != null) {
        unawaited(recordingIn(have, id: 'file-${f.id}', space: c.name).then((r) {
          if (!context.mounted) return;
          if (r == null) return play();
          openRecordingFile(context, r, have, f);
        }));
        return;
      }
      if (namedAsRecording(f.name)) {
        push<void>(context, (_) => FilePreviewScreen(channel: c, file: f, store: store, chat: chat, mixer: true));
        return;
      }
    }
    play();
    return;
  }
  push<void>(context, (_) => FilePreviewScreen(channel: c, file: f, store: store, chat: chat));
}

/// Opens [r], the call's recording in [f] (on this device at [path]), in the mixer, with the way from there to the
/// app's video player. One of this device's own recordings keeps what was decoded of it, as from its list; any other
/// is only passing through (RecordingPlayback.passing).
void openRecordingFile(BuildContext context, Recording r, String path, SpaceFile f) {
  unawaited(showRecordingPlayback(
    context,
    r,
    passing: r.path == path,
    plain: () {
      if (context.mounted) Navigator.of(context).push(videoRoute(VideoScreen(path: path, title: f.name, poster: f.thumb)));
    },
  ));
}

/// The preview page of one file of a space: its name at the head, and under it the file as its kind is shown.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({super.key, required this.channel, required this.file, this.store, this.chat = false, this.mixer = false});

  /// A video named as a call's recording is, not on this device yet ([openSpaceFile]): once it has come down and is
  /// one, the mixer opens over this page by itself, and this page has Open in the mixer beside Play.
  final bool mixer;
  final VoiceChannel channel;
  final SpaceFile file;
  final FilesStore? store;

  /// A file sent in a space's chat (lib/ui/space_chat_files.dart): in no list, so never "removed from the space", and
  /// nothing to rename, move or delete; Save and Share in the … menu's place.
  final bool chat;

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  FilesStore get _store => widget.store ?? FilesStore.instance;
  String? _path;
  FilesError? _error;

  /// Sound played as it comes down: _AudioPlayer holds the stream itself.
  bool _streamed = false;

  /// In a browser: what came down, read back from the tab for a picture or words (a page reads no path); and a file
  /// too big to bring into the tab just to show it ([browserShowsHere]).
  Uint8List? _bytes;
  bool _tooBig = false;

  /// The call's recording this file turned out to be ([FilePreviewScreen.mixer]).
  Recording? _recording;

  @override
  void initState() {
    super.initState();
    _bring();
  }

  /// Gets the file to show: the copy on this device where there is one, sound as a stream, and anything else brought
  /// down whole. Called again by Try again after a failure.
  void _bring() {
    _error = null;
    final had = _store.cached(widget.file);
    if (had != null && !_store.browser) {
      _path = had;
      if (widget.mixer) unawaited(_look(had));
      return;
    }
    // In a browser, what would be held whole in the tab only to be looked at is not brought down by opening it
    // (browserShowsHere): Download is there, for the person to choose (Safari keeps what a tab holds in memory).
    if (_store.browser && had == null && !browserShowsHere(widget.file)) {
      _tooBig = true;
      return;
    }
    // Sound plays as it comes down, as a video does, rather than after the whole of it (Matt, 2026-11-18). Not in a
    // browser, which has no server to play from.
    if (widget.file.kind == FileKind.audio && playsVideo && !_store.browser) {
      _streamed = true;
      return;
    }
    unawaited(_store.fetch(widget.channel, widget.file).then((p) async {
      // A browser's picture or words, read back from where the tab holds them (the first 256 KB of words).
      final kind = widget.file.kind;
      final bytes = !_store.browser
          ? null
          : kind == FileKind.text || kind == FileKind.code
              ? await HeldFiles.bytes(p, most: _WordsState.most)
              : kind == FileKind.image
                  ? await HeldFiles.bytes(p)
                  : null;
      if (mounted) {
        setState(() {
          _path = p;
          _bytes = bytes;
        });
        if (widget.mixer) unawaited(_look(p));
      }
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e is FilesError ? e : FilesError(0, '$e'));
    }));
  }

  /// The file is here, at [p], and was opened as a call's recording might be ([FilePreviewScreen.mixer]): where it is
  /// one, the mixer opens over this page, which then has Open in the mixer beside Play.
  Future<void> _look(String p) async {
    if (widget.file.kind != FileKind.video) return;
    final r = await recordingIn(p, id: 'file-${widget.file.id}', space: widget.channel.name);
    if (r == null || !mounted) return;
    setState(() => _recording = r);
    openRecordingFile(context, r, p, widget.file);
  }

  /// The file as it is now in the list: renamed or moved meanwhile, it keeps up.
  SpaceFile get _file => widget.chat ? widget.file : _store.of(widget.channel).files[widget.file.id] ?? widget.file;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final f = _file;
        final gone = !widget.chat && _store.of(widget.channel).ready && !_store.of(widget.channel).files.containsKey(f.id);
        final line = '${fileSize(f.size)} · ${fileWho(f)} · ${listWhen(f.when)}';
        final wide = MediaQuery.sizeOf(context).width >= 640;
        return GhostPage(
          title: f.name,
          subtitle: line,
          titleLeading: TitleBarMark(icon: fileIcon(f.kind), child: FileBadge(kind: f.kind, size: 18)),
          titleWidget: Row(children: [
            FileBadge(kind: f.kind, size: 32),
            SizedBox(width: t.space(2) + 2),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold')),
                Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ]),
            ),
          ]),
          // Save and Share once each: in the body's buttons for a file this page can't show (a PDF), in the … menu
          // otherwise; beside the … only on a wide window, for a file shown here. On a phone the title keeps the room.
          actions: [
            if ((wide || widget.chat) && shownHere(f) && FilePlatform.canSave) IconTap(icon: LucideMore.download, label: FilePlatform.canShare ? 'Save' : 'Download', onPressed: () => fileAction(context, widget.channel, f, _store, (p) => FilePlatform.save(p, f.name, f.mime), doneWords: true)),
            if ((wide || widget.chat) && shownHere(f) && FilePlatform.canShare) IconTap(icon: Lucide.share2, label: 'Share', onPressed: () => fileAction(context, widget.channel, f, _store, (p) => FilePlatform.share(p, f.name, f.mime))),
            if (!widget.chat) IconTap(icon: Lucide.ellipsisVertical, label: 'More', onPressed: () => showFileMenu(context, widget.channel, f, store: _store)),
          ],
          body: gone ? _note(t, Lucide.trash2, 'This file was removed from the space.') : _body(context, t, f),
        );
      },
    );
  }

  /// A notice in the middle of the page: an icon, a line of words, and a button under them where one is given.
  Widget _note(Tokens t, LucideIcon icon, String words, {Widget? action}) => Center(
        child: Padding(
          padding: EdgeInsets.all(t.space(6)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(icon, size: 32, color: t.color('app-ink-3')),
            SizedBox(height: t.space(3)),
            Text(words, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
            if (action != null) ...[SizedBox(height: t.space(3)), action],
          ]),
        ),
      );

  Widget _body(BuildContext context, Tokens t, SpaceFile f) {
    if (_error != null) {
      return _note(t, _error!.offline ? Lucide.wifiOff : Lucide.circleAlert, _error!.message, action: _Pill(label: 'Try again', icon: Lucide.refreshCw, onPressed: () => setState(_bring)));
    }
    if (_streamed && f.kind == FileKind.audio) return _AudioPlayer(key: ValueKey('stream ${f.id}'), file: f, stream: () => _store.stream(widget.channel, widget.file));
    if (_tooBig) return _other(t, f, '', note: 'Too big to show in a browser (${fileSize(f.size)}). Download it, or open it in Uplink on a phone or a computer.');
    final path = _path;
    if (path == null) {
      final coming = _store.downloading(f);
      return Center(
        child: Padding(
          padding: EdgeInsets.all(t.space(6)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FileFace(file: f, size: 72),
            SizedBox(height: t.space(4)),
            SizedBox(width: 220, child: GlacierProgressBar(value: (coming?.progress ?? 0) * 100, indeterminate: coming == null, ariaLabel: 'Getting it')),
            SizedBox(height: t.space(2)),
            Text(coming == null ? 'Getting it…' : '${fileSize(coming.done)} of ${fileSize(f.size)}', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
      );
    }
    switch (f.kind) {
      // A HEIC too where this device reads one (GMFB-60); one that doesn't open after all is the file's page, below.
      case FileKind.image when FileKind.drawsAsPicture(f.name, f.mime):
        return ColoredBox(
          color: isBevelChrome(t) ? DialupColors.of(t).paper : t.color('glacier-bg'),
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 8,
            child: Center(
              // A picture of a few megabytes is read at once, so it shows on the first frame; a bigger one is streamed.
              child: _bytes != null
                  ? Image.memory(_bytes!, fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: _decodeWidth(context), errorBuilder: (_, _, _) => _other(t, f, path))
                  : f.size <= 8 << 20
              // Decoded no wider than the screen's pixels (twice, for zooming in): a picture that claims to be tens of
              // thousands across is not unpacked whole.
                  ? Image.memory(fileBytes(path) ?? Uint8List(0), fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: _decodeWidth(context), errorBuilder: (_, _, _) => _other(t, f, path))
                  : Image.file(File(path), fit: BoxFit.contain, cacheWidth: _decodeWidth(context), errorBuilder: (_, _, _) => _other(t, f, path)),
            ),
          ),
        );
      case FileKind.audio:
        return _AudioPlayer(key: ValueKey(path), path: path, file: f, stream: null);
      case FileKind.text || FileKind.code:
        return _Words(path: path, code: f.kind == FileKind.code, bytes: _bytes, size: f.size);
      case FileKind.video when playsVideo:
        return _other(t, f, path, play: true);
      default:
        return _other(t, f, path, runs: FilePlatform.runsCode(f.name));
    }
  }

  /// How wide a picture is decoded, in pixels: twice the screen's width, so zooming in stays sharp, and never the
  /// whole of a huge picture.
  int _decodeWidth(BuildContext context) => (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 2).round().clamp(256, 8192);

  /// Whether this page shows [f] itself (a picture, sound, words); else it offers the ways to open it elsewhere.
  bool shownHere(SpaceFile f) => switch (f.kind) {
        FileKind.image => FileKind.drawsAsPicture(f.name, f.mime),
        FileKind.audio || FileKind.text || FileKind.code => true,
        _ => false,
      };

  /// Anything not shown here: its mark, name and size, and the ways to open it elsewhere.
  Widget _other(Tokens t, SpaceFile f, String path, {bool play = false, bool runs = false, String? note}) => Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(t.space(6)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FileFace(file: f, size: 96),
            SizedBox(height: t.space(4)),
            Text(f.name, textAlign: TextAlign.center, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
            SizedBox(height: t.space(1)),
            Text('${f.kind.label} · ${fileSize(f.size)}', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            SizedBox(height: t.space(5)),
            // A program or a script (FilePlatform.runsCode) is never opened from here: anyone in the space could have
            // added it. It says what it is, by its real ending, and can be shown in its folder or saved.
            if (note != null) ...[
              SettingsCallout(icon: AppIcon(Lucide.info, size: 18), child: Text(note)),
              SizedBox(height: t.space(4)),
            ],
            if (runs) ...[
              SettingsCallout(
                icon: AppIcon(Lucide.triangleAlert, size: 18),
                child: Text('This is a .${f.name.split('.').last.toLowerCase()} file: it runs a program when opened, so it isn\'t opened from here. Open it yourself only if you trust ${fileWho(f) == 'You' ? 'where it came from' : fileWho(f)}.'),
              ),
              SizedBox(height: t.space(4)),
            ],
            Wrap(spacing: t.space(2), runSpacing: t.space(2), alignment: WrapAlignment.center, children: [
              if (play && _recording != null) _Pill(label: 'Open in the mixer', icon: Lucide.slidersHorizontal, strong: true, onPressed: () => openRecordingFile(context, _recording!, path, f)),
              if (play)
                _Pill(label: 'Play', icon: Lucide.play, strong: _recording == null, onPressed: () => Navigator.of(context).push(videoRoute(VideoScreen(path: path, title: f.name, poster: f.thumb))))
              // Never in a browser: a file opened in a tab of the app's address could be a page whose script reads
              // what the app keeps there (docs/OPEN_NETWORK.md, part 6). It is downloaded instead.
              else if (!runs && FilePlatform.canOpen)
                _Pill(label: 'Open', icon: Lucide.externalLink, strong: true, onPressed: () => FilePlatform.open(path, f.name)),
              if (FilePlatform.canSave) _Pill(label: FilePlatform.canShare ? 'Save' : 'Download', icon: LucideMore.download, onPressed: () => fileAction(context, widget.channel, f, _store, (p) => FilePlatform.save(p, f.name, f.mime), doneWords: true)),
              if (FilePlatform.canShare) _Pill(label: 'Share', icon: Lucide.share2, onPressed: () => FilePlatform.share(path, f.name, f.mime)),
              if (PlatformInfo.isMacOS) _Pill(label: 'Show in Finder', icon: Lucide.folderOpen, onPressed: () => FilePlatform.reveal(path)),
            ]),
          ]),
        ),
      );
}

/// A button of the preview (Open, Save, Share, Try again): an icon and a word; the [strong] one is the main action.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.icon, required this.onPressed, this.strong = false});
  final String label;
  final LucideIcon icon;
  final VoidCallback onPressed;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return RetroButton(onPressed: onPressed, icon: icon, label: label, primary: strong);
    // The strong one in the screen's one strong fill, as Upload's (teal in Mist, not a near-black beside the accent).
    final (strongColour, onStrong) = strongFill(t);
    final fill = strong ? strongColour : t.color('app-paper-2');
    final ink = strong ? onStrong : t.color('app-ink');
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
        decoration: BoxDecoration(color: fill.withValues(alpha: state.pressed ? 0.85 : 1), borderRadius: BorderRadius.circular(t.radius('full'))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(icon, size: 16, color: ink, wash: false),
          SizedBox(width: t.space(2)),
          Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
        ]),
      ),
    );
  }
}

/// A text or code file's words: the first 256 KB, said where there is more.
class _Words extends StatefulWidget {
  const _Words({required this.path, required this.code, this.bytes, this.size});
  final String path;
  final bool code;

  /// The file's bytes where they are held already (a browser's: its first 256 KB), in place of reading [path]; and
  /// how long the whole file is.
  final Uint8List? bytes;
  final int? size;

  @override
  State<_Words> createState() => _WordsState();
}

class _WordsState extends State<_Words> {
  static const most = 256 * 1024;
  String? _text;
  bool _more = false;

  @override
  void initState() {
    super.initState();
    final held = widget.bytes;
    if (held != null) {
      _text = utf8.decode(held.length > most ? Uint8List.sublistView(held, 0, most) : held, allowMalformed: true);
      _more = (widget.size ?? held.length) > most;
      return;
    }
    unawaited(() async {
      final f = File(widget.path);
      final length = await f.length();
      final raf = await f.open();
      try {
        final bytes = await raf.read(most);
        final text = utf8.decode(bytes, allowMalformed: true);
        if (mounted) {
          setState(() {
            _text = text;
            _more = length > most;
          });
        }
      } finally {
        await raf.close();
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = _text;
    if (text == null) return const SkeletonLines(label: 'Opening the file');
    final bevel = isBevelChrome(t);
    final words = Text(text, style: pageText(t, t.fontSize('sm'), mono: widget.code, height: 1.5, color: t.color('app-ink')));
    return ColoredBox(
      color: bevel ? DialupColors.of(t).paper : t.color('glacier-bg'),
      child: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), MediaQuery.paddingOf(context).bottom + t.space(6)),
        children: [
          // Code keeps its lines: it scrolls across rather than wrapping.
          if (widget.code) SingleChildScrollView(scrollDirection: Axis.horizontal, child: words) else words,
          if (_more)
            Padding(
              padding: EdgeInsets.only(top: t.space(4)),
              child: Text('Only the start is shown. Open it to read the rest.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ),
        ],
      ),
    );
  }
}

/// Sound: play and pause, where it has got to, and a bar to move along it. Played by the same engine as a video
/// (lib/ui/video_engine.dart), so a computer's is libmpv's and reads what the video player reads.
class _AudioPlayer extends StatefulWidget {
  const _AudioPlayer({super.key, this.path, required this.file, required this.stream});
  final String? path;
  final SpaceFile file;

  /// Where it isn't here yet: the stream to play it from as it comes, made when the player is.
  final StreamedMedia Function()? stream;

  @override
  State<_AudioPlayer> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends State<_AudioPlayer> {
  VideoEngine? _player;
  StreamedMedia? _stream;
  String? _problem;

  @override
  void initState() {
    super.initState();
    if (!playsVideo) {
      _problem = 'Open it to play it.';
      return;
    }
    final p = _player = VideoEngine.make();
    p.addListener(_tick);
    unawaited(_open(p));
  }

  /// Opened from the disk or from the stream, with the same patience as a video's: a sound that isn't ready by then
  /// says so, never a spinner for ever.
  Future<void> _open(VideoEngine p) async {
    try {
      var path = widget.path;
      if (path == null) {
        final s = _stream = widget.stream!();
        s.changes.addListener(_tick);
        path = await s.open().timeout(VideoScreen.openPatience);
      }
      if (!mounted) return;
      await p.open(path).timeout(VideoScreen.openPatience);
      if (mounted && !p.value.ready && _problem == null) setState(() => _problem = 'This sound can\'t be played here. Open it to play it.');
    } catch (e) {
      if (mounted && _problem == null) setState(() => _problem = _stream?.failure ?? 'This sound can\'t be played here. Open it to play it.');
    }
  }

  /// The player or the stream changed: draws again, with what went wrong where either has failed.
  void _tick() {
    if (!mounted) return;
    if (_player?.value.error != null) _problem = 'This sound can\'t be played here. Open it to play it.';
    final failure = _stream?.failure;
    if (failure != null && _player?.value.ready != true) _problem = failure;
    setState(() {});
  }

  @override
  void dispose() {
    final p = _player;
    final s = _stream;
    s?.changes.removeListener(_tick);
    if (p != null) {
      p.removeListener(_tick);
      unawaited(p.release().catchError((_) {}).whenComplete(() {
        p.dispose();
        s?.close();
      }));
    } else {
      s?.close();
    }
    super.dispose();
  }

  static String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = _player;
    final v = p?.value;
    final length = v?.duration ?? Duration.zero;
    final at = v?.position ?? Duration.zero;
    final playing = v?.playing ?? false;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(t.space(6)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FileBadge(kind: FileKind.audio, size: 96),
            SizedBox(height: t.space(4)),
            Text(widget.file.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
            SizedBox(height: t.space(5)),
            if (_problem != null)
              Text(_problem!, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))
            else ...[
              LayoutBuilder(builder: (context, box) {
                final share = length.inMilliseconds == 0 ? 0.0 : at.inMilliseconds / length.inMilliseconds;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => p?.seek(length * (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                  onHorizontalDragUpdate: (d) => p?.seek(length * (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: t.space(2)),
                    child: GlacierProgressBar(value: share.clamp(0.0, 1.0) * 100, ariaLabel: 'Where it has got to'),
                  ),
                );
              }),
              Row(children: [
                Text(_clock(at), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                const Spacer(),
                Text(_clock(length), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ]),
              SizedBox(height: t.space(3)),
              IconTap(
                icon: playing ? Lucide.pause : Lucide.play,
                label: playing ? 'Pause' : 'Play',
                filled: true,
                size: 22,
                onPressed: v?.ready != true
                    ? null
                    : () {
                        if (playing) {
                          p!.pause();
                        } else {
                          if (at >= length) p!.seek(Duration.zero);
                          p!.play();
                        }
                      },
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
