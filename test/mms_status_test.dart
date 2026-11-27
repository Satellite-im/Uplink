import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

/// What the app says of picture messages (Matt, 2026-11-13: "It seems like picture sending is also not working at
/// all almost like MMS isn't working"): what would stop one, and the report a person can copy.
void main() {
  test('nothing in the way says nothing', () {
    expect(MmsStatus.from(const {'dataOn': true, 'sim': true, 'allowed': true}).obstacle, isNull);
    // What Android would not say is not held against the phone.
    expect(MmsStatus.from(const {}).obstacle, isNull);
  });

  test('mobile data off, the carrier refusing, no SIM: each is said, the worst first', () {
    expect(MmsStatus.from(const {'dataOn': false, 'sim': true, 'allowed': true}).obstacle, contains('Mobile data is off'));
    expect(MmsStatus.from(const {'dataOn': false, 'sim': true, 'allowed': false}).obstacle, contains('carrier'));
    expect(MmsStatus.from(const {'dataOn': false, 'sim': false, 'allowed': false}).obstacle, contains('no SIM'));
  });

  test('the report has every line and nothing of anyone\'s messages', () {
    final s = MmsStatus.from({
      'dataOn': true, 'carrier': 'T-Mobile', 'sim': true, 'allowed': true, 'maxBytes': 1048576, 'waiting': 2,
      'lastSend': {'at': DateTime(2026, 11, 13, 19, 5).millisecondsSinceEpoch, 'ok': false, 'detail': 'the carrier\'s server refused it (HTTP 403), 294 KB'},
    });
    final report = s.report('0.6.2');
    expect(report, contains('Uplink 0.6.2'));
    expect(report, contains('Carrier: T-Mobile'));
    expect(report, contains('Mobile data: on'));
    expect(report, contains('Largest message: 1024 KB'));
    expect(report, contains('Last sent: failed: the carrier\'s server refused it (HTTP 403), 294 KB (2026-11-13 19:05)'));
    expect(report, contains('Last fetched: none yet'));
    expect(report, contains('Waiting to be fetched: 2'));
  });

  test('a failed picture message carries its reason', () {
    final m = Message.from({'id': 1, 'kind': 'mms', 'date': 0, 'outgoing': true, 'state': 'failed', 'why': 'mobile data is off'});
    expect(m.why, 'mobile data is off');
    expect(Message.from({'id': 2, 'kind': 'sms', 'date': 0}).why, isNull);
  });
}
