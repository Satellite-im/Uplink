import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../platform_info.dart';
import 'lan_wire.dart';

/// The local network route's own network where there is dart:io: beacons as UDP broadcasts on [LanSockets.port], and
/// wires as TCP connections to a door on a port the system chose. On Android, the Mac, Windows and Linux. Not on an
/// iPhone: Apple lets an app say something to a whole network only with an entitlement it grants app by app
/// (com.apple.developer.networking.multicast), which this app has not asked for.
LanGround? makeLanGround() => PlatformInfo.isIOS ? null : LanSockets();

/// Why this build has no local network route, in words for Settings › Routes; null where it has one.
String? lanGroundMissing() => PlatformInfo.isIOS ? 'An iPhone lets an app find others on a network only with Apple\'s leave, which this app doesn\'t have yet.' : null;

/// [LanGround] over sockets.
///
/// **Hearing** is one socket on [port] at every address, which is the only way a broadcast is heard (a socket at one
/// address hears only what is sent to that address). It never says anything, so nothing said can close it; where the
/// system closes it all the same, the route is told ([LanGround.air]'s `lost`) and opens it again. It reads at most
/// [perTick] datagrams each [tick] and lets the system drop the rest unread: read as fast as they came, a flood of
/// them stopped everything else the app does (found in review, 2026-11-26).
///
/// **Saying** is a socket made for each beacon at the address it is said from, so the beacon leaves from that address
/// and by its network, and closed after. dart:io never throws where a datagram can't be sent: it answers 0, reports the
/// error on the socket's stream and closes the socket. One socket kept for hearing and saying both was closed by the
/// first beacon that failed (a laptop awake before its Wi-Fi), and the route went on saying it was ready (found in
/// review, 2026-11-26).
///
/// **On an Android phone** the Wi-Fi drops what is said to a whole network before any app sees it, unless an app says
/// it is listening: the air asks Android for that as it opens and lets it go as it closes
/// (android/.../LanEar.kt, a multicast lock). Without it a phone said its beacons and heard none.
///
/// [beaconTo], [sayPort], [bind] and [local] are for a test on one machine, where nothing is broadcast and two copies
/// can't both hear one port: where beacons are said in place of the network's broadcast addresses, the port they are
/// said to, the address everything listens at, and the addresses this device is said to have.
class LanSockets implements LanGround {
  LanSockets({this.port = defaultPort, this.bind, this.beaconTo, this.local, int? sayPort}) : sayPort = sayPort ?? port;

  /// The UDP port beacons are said to and heard on: the SMS route's port and one more (lib/net/sms_carrier.dart).
  static const defaultPort = 16963;

  /// The most datagrams read in one [tick]: fifty devices' beacons in a tenth of a second is no network this is for.
  static const perTick = 50;
  static const tick = Duration(milliseconds: 100);

  final int port, sayPort;
  final InternetAddress? bind;
  final List<InternetAddress>? beaconTo;
  final List<String>? local;

  @override
  Future<List<String>> addresses() async {
    final said = local;
    if (said != null) return said;
    final out = <String>[];
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in i.addresses) {
          if (isLanAddress(a.address) && !out.contains(a.address)) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  /// Tells Android the app is listening to what is said to the whole network, or no longer (LanEar.kt). Nothing on
  /// any other system, and nothing where the app's own code is not there to ask (a test).
  static Future<void> _listening(bool on) async {
    if (!PlatformInfo.isAndroid) return;
    try {
      await const MethodChannel('ghost_messaging/lan').invokeMethod<bool>('hear', {'on': on}).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<LanAir> air(void Function(Uint8List bytes, String address) heard, {void Function()? lost}) async {
    // Shared with any other copy of the app on this device where the system lets a port be shared (not Windows).
    final socket = await RawDatagramSocket.bind(bind ?? InternetAddress.anyIPv4, port, reuseAddress: true, reusePort: !PlatformInfo.isWindows);
    await _listening(true);
    final air = _Air(this, socket);
    var read = 0;
    air.timer = Timer.periodic(tick, (_) {
      read = 0;
      if (!air.closed) socket.readEventsEnabled = true;
    });
    void gone() {
      if (air.closed) return;
      air.closed = true;
      air.timer?.cancel();
      unawaited(_listening(false));
      lost?.call();
    }

    socket.listen((event) {
      if (event == RawSocketEvent.closed) return gone();
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        heard(d.data, d.address.address);
        // Over what a tick may bring: nothing more is read until the next, and the system drops what comes meanwhile.
        if (++read >= perTick) {
          socket.readEventsEnabled = false;
          return;
        }
      }
    }, onError: (Object _) => gone(), onDone: gone);
    return air;
  }

  @override
  Future<LanDoor> door(void Function(LanWire wire) came) async {
    final server = await ServerSocket.bind(bind ?? InternetAddress.anyIPv4, 0);
    server.listen((s) {
      // A connection reset the moment it was made has no address to give: closed, and nothing thrown here.
      final String from;
      try {
        from = s.remoteAddress.address;
      } catch (_) {
        s.destroy();
        return;
      }
      came(_Wire(s, from));
    }, onError: (Object _) {});
    return _Door(server);
  }

  @override
  Future<LanWire> dial(String address, int port, {Duration timeout = const Duration(seconds: 3)}) async => _Wire(await Socket.connect(address, port, timeout: timeout), address);
}

class _Air implements LanAir {
  _Air(this._ground, this._socket);
  final LanSockets _ground;
  final RawDatagramSocket _socket;
  Timer? timer;
  bool closed = false;

  /// Where a beacon said from [from] goes: everyone on the last 256 of its network (a network is nearly always that
  /// or smaller), and the network's own "everyone" address, which the system sends by the network it would use for
  /// anything else.
  List<InternetAddress> _everyone(String from) => _ground.beaconTo ?? [InternetAddress('${from.substring(0, from.lastIndexOf('.'))}.255'), InternetAddress('255.255.255.255')];

  @override
  Future<bool> say(String from, Uint8List beacon) async {
    if (closed) return false;
    RawDatagramSocket? out;
    try {
      out = await RawDatagramSocket.bind(InternetAddress(from), 0);
      out.broadcastEnabled = true;
      // What a failed send reports comes here, a moment after: taken, so it is nobody's unhandled error.
      out.listen((_) {}, onError: (Object _) {});
      var sent = 0;
      for (final to in _everyone(from)) {
        try {
          if (out.send(beacon, to, _ground.sayPort) > 0) sent++;
        } catch (_) {}
      }
      return sent > 0;
    } catch (_) {
      return false;
    } finally {
      out?.close();
    }
  }

  @override
  Future<void> close() async {
    final was = closed;
    closed = true;
    timer?.cancel();
    _socket.close();
    // Said already where the system closed it first.
    if (!was) await LanSockets._listening(false);
  }
}

class _Door implements LanDoor {
  _Door(this._server);
  final ServerSocket _server;
  @override
  int get port => _server.port;
  @override
  Future<void> close() async {
    await _server.close();
  }
}

/// A wire over a TCP connection: [LanFramer]'s frames each way.
class _Wire implements LanWire {
  _Wire(this._socket, this.address) {
    try {
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    // What a write to a connection the other end reset reports comes here: taken, so it is nobody's unhandled error.
    unawaited(_socket.done.then<void>((_) {}, onError: (Object _) {}));
    _socket.listen(
      (bytes) {
        for (final f in _framer.add(bytes)) {
          if (!_frames.isClosed) _frames.add(f);
        }
        if (_framer.broken) unawaited(close());
      },
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final LanFramer _framer = LanFramer();
  final _frames = StreamController<Uint8List>();
  bool _closed = false;

  @override
  final String address;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(Uint8List frame) {
    if (_closed) return;
    try {
      _socket.add(LanFramer.wrap(frame));
    } catch (_) {
      unawaited(close());
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    // Not waited for: with nobody listening yet, a controller's close never ends.
    if (!_frames.isClosed) unawaited(_frames.close());
  }
}
