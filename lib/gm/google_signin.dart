import 'dart:convert';

/// Pairing Google Messages by the person's Google account (Matt, 2026-11-15, of Device pairing on his Fold: "it seems
/// they removed the ability to do it with the QR code"; mautrix-gmessages' docs agree, "it appears Google has killed
/// it"). The helper (sidecar/gmessages, `pair_google`) needs the cookies of a browser signed in to that account at
/// messages.google.com/web/config; the person signs in there in a private window (so the browser does not go on
/// changing them) and copies that request from the browser's developer tools ("Copy as cURL").

/// Where to sign in: Google's account chooser, coming back to messages.google.com's config, which signs the browser
/// in to the account without pairing it.
const googleSignInUrl = 'https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config';

/// The cookies the helper needs; `__Secure-1PSIDTS` is taken too where it is there.
const googleCookieNames = ['SID', 'HSID', 'SSID', 'OSID', 'APISID', 'SAPISID', '__Secure-1PSIDTS'];
const googleCookiesNeeded = ['SID', 'HSID', 'SSID', 'OSID', 'APISID', 'SAPISID'];

/// What was pasted, read as Google's cookies: a "Copy as cURL" (bash or Windows cmd), a `Cookie:` header, a JSON
/// object of names and values, or `name=value; …`. Only the ones the helper needs are kept.
Map<String, String> googleCookiesIn(String pasted) {
  final text = pasted.trim();
  final found = <String, String>{};
  // Keeps the wanted cookies out of `name=value; name=value`.
  void take(String pairs) {
    for (final part in pairs.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final name = part.substring(0, i).trim();
      final value = part.substring(i + 1).trim();
      if (googleCookieNames.contains(name) && value.isNotEmpty) found[name] = value;
    }
  }

  if (text.startsWith('{')) {
    try {
      final m = jsonDecode(text);
      if (m is Map) {
        for (final e in m.entries) {
          if (googleCookieNames.contains('${e.key}') && '${e.value}'.isNotEmpty) found['${e.key}'] = '${e.value}';
        }
        return found;
      }
    } catch (_) {}
  }
  // Windows' cmd form escapes with ^; its quotes are double.
  final unescaped = text.replaceAll('^"', '"').replaceAll('^%', '%').replaceAll('^&', '&').replaceAll('^\\^', '^');
  // -H 'cookie: …' / -H "Cookie: …"
  for (final m in RegExp(r'''-H\s+(['"])[Cc]ookie:\s*(.*?)\1''', dotAll: true).allMatches(unescaped)) {
    take(m.group(2)!);
  }
  // -b '…' / --cookie '…'
  for (final m in RegExp(r'''(?:-b|--cookie)\s+(['"])(.*?)\1''', dotAll: true).allMatches(unescaped)) {
    take(m.group(2)!);
  }
  if (found.isEmpty) {
    // A header as it is, or the pairs alone.
    final header = RegExp(r'^[Cc]ookie:\s*(.*)$', multiLine: true).firstMatch(unescaped);
    take(header != null ? header.group(1)! : unescaped);
  }
  return found;
}

/// The ones still missing from [cookies], for saying what to copy again.
List<String> googleCookiesMissing(Map<String, String> cookies) => [for (final n in googleCookiesNeeded) if (!cookies.containsKey(n)) n];
