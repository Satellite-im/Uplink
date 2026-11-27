import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/invite_words.dart';
import 'package:test/test.dart';

/// Circles' invite words (lib/invite_words.dart; Matt, 2026-11-19: "add the custom invite code word as a default
/// feature").
void main() {
  final h1 = 'a' * 64, h2 = 'b' * 64;

  test('claimed by one install: taken for others, changed or dropped only by it, looked up by anyone', () {
    final w = InviteWords();
    final said = <Map<String, Object?>>[];
    void tell(Map<String, Object?> m) => said.add(m);

    w.said('maya', {'dir': 'word-set', 'h': h1, 'b': 'sealed-1'}, tell);
    expect(said.last, {'dir': 'word-set', 'h': h1, 'ok': true});
    w.said('sam', {'dir': 'word-set', 'h': h1, 'b': 'mine'}, tell);
    expect(said.last['dir'], 'err');
    expect(w.blobOf(h1), 'sealed-1');
    // Its owner may set it again (a new link), and anyone may look it up.
    w.said('maya', {'dir': 'word-set', 'h': h1, 'b': 'sealed-2'}, tell);
    w.said('sam', {'dir': 'word', 'h': h1}, tell);
    expect(said.last, {'dir': 'word', 'h': h1, 'b': 'sealed-2'});
    w.said('sam', {'dir': 'word', 'h': h2}, tell);
    expect(said.last, {'dir': 'word', 'h': h2, 'b': null});
    // Only its owner drops it.
    w.said('sam', {'dir': 'word-drop', 'h': h1}, tell);
    expect(said.last['dir'], 'err');
    w.said('maya', {'dir': 'word-drop', 'h': h1}, tell);
    expect(w.blobOf(h1), isNull);
    // Not a hash, or too big: refused.
    w.said('maya', {'dir': 'word-set', 'h': 'bookclub', 'b': 'x'}, tell);
    expect(said.last['dir'], 'err');
    w.said('maya', {'dir': 'word-set', 'h': h2, 'b': 'x' * (InviteWords.maxBlob + 1)}, tell);
    expect(said.last['dir'], 'err');
  });

  test('one install holds so many words, and words not set again for a year go', () {
    var now = DateTime.utc(2026, 11, 19);
    final w = InviteWords(now: () => now);
    final said = <Map<String, Object?>>[];
    for (var i = 0; i < InviteWords.maxForOne + 1; i++) {
      w.said('maya', {'dir': 'word-set', 'h': i.toRadixString(16).padLeft(64, '0'), 'b': 'x'}, said.add);
    }
    expect(w.count, InviteWords.maxForOne);
    expect(said.last['dir'], 'err');
    now = now.add(InviteWords.life + const Duration(days: 1));
    w.sweep();
    expect(w.count, 0);
  });

  test('kept across a restart, and answered over HTTP for the site\'s page', () async {
    final dir = Directory.systemTemp.createTempSync('words');
    addTearDown(() => dir.deleteSync(recursive: true));
    InviteWords(dataDir: dir).said('maya', {'dir': 'word-set', 'h': h1, 'b': 'sealed'}, (_) {});
    final w = InviteWords(dataDir: dir)..load();
    expect(w.blobOf(h1), 'sealed');

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) => w.handle(r, r.uri.pathSegments.last));
    final client = HttpClient();
    addTearDown(client.close);
    Future<(int, Object?)> get(String h) async {
      final res = await (await client.get('127.0.0.1', server.port, '/word/$h')).close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    }

    final (status, body) = await get(h1);
    expect(status, 200);
    expect(body, {'b': 'sealed'});
    expect((await get(h2)).$1, 404);
    expect((await get('nothex')).$1, 404);
  });
}
