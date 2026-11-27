import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/bounty.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// Bounties in souls paid by the bounty key (bounty.dart; Matt, 2026-11-21: "i want you to pay the bounties for me",
/// then "A bounty key on the relay"): only that key's requests, signed, fresh and once each; souls alone, a few hundred
/// at most, with why, so many a day.
class _Key {
  _Key(int n) : scalar = List.generate(32, (i) => (n * 41 + i * 7 + 5) & 0xff) {
    public = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> public;
  int _nonce = 1;

  Map<String, String> signed(List<int> body, {int? at}) {
    final time = at ?? DateTime.now().millisecondsSinceEpoch;
    final words = Bounty.signedWords(time, hexOf(sha256(body)));
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...utf8.encode(words)]);
    _nonce++;
    return {'x-ghost-key': base64Encode(public), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(P256.sign(scalar, utf8.encode(words), nonce))};
  }
}

void main() {
  final bounty = _Key(1), stranger = _Key(2);
  const kevin = 'c6e90640d7b13c1f9b3eba7399c924f8';
  late Relay relay;
  late Uri base;
  late Map<String, int> souls;
  late List<String> whys;

  Future<void> start({String? key}) async {
    souls = {};
    whys = [];
    relay = Relay(
      bounty: Bounty(
        key: key ?? hexOf(bounty.public),
        give: (to, n, why) {
          whys.add(why);
          return souls[to] = (souls[to] ?? 0) + n;
        },
      ),
    );
    final port = await relay.start(host: '127.0.0.1', port: 0);
    base = Uri.parse('http://127.0.0.1:$port');
  }

  tearDown(() => relay.stop());

  Future<(int, Map<String, dynamic>)> pay(Map<String, Object?> body, {Map<String, String>? headers, _Key? by}) async {
    final bytes = utf8.encode(jsonEncode(body));
    final client = HttpClient();
    try {
      final req = await client.postUrl(base.replace(path: '/bounty'));
      (headers ?? (by ?? bounty).signed(bytes)).forEach(req.headers.set);
      req.add(bytes);
      final res = await req.close();
      return (res.statusCode, (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>());
    } finally {
      client.close(force: true);
    }
  }

  test('the bounty key pays souls to a tester, with why', () async {
    await start();
    final (status, said) = await pay({'to': kevin, 'souls': 50, 'why': 'GMFB-14 fixed'});
    expect(status, 200);
    expect(said['n'], 50);
    expect(souls[kevin], 50);
    expect(whys, ['GMFB-14 fixed']);
  });

  test('anyone else, a stale or replayed request, or one out of bounds is refused; nothing is given', () async {
    await start();
    expect((await pay({'to': kevin, 'souls': 50, 'why': 'x'}, by: stranger)).$1, 401, reason: 'not the bounty key');
    final body = {'to': kevin, 'souls': 50, 'why': 'GMFB-2 built'};
    final bytes = utf8.encode(jsonEncode(body));
    expect((await pay(body, headers: bounty.signed(bytes, at: DateTime.now().millisecondsSinceEpoch - 600000))).$1, 401, reason: 'ten minutes old');
    final once = bounty.signed(bytes);
    expect((await pay(body, headers: once)).$1, 200);
    expect((await pay(body, headers: once)).$1, 401, reason: 'the same request again');
    expect((await pay({'to': kevin, 'souls': 501, 'why': 'x'})).$1, 400, reason: 'more than 500 at once');
    expect((await pay({'to': kevin, 'souls': -5, 'why': 'x'})).$1, 400, reason: 'a bounty never takes');
    expect((await pay({'to': kevin, 'souls': 50, 'why': ' '})).$1, 400, reason: 'why is needed');
    expect((await pay({'to': 'nobody', 'souls': 50, 'why': 'x'})).$1, 400, reason: 'an Uplink id');
    expect(souls[kevin], 50, reason: 'only the one good request paid');
  });

  test('so many a day; off where no key is set', () async {
    await start();
    for (var i = 0; i < Bounty.mostADay; i++) {
      expect((await pay({'to': kevin, 'souls': 1, 'why': 'n$i'})).$1, 200);
    }
    expect((await pay({'to': kevin, 'souls': 1, 'why': 'one more'})).$1, 429);
    await relay.stop();
    await start(key: '');
    expect((await pay({'to': kevin, 'souls': 50, 'why': 'x'})).$1, 404);
  });
}
