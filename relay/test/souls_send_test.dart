import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/files_roster.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:ghost_relay/souls_send.dart';
import 'package:test/test.dart';

/// Souls sent from one person to another (souls_send.dart, Handles.sendSouls; GMFB-39, Matt, 2026-11-23: "Tip souls
/// in a chat"): signed by the sender, moved whole and once, never made or lost, within the day's limits, and kept.
class _Key {
  _Key(int n) : scalar = List.generate(32, (i) => (n * 41 + i * 7 + 5) & 0xff) {
    public = P256.publicOf(scalar);
    id = FilesRoster.idOf(public);
  }
  final List<int> scalar;
  late final List<int> public;
  late final String id;
  int _nonce = 1;

  Map<String, String> signed(String path, List<int> body, {int? at}) {
    final time = at ?? DateTime.now().millisecondsSinceEpoch;
    final words = SoulsSend.signedWords(path, time, hexOf(sha256(body)));
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...utf8.encode(words)]);
    _nonce++;
    return {'x-ghost-key': base64Encode(public), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(P256.sign(scalar, utf8.encode(words), nonce))};
  }
}

void main() {
  final maya = _Key(1), kevin = _Key(2), stranger = _Key(3);
  late Directory dir;
  late Handles handles;
  late Relay relay;
  late Uri base;
  late DateTime clock;
  var made = 0;

  /// A sending's own name, afresh.
  String fresh() => (++made).toRadixString(16).padLeft(32, '0');

  Future<void> open() async {
    handles = Handles(dataDir: dir, now: () => clock)..load();
    relay = Relay(souls: SoulsSend(send: handles.sendSouls, receiptOf: handles.soulsReceipt, soulsOf: handles.soulsOf, now: () => clock));
    final port = await relay.start(host: '127.0.0.1', port: 0);
    base = Uri.parse('http://127.0.0.1:$port');
  }

  /// [who] with a username here, as the app claims one over its hub connection.
  Future<void> named(_Key who, String name) async {
    handles.came(who.id, (_) {}, key: who.public);
    await handles.said(who.id, {'dir': 'claim', 'name': name});
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('souls_send_test');
    clock = DateTime.now();
    await open();
    await named(maya, 'maya');
    await named(kevin, 'kevin');
    handles.giveBounty(maya.id, 100, 'GMFB-1 fixed');
  });

  tearDown(() async {
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> ask(String path, Map<String, Object?> body, {_Key? by, Map<String, String>? headers}) async {
    final bytes = utf8.encode(jsonEncode(body));
    final client = HttpClient();
    try {
      final req = await client.postUrl(base.replace(path: path));
      (headers ?? (by ?? maya).signed(path, bytes, at: clock.millisecondsSinceEpoch)).forEach(req.headers.set);
      req.add(bytes);
      final res = await req.close();
      return (res.statusCode, (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>());
    } finally {
      client.close(force: true);
    }
  }

  Future<(int, Map<String, dynamic>)> send(int souls, {_Key? by, String? to, String? id}) => ask('/souls/send', {'to': to ?? kevin.id, 'souls': souls, 'id': id ?? fresh()}, by: by);

  int all() => handles.soulsOf(maya.id) + handles.soulsOf(kevin.id) + handles.soulsOf(stranger.id);

  test('souls move from the sender to a friend, with a receipt either of them can check', () async {
    final told = <Map<String, Object?>>[];
    handles.came(kevin.id, told.add, key: kevin.public);
    final id = fresh();
    final (status, said) = await send(20, id: id);
    expect(status, 200);
    expect(said['ok'], true);
    expect(said['n'], 80, reason: 'the sender\'s souls after');
    expect(said['receipt'], {'id': id, 'at': clock.millisecondsSinceEpoch, 'from': maya.id, 'to': kevin.id, 'souls': 20});
    expect(handles.soulsOf(maya.id), 80);
    expect(handles.soulsOf(kevin.id), 20);
    expect(told.single, containsPair('n', 20), reason: 'kevin\'s app is told his new count');
    expect(told.single, containsPair('why', 'From maya'));
    for (final who in [maya, kevin]) {
      final (s, r) = await ask('/souls/receipt', {'id': id}, by: who);
      expect(s, 200);
      expect((r['receipt'] as Map)['souls'], 20);
    }
    final (s, r) = await ask('/souls/receipt', {'id': id}, by: stranger);
    expect(s, 200);
    expect(r['receipt'], isNull, reason: 'a receipt is the two people\'s alone');
    expect((await ask('/souls/receipt', {'id': fresh()})).$2['receipt'], isNull, reason: 'no such sending');
  });

  test('asked again with the same id, nothing more moves: the first receipt is answered', () async {
    final id = fresh();
    expect((await send(20, id: id)).$1, 200);
    // The app asks again a moment later, signed afresh (the very same signed request is a replay, and refused).
    clock = clock.add(const Duration(seconds: 2));
    final (status, said) = await send(20, id: id);
    expect(status, 200);
    expect(said['again'], true);
    expect(said['n'], 80);
    expect(handles.soulsOf(kevin.id), 20, reason: 'sent once');
    expect((await send(30, id: id)).$2['error'], 'id_used', reason: 'the same id for another number');
    expect((await send(20, id: id, by: kevin, to: maya.id)).$2['error'], 'id_used', reason: 'the same id from someone else');
    expect(all(), 100);
  });

  test('refused, and nothing moved: not whole, not positive, too many, to yourself, to nobody, more than you have', () async {
    expect((await send(0)).$1, 400);
    expect((await send(-5)).$2['error'], 'amount', reason: 'never takes');
    expect((await send(Handles.sendAtOnce + 1)).$2['error'], 'amount');
    expect((await ask('/souls/send', {'to': kevin.id, 'souls': 2.5, 'id': fresh()})).$2['error'], 'amount');
    expect((await ask('/souls/send', {'to': kevin.id, 'souls': '20', 'id': fresh()})).$2['error'], 'amount');
    expect((await send(5, to: maya.id)).$2['error'], 'yourself');
    final (status, said) = await send(5, to: stranger.id);
    expect(status, 409);
    expect(said['error'], 'no_receiver', reason: 'nobody with a username here has that id');
    expect((await send(5, by: stranger)).$2['error'], 'no_account');
    expect((await send(5, by: kevin, to: maya.id)).$2['error'], 'not_enough', reason: 'kevin has none');
    expect((await ask('/souls/send', {'to': 'kevin', 'souls': 5, 'id': fresh()})).$1, 400);
    expect((await ask('/souls/send', {'to': kevin.id, 'souls': 5, 'id': 'x'})).$1, 400);
    expect(handles.soulsOf(maya.id), 100);
    expect(all(), 100);
  });

  test('only the sender\'s own signature, fresh and once', () async {
    final body = {'to': kevin.id, 'souls': 5, 'id': fresh()};
    final bytes = utf8.encode(jsonEncode(body));
    final now = clock.millisecondsSinceEpoch;
    expect((await ask('/souls/send', body, headers: const {})).$1, 401, reason: 'not signed');
    expect((await ask('/souls/send', body, headers: maya.signed('/souls/send', bytes, at: now - 600000))).$1, 401, reason: 'ten minutes old');
    expect((await ask('/souls/send', body, headers: maya.signed('/souls/receipt', bytes, at: now))).$1, 401, reason: 'signed for another route');
    final other = maya.signed('/souls/send', utf8.encode(jsonEncode({...body, 'souls': 50})), at: now);
    expect((await ask('/souls/send', body, headers: other)).$1, 401, reason: 'signed for another body');
    // Kevin's key over the same body sends nobody's souls but kevin's, here to himself: who sends is who signed.
    expect((await ask('/souls/send', body, by: kevin)).$2['error'], 'yourself');
    final once = maya.signed('/souls/send', bytes, at: now);
    expect((await ask('/souls/send', body, headers: once)).$1, 200);
    expect((await ask('/souls/send', body, headers: once)).$1, 401, reason: 'the same signed request again');
    expect(handles.soulsOf(maya.id), 95);
    expect(all(), 100);
  });

  test('two at once that together are more than the sender has: one goes, one is refused', () async {
    final both = await Future.wait([send(60), send(60)]);
    expect(both.map((r) => r.$1).toList()..sort(), [200, 409]);
    expect(both.firstWhere((r) => r.$1 == 409).$2['error'], 'not_enough');
    expect(handles.soulsOf(maya.id), 40);
    expect(handles.soulsOf(kevin.id), 60);
    expect(all(), 100);
  });

  test('so many souls, and so many sendings, in a day', () async {
    handles.giveBounty(maya.id, 400, 'more to send');
    for (var i = 0; i < 3; i++) {
      expect((await send(100)).$1, 200);
    }
    final (status, said) = await send(1);
    expect(status, 429);
    expect(said['error'], 'daily_limit', reason: '${Handles.sendADay} souls a day');
    expect(handles.soulsOf(kevin.id), 300);
    // A day on, there is room again; then the count of sendings stops it.
    clock = clock.add(const Duration(hours: 25));
    for (var i = 0; i < Handles.sendsADay; i++) {
      expect((await send(1)).$1, 200, reason: 'sending ${i + 1}');
    }
    expect((await send(1)).$2['error'], 'daily_limit', reason: '${Handles.sendsADay} sendings a day');
    expect(all(), 500);
  });

  test('so many askings an hour from one person', () async {
    for (var i = 0; i < SoulsSend.sendsAnHour; i++) {
      await send(5, to: maya.id);
    }
    final (status, said) = await send(5);
    expect(status, 429);
    expect(said['error'], 'rate_limited');
    expect(handles.soulsOf(maya.id), 100);
  });

  test('kept: the counts and the receipt are on disk together, and a repeat after a restart still moves nothing', () async {
    final id = fresh();
    expect((await send(20, id: id)).$1, 200);
    // On disk as it is answered, in the one file: the sender's count, the receiver's and the receipt.
    final kept = jsonDecode(File('${dir.path}/handles.json').readAsStringSync()) as Map;
    expect((kept['souls'] as Map)[maya.id], 80);
    expect((kept['souls'] as Map)[kevin.id], 20);
    expect(((kept['sent'] as List).single as Map)['id'], id);
    await relay.stop();
    await open();
    expect(handles.soulsOf(maya.id), 80);
    expect(handles.soulsOf(kevin.id), 20);
    expect((await ask('/souls/receipt', {'id': id}, by: kevin)).$2['receipt'], isNotNull);
    final (status, said) = await send(20, id: id);
    expect(status, 200);
    expect(said['again'], true);
    expect(handles.soulsOf(kevin.id), 20);
    expect(all(), 100);
  });

  test('a relay without it answers as it always has', () async {
    await relay.stop();
    relay = Relay();
    final port = await relay.start(host: '127.0.0.1', port: 0);
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/souls/send'));
      final res = await req.close();
      expect(res.statusCode, 200);
      expect(await res.transform(utf8.decoder).join(), 'Ghost Messaging relay\n', reason: 'what the app reads as "not here yet"');
    } finally {
      client.close(force: true);
    }
  });
}
