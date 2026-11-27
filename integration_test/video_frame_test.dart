import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/video_frame.dart';
import 'package:integration_test/integration_test.dart';

/// A video's frame for its preview in a Files space (lib/files/video_frame.dart), with real videos on the real Mac app:
/// AVFoundation for an MP4, libmpv (media_kit, Windows' way too) for an MKV and an MP4.
///
///   flutter test integration_test/video_frame_test.dart -d macos --dart-define=VIDEO_DIR=/folder/with/long.mp4,long.mkv
///
/// libmpv's half runs with --dart-define=MPV=1: started from `flutter test` with the app already open (the test's copy
/// not brought to the front), libmpv's open never finished (2026-11-18), and videoFrame's limit gave up on it, as it
/// should; it wants the app in front, as a person has it.
const _dir = String.fromEnvironment('VIDEO_DIR');
const _mpv = bool.fromEnvironment('MPV');

Future<(int, int)> _size(List<int> png) async {
  final codec = await ui.instantiateImageCodec(Uint8List.fromList(png));
  final f = await codec.getNextFrame();
  return (f.image.width, f.image.height);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a frame from the first minute: an MP4 by AVFoundation, an MKV by libmpv, and libmpv alone', (tester) async {
    await tester.pumpWidget(const SizedBox());
    expect(_dir, isNotEmpty, reason: 'give --dart-define=VIDEO_DIR=');
    final mp4 = await videoFrame('$_dir/long.mp4');
    debugPrint('VIDEO-FRAME-STEP avfoundation ${mp4?.length}');
    expect(mp4, isNotNull, reason: 'AVFoundation reads an MP4');
    final frames = [('mp4', mp4!)];
    if (_mpv) {
      final mpv = await mediaKitFrame('$_dir/long.mp4', log: (s) => debugPrint('VIDEO-FRAME-STEP mpv $s'));
      expect(mpv, isNotNull, reason: 'libmpv alone, as on Windows');
      final mkv = await videoFrame('$_dir/long.mkv');
      expect(mkv, isNotNull, reason: 'libmpv reads what AVFoundation can\'t');
      frames.addAll([('mpv', mpv!), ('mkv', mkv!)]);
    } else {
      // Whatever libmpv does here, an MKV's frame gives up in time rather than holding an upload.
      final began = DateTime.now();
      await videoFrame('$_dir/long.mkv');
      expect(DateTime.now().difference(began), lessThan(frameLimit + const Duration(seconds: 5)));
    }
    for (final (name, png) in frames) {
      final (w, h) = await _size(png);
      File('$_dir/frame-$name.png').writeAsBytesSync(png);
      debugPrint('VIDEO-FRAME $name ${png.length} bytes ${w}x$h');
      expect(w, greaterThan(0));
    }
    expect(frameAt(const Duration(minutes: 150)), const Duration(minutes: 1), reason: 'never past the first minute');
    expect(frameAt(const Duration(seconds: 150)), const Duration(seconds: 15));
    expect(frameAt(const Duration(seconds: 5)), const Duration(seconds: 1));
  });
}
