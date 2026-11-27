import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/p2p/card.dart';
import 'package:ghost_relay/p256.dart';

/// The device card (lib/net/p2p/card.dart; docs/OPEN_NETWORK.md, section 1): an account's signed word that a node id
/// is one of its devices. Made through a signer, checked with nothing but the card, and refused whenever a single
/// thing about it is not as it was signed.

const _device = '000102030405060708090a0b0c0d0e0f';
const _node = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';
const _made = 1795000000000;
final _at = DateTime.fromMillisecondsSinceEpoch(_made);
const _day = 24 * 60 * 60 * 1000;

/// The account every test here signs as: the fixed key test/net_test.dart holds to the phone's Kotlin.
NetKeys _keys() => NetKeys.fromScalar(List.generate(32, (i) => i + 1));

/// A signer that counts what it is asked, as a phone's keystore would be asked.
class _Counting implements NetSigner {
  _Counting(this.keys);
  final NetKeys keys;
  final asked = <List<int>>[];
  @override
  String get id => keys.id;
  @override
  Uint8List get publicKey => keys.public;
  @override
  Future<Uint8List> sign(List<int> message) async {
    asked.add(List.of(message));
    return NetCrypto.sign(keys, message);
  }
}

/// A signer whose answers are not its key's.
class _Broken extends _Counting {
  _Broken(super.keys);
  @override
  Future<Uint8List> sign(List<int> message) async => Uint8List(64);
}

Future<DeviceCard> _card({NetKeys? keys, String device = _device, String node = _node, DateTime? now}) => DeviceCard.make(KeysSigner(keys ?? _keys()), device: device, nodeId: node, now: now ?? _at);

void main() {
  test('what is signed is held to fixed bytes: the words, then the account, the device, the node id and the two times', () async {
    final keys = _keys();
    expect(keys.id, 'd284f0626fd0836ce4b1731793fa6905');
    final bytes = DeviceCard.signedBytes(account: keys.id, device: _device, nodeId: _node, made: _made, until: _made + 30 * _day);
    // Worked out apart from this code: "ghost-p2p card v1\n", a (16), d (16), n (32), t (8), x (8), highest byte first.
    expect(
      NetCrypto.hex(bytes),
      '67686f73742d70327020636172642076310a'
      'd284f0626fd0836ce4b1731793fa6905'
      '000102030405060708090a0b0c0d0e0f'
      '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0'
      '000001a1ee565e00'
      '000001a288d52600',
    );
    expect(utf8.decode(bytes.sublist(0, 18)), 'ghost-p2p card v1\n');
    expect(bytes, hasLength(18 + 16 + 16 + 32 + 8 + 8));
    // And it is those bytes the signer was asked to sign, once.
    final signer = _Counting(keys);
    final card = await DeviceCard.make(signer, device: _device, nodeId: _node, now: _at);
    expect(signer.asked, [bytes]);
    // The relay's own arithmetic takes the signature too: nothing here checks itself alone.
    expect(P256.verify(keys.public, bytes, card.signature), isTrue);
    expect(P256.verify(keys.public, Uint8List.fromList(bytes)..[20] ^= 1, card.signature), isFalse);
  });

  test('a card goes into JSON and comes back the same, and is checked with nothing but itself', () async {
    final card = await _card();
    final json = card.toJson();
    expect(json.keys, ['v', 'a', 'k', 'd', 'n', 't', 'x', 's']);
    expect([json['v'], json['a'], json['d'], json['n'], json['t'], json['x']], [1, _keys().id, _device, _node, _made, _made + 30 * _day]);
    expect(base64Decode(json['k'] as String), _keys().public);
    expect(base64Decode(json['s'] as String), hasLength(64));
    // Through text, as it crosses in an envelope.
    final back = DeviceCard.fromJson(jsonDecode(jsonEncode(json)), now: _made + 1000);
    expect(back, card);
    expect([back!.account, back.device, back.nodeId, back.made, back.until], [_keys().id, _device, _node, _made, _made + 30 * _day]);
    expect(back.key, _keys().public);
    expect(back.tag, card.tag);
    expect(card.tag, hasLength(16));
    // A field a newer build adds is passed over.
    expect(DeviceCard.fromJson({...json, 'later': 'something new'}, now: _made), card);
  });

  test('every field changed is refused, whatever it is changed to', () async {
    final card = await _card();
    final good = card.toJson();
    final other = NetKeys.generate();
    DeviceCard? read(Map<String, dynamic> j) => DeviceCard.fromJson(jsonDecode(jsonEncode(j)), now: _made + 1000);
    expect(read(good), isNotNull, reason: 'as it was made, it is taken');

    String flipped(String hex) => '${hex.substring(0, hex.length - 1)}${hex.endsWith('0') ? '1' : '0'}';
    final sig = base64Decode(good['s'] as String);
    final tampered = <String, Object?>{
      // Another version, or none.
      'v: 2': {...good, 'v': 2},
      'v: "1"': {...good, 'v': '1'},
      'v: 1.5': {...good, 'v': 1.5},
      'no v': {...good}..remove('v'),
      // Another account's name on this account's key and signature.
      'a: another name': {...good, 'a': other.id},
      'a: one digit off': {...good, 'a': flipped(good['a'] as String)},
      'a: capitals': {...good, 'a': (good['a'] as String).toUpperCase()},
      'a: short': {...good, 'a': (good['a'] as String).substring(2)},
      'a: a number': {...good, 'a': 7},
      // Another key under this account's name.
      'k: another key': {...good, 'k': base64Encode(other.public)},
      'k: not a key': {...good, 'k': base64Encode(Uint8List(33))},
      'k: not base64': {...good, 'k': '*' * 44},
      'k: 65 bytes': {...good, 'k': base64Encode(Uint8List(65)..[0] = 4)},
      'k: a list': {...good, 'k': _keys().public.toList()},
      // Another device, another node: the signature is over both.
      'd: another device': {...good, 'd': flipped(_device)},
      'd: 64 digits': {...good, 'd': _device * 2},
      'd: not hex': {...good, 'd': 'z' * 32},
      'n: another node': {...good, 'n': flipped(_node)},
      'n: 32 digits': {...good, 'n': _node.substring(32)},
      'n: capitals': {...good, 'n': _node.toUpperCase()},
      'n: null': {...good, 'n': null},
      // Its times: moved, swapped, stretched, not numbers.
      't: a second later': {...good, 't': _made + 1000},
      't: a string': {...good, 't': '$_made'},
      't: a fraction': {...good, 't': _made + 0.5},
      't: nothing': {...good, 't': 0},
      'x: a day longer': {...good, 'x': _made + 31 * _day},
      'x: before it was made': {...good, 'x': _made - 1},
      'x: a string': {...good, 'x': 'never'},
      // The signature: changed, cut, another's, the wrong shape.
      's: one bit': {...good, 's': base64Encode(Uint8List.fromList(sig)..[5] ^= 1)},
      's: its last byte': {...good, 's': base64Encode(Uint8List.fromList(sig)..[63] ^= 0x80)},
      's: cut short': {...good, 's': base64Encode(sig.sublist(0, 63))},
      's: another key\'s': {...good, 's': base64Encode(NetCrypto.sign(other, DeviceCard.signedBytes(account: card.account, device: _device, nodeId: _node, made: _made, until: card.until)))},
      's: missing': {...good}..remove('s'),
      's: a megabyte': {...good, 's': 'A' * (1 << 20)},
    };
    for (final MapEntry(key: what, value: j) in tampered.entries) {
      expect(read((j as Map).cast<String, dynamic>()), isNull, reason: what);
    }
    // Not a card at all.
    for (final junk in <Object?>[null, 7, 'card', <Object>[], <String, Object>{}, [good]]) {
      expect(DeviceCard.fromJson(junk, now: _made), isNull, reason: '$junk');
    }
    // More fields than any card has: refused before anything is worked out.
    final before = NetCrypto.verifications;
    expect(DeviceCard.fromJson({...good, for (var i = 0; i < 20; i++) 'f$i': i}, now: _made), isNull);
    expect(DeviceCard.fromJson({...good, 's': 'A' * (1 << 20)}, now: _made), isNull);
    expect(NetCrypto.verifications, before, reason: 'nothing oversized reaches the arithmetic');
  });

  test('a card is its own account\'s: one signed for another account by this one\'s key, or naming another\'s key, is refused', () async {
    final mine = _keys(), theirs = NetKeys.generate();
    // Their name and their key, signed by mine.
    final forged = DeviceCard.signedBytes(account: theirs.id, device: _device, nodeId: _node, made: _made, until: _made + 30 * _day);
    final j = {'v': 1, 'a': theirs.id, 'k': base64Encode(theirs.public), 'd': _device, 'n': _node, 't': _made, 'x': _made + 30 * _day, 's': base64Encode(NetCrypto.sign(mine, forged))};
    expect(DeviceCard.fromJson(j, now: _made), isNull, reason: 'the signature is not that key\'s');
    // Their name with my key and my signature over their name.
    expect(DeviceCard.fromJson({...j, 'k': base64Encode(mine.public)}, now: _made), isNull, reason: 'the name is not that key\'s');
    // What it would take: their own key.
    expect(DeviceCard.fromJson({...j, 's': base64Encode(NetCrypto.sign(theirs, forged))}, now: _made)!.account, theirs.id);
  });

  test('good for thirty days and no longer: run out, made too far ahead, or made to last longer, it is refused', () async {
    final card = await _card();
    final j = card.toJson();
    expect(card.until - card.made, 30 * _day);
    expect(DeviceCard.fromJson(j, now: _made + 30 * _day - 1), isNotNull, reason: 'its last millisecond');
    expect(DeviceCard.fromJson(j, now: _made + 30 * _day), isNull, reason: 'run out');
    expect(card.expired(_made + 30 * _day - 1), isFalse);
    expect(card.expired(_made + 30 * _day), isTrue);
    // Another device's clock is never quite this one's: a day ahead is taken, more is not.
    expect(DeviceCard.fromJson(j, now: _made - _day), isNotNull);
    expect(DeviceCard.fromJson(j, now: _made - _day - 1), isNull, reason: 'made more than a day ahead of this clock');
    // Signed to last sixty days: the signature is good, the card is not.
    final keys = _keys();
    Map<String, dynamic> signed(int made, int until) =>
        {...j, 't': made, 'x': until, 's': base64Encode(NetCrypto.sign(keys, DeviceCard.signedBytes(account: keys.id, device: _device, nodeId: _node, made: made, until: until)))};
    expect(DeviceCard.fromJson(signed(_made, _made + 30 * _day), now: _made), isNotNull, reason: 'signed here as the card was');
    expect(DeviceCard.fromJson(signed(_made, _made + 60 * _day), now: _made), isNull);
    // Signed to run out before it was made, or made before time began: the same.
    expect(DeviceCard.fromJson(signed(_made + _day ~/ 2, _made + _day ~/ 4), now: _made), isNull);
    expect(DeviceCard.fromJson(signed(_made + _day ~/ 2, _made + _day ~/ 2), now: _made), isNull);
    expect(DeviceCard.fromJson(signed(-_day, _day), now: 1000), isNull);
    expect(DeviceCard.fromJson(signed(0, _day), now: 1000), isNull);
    expect(DeviceCard.fromJson(signed(1, _day), now: 1000), isNotNull);
  });

  test('made again when a week is left, or the node id, the device or the account is another', () async {
    final card = await _card();
    bool due(int now, {String node = _node, String? device, String? account}) => card.due(now, nodeId: node, device: device, account: account);
    expect(due(_made), isFalse);
    expect(due(_made + 23 * _day - 1), isFalse, reason: 'a week and a millisecond left');
    expect(due(_made + 23 * _day), isTrue, reason: 'a week left');
    expect(due(_made + 40 * _day), isTrue, reason: 'run out');
    expect(due(_made, node: 'ab' * 32), isTrue, reason: 'the node key was made again');
    expect(due(_made, device: 'cd' * 16), isTrue);
    expect(due(_made, device: _device, account: card.account), isFalse);
    expect(due(_made, account: NetKeys.generate().id), isTrue, reason: 'this install is someone else now');
    // The one made in its place is another card, good from then.
    final later = await _card(now: _at.add(const Duration(days: 23)));
    expect(later, isNot(card));
    expect(later.tag, isNot(card.tag));
    expect(later.until, card.until + 23 * _day);
  });

  test('made only for a device and a node that are named as they should be, and only by a signer whose answers are its key\'s', () async {
    await expectLater(_card(device: 'short'), throwsArgumentError);
    await expectLater(_card(node: _device), throwsArgumentError);
    await expectLater(_card(node: _node.toUpperCase()), throwsArgumentError);
    await expectLater(DeviceCard.make(_Broken(_keys()), device: _device, nodeId: _node, now: _at), throwsStateError);
  });
}
