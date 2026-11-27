/// Speaking to the relay's keeper of waiting invites (relay/lib/invites.dart) over the hub: leaving sealed invites for
/// numbers not on Uplink yet, and, on the install that verified a number, taking those left for it.
library;

import 'dart:async';

import '../net/carrier.dart' show CarrierState;
import '../net/hub_carrier.dart';
import '../net/net.dart';

/// Why the relay could not be asked, or what it refused.
class InviteRelayError implements Exception {
  const InviteRelayError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One question to the relay and its answer: [what] says `{"dir": …}`, and the answer is the message that comes back
/// with the same `dir`, or an error about it.
typedef InviteAsk = Future<Map<String, dynamic>> Function(Map<String, Object?> what);

/// Asks [hub], which must be up, and waits up to [wait] for the answer.
Future<Map<String, dynamic>> askHub(HubCarrier hub, Map<String, Object?> what, {Duration wait = const Duration(seconds: 15)}) async {
  final dir = what['dir'];
  final done = Completer<Map<String, dynamic>>();
  final sub = hub.handles.listen((m) {
    if (done.isCompleted) return;
    if (m['dir'] == dir) done.complete(m);
    if (m['dir'] == 'err' && m['about'] == dir) done.completeError(InviteRelayError((m['err'] as String?) ?? 'The relay server said no.'));
  });
  try {
    if (!hub.sayHandles(what)) throw const InviteRelayError('The relay server can\'t be reached right now.');
    // A relay from before invites were kept (0.9.2's) does not answer at all: given up on, never waited on for long.
    return await done.future.timeout(wait, onTimeout: () => throw const InviteRelayError('The relay server did not answer.'));
  } finally {
    await sub.cancel();
  }
}

/// Asks the relay over the app's own connection, where it is up. Leaving invites needs someone the relay knows (a
/// verified number or a linked account, relay/lib/invites.dart), so there is no asking over a connection made for the
/// question with a key of its own: a paired computer has the phone leave them (lib/invites/text_invites.dart), since
/// the phone is what sends the texts anyway.
Future<Map<String, dynamic>> askAnyHub(Map<String, Object?> what) async {
  final own = Net.instance.hub;
  if (own != null && own.state.value == CarrierState.up) return askHub(own, what);
  throw const InviteRelayError('The relay server can\'t be reached right now.');
}
