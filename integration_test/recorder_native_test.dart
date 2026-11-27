import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/mp4_names.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:integration_test/integration_test.dart';

/// The recorder's native half on a device (android CallRecorder.kt, macos/ios CallRecorder.swift): three voices of
/// different lengths encoded as AAC into one MP4, named. Run on a throwaway device:
///   flutter test integration_test/recorder_native_test.dart -d emulator-5590
/// It prints where the file is, to pull and read with ffprobe.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost/recorder');

  testWidgets('three voices make one MP4 with four named tracks, the mix first', (tester) async {
    final dir = Directory('${CallRecorder.folder().path}/native-test')..createSync(recursive: true);
    // Start and stop with nobody tapped: the clock and the files open and close.
    expect(await channel.invokeMethod('start', {'mic': '${dir.path}/me.pcm', 'muted': false}), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final counts = await channel.invokeMethod<Map>('stop');
    expect(counts, isNotNull);

    Uint8List tone(double hz, double seconds) {
      final n = (48000 * seconds).round();
      final d = ByteData(n * 2);
      for (var i = 0; i < n; i++) {
        d.setInt16(i * 2, (8000 * math.sin(2 * math.pi * hz * i / 48000)).round(), Endian.little);
      }
      return d.buffer.asUint8List();
    }

    final paths = <String>[];
    for (final (i, (hz, s)) in [(220.0, 3.0), (330.0, 2.0), (440.0, 3.5)].indexed) {
      final p = '${dir.path}/v$i.pcm';
      File(p).writeAsBytesSync(tone(hz, s));
      paths.add(p);
    }
    final mix = '${dir.path}/mix.pcm';
    mixPcm(paths, mix);
    final out = '${dir.path}/test.mp4';
    await channel.invokeMethod('mux', {
      'out': out,
      'inputs': [mix, ...paths],
    });
    expect(File(out).lengthSync(), greaterThan(1000));
    await Mp4Names.apply(out, ['Everyone', 'Maya', 'Sam', 'Ana']);
    // ignore: avoid_print
    print('RECORDER-TEST-FILE $out ${File(out).lengthSync()}');
    // The file itself, for ffprobe on the computer: the test's app is taken off the device when it ends.
    final b64 = base64.encode(File(out).readAsBytesSync());
    for (var i = 0; i < b64.length; i += 800) {
      // ignore: avoid_print
      print('RECB64 ${b64.substring(i, math.min(i + 800, b64.length))}');
    }
  });
}
