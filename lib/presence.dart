/// Who is on, wherever someone's face is drawn (lib/ui/common.dart Avatar; Matt, 2026-11-17: "activity presence
/// sensing for friends and conacts on telegram and signal to be able to tell if a friend is online on a given plaform
/// anywhere the users avatar is shown", and "especially required for our own API reporting presence sensing within the
/// app for users who have signed up for a username and are part of our own system").
///
/// Uplink's own first: someone this phone shares keys with (by their number) or a friend by username
/// (`@name`), as the relay server's hub says they come and go and put the app away (lib/net/hub_carrier.dart). Then
/// the other networks that say so (Telegram; lib/inbox/inbox.dart). Online anywhere wins.
library;

import 'package:flutter/foundation.dart';

import 'friends/buddies.dart';
import 'friends/friends.dart';
import 'inbox/inbox.dart';
import 'net/net.dart';

/// Asks who is on, by address. Nothing is kept here: each answer is read from the networks' own stores.
class Presence {
  Presence._();

  /// Told whenever anyone's presence changes, on our own system or another network.
  static Listenable get changes => Listenable.merge([Net.instance.presence, Inbox.instance.presenceChanges]);

  /// The install name on our own system of whoever [address] names: a friend by username (`@name`), the one that
  /// username stands for (Buddies.standingFor: never a request not yet answered, or someone blocked, that gave the same
  /// username); or someone this phone shares keys with, by their number: the id the encryption record for that number
  /// names (Friends.idOf), never whoever the routes happen to hold under it (a member of a group, under a number its
  /// admin wrote). Both found in review, 2026-11-23. Null for anyone else.
  static String? ghostIdOf(String address) {
    if (address.startsWith('@')) return Buddies.instance.standingFor(address)?.id;
    if (address.contains(':')) return null;
    return Friends.instance.idOf(address);
  }

  /// Whether the install named [id] is on our own system now, or when it was last seen, as the relay's hub says: by
  /// its name, for whoever is known by it already (one of the routes' people, a friend by username).
  static InboxPresence? ofId(String id) {
    // A friend on another relay: who is here doesn't cross relays yet (docs/OPEN_NETWORK.md, section 4), and what this
    // relay last saw of them (before they moved away, say) would only mislead. Nothing is shown.
    final buddy = Buddies.instance.byId(id);
    if (buddy != null && Buddies.instance.apart(buddy)) return null;
    final g = Net.instance.presenceOfId(id);
    return g == null ? null : InboxPresence(network: 'Uplink', online: g.online, lastSeen: g.lastSeen, away: g.away, busy: g.busy);
  }

  /// Whether whoever [address] names is on now, and where; or when they were last seen. Null where nothing is known.
  static InboxPresence? of(String address) {
    final id = ghostIdOf(address);
    final ghost = id == null ? null : ofId(id);
    // Busy or away on Uplink is how they chose to be shown: it wins over being online elsewhere.
    if (ghost != null && (ghost.online || ghost.busy || ghost.away)) return ghost;
    final other = Inbox.instance.presenceOfAddress(address);
    if (other != null && other.online) return other;
    if (ghost == null) return other;
    if (other == null) return ghost;
    // Neither on: whichever saw them last.
    final a = ghost.lastSeen, b = other.lastSeen;
    if (a == null) return other;
    if (b == null) return ghost;
    return a.isAfter(b) ? ghost : other;
  }
}
