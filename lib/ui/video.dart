import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import 'video_screen.dart';
import 'voice.dart' show voiceClock, voiceProblem;

/// Why a video that came small is small.
const String shrunkNote = 'Shrunk by the sender\'s phone to send as a picture message.';

/// A video in the conversation, drawn as a picture of where it starts, how long it runs, and a button that plays it
/// (Matt, 2026-11-14: "mp4 files are not loading it just shows up as a string of text for the filename"). It plays
/// the whole screen in the app's own player (lib/ui/video_screen.dart) on the phone and on a computer alike (Matt,
/// 2026-11-18: "add support for playing mkv video files and mp4's within the app in a player themed by glacier UI";
/// a computer's had been a window of AVFoundation's, macos/Runner/DeskVideo.swift, which could not open an .mkv).
/// Where no picture can be made of it (a kind the device cannot read), it is still named and can still be tried.
class VideoBubble extends StatefulWidget {
  const VideoBubble({super.key, required this.video, required this.radius, required this.maxWidth, required this.ground, required this.ink, this.received = false, this.title});
  final Attachment video;

  /// Who sent it, said at the top of the player.
  final String? title;

  /// It came from someone else: where it came small, the line under it says why.
  final bool received;
  final BorderRadius radius;
  final double maxWidth;

  /// The bubble's own colours, for a video with no picture.
  final Color ground;
  final Color ink;

  @override
  State<VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<VideoBubble> {
  late Future<VideoPreview> _preview = Sms.instance.videoPreview(widget.video);
  bool _starting = false;

  /// The list hands this place to another message when one arrives above it: what was shown was the other's.
  @override
  void didUpdateWidget(VideoBubble old) {
    super.didUpdateWidget(old);
    if (old.video.id != widget.video.id) _preview = Sms.instance.videoPreview(widget.video);
  }

  /// Opens the player over the whole screen; a second press while it is opening does nothing.
  Future<void> _play() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      // The app's own player, opened at once over the video's picture while its file is made (Matt, 2026-11-17: "The
      // app has gotten pretty laggy, especially when opening videos"). A computer's file is a copy of the phone's
      // bytes, removed once the player has gone.
      final poster = (await _preview.catchError((_) => const VideoPreview())).picture;
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(videoRoute(VideoScreen.coming(file: Sms.instance.videoFile(widget.video), poster: poster, title: widget.title ?? widget.video.name, dropFile: Sms.remote)));
    } catch (e) {
      if (mounted) toast(context, voiceProblem(e), tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FutureBuilder<VideoPreview>(
      future: _preview,
      builder: (context, snap) {
        final preview = snap.data;
        final picture = preview?.picture;
        final length = preview?.length ?? Duration.zero;
        final waiting = snap.connectionState != ConnectionState.done;
        // As wide as the bubble may be, and as tall as the video's own shape makes it (16 by 9 until that is known).
        final shape = (preview != null && preview.width > 0 && preview.height > 0) ? preview.width / preview.height : 16 / 9;
        // Never wider than a phone's bubble, on a computer's wide window either.
        final most = math.min(widget.maxWidth, t.lenOf('22rem'));
        final width = shape >= 1 ? most : most * 0.62;
        final height = (width / shape).clamp(t.lenOf('6rem'), most * 1.3);
        final disc = t.lenOf('3rem');
        // Under it, how large it came (Matt, 2026-11-14: "the videos sent from iphone are extremely low quality":
        // a phone that sends a video as a picture message shrinks it to fit the carrier's limit, and nothing here
        // can give back what was taken out). The size always; why, where it came small from someone else.
        final facts = preview?.facts;
        final quiet = pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.3);
        final player = GlacierPressable(
          onPressed: _play,
          semanticLabel: 'Play video',
          builder: (context, state) => ClipRRect(
            borderRadius: widget.radius,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                if (picture != null)
                  Image.memory(picture, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round())
                else
                  ColoredBox(
                    color: widget.ground,
                    child: waiting
                        ? null
                        : Padding(
                            padding: EdgeInsets.all(t.space(3)),
                            child: Align(
                              alignment: AlignmentDirectional.topStart,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                AppIcon(Lucide.film, size: 15, color: widget.ink, wash: false),
                                SizedBox(width: t.space(2)),
                                Flexible(child: Text(widget.video.name ?? 'Video', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: widget.ink))),
                              ]),
                            ),
                          ),
                  ),
                // A little dark over the picture, so the button and the length read on a bright one.
                if (picture != null) ColoredBox(color: Color.fromRGBO(0, 0, 0, state.pressed ? 0.3 : 0.14)),
                Center(
                  child: Container(
                    width: disc,
                    height: disc,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: picture != null ? const Color(0xB3000000) : widget.ink.withValues(alpha: state.pressed ? 0.26 : 0.14)),
                    child: _starting ? const GhostSpinner(size: 18) : AppIcon(Lucide.play, size: 20, color: picture != null ? const Color(0xFFFFFFFF) : widget.ink),
                  ),
                ),
                if (length > Duration.zero)
                  PositionedDirectional(
                    end: t.space(2),
                    bottom: t.space(2),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 2),
                      decoration: BoxDecoration(color: picture != null ? const Color(0xB3000000) : widget.ink.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(t.lenOf('0.6rem'))),
                      child: Text(voiceClock(length), style: pageText(t, t.fontSize('xs'), weight: 'medium', color: picture != null ? const Color(0xFFFFFFFF) : widget.ink)),
                    ),
                  ),
              ]),
            ),
          ),
        );
        if (facts == null) return player;
        return SizedBox(
          width: width,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            player,
            SizedBox(height: t.space(1)),
            Text(facts, style: quiet),
            if (widget.received && preview!.small) Text(shrunkNote, style: quiet),
          ]),
        );
      },
    );
  }
}
