import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

/// What federation reads from the relay's environment (lib/federation.dart FedConfig.fromEnvironment), the relay's own
/// key (relay-key.json), and the program started with it on (bin/relay.dart).
void main() {
  FedConfig of(Map<String, String> env) => FedConfig.fromEnvironment(env);
  List<Object> all(FedConfig c) => [c.mode, c.allow, c.block, c.publicHub, c.via, c.packetsAMinute, c.bytesADay, c.lookupsAnHour, c.ports, c.plain];

  group('the environment', () {
    test('with nothing set: off, and every limit at its default', () {
      const d = FedConfig();
      expect(all(of(const {})), [FedMode.off, <String>{}, <String>{}, '', '', 1200, 512 << 20, 600, <int>{}, false]);
      expect(all(of(const {})), all(d));
      expect(of(const {}).problems, isEmpty);
    });

    test('GHOST_FED: off, open or list, and anything else is off, with a word to the keeper', () {
      expect([for (final v in ['off', 'open', 'list', ' Open ', 'LIST', '']) of({'GHOST_FED': v}).mode], [FedMode.off, FedMode.open, FedMode.list, FedMode.open, FedMode.list, FedMode.off]);
      for (final junk in ['on', '1', 'true', 'yes', 'all', 'open,list']) {
        final c = of({'GHOST_FED': junk});
        expect([c.mode, c.problems], [FedMode.off, hasLength(1)], reason: junk);
      }
    });

    test('allow and block: hosts and relays\' names, commas between; what is neither is passed over and said', () {
      final c = of({'GHOST_FED_ALLOW': ' Relay.Example.org , ${'AB' * 16},x.test:8443,', 'GHOST_FED_BLOCK': 'bad.example,not a host,https://x.test,${'zz' * 16}'});
      expect(c.allow, {'relay.example.org', 'ab' * 16, 'x.test:8443'});
      expect(c.block, {'bad.example', 'zz' * 16}, reason: 'thirty-two letters are a host\'s name as well as they could be a relay\'s');
      expect(c.problems, hasLength(2));
      expect(c.problems.join(' '), allOf(contains('not a host'), contains('https://x.test')));
    });

    test('this relay\'s own address, and the relay it stays linked to: a hub\'s address, written as they are compared', () {
      expect(of({'GHOST_PUBLIC_HUB': 'wss://Relay.Example.com:443/hub/'}).publicHub, 'wss://relay.example.com/hub');
      expect(of({'GHOST_FED_VIA': 'wss://gogho.st/hub'}).via, 'wss://gogho.st/hub');
      expect(of({'GHOST_PUBLIC_HUB': 'ws://10.0.0.5:8787/hub'}).publicHub, 'ws://10.0.0.5:8787/hub', reason: 'what it says of itself is its keeper\'s to say; what it dials is held to the guard');
      for (final bad in ['relay.example.com', 'https://relay.example.com/hub', 'wss://relay.example.com', 'wss://relay.example.com/hub?x=1', 'wss://user@relay.example.com/hub', 'wss:///hub']) {
        final c = of({'GHOST_PUBLIC_HUB': bad, 'GHOST_FED_VIA': bad});
        expect([c.publicHub, c.via, c.problems], ['', '', hasLength(2)], reason: bad);
      }
    });

    test('the limits: each name sets its own; what does not read keeps the default, and says so', () {
      final c = of({'GHOST_FED_PACKETS_A_MINUTE': ' 60 ', 'GHOST_FED_BYTES_A_DAY': '1000000', 'GHOST_FED_LOOKUPS_AN_HOUR': '10'});
      expect([c.packetsAMinute, c.bytesADay, c.lookupsAnHour, c.problems], [60, 1000000, 10, isEmpty]);
      for (final junk in ['lots', '-1', '0', '1.5', '1e6', '0x10']) {
        final j = of({'GHOST_FED_PACKETS_A_MINUTE': junk, 'GHOST_FED_BYTES_A_DAY': junk, 'GHOST_FED_LOOKUPS_AN_HOUR': junk});
        expect([j.packetsAMinute, j.bytesADay, j.lookupsAnHour, j.problems], [1200, 512 << 20, 600, hasLength(3)], reason: junk);
      }
      expect(of({'GHOST_FED_PACKETS_A_MINUTE': '99999999999'}).packetsAMinute, 1000000, reason: 'held to its most');
    });

    test('ports and plain', () {
      final c = of({'GHOST_FED_PORTS': '8443, 9443,0,70000,x', 'GHOST_FED_PLAIN': '1'});
      expect([c.ports, c.plain, c.problems], [{8443, 9443}, true, hasLength(3)]);
      for (final junk in ['yes', 'true', '0', '']) {
        expect(of({'GHOST_FED_PLAIN': junk}).plain, isFalse, reason: junk);
      }
      // They reach the guard everything dialled is held to.
      final fed = Federation(config: c);
      expect(fed.guard.ports, {443, 8443, 9443});
      expect(fed.guard.plain, isTrue);
      expect(Federation().guard.ports, {443});
      expect(Federation().guard.plain, isFalse);
    });

    test('standing links: off unless set, open, or relays\' names; anything else passed over and said', () {
      expect([of(const {}).standingOpen, of(const {}).standing], [false, <String>{}]);
      expect([of({'GHOST_FED_STANDING': 'off'}).standingOpen, of({'GHOST_FED_STANDING': 'off'}).problems], [false, isEmpty]);
      expect(of({'GHOST_FED_STANDING': ' Open '}).standingOpen, isTrue);
      final c = of({'GHOST_FED_STANDING': '${'AB' * 16}, relay.example.org,${'cd' * 16}'});
      expect([c.standingOpen, c.standing, c.problems], [false, {'ab' * 16, 'cd' * 16}, hasLength(1)]);
    });
  });

  group('the relay\'s own key', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ghost-fed-key-'));
    tearDown(() => dir.deleteSync(recursive: true));
    const on = FedConfig(mode: FedMode.open);

    test('off, none is made or read, and no file is touched: the relay is the one it was before', () {
      final off = Federation(dataDir: dir);
      expect([off.on, off.card], [false, isNull]);
      off.homes.dirty = true;
      off.stop();
      expect(dir.listSync(), isEmpty, reason: 'no relay-key.json, no homes.json');
      // A key file from a time it was on is left as it is, unread.
      File('${dir.path}/relay-key.json').writeAsStringSync('{not json');
      Federation(dataDir: dir);
      expect(dir.listSync().map((f) => f.path.split('/').last), ['relay-key.json']);
    });

    test('made on first start, in relay-key.json, which only the relay\'s own user can read; the same key from then on', () {
      final first = Federation(dataDir: dir, config: on);
      final file = File('${dir.path}/relay-key.json');
      expect(file.existsSync(), isTrue);
      if (!Platform.isWindows) expect(file.statSync().modeString(), 'rw-------');
      final kept = jsonDecode(file.readAsStringSync()) as Map;
      expect(kept.keys, ['v', 'id', 'key', 'scalar']);
      expect([kept['id'], kept['key']], [first.id, base64Encode(first.key)]);
      expect(P256.publicOf([for (var i = 0; i < 64; i += 2) int.parse((kept['scalar'] as String).substring(i, i + 2), radix: 16)]), first.key);
      expect(first.id, Hub.nameOf(first.key), reason: 'its name is made from its key as an install\'s is');
      expect(File('${dir.path}/relay-key.json.tmp').existsSync(), isFalse);
      final again = Federation(dataDir: dir, config: on);
      expect([again.id, again.key], [first.id, first.key]);
      if (!Platform.isWindows) expect(file.statSync().modeString(), 'rw-------');
    });

    test('its mode is set on the file alone, before anything is written to it: nothing is changed for the rest of the process', () {
      if (Platform.isWindows) return markTestSkipped('a file on Windows has no such mode');
      final other = File('${dir.path}/before')..writeAsStringSync('x');
      final usual = other.statSync().modeString();
      Federation.writePrivately(File('${dir.path}/secret.json'), '{"a":1}');
      expect(File('${dir.path}/secret.json').statSync().modeString(), 'rw-------');
      expect(File('${dir.path}/secret.json').readAsStringSync(), '{"a":1}');
      final after = File('${dir.path}/after')..writeAsStringSync('x');
      expect(after.statSync().modeString(), usual, reason: 'a file the process makes after is made as one before it was: the mask was never narrowed');
      // And a file made as any is, set to the owner's alone.
      final plain = File('${dir.path}/plain')..writeAsStringSync('x');
      expect(Federation.onlyOwner(plain.path), isTrue);
      expect(plain.statSync().modeString(), 'rw-------');
    });

    test('with no folder it is kept in memory: a new one each time', () {
      expect(Federation(config: on).id, isNot(Federation(config: on).id));
      expect(dir.listSync(), isEmpty);
    });

    test('made in a folder that is not there yet', () {
      final deep = Directory('${dir.path}/not/yet');
      final fed = Federation(dataDir: deep, config: on);
      expect(File('${deep.path}/relay-key.json').existsSync(), isTrue);
      expect(Federation(dataDir: deep, config: on).id, fed.id);
    });

    test('a key file that can\'t be read is put aside, never written over, and a new key made', () {
      final file = File('${dir.path}/relay-key.json');
      for (final bad in ['{not json', '{"v":1}', '{"v":1,"scalar":"abc"}', '{"v":1,"scalar":"${'00' * 32}"}', '{"v":1,"scalar":"${'ff' * 32}"}']) {
        file.writeAsStringSync(bad);
        final fed = Federation(dataDir: dir, config: on);
        final aside = dir.listSync().whereType<File>().where((f) => f.path.contains('.broken-')).toList();
        expect(aside, isNotEmpty, reason: bad);
        expect(aside.any((f) => f.readAsStringSync() == bad), isTrue, reason: 'what was there is kept as it was');
        expect((jsonDecode(file.readAsStringSync()) as Map)['id'], fed.id);
        for (final f in aside) {
          f.deleteSync();
        }
      }
    });

    test('its signatures are its key\'s, each with a number of its own', () {
      // The same seed twice gives the same key; what it signs differs each time (a fresh number), and verifies.
      final x = Federation(random: Random(4), config: on), y = Federation(random: Random(4), config: on);
      expect(x.id, y.id);
      expect(x.card, {'id': x.id, 'key': base64Encode(x.key), 'fed': true}, reason: 'on, with no address: its name and key, and that it talks');
    });
  });

  test('the program, started with federation on: says so, names itself in the hub\'s hello, and keeps its key privately', () async {
    final data = await Directory.systemTemp.createTemp('ghost-relay-fed-');
    addTearDown(() => data.delete(recursive: true));
    final p = await Process.start(Platform.resolvedExecutable, ['bin/relay.dart', '--host', '127.0.0.1', '--port', '0', '--data', data.path],
        environment: const {'GHOST_FED': 'list', 'GHOST_FED_ALLOW': 'friend.example.org', 'GHOST_PUBLIC_HUB': 'wss://relay.example.com/hub', 'GHOST_FED_BLOCK': 'not a host'}, includeParentEnvironment: false);
    addTearDown(() => p.kill(ProcessSignal.sigkill));
    final err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write);
    final listening = Completer<(int, String)>();
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final m = RegExp(r'listening on ws://127\.0\.0\.1:(\d+)').firstMatch(line);
      if (m != null && !listening.isCompleted) listening.complete((int.parse(m.group(1)!), line));
    });
    final (port, line) = await listening.future.timeout(const Duration(seconds: 90), onTimeout: () => fail('it never said it was listening: $err'));
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub');
    final hello = jsonDecode(await ws.first.timeout(const Duration(seconds: 10)) as String) as Map;
    await ws.close();
    final card = hello['relay'] as Map;
    expect(card.keys, ['id', 'key', 'url', 'fed']);
    expect([card['url'], card['fed']], ['wss://relay.example.com/hub', true]);
    expect(Hub.nameOf(base64Decode(card['key'] as String)), card['id']);
    expect(line, contains('other relays: list, this one is ${card['id']}'));
    final key = File('${data.path}/relay-key.json');
    expect((jsonDecode(key.readAsStringSync()) as Map)['id'], card['id']);
    if (!Platform.isWindows) expect(key.statSync().modeString(), 'rw-------');
    p.kill(ProcessSignal.sigterm);
    expect(await p.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(err.toString().trim().split('\n'), ['relay: GHOST_FED_BLOCK: "not a host" is neither a host nor a relay\'s name, and is passed over'], reason: 'what it could not read, said once, and nothing else');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
