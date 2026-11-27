import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/actions.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// Quick actions (lib/plugins/actions.dart; Matt, 2026-11-14: "a time becomes Add to calendar, an address Open in
/// Maps, a tracking number a live status, a code is copied").
void main() {
  // Saturday 14 November 2026, 10:00.
  final now = DateTime(2026, 11, 14, 10);

  test('a day and a time, the ways people write them', () {
    expect(whenIn('see you tomorrow at 9:30am', now), (at: DateTime(2026, 11, 15, 9, 30), allDay: false));
    expect(whenIn('dinner Friday at 7', now), (at: DateTime(2026, 11, 20, 19), allDay: false));
    expect(whenIn('Your appointment is Nov 20 at 2:15 pm', now), (at: DateTime(2026, 11, 20, 14, 15), allDay: false));
    expect(whenIn('party on 12/5', now), (at: DateTime(2026, 12, 5), allDay: true));
    expect(whenIn('tonight at 8?', now), (at: DateTime(2026, 11, 14, 20), allDay: false));
    expect(whenIn('call me at 7pm', now), (at: DateTime(2026, 11, 14, 19), allDay: false));
    expect(whenIn('it was 9am, now it is gone', now), (at: DateTime(2026, 11, 15, 9), allDay: false), reason: 'a time gone today is tomorrow\'s');
    expect(whenIn('Jan 3 works', now)!.at, DateTime(2027, 1, 3), reason: 'a day long gone this year is next year\'s');
    // Not a day or a time.
    expect(whenIn('I have 3 cats and 2 dogs', now), isNull);
    expect(whenIn('Sounds good, see you', now), isNull);
    expect(whenIn('Your code is 482913', now), isNull);
  });

  test('an address, a tracking number, a phone number', () {
    expect(addressIn('Come to 1647 Winston Ct, Mundelein IL 60060 at 7'), '1647 Winston Ct, Mundelein IL 60060');
    expect(addressIn('meet at 3916 Shakespeare Dr.'), '3916 Shakespeare Dr');
    expect(addressIn('I walked 5 miles today'), isNull);
    expect(trackingIn('UPS 1Z999AA10123456784 is on its way')!.url, contains('1Z999AA10123456784'));
    expect(trackingIn('USPS 9405530109355231484225 delivered')!.carrier, 'USPS');
    expect(trackingIn('FedEx: we have your package 797218326615')!.carrier, 'FedEx');
    expect(trackingIn('order 797218326615 shipped'), isNull, reason: 'twelve digits are FedEx only where the text says so');
    expect(numberIn('Call us at (980) 729-8788 if you need help'), '(980) 729-8788');
  });

  test('the buttons a message gets, and none for everyday words', () {
    final a = actionsIn('Dinner Friday at 7 at 1647 Winston Ct. Call 980-729-8788 if lost', now);
    expect([for (final x in a) x.kind], ['event', 'map', 'call']);
    expect(a.first.label, 'Fri 7 PM');
    expect([for (final x in actionsIn('Your code is 482913', now)) x.label], ['Copy 482913']);
    expect(actionsIn('haha that is so funny', now), isEmpty);
    expect(actionsIn('Movie night is still on for tonight right?', now), isEmpty, reason: 'today with no time is no calendar entry');
    expect(shippedPlugins.whereType<ActionsPlugin>(), hasLength(1));
  });
}
