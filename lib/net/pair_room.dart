import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'net.dart';
import '../invites/link_relay.dart';

/// A QR code shown on another screen, for a phone that cannot scan its own (Google Messages' Device pairing, Signal's
/// Link new device): a room on Uplink's relay whose name, token and key come from a secret in a link
/// (`https://gogho.st/pair/#<secret>`). The page at that link joins the room and draws each code said in it, sealed
/// with the key, so the relay carries what it cannot read. Made from lib/ui/gm_web_screen.dart's, for Signal too.
class PairRoom {
  // The link's secret, with the room's name and key made from it; the code last said; and the listener for the
  // page joining.
  Uint8List? _secret;
  String? _room;
  Uint8List? _key;
  String? _said;
  String? _last;
  bool _joined = false;
  Timer? _again;
  StreamSubscription<Object?>? _came;

  /// How often the code as it is now is said again, for a page that joined while this phone could not hear it (a
  /// reconnect, the app behind the share sheet): GMFB-15, a page that never got a code drew an empty white box.
  static const sayAgain = Duration(seconds: 6);

  /// The page's address, once the room is open.
  ///
  /// The room is on the relay this app uses, so where that is not Uplink's own the address names it after the
  /// secret (lib/invites/link_relay.dart; GMFB-25): the page dialled gogho.st's hub whatever relay the app was on, and
  /// waited in a room the app was never in.
  String? get link => _secret == null ? null : LinkRelay.mark('https://gogho.st/pair/#${NetCrypto.hex(_secret!)}');

  /// Joined on the relay: only then does a page at [link] get anything.
  bool get open => _joined;

  /// Opens the room; [onCame] is told when the page joins, so it is given the code as it is now. False where the relay
  /// could not be reached in ten seconds: nothing would reach a page then, so the link is not worth sharing.
  Future<bool> openRoom({void Function()? onCame}) async {
    final r = Random.secure();
    final secret = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
    _secret = secret;
    _room = NetCrypto.hex(NetCrypto.derive(secret, 'gmpair room').sublist(0, 16));
    _key = NetCrypto.derive(secret, 'gmpair key');
    final token = NetCrypto.hex(NetCrypto.derive(secret, 'gmpair token'));
    await Net.instance.want('gmpair', true);
    for (var i = 0; i < 20 && !_joined; i++) {
      final hub = Net.instance.hub;
      if (hub != null) {
        try {
          await hub.join(_room!, token);
          _joined = true;
          break;
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!_joined) {
      _secret = null;
      _room = null;
      _key = null;
      unawaited(Net.instance.want('gmpair', false));
      return false;
    }
    // Anyone arriving (the page's `came`, or the room's member list after this phone reconnects) is given the code
    // as it is now.
    _came = Net.instance.hub?.roomEvents.where((e) => e.room == _room && ((e.came?.isNotEmpty ?? false) || (e.members?.isNotEmpty ?? false))).listen((_) {
      _said = null;
      onCame?.call();
    });
    _again = Timer.periodic(sayAgain, (_) {
      final url = _last;
      if (url != null) _say({'t': 'qr', 'url': url});
    });
    return true;
  }

  /// Draws [url] as the page's QR code (said again only when it changes).
  void showCode(String url) {
    _last = url;
    if (url == _said) return;
    if (_say({'t': 'qr', 'url': url})) _said = url;
  }

  /// Tells the page it is done, and stops saying the code again.
  void done() {
    _again?.cancel();
    _last = null;
    _say({'t': 'paired'});
  }

  /// Says [m] in the room, sealed with its key; false where there is no room, or the relay can't take it.
  bool _say(Map<String, Object?> m) {
    final room = _room, key = _key, hub = Net.instance.hub;
    if (room == null || key == null || hub == null) return false;
    try {
      hub.sendRoom(room, NetCrypto.seal(key, utf8.encode(jsonEncode(m))));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Leaves the room, and no longer asks for the relay to be kept connected for it.
  void close() {
    _came?.cancel();
    _again?.cancel();
    _again = null;
    _joined = false;
    _last = null;
    final room = _room;
    if (room != null) Net.instance.hub?.leave(room);
    _room = null;
    _key = null;
    _said = null;
    unawaited(Net.instance.want('gmpair', false));
  }
}
