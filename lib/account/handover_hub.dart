import 'dart:async';
import 'dart:typed_data';

import '../net/hub_carrier.dart';
import '../net/net.dart';
import 'handover.dart';

/// The room a new device and a phone meet in to sign in by a scanned code (GMFB-45; handover.dart), on the relay's hub
/// as the app is connected to it: an ordinary room (HubCarrier.join), as a voice room or a QR shown on another screen
/// (lib/net/pair_room.dart) is, so the relay as it runs today carries it. Its packets are passed on and never kept
/// ([HubCarrier.sendRoom] without `keep`). The relay is asked to stay connected for as long as the room is held: a
/// device signed in to nothing has nobody to reach, and would not dial out otherwise ([Net.want]).
class HubHandoverRoom implements HandoverRoom {
  /// [hub]: a test's hub in the app's place (then nothing is asked of [Net]).
  HubHandoverRoom({HubCarrier? Function()? hub}) : _find = hub;
  final HubCarrier? Function()? _find;

  static const _who = 'signin';
  final _heard = StreamController<Uint8List>.broadcast();
  StreamSubscription<Object?>? _sub;
  HubCarrier? _hub;
  String? _name;
  bool _left = false;

  @override
  Stream<Uint8List> get heard => _heard.stream;

  @override
  Future<void> join(String name, String token) async {
    if (_find == null) await Net.instance.want(_who, true);
    // The hub is made a moment after the app starts (Net.start), so it is waited for, ten seconds at most.
    HubCarrier? hub;
    for (var i = 0; i < 40 && !_left; i++) {
      hub = _find != null ? _find() : Net.instance.hub;
      if (hub != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (hub == null || _left) {
      leave();
      throw StateError('no relay');
    }
    _hub = hub;
    _name = name;
    _sub = hub.roomPackets.where((p) => p.room == name).listen((p) => _heard.add(p.bytes));
    try {
      await hub.join(name, token).timeout(const Duration(seconds: 12));
    } catch (_) {
      leave();
      rethrow;
    }
  }

  @override
  void say(Uint8List packet) {
    final hub = _hub, name = _name;
    if (hub == null || name == null) throw StateError('not in the room');
    hub.sendRoom(name, packet);
  }

  @override
  void leave() {
    if (_left) return;
    _left = true;
    _sub?.cancel();
    _sub = null;
    final name = _name;
    if (name != null) _hub?.leave(name);
    _hub = null;
    _name = null;
    if (_find == null) unawaited(Net.instance.want(_who, false));
  }
}
