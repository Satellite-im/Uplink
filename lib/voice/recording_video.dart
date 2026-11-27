/// A recording's picture (GMFB-42: "Extend the Record call plugin so a recording can also capture the webcams and
/// screenshares in the call, not just the audio tracks"; Matt, 2026-11-23: "One composed video").
///
/// The recording stays the MP4 it was, a track for everyone and a track for each voice, with one track of video put
/// after them: every camera in the call in a grid, or, while someone shares a screen, the screen large and the
/// cameras small beside it. 1280 by 720, fifteen frames a second, about 1.6 Mb/s: with the sound of four people, close
/// to half a gigabyte for half an hour.
///
/// **Who is drawn.** Only someone whose own device said yes to voice and video for this recording
/// ([VoiceMember.picturedIn]). A yes to the voice alone (an older build, which never asked about a picture) puts
/// their name and initial on their tile and never their camera or screen. Someone who said no, or has not answered,
/// has no tile at all.
///
/// **Where the work is.** What is drawn where is worked out here ([faces], [layout]), so it can be tested; the tiles'
/// backs and names are painted here too ([plate]), so the native half draws no words. The native half
/// (macos/Runner/CallVideo.swift) is handed the plate and, for each picture, a track and a place: it lays the newest
/// frame of each over the plate fifteen times a second and encodes what it gets.
///
/// **Computers: a Mac and a Windows PC.** [supported] is those two. A phone records the voices as before, and so does
/// Linux, which is not offered video. Each has a native half of its own that is handed the same plate and tiles and
/// makes a file of video beside the voices' files:
///
/// - A Mac: macos/Runner/CallVideo.swift (Core Image over the plate, AVAssetWriter's H.264), and CallRecorder's mux
///   copies the track into the MP4.
/// - Windows (Matt, 2026-11-26: "Build Windows too"): windows/runner/call_video.cpp (a renderer on each track through
///   flutter_webrtc's `MediaTrackForId`, frames scaled over the plate there, Media Foundation's H.264 writer fed NV12),
///   and lib/voice/mp4_merge.dart puts the track in after the voices. Where that Windows has no H.264 encoder the
///   picture's file can't be begun, and the recording is the voices, as it is said to be when it starts.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../platform_info.dart';
import 'voice.dart';

/// Someone the recording's picture has a tile for: this device's person ('me') or a member who said yes.
@immutable
class VideoFace {
  const VideoFace({required this.key, required this.name, this.track, this.mark = '', this.screen = false});

  /// 'me', or the member's id.
  final String key;
  final String name;

  /// The track their picture is on, as the native half knows it; null where there is nothing of theirs to draw (no
  /// camera on, or no yes to video): their tile is their name.
  final String? track;

  /// Which connection [track] came on: a connection made again brings a track with the same id.
  final String mark;

  /// The picture is their screen: drawn whole and large.
  final bool screen;
}

/// One tile of the recording's picture.
@immutable
class VideoTile {
  const VideoTile({required this.key, required this.name, required this.rect, required this.picture, this.track, this.mark = '', this.contain = false, this.stage = false});
  final String key;
  final String name;

  /// The whole tile, in the picture's pixels from its top left.
  final ui.Rect rect;

  /// Where the camera or screen is drawn in it: the tile less the strip its name is written on.
  final ui.Rect picture;
  final String? track;
  final String mark;

  /// Drawn whole, with bars where its shape is not the tile's (a screen); else filling the tile, its edges cut (a
  /// camera).
  final bool contain;

  /// The large one: the shared screen.
  final bool stage;
}

/// Where everything is in the recording's picture now.
@immutable
class VideoLayout {
  const VideoLayout(this.width, this.height, this.tiles);
  final int width, height;
  final List<VideoTile> tiles;

  /// Says everything the picture is made from: the same words, the same picture.
  String get signature => [
        '$width×$height',
        for (final t in tiles) '${t.key}|${t.name}|${t.rect.left},${t.rect.top},${t.rect.width},${t.rect.height}|${t.track ?? ''}|${t.mark}|${t.contain ? 1 : 0}',
      ].join('\n');

  /// The pictures to draw, for the native half: each one's track and its place, in whole pixels from the top left.
  List<Map<String, Object>> toNative() => [
        for (final t in tiles)
          if (t.track != null)
            {
              'track': t.track!,
              'x': t.picture.left.round(),
              'y': t.picture.top.round(),
              'w': t.picture.width.round(),
              'h': t.picture.height.round(),
              'contain': t.contain,
            },
      ];
}

/// Static only: what a recording's picture is, who is in it, and where.
abstract final class RecordingVideo {
  static const width = 1280, height = 720;

  /// Frames a second.
  static const fps = 15;

  /// Bits a second for the picture: with a 128 kb/s track for everyone and for each of four voices, about half a
  /// gigabyte for half an hour (Matt, 2026-11-23).
  static const bitrate = 1600000;

  /// Between tiles, and around them.
  static const gap = 8.0;

  /// The strip at the foot of a tile its name is written on.
  static const strip = 28.0;

  /// How wide the cameras beside a shared screen are.
  static const side = 256.0;

  /// Whether a device records video: a Mac or a Windows PC. Not a phone (it records the voices, as before), not a
  /// browser, and not Linux.
  static bool supportedOn({required bool web, required bool macOS, bool windows = false}) => !web && (macOS || windows);

  /// Whether this device records video.
  static bool get supported => supportedOn(web: kIsWeb, macOS: !kIsWeb && PlatformInfo.isMacOS, windows: !kIsWeb && PlatformInfo.isWindows);

  /// Who has a tile in the recording [recording], this device's person first, and whether a picture may be drawn in
  /// it. [own] is this device's picture while its camera is on or its screen shared; [pictures] is each other
  /// member's, by id, as the call's media has it.
  static List<VideoFace> faces({
    required String recording,
    required String myName,
    required Iterable<VoiceMember> members,
    required String Function(String id) nameOf,
    ({String track, bool screen})? own,
    Map<String, VoiceSound> pictures = const {},
  }) =>
      [
        VideoFace(key: 'me', name: myName, track: own?.track, mark: own == null ? '' : 'me', screen: own?.screen ?? false),
        for (final m in members)
          // In the recording at all: their voice's yes. Without it there is nothing of theirs here, not even a name.
          if (m.agreed.contains(recording) && !m.declined.contains(recording))
            () {
              final p = pictures[m.id];
              // Their picture only with their yes to it, and only while they send one.
              final drawn = p != null && m.picturedIn(recording) && (m.video || m.screen);
              return VideoFace(key: m.id, name: nameOf(m.id), track: drawn ? p.track : null, mark: drawn ? '${p.link}' : '', screen: drawn && m.screen);
            }(),
      ];

  /// Where each of [faces] goes. With a screen shared (the first there is), it is large on the left and everyone else
  /// in a column on the right; otherwise everyone in a grid, as near square as their number allows, a row that is
  /// not full in the middle.
  static VideoLayout layout(List<VideoFace> faces, {int width = width, int height = height}) {
    final w = width.toDouble(), h = height.toDouble();
    if (faces.isEmpty) return VideoLayout(width, height, const []);
    VideoTile tile(VideoFace f, ui.Rect r, {bool stage = false}) {
      final rect = ui.Rect.fromLTRB(r.left.roundToDouble(), r.top.roundToDouble(), r.right.roundToDouble(), r.bottom.roundToDouble());
      // A tile too low for a strip and a picture both is all picture.
      final picture = rect.height > strip * 2.5 ? ui.Rect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom - strip) : rect;
      return VideoTile(key: f.key, name: f.name, rect: rect, picture: picture, track: f.track, mark: f.mark, contain: f.screen, stage: stage);
    }

    final shared = faces.where((f) => f.track != null && f.screen).firstOrNull;
    if (shared != null) {
      final others = [for (final f in faces) if (!identical(f, shared)) f];
      if (others.isEmpty) return VideoLayout(width, height, [tile(shared, ui.Rect.fromLTWH(gap, gap, w - gap * 2, h - gap * 2), stage: true)]);
      final left = w - side - gap;
      // As tall as a camera's shape and its name, or as tall as fits where there are many.
      final each = math.min(side * 9 / 16 + strip, (h - gap * (others.length + 1)) / others.length);
      return VideoLayout(width, height, [
        tile(shared, ui.Rect.fromLTWH(gap, gap, left - gap * 2, h - gap * 2), stage: true),
        for (final (i, f) in others.indexed) tile(f, ui.Rect.fromLTWH(left, gap + i * (each + gap), side, each)),
      ]);
    }
    final n = faces.length;
    final cols = math.sqrt(n).ceil();
    final rows = (n / cols).ceil();
    final cw = (w - gap * (cols + 1)) / cols, ch = (h - gap * (rows + 1)) / rows;
    return VideoLayout(width, height, [
      for (final (i, f) in faces.indexed)
        () {
          final row = i ~/ cols;
          final inRow = row == rows - 1 ? n - cols * (rows - 1) : cols;
          final from = (w - (inRow * cw + (inRow - 1) * gap)) / 2;
          return tile(f, ui.Rect.fromLTWH(from + (i % cols) * (cw + gap), gap + row * (ch + gap), cw, ch));
        }(),
    ]);
  }

  /// The letter a tile without a picture shows: the first of their name.
  static String initial(String name) {
    final n = name.trim();
    return n.isEmpty ? '?' : String.fromCharCode(n.runes.first).toUpperCase();
  }

  /// What is under the pictures, as [layout]'s width by height pixels of RGBA: each tile's back, its person's initial
  /// (seen wherever no picture is drawn over it, and until a picture's first frame comes), and their name on its strip.
  static Future<Uint8List> plate(VideoLayout layout) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final all = ui.Rect.fromLTWH(0, 0, layout.width.toDouble(), layout.height.toDouble());
    canvas.drawRect(all, ui.Paint()..color = const ui.Color(0xFF0E1013));
    ui.Paragraph words(String text, double size, double within, {ui.FontWeight weight = ui.FontWeight.w600, ui.TextAlign align = ui.TextAlign.start}) {
      final b = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: size, fontWeight: weight, maxLines: 1, ellipsis: '…', textAlign: align))
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFF2F4F7)))
        ..addText(text);
      return b.build()..layout(ui.ParagraphConstraints(width: math.max(1, within)));
    }

    for (final t in layout.tiles) {
      canvas.drawRect(t.rect, ui.Paint()..color = const ui.Color(0xFF1B1F25));
      // The initial in a disc, in the middle of where a picture would be.
      final r = math.min(t.picture.width, t.picture.height) * 0.28;
      if (r >= 8) {
        canvas.drawCircle(t.picture.center, r, ui.Paint()..color = const ui.Color(0xFF343B46));
        final letter = words(initial(t.name), r, r * 2, weight: ui.FontWeight.w700, align: ui.TextAlign.center);
        canvas.drawParagraph(letter, ui.Offset(t.picture.center.dx - r, t.picture.center.dy - letter.height / 2));
      }
      if (t.picture.bottom < t.rect.bottom) {
        final name = words(t.name, 14, t.rect.width - 16);
        canvas.drawParagraph(name, ui.Offset(t.rect.left + 8, t.picture.bottom + (strip - name.height) / 2));
      }
    }
    final image = await recorder.endRecording().toImage(layout.width, layout.height);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) throw StateError('no picture of the tiles');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  }
}
