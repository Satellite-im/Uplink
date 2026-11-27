import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/feedback.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// Feedback from the app filed in Notion (feedback.dart; Matt, 2026-11-19: "wire up notion to create user feedback
/// tickets ... upload screenshots ... optionally provide their username automatically so we can give out bug
/// bounties"). Notion is stood in for: each call it was made is kept, and it answers as Notion does.
class _Sender {
  _Sender(int n) : scalar = List.generate(32, (i) => (n * 37 + i * 5 + 3) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get id => hexOf(sha256(key).sublist(0, 16));

  Map<String, String> signed(List<int> body, {int? at, String path = '/feedback'}) {
    final time = at ?? DateTime.now().millisecondsSinceEpoch;
    final words = Feedback.signedWords(path, time, hexOf(sha256(body)));
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...utf8.encode(words)]);
    _nonce++;
    return {'x-ghost-key': base64Encode(key), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(P256.sign(scalar, utf8.encode(words), nonce))};
  }
}

void main() {
  late Relay relay;
  late List<(String, Uri, Map<String, String>, List<int>)> calls;
  late int pageStatus;
  late Uri base;
  final maya = _Sender(1), sam = _Sender(2);

  Future<(int, Map<String, dynamic>)> send(Map<String, Object?> body, {_Sender? by, Map<String, String>? headers}) async {
    final bytes = utf8.encode(jsonEncode(body));
    final client = HttpClient();
    try {
      final req = await client.postUrl(base.replace(path: '/feedback'));
      (headers ?? (by ?? maya).signed(bytes)).forEach(req.headers.set);
      req.add(bytes);
      final res = await req.close();
      final words = await res.transform(utf8.decoder).join();
      return (res.statusCode, (jsonDecode(words) as Map).cast<String, dynamic>());
    } finally {
      client.close(force: true);
    }
  }

  Future<void> start({bool on = true}) async {
    calls = [];
    pageStatus = 200;
    final feedback = Feedback(
      config: on ? const FeedbackConfig(notionToken: 'ntn_test', dataSource: '41e2ecf7-f3ac-81dd-9d59-000b22859842') : const FeedbackConfig(),
      ownsName: (id, name) => id == maya.id && name == 'maya',
      accountOf: (id) => id == maya.id ? '0x00000000000000000000000000000000000000aa' : null,
      notion: (method, url, headers, body) async {
        calls.add((method, url, headers, body));
        if (url.path == '/v1/file_uploads') return (200, jsonEncode({'id': 'up${calls.length}', 'status': 'pending'}));
        if (url.path.endsWith('/send')) return (200, jsonEncode({'status': 'uploaded'}));
        if (url.path == '/v1/pages') {
          return (pageStatus, pageStatus == 200 ? jsonEncode({'id': 'page1', 'properties': {'ID': {'type': 'unique_id', 'unique_id': {'prefix': 'GMFB', 'number': 12}}}}) : '{"message":"nope"}');
        }
        return (404, '{}');
      },
    );
    relay = Relay(feedback: feedback);
    final port = await relay.start(host: '127.0.0.1', port: 0);
    base = Uri.parse('http://127.0.0.1:$port');
  }

  tearDown(() => relay.stop());

  test('a signed report is filed: its kind, words, name checked as the sender\'s, platform, version and screenshots, uploaded first', () async {
    await start();
    final shot = base64Encode(List.filled(300, 7));
    final (status, answer) = await send({
      'type': 'bug',
      'title': '',
      'text': 'The call drops when I lock my phone.\n\nIt happens every time.',
      'username': 'Maya',
      'platform': 'android',
      'version': '0.9.34',
      'shots': [
        {'name': 'call.png', 'mime': 'image/png', 'data': shot},
        {'name': 'not a picture', 'mime': 'text/html', 'data': shot},
      ],
    });
    expect(status, 200);
    expect(answer, {'ok': true, 'id': 'GMFB-12'});
    expect(calls.map((c) => c.$2.path), ['/v1/file_uploads', '/v1/file_uploads/up1/send', '/v1/pages'], reason: 'only the picture goes up, before the page');
    expect(calls.first.$3['Authorization'], 'Bearer ntn_test');
    expect(calls.first.$3['Notion-Version'], Feedback.notionVersion);
    expect(calls[1].$3['Content-Type'], startsWith('multipart/form-data; boundary='));
    expect(utf8.decode(calls[1].$4, allowMalformed: true), contains('name="file"; filename="call.png"'));
    final page = jsonDecode(utf8.decode(calls.last.$4)) as Map;
    expect(page['parent'], {'data_source_id': '41e2ecf7-f3ac-81dd-9d59-000b22859842'});
    final p = page['properties'] as Map;
    expect(p['Title']['title'][0]['text']['content'], 'The call drops when I lock my phone.', reason: 'no title: the first line');
    expect(p['Type'], {'select': {'name': 'Bug'}});
    expect(p['Username']['rich_text'][0]['text']['content'], '@maya', reason: 'her key holds the name');
    expect(p['Platform'], {'select': {'name': 'Android'}});
    expect(p['Version']['rich_text'][0]['text']['content'], '0.9.34');
    expect(p['Screenshots']['files'], [{'type': 'file_upload', 'file_upload': {'id': 'up1'}, 'name': 'call.png'}]);
    final blocks = page['children'] as List;
    expect(blocks.where((b) => b['type'] == 'paragraph'), hasLength(2));
    // Who sent it, by what stays theirs as the name changes (Matt, 2026-11-20: "tie users names to their accounts ... so
    // that we can give out bug bounties properly"): her id, which the admin page gives souls to, and her account.
    expect(blocks.first['type'], 'callout');
    expect(blocks.first['callout']['rich_text'][0]['text']['content'], 'Reporter: @maya · Uplink id ${maya.id} · account 0x00000000000000000000000000000000000000aa');
    expect(blocks.last, {'object': 'block', 'type': 'image', 'image': {'type': 'file_upload', 'file_upload': {'id': 'up1'}}});
  });

  test('someone else\'s username is filed as unverified; no username, none', () async {
    await start();
    expect((await send({'type': 'feature', 'text': 'Dark mode please', 'username': 'maya'}, by: sam)).$1, 200);
    final p = (jsonDecode(utf8.decode(calls.last.$4)) as Map)['properties'] as Map;
    expect(p['Username']['rich_text'][0]['text']['content'], '@maya (not verified)');
    expect(p['Type'], {'select': {'name': 'Feature idea'}});
    expect((await send({'type': 'praise', 'text': 'Love it'}, by: sam)).$1, 200);
    expect(((jsonDecode(utf8.decode(calls.last.$4)) as Map)['properties'] as Map).containsKey('Username'), isFalse);
    // No name given: nobody named in the page either.
    expect(((jsonDecode(utf8.decode(calls.last.$4)) as Map)['children'] as List).where((b) => b['type'] == 'callout'), isEmpty);
  });

  test('unsigned, stale, replayed or empty reports are refused; so many an hour; off until it is set up; Notion\'s refusal said plainly', () async {
    await start();
    final body = {'type': 'bug', 'text': 'Crash'};
    final bytes = utf8.encode(jsonEncode(body));
    expect((await send(body, headers: const {})).$1, 401);
    expect((await send(body, headers: maya.signed(bytes, at: DateTime.now().millisecondsSinceEpoch - 600000))).$1, 401, reason: 'ten minutes old');
    final once = maya.signed(bytes);
    expect((await send(body, headers: once)).$1, 200);
    expect((await send(body, headers: once)).$1, 401, reason: 'the same request again');
    expect((await send({'type': 'bug', 'text': '   '})).$1, 400);
    expect((await send({'type': 'rant', 'text': 'Words'})).$1, 400);
    for (var i = 0; i < Feedback.perIdAnHour - 1; i++) {
      expect((await send(body)).$1, 200);
    }
    final (status, answer) = await send(body);
    expect(status, 429);
    expect(answer['error'], contains('a lot of feedback'));
    expect((await send(body, by: sam)).$1, 200, reason: 'another sender is not held');

    pageStatus = 400;
    final (bad, said) = await send(body, by: sam);
    expect(bad, 502);
    expect(said['error'], contains('didn\'t take it'));
    await relay.stop();

    await start(on: false);
    expect((await send(body)).$1, 503);
    expect(calls, isEmpty);
  });

  // Who sent a report is known only once its body is read, so what can be told before is: a stranger can't have the
  // relay hold megabytes it will throw away.
  test('nothing is read for a request with no signature, one too big, or too many at once or from one address', () async {
    await start();
    // A raw request whose body never finishes arriving: answered at once only if the body is not waited for.
    Future<int> raw(Map<String, String> headers, {int length = 1000}) async {
      final s = await Socket.connect('127.0.0.1', base.port);
      s.write('POST /feedback HTTP/1.1\r\nhost: x\r\ncontent-length: $length\r\n${headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n{');
      await s.flush();
      final head = await utf8.decoder.bind(s).first.timeout(const Duration(seconds: 5));
      s.destroy();
      return int.parse(head.split(' ')[1]);
    }

    expect(await raw(const {}), 401, reason: 'no signature: not read');
    expect(await raw({'x-ghost-key': 'AAAA', 'x-ghost-sig': 'AAAA', 'x-ghost-time': '${DateTime.now().millisecondsSinceEpoch}'}), 401, reason: 'not a key\'s size');
    expect(await raw(maya.signed(const []), length: Feedback.most + 1), 413, reason: 'said to be too big');
    expect(calls, isEmpty);

    // As many bodies as may be read at once, each begun and not finished; one more is told to try again.
    final open = <Socket>[];
    for (var i = 0; i < Feedback.bodiesInFlight; i++) {
      final s = await Socket.connect('127.0.0.1', base.port);
      s.write('POST /feedback HTTP/1.1\r\nhost: x\r\ncontent-length: 1000\r\n${maya.signed(const []).entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n{');
      await s.flush();
      open.add(s);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await raw(maya.signed(const [])), 503);
    for (final s in open) {
      s.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final body = {'type': 'bug', 'text': 'Crash'};
    expect((await send(body)).$1, 200, reason: 'the slots were given back');

    // One address, however many keys it signs with: so many bodies an hour.
    var refused = 0;
    for (var i = 0; i < Feedback.perAddressAnHour; i++) {
      if (await raw(_Sender(10 + i).signed(const []), length: 1) == 429) refused++;
    }
    expect(refused, Feedback.bodiesInFlight + 2, reason: 'the bodies read above were this address\'s too');
  });

  test('a screenshot\'s name can\'t add a line to the form sent on', () async {
    await start();
    final (status, _) = await send({
      'type': 'bug',
      'text': 'Crash',
      'shots': [
        {'name': 'a\r\nX-Evil: 1\r\n\r\n"b.png', 'mime': 'image/png', 'data': base64Encode(List.filled(20, 7))},
      ],
    });
    expect(status, 200);
    final form = latin1.decode(calls[1].$4);
    expect(form, contains('filename="aX-Evil: 1b.png"\r\nContent-Type: image/png\r\n\r\n'));
    expect(form.split('\r\n\r\n').first, isNot(contains('X-Evil: 1\r')));
  });
}
