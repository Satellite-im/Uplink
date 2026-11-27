import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/thread.dart' show missingPill;

/// Matt, 2026-11-26: "some RCS images are just displaying as "attachment"". A message of Google Messages' whose
/// picture only its notification told of comes from the phone with what it was (`missing`, android Store.kt), and
/// its bubble says so, not "Attachment".
void main() {
  test('a picture the phone could not get says it is a picture', () {
    final m = Message.from({'id': 1, 'kind': 'rcs', 'address': '+15550100', 'body': '', 'date': 0, 'outgoing': false, 'state': 'received', 'parts': const [], 'missing': 'Picture'});
    expect(m.missing, 'Picture');
    expect(missingPill(m.missing!), 'Picture: open it in Google Messages to see it');
  });

  test('a message without one has none', () {
    final m = Message.from({'id': 2, 'kind': 'sms', 'address': '+15550100', 'body': 'hi', 'date': 0, 'outgoing': false, 'state': 'received'});
    expect(m.missing, isNull);
  });
}
