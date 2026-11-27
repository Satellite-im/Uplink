import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/names.dart';
import 'package:ghost_messaging/voice/hangout.dart';

/// Names with no "@" in front (lib/names.dart; Matt, 2026-11-19: "Some users have @ prefixes and others don't find out
/// what's causing this and normalize things so we don't have the @ prefix before names on the platform"): someone
/// with no display name went by "@username".
void main() {
  test('a name loses any "@" in front of it, and nothing else', () {
    expect(bareName('@maya'), 'maya');
    expect(bareName('  @@maya '), 'maya');
    expect(bareName('Maya Chen'), 'Maya Chen');
    expect(bareName('maya@home'), 'maya@home');
    expect(bareName('@'), '');
    expect(bareName(''), '');
  });

  test('a friend with no name goes by their username, without the "@"', () {
    expect(const Buddy(username: 'maya', id: 'a', key: 'k').shown, 'maya');
    expect(const Buddy(username: 'maya', id: 'a', key: 'k', name: 'Maya Chen').shown, 'Maya Chen');
  });

  test('a space\'s message from a build that still says "@username" reads as the name', () {
    expect(HangoutMessage.fromJson({'id': 'a', 'x': 'hi', 'at': 1, 'n': '@maya'}, 'f')!.name, 'maya');
    expect(HangoutMessage.fromJson({'id': 'a', 'x': 'hi', 'at': 1, 'n': 'Maya Chen'}, 'f')!.name, 'Maya Chen');
  });
}
