// One MP4 of several voices from one MP4 a voice (lib/voice/mp4_merge.dart: how a call's recording is put together on
// Windows; Matt, 2026-11-21: "my friend is not able to see plugins added for recording calls on his pc"). The inputs
// are made by ffmpeg and by the Mac's own afconvert, so it runs where those are: on a machine without ffmpeg it is
// skipped.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/mp4_merge.dart';
import 'package:ghost_messaging/voice/mp4_names.dart';

String? _which(String name) {
  for (final dir in ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin']) {
    if (File('$dir/$name').existsSync()) return '$dir/$name';
  }
  return null;
}

void main() {
  final ffmpeg = _which('ffmpeg'), ffprobe = _which('ffprobe');
  final skip = ffmpeg == null || ffprobe == null ? 'needs ffmpeg and ffprobe' : null;

  /// [seconds] of a tone at [hz], 48 kHz mono 16-bit.
  Uint8List tone(double hz, double seconds) {
    final n = (seconds * 48000).round();
    final out = ByteData(n * 2);
    for (var i = 0; i < n; i++) {
      out.setInt16(i * 2, (math.sin(2 * math.pi * hz * i / 48000) * 12000).round(), Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// The tone in [pcm], from how often it crosses zero.
  double pitch(Uint8List pcm) {
    final d = ByteData.sublistView(pcm);
    var crossings = 0;
    final n = pcm.length ~/ 2;
    for (var i = 1; i < n; i++) {
      if ((d.getInt16(i * 2 - 2, Endian.little) < 0) != (d.getInt16(i * 2, Endian.little) < 0)) crossings++;
    }
    return crossings / 2 / (n / 48000);
  }

  test('three files of one voice each become one file of three tracks, each still its own sound and length', () async {
    final dir = Directory.systemTemp.createTempSync('merge');
    addTearDown(() => dir.deleteSync(recursive: true));
    final voices = [(hz: 440.0, s: 3.0), (hz: 880.0, s: 2.0), (hz: 1320.0, s: 3.0)];
    final parts = <String>[];
    for (var i = 0; i < voices.length; i++) {
      final pcm = '${dir.path}/$i.pcm';
      File(pcm).writeAsBytesSync(tone(voices[i].hz, voices[i].s));
      final out = '${dir.path}/$i.m4a';
      // The second with its movie box first (a "fast start" file), the third by the Mac's own encoder where there
      // is one: the merge reads each as it finds it.
      final afconvert = i == 2 ? _which('afconvert') : null;
      final ProcessResult made;
      if (afconvert != null) {
        final wav = '${dir.path}/$i.wav';
        expect(Process.runSync(ffmpeg!, ['-v', 'error', '-f', 's16le', '-ar', '48000', '-ac', '1', '-i', pcm, wav]).exitCode, 0);
        made = Process.runSync(afconvert, ['-f', 'm4af', '-d', 'aac', '-b', '128000', wav, out]);
      } else {
        made = Process.runSync(ffmpeg!, ['-v', 'error', '-f', 's16le', '-ar', '48000', '-ac', '1', '-i', pcm, '-c:a', 'aac', '-b:a', '128k', if (i == 1) ...['-movflags', '+faststart'], out]);
      }
      expect(made.exitCode, 0, reason: '${made.stderr}');
      parts.add(out);
    }
    final out = '${dir.path}/call.mp4';
    await Mp4Merge.merge(parts, out);
    await Mp4Names.apply(out, ['Everyone', 'Maya', 'Sam']);

    final probe = Process.runSync(ffprobe!, ['-v', 'error', '-show_entries', 'stream=index,codec_name,duration:stream_tags=title', '-of', 'csv=p=0', out]);
    expect(probe.exitCode, 0, reason: '${probe.stderr}');
    final lines = '${probe.stdout}'.trim().split('\n');
    expect(lines, hasLength(3), reason: '${probe.stdout}');
    expect('${probe.stderr}', isEmpty);
    for (var i = 0; i < 3; i++) {
      final f = lines[i].split(',');
      expect(f[1], 'aac');
      expect(double.parse(f[2]), closeTo(voices[i].s, 0.1), reason: lines[i]);
      expect(lines[i], contains(['Everyone', 'Maya', 'Sam'][i]));
      // Each track decoded is still its own tone, the whole way through with no errors.
      final back = '${dir.path}/back$i.pcm';
      final dec = Process.runSync(ffmpeg!, ['-v', 'error', '-xerror', '-i', out, '-map', '0:$i', '-f', 's16le', '-ar', '48000', '-ac', '1', back]);
      expect(dec.exitCode, 0, reason: '${dec.stderr}');
      expect('${dec.stderr}', isEmpty);
      final pcm = File(back).readAsBytesSync();
      expect(pcm.length / 96000, closeTo(voices[i].s, 0.1));
      expect(pitch(pcm), closeTo(voices[i].hz, voices[i].hz * 0.02));
    }
  }, skip: skip);

  test('a file of video is put in after the voices, every frame of it still read, and one that is not video is left out', () async {
    final dir = Directory.systemTemp.createTempSync('merge');
    addTearDown(() => dir.deleteSync(recursive: true));
    final parts = <String>[];
    for (final (i, hz) in [440.0, 880.0].indexed) {
      final pcm = '${dir.path}/$i.pcm';
      File(pcm).writeAsBytesSync(tone(hz, 3));
      final out = '${dir.path}/$i.m4a';
      expect(Process.runSync(ffmpeg!, ['-v', 'error', '-f', 's16le', '-ar', '48000', '-ac', '1', '-i', pcm, '-c:a', 'aac', '-b:a', '128k', out]).exitCode, 0);
      parts.add(out);
    }
    // Three seconds of a moving pattern, 1280 by 720 at fifteen a second, H.264 with no frames out of order, in an
    // MP4 with its movie box last: what the Windows half writes (windows/runner/call_video.cpp).
    final video = '${dir.path}/video.mp4';
    final made = Process.runSync(ffmpeg!, ['-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=15', '-t', '3', '-c:v', 'libx264', '-bf', '0', '-pix_fmt', 'yuv420p', video]);
    if (made.exitCode != 0) {
      markTestSkipped('this ffmpeg has no H.264 encoder: ${made.stderr}');
      return;
    }
    final out = '${dir.path}/call.mp4';
    expect(await Mp4Merge.merge(parts, out, video: video), isTrue);
    await Mp4Names.apply(out, ['Everyone', 'Maya']);
    final probe = Process.runSync(ffprobe!, ['-v', 'error', '-count_frames', '-show_entries', 'stream=index,codec_type,codec_name,width,height,nb_read_frames,duration', '-of', 'csv=p=0', out]);
    expect(probe.exitCode, 0, reason: '${probe.stderr}');
    expect('${probe.stderr}', isEmpty);
    final lines = '${probe.stdout}'.trim().split('\n');
    expect(lines, hasLength(3), reason: '${probe.stdout}');
    expect(lines[0], contains('aac'));
    expect(lines[1], contains('aac'));
    expect(lines[2], allOf(contains('h264'), contains('video'), contains('1280'), contains('720')), reason: lines[2]);
    // Its colours are said in the file (BT.709, the narrow range), which the file put in did not say.
    final colours = Process.runSync(ffprobe, ['-v', 'error', '-select_streams', 'v', '-show_entries', 'stream=color_range,color_space,color_transfer,color_primaries', '-of', 'csv=p=0', out]);
    expect('${colours.stdout}'.trim(), 'tv,bt709,bt709,bt709');
    // Every one of its 45 frames is read back, and the whole track decodes with no error.
    expect(lines[2].split(','), contains('45'), reason: lines[2]);
    final dec = Process.runSync(ffmpeg, ['-v', 'error', '-xerror', '-i', out, '-map', '0:v', '-f', 'null', '-']);
    expect(dec.exitCode, 0, reason: '${dec.stderr}');
    expect('${dec.stderr}', isEmpty);
    // The voices are still their own tones.
    for (final (i, hz) in [440.0, 880.0].indexed) {
      final back = '${dir.path}/back$i.pcm';
      expect(Process.runSync(ffmpeg, ['-v', 'error', '-xerror', '-i', out, '-map', '0:$i', '-f', 's16le', '-ar', '48000', '-ac', '1', back]).exitCode, 0);
      expect(pitch(File(back).readAsBytesSync()), closeTo(hz, hz * 0.02));
    }

    // A "video" that is a voice's file, junk, or not there: left out, the voices made as before.
    for (final not in [parts[0], (File('${dir.path}/junk.mp4')..writeAsBytesSync(List.filled(64, 7))).path, '${dir.path}/none.mp4']) {
      final plain = '${dir.path}/plain.mp4';
      expect(await Mp4Merge.merge(parts, plain, video: not), isFalse);
      final p = Process.runSync(ffprobe, ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', plain]);
      expect('${p.stdout}'.trim().split('\n'), ['audio', 'audio']);
    }
  }, skip: skip);

  test('a file with no sound, or none at all, is said so and nothing is half made', () async {
    final dir = Directory.systemTemp.createTempSync('merge');
    addTearDown(() => dir.deleteSync(recursive: true));
    final junk = File('${dir.path}/junk.m4a')..writeAsBytesSync(List.filled(64, 7));
    await expectLater(Mp4Merge.merge([junk.path], '${dir.path}/out.mp4'), throwsA(isA<FormatException>()));
    await expectLater(Mp4Merge.merge(const [], '${dir.path}/out.mp4'), throwsA(isA<FormatException>()));
    expect(File('${dir.path}/out.mp4').existsSync(), isFalse);
  });
}
