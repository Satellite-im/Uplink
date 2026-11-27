import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/link/crypto.dart';

/// The Mac's sealing, held to the examples the phone's Kotlin is held to (test/desk_vectors.json, made by
/// tool/desk_vectors.mjs with Node's own cryptography; `DeskCryptoTest.kt` reads the same file).
void main() {
  final v = jsonDecode(File('test/desk_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final input = v['input'] as Map<String, dynamic>;
  Uint8List bytes(String name) => DeskCrypto.unhex(v[name] as String);
  Uint8List given(String name) => DeskCrypto.unhex(input[name] as String);

  final desk = DeskCrypto.keyPairFrom(given('deskPrivate'));
  final phone = DeskCrypto.keyPairFrom(given('phonePrivate'));
  final pairKey = DeskCrypto.pairKey(desk, bytes('phonePublic'), given('secret'))!;

  test('a key pair from its private half has the examples\' public half', () {
    expect(DeskCrypto.hex(desk.public), v['deskPublic']);
    expect(DeskCrypto.hex(phone.public), v['phonePublic']);
    expect(DeskCrypto.hex(desk.scalar), input['deskPrivate']);
    final fresh = DeskCrypto.newKeyPair();
    expect(fresh.public.length, 33);
    expect(DeskCrypto.isKey(fresh.public), isTrue);
    expect(DeskCrypto.hex(DeskCrypto.keyPairFrom(fresh.scalar).public), DeskCrypto.hex(fresh.public));
    expect(DeskCrypto.isKey(Uint8List(33)), isFalse);
    expect(DeskCrypto.isKey(Uint8List(32)), isFalse);
  });

  test('the pairing\'s key is the examples\', and the same from both sides', () {
    expect(DeskCrypto.hex(pairKey), v['pairKey']);
    expect(DeskCrypto.hex(DeskCrypto.pairKey(phone, bytes('deskPublic'), given('secret'))!), v['pairKey']);
    expect(DeskCrypto.id(pairKey), v['id']);
    expect(DeskCrypto.relayChannel(pairKey), v['relayChannel']);
    expect(DeskCrypto.relayToken(pairKey), v['relayToken']);
    expect(DeskCrypto.code(pairKey), v['code']);
  });

  test('without the QR code\'s secret, or with a swapped key, the key is another', () {
    expect(DeskCrypto.hex(DeskCrypto.pairKey(desk, bytes('phonePublic'), Uint8List(16))!), isNot(v['pairKey']));
    final eve = DeskCrypto.newKeyPair();
    expect(DeskCrypto.hex(DeskCrypto.pairKey(desk, eve.public, given('secret'))!), isNot(v['pairKey']));
    expect(DeskCrypto.pairKey(desk, Uint8List(33), given('secret')), isNull);
  });

  test('what the secret alone makes is the examples\'', () {
    expect(DeskCrypto.pairingId(given('secret')), v['pairingId']);
    expect(DeskCrypto.pairingChannel(given('secret')), v['pairingChannel']);
    expect(DeskCrypto.pairingToken(given('secret')), v['pairingToken']);
  });

  test('the QR code is written as the examples\' and read back', () {
    final offer = DeskOffer(key: bytes('deskPublic'), secret: given('secret'), name: "Matt's MacBook", mode: 'both', relay: 'wss://ghost-sms.com/relay');
    expect(offer.text, v['offerText']);
    final read = DeskOffer.parse(v['offerText'] as String)!;
    expect(DeskCrypto.hex(read.key), v['deskPublic']);
    expect(DeskCrypto.hex(read.secret), input['secret']);
    expect(read.name, "Matt's MacBook");
    expect(read.mode, 'both');
    expect(read.relay, 'wss://ghost-sms.com/relay');
    // As the link the QR code holds: the same offer, read back the same.
    expect(offer.link, v['offerLink']);
    final linked = DeskOffer.parse(v['offerLink'] as String)!;
    expect(DeskCrypto.hex(linked.key), v['deskPublic']);
    expect(DeskCrypto.hex(linked.secret), input['secret']);
    expect(DeskOffer.parse('ghostmsg://pair/'), isNull);
    expect(DeskOffer.parse('https://example.com'), isNull);
    expect(DeskOffer.parse('GHOSTPAIR1:e30'), isNull);
    expect(DeskOffer.parse('GHOSTPAIR1:!!!'), isNull);
  });

  test('a connection\'s keys and frames are the examples\'', () {
    final keys = DeskCrypto.sessionKeys(pairKey, given('deskNonce'), given('phoneNonce'), DeskCrypto.keyPairFrom(given('deskEphemeral')), bytes('phoneEphemeralPublic'))!;
    expect(DeskCrypto.hex(keys.desk), v['deskKey']);
    expect(DeskCrypto.hex(keys.phone), v['phoneKey']);
    final fromThePhone = DeskCrypto.sessionKeys(pairKey, given('deskNonce'), given('phoneNonce'), DeskCrypto.keyPairFrom(given('phoneEphemeral')), bytes('deskEphemeralPublic'))!;
    expect(DeskCrypto.hex(fromThePhone.desk), v['deskKey']);

    final mac = DeskChannel(sendKey: keys.desk, receiveKey: keys.phone);
    for (final f in (v['frames'] as List).cast<Map<String, dynamic>>()) {
      final sealed = DeskCrypto.unhex(f['sealed'] as String);
      if (f['from'] == 'desk') {
        expect(DeskCrypto.hex(mac.seal(f['text'] as String)), f['sealed']);
      } else {
        expect(mac.open(sealed), f['text']);
      }
    }
  });

  test('a frame repeated, reordered or changed does not open', () {
    final a = Uint8List.fromList(List.filled(32, 1));
    final b = Uint8List.fromList(List.filled(32, 2));
    final mac = DeskChannel(sendKey: a, receiveKey: b);
    final phone = DeskChannel(sendKey: b, receiveKey: a);
    final first = mac.seal('send this text');
    final second = mac.seal('and this one');
    expect(phone.open(first), 'send this text');
    expect(phone.open(first), isNull);
    expect(phone.open(second), 'and this one');
    final third = mac.seal('three');
    final fourth = mac.seal('four');
    expect(phone.open(fourth), isNull);
    expect(phone.open(third), 'three');
    expect(phone.open(fourth), 'four');
    final fifth = mac.seal('five');
    fifth[2] ^= 1;
    expect(phone.open(fifth), isNull);
    final back = phone.seal('from the phone');
    expect(phone.open(back), isNull);
    expect(mac.open(back), 'from the phone');
  });
}
