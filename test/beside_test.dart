import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

/// Uplink beside Google Messages (android GmBridge.kt; Matt, 2026-11-15: "I'd like to have a way that people can
/// reliably get text in and out of ghost without needing to switch the default messaging app"): when the app runs.
void main() {
  SmsStatus said(Map<String, Object> m) => SmsStatus.from({'contacts': true, 'notifications': true, 'phone': true, ...m});

  test('the default SMS app runs, beside Google Messages or not', () {
    final s = said({'isDefault': true});
    expect(s.usable, isTrue);
    expect(s.beside, isFalse, reason: 'the default is never "beside"');
  });

  test('beside Google Messages needs both: texts allowed and notification access', () {
    expect(said({'isDefault': false, 'sms': true, 'bridge': true}).beside, isTrue);
    expect(said({'isDefault': false, 'sms': true, 'bridge': true}).usable, isTrue);
    expect(said({'isDefault': false, 'sms': true, 'bridge': false}).usable, isFalse, reason: 'no RCS without notification access');
    expect(said({'isDefault': false, 'sms': false, 'bridge': true}).usable, isFalse, reason: 'no texts without the SMS permissions');
  });

  test('an older phone half that says nothing of the bridge is read as not beside', () {
    final s = said({'isDefault': false});
    expect(s.gmInstalled, isFalse);
    expect(s.usable, isFalse);
  });
}
