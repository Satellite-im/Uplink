import 'dart:async';

import 'package:flutter/foundation.dart';

import 'carrier.dart';

/// What a phone does for the SMS route: sends bytes to a number as a data text, and says what data texts came
/// (android/.../NetSms.kt). A computer has none.
abstract class SmsBridge {
  /// Whether data texts can be sent and heard now: a SIM, and Android's leave to send and receive SMS.
  Future<bool> available();

  /// Sends [bytes] to [address] as one data text; and the data texts that come, with the number each came from.
  Future<void> send(String address, Uint8List bytes);
  Stream<({String address, Uint8List bytes})> get incoming;
}

/// The route through the phone network itself: packets as data texts, which no texting app shows (Matt,
/// 2026-11-14: "At its core id also like to be able to send almost all chat data and negotiate calls when both
/// parties have sms enabled").
///
/// It needs no internet and reaches a phone whose app is closed, which no other route does. It is also the only
/// one that can cost the person money, is slow, and holds 133 bytes a text: so it carries only what is allowed to
/// go by a metered route (Switchboard.send's `metered`): a call ringing, a first greeting, a short message when
/// nothing else reaches. A packet too long for one text crosses in up to six.
class SmsCarrier implements Carrier {
  SmsCarrier(this.bridge);
  final SmsBridge bridge;

  /// What one data text holds: 140 bytes, less the seven that say which app it is for.
  static const perText = 133;

  @override
  String get id => 'sms';
  @override
  String get name => 'SMS';
  @override
  String get about => 'As data texts over the phone network. Needs no internet and reaches a phone whose app is closed. Each one counts as a text on your plan, so only small things that matter go this way.';
  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: perText, maxParts: 6, metered: true, live: false, wakes: true);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;

  final _arrived = StreamController<Arrived>.broadcast();
  StreamSubscription<({String address, Uint8List bytes})>? _sub;
  @override
  Stream<Arrived> get arrived => _arrived.stream;

  @override
  Future<void> start() async {
    _sub ??= bridge.incoming.listen((m) => _arrived.add(Arrived(id, m.bytes, address: m.address)));
    await look();
  }

  /// Asks the phone again whether texts can be sent: after the person gives or takes away its leave.
  Future<void> look() async {
    bool ok;
    try {
      ok = await bridge.available();
    } catch (_) {
      ok = false;
    }
    problem = ok ? null : 'This phone cannot send data texts now: no SIM, or SMS is not allowed for this app';
    state.value = ok ? CarrierState.up : CarrierState.down;
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    state.value = CarrierState.off;
  }

  /// Whether [address] is a phone number a data text can go to: digits, seven at least, with only the marks numbers are
  /// written with. Never a username (`@maya`), a group's or a member's stand-in, or a sender's name: Android takes a data
  /// text for "@maya" and fails it without a word, so it read as passed on (found in review, 2026-11-23).
  static bool isNumber(String? address) {
    final a = (address ?? '').trim();
    return RegExp(r'^\+?[0-9 ().\-]+$').hasMatch(a) && a.replaceAll(RegExp(r'[^0-9]'), '').length >= 7;
  }

  @override
  bool reaches(Peer peer) => state.value == CarrierState.up && isNumber(peer.address);

  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    final to = peer.address;
    if (to == null || !isNumber(to)) throw CarrierError('no number is known for them');
    if (packet.length > perText) throw CarrierError('too long for a text');
    try {
      await bridge.send(to, packet);
    } catch (e) {
      throw CarrierError('the text could not be sent: $e');
    }
    return Handed.passed;
  }
}
