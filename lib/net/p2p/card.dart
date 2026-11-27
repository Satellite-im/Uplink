import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../crypto.dart';
import '../hub_carrier.dart' show NetSigner;
import 'node.dart' show isNodeId;

/// A device card (docs/OPEN_NETWORK.md, section 1): an account's word that a node id is one of its devices.
///
///     {"v":1, "a": account name, "k": account public key (33 bytes, base64), "d": device, "n": node id,
///      "t": made (ms), "x": good until (ms), "s": signature (r then s, base64)}
///
/// signed by the account's key over `"ghost-p2p card v1\n"` then `a (16) | d (16) | n (32) | t (8) | x (8)`, the two
/// times as whole numbers with their highest byte first.
///
/// Anyone can check one with nothing but the card ([fromJson]): the name is the key's, the signature is the key's, and
/// it has not run out. Whether the account is one this device links with is the direct network's to say (p2p.dart): a
/// card is taken only from a sealed envelope whose sender is the account it names.
///
/// A card is the account's word for the node, not the node's for the account: an account could name a node that is
/// not its own. So a card alone lets nothing through; the device at the other end of a stream proves whose it is
/// there (p2p_carrier.dart).
@immutable
class DeviceCard {
  const DeviceCard._({required this.account, required this.key, required this.device, required this.nodeId, required this.made, required this.until, required this.signature});

  static const version = 1;

  /// How long a card is good for, and how long before it runs out a device makes itself a new one.
  static const goodFor = Duration(days: 30);
  static const renewWith = Duration(days: 7);

  /// How far ahead of this device's clock a card's making may be: another device's clock is never quite this one's.
  static const ahead = Duration(days: 1);

  /// The most fields a card may have: what a newer build adds is passed over, but not without end.
  static const mostFields = 16;

  static final _words = utf8.encode('ghost-p2p card v1\n');
  static final _name = RegExp(r'^[0-9a-f]{32}$');

  /// The account's name: NetCrypto.idOf its key, 32 hex digits.
  final String account;

  /// The account's public key, 33 bytes.
  final Uint8List key;

  /// Which of the account's devices this is (`hub_device`), 32 hex digits.
  final String device;

  /// The device's node id on the direct network, 64 hex digits.
  final String nodeId;

  /// When it was made and until when it is good, in milliseconds.
  final int made;
  final int until;

  /// The account's signature over [signedBytes]: r then s, 64 bytes.
  final Uint8List signature;

  /// What the account's key signs.
  static Uint8List signedBytes({required String account, required String device, required String nodeId, required int made, required int until}) =>
      Uint8List.fromList([..._words, ...NetCrypto.unhex(account), ...NetCrypto.unhex(device), ...NetCrypto.unhex(nodeId), ..._eight(made), ..._eight(until)]);

  /// [n] as eight bytes, the highest first. In two halves: a browser has no 64-bit whole numbers.
  static Uint8List _eight(int n) => (ByteData(8)
        ..setUint32(0, n ~/ 0x100000000)
        ..setUint32(4, n % 0x100000000))
      .buffer
      .asUint8List();

  /// A card for [device] at [nodeId], signed by [signer]'s account now. On a phone the key never leaves the keystore:
  /// the signing is asked of it.
  static Future<DeviceCard> make(NetSigner signer, {required String device, required String nodeId, required DateTime now}) async {
    if (!_name.hasMatch(device)) throw ArgumentError('a device is named by 32 hex digits');
    if (!isNodeId(nodeId)) throw ArgumentError('a node id is 64 hex digits');
    final made = now.millisecondsSinceEpoch, until = made + goodFor.inMilliseconds;
    final account = signer.id;
    final signature = await signer.sign(signedBytes(account: account, device: device, nodeId: nodeId, made: made, until: until));
    final card = DeviceCard._(account: account, key: Uint8List.fromList(signer.publicKey), device: device, nodeId: nodeId, made: made, until: until, signature: Uint8List.fromList(signature));
    // What was just signed is checked as anyone else's would be: a signer that answers with something else is found
    // out here, not by every friend in turn.
    if (fromJson(card.toJson(), now: made) == null) throw StateError('the card could not be signed');
    return card;
  }

  Map<String, dynamic> toJson() => {'v': version, 'a': account, 'k': base64Encode(key), 'd': device, 'n': nodeId, 't': made, 'x': until, 's': base64Encode(signature)};

  /// The card [j] is, checked whole, or null: it comes from someone else's device. Every field is of its kind and its
  /// length, the name is the key's, the times are a card's (made before it runs out, good for no longer than
  /// [goodFor], not made further ahead than [ahead], not run out at [now]), and the signature is the key's.
  ///
  /// [known]: this device checked the signature when the card came and has kept the card since under a seal only it
  /// can make (P2p's kept cards): everything is checked again but the signature, which is arithmetic of some
  /// milliseconds that would otherwise be done for every card held at every start.
  static DeviceCard? fromJson(Object? j, {required int now, bool known = false}) {
    if (j is! Map || j.length > mostFields) return null;
    final v = j['v'], a = j['a'], k = j['k'], d = j['d'], n = j['n'], t = j['t'], x = j['x'], s = j['s'];
    if (v is! int || v != version) return null;
    if (a is! String || !_name.hasMatch(a) || d is! String || !_name.hasMatch(d) || !isNodeId(n)) return null;
    if (t is! int || x is! int || t <= 0 || x <= t || x - t > goodFor.inMilliseconds || t > now + ahead.inMilliseconds || x <= now) return null;
    // 33 bytes are 44 characters of base64, 64 are 88: nothing longer is even decoded.
    if (k is! String || k.length != 44 || s is! String || s.length != 88) return null;
    final Uint8List key, signature;
    try {
      key = base64Decode(k);
      signature = base64Decode(s);
    } catch (_) {
      return null;
    }
    if (key.length != 33 || (key[0] != 2 && key[0] != 3) || signature.length != 64) return null;
    if (NetCrypto.idOf(key) != a) return null;
    if (!known && !NetCrypto.verify(key, signedBytes(account: a, device: d, nodeId: n as String, made: t, until: x), signature)) return null;
    return DeviceCard._(account: a, key: key, device: d, nodeId: n as String, made: t, until: x, signature: signature);
  }

  /// Whether it is no longer good at [now] (ms).
  bool expired(int now) => until <= now;

  /// Whether a device holding this card should make itself a new one at [now]: a week or less is left, or its node id
  /// is no longer [nodeId] (or the card is another device's or another account's).
  bool due(int now, {required String nodeId, String? device, String? account}) =>
      nodeId != this.nodeId || (device != null && device != this.device) || (account != null && account != this.account) || until - now <= renewWith.inMilliseconds;

  /// A short name for this very card: which card a friend was told is kept by it.
  String get tag => NetCrypto.hex(NetCrypto.sha256(signature).sublist(0, 8));

  @override
  bool operator ==(Object other) =>
      other is DeviceCard && other.account == account && other.device == device && other.nodeId == nodeId && other.made == made && other.until == until && listEquals(other.key, key) && listEquals(other.signature, signature);

  @override
  int get hashCode => Object.hash(account, device, nodeId, made, until);

  @override
  String toString() => 'DeviceCard(${account.substring(0, 6)} device ${device.substring(0, 6)} node ${nodeId.substring(0, 6)})';
}
