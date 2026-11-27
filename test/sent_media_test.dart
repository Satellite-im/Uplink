import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

/// A picture you send is written as a part first and its bytes after; read in between, it comes back empty. Matt,
/// 2026-11-19: "when I'm sending pictures and voice messages sometimes I don't see my outbound messages just the
/// delivered tag". Empty bytes were kept for as long as the app was open, and the picture drew as nothing.
class _Phone implements SmsCalls {
  final answers = <Uint8List?>[];
  var asked = 0;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method != 'part') return null;
    asked++;
    return (answers.isEmpty ? null : answers.removeAt(0)) as T?;
  }
}

void main() {
  test('empty bytes are not a picture: answered as not there, and asked for again', () async {
    final phone = _Phone()..answers.addAll([Uint8List(0), Uint8List.fromList([1, 2, 3])]);
    Sms.calls = phone;
    expect(await Sms.instance.part(9001), isNull);
    expect(await Sms.instance.part(9001), [1, 2, 3], reason: 'asked again, not the empty answer kept');
    expect(phone.asked, 2);
    // Once had, it is kept.
    expect(await Sms.instance.part(9001), [1, 2, 3]);
    expect(phone.asked, 2);
  });
}
