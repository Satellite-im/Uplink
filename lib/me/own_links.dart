import 'package:flutter/foundation.dart';

/// A link someone typed on their own profile (GMFB-34: "Linked accounts shown on the profile (self-declared links)"):
/// what they call it ("Website", "GitHub") and an https address. Nothing checks that the place is theirs, so a card
/// says "says" beside it, and it is opened only on a press, with the whole address shown first.
///
/// Sent to friends with the profile (`ol`, lib/friends/buddies.dart) as `[{"l": label, "u": address}]`, [most] at
/// most; a build from before passes it over. What comes is read by the same rules as what is typed ([problemOf]), so a
/// link that could not be typed here is never shown here.
@immutable
class OwnLink {
  const OwnLink(this.label, this.address);
  final String label;
  final String address;

  /// How many a profile has at most, and how long a label and an address may be.
  static const most = 5;
  static const labelMost = 24;
  static const addressMost = 200;

  /// The address without its "https://" and a lone "/" at its end: what a card shows in a row.
  String get short {
    final s = address.substring('https://'.length);
    return s.endsWith('/') && s.indexOf('/') == s.length - 1 ? s.substring(0, s.length - 1) : s;
  }

  /// Where the address goes: its host, as the press says it first ("github.com").
  String get host => Uri.parse(address).host;

  Map<String, String> toJson() => {'l': label, 'u': address};

  /// A label as typed, made one line with no spaces at its ends.
  static String tidyLabel(String label) => label.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// An address as typed: spaces at its ends gone, and "https://" put before one written without it ("example.com").
  static String tidyAddress(String address) {
    final a = address.trim();
    return a.isEmpty || a.contains('://') ? a : 'https://$a';
  }

  // Anything that is not drawn as itself: control characters, and the marks that turn text round or hide in it.
  static final _unseen = RegExp(r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]', unicode: true);

  /// Why [label] and [address] (each tidied) can't be a link, in words for the person; null where they can.
  static String? problemOf(String label, String address) {
    if (label.isEmpty) return 'Give the link a name, like Website.';
    if (label.runes.length > labelMost) return 'A link\'s name is $labelMost characters at most.';
    if (_unseen.hasMatch(label)) return 'That name has a character that can\'t be shown.';
    if (address.isEmpty) return 'Type the link\'s address.';
    if (address.length > addressMost) return 'An address is $addressMost characters at most.';
    if (_unseen.hasMatch(address) || address.contains(RegExp(r'\s'))) return 'An address has no spaces in it.';
    if (!address.startsWith('https://')) return 'Only https:// addresses can be added.';
    if (address.contains('\\')) return 'That isn\'t an address.';
    // The site's name as it is written, which is how it is shown: no name and password before it
    // ("https://bank.com@elsewhere.example" reads as the bank), nothing spelled with a % in it, a name with a dot in
    // plain letters, and no port but the usual one.
    var site = address.substring('https://'.length).split(RegExp('[/?#]')).first;
    if (site.endsWith(':443')) site = site.substring(0, site.length - 4);
    if (site.length > 100 || !_host.hasMatch(site)) return 'An address needs a site\'s name, like example.com.';
    try {
      if (Uri.parse(address).host.toLowerCase() != site.toLowerCase()) return 'That isn\'t an address.';
    } catch (_) {
      return 'That isn\'t an address.';
    }
    return null;
  }

  static final _host = RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,22}[a-z0-9]$', caseSensitive: false);

  /// The links said in [j], as sent or kept: each a label and an address that could be typed here, the first [most],
  /// one of each address. Null where [j] is not a list (nothing was said: a build from before).
  static List<OwnLink>? listOf(Object? j) {
    if (j is! List) return null;
    final out = <OwnLink>[];
    for (final x in j.take(most * 4)) {
      if (x is! Map) continue;
      final l = x['l'], u = x['u'];
      if (l is! String || u is! String || l.length > labelMost * 4 || u.length > addressMost) continue;
      final label = tidyLabel(l);
      if (problemOf(label, u) != null || out.any((o) => o.address == u)) continue;
      out.add(OwnLink(label, u));
      if (out.length >= most) break;
    }
    return out;
  }

  @override
  bool operator ==(Object other) => other is OwnLink && other.label == label && other.address == address;

  @override
  int get hashCode => Object.hash(label, address);
}
