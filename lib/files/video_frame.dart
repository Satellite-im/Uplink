/// A frame of a video, for its preview in a Files space (Matt, 2026-11-18: "Please make the files have previews in the
/// files page in the app like gifs images and videos having a frame from the first minute of the video"): a tenth of
/// the way in, at least a second (past a black opening), never past the first minute.
///
/// Each platform's own reader where it has one: Android's MediaMetadataRetriever (the sms channel), AVFoundation on a
/// Mac and an iPhone (the desktop system channel), libmpv on a Mac for what AVFoundation can't read (an MKV); on Windows, libmpv through media_kit, the player the app plays
/// videos with there (lib/ui/video_engine.dart).
library;

import 'dart:async';
import '../platform_info.dart';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

/// The frame as an encoded picture (a PNG), or null where this device can't read the video. Never longer than
/// [frameLimit]: an upload waits on its preview, and a video no reader can open must not hold it up.
Future<Uint8List?> videoFrame(String path) => _videoFrame(path).timeout(frameLimit, onTimeout: () => null);

/// The longest [videoFrame] waits: a little over libmpv's three steps at their limit ([mediaKitFrame]).
const frameLimit = Duration(seconds: 25);

/// The frame by this platform's reader, with no time limit of its own; null where there is none or it failed.
Future<Uint8List?> _videoFrame(String path) async {
  try {
    if (PlatformInfo.isAndroid) return await const MethodChannel('ghost_messaging/sms').invokeMethod<Uint8List>('videoFrame', {'path': path});
    if (PlatformInfo.isMacOS || PlatformInfo.isIOS) {
      final native = await const MethodChannel('ghost_desktop/system').invokeMethod<Uint8List>('videoFrame', {'path': path});
      // AVFoundation reads no MKV: on a Mac, libmpv does (as the app's player plays them there).
      if (native != null || PlatformInfo.isIOS) return native;
      return await mediaKitFrame(path);
    }
    if (PlatformInfo.isWindows || PlatformInfo.isLinux) return await mediaKitFrame(path);
  } catch (_) {}
  return null;
}

/// Where in a video of [length] its frame is taken: a tenth of the way, at least a second (half of a shorter one), at
/// most a minute.
Duration frameAt(Duration length) {
  if (length <= Duration.zero) return const Duration(seconds: 1);
  final tenth = length ~/ 10;
  final least = length < const Duration(seconds: 2) ? length ~/ 2 : const Duration(seconds: 1);
  final at = tenth < least ? least : tenth;
  return at > const Duration(minutes: 1) ? const Duration(minutes: 1) : at;
}

/// The frame by libmpv: the video opened silent and paused, sought to [frameAt], and that frame taken. Each step has a
/// time limit, and [log] hears each as it is passed (for finding which one a video stops at).
Future<Uint8List?> mediaKitFrame(String path, {void Function(String step)? log}) async {
  const step = Duration(seconds: 8);
  mk.MediaKit.ensureInitialized();
  final player = mk.Player(configuration: const mk.PlayerConfiguration(muted: true));
  try {
    final controller = mkv.VideoController(player);
    log?.call('made');
    final length = Completer<Duration>();
    final sub = player.stream.duration.listen((d) {
      if (d > Duration.zero && !length.isCompleted) length.complete(d);
    });
    await player.open(mk.Media(Uri.file(path).toString()), play: false).timeout(step);
    log?.call('opened');
    final d = await length.future.timeout(step, onTimeout: () => Duration.zero);
    await sub.cancel();
    log?.call('length $d');
    await player.seek(frameAt(d)).timeout(step);
    log?.call('sought ${frameAt(d)}');
    await controller.waitUntilFirstFrameRendered.timeout(step, onTimeout: () {});
    log?.call('drawn');
    // The seek's frame drawn before it is taken.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final shot = await player.screenshot(format: 'image/png').timeout(step, onTimeout: () => null);
    log?.call('shot ${shot?.length}');
    return shot;
  } catch (e) {
    log?.call('failed $e');
    return null;
  } finally {
    await player.dispose().timeout(step, onTimeout: () {});
  }
}
