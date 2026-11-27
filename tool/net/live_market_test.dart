import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';

/// The Marketplace on the relay that is really there (relay/lib/market.dart, behind gogho.st/market; Matt, 2026-11-20:
/// "I would like users to be able to develop and submit their own plugins to our plugin marketplace and I'd like to be
/// able to verify them for the store through a review process"), checked by hand after tool/deploy-relay.mjs and
/// tool/deploy-site.mjs --caddy put it there, never in CI:
///
///     flutter test tool/net/live_market_test.dart --dart-define=MARKET=https://gogho.st/market
///
/// It reads what anyone may (what the store takes, the catalog, the withdrawals), asks as a throwaway key for that key's
/// own submissions (there are none), reports a plugin that isn't there (404), and asks for an icon route there isn't
/// (404). It submits nothing and retires nothing, so it leaves nothing behind but the throwaway key's request counts.
const market = String.fromEnvironment('MARKET');

void main() {
  late HttpClient http;
  setUp(() {
    // Plain HTTP to the real server, whatever the test binding would put in its way.
    HttpOverrides.global = null;
    http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  });
  tearDown(() => http.close(force: true));

  /// [method] [path] on the market's server, signed by [as] as the app signs (relay/lib/market.dart's signedWords, the
  /// body's hash and length said up front): its status and its JSON.
  Future<(int, Map<String, dynamic>)> ask(String method, String path, {NetKeys? as, Object? json}) async {
    final url = Uri.parse(market).replace(path: path);
    final body = json == null ? const <int>[] : utf8.encode(jsonEncode(json));
    final req = await http.openUrl(method, url);
    if (as != null) {
      final time = DateTime.now().millisecondsSinceEpoch;
      final sha = NetCrypto.hex(NetCrypto.sha256(body));
      req.headers
        ..set('x-ghost-key', base64Encode(as.public))
        ..set('x-ghost-time', '$time')
        ..set('x-ghost-sig', base64Encode(NetCrypto.sign(as, utf8.encode('ghost-market v1\n$method\n${url.path}\n$time\n$sha'))));
      if (method != 'GET' && method != 'DELETE') {
        req.headers
          ..set('x-ghost-body-sha256', sha)
          ..set('x-ghost-body-length', '${body.length}');
      }
    }
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final words = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
    return (res.statusCode, (jsonDecode(words) as Map).cast<String, dynamic>());
  }

  test('the Marketplace at $market: read by anyone, asked by a throwaway key, nothing left behind', () async {
    expect(market, isNotEmpty, reason: 'say where: --dart-define=MARKET=https://…/market');
    final (status, info) = await ask('GET', '/market');
    expect([status, info['ok'], info['market'], info['format']], [200, true, 1, 'ghost-plugin/1']);
    debugPrint('open: ${info['open']}; limits: ${info['limits']}');

    final (catalogStatus, catalog) = await ask('GET', '/market/catalog');
    expect([catalogStatus, catalog['ok'], catalog['v']], [200, true, 1]);
    expect(catalog['plugins'], isA<List>());
    final (revokedStatus, revoked) = await ask('GET', '/market/revoked');
    expect([revokedStatus, revoked['ok'], revoked['v']], [200, true, 1]);
    expect([revoked['revoked'], revoked['retired']], [isA<List>(), isA<List>()]);
    debugPrint('${(catalog['plugins'] as List).length} listed, ${(revoked['revoked'] as List).length} withdrawn, ${(revoked['retired'] as List).length} keys retired');

    final throwaway = NetKeys.generate();
    final (mineStatus, mine) = await ask('GET', '/market/mine', as: throwaway);
    expect([mineStatus, mine['ok'], mine['blocked'], mine['submissions'], mine['plugins']], [200, true, false, isEmpty, isEmpty], reason: 'a key nobody has seen: signed, and nothing of its own');

    final none = 'nosuchplugin${DateTime.now().millisecondsSinceEpoch % 100000}';
    final (reportStatus, report) = await ask('POST', '/market/report', as: throwaway, json: {'plugin': none, 'version': '1.0.0', 'reason': 'other', 'text': 'A live check after a deploy: there is no such plugin.'});
    expect([reportStatus, report['ok'], report['error']], [404, false, 'not_found']);

    final (iconStatus, icon) = await ask('GET', '/market/packages/${'0' * 64}/icon');
    expect([iconStatus, icon['ok'], icon['error']], [404, false, 'not_found'], reason: 'no icon route: the app draws a listing\'s icon from its checked package');
  });
}
