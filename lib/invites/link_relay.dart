import '../net/home_record.dart' show goodRelayHost;

/// Which relay an invite link's circle or space is on (GMFB-25: "The app works fully against a self-hosted hub";
/// checked against the code on 2026-11-25: "add-me and invite links know only gogho.st"). A circle and a space are
/// rooms on one relay, and their links named none: opened by someone whose app used another relay, the app joined the
/// same rooms there, where nobody was, and said nothing.
///
/// A link made while the app uses a relay other than Uplink's own ends with that relay's host after an `@`:
///
///     https://gogho.st/join/#c.<seed>.<name>.<owner>@relay.example.com
///     https://gogho.st/join/#<seed>.<name>.<owner>.text@relay.example.com:8443
///
/// Still after `#`, so no server is told it, and still under gogho.st's address, whose page reads it (site/join). A
/// link made on Uplink's relay names none, as every link did before, so an older build reads those as it
/// always has; one that names a relay is no link at all to a build from before, which would only have joined an empty
/// room with it.
abstract final class LinkRelay {
  /// The relay the links this app makes name: its host (and port, where it has one of its own) while the app uses a
  /// relay other than Uplink's; null on ours, for a relay no link can name (lib/net/relay_choice.dart,
  /// relayHostForLinks), and where nothing set this (a test). Set as the routes start (lib/net/net.dart).
  static String? Function()? here;

  /// A relay's host at the end of a link, after an `@`: as [goodRelayHost] takes one. As a pattern's end, for whatever
  /// reads a link out of other words ([Circles.linkIn]): a full stop after the link is not part of it.
  static const pattern = r'(?:@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+(?::[0-9]{1,5})?)?';

  /// [link], naming the relay this app is on where that is not Uplink's own.
  static String mark(String link) {
    final host = here?.call()?.toLowerCase();
    return host == null || !goodRelayHost(host) ? link : '$link@$host';
  }

  /// [link] without the relay it names, and that relay: null where it names none, or what follows its last `@` could
  /// not be a relay's host (then the link is left as it is, for whoever reads it to refuse).
  static ({String link, String? relay}) split(String link) {
    final at = link.lastIndexOf('@');
    final hash = link.indexOf('#');
    if (at < 0 || (hash >= 0 && at < hash)) return (link: link, relay: null);
    final host = link.substring(at + 1).toLowerCase();
    return goodRelayHost(host) ? (link: link.substring(0, at), relay: host) : (link: link, relay: null);
  }

  /// Where [link] names a relay other than the one this app uses, that relay's host; null where it names none (it is
  /// taken to be here, as every link from before is) or names this one. [mine]: this app's relay as a link names it,
  /// null on Uplink's own; [isHere]: whether a host is this app's relay under another of its names.
  static String? elsewhere(String link, {required String? mine, bool Function(String host)? isHere}) {
    final theirs = split(link).relay;
    if (theirs == null || theirs == mine || (isHere?.call(theirs) ?? false)) return null;
    return theirs;
  }

  /// What is said in place of joining, where an invite's circle or space is on another relay ([theirs]) than this
  /// app's ([mine], as Settings › Routes names it).
  static String elsewhereWords(String theirs, {required String mine, bool space = false}) =>
      'This ${space ? 'space' : 'circle'} is on the relay $theirs, and you use $mine. A circle and its spaces are on the relay they were made on: to join, use that relay first (Settings › Routes › Relay server).';
}
