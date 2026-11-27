import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/roles.dart';

/// The browser checks rosters the app signs (site/join/voice.js Roster.trusted): this writes a few, signed here, for
/// tool/voicebench/roster_check.mjs to check there (it runs this first).
void main() {
  test('signed rosters for the browser to check', () async {
    final owner = NetKeys.generate(), admin = NetKeys.generate(), other = NetKeys.generate();
    final ownerKey = NetCrypto.hex(owner.public);
    Future<Roster> sign(Roster r, NetKeys k) => r.signedBy(k.id, k.public, (m) async => NetCrypto.sign(k, m));
    final grant = NetCrypto.hex(NetCrypto.sign(owner, Roster.grantMessage(ownerKey, admin.id)));
    final first = await sign(Roster.first(ownerKey).next(assigned: {other.id: Role.moderator, admin.id: Role.admin}, adminGrants: {admin.id: grant}, muted: {other.id}), owner);
    final byAdmin = await sign(first.next(roles: [...first.ranked, const Role(id: 'dj', name: 'DJ — ünï', rank: 15, perms: {Perm.chat, Perm.speak})], newcomer: 'dj'), admin);
    // A role coloured (Matt, 2026-11-17: "assign role colors like discord does"): the browser checks it too.
    final coloured = await sign(byAdmin.next(roles: [for (final r in byAdmin.ranked) r.id == 'dj' ? r.copyWith(color: '#e91e63') : r]), admin);
    final forged = await sign(first.next(assigned: {other.id: Role.admin}), other);
    expect(first.trustedFor(ownerKey) && byAdmin.trustedFor(ownerKey) && coloured.trustedFor(ownerKey) && !forged.trustedFor(ownerKey), isTrue);
    File('build/rosters.json').writeAsStringSync(jsonEncode({
      'owner': ownerKey,
      'other': other.id,
      'good': [first.toJson(), byAdmin.toJson(), coloured.toJson()],
      'bad': [forged.toJson(), {...first.toJson(), 'v': 9}],
    }));
  });
}
