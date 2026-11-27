import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

// How large a video came, as the conversation says it under the video (lib/ui/video.dart; Matt, 2026-11-14: "the
// videos sent from iphone are extremely low quality").

void main() {
  test('a video\'s own size and its file\'s, in words', () {
    expect(const VideoPreview(videoWidth: 320, videoHeight: 240, bytes: 912384).facts, '320 × 240 · 913 KB');
    expect(const VideoPreview(videoWidth: 1920, videoHeight: 1080, bytes: 24500000).facts, '1920 × 1080 · 24.5 MB');
    expect(const VideoPreview(videoWidth: 176, videoHeight: 144, bytes: 1200000).facts, '176 × 144 · 1.2 MB');
    // What is known is said, and nothing where nothing is.
    expect(const VideoPreview(bytes: 4000).facts, '4 KB');
    expect(const VideoPreview(videoWidth: 640, videoHeight: 360).facts, '640 × 360');
    expect(const VideoPreview().facts, isNull);
    expect(VideoPreview.from(const {'millis': 5000}).facts, isNull, reason: 'a phone or a Mac from before it said');
    expect(VideoPreview.from(const {'videoWidth': 320, 'videoHeight': 240, 'bytes': 912384}).facts, '320 × 240 · 913 KB');
  });

  test('small is what a phone makes of a video to send it as a picture message', () {
    expect(const VideoPreview(videoWidth: 320, videoHeight: 240).small, isTrue);
    expect(const VideoPreview(videoWidth: 176, videoHeight: 144).small, isTrue);
    expect(const VideoPreview(videoWidth: 240, videoHeight: 320).small, isTrue, reason: 'filmed upright');
    expect(const VideoPreview(videoWidth: 640, videoHeight: 360).small, isTrue);
    expect(const VideoPreview(videoWidth: 640, videoHeight: 480).small, isFalse);
    expect(const VideoPreview(videoWidth: 1280, videoHeight: 720).small, isFalse);
    expect(const VideoPreview(videoWidth: 1080, videoHeight: 1920).small, isFalse);
    expect(const VideoPreview().small, isFalse, reason: 'not known is not small');
  });
}
