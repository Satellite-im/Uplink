import 'dart:async';
import 'dart:typed_data';

import 'package:ghost_messaging/net/lan/lan_wire.dart';

/// A network in memory for the local network route's tests (lib/net/lan): every device that joins hears what the
/// others say to everyone, and can connect to their doors. What crosses it is kept, so a test can look at what the
/// network itself would see ([beacons], [frames]), and a test can stand on it as a stranger would ([FakeLanGround] used
/// by hand: say anything from its address, connect to any door, send any frame).
class FakeLan {
  final List<FakeLanGround> _joined = [];

  /// Every beacon said, with the address it was said from; and every frame sent on any wire, in the order they were sent.
  final List<({String from, Uint8List bytes})> beacons = [];
  final List<Uint8List> frames = [];

  /// Every wire made, as its two ends (the one that connected, the one connected to), in the order they were connected.
  final List<(FakeLanWire, FakeLanWire)> wires = [];

  /// Whether what is said to everyone is lost on the way (a network that passes no broadcasts); and to these alone.
  bool deaf = false;
  final Set<String> deafTo = {};

  /// A device on this network at [address].
  FakeLanGround join(String address) {
    final g = FakeLanGround._(this, address);
    _joined.add(g);
    return g;
  }
}

class FakeLanGround implements LanGround {
  FakeLanGround._(this.net, this.address);
  final FakeLan net;

  /// The address this device has; a test may give it another, as a device that moved networks has.
  String address;

  void Function(Uint8List bytes, String address)? _heard;
  void Function()? _lost;
  final Map<int, void Function(LanWire)> _doors = {};
  int _nextPort = 40000;

  /// Whether opening the air fails, as a port another program holds does; whether nothing can be said, as on a system
  /// that keeps the app off the network (it is answered false, as dart:io's send answers 0: nothing is thrown); and
  /// whether the device is on no network at all.
  bool noAir = false, mute = false, noNetwork = false;

  /// How many times the air and a door were opened.
  int airs = 0, doors = 0;

  @override
  Future<List<String>> addresses() async => noNetwork ? const [] : [address];

  @override
  Future<LanAir> air(void Function(Uint8List bytes, String address) heard, {void Function()? lost}) async {
    if (noAir) throw StateError('address in use');
    airs++;
    _heard = heard;
    _lost = lost;
    return _FakeAir(this);
  }

  /// The system closes what the air listens on, as a socket's error does: the route is told, once.
  void loseAir() {
    final lost = _lost;
    _heard = null;
    _lost = null;
    lost?.call();
  }

  @override
  Future<LanDoor> door(void Function(LanWire wire) came) async {
    doors++;
    final port = _nextPort++;
    _doors[port] = came;
    return _FakeDoor(this, port);
  }

  @override
  Future<LanWire> dial(String address, int port, {Duration timeout = const Duration(seconds: 3)}) async {
    final other = net._joined.where((g) => g.address == address).firstOrNull;
    final came = other?._doors[port];
    if (other == null || came == null) throw StateError('connection refused');
    final mine = FakeLanWire._(net, other.address), theirs = FakeLanWire._(net, this.address);
    mine._other = theirs;
    theirs._other = mine;
    net.wires.add((mine, theirs));
    scheduleMicrotask(() => came(theirs));
    return mine;
  }

  /// Says [bytes] to everyone else on the network, as from this device's address (or [from], which a datagram's
  /// sender may write as it likes).
  void say(Uint8List bytes, {String? from}) {
    final source = from ?? address;
    net.beacons.add((from: source, bytes: bytes));
    if (net.deaf) return;
    for (final g in net._joined) {
      if (identical(g, this) || net.deafTo.contains(g.address)) continue;
      final heard = g._heard;
      if (heard != null) scheduleMicrotask(() => heard(bytes, source));
    }
  }
}

class _FakeAir implements LanAir {
  _FakeAir(this._ground);
  final FakeLanGround _ground;
  bool _closed = false;

  @override
  Future<bool> say(String from, Uint8List beacon) async {
    if (_closed || _ground.mute) return false;
    _ground.say(beacon, from: from);
    return true;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _ground._heard = null;
    _ground._lost = null;
  }
}

class _FakeDoor implements LanDoor {
  _FakeDoor(this._ground, this.port);
  final FakeLanGround _ground;
  @override
  final int port;
  @override
  Future<void> close() async => _ground._doors.remove(port);
}

/// One end of a wire in memory. What it is sent goes to the other end's [frames] a moment later, in order, and what
/// was sent before it closed still arrives, as over TCP.
class FakeLanWire implements LanWire {
  FakeLanWire._(this._net, this.address);
  final FakeLan _net;
  @override
  final String address;
  late FakeLanWire _other;
  final _frames = StreamController<Uint8List>();
  bool closed = false;

  /// Everything this end was sent to pass on, in order.
  final List<Uint8List> sent = [];

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(Uint8List frame) {
    if (closed) return;
    sent.add(frame);
    _net.frames.add(frame);
    _other.arrive(frame);
  }

  /// [frame] comes to this end, as if the other had sent it: what someone on the wire could make it hear.
  void arrive(Uint8List frame) {
    if (_frames.isClosed) return;
    scheduleMicrotask(() {
      if (!_frames.isClosed) _frames.add(frame);
    });
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    // After what is already on its way, at both ends.
    scheduleMicrotask(() {
      if (!_frames.isClosed) unawaited(_frames.close());
    });
    unawaited(_other.close());
  }
}
