import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/roles.dart';

/// Role colours (Matt, 2026-11-17: "Don't show the badges for owner moderator etc, instead assign role colors like
/// discord does and for the owner just show a singlular crown icon"): kept in the signed roster, written only where
/// chosen.
void main() {
  final owner = NetKeys.generate();
  final ownerHex = NetCrypto.hex(owner.public);
  Future<Roster> sign(Roster r) => r.signedBy(owner.id, owner.public, (m) async => NetCrypto.sign(owner, m));

  test('defaults: admins red, moderators blue, members the text\'s own', () {
    final roles = {for (final r in Role.defaults) r.id: r};
    expect(roles[Role.admin]!.shownColor, '#e74c3c');
    expect(roles[Role.moderator]!.shownColor, '#3498db');
    expect(roles[Role.member]!.shownColor, isNull);
  });

  test('a roster nobody coloured is written as before; a chosen colour is signed, kept and read back', () async {
    final first = await sign(Roster.first(ownerHex));
    for (final r in (jsonDecode(jsonEncode(first.toJson())) as Map)['roles'] as List) {
      expect((r as Map).containsKey('c'), isFalse, reason: 'no colour chosen, nothing new on the wire');
    }
    final coloured = await sign(first.next(roles: [for (final r in first.ranked) r.id == Role.member ? r.copyWith(color: '#9b59b6') : r]));
    expect(coloured.trustedFor(ownerHex), isTrue);
    final back = Roster.fromJson(jsonDecode(jsonEncode(coloured.toJson())))!;
    expect(back.trustedFor(ownerHex), isTrue, reason: 'read back, it still checks');
    expect(back.roleById(Role.member)!.shownColor, '#9b59b6');
    final cleared = back.roleById(Role.member)!.copyWith(noColor: true);
    expect(cleared.color, isNull);
  });

  test('what a newer build writes on a role is kept and written back', () {
    final r = Role.fromJson({'id': 'x', 'n': 'Crew', 'p': ['speak'], 'r': 12, 'c': '#E91E63', 'icon': 'star'})!;
    expect(r.color, '#e91e63');
    expect(r.toJson()['icon'], 'star');
    expect(Role.fromJson({'id': 'x', 'n': 'Crew', 'p': [], 'r': 12, 'c': 'red'})!.color, isNull, reason: 'only #rrggbb');
  });
}
