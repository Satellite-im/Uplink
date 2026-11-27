import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import 'common.dart';

/// A picture over everything, full screen (Matt, 2026-11-19: "when clicking a picture in a chat, like in a circle make
/// it a full screen overlay"): on a dark ground, pinched or scrolled to zoom, a tap or Escape or the cross to go back.
/// [thumb] shows at once while [file] comes ([coming]), so the picture is there the moment it is pressed. [more] is a
/// button at the top for what else can be done with it (Save, Share, its details).
Future<void> showPictureOverlay(BuildContext context, {Uint8List? bytes, String? path, Future<String?>? coming, Uint8List? thumb, String? title, VoidCallback? more}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: const Color(0xF2000000),
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, _, _) => PictureOverlay(bytes: bytes, path: path, coming: coming, thumb: thumb, title: title, more: more),
    // Grown a little into place over the darkening, as the texts' viewer always did.
    transitionsBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
  ));
}

/// The overlay's page ([showPictureOverlay] raises it): the picture from [bytes], or the file at [path] once there.
class PictureOverlay extends StatefulWidget {
  const PictureOverlay({super.key, this.bytes, this.path, this.coming, this.thumb, this.title, this.more});
  final Uint8List? bytes;
  final String? path;
  final Future<String?>? coming;
  final Uint8List? thumb;
  final String? title;
  final VoidCallback? more;

  @override
  State<PictureOverlay> createState() => _PictureOverlayState();
}

class _PictureOverlayState extends State<PictureOverlay> {
  String? _path;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _path = widget.path;
    final coming = widget.coming;
    if (_path == null && coming != null) {
      unawaited(coming.then((p) {
        if (mounted && p != null) setState(() => _path = p);
      }, onError: (Object _) {}));
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final thumb = widget.thumb;
    final small = thumb == null ? null : Image.memory(thumb, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    Widget? picture;
    if (widget.bytes != null) {
      picture = Image.memory(widget.bytes!, fit: BoxFit.contain, gaplessPlayback: true);
    } else if (_path != null) {
      picture = Image.file(File(_path!), fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, _, _) => small ?? const SizedBox.shrink());
    }
    final shown = picture ?? small;
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) _close();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              key: const ValueKey('picture-overlay'),
              maxScale: 6,
              child: Center(
                child: Stack(alignment: Alignment.center, children: [
                  ?shown,
                  if (picture == null) const GhostSpinner(size: 24),
                ]),
              ),
            ),
          ),
          PositionedDirectional(
            top: pad.top + 8,
            start: 8,
            end: 8,
            child: Row(children: [
              Expanded(
                child: Text(
                  widget.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: pageText(context.tokens, context.tokens.fontSize('md'), weight: 'semibold', color: const Color(0xE6FFFFFF)),
                ),
              ),
              if (widget.more != null) IconTap(key: const ValueKey('picture-overlay-more'), icon: Lucide.ellipsis, label: 'More', color: const Color(0xFFFFFFFF), onPressed: widget.more),
              IconTap(key: const ValueKey('picture-overlay-close'), icon: Lucide.x, label: 'Close', color: const Color(0xFFFFFFFF), onPressed: _close),
            ]),
          ),
        ]),
      ),
    );
  }
}
