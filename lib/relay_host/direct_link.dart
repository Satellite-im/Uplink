import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../net/hub_link.dart';
import '../net/p2p/node.dart';
import '../net/p2p/p2p.dart';
import 'address.dart';

/// A hub connection over the direct network (docs/OPEN_NETWORK.md, section 5): to a relay hosted from someone's app,
/// reached from anywhere by the node id of the device it runs on, on channel 1 ([P2pChannel.hub]), with no port opened
/// and no certificate. Both ends need Direct on. What it carries is what a hub's WebSocket carries, each message one
/// frame of the stream, said as which kind it is ([DirectFrames]); nothing here is the relay's, so a phone, a computer
/// and an iPhone can all join one this way.

/// What a hub's messages are on a stream, which carries bytes alone: a text (the hub's JSON) is `[0]` then its UTF-8, a
/// packet `[1]` then its bytes. The host's end (lib/relay_host/relay_host_io.dart) reads and writes the same.
abstract final class DirectFrames {
  static const text = 0, bytes = 1;

  /// The longest message carried: a frame is at most [P2pNode.maxFrame] bytes, one of them the kind.
  static const most = P2pNode.maxFrame - 1;

  /// [message] (a String or a `List<int>`) as a frame.
  static Uint8List encode(Object message) {
    final body = message is String ? utf8.encode(message) : message as List<int>;
    return Uint8List(body.length + 1)
      ..[0] = message is String ? text : bytes
      ..setRange(1, body.length + 1, body);
  }

  /// What [frame] carries: a String or a Uint8List; null where it is neither kind, or its text is not UTF-8.
  static Object? decode(Uint8List frame) {
    if (frame.isEmpty) return null;
    if (frame[0] == bytes) return Uint8List.sublistView(frame, 1);
    if (frame[0] != text) return null;
    try {
      return utf8.decode(Uint8List.sublistView(frame, 1));
    } catch (_) {
      return null;
    }
  }
}

/// Why a hosted relay could not be dialled over Direct, in words to show (Settings › Routes says them after "Couldn't
/// connect").
class DirectDialError implements Exception {
  const DirectDialError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Dials the hosted relay at [address] over the direct network: this device's node brought up (a phone's kept up while
/// the connection lasts: [P2p.busy]), then a stream to the relay's device on channel 1, by the link helper this
/// device's relay named (both ends on one relay's helpers find each other through it) or, on one network, as it is.
/// Fails with a [DirectDialError] where this device has no direct route, Direct is off here, the address names no
/// device, or the device isn't reached within [timeout].
Future<HubLink> dialOverDirect(P2p? p2p, GhostRelayAddress address, {Duration timeout = const Duration(seconds: 10)}) async {
  final node = address.node;
  if (node == null) throw const DirectDialError('This relay\'s address names no device to reach it at over Direct.');
  if (p2p == null) throw const DirectDialError('This device has no Direct route, which a relay hosted from someone\'s app is reached by.');
  if (!p2p.on) throw const DirectDialError('Direct is switched off on this device: switch it on above to reach a relay hosted from someone\'s app.');
  p2p.busy(true);
  try {
    await p2p.up();
    final helper = p2p.helpers.firstOrNull;
    final stream = await p2p.node.open(node, P2pChannel.hub, hint: helper == null ? null : Whereabouts(helper: helper), timeout: timeout);
    return DirectHubLink(stream, onClose: () => p2p.busy(false));
  } catch (e) {
    p2p.busy(false);
    if (e is DirectDialError) rethrow;
    throw DirectDialError('Its device wasn\'t reached over Direct ($e). It may be off, or not hosting now.');
  }
}

/// A [HubLink] over a stream on channel 1: what the hub says comes out of [said] as it would from a WebSocket, and what
/// is said to it goes as frames, one after another, in order.
class DirectHubLink implements HubLink {
  DirectHubLink(this.stream, {void Function()? onClose}) : _onClose = onClose {
    _sub = stream.frames.listen((frame) {
      final m = DirectFrames.decode(frame);
      // A frame that is neither kind is not from a hub: the link ends.
      if (m == null) {
        unawaited(close());
        return;
      }
      _said.add(m);
    }, onDone: _done, onError: (Object _) => _done(), cancelOnError: true);
  }

  final P2pStream stream;
  final void Function()? _onClose;
  late final StreamSubscription<Uint8List> _sub;
  final _said = StreamController<Object>();
  Future<void> _last = Future.value();
  bool _closed = false;

  @override
  Stream<Object> get said => _said.stream;

  @override
  void say(Object message) {
    if (_closed) return;
    final frame = DirectFrames.encode(message);
    if (frame.length > P2pNode.maxFrame) return;
    // One after another: each frame put once the one before it has been taken.
    _last = _last.then((_) => _closed ? null : stream.add(frame)).catchError((Object _) => close());
  }

  void _done() {
    if (!_said.isClosed) unawaited(_said.close());
    if (!_closed) {
      _closed = true;
      _onClose?.call();
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      _onClose?.call();
    }
    try {
      await stream.close();
    } catch (_) {}
    await _sub.cancel();
    // Not waited for: with nobody listening it would never be done.
    if (!_said.isClosed) unawaited(_said.close());
  }
}
