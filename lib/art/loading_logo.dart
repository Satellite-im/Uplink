import 'dart:async';

import 'package:flutter/widgets.dart';

/// The logo as it turns while the app loads or looks for an update (Matt, 2026-11-27: "update the update screen to
/// use the loading_logo.mp4 and make it larger so it is visible, also on the phone add a loading splash screen using
/// the same logo"): his film of it, four seconds that come back to where they began, going round for as long as it is
/// shown. On a computer's launch splash (lib/desktop/ui/launch_splash.dart) and a phone's (lib/ui/launch_gate.dart).
///
/// The film is the white logo on black. The app carries it as a picture that moves (assets/art/loading-logo.webp,
/// made by tool/loading_logo.sh, which says why not the film itself), still black and white, and draws it in
/// [color]: how bright each dot of the picture is, is how much of the colour it gets, and the black gets none. So it
/// is the page's ink on whatever page is behind it, light or dark.
///
/// Where the device is asked to move less (reduced motion), it is the film's first frame and no more
/// ([still]): the same logo, the same size, drawn the same way, not turning.
///
/// The film is read for as long as the logo is shown and let go of after: a picture that moves is kept whole by
/// the pictures' cache (the file, and the frame it is on), and nothing shows this one again once the app is open.
class LoadingLogo extends StatefulWidget {
  const LoadingLogo({super.key, required this.width, required this.color, this.onShown});

  /// How wide it is drawn; its height follows from [shape].
  final double width;

  /// What it is drawn in: the page's ink.
  final Color color;

  /// Told once, after the frame in which the logo is first on the page (true), or in which it turned out that this
  /// build of the app can't read it (false): what a splash counts its time from.
  final ValueChanged<bool>? onShown;

  static const asset = 'assets/art/loading-logo.webp';

  /// The film's first frame by itself, for a device that asks for less motion.
  static const still = 'assets/art/loading-logo-still.webp';

  /// The picture's width over its height: 640 by 548, the part of the film the logo ever reaches.
  static const shape = 640 / 548;

  /// The film's black is not quite nothing once it is packed small, nor its white quite everything: about one dot in
  /// thirty of the black is a part or two in 255 off, which on a black page is a speckle of nearly-black round the
  /// logo. Under [floor] counts as none of the colour and over [ceiling] as all of it.
  static const floor = 8.0, ceiling = 247.0;

  /// What draws a black and white picture in [color]: red, green and blue are the colour's own whatever the picture
  /// has there, and how solid a dot is, is how bright the picture is there (its red, the three being alike) between
  /// [floor] and [ceiling]. The colour is taken as solid: how see-through it is, is not this's to draw (the answer
  /// is cut off at wholly solid and nowhere below, so a see-through colour would come out too strong at the top).
  static List<double> inked(Color color) {
    const gain = 255 / (ceiling - floor);
    return [
      0, 0, 0, 0, color.r * 255, //
      0, 0, 0, 0, color.g * 255, //
      0, 0, 0, 0, color.b * 255, //
      gain, 0, 0, 0, -gain * floor, //
    ];
  }

  @override
  State<LoadingLogo> createState() => _LoadingLogoState();
}

class _LoadingLogoState extends State<LoadingLogo> {
  bool _told = false;

  /// Says the logo is on the page, or can't be, once: after the frame being built now, which is the one it is in.
  void _tell(bool there) {
    if (_told) return;
    _told = true;
    final tell = widget.onShown;
    if (tell != null) WidgetsBinding.instance.addPostFrameCallback((_) => tell(there));
  }

  @override
  void dispose() {
    // Asked of the cache and not waited on: the pictures under this are let go of first, so nothing is listening.
    for (final name in [LoadingLogo.asset, LoadingLogo.still]) {
      unawaited(AssetImage(name).evict().catchError((_) => false));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width, color = widget.color;
    final height = width / LoadingLogo.shape;
    final moving = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    Widget logo = ColorFiltered(
      colorFilter: ColorFilter.matrix(LoadingLogo.inked(color)),
      child: Image.asset(
        moving ? LoadingLogo.asset : LoadingLogo.still,
        width: width,
        height: height,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
        // Nothing until its first frame is read (a moment): the film begins on the logo, so it simply appears.
        frameBuilder: (context, child, frame, sync) {
          if (frame == null && !sync) return const SizedBox.expand();
          _tell(true);
          return child;
        },
        // A build that can't read it leaves its place empty, where an error's picture would be drawn.
        errorBuilder: (context, _, _) {
          _tell(false);
          return const SizedBox.expand();
        },
      ),
    );
    // A see-through ink is the solid one, drawn that see-through.
    if (color.a < 1) logo = Opacity(opacity: color.a, child: logo);
    return SizedBox(width: width, height: height, child: logo);
  }
}
