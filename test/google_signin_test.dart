import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/gm/google_signin.dart';

/// Reading a pasted sign-in into Google's cookies (lib/gm/google_signin.dart; Matt, 2026-11-15: "it seems they removed
/// the ability to do it with the QR code").
void main() {
  const all = 'SID=s1; HSID=h1; SSID=ss1; OSID=o1; APISID=a1; SAPISID=sa1; __Secure-1PSIDTS=t1; NID=other';

  test('a bash "Copy as cURL" from Chrome', () {
    final c = googleCookiesIn("curl 'https://messages.google.com/web/config' \\\n  -H 'accept: */*' \\\n  -H 'cookie: $all' \\\n  -H 'user-agent: x'");
    expect(c, {'SID': 's1', 'HSID': 'h1', 'SSID': 'ss1', 'OSID': 'o1', 'APISID': 'a1', 'SAPISID': 'sa1', '__Secure-1PSIDTS': 't1'});
    expect(googleCookiesMissing(c), isEmpty);
  });

  test('Firefox\'s -b form and Windows cmd\'s ^" escaping', () {
    expect(googleCookiesIn("curl 'https://messages.google.com/web/config' -b '$all'")['SAPISID'], 'sa1');
    expect(googleCookiesIn('curl ^"https://messages.google.com/web/config^" -H ^"cookie: $all^"')['OSID'], 'o1');
  });

  test('a header, the pairs alone, or JSON', () {
    expect(googleCookiesIn('Cookie: $all')['SID'], 's1');
    expect(googleCookiesIn(all)['HSID'], 'h1');
    expect(googleCookiesIn('{"SID":"s1","HSID":"h1","SSID":"ss1","OSID":"o1","APISID":"a1","SAPISID":"sa1","NID":"x"}').length, 6);
  });

  test('what is missing is said, and nothing else is kept', () {
    final c = googleCookiesIn('-H \'cookie: SID=s1; NID=n\'');
    expect(c, {'SID': 's1'});
    expect(googleCookiesMissing(c), ['HSID', 'SSID', 'OSID', 'APISID', 'SAPISID']);
    expect(googleCookiesIn('nothing useful here'), isEmpty);
  });
}
