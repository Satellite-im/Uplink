import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Scribe's native half on a device (android Scribe.kt, macos/ios Scribe.swift): one voice's track of a recording
/// heard by the device's own speech recognition, each stretch with its time. Needs a recording pushed first:
///   adb push call.mp4 /data/local/tmp/call.mp4   (track 1 and 2 one voice each)
///   flutter test integration_test/scribe_native_test.dart -d emulator-5590
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost/scribe');

  testWidgets('each voice\'s track is written out, line by line, with its time', (tester) async {
    final available = await channel.invokeMethod<bool>('available');
    // ignore: avoid_print
    print('SCRIBE-AVAILABLE $available');
    if (available != true) return;
    for (final track in [1, 2]) {
      final lines = await channel.invokeMethod<List>('transcribe', {'path': '/data/local/tmp/call.mp4', 'track': track, 'language': 'en-US'});
      // ignore: avoid_print
      print('SCRIBE-TRACK $track $lines');
    }
  });
}
