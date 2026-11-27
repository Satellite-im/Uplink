import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Human check (GMFB-23) works only where a start-up path makes it: the phone's did, the computer's did not, so on
/// a Mac, Windows or Linux nobody new was ever held or asked its question (Matt, 2026-11-23: "the bots are still
/// messaging me without being asked the riddle"). Every path that starts the other networks starts it too, after them.
void main() {
  for (final f in ['lib/main.dart', 'lib/desktop/main.dart']) {
    test('$f starts the Human check after it starts the networks', () {
      final src = File(f).readAsStringSync();
      final networks = src.indexOf('Inbox.instance.start(');
      final check = src.indexOf('startHumanCheck(');
      expect(networks, greaterThan(-1), reason: '$f starts the networks');
      expect(check, greaterThan(networks), reason: '$f must call startHumanCheck after Inbox.instance.start');
    });
  }
}
