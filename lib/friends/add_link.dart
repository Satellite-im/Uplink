/// Someone's add-me link (GMFB-34: "A gogho.st/add/USERNAME link and QR code that opens a friend request"):
/// `https://gogho.st/add/USERNAME#KEY`, shown with its QR code in Profile and shared from there. Opened, the app asks
/// whether to send that person a friend request (lib/main.dart); the site's page (site/add) does the same for someone
/// without the app, leading to it.
///
/// `#KEY` is the person's whole account name, 32 hex digits (the first 16 bytes of the SHA-256 of their key, as
/// NetCrypto.idOf makes it), after `#` so a browser never sends it to any server (docs/OPEN_NETWORK.md, section 3: the
/// name watch). The app refuses the relay's answer for the username where its key doesn't make that name
/// (Buddies.add's keyPrefix): a relay that gives the username to someone else can't slip them in through the link. All
/// 32 digits, not 8 (the review, S3): 8 is 32 bits, and a relay could search out a key whose name begins the same in some
/// four thousand million tries. A link from before, with 8, is still taken as it says.
///
/// **Which relay** (GMFB-25). A username is a name on one relay, so a link from someone on a relay of their own says
/// which, after the key: `#KEY@relay.example.com`. Still after `#`, so no server is told it, and still under gogho.st's
/// address, whose page (site/add) carries it into the app. A link with none is someone on Uplink's relay. The
/// app asks that relay for the name (Buddies.add as `name@relay`), and the key holds the answer to the person who
/// shared the link whichever relay gives it.
library;

import '../me/me.dart' show Me;
import '../net/home_record.dart' show goodRelayHost;

/// How many hex digits of the account name an add-me link carries (all of it), and the fewest one is taken with (a link
/// made before it carried all).
const keyDigits = 32, fewestKeyDigits = 8;

/// [username]'s add-me link, with [id] (their account name, all [keyDigits] hex digits of it) after `#` where given,
/// and after that the [relay] the username is on (its host, with its port where it has one) where that is not Uplink's
/// own. A relay is named only with a key: it is the key that holds whatever that relay answers to them.
String addMeLink(String username, {String? id, String? relay}) {
  if (id == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return 'https://gogho.st/add/$username';
  final at = relay?.trim().toLowerCase();
  return 'https://gogho.st/add/$username#${id.substring(0, keyDigits)}${at != null && goodRelayHost(at) ? '@$at' : ''}';
}

/// The username an add-me link names ([addMeLink], or the app's own `ghostmsg://add/NAME`), tidied; null for
/// anything else, or a name that cannot be a username.
String? addLinkUsername(String? text) {
  if (text == null) return null;
  final m = RegExp(r'(?:https?://(?:www\.)?gogho\.st/add/|ghostmsg://add/)@?([A-Za-z0-9._]+)/?(?:[?#].*)?$').firstMatch(text.trim());
  if (m == null) return null;
  final name = m.group(1)!.toLowerCase();
  return Me.goodUsername(name) ? name : null;
}

/// The key digits an add-me link carries after `#` (lower case): [fewestKeyDigits] to [keyDigits] hex digits; null
/// where it carries none (a link from before), or anything else there.
String? addLinkKey(String? text) {
  if (text == null || addLinkUsername(text) == null) return null;
  final t = text.trim(), at = t.indexOf('#');
  if (at < 0) return null;
  final after = t.substring(at + 1).toLowerCase();
  final relay = after.indexOf('@');
  final key = relay < 0 ? after : after.substring(0, relay);
  return RegExp('^[0-9a-f]{$fewestKeyDigits,$keyDigits}\$').hasMatch(key) ? key : null;
}

/// The relay an add-me link says its username is on, after the key (`#KEY@relay.example.com`): its host, lower case,
/// with its port where it has one. Null where it names none (someone on Uplink's relay, or a link from
/// before), has no key, or what follows the `@` could not be a relay's host.
String? addLinkRelay(String? text) {
  if (addLinkKey(text) == null) return null;
  final t = text!.trim();
  final after = t.substring(t.indexOf('#') + 1).toLowerCase();
  final at = after.indexOf('@');
  if (at < 0) return null;
  final host = after.substring(at + 1);
  return goodRelayHost(host) ? host : null;
}
