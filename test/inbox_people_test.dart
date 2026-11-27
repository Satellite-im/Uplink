import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/people.dart';

/// People put together from the phone's contacts and Telegram's and Signal's (lib/inbox/people.dart; Matt, 2026-11-16:
/// "Show telegram and signal contacts when linked with icons to show which each is and filters, where contacts can be
/// messages on multiple platforms as which you like to use when stating a conversation").
void main() {
  InboxContact tg(String id, String name, {String? number, String? handle}) => InboxContact(network: 'telegram', id: id, name: name, number: number, handle: handle);
  InboxContact sg(String id, String name, {String? number}) => InboxContact(network: 'signal', id: id, name: name, number: number);

  test('one person on the phone, Telegram and Signal is one row, reachable three ways', () {
    final people = gather(
      [const PhoneContact(address: '(555) 123-0001', name: 'Maya Chen', label: 'Mobile')],
      [tg('11', 'Maya C', number: '+15551230001'), sg('aci-1', 'Maya', number: '+1 555 123 0001')],
    );
    expect(people, hasLength(1));
    final maya = people.single;
    expect(maya.name, 'Maya Chen', reason: 'the phone\'s name for them wins');
    expect([for (final r in maya.reaches) r.kind], ['phone', 'telegram', 'signal']);
    expect(maya.inPhone, isTrue);
  });

  test('a network contact with no number joins the phone contact of the same full name', () {
    final people = gather([const PhoneContact(address: '+15550001111', name: 'Jo Park')], [tg('7', 'jo park', handle: '@jopark')]);
    expect(people, hasLength(1));
    expect(people.single.kinds, {'phone', 'telegram'});
  });

  test('names are not guessed between: a single name, two of the same name, or two different numbers', () {
    // A one-word name is too common to match on.
    expect(gather([const PhoneContact(address: '+15550001111', name: 'Dad')], [tg('1', 'Dad')]), hasLength(2));
    // Two phone contacts called Sam Rivera: the Telegram one is its own row.
    expect(
      gather([const PhoneContact(address: '+15550002222', name: 'Sam Rivera'), const PhoneContact(address: '+15550003333', name: 'Sam Rivera')], [tg('2', 'Sam Rivera')]),
      hasLength(3),
    );
    // Same name, different numbers: two people.
    expect(gather([const PhoneContact(address: '+15550004444', name: 'Alex Kim')], [sg('a', 'Alex Kim', number: '+15559999999')]), hasLength(2));
  });

  test('someone only on Telegram and Signal, matched by number, can be texted at that number too', () {
    final people = gather(const [], [tg('5', 'Riley Fox', number: '+447700900123'), sg('b', 'Riley', number: '+44 7700 900123')]);
    expect(people, hasLength(1));
    expect([for (final r in people.single.reaches) r.kind], ['phone', 'telegram', 'signal']);
    expect(people.single.reaches.first.address, '+447700900123');
    expect(people.single.inPhone, isFalse);
  });

  test('the phone\'s order is kept, then the rest by name; friends stay friends', () {
    final people = gather(
      [const PhoneContact(address: '+15550000002', name: 'Zed Last', friend: true), const PhoneContact(address: '+15550000001', name: 'Amy First')],
      [tg('9', 'Bea Telegram'), sg('c', 'Al Signal')],
    );
    expect([for (final s in people) s.name], ['Zed Last', 'Amy First', 'Al Signal', 'Bea Telegram']);
    expect(people.first.friend, isTrue);
  });

  test('filters: everyone, the phone\'s, or one network\'s', () {
    final people = gather(
      [const PhoneContact(address: '+15550000001', name: 'Amy First')],
      [tg('1', 'Amy First', number: '+15550000001'), tg('2', 'Bea Telegram'), sg('s', 'Cy Signal')],
    );
    expect([for (final s in narrowed(people, 'all')) s.name], ['Amy First', 'Bea Telegram', 'Cy Signal']);
    expect([for (final s in narrowed(people, 'phone')) s.name], ['Amy First']);
    expect([for (final s in narrowed(people, 'telegram')) s.name], ['Amy First', 'Bea Telegram']);
    expect([for (final s in narrowed(people, 'signal')) s.name], ['Cy Signal']);
  });

  test('search finds by name, number or handle', () {
    final s = gather(const [], [tg('1', 'Jo Park', number: '+15551234567', handle: '@jopark')]).single;
    expect(answers(s, 'jo'), isTrue);
    expect(answers(s, '1234'), isTrue);
    expect(answers(s, '@jopark'), isTrue);
    expect(answers(s, 'jopark'), isTrue);
    expect(answers(s, 'maya'), isFalse);
  });

  test('a friend by username is written to on Uplink by it (Matt, 2026-11-19: "the message with isn\'t working")', () {
    final phil = gather([const PhoneContact(address: '@phil_test', name: 'philtestaccount', friend: true)], const []).single;
    expect([for (final r in phil.reaches) r.address], ['@phil_test'], reason: 'one way, so a press opens the chat');
    // Someone not a friend whose "number" has no digits is still not something to text.
    expect(gather([const PhoneContact(address: 'Unknown', name: 'Odd')], const []).single.reaches, isEmpty);
  });
}
