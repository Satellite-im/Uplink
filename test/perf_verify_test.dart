import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/roles.dart';

/// docs/performance-audit.md, finding 7: a grant's signature is checked once, however often a screen asks of it.
void main() {
  test('a signature\'s check is remembered for the same key, message and signature, and not for another', () {
    final keys = NetKeys.generate();
    final message = utf8.encode('ghost-test|hello');
    final sig = NetCrypto.sign(keys, message);
    final before = NetCrypto.verifications;
    for (var i = 0; i < 50; i++) {
      expect(NetCrypto.verifyOnce(keys.public, message, sig), isTrue);
    }
    expect(NetCrypto.verifications - before, 1, reason: 'fifty askings, one check');
    // Another message under the same signature is its own question, and is no.
    expect(NetCrypto.verifyOnce(keys.public, utf8.encode('ghost-test|other'), sig), isFalse);
    // A signature someone else made is no, however often asked.
    final other = NetCrypto.sign(NetKeys.generate(), message);
    expect(NetCrypto.verifyOnce(keys.public, message, other), isFalse);
    expect(NetCrypto.verifyOnce(keys.public, message, other), isFalse);
    expect(NetCrypto.verifications - before, 3);
  });

  test('asking a roster who is an admin, row after row, checks the owner\'s grant once', () {
    final owner = NetKeys.generate(), admin = NetKeys.generate();
    final ownerHex = NetCrypto.hex(owner.public);
    final adminId = NetCrypto.idOf(admin.public);
    final grant = NetCrypto.hex(NetCrypto.sign(owner, Roster.grantMessage(ownerHex, adminId)));
    final roster = Roster(owner: ownerHex, roles: Role.defaults, assigned: {adminId: Role.admin}, adminGrants: {adminId: grant});
    final before = NetCrypto.verifications;
    for (var i = 0; i < 200; i++) {
      expect(roster.roleOf(adminId).id, Role.admin);
    }
    expect(NetCrypto.verifications - before, lessThanOrEqualTo(1));
    // A grant not the owner's is no admin.
    final forged = Roster(owner: ownerHex, roles: Role.defaults, assigned: {adminId: Role.admin}, adminGrants: {adminId: NetCrypto.hex(NetCrypto.sign(admin, Roster.grantMessage(ownerHex, adminId)))});
    expect(forged.roleOf(adminId).id, isNot(Role.admin));
  });
}
