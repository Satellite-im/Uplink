import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/fed_dial.dart';
import 'package:ghost_relay/hub.dart';
import 'package:test/test.dart';

/// Dialling another relay safely (lib/fed_dial.dart): the addresses come from other people, and the server this runs
/// on has other services on its own loopback and network. Names are looked up by a stand-in here, so nothing asks the
/// real DNS but where the test says so (names that need no network to answer).
void main() {
  InternetAddress ip(String a) => InternetAddress(a);
  Uri u(String s) => Uri.parse(s);

  /// A guard whose names resolve as [names] says; a name not in it resolves to nothing.
  DialGuard guard(Map<String, List<String>> names, {bool plain = false, Set<int> ports = const {}, List<String>? asked, DateTime Function()? now}) => DialGuard(
        plain: plain,
        ports: ports,
        now: now,
        resolve: (host) async {
          asked?.add(host);
          return [for (final a in names[host] ?? const <String>[]) ip(a)];
        },
      );

  group('which addresses are public', () {
    test('IPv4: not this machine, a private network, link-local, carrier NAT, documentation, multicast or reserved', () {
      for (final a in ['127.0.0.1', '127.255.255.254', '0.0.0.0', '0.1.2.3', '10.0.0.1', '10.255.255.255', '172.16.0.1', '172.31.255.255', '192.168.0.1', '192.168.255.255', '169.254.0.1', '169.254.169.254', '100.64.0.1', '100.127.255.255', '192.0.0.1', '192.0.2.1', '192.88.99.1', '198.18.0.1', '198.19.255.255', '198.51.100.1', '203.0.113.1', '224.0.0.1', '239.255.255.255', '240.0.0.1', '255.255.255.255']) {
        expect(DialGuard.isPublic(ip(a)), isFalse, reason: a);
      }
      for (final a in ['1.1.1.1', '8.8.8.8', '100.63.255.255', '100.128.0.1', '172.15.255.255', '172.32.0.1', '192.167.255.255', '192.169.0.1', '169.253.255.255', '198.17.255.255', '198.20.0.1', '203.0.112.255', '223.255.255.255', '192.0.1.1', '192.88.98.1']) {
        expect(DialGuard.isPublic(ip(a)), isTrue, reason: a);
      }
    });

    test('IPv6: only global unicast, and never an IPv4 address of the kinds above written as IPv6', () {
      for (final a in ['::', '::1', 'fe80::1', 'febf::1', 'fc00::1', 'fd12:3456:789a::1', 'fec0::1', 'ff02::1', 'ff0e::1', '2001:db8::1', '2001::1', '2001:0:4136:e378::1', '100::1', '::ffff:127.0.0.1', '::ffff:10.0.0.1', '::ffff:192.168.1.1', '::ffff:169.254.169.254', '64:ff9b::127.0.0.1', '64:ff9b::10.1.2.3', '2002:7f00:1::1', '2002:0a00:1::1', '2002:c0a8:101::1', '::127.0.0.1', '4000::1', 'e000::1']) {
        expect(DialGuard.isPublic(ip(a)), isFalse, reason: a);
      }
      for (final a in ['2606:4700:4700::1111', '2001:4860:4860::8888', '2a00:1450:4001::1', '::ffff:8.8.8.8', '64:ff9b::8.8.8.8', '2002:808:808::1', '2001:200::1', '3fff:ffff::1']) {
        expect(DialGuard.isPublic(ip(a)), isTrue, reason: a);
      }
    });
  });

  group('what is dialled at all', () {
    test('only a hub\'s address: wss, port 443, a path ending /hub, and nothing else', () {
      final g = guard({});
      expect(g.shape(u('wss://relay.example.com/hub')), isNull);
      expect(g.shape(u('wss://relay.example.com:443/hub')), isNull);
      expect(g.shape(u('wss://relay.example.com/some/path/hub')), isNull);
      for (final bad in ['ws://relay.example.com/hub', 'https://relay.example.com/hub', 'http://relay.example.com/hub', 'ftp://relay.example.com/hub', 'wss://relay.example.com:8443/hub', 'wss://relay.example.com:80/hub', 'wss://relay.example.com:22/hub', 'wss://relay.example.com/', 'wss://relay.example.com/hub/', 'wss://relay.example.com/admin', 'wss://relay.example.com/hub?x=1', 'wss://relay.example.com/hub#x', 'wss://user:pass@relay.example.com/hub', 'wss:///hub', 'wss://relay.example.com/${'x' * 200}/hub']) {
        expect(g.shape(u(bad)), isNotNull, reason: bad);
      }
    });

    test('plain ws:// only where a setting says so, and other ports only those named', () {
      expect(guard({}, plain: true).shape(u('ws://relay.example.com/hub')), isNotNull, reason: 'port 80 is not 443, and was not named');
      expect(guard({}, plain: true, ports: {80}).shape(u('ws://relay.example.com/hub')), isNull);
      expect(guard({}, ports: {80}).shape(u('ws://relay.example.com/hub')), isNotNull, reason: 'the port alone does not allow plain');
      expect(guard({}, ports: {8443}).shape(u('wss://relay.example.com:8443/hub')), isNull);
      expect(guard({}, ports: {8443}).shape(u('wss://relay.example.com/hub')), isNull, reason: '443 is always dialled');
      expect(guard({}, ports: {8443}).shape(u('wss://relay.example.com:9443/hub')), isNotNull);
    });
  });

  group('names are looked up first, and every answer must be public', () {
    test('a name that resolves to public addresses is dialled at those addresses', () async {
      final asked = <String>[];
      final ok = await guard({'relay.example.com': ['93.184.216.34', '2606:2800:220:1::1']}, asked: asked).check(u('wss://relay.example.com/hub'));
      expect(ok.problem, isNull);
      expect(ok.addresses.map((a) => a.address), ['93.184.216.34', '2606:2800:220:1::1']);
      expect(asked, ['relay.example.com'], reason: 'looked up once');
    });

    test('a name that resolves to this machine or its network is refused, whatever it is called', () async {
      for (final a in ['127.0.0.1', '::1', '10.0.0.5', '192.168.1.10', '169.254.169.254', 'fd00::1', 'fe80::1', '::ffff:127.0.0.1', '0.0.0.0', '100.64.0.1']) {
        final no = await guard({'innocent.example.com': [a]}).check(u('wss://innocent.example.com/hub'));
        expect([no.problem, no.addresses], ['not a public address', isEmpty], reason: a);
      }
    });

    test('one private answer among public ones refuses the name', () async {
      final no = await guard({'mixed.example.com': ['93.184.216.34', '127.0.0.1']}).check(u('wss://mixed.example.com/hub'));
      expect(no.problem, 'not a public address');
      final too = await guard({'mixed.example.com': ['2606:2800:220:1::1', '93.184.216.34', 'fd00::2']}).check(u('wss://mixed.example.com/hub'));
      expect(too.problem, 'not a public address');
    });

    test('a literal address is held to the same, with nothing looked up', () async {
      final asked = <String>[];
      final g = guard({}, asked: asked);
      for (final host in ['127.0.0.1', '10.1.2.3', '192.168.0.1', '169.254.169.254', '[::1]', '[fd00::1]', '[fe80::1]', '[::ffff:127.0.0.1]', '[::ffff:7f00:1]', '0.0.0.0']) {
        expect((await g.check(u('wss://$host/hub'))).problem, 'not a public address', reason: host);
      }
      expect((await g.check(u('wss://93.184.216.34/hub'))).addresses.single.address, '93.184.216.34');
      expect((await g.check(u('wss://[2606:2800:220:1::1]/hub'))).problem, isNull);
      expect(asked, isEmpty);
    });

    test('a name that resolves to nothing, or can\'t be looked up, or takes too long, is refused', () async {
      expect((await guard({}).check(u('wss://nothing.example.com/hub'))).problem, 'the name could not be looked up');
      final fails = DialGuard(resolve: (_) async => throw const SocketException('no such host'));
      expect((await fails.check(u('wss://x.example.com/hub'))).problem, 'the name could not be looked up');
      final slow = DialGuard(resolve: (_) => Completer<List<InternetAddress>>().future, lookupWithin: const Duration(milliseconds: 10));
      expect((await slow.check(u('wss://x.example.com/hub'))).problem, 'the name could not be looked up');
    });

    test('the ways of writing this machine that only the system\'s own lookup understands are caught by it', () async {
      // No stand-in here: these need no network to resolve, and the system turns each into 127.0.0.1 or ::1.
      final real = DialGuard();
      for (final host in ['localhost', '127.1', '2130706433', '0x7f.0.0.1', '0177.0.0.1', '127.0.0.01', '010.0.0.1']) {
        final no = await real.check(u('wss://$host/hub'));
        expect(no.problem, isNotNull, reason: host);
        expect(no.addresses, isEmpty, reason: host);
      }
    });

    test('what may not be dialled is not dialled: dial throws, and no connection is tried', () async {
      final g = guard({'internal.example.com': ['10.0.0.1']});
      for (final bad in ['wss://internal.example.com/hub', 'wss://127.0.0.1/hub', 'ws://relay.example.com/hub', 'wss://relay.example.com:8080/hub', 'wss://nothing.example.com/hub']) {
        await expectLater(g.dial(u(bad)), throwsA(isA<DialRefused>()), reason: bad);
      }
    });

    test('so many dials a minute of each kind, each kind its own: strangers\' looks can\'t use up a relay\'s own dials', () async {
      var clock = DateTime.utc(2026, 11, 22, 12);
      final g = DialGuard(now: () => clock, dialsAMinute: 3, retriesAMinute: 2, lookBacksAMinute: 1);
      expect([for (var i = 0; i < 4; i++) g.take(DialKind.lookBack)], [true, false, false, false]);
      expect([for (var i = 0; i < 4; i++) g.take(DialKind.own)], [true, true, true, false], reason: 'the looks took none of these');
      expect([for (var i = 0; i < 3; i++) g.take(DialKind.retry)], [true, true, false]);
      expect([g.hasRoom(DialKind.own), g.hasRoom(DialKind.retry), g.hasRoom(DialKind.lookBack)], [false, false, false]);
      clock = clock.add(const Duration(seconds: 59));
      expect(g.take(DialKind.own), isFalse);
      clock = clock.add(const Duration(seconds: 1));
      expect([g.take(DialKind.own), g.take(DialKind.retry), g.take(DialKind.lookBack)], [true, true, true]);
      // What is refused for its shape, or looked up, is not a dial: the check counts nothing.
      final h = guard({'a.example.com': ['93.184.216.34']}, now: () => clock);
      for (var i = 0; i < 50; i++) {
        expect((await h.check(u('wss://a.example.com/hub'))).problem, isNull);
      }
      expect((await h.check(u('ws://a.example.com/hub'))).problem, 'only wss:// is dialled');
      expect([DialGuard().dialsAMinute, DialGuard().retriesAMinute, DialGuard().lookBacksAMinute], [30, 30, 10]);
    });
  });

  group('the connection is made to the address that was checked', () {
    late HttpServer server;
    late Hub hub;
    final hosts = <String>[];

    setUp(() async {
      hub = Hub();
      hosts.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        hosts.add(request.headers.value('host') ?? '');
        if (request.uri.path == '/moved/hub') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('Location', 'http://other.invalid:${server.port}/hub');
          request.response.close();
          return;
        }
        hub.accept(request);
      });
    });
    tearDown(() async {
      hub.stop();
      await server.close(force: true);
    });

    test('a name that resolves nowhere still connects, because the name is never looked up: only the checked address is dialled', () async {
      // `relay.invalid` cannot resolve (RFC 2606). The connection is made to the address handed over, and the name is
      // only what the request says its host is.
      final socket = await connectPinned(u('ws://relay.invalid:${server.port}/hub'), InternetAddress.loopbackIPv4);
      final first = await socket.incoming.first.timeout(const Duration(seconds: 10));
      expect((jsonDecode(first as String) as Map)['hello'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hosts, ['relay.invalid:${server.port}']);
      await socket.close();
    });

    test('a redirect is not followed to another host', () async {
      await expectLater(connectPinned(u('ws://relay.invalid:${server.port}/moved/hub'), InternetAddress.loopbackIPv4), throwsA(anything));
      expect(hosts, ['relay.invalid:${server.port}'], reason: 'one request, and none to the host it was sent on to');
    });
  });
}
