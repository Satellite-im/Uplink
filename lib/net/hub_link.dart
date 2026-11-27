/// The connection the hub's route is made over (hub_carrier.dart), apart from what carries it: a WebSocket from a
/// phone or a computer (hub_link_io.dart), the browser's own in a web page (hub_link_web.dart), or whatever another
/// [HubDial] makes: a hub in this very app, another relay, a peer-to-peer stream. Nothing here knows which.
library;

import 'hub_link_io.dart' if (dart.library.js_interop) 'hub_link_web.dart' as platform;

/// One connection to a hub, whatever carries it.
abstract class HubLink {
  /// What the hub says: a String (its JSON) or a Uint8List (a frame). Done when the link has closed.
  Stream<Object> get said;

  /// Says a String or a `List<int>` to the hub.
  void say(Object message);

  /// Closes the link; [said] is done once it has.
  Future<void> close();
}

/// A link that can say what the hub closed it with (a WebSocket's close code): 4409 where a newer connection of the
/// same device took its place (GMFB-47). Apart from [HubLink], so a link that can't say need not.
abstract class HubLinkEnd {
  /// The code it was closed with; null while open, or where none was given.
  int? get closeCode;
}

/// Makes a link to the hub at [url], open and ready to be said to; throws where it can't. How long it tries is its
/// own to decide: whoever dials waits for as long as it does.
typedef HubDial = Future<HubLink> Function(String url);

/// Dials the hub at [url] as the platform this runs on does: a WebSocket, dart:io's or the browser's. Ten seconds
/// to connect, then a TimeoutException. A relay hosted from someone's app (`ghost-relay://…`,
/// lib/relay_host/address.dart) is no WebSocket's: it is dialled as [HubDials.hosted] says.
Future<HubLink> dialHub(String url) {
  if (url.trim().toLowerCase().startsWith('ghost-relay://')) {
    final dial = HubDials.hosted;
    return dial == null ? Future.error(const HubDialRefused('A relay hosted from someone\'s app can\'t be reached from here.')) : dial(url);
  }
  return platform.dialHub(url);
}

/// Why a [dialHub] failed, in the platform's own few words: what Settings › Routes says after "Couldn't connect"
/// (relay_choice.dart).
String dialProblem(Object error) => error is HubDialRefused ? error.message : platform.dialProblem(error);

/// What a relay hosted from an app says (`{"ok": false, "err": …, "door": "full"}` in place of its hello, then closed:
/// lib/relay_host/relay_host_io.dart) where this device already has as many connections to it as it takes from one
/// device: what the app shows.
const doorFullWords = 'This relay takes only a few connections from one device at a time, and this device has them. Close Uplink elsewhere on this device, or try again in a moment.';

/// The ways to a hub that aren't a WebSocket, set by whoever has one.
abstract final class HubDials {
  /// How a relay hosted from someone's app is dialled (`ghost-relay://…`): in memory where it is this app's own, over
  /// the direct network where it is another device's (lib/relay_host, set as the routes start). Null where there is no
  /// way: a browser, a test that set none.
  static HubDial? hosted;
}

/// Why an address could not be dialled at all, in words to show.
class HubDialRefused implements Exception {
  const HubDialRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
