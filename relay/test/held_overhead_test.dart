import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart' show someBytes, unhex;

/// What the hub holds for people who are away is counted with what holding each packet costs ([Hub.heldOverhead]), not
/// by the packets' bytes alone: counted by bytes, one connection sending one-byte packets to made-up names held over a
/// million of them under a 24 MB limit, several times that in memory (found by the hosted relay's review, 2026-11-23,
/// and true of gogho.st's 96 MB too).

/// A connection that keeps nothing it is told: so the test itself holds nothing as it fills the hub.
class _Sink implements HubSocket {
  final _in = StreamController<Object?>();
  final said = <Completer<Map>>[Completer<Map>(), Completer<Map>()];
  int heard = 0;
  bool _open = true;

  @override
  Stream<Object?> get incoming => _in.stream;

  @override
  void add(Object data) {
    if (data is String && heard < 2) said[heard].complete(jsonDecode(data) as Map);
    heard++;
  }

  @override
  bool get isOpen => _open;

  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    await _in.close();
  }

  void say(Object m) => _in.add(m);
}

void main() {
  test('one-byte packets to made-up names: each is counted with its overhead, so the limit bounds how many are held', () async {
    const limit = 1 << 20;
    final hub = Hub(heldBytes: limit);
    final s = _Sink();
    hub.attach(s);
    final scalar = someBytes(32), key = P256.publicOf(scalar), id = Hub.nameOf(key);
    final nonce = unhex((await s.said[0].future)['hello'] as String);
    s.say(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], someBytes(32)))}));
    expect((await s.said[1].future)['ok'], true);

    final rnd = Random(7);
    var seq = 0, held = 0;
    final names = <String>[];
    // Far more than fit: 40 made-up names, a mailbox's most to each.
    for (var p = 0; p < 40; p++) {
      final to = Uint8List.fromList([for (var i = 0; i < 16; i++) rnd.nextInt(256)]);
      names.add(to.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      for (var j = 0; j < Hub.mailboxFrames; j++) {
        final n = ByteData(4)..setUint32(0, ++seq);
        s.say(Uint8List.fromList([Hub.toPeer, ...n.buffer.asUint8List(), ...to, 0x2a]));
      }
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final n in names) {
      held += hub.heldFor(n);
    }
    expect(held, greaterThan(0));
    expect(held * Hub.heldOverhead, lessThanOrEqualTo(limit), reason: 'every packet held is counted with its overhead');
    expect(hub.holding, greaterThanOrEqualTo(held * (Hub.heldOverhead + 1)));
    expect(hub.holding, lessThanOrEqualTo(limit));
    expect(held, lessThan(40 * Hub.mailboxFrames), reason: 'the limit was reached: by bytes alone all 8,000 would have been held');
  });
}
