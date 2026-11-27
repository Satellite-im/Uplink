import 'dart:async';
import 'dart:typed_data';

/// What the local network route (lan_carrier.dart) stands on, apart from what carries it: a way to say a few bytes to
/// everyone on a network this device is on and to hear what they say (the **air**: UDP broadcast, lan_ground_io.dart),
/// and a way to connect to one of them and be connected to (a **door** and **wires**: TCP). Nothing here knows which,
/// so a test puts a network of its own under several routes (test/support/fake_lan.dart), and a build with no sockets
/// (a browser) has none and no route.
abstract class LanGround {
  /// The addresses this device has now on private networks ([isLanAddress]): each is a network a beacon is said on,
  /// from that address. None where it is on no such network.
  Future<List<String>> addresses();

  /// Opens the air: [heard] is told every beacon said on those networks, with the address it came from. [lost] is told
  /// where the air stops hearing by itself (the system closed what it listened on), so the route opens it again.
  Future<LanAir> air(void Function(Uint8List bytes, String address) heard, {void Function()? lost});

  /// Opens a door for the others to connect to: [came] is told each wire as it is made.
  Future<LanDoor> door(void Function(LanWire wire) came);

  /// Connects to the door at [address], [port]; throws where it can't within [timeout].
  Future<LanWire> dial(String address, int port, {Duration timeout = const Duration(seconds: 3)});
}

/// The air, open, until closed.
abstract class LanAir {
  /// Says [beacon] to everyone on the network this device is on at [from] (one of [LanGround.addresses]), as from
  /// that address. Whether it was said: false, never a throw, where it could not be (no network there now, or the
  /// system keeps the app off it).
  Future<bool> say(String from, Uint8List beacon);
  Future<void> close();
}

/// A door, open at [port].
abstract class LanDoor {
  int get port;
  Future<void> close();
}

/// One connection between two devices, as whole frames each way. [frames] is done when it has closed, whoever closed
/// it; a frame longer than [LanFramer.longest] closes it.
abstract class LanWire {
  /// The other end's address on the network.
  String get address;
  Stream<Uint8List> get frames;
  void send(Uint8List frame);
  Future<void> close();
}

/// Frames over a stream of bytes: each a length of four bytes, big-endian, then that many bytes. What a wire over TCP
/// is made of (lan_ground_io.dart); here, apart from any socket, so it is tried without one.
class LanFramer {
  /// The longest frame taken: a packet as the routes carry them (HubCarrier.maxPacket, 60 KB), with room for its
  /// sealing.
  static const longest = 64 * 1024;

  final BytesBuilder _held = BytesBuilder(copy: false);

  /// Whether what came could not be frames: a length longer than [longest]. Nothing more is taken once it is.
  bool broken = false;

  /// [frame] with its length before it.
  static Uint8List wrap(Uint8List frame) {
    final out = Uint8List(4 + frame.length);
    ByteData.sublistView(out).setUint32(0, frame.length);
    out.setRange(4, out.length, frame);
    return out;
  }

  /// Takes more of the stream, and gives back the frames that are now whole, in order.
  List<Uint8List> add(List<int> bytes) {
    if (broken) return const [];
    _held.add(bytes);
    final all = _held.takeBytes();
    final out = <Uint8List>[];
    var at = 0;
    while (all.length - at >= 4) {
      final n = ByteData.sublistView(all, at, at + 4).getUint32(0);
      if (n > longest) {
        broken = true;
        return out;
      }
      if (all.length - at - 4 < n) break;
      out.add(Uint8List.sublistView(all, at + 4, at + 4 + n));
      at += 4 + n;
    }
    if (at < all.length) _held.add(Uint8List.sublistView(all, at));
    return out;
  }
}

/// Whether [address] is a private network's (RFC 1918): 10/8, 172.16/12 or 192.168/16, as home and office networks
/// use (and some carriers and VPNs too, which is why the route also keeps to networks this device is on: [sameNet]).
/// The route says nothing to, hears nothing from and connects to nothing at any other: the open internet, loopback,
/// the link-local addresses a cloud's machines answer on.
bool isLanAddress(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final b = [for (final p in parts) int.tryParse(p) ?? -1];
  if (b.any((x) => x < 0 || x > 255)) return false;
  return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
}

/// Whether [a] and [b] are on one network as nearly as can be told without its mask (dart:io gives none): private
/// addresses whose first two numbers are the same. What a device hears from, connects to and takes connections from is
/// held to the networks it has an address on, so nothing it is told can send it connecting across to another.
bool sameNet(String a, String b) {
  if (!isLanAddress(a) || !isLanAddress(b)) return false;
  final x = a.split('.'), y = b.split('.');
  return x[0] == y[0] && x[1] == y[1];
}
