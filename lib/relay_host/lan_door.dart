import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What stands in front of the local network's door of a relay hosted from the app (relay_host_io.dart), between the
/// listening socket and dart:io's HttpServer: every connection counted as it is taken, for its address and in all, and
/// one past either closed at once; and a connection that hasn't finished its request ([through]) in [wait] closed.
///
/// Found in review, 2026-11-23: with nothing in front, a request that never finished its headers was never handed to
/// the hub, so the hub's 200 connections never counted it, and nothing closed it before dart:io's two-minute idle
/// timeout. Each held one of the app's file descriptors (a Mac app from the Dock has 256): one device on the network
/// could take them all, and the app could then open no file.
class LanDoor extends Stream<Socket> implements ServerSocket {
  LanDoor(this._listening, {this.most = 64, this.each = 8, this.eachThrough = 3, this.wait = const Duration(seconds: 5), this.localOk});

  /// The most connections from one address that have finished their request (a device signed in, or signing in): an
  /// app needs one, and a check of the relay one more for a moment. Without it 8 addresses with 8 sign-ins each filled
  /// the door, with no pass phrase set (found in the third review, 2026-11-23).
  final int eachThrough;

  final ServerSocket _listening;

  /// The most connections at the door at once, all together and from any one address; and how long one may take to
  /// finish its request.
  final int most, each;
  final Duration wait;

  /// Whether a connection that came in at this device's address [local] is taken: the door listens on every address,
  /// and takes only those its keeper's network is reached by (not a phone's mobile data). Null takes every one.
  final bool Function(InternetAddress local)? localOk;

  final Set<_DoorSocket> _open = {};
  final Map<String, int> _from = {};
  final Map<String, _DoorSocket> _byEnd = {};

  /// How many connections are at the door now (those handed on to the hub included, until they close).
  int get open => _open.length;

  /// How many were closed as they came, the door full for them.
  int turnedAway = 0;

  /// How many were closed for not finishing their request in time.
  int timedOut = 0;

  static String _end(InternetAddress a, int port) => '${a.address}#$port';

  /// The request that came on the connection from [address]:[port] has finished its headers: it is not closed for
  /// taking too long. Whatever comes of it then is the hub's (whose own wait for a hello closes a silent WebSocket).
  /// False where it was closed instead, its address having as many through as it may ([eachThrough]).
  bool through(InternetAddress? address, int? port) {
    if (address == null || port == null) return true;
    final s = _byEnd[_end(address, port)];
    if (s == null || s.isThrough) return true;
    final already = _open.where((o) => o.isThrough && o.from == address.address).length;
    if (already >= eachThrough) {
      // Answered and closed by whoever asked (relay_host_io.dart), not destroyed: the far end is told why. It is no
      // longer timed: the answer goes at once.
      turnedAway++;
      s.deadline?.cancel();
      return false;
    }
    s.through();
    return true;
  }

  Socket? _take(Socket raw) {
    String address;
    int port;
    try {
      address = raw.remoteAddress.address;
      port = raw.remotePort;
    } catch (_) {
      raw.destroy();
      return null;
    }
    final mine = _from[address] ?? 0;
    bool atOkAddress;
    try {
      atOkAddress = localOk?.call(raw.address) ?? true;
    } catch (_) {
      atOkAddress = false;
    }
    if (_open.length >= most || mine >= each || !atOkAddress) {
      turnedAway++;
      raw.destroy();
      return null;
    }
    final end = _end(raw.remoteAddress, port);
    late final _DoorSocket s;
    s = _DoorSocket(raw, address, onGone: () {
      if (!_open.remove(s)) return;
      final n = (_from[address] ?? 1) - 1;
      if (n <= 0) {
        _from.remove(address);
      } else {
        _from[address] = n;
      }
      if (identical(_byEnd[end], s)) _byEnd.remove(end);
    });
    _open.add(s);
    _from[address] = mine + 1;
    _byEnd[end] = s;
    s.deadline = Timer(wait, () {
      if (s.isThrough) return;
      timedOut++;
      s.destroy();
    });
    return s;
  }

  @override
  StreamSubscription<Socket> listen(void Function(Socket event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _listening.map(_take).where((s) => s != null).cast<Socket>().listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  InternetAddress get address => _listening.address;

  @override
  int get port => _listening.port;

  @override
  Future<ServerSocket> close() async {
    await _listening.close();
    for (final s in _open.toList()) {
      s.destroy();
    }
    return this;
  }
}

/// A connection at the door: the socket itself, with its going told to the door however it goes (closed by either
/// end, destroyed, failed).
class _DoorSocket extends Stream<Uint8List> implements Socket {
  _DoorSocket(this._s, this.from, {required void Function() onGone}) : _onGone = onGone {
    unawaited(_s.done.then((_) => _gone(), onError: (Object _) => _gone()));
  }

  final Socket _s;

  /// The address it came from.
  final String from;
  final void Function() _onGone;
  Timer? deadline;
  bool isThrough = false;
  bool _wentAway = false;

  void through() {
    isThrough = true;
    deadline?.cancel();
    deadline = null;
  }

  void _gone() {
    if (_wentAway) return;
    _wentAway = true;
    deadline?.cancel();
    deadline = null;
    _onGone();
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) => _s
      .transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleError: (e, st, sink) {
            _gone();
            sink.addError(e, st);
          },
          handleDone: (sink) {
            _gone();
            sink.close();
          },
        ),
      )
      .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  void destroy() {
    _s.destroy();
    _gone();
  }

  @override
  Future<void> close() => _s.close();

  @override
  Future<void> get done => _s.done;

  @override
  Encoding get encoding => _s.encoding;
  @override
  set encoding(Encoding value) => _s.encoding = value;

  @override
  void add(List<int> data) => _s.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _s.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _s.addStream(stream);
  @override
  Future<void> flush() => _s.flush();
  @override
  void write(Object? object) => _s.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _s.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => _s.writeln(object);
  @override
  void writeCharCode(int charCode) => _s.writeCharCode(charCode);

  @override
  bool setOption(SocketOption option, bool enabled) => _s.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _s.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _s.setRawOption(option);

  @override
  int get port => _s.port;
  @override
  int get remotePort => _s.remotePort;
  @override
  InternetAddress get address => _s.address;
  @override
  InternetAddress get remoteAddress => _s.remoteAddress;
}
