import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/web_app.dart';
import 'package:test/test.dart';

/// The app in a browser, served by the relay as plain files under `/app/` (lib/web_app.dart; Matt: "the full web
/// client"): the page and the hub are one address, as a browser needs, and the folder is a folder of files and
/// nothing more.
void main() {
  late Directory root;
  late Directory web;
  late Relay relay;
  late int port;
  final http = HttpClient()..autoUncompress = false;

  /// One request written out by hand, so the address goes exactly as given (a client would tidy `..` away first):
  /// the status line's number, the headers, and the body's bytes.
  Future<({int status, Map<String, String> headers, List<int> body})> raw(String target, {String method = 'GET', Map<String, String> headers = const {}}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.write('$method $target HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n${[for (final e in headers.entries) '${e.key}: ${e.value}\r\n'].join()}\r\n');
    await socket.flush();
    final bytes = <int>[];
    await socket.listen(bytes.addAll).asFuture<void>().timeout(const Duration(seconds: 10));
    await socket.close();
    final split = _indexOf(bytes, const [13, 10, 13, 10]);
    final head = latin1.decode(bytes.sublist(0, split < 0 ? bytes.length : split)).split('\r\n');
    final got = <String, String>{};
    for (final line in head.skip(1)) {
      final at = line.indexOf(':');
      if (at > 0) got[line.substring(0, at).toLowerCase()] = line.substring(at + 1).trim();
    }
    var body = split < 0 ? <int>[] : bytes.sublist(split + 4);
    if (got['transfer-encoding'] == 'chunked') body = _unchunk(body);
    return (status: int.parse(head.first.split(' ')[1]), headers: got, body: body);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ghost-relay-web-');
    web = Directory('${root.path}/web')..createSync();
    File('${web.path}/index.html').writeAsStringSync('<!DOCTYPE html><title>Uplink</title>');
    File('${web.path}/main.dart.js').writeAsStringSync('console.log("the app");');
    File('${web.path}/main.dart.3f9a1c2b.js').writeAsStringSync('console.log("the app, named by what is in it");');
    File('${web.path}/manifest.json').writeAsStringSync('{}');
    File('${web.path}/.last_build_id').writeAsStringSync('hidden');
    Directory('${web.path}/canvaskit').createSync();
    File('${web.path}/canvaskit/canvaskit.wasm').writeAsBytesSync([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]);
    Directory('${web.path}/assets/fonts').createSync(recursive: true);
    File('${web.path}/assets/fonts/Inter.ttf').writeAsBytesSync(List.filled(64, 7));
    File('${web.path}/icon.png').writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
    // Beside the folder, where nothing asked of /app/ may reach.
    File('${root.path}/secret.txt').writeAsStringSync('not yours');
    relay = Relay(hub: Hub(), web: WebApp(web));
    port = await relay.start(port: 0);
  });

  tearDown(() async {
    await relay.stop();
    await root.delete(recursive: true);
  });

  tearDownAll(() => http.close(force: true));

  test('/app/ is the page, asked for again each time; /app goes to /app/', () async {
    final page = await raw('/app/');
    expect(page.status, 200);
    expect(page.headers['content-type'], 'text/html; charset=utf-8');
    expect(page.headers['cache-control'], 'no-cache');
    expect(utf8.decode(page.body), contains('<title>Uplink</title>'));
    expect((await raw('/app/index.html')).body, page.body);
    // The page's own addresses are read from the folder, so the folder's address ends in a slash.
    final bare = await raw('/app');
    expect(bare.status, 301);
    expect(bare.headers['location'], '/app/');
    expect((await raw('/app?x=1')).headers['location'], '/app/?x=1');
    // Never a frame in another site's page, and never guessed to be another kind of file.
    expect(page.headers['x-frame-options'], 'DENY');
    expect(page.headers['x-content-type-options'], 'nosniff');
    // Nothing that would let another site's page read it.
    expect(page.headers.keys.where((h) => h.startsWith('access-control-')), isEmpty);
  });

  // The list both of the app's addresses are held to (the app's tool/web/headers.json): app.gogho.st's block in
  // tool/deploy-site.mjs (test/web_build_test.dart), and this.
  test('every answer says what the app may do: the page\'s own policy as a header, the worker\'s too, and the rest of the list', () async {
    final list = jsonDecode(File('../tool/web/headers.json').readAsStringSync()) as Map;
    const policy = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' wss://hub.example/hub; base-uri 'self'";
    File('${web.path}/index.html').writeAsStringSync('<!DOCTYPE html><head><meta http-equiv="Content-Security-Policy" content="$policy"></head><title>Uplink</title>');
    File('${web.path}/argon2id.js').writeAsStringSync('self.onmessage = () => {};');
    final expected = {...(list['every'] as Map).cast<String, String>(), 'Content-Security-Policy': '$policy; ${list['frameAncestors']}'};
    for (final (path, status) in const [('/app/', 200), ('/app/argon2id.js', 200), ('/app/main.dart.3f9a1c2b.js', 200), ('/app/nothing-here.js', 404)]) {
      final got = await raw(path);
      expect(got.status, status, reason: path);
      for (final e in expected.entries) {
        expect(got.headers[e.key.toLowerCase()], e.value, reason: '$path: ${e.key}');
      }
    }
    // Refused, it says the same.
    final refused = await raw('/app/', method: 'POST', headers: {'Content-Length': '0'});
    expect(refused.headers['content-security-policy'], expected['Content-Security-Policy']);
    // The cache's words are the list's.
    expect((await raw('/app/')).headers['cache-control'], (list['cache'] as Map)['plain']);
    expect((await raw('/app/main.dart.3f9a1c2b.js')).headers['cache-control'], (list['cache'] as Map)['hashed']);
    // HSTS is app.gogho.st's: a relay's server in front of it says its own.
    expect((await raw('/app/')).headers.containsKey('strict-transport-security'), isFalse);
    // A page whose policy changes (another build) is read again; one with none is held to the relay's own.
    File('${web.path}/index.html').writeAsStringSync('<!DOCTYPE html><head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; connect-src \'self\'"></head><p>a longer page than before</p>');
    expect((await raw('/app/')).headers['content-security-policy'], "default-src 'none'; connect-src 'self'; frame-ancestors 'none'");
    File('${web.path}/index.html').writeAsStringSync('<!DOCTYPE html><title>No policy here at all, and longer again than both</title>');
    expect((await raw('/app/argon2id.js')).headers['content-security-policy'], "${WebApp.fallbackPolicy}; frame-ancestors 'none'");
  });

  // What the page asks for as it signs out or is removed (the app's lib/web/browser_web.dart): the browser told to clear
  // everything this address keeps, which in Chromium takes a deleted store's bytes off the disk too.
  test('/app/clear-site-data tells the browser to clear what this address keeps, and nothing else', () async {
    final got = await raw('/app/clear-site-data', headers: {'Sec-Fetch-Site': 'same-origin'});
    expect(got.status, 204);
    expect(got.headers['clear-site-data'], '"storage"');
    expect(got.headers['cache-control'], 'no-store');
    expect(got.body, isEmpty);
    // With the app's own headers, as every answer here.
    expect(got.headers['x-frame-options'], 'DENY');
    expect(got.headers['content-security-policy'], endsWith("frame-ancestors 'none'"));
    // Nowhere else: no file of the folder clears anything.
    for (final path in ['/app/', '/app/main.dart.js', '/app/nothing-here.js']) {
      expect((await raw(path)).headers.containsKey('clear-site-data'), isFalse, reason: path);
    }
    expect((await raw('/app/clear-site-data', method: 'POST', headers: {'Content-Length': '0', 'Sec-Fetch-Site': 'same-origin'})).status, 405);
  });

  // Third review, A2: another site sending the browser to it (a link, a redirect, a picture) cleared the app's store in
  // Chromium and WebKit. Only the page's own fetch is answered; anything else is a file that isn't here.
  test('/app/clear-site-data answers only the page itself: from anywhere else it is not here', () async {
    for (final from in [null, 'cross-site', 'same-site', 'none', 'SAME-ORIGIN ', '']) {
      final got = await raw('/app/clear-site-data', headers: {'Sec-Fetch-Site': ?from});
      expect(got.status, 404, reason: '$from');
      expect(got.headers.containsKey('clear-site-data'), isFalse, reason: '$from');
    }
    expect((await raw('/app/clear-site-data', headers: {'Sec-Fetch-Site': 'same-origin'})).headers['clear-site-data'], '"storage"');
  });

  test('each file is said to be what it is', () async {
    for (final (path, type) in const [
      ('/app/main.dart.js', 'text/javascript; charset=utf-8'),
      ('/app/manifest.json', 'application/json; charset=utf-8'),
      ('/app/canvaskit/canvaskit.wasm', 'application/wasm'),
      ('/app/assets/fonts/Inter.ttf', 'font/ttf'),
      ('/app/icon.png', 'image/png'),
    ]) {
      final got = await raw(path);
      expect(got.status, 200, reason: path);
      expect(got.headers['content-type'], type, reason: path);
      expect(got.headers['content-length'], '${got.body.length}', reason: path);
    }
    expect(WebApp.typeOf('notes.unknown'), 'application/octet-stream');
    expect(WebApp.typeOf('Icon.PNG'), 'image/png');
  });

  test('a file named by what is in it is kept for a year; any other is asked for again, and answered "as you have it"', () async {
    final named = await raw('/app/main.dart.3f9a1c2b.js');
    expect(named.headers['cache-control'], 'public, max-age=31536000, immutable');
    final plain = await raw('/app/main.dart.js');
    expect(plain.headers['cache-control'], 'no-cache');
    final tag = plain.headers['etag']!;
    expect(tag, matches(RegExp(r'^"[0-9a-f]+-[0-9a-f]+"$')));
    final again = await raw('/app/main.dart.js', headers: {'If-None-Match': tag});
    expect(again.status, 304);
    expect(again.body, isEmpty);
    expect((await raw('/app/main.dart.js', headers: {'If-None-Match': 'W/$tag, "other"'})).status, 304);
    expect((await raw('/app/main.dart.js', headers: {'If-None-Match': '"other"'})).status, 200);
    // Written again (another build): another tag, and the whole file.
    File('${web.path}/main.dart.js').writeAsStringSync('console.log("the next build of the app");');
    final next = await raw('/app/main.dart.js', headers: {'If-None-Match': tag});
    expect(next.status, 200);
    expect(utf8.decode(next.body), contains('next build'));
    for (final (name, is_) in const [('main.dart.3f9a1c2b.js', true), ('main.dart.js', false), ('Icon-192.png', false), ('canvaskit.wasm', false), ('a.deadbeefcafe.wasm', true), ('index.html', false), ('notes-20261122.txt', false)]) {
      expect(WebApp.hashed(name), is_, reason: name);
    }
  });

  test('HEAD is the headers alone; anything but GET and HEAD is refused', () async {
    final head = await raw('/app/main.dart.js', method: 'HEAD');
    expect(head.status, 200);
    expect(head.headers['content-length'], '${'console.log("the app");'.length}');
    expect(head.body, isEmpty);
    for (final method in ['POST', 'PUT', 'DELETE']) {
      final got = await raw('/app/main.dart.js', method: method, headers: {'Content-Length': '0'});
      expect(got.status, 405, reason: method);
      expect(got.headers['allow'], 'GET, HEAD');
    }
    expect(File('${web.path}/main.dart.js').readAsStringSync(), 'console.log("the app");');
  });

  test('no lists of what is in a folder, and nothing that is not there', () async {
    for (final path in ['/app/canvaskit', '/app/canvaskit/', '/app/assets/', '/app/assets/fonts', '/app/nothing.js', '/app/canvaskit/nothing.wasm', '/app/index.html/more']) {
      final got = await raw(path);
      expect(got.status, 404, reason: path);
      expect(utf8.decode(got.body), 'Not found\n', reason: path);
    }
    // A file whose name starts with a dot is the build's own business.
    expect((await raw('/app/.last_build_id')).status, 404);
  });

  test('nothing outside the folder, however the address is written', () async {
    for (final path in [
      '/app/../secret.txt',
      '/app/canvaskit/../../secret.txt',
      '/app/%2e%2e/secret.txt',
      '/app/%2E%2E/secret.txt',
      '/app/..%2fsecret.txt',
      '/app/..%2Fsecret.txt',
      '/app/%2e%2e%2fsecret.txt',
      '/app/..%5csecret.txt',
      '/app/canvaskit%2f..%2f..%2fsecret.txt',
      '/app/canvaskit/..%2f..%2fsecret.txt',
      '/app/%252e%252e/secret.txt',
      '/app//secret.txt',
      '/app/%00/secret.txt',
      '/app/index.html%00.png',
      '/app/C:%5csecret.txt',
      '/app/....//secret.txt',
    ]) {
      final got = await raw(path);
      expect(utf8.decode(got.body, allowMalformed: true), isNot(contains('not yours')), reason: path);
      expect(got.status, anyOf(404, 400, 200), reason: path);
      // 200 only where the address, tidied, is no longer under /app/ at all: the relay's own plain answer.
      if (got.status == 200) expect(utf8.decode(got.body), 'Ghost Messaging relay\n', reason: path);
    }
  });

  test('a link in the folder to somewhere outside it is not followed', () async {
    Link('${web.path}/out.txt').createSync('${root.path}/secret.txt');
    Link('${web.path}/outside').createSync(root.path);
    Link('${web.path}/inside.js').createSync('${web.path}/main.dart.js');
    expect((await raw('/app/out.txt')).status, 404);
    expect((await raw('/app/outside/secret.txt')).status, 404);
    // One that stays inside is a file like any other.
    final inside = await raw('/app/inside.js');
    expect(inside.status, 200);
    expect(utf8.decode(inside.body), 'console.log("the app");');
  }, skip: Platform.isWindows ? 'links need rights of their own on Windows' : false);

  test('a file packed beforehand is sent packed to a browser that reads that packing, and never a stale one', () async {
    final plain = 'console.log("the app");';
    final js = File('${web.path}/main.dart.js');
    File('${web.path}/main.dart.js.gz').writeAsBytesSync(gzip.encode(utf8.encode(plain)));
    File('${web.path}/main.dart.js.br').writeAsBytesSync(utf8.encode('as if packed with brotli'));
    final gz = await raw('/app/main.dart.js', headers: {'Accept-Encoding': 'gzip, deflate'});
    expect(gz.headers['content-encoding'], 'gzip');
    expect(gz.headers['content-type'], 'text/javascript; charset=utf-8');
    expect(gz.headers['vary'], 'Accept-Encoding');
    expect(utf8.decode(gzip.decode(gz.body)), plain);
    final br = await raw('/app/main.dart.js', headers: {'Accept-Encoding': 'gzip, deflate, br;q=0.9'});
    expect(br.headers['content-encoding'], 'br');
    expect(utf8.decode(br.body), 'as if packed with brotli');
    final none = await raw('/app/main.dart.js');
    expect(none.headers.containsKey('content-encoding'), isFalse);
    expect(utf8.decode(none.body), plain);
    // The file written again after its packed copies: they are another build's, and the file itself is sent.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    js.writeAsStringSync('console.log("newer");');
    final newer = await raw('/app/main.dart.js', headers: {'Accept-Encoding': 'gzip, br'});
    expect(newer.headers.containsKey('content-encoding'), isFalse);
    expect(utf8.decode(newer.body), 'console.log("newer");');
  });

  test('the hub and the relay\'s other answers are as they were beside it', () async {
    final hello = await (await http.get('127.0.0.1', port, '/')).close();
    expect(await hello.transform(utf8.decoder).join(), 'Ghost Messaging relay\n');
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub');
    final first = await ws.first.timeout(const Duration(seconds: 10));
    expect((jsonDecode(first as String) as Map)['hello'], matches(RegExp(r'^[0-9a-f]+$')));
    await ws.close();
  });

  test('with no folder named there is no /app/, and a folder with no page says so', () async {
    final none = Relay();
    final at = await none.start(port: 0);
    addTearDown(none.stop);
    final got = await (await http.get('127.0.0.1', at, '/app/')).close();
    expect(await got.transform(utf8.decoder).join(), 'Ghost Messaging relay\n');
    expect(WebApp(web).there, isTrue);
    expect(WebApp(Directory('${root.path}/nowhere')).there, isFalse);
  });
}

int _indexOf(List<int> bytes, List<int> what) {
  for (var i = 0; i + what.length <= bytes.length; i++) {
    var same = true;
    for (var j = 0; j < what.length && same; j++) {
      same = bytes[i + j] == what[j];
    }
    if (same) return i;
  }
  return -1;
}

/// A body sent in chunks, put back together.
List<int> _unchunk(List<int> body) {
  final out = <int>[];
  var at = 0;
  while (at < body.length) {
    final end = _indexOf(body.sublist(at), const [13, 10]);
    if (end < 0) break;
    final size = int.parse(latin1.decode(body.sublist(at, at + end)).split(';').first.trim(), radix: 16);
    if (size == 0) break;
    at += end + 2;
    out.addAll(body.sublist(at, at + size));
    at += size + 2;
  }
  return out;
}
