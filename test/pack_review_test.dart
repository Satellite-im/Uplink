import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';

/// The review's signatures (lib/plugins/pack/review.dart; Matt, 2026-11-20: "I'd like to be able to verify them for the
/// store through a review process"): the words each signs, signing and checking with a key made for the test, every
/// way an approval, a withdrawal or a retirement can be wrong, and the keys and lists this build ships with.
void main() {
  const sha = '5c07c72f99f594ea3538046d4144515ed99756e9816b614a77a513c6afd562e7';
  final reviewer = KeysSigner(NetKeys.generate());
  final key = base64Encode(reviewer.publicKey);
  final keys = [key];

  test('the words each signs, exactly', () {
    expect(approvalWords('bills', '1.0.0', sha), 'ghost-market approve v1\nbills\n1.0.0\n$sha');
    final revoke = revocationWords('bills', sha, 1763600000000, 'It sorted contacts\' texts.');
    expect(revoke.split('\n'), ['ghost-market revoke v1', 'bills', sha, '1763600000000', 'It sorted contacts\' texts.']);
    expect(retirementWords(key).split('\n'), ['ghost-market retire v1', key]);
  });

  group('an approval', () {
    test('signed verifies, and its shape is what the relay and the cache keep', () async {
      final a = await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha, at: DateTime.fromMillisecondsSinceEpoch(1763600000000));
      expect(a.key, key);
      expect(a.key, hasLength(44));
      expect(a.sig, hasLength(88));
      expect(a.at, 1763600000000);
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isTrue);
      final back = PackApproval.fromJson(jsonDecode(jsonEncode(a.toJson())) as Map);
      expect(back.toJson(), a.toJson());
      expect(verifyApproval(back, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isTrue);
      expect(a.toJson().keys, ['v', 'plugin', 'version', 'sha256', 'key', 'sig', 'at']);
    });

    test('a wrong plugin, version, SHA-256, key or signature fails', () async {
      final a = await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha);
      expect(verifyApproval(a, plugin: 'parcels', version: '1.0.0', sha256: sha, keys: keys), isFalse);
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.1', sha256: sha, keys: keys), isFalse);
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.0', sha256: sha.replaceFirst('5c', '5d'), keys: keys), isFalse);
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.0', sha256: sha, keys: [base64Encode(NetKeys.generate().public)]), isFalse, reason: 'its key isn\'t pinned');
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.0', sha256: sha), isFalse, reason: 'this build pins no key yet');
      final other = KeysSigner(NetKeys.generate());
      final forged = PackApproval(plugin: 'bills', version: '1.0.0', sha256: sha, key: key, sig: base64Encode(await other.sign(utf8.encode(approvalWords('bills', '1.0.0', sha)))), at: 0);
      expect(verifyApproval(forged, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isFalse, reason: 'signed by another key than it names');
      final tampered = PackApproval(plugin: a.plugin, version: a.version, sha256: a.sha256, key: a.key, sig: base64Encode(base64Decode(a.sig)..[10] ^= 1), at: a.at);
      expect(verifyApproval(tampered, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isFalse);
      final v2 = PackApproval(plugin: a.plugin, version: a.version, sha256: a.sha256, key: a.key, sig: a.sig, at: a.at, v: 2);
      expect(verifyApproval(v2, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isFalse);
      final junk = PackApproval(plugin: a.plugin, version: a.version, sha256: a.sha256, key: 'not base64!', sig: '???', at: a.at);
      expect(verifyApproval(junk, plugin: 'bills', version: '1.0.0', sha256: sha, keys: ['not base64!']), isFalse);
    });

    test('the "at" is kept, not signed: changing it changes nothing', () async {
      final a = await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha);
      final later = PackApproval(plugin: a.plugin, version: a.version, sha256: a.sha256, key: a.key, sig: a.sig, at: a.at + 99999);
      expect(verifyApproval(later, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys), isTrue);
    });

    test('a shape that isn\'t one is a FormatException', () {
      expect(() => PackApproval.fromJson(const {'v': 1, 'plugin': 'bills'}), throwsFormatException);
      expect(() => PackApproval.fromJson(const {'v': '1', 'plugin': 'bills', 'version': '1.0.0', 'sha256': sha, 'key': 'k', 'sig': 's', 'at': 1}), throwsFormatException);
    });
  });

  group('a retired key', () {
    test('its approvals fail, and its withdrawals still count', () async {
      final a = await signApproval(reviewer, plugin: 'bills', version: '1.0.0', sha256: sha);
      final r = await signRevocation(reviewer, plugin: 'bills', sha256: sha, why: 'It sorted contacts\' texts.');
      final retired = {key};
      expect(verifyApproval(a, plugin: 'bills', version: '1.0.0', sha256: sha, keys: keys, retired: retired), isFalse);
      expect(verifyRevocation(r, keys: keys), isTrue, reason: 'a revocation only takes trust away');
      expect(isReviewKey(reviewer.publicKey, keys: keys), isTrue);
      expect(isReviewKey(reviewer.publicKey, keys: keys, retired: retired), isFalse);
      expect(isReviewKey(NetKeys.generate().public, keys: keys), isFalse);
    });
  });

  group('a revocation', () {
    test('signed verifies, its reason and time signed with it', () async {
      final r = await signRevocation(reviewer, plugin: 'bills', sha256: sha, why: 'It sorted contacts\' texts.', at: DateTime.fromMillisecondsSinceEpoch(1763600000000));
      expect(r.at, 1763600000000);
      expect(verifyRevocation(r, keys: keys), isTrue);
      expect(PackRevocation.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map).toJson(), r.toJson());
      expect(r.toJson().keys, ['v', 'plugin', 'sha256', 'at', 'why', 'key', 'sig']);
    });

    test('a changed reason, time, package or key fails, and so does a reason a pack couldn\'t hold', () async {
      final r = await signRevocation(reviewer, plugin: 'bills', sha256: sha, why: 'It sorted contacts\' texts.');
      PackRevocation edited({String? why, int? at, String? sha256, String? plugin}) => PackRevocation(plugin: plugin ?? r.plugin, sha256: sha256 ?? r.sha256, at: at ?? r.at, why: why ?? r.why, key: r.key, sig: r.sig);
      expect(verifyRevocation(edited(why: 'It was fine.'), keys: keys), isFalse);
      expect(verifyRevocation(edited(at: r.at + 1), keys: keys), isFalse);
      expect(verifyRevocation(edited(sha256: sha.replaceFirst('5c', '5d')), keys: keys), isFalse);
      expect(verifyRevocation(edited(plugin: 'parcels'), keys: keys), isFalse);
      expect(verifyRevocation(r, keys: [base64Encode(NetKeys.generate().public)]), isFalse);
      expect(verifyRevocation(r), isFalse, reason: 'this build pins no key yet');
      for (final why in ['', 'a' * 201, 'two\nlines', 'hidden\u200Bwords']) {
        final bad = await signRevocation(reviewer, plugin: 'bills', sha256: sha, why: why);
        expect(verifyRevocation(bad, keys: keys), isFalse, reason: why);
      }
      expect(verifyRevocation(await signRevocation(reviewer, plugin: 'bills', sha256: sha, why: 'a' * 200), keys: keys), isTrue);
    });
  });

  group('a retirement', () {
    test('by the key it retires verifies; by another key it doesn\'t', () async {
      final t = await signRetirement(reviewer, at: DateTime.fromMillisecondsSinceEpoch(5));
      expect(t.key, key);
      expect(t.at, 5);
      expect(verifyRetirement(t), isTrue);
      expect(t.toJson().keys, ['v', 'key', 'at', 'sig']);
      expect(PackRetirement.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map).toJson(), t.toJson());
      final other = KeysSigner(NetKeys.generate());
      final byAnother = PackRetirement(key: key, at: 5, sig: base64Encode(await other.sign(utf8.encode(retirementWords(key)))));
      expect(verifyRetirement(byAnother), isFalse);
      final ofAnother = PackRetirement(key: base64Encode(other.publicKey), at: 5, sig: t.sig);
      expect(verifyRetirement(ofAnother), isFalse);
      expect(verifyRetirement(PackRetirement(key: t.key, at: t.at, sig: t.sig, v: 2)), isFalse);
    });
  });

  test('every pinned review key is a 33-byte compressed P-256 key, in 44 characters of base64', () {
    for (final k in marketReviewKeys) {
      expect(k, hasLength(44));
      final bytes = base64Decode(k);
      expect(bytes, hasLength(33));
      expect(bytes.first, anyOf(2, 3));
    }
  });

  test('every withdrawal and retirement this build ships verifies', () {
    for (final r in shippedRevocations) {
      expect(verifyRevocation(PackRevocation.fromJson(r)), isTrue, reason: '$r');
    }
    for (final r in shippedRetirements) {
      final t = PackRetirement.fromJson(r);
      expect(verifyRetirement(t), isTrue, reason: '$r');
      expect(marketReviewKeys, contains(t.key), reason: 'only a pinned key\'s retirement means anything');
    }
  });
}
