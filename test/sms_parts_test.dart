import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

/// A picture asked for before the phone has it (Matt, 2026-11-16: "the preview of the image I sent never loads"):
/// asked again later, it comes; and one held while sending is had at once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a picture not there yet is asked for again, not kept as missing', () async {
    var ready = false;
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      if (call.method != 'part') return null;
      asked++;
      return ready ? Uint8List.fromList([7, 7, 7]) : null;
    });
    expect(await Sms.instance.part(424242), isNull);
    await Future<void>.delayed(Duration.zero);
    ready = true;
    expect(await Sms.instance.part(424242), [7, 7, 7]);
    expect(asked, 2);
    // Once had, it is kept.
    expect(await Sms.instance.part(424242), [7, 7, 7]);
    expect(asked, 2);
  });

  test('a picture held while its message sends is had without asking the phone', () async {
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      asked++;
      return null;
    });
    Sms.instance.holdPart(-55, Future.value(Uint8List.fromList([1, 2])));
    expect(await Sms.instance.part(-55), [1, 2]);
    expect(asked, 0);
  });
}
