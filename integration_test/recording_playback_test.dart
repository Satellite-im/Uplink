import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_playback.dart';
import 'package:integration_test/integration_test.dart';

/// A recording kept on the device opened in the mixer, on a device (lib/voice/recording_playback.dart): a recording of
/// three voices made as a call's is (one tone each, the second starting late), each voice decoded back, played and
/// moved, and the mix saved again with one voice muted. Run on a throwaway device:
///   flutter test integration_test/recording_playback_test.dart -d emulator-5554
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a saved recording opens in the mixer: each voice decoded, played, and mixed again', (tester) async {
    final dir = Directory('${CallRecorder.folder().path}/playback-test')..createSync(recursive: true);
    Uint8List tone(double hz, double seconds, {double from = 0, double level = 0.4}) {
      final n = (48000 * seconds).round();
      final d = ByteData(n * 2);
      for (var i = (48000 * from).round(); i < n; i++) {
        d.setInt16(i * 2, (32767 * level * math.sin(2 * math.pi * hz * i / 48000)).round(), Endian.little);
      }
      return d.buffer.asUint8List();
    }

    final voices = <String>[];
    for (final (i, (hz, from, level)) in [(220.0, 0.0, 0.4), (330.0, 2.0, 0.25), (440.0, 0.0, 0.1)].indexed) {
      final p = '${dir.path}/v$i.pcm';
      File(p).writeAsBytesSync(tone(hz, 4, from: from, level: level));
      voices.add(p);
    }
    final mixed = '${dir.path}/mix.pcm';
    mixPcm(voices, mixed);
    final out = '${CallRecorder.folder().path}/rec-playback-test.mp4';
    await CallRecorder.makeMp4([mixed, ...voices], out, ['Everyone', 'Matt', 'Maya', 'Theo'], work: dir.path);
    final r = Recording(id: 'rec-playback-test', path: out, space: 'general', at: DateTime.now(), seconds: 4, people: const ['Matt', 'Maya', 'Theo']);

    final p = RecordingPlayback(r);
    final began = DateTime.now();
    await p.open();
    debugPrint('playback: opened in ${DateTime.now().difference(began).inMilliseconds} ms, error ${p.error}');
    expect(p.error, isNull);
    expect(p.ready, isTrue);
    expect(p.seconds, closeTo(4, 0.15));
    // Each voice's waveform is its own tone: loudness as made, Maya silent for her first two seconds.
    final w = p.meter.levels;
    double peakOf(List<double> l, int from, int to) => l.sublist(from, math.min(to, l.length)).fold(0.0, math.max);
    debugPrint('playback: peaks ${[for (final k in p.keys) peakOf(w[k]!, 25, 35).toStringAsFixed(2)]}');
    expect(peakOf(w['v1']!, 5, 35), closeTo(0.4, 0.06));
    expect(peakOf(w['v2']!, 2, 15), lessThan(0.03), reason: 'Maya starts at two seconds');
    expect(peakOf(w['v2']!, 25, 35), closeTo(0.25, 0.05));
    expect(peakOf(w['v3']!, 5, 35), closeTo(0.1, 0.03));

    // Played: the playhead moves with the sound, and the meters show each voice there.
    await p.play();
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final heard = p.at;
    final meters = {for (final k in p.keys) k: p.meter.now[k]!.peak};
    await p.pause();
    debugPrint('playback: after 2.5 s the playhead is at ${heard.toStringAsFixed(2)} s, meters $meters');
    expect(heard, greaterThan(1.2), reason: 'it played');
    expect(meters['v1'], greaterThan(0.2));
    // Moved: the meters read there.
    await p.seek(1);
    expect(p.at, closeTo(1, 0.01));
    expect(p.meter.now['v2']!.peak, lessThan(0.03), reason: 'Maya is silent at one second');

    // Maya muted, Matt halved: saved as a new recording; its mix is the others as set, its voices as they were.
    p.setMuted('v2', true);
    p.setFader('v1', 0.5);
    final saved = await p.save();
    expect(saved.mixedFrom, r.id);
    expect(File(saved.path).existsSync(), isTrue);
    expect(CallRecorder.instance.kept.first.id, saved.id);
    final again = RecordingPlayback(saved);
    await again.open();
    expect(again.error, isNull);
    expect(again.keys, hasLength(3), reason: 'every voice still a track of its own');
    final mixWave = await _decodeMix(saved.path, dir.path);
    final late = peakOf(mixWave, 25, 35);
    debugPrint('playback: the saved mix peaks at ${late.toStringAsFixed(3)} where Matt (0.4, halved) and Theo (0.1) play and Maya is muted');
    expect(late, closeTo(0.2 + 0.1, 0.06), reason: 'Matt at half, Theo as he was, Maya out');
    p.dispose();
    again.dispose();
    CallRecorder.instance.delete(saved);
    File(out).deleteSync();
    dir.deleteSync(recursive: true);
  });
}

/// The saved recording's first track (everyone mixed) as its waveform.
Future<List<double>> _decodeMix(String path, String dir) async {
  const channel = MethodChannel('ghost/scribe');
  final raw = '$dir/mix-check.raw';
  final got = await channel.invokeMethod<Map>('decode', {'path': path, 'track': 0, 'out': raw});
  final pcm = '$dir/mix-check.pcm';
  toMono48k(raw, pcm, fromRate: (got!['rate'] as num).toInt(), channels: (got['channels'] as num).toInt());
  return waveform(pcm);
}
