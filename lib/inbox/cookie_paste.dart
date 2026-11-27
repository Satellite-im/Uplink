import 'dart:convert';

/// What was pasted, read as a browser's cookies: a request copied from the browser's developer tools ("Copy as cURL",
/// bash or Windows cmd), a `Cookie:` header, a JSON object of names and values, or `name=value; …`. Only those in
/// [names] are kept (all of them where [names] is empty). As lib/gm/google_signin.dart reads Google's, for any site:
/// the account helpers sign in this way (sidecar/ACCOUNT_HELPERS.md).
Map<String, String> cookiesIn(String pasted, {Set<String> names = const {}}) {
  final text = pasted.trim();
  final found = <String, String>{};
  bool wanted(String name) => names.isEmpty || names.contains(name);
  // Takes the wanted cookies out of `name=value; name=value`.
  void take(String pairs) {
    for (final part in pairs.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final name = part.substring(0, i).trim();
      var value = part.substring(i + 1).trim();
      // LinkedIn's JSESSIONID is kept in quotes ("ajax:123"); the quotes are part of how it is written, not of it.
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1);
      if (wanted(name) && value.isNotEmpty) found[name] = value;
    }
  }

  if (text.startsWith('{')) {
    try {
      final m = jsonDecode(text);
      if (m is Map) {
        for (final e in m.entries) {
          if (wanted('${e.key}') && '${e.value}'.isNotEmpty) found['${e.key}'] = '${e.value}';
        }
        return found;
      }
    } catch (_) {}
  }
  // Windows' cmd form escapes with ^; its quotes are double.
  final unescaped = text.replaceAll('^"', '"').replaceAll('^%', '%').replaceAll('^&', '&').replaceAll('^\\^', '^');
  // -H 'cookie: …' / -H "Cookie: …". Bash's form is in single quotes, so a double quote inside it is the value's own.
  for (final m in RegExp(r"-H\s+'[Cc]ookie:\s*(.*?)'", dotAll: true).allMatches(unescaped)) {
    take(m.group(1)!);
  }
  if (found.isEmpty) {
    for (final m in RegExp(r'-H\s+"[Cc]ookie:\s*((?:[^"\\]|\\.)*)"', dotAll: true).allMatches(unescaped)) {
      take(m.group(1)!.replaceAll(r'\"', '"'));
    }
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

/// Those of [needed] that [cookies] lacks, for saying what to copy again.
List<String> cookiesMissing(Map<String, String> cookies, Iterable<String> needed) => [for (final n in needed) if (!cookies.containsKey(n)) n];

/// The session token in what was pasted, for a service that signs in with one beside its cookies (Discord, Slack;
/// lib/inbox/account_helper.dart): Slack's xoxc- token wherever it is (a form field, a multipart part, the address),
/// else a copied request's authorization header (Discord's is the token itself), else a token pasted alone.
String? tokenIn(String pasted) {
  final text = pasted.trim();
  final slack = RegExp(r'xoxc-[A-Za-z0-9-]+').firstMatch(text);
  if (slack != null) return slack.group(0);
  final unescaped = text.replaceAll('^"', '"');
  final header = RegExp(r"""-H\s+['"][Aa]uthorization:\s*([^'"\s]+)['"]""").firstMatch(unescaped) ??
      RegExp(r'^[Aa]uthorization:\s*(\S+)\s*$', multiLine: true).firstMatch(unescaped);
  if (header != null) return header.group(1);
  // A token alone: one long word with no spaces, cookies or quotes in it.
  if (RegExp(r'^[A-Za-z0-9._-]{50,}$').hasMatch(text)) return text;
  return null;
}
