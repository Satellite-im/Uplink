import 'package:flutter/foundation.dart';

/// Someone else's install, as the routes know it: its name, the key this install shares with it, and whatever a
/// route needs to find it (a phone number for SMS).
class Peer {
  const Peer({required this.id, this.key, this.address, this.name});

  /// Their name: NetCrypto.idOf their public key, 32 hex digits.
  final String id;

  /// What packets to and from them are sealed with (NetCrypto.netKey); null where no keys have been exchanged, and
  /// then only what is said in the clear can pass.
  final Uint8List? key;

  /// Their phone number, where it is known.
  final String? address;
  final String? name;

  @override
  String toString() => 'Peer(${id.length >= 6 ? id.substring(0, 6) : id}${name == null ? '' : ' $name'})';
}

/// How a route stands.
enum CarrierState {
  /// Switched off, or not started.
  off,

  /// Starting, or trying again after it was lost.
  connecting,

  /// Ready to carry.
  up,

  /// Cannot carry now; [Carrier.problem] says why.
  down,
}

/// What became of a packet a route took.
enum Handed {
  /// It was passed to the other install, or sent on its way with nothing more this route can know.
  passed,

  /// They are not there now: it is kept for them and handed over when they next are.
  held,
}

/// What a route is like, which is what the switchboard chooses by.
class CarrierTraits {
  const CarrierTraits({required this.maxPacket, this.maxParts = 1, this.metered = false, this.live = true, this.wakes = false, this.ackWait = const Duration(seconds: 4)});

  /// The longest packet it carries in one piece, in bytes, and how many pieces it will carry of one too long.
  final int maxPacket;
  final int maxParts;

  /// It may cost the person money or count against a plan (SMS): used only for what is allowed to.
  final bool metered;

  /// What it passes arrives within moments while both are there, so an answer can be waited for.
  final bool live;

  /// It reaches a phone whose app is closed (SMS).
  final bool wakes;

  /// How long an answer is waited for before the next route is tried.
  final Duration ackWait;
}

/// Something a route brought.
class Arrived {
  const Arrived(this.carrier, this.bytes, {this.address, this.from, this.line, this.device});
  final String carrier;
  final Uint8List bytes;

  /// The link it came on, where the route holds links of its own ([LiveLinks]): what answers it goes back on that link
  /// ([LiveLinks.sendOn]), not to every device of the sender. What it is, is the route's own business.
  final Object? line;

  /// Who sent it, as the route itself vouches (the relay's hub checks a signature at hello and stamps each packet with
  /// the sender's name); null where the route can't say.
  final String? from;

  /// Where the route itself knows it came from (the number a text came from).
  final String? address;

  /// Which of this account's own devices sent it, as the relay's hub vouches (a packet the account sent its own name,
  /// handed with the device that sent it: relay/lib/hub.dart toPeerFromDevice); null where the route can't say.
  final String? device;
}

/// One way of getting a packet from this install to another: this server's hub, the local network, SMS, and later
/// a peer-to-peer network (Matt, 2026-11-14: "The goal will be to have multiple sources to feed data to eachother
/// from wifi locally, p2p, internet, sms, etc"). Everything above the routes speaks only to this, so one can be
/// taken out and another put in its place without the rest knowing (Switchboard.add, remove, replace).
///
/// A route carries bytes and knows nothing of what they are: packets are sealed before they reach it.
abstract class Carrier {
  /// A short name that does not change: `hub`, `lan`, `sms`, `p2p`.
  String get id;

  /// What it is called in Settings, and a line on what it is.
  String get name;
  String get about;
  CarrierTraits get traits;
  ValueListenable<CarrierState> get state;

  /// Why it is down, in words to show; null while it is not.
  String? get problem;

  /// Starts it (dialling, listening) and stops it; [state] says how it stands after.
  Future<void> start();
  Future<void> stop();

  /// Whether a packet handed over now could be expected to get to [peer].
  bool reaches(Peer peer);

  /// Takes a packet for [peer]. Throws when it cannot.
  Future<Handed> send(Peer peer, Uint8List packet);

  /// What it brings.
  Stream<Arrived> get arrived;
}

/// A route that holds links of its own to some people's devices (the direct route's streams, lib/net/p2p). When a
/// route before it only kept a packet for someone who is away from it, the switchboard gives the packet to a link
/// that is open right now as well, and to nothing else: asking whether one is open, and sending by it, start nothing
/// and dial nobody.
abstract class LiveLinks {
  /// Whether a link to one of [peer]'s devices is open now.
  bool linked(Peer peer);

  /// Whether a link to the device of anyone but this install's own account is open now: whether this route reaches
  /// someone right now, without dialling (Friends asks, lib/friends/friends.dart).
  bool get linkedToSomeone;

  /// Sends [packet] to [peer] by the links open now and by nothing else. Throws [CarrierError] where none took it.
  Future<Handed> sendLinked(Peer peer, Uint8List packet);

  /// Sends [packet], an answer, to [peer] on [line] (where what it answers came by: [Arrived.line]) while that is open
  /// and [peer]'s, else by the links to [peer] open now; never dials or starts anything. Throws [CarrierError] where
  /// none took it.
  Future<Handed> sendOn(Peer peer, Object? line, Uint8List packet);
}

/// A route that cannot carry a packet says why by throwing this.
class CarrierError implements Exception {
  CarrierError(this.message);
  final String message;
  @override
  String toString() => message;
}
