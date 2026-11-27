import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/pushes.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// Waking a closed app (Matt, 2026-11-16: "Yes, wake-ups"): an Android phone's look at what is held for it, and an
/// iPhone's push when something is held for it (hub.dart, pushes.dart).

final _rnd = Random(7);
List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// An install: a key, and connections to the hub signed with it.
class _Install {
  _Install() : scalar = _bytes(32) {
    key = P256.publicOf(scalar);
    id = Hub.nameOf(key);
  }
  final List<int> scalar;
  late final List<int> key;
  late final String id;
  late WebSocket ws;
  final said = StreamController<Map>.broadcast();
  final frames = <List<int>>[];

  /// Signs in (or only looks, with [peek]); what the hub answers the hello with.
  Future<Map> connect(String url, {bool peek = false, String? device}) async {
    final socket = await WebSocket.connect(url);
    if (!peek) ws = socket;
    final first = Completer<Map>(), hello = Completer<Map>();
    socket.listen((d) {
      if (d is List<int>) {
        frames.add(d);
        return;
      }
      final m = jsonDecode(d as String) as Map;
      if (!first.isCompleted) {
        first.complete(m);
      } else if (!hello.isCompleted) {
        hello.complete(m);
      } else {
        said.add(m);
      }
    });
    final nonce = _unhex((await first.future)['hello'] as String);
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], _bytes(32));
    socket.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (peek) 'peek': true, 'device': ?device}));
    return hello.future.timeout(const Duration(seconds: 5));
  }

  /// A packet to [to], as the app's hub route sends one: [1][seq][to][the packet].
  void sendTo(_Install to, List<int> packet) {
    final seq = ByteData(4)..setUint32(0, _rnd.nextInt(1 << 30));
    ws.add(Uint8List.fromList([Hub.toPeer, ...seq.buffer.asUint8List(), ..._unhex(to.id), ...packet]));
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  late Relay relay;
  late Hub hub;
  late String url;
  late Pushes pushes;
  late Directory dir;
  final sent = <(String, bool)>[];

  setUp(() async {
    sent.clear();
    dir = Directory.systemTemp.createTempSync('pushes');
    pushes = Pushes(dataDir: dir, send: (token, sandbox) async {
      sent.add((token, sandbox));
      return true;
    });
    hub = Hub(pushes: pushes);
    relay = Relay(hub: hub);
    url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
  });
  tearDown(() async {
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  test('a look is told how much is held, is handed nothing, and takes nothing: the app gets it all when it opens', () async {
    final a = _Install(), b = _Install();
    await a.connect(url);
    a.sendTo(b, [9, 9, 9]);
    a.sendTo(b, [8, 8]);
    await _settle();
    expect(await b.connect(url, peek: true), {'ok': true, 'held': 2, 'peek': true, 'here': false});
    await _settle();
    expect(b.frames, isEmpty);
    expect(hub.heldFor(b.id), 2);
    expect((await b.connect(url))['held'], 2);
    await _settle();
    expect(b.frames, hasLength(2));
  });

  test('the greeting says the hub knows a look, so a closed app\'s check signs in to no hub that would hand it all over', () async {
    final ws = await WebSocket.connect(url);
    final first = jsonDecode(await ws.first as String) as Map;
    expect(first['peek'], isTrue);
    expect(first['hello'], isA<String>());
  });

  test('a look while the app itself is connected leaves its connection be', () async {
    final b = _Install();
    await b.connect(url);
    final open = b.ws;
    expect((await b.connect(url, peek: true))['here'], isTrue);
    await _settle();
    expect(open.readyState, WebSocket.open, reason: 'not replaced by a look');
  });

  test('an iPhone\'s token: what is held for it wakes it, once for many; kept across a restart; forgotten when it says so', () async {
    final a = _Install(), b = _Install();
    await a.connect(url);
    await b.connect(url);
    final answer = b.said.stream.first;
    b.ws.add(jsonEncode({'push': {'apns': 'ab' * 32, 'sandbox': true}}));
    expect(await answer.timeout(const Duration(seconds: 3)), {'push': true});
    expect(pushes.registered, 1);
    expect(Pushes(dataDir: dir).registered, 1, reason: 'kept in pushes.json');
    await b.ws.close();
    await _settle();
    a.sendTo(b, [1]);
    a.sendTo(b, [2]);
    await _settle();
    expect(sent, [('ab' * 32, true)], reason: 'one wake for the two, within the quiet minute');
    expect((await b.connect(url))['held'], 2);
    final forgot = b.said.stream.first;
    b.ws.add(jsonEncode({'push': null}));
    await forgot.timeout(const Duration(seconds: 3));
    expect(pushes.registered, 0);
  });

  // Two iPhones signed in to one account are one install to the hub, each with a token of its own: one of them wiped or
  // signed out says {"push": null}, which took the other's too while there was one token an install (third review).
  test('two iPhones of one account: each keeps its own token, and one forgetting its own leaves the other\'s', () async {
    final a = _Install(), b = _Install();
    await a.connect(url);
    await b.connect(url, device: 'one');
    final first = b.ws;
    var answer = b.said.stream.first;
    first.add(jsonEncode({'push': {'apns': 'aa' * 32, 'sandbox': false}}));
    await answer.timeout(const Duration(seconds: 3));
    await b.connect(url, device: 'two');
    final second = b.ws;
    answer = b.said.stream.first;
    second.add(jsonEncode({'push': {'apns': 'bb' * 32, 'sandbox': false}}));
    await answer.timeout(const Duration(seconds: 3));
    expect(pushes.registered, 2);
    // The first is wiped: it forgets its token, and its alone.
    answer = b.said.stream.first;
    first.add(jsonEncode({'push': null}));
    await answer.timeout(const Duration(seconds: 3));
    expect(pushes.registered, 1);
    await first.close();
    await second.close();
    await _settle();
    a.sendTo(b, [1]);
    await _settle();
    expect(sent, [('bb' * 32, false)], reason: 'the one still signed in is woken, the wiped one not');
  });

  test('tokens kept before devices are read as the install\'s, and the same phone saying its device takes that one\'s place', () {
    final old = Directory.systemTemp.createTempSync('ghost-pushes-old');
    addTearDown(() => old.deleteSync(recursive: true));
    File('${old.path}/pushes.json').writeAsStringSync(jsonEncode({'x': {'t': 'cc' * 32, 's': true, 'd': '2026-11-20'}}));
    final woken = <String>[];
    final p = Pushes(dataDir: old, send: (t, _) async {
      woken.add(t);
      return true;
    });
    expect(p.registered, 1);
    p.held('x');
    expect(woken, ['cc' * 32]);
    // The same iPhone, updated, says which device it is: one token, not two.
    p.said('x', {'apns': 'cc' * 32, 'sandbox': true}, device: 'phone');
    expect(p.registered, 1);
    // An app from before devices forgetting its token takes the install's own, as it always did.
    final q = Pushes(send: (_, _) async => true);
    q.said('y', {'apns': 'dd' * 32});
    q.said('y', {'apns': 'ee' * 32}, device: 'other');
    q.said('y', null);
    expect(q.registered, 1);
  });

  test('no token: held, and nothing sent; a token that is not hex is not kept', () async {
    final a = _Install(), b = _Install();
    await a.connect(url);
    a.sendTo(b, [1]);
    await _settle();
    expect(hub.heldFor(b.id), 1);
    expect(sent, isEmpty);
    pushes.said(b.id, {'apns': 'not a token'});
    expect(pushes.registered, 0);
  });

  test('the quiet minute passes: woken again', () {
    var now = DateTime(2026, 11, 16, 12);
    var count = 0;
    final p = Pushes(now: () => now, send: (_, _) async {
      count++;
      return true;
    });
    p.said('x', {'apns': 'cd' * 32});
    p.held('x');
    p.held('x');
    now = now.add(const Duration(seconds: 61));
    p.held('x');
    expect(count, 2);
  });

  test('Apple\'s token: ES256 over header and claims, checked with the key\'s public half; the key read from a .p8', () {
    final scalar = _bytes(32);
    final jwt = Apns.token(scalar, keyId: 'ABC123DEFG', teamId: 'F6ZAL7ANAD', issuedAt: 1800000000);
    final parts = jwt.split('.');
    expect(parts, hasLength(3));
    List<int> b64(String s) => base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));
    expect(jsonDecode(utf8.decode(b64(parts[0]))), {'alg': 'ES256', 'kid': 'ABC123DEFG'});
    expect(jsonDecode(utf8.decode(b64(parts[1]))), {'iss': 'F6ZAL7ANAD', 'iat': 1800000000});
    expect(P256.verify(P256.publicOf(scalar), utf8.encode('${parts[0]}.${parts[1]}'), b64(parts[2])), isTrue);
  });

  test('a real .p8 (made by openssl as Apple makes them): its key found', () async {
    final pem = File('${dir.path}/k.p8');
    final made = await Process.run('openssl', ['genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', pem.path]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final scalar = Apns.scalarOf(pem.readAsStringSync());
    expect(scalar, hasLength(32));
    // Its public half, as openssl works it out, is ours.
    final out = File('${dir.path}/k.pub');
    final pub = await Process.run('openssl', ['ec', '-in', pem.path, '-pubout', '-conv_form', 'compressed', '-outform', 'DER', '-out', out.path]);
    expect(pub.exitCode, 0, reason: '${pub.stderr}');
    final der = out.readAsBytesSync();
    expect(der.sublist(der.length - 33), P256.publicOf(scalar));
  }, skip: Platform.isWindows);

  test('Apple\'s token is given to curl on its standard input, never among its arguments', () async {
    final (args, input) = Apns.curlFor('https://api.push.apple.com/3/device/abc', jwt: 'aaa.bbb.ccc', topic: 'com.example.app');
    expect(args.join(' '), isNot(contains('aaa.bbb.ccc')));
    expect(args.join(' '), isNot(contains('bearer')));
    expect(args, containsAllInOrder(['--http2', '-H', '@-', '-d', Apns.payload, 'https://api.push.apple.com/3/device/abc']));
    expect(input, contains('authorization: bearer aaa.bbb.ccc\n'));
    // curl itself, to a server here: every header arrives, with the body, and the status comes back.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String, String?>{};
    server.listen((r) async {
      for (final h in ['authorization', 'apns-topic', 'apns-push-type', 'apns-priority']) {
        seen[h] = r.headers.value(h);
      }
      seen['body'] = await utf8.decodeStream(r);
      r.response
        ..statusCode = 410
        ..write('{"reason":"Unregistered"}');
      await r.response.close();
    });
    final (localArgs, localInput) = Apns.curlFor('http://127.0.0.1:${server.port}/3/device/abc', jwt: 'aaa.bbb.ccc', topic: 'com.example.app');
    // Without --http2: over plain http curl would ask to upgrade, which this server takes for a request with no body.
    final (out, err) = await Apns.curl([...localArgs.where((a) => a != '--http2')], localInput);
    expect(out.trim(), '410');
    expect(err, contains('Unregistered'));
    expect(seen, {'authorization': 'bearer aaa.bbb.ccc', 'apns-topic': 'com.example.app', 'apns-push-type': 'alert', 'apns-priority': '10', 'body': Apns.payload});
  }, skip: Platform.isWindows);
}
