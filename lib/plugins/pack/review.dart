/// The review's signatures (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review
/// process"): an approval binds a plugin's id, its version and its package's SHA-256 under the reviewer's hub key; a
/// revocation withdraws one package, with its reason signed too; a retirement is a review key saying, by its own
/// signature, that it is no longer to be trusted. The app checks an approval against the keys it pins
/// (review_keys.dart) when it installs a pack and every time it loads one.
///
/// Nothing here trusts the relay: a relay that is wrong, broken into or self-hosted can withhold plugins, withdrawals
/// and retirements, never make a plugin reviewed. This is the only file of the app that holds the words the review key
/// signs (test/pack_words_test.dart), so no other feature can become a way to have that key sign them.
library;

import 'dart:convert';

import '../../net/crypto.dart';
import '../../net/hub_carrier.dart' show NetSigner;
import 'format.dart' show packTextOk;
import 'review_keys.dart';

/// The exact words each signature is over, a line for each part. The first line names what is signed, so a signature
/// made for one of the three never passes for another. The relay checks the same words.
String approvalWords(String plugin, String version, String sha256) => 'ghost-market approve v1\n$plugin\n$version\n$sha256';
String revocationWords(String plugin, String sha256, int at, String why) => 'ghost-market revoke v1\n$plugin\n$sha256\n$at\n$why';
String retirementWords(String key) => 'ghost-market retire v1\n$key';

/// The reviewer's signature over one package of one plugin at one version: what lets a pack from the Marketplace
/// install, kept beside it (approval.json) and checked again at every load.
class PackApproval {
  const PackApproval({required this.plugin, required this.version, required this.sha256, required this.key, required this.sig, required this.at, this.v = 1});
  final int v;                 // 1
  final String plugin;         // the pack id, no x
  final String version;
  final String sha256;         // 64 lower-case hex
  final String key;            // base64 of the 33-byte compressed public key (44 characters)
  final String sig;            // base64 of the 64-byte r‖s ECDSA P-256 SHA-256 signature over utf8(approvalWords(...)) (88 characters)
  final int at;                // ms since the epoch; kept, not signed, and never shown (a relay could change it)

  /// FormatException for anything else. A shape that reads but doesn't hold ([v] not 1, a bad signature) is
  /// verifyApproval's to refuse.
  factory PackApproval.fromJson(Map j) {
    final (v, plugin, version, sha256, key, sig, at) = (j['v'], j['plugin'], j['version'], j['sha256'], j['key'], j['sig'], j['at']);
    if (v is! int || plugin is! String || version is! String || sha256 is! String || key is! String || sig is! String || at is! int) throw const FormatException('Not an approval');
    return PackApproval(plugin: plugin, version: version, sha256: sha256, key: key, sig: sig, at: at, v: v);
  }

  Map<String, Object?> toJson() => {'v': v, 'plugin': plugin, 'version': version, 'sha256': sha256, 'key': key, 'sig': sig, 'at': at};
}

/// The reviewer's signed withdrawal of one package of one plugin, with the reason: a device that holds it switches
/// that copy off and never installs it again.
class PackRevocation {
  const PackRevocation({required this.plugin, required this.sha256, required this.at, required this.why, required this.key, required this.sig, this.v = 1});
  final int v;
  final String plugin, sha256;
  final int at;                // ms; signed
  final String why;            // 1 to 200, packTextOk with no newline; signed, so the reason shown is the reviewer's own
  final String key, sig;       // sig over utf8(revocationWords(plugin, sha256, at, why))

  factory PackRevocation.fromJson(Map j) {
    final (v, plugin, sha256, at, why, key, sig) = (j['v'], j['plugin'], j['sha256'], j['at'], j['why'], j['key'], j['sig']);
    if (v is! int || plugin is! String || sha256 is! String || at is! int || why is! String || key is! String || sig is! String) throw const FormatException('Not a revocation');
    return PackRevocation(plugin: plugin, sha256: sha256, at: at, why: why, key: key, sig: sig, v: v);
  }

  Map<String, Object?> toJson() => {'v': v, 'plugin': plugin, 'sha256': sha256, 'at': at, 'why': why, 'key': key, 'sig': sig};
}

/// A review key saying, with its own signature, that it is no longer to be trusted: made now and kept offline, sent if
/// the key is ever lost or taken (G.4).
class PackRetirement {
  const PackRetirement({required this.key, required this.at, required this.sig, this.v = 1});
  final int v;                 // 1
  final String key;            // the review key it retires, base64 (44)
  final int at;                // ms; kept, not signed, never shown
  final String sig;            // by that key, over utf8(retirementWords(key))

  factory PackRetirement.fromJson(Map j) {
    final (v, key, at, sig) = (j['v'], j['key'], j['at'], j['sig']);
    if (v is! int || key is! String || at is! int || sig is! String) throw const FormatException('Not a retirement');
    return PackRetirement(key: key, at: at, sig: sig, v: v);
  }

  Map<String, Object?> toJson() => {'v': v, 'key': key, 'at': at, 'sig': sig};
}

/// Whether [publicKey] (33 bytes) is one this build trusts for reviews: in [keys], and not retired.
bool isReviewKey(List<int> publicKey, {List<String> keys = marketReviewKeys, Set<String> retired = const {}}) {
  final key = base64Encode(publicKey);
  return keys.contains(key) && !retired.contains(key);
}

/// Holds exactly when [a] is a version 1 approval of [plugin] at [version] with [sha256], by a key in [keys] that
/// isn't [retired], and its signature verifies over approvalWords.
bool verifyApproval(PackApproval a, {required String plugin, required String version, required String sha256, List<String> keys = marketReviewKeys, Set<String> retired = const {}}) =>
    a.v == 1 && a.plugin == plugin && a.version == version && a.sha256 == sha256 && keys.contains(a.key) && !retired.contains(a.key) && _signed(a.key, approvalWords(plugin, version, sha256), a.sig);

/// Holds when [r] is a version 1 revocation by a key in [keys] whose reason is 1 to 200 characters of one line and whose
/// signature verifies over revocationWords. A retired key's revocations still count: a revocation only ever takes
/// trust away, and refusing old ones after a retirement would bring withdrawn plugins back.
bool verifyRevocation(PackRevocation r, {List<String> keys = marketReviewKeys}) =>
    r.v == 1 && keys.contains(r.key) && r.why.isNotEmpty && r.why.length <= 200 && packTextOk(r.why) && _signed(r.key, revocationWords(r.plugin, r.sha256, r.at, r.why), r.sig);

/// Holds when [r] is a version 1 retirement signed by the key it retires. Only the key's holder can make one, which is
/// why anyone may send it; only a pinned key's is kept.
bool verifyRetirement(PackRetirement r) => r.v == 1 && _signed(r.key, retirementWords(r.key), r.sig);

// [sig] (base64, r then s) is [key]'s (base64, 33 bytes) over [words]: anything that isn't base64, or isn't a key or a
// signature at all, doesn't verify.
bool _signed(String key, String words, String sig) {
  try {
    return NetCrypto.verify(base64Decode(key), utf8.encode(words), base64Decode(sig));
  } catch (_) {
    return false;
  }
}

/// The reviewer's approval of [plugin] at [version] with [sha256], by [signer]: the hub key of the device reviewing,
/// the same that signs the request it goes in (the relay wants the two to be one).
Future<PackApproval> signApproval(NetSigner signer, {required String plugin, required String version, required String sha256, DateTime? at}) async {
  final sig = await signer.sign(utf8.encode(approvalWords(plugin, version, sha256)));
  return PackApproval(plugin: plugin, version: version, sha256: sha256, key: base64Encode(signer.publicKey), sig: base64Encode(sig), at: (at ?? DateTime.now()).millisecondsSinceEpoch);
}

/// [signer]'s withdrawal of the package [sha256] of [plugin], its reason [why] signed with it, as the time is.
Future<PackRevocation> signRevocation(NetSigner signer, {required String plugin, required String sha256, required String why, DateTime? at}) async {
  final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
  final sig = await signer.sign(utf8.encode(revocationWords(plugin, sha256, ms, why)));
  return PackRevocation(plugin: plugin, sha256: sha256, at: ms, why: why, key: base64Encode(signer.publicKey), sig: base64Encode(sig));
}

/// [signer]'s own key retiring itself: made as soon as the key is pinned and kept offline (G.4), sent only if the key
/// is ever lost or taken.
Future<PackRetirement> signRetirement(NetSigner signer, {DateTime? at}) async {
  final key = base64Encode(signer.publicKey);
  final sig = await signer.sign(utf8.encode(retirementWords(key)));
  return PackRetirement(key: key, at: (at ?? DateTime.now()).millisecondsSinceEpoch, sig: base64Encode(sig));
}
