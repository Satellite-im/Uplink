import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/hub_pass.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/relay_choice.dart';
import 'package:ghost_messaging/relay_host/address.dart';
import 'package:ghost_messaging/relay_host/direct_link.dart';
import 'package:ghost_messaging/relay_host/hosting.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';
import 'package:ghost_relay/hub.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';
import 'support/host_support.dart';
import 'support/hub_pair.dart';

/// A relay hosted from the app (lib/relay_host; docs/OPEN_NETWORK.md, section 5; Matt, 2026-11-22: "i'd like everyone to
/// be able to host a relay from their client"): the same hub gogho.st runs, in the app, with a folder and a key of its
/// own and small limits; this app on it in memory, a device anywhere on it over Direct, a pass phrase where it is set;
/// up while the app runs and stopped cleanly. The local network in two processes and the link to a public relay are
/// test/relay_host_lan_test.dart's; the screens test/relay_host_settings_test.dart's.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  group('the pass phrase', () {
    const phrase = 'correct horse battery staple';
    final salt = 'ab' * 16;
    test('the app makes the key and the proof as the relay does, with the relay\'s own salt', () {
      final key = HubPass.keyNow(phrase, salt);
      expect(NetCrypto.hex(key), '57127492378841a4077eb48b9242dd3ab2f4d818086d9e7b010dac4843bbb1b4', reason: 'the value relay/test/hosted_options_test.dart holds the relay to');
      expect(key, Hub.passKeyOf(phrase, salt));
      expect(HubPass.keyNow(phrase, 'cd' * 16), isNot(key), reason: 'another relay, another key');
      final nonce = NetCrypto.randomBytes(32), id = NetKeys.generate().id;
      expect(HubPass.proof(key, nonce, id), NetCrypto.hex(Hub.passProof(key, nonce, id)));
      expect([HubPass.words, HubPass.rounds], [Hub.passWords, Hub.passRounds]);
    });
  });

  group('its addresses', () {
    final relay = 'ab' * 16, node = 'cd' * 32;
    test('its own: its name, the device it runs on over Direct, and the public relay it stays linked to, as written both ways', () {
      final a = GhostRelayAddress(relay: relay, node: node, via: 'wss://gogho.st/hub');
      expect('$a', 'ghost-relay://$relay?n=$node&via=wss%3A%2F%2Fgogho.st%2Fhub');
      expect(GhostRelayAddress.parse('$a'), a);
      expect(GhostRelayAddress.parse('GHOST-RELAY://${relay.toUpperCase()}?n=$node'), GhostRelayAddress(relay: relay, node: node), reason: 'read in lower case');
      expect('${GhostRelayAddress(relay: relay, via: 'wss://gogho.st/hub')}', 'ghost-relay://$relay?via=wss%3A%2F%2Fgogho.st%2Fhub', reason: 'what a home record names for its people (lib/net/home_record.dart hostedAddress)');
      // What isn't one is refused whole: someone else wrote it.
      for (final bad in ['ghost-relay://${'ab' * 15}', 'ghost-relay://$relay?n=${'cd' * 31}', 'ghost-relay://$relay?via=https%3A%2F%2Fx', 'ghost-relay://$relay:80', 'ghost-relay://$relay/path', 'wss://gogho.st/hub', 'ghost-relay://u@$relay']) {
        expect(GhostRelayAddress.parse(bad), isNull, reason: bad);
      }
    });

    test('a sign-in to it is bound to the device it was dialled at over Direct, or for the app it runs in to its name', () {
      expect(HubCarrier.hostOf('ghost-relay://$relay?n=$node&via=wss%3A%2F%2Fgogho.st%2Fhub'), node);
      expect(HubCarrier.hostOf('ghost-relay://$relay?via=wss%3A%2F%2Fgogho.st%2Fhub'), relay);
      expect(HubCarrier.hostOf('ws://192.168.1.5:7787/hub'), '192.168.1.5:7787', reason: 'on the local network, as any relay\'s');
    });

    test('the link to open carries either address, and the relay picker takes the address, the link, or nothing that isn\'t one', () {
      final own = 'ghost-relay://$relay?n=$node&via=wss%3A%2F%2Fgogho.st%2Fhub';
      expect(relayLink(own), 'ghostmsg://relay?a=${Uri.encodeQueryComponent(own)}');
      expect(relayFromLink(relayLink(own)), own);
      expect(relayFromLink(relayLink('ws://192.168.1.5:7787/hub')), 'ws://192.168.1.5:7787/hub');
      expect(relayFromLink('ghostmsg://relay?a=${Uri.encodeQueryComponent('https://evil.example/')}'), isNull);
      expect(relayFromLink('ghostmsg://add/maya'), isNull);
      expect(tidyRelayAddress(own.replaceFirst(relay, relay.toUpperCase())), own);
      expect(tidyRelayAddress(relayLink('ws://192.168.1.5:7787/hub')), 'ws://192.168.1.5:7787/hub');
      expect(tidyRelayAddress('ghost-relay://not-a-relay'), isNull);
      expect(tidyRelayAddress('ghostmsg://join/#c.abc'), isNull);
      expect(lanHubUrl('192.168.1.5', 7787), 'ws://192.168.1.5:7787/hub');
      expect(lanHubUrl('fd00::5', 7787), 'ws://[fd00::5]:7787/hub');
    });
  });

  group('this app on it, in memory', () {
    test('two installs sign in to it with no socket, and reach each other; the hub says it runs in an app and names its public relay', () async {
      final k = Kept();
      final host = makeHost(k);
      addTearDown(host.shutdown);
      await host.setOn(true);
      expect([host.on, host.state, host.relayId, k.choices[RelayHost.idKey]], [true, HostState.up, isNotNull, host.relayId]);
      final a = OnHost(host), b = OnHost(host);
      await a.up();
      await b.up();
      expect(host.connections, 2);
      // The hub's hello: hosted from an app, and the relay it stays linked to, which a home record names it by.
      expect([a.carrier.hosted, a.carrier.asksPass, a.carrier.relay?.id, a.carrier.relay?.via, a.carrier.relay?.url], [true, false, host.relayId, 'wss://gogho.st/hub', null]);
      // Signed in bound to the relay's own name (v2), which only this relay takes.
      expect(host.hub!.signsV2(a.id), isTrue);
      final handed = await a.carrier.send(Peer(id: b.id), Uint8List.fromList([7, 7, 7]));
      expect(handed, Handed.passed);
      await waitFor(() => b.got.isNotEmpty, 'the packet never reached b');
      expect([b.got.single.from, b.got.single.bytes], [a.id, [7, 7, 7]]);
      for (final x in [a, b]) {
        await x.carrier.stop();
      }
    });

    test('while it isn\'t running, its dial reaches nothing and says so', () async {
      final host = makeHost(Kept());
      await expectLater(host.dialHere(), throwsA(isA<HubDialRefused>().having((e) => e.message, 'message', 'The relay on this device isn\'t running.')));
    });
  });

  group('on the local network', () {
    test('its addresses are looked at again every half minute: moved to another network, it is shown and reached at its address there', () async {
      final clock = FakeClock();
      var addresses = ['127.0.0.1'];
      final host = makeHost(Kept(), lan: true, timer: clock.timer, addresses: () async => addresses);
      addTearDown(host.shutdown);
      await host.setOn(true);
      final port = Uri.parse(host.lanUrls.single).port;
      expect(host.lanUrls, ['ws://127.0.0.1:$port/hub']);
      addresses = ['127.0.0.2'];
      await clock.pass(const Duration(seconds: 28));
      expect(host.lanUrls, ['ws://127.0.0.1:$port/hub'], reason: 'not yet');
      await clock.pass(const Duration(seconds: 2));
      await waitFor(() => host.lanUrls.first == 'ws://127.0.0.2:$port/hub', 'the new address was never shown');
      expect(host.hub!.names, contains('127.0.0.2:$port'), reason: 'a sign-in bound to it is taken there');
    });
  });

  group('the public relay it stays linked to', () {
    test('gogho.st unless changed; changed, it starts again linked there, and its address names it; only a public relay\'s address is taken', () async {
      final k = Kept();
      final host = makeHost(k);
      addTearDown(host.shutdown);
      await host.setOn(true);
      expect([host.via, host.federation!.config.via, GhostRelayAddress.parse(host.ownUrl!)!.via], List.filled(3, Net.defaultHub));
      final id = host.relayId;
      expect(await host.setVia('Relay.Example.com'), isNull);
      expect([k.choices[RelayHost.viaKey], host.via, host.federation!.config.via, GhostRelayAddress.parse(host.ownUrl!)!.via], List.filled(4, 'wss://relay.example.com/hub'));
      expect([host.state, host.relayId], [HostState.up, id], reason: 'the same relay, linked elsewhere');
      // What the hub says of itself, which its people's records are made from.
      final a = OnHost(host);
      await a.up();
      expect(a.carrier.relay?.via, 'wss://relay.example.com/hub');
      await a.carrier.stop();
      for (final bad in ['ws://relay.example.com/hub', 'ghost-relay://${'ab' * 16}', 'not an address at all']) {
        expect(await host.setVia(bad), 'The relay it stays linked to is a public relay\'s address, like relay.example.com.', reason: bad);
      }
      expect(await host.setVia(''), isNull);
      expect([k.choices[RelayHost.viaKey], host.via], ['', Net.defaultHub]);
    });
  });

  group('its limits, the hub\'s own set small', () {
    test('200 connections (one more is closed at once), 24 MB held for people away, 8 MB of what rooms keep, 16 MB in flight', () async {
      final host = makeHost(Kept());
      addTearDown(host.shutdown);
      await host.setOn(true);
      final hub = host.hub!;
      expect([hub.maxConnections, hub.heldBytes, hub.roomKeepBytes, hub.wire.most, hub.wire.eachOut], [200, 24 << 20, 8 << 20, 16 << 20, 4 << 20]);
      // What it keeps of who signs in and where people live, sized for a few, not a server's (the second review,
      // 2026-11-23: 200,000 v2 keys and 20,000 home records).
      expect([hub.maxSignsV2, hub.newV2AnHourAll, host.federation!.homes.maxOwn, host.federation!.homes.maxOthers], [2000, 200, 1000, 1000]);
      expect([hub.hosted, hub.trustsProxy, hub.asksPass], [true, false, false]);
      // Two hundred connections, signed in or not, are taken; the two hundred and first is closed before it is greeted.
      final links = [for (var i = 0; i < 200; i++) await host.dialHere()];
      final greeted = <Future<Object?>>[for (final l in links.take(3)) l.said.first];
      expect((jsonDecode((await greeted.first) as String) as Map)['hello'], isA<String>());
      final extra = await host.dialHere();
      expect(await extra.said.toList(), isEmpty, reason: 'closed at once, nothing said');
      for (final l in links) {
        await l.close();
      }
      await pumpEventQueue();
      // And with one gone, there is room again.
      final again = await host.dialHere();
      expect((jsonDecode((await again.said.first) as String) as Map)['hello'], isA<String>());
      await again.close();
    });

    test('what is held for someone away is held to its 24 MB: past it, the sender is told it is full', () async {
      final host = makeHost(Kept());
      addTearDown(host.shutdown);
      await host.setOn(true);
      final a = OnHost(host);
      await a.up();
      // Each away person's mailbox takes a megabyte (16 of these); a few dozen people's would be past 24 MB: it keeps
      // 24 MB in all, then says full.
      var full = 0, kept = 0;
      for (var i = 0; i < 30 && full == 0; i++) {
        final away = NetKeys.generate().id;
        for (var j = 0; j < 16; j++) {
          try {
            await a.carrier.send(Peer(id: away), Uint8List(60 * 1024));
            kept++;
          } on CarrierError {
            full++;
          }
        }
      }
      expect(full, greaterThan(0));
      expect(host.hub!.holding, lessThanOrEqualTo(24 << 20));
      expect(kept * (60 * 1024 + 17), greaterThan(23 << 20), reason: 'it held all it may first');
      await a.carrier.stop();
    });
  });

  group('a pass phrase', () {
    const phrase = 'the long way round the lake';
    test('this app gives it as anyone does; one without it is refused, told so, and not dialled again by itself; given, it signs in', () async {
      final k = Kept();
      final host = makeHost(k);
      addTearDown(host.shutdown);
      await host.setOn(true);
      await host.setPass(phrase);
      expect([host.hasPass, k.secrets[RelayHost.passKey], host.hub!.asksPass], [true, phrase, true]);
      final mine = OnHost(host, pass: () => host.ownPass);
      await mine.up();
      expect(mine.carrier.asksPass, isTrue);
      String? given;
      final other = OnHost(host, pass: () => given, stranger: true);
      await other.carrier.start();
      await waitFor(() => other.carrier.passRefused != null, 'never refused');
      expect([other.carrier.passRefused, other.carrier.state.value, other.carrier.problem], ['needed', CarrierState.down, 'This relay asks for a pass phrase.']);
      // Waits for a phrase: no dial again by itself (each would be refused the same, and a wrong one counts).
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(other.dials, 1);
      given = 'the short way';
      other.carrier.passAgain();
      await waitFor(() => other.carrier.passRefused == 'wrong', 'a wrong one was never refused as wrong');
      expect(other.dials, 2);
      given = phrase;
      other.carrier.passAgain();
      await waitFor(() => other.carrier.state.value == CarrierState.up, 'never signed in with the right one');
      expect(other.carrier.passRefused, isNull);
      for (final x in [mine, other]) {
        await x.carrier.stop();
      }
    });

    test('refused for too many wrong phrases lately, the route waits as long as the relay says before it asks again (not its usual few seconds)', () async {
      final memory = MemoryHub(Hub(pass: phrase, passGuessesAll: 0));
      var dials = 0;
      final c = HubCarrier(url: memory.url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 5), dial: (url) {
        dials++;
        return memory.dial(url);
      })
        ..pass = () => phrase;
      await c.start();
      await waitFor(() => c.passRefused == 'busy', 'never refused as busy');
      expect(c.problem, 'Too many wrong pass phrases lately. Try again in a while.');
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(dials, 1, reason: 'its usual wait is 5 ms here; this one is the relay\'s');
      expect(c.passBusyFor, const Duration(hours: 1), reason: 'strangers have had all theirs this hour: the hour is out in an hour');
      expect(HubCarrier.passBusyWait, const Duration(minutes: 10), reason: 'where a relay doesn\'t say');
      await c.stop();
    });

    test('refused as wrong, the route waits for a phrase even when it is started again', () async {
      final memory = MemoryHub(Hub(pass: phrase));
      var dials = 0;
      final c = HubCarrier(url: memory.url, signer: KeysSigner(NetKeys.generate()), retry: const Duration(milliseconds: 5), dial: (url) {
        dials++;
        return memory.dial(url);
      })
        ..pass = () => 'not the phrase';
      await c.start();
      await waitFor(() => c.passRefused == 'wrong', 'never refused as wrong');
      await c.stop();
      await c.start();
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect([dials, c.state.value, c.passRefused], [1, CarrierState.down, 'wrong'], reason: 'started again, a wrong phrase would be refused the same, and counted');
      // Given one, it is asked again at once.
      c.pass = () => phrase;
      c.passAgain();
      await waitFor(() => c.state.value == CarrierState.up, 'never signed in with the phrase given');
      expect(dials, 2);
      await c.stop();
    });

    test('changed, everyone is signed out to sign in again with the new one', () async {
      final host = makeHost(Kept());
      addTearDown(host.shutdown);
      await host.setOn(true);
      final mine = OnHost(host, pass: () => host.ownPass);
      await mine.up();
      await host.setPass(phrase);
      await waitFor(() => mine.carrier.state.value == CarrierState.up && host.connections == 1 && host.hub!.asksPass, 'this app never signed in again with the new phrase');
      await host.setPass(null);
      await waitFor(() => !host.hub!.asksPass && host.connections == 1 && mine.carrier.state.value == CarrierState.up, 'never signed in again once it was taken away');
      await mine.carrier.stop();
    });
  });

  group('starting, stopping, signing out', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('relay-host-'));
    tearDown(() => dir.delete(recursive: true));

    test('stopping closes every connection, and this app sees its relay gone; what it held goes; its folder keeps its key, and it has the same name again', () async {
      final k = Kept();
      final host = makeHost(k, folder: dir);
      await host.setOn(true);
      final id = host.relayId;
      final a = OnHost(host);
      await a.up();
      // Something held for someone away, in memory.
      final away = NetKeys.generate();
      expect(await a.carrier.send(Peer(id: away.id), Uint8List.fromList(utf8.encode('SECRET-WORDS'))), Handed.held);
      await host.shutdown();
      await waitFor(() => a.carrier.state.value == CarrierState.down, 'this app never saw its relay go');
      expect(host.state, HostState.off);
      expect(host.on, isTrue, reason: 'shut down with the app, the choice stays');
      // What its folder keeps: its key and who signs in the newer way; nothing anyone said.
      final names = dir.listSync().map((f) => f.path.split(Platform.pathSeparator).last).toSet();
      expect(names, containsAll(['relay-key.json', 'hub-v2.json']));
      for (final f in dir.listSync().whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('SECRET-WORDS')), reason: f.path);
      }
      // Started again: the same name, and nothing of what it held.
      await host.startIfOn();
      expect(host.relayId, id);
      await waitFor(() => a.carrier.state.value == CarrierState.up, 'this app never came back to it');
      final b = OnHost(host, dial: (_) => host.dialHere());
      await b.up();
      expect(host.hub!.heldFor(away.id), 0, reason: 'what it held was in memory, and went when it stopped');
      for (final x in [a, b]) {
        await x.carrier.stop();
      }
      await host.shutdown();
    });

    test('switched off while this app uses it: the app goes back to the relay it used before, then it stops', () async {
      final k = Kept()..choices['net_hub'] = 'wss://relay.example.com/hub';
      final host = makeHost(k);
      await host.setOn(true);
      expect(await host.useHere(), isNull);
      expect([k.hubUrl, k.choices[RelayHost.beforeKey], host.inUse], [host.ownUrl, 'wss://relay.example.com/hub', true]);
      await host.setOn(false);
      expect([k.hubUrl, host.on, host.state, host.inUse], ['wss://relay.example.com/hub', false, HostState.off, false]);
    });

    test('signing out stops it and switches it off, forgets its pass phrase, keeps its folder, and sets this app\'s relay back', () async {
      final k = Kept();
      final host = makeHost(k, folder: dir);
      await host.setOn(true);
      await host.setPass('a phrase of the person signing out');
      expect(await host.useHere(), isNull);
      expect(k.choices[RelayHost.beforeKey], '', reason: 'it came from Uplink\'s own, kept as nothing chosen');
      await host.signedOut();
      expect([host.on, host.state, host.hasPass, k.secrets[RelayHost.passKey], k.hubUrl], [false, HostState.off, false, '', Net.defaultHub]);
      expect(File('${dir.path}/relay-key.json').existsSync(), isTrue);
    });
  });

  group('on a phone', () {
    test('it stops a minute after the app is put away, and starts again as it comes back; a computer\'s runs on', () async {
      final clock = FakeClock();
      final phone = makeHost(Kept(), phone: true, timer: clock.timer), computer = makeHost(Kept(), timer: clock.timer);
      addTearDown(phone.shutdown);
      addTearDown(computer.shutdown);
      for (final h in [phone, computer]) {
        await h.setOn(true);
        h.appAway(true);
      }
      await clock.pass(const Duration(seconds: 59));
      expect([phone.state, computer.state], [HostState.up, HostState.up]);
      await clock.pass(const Duration(seconds: 1));
      await waitFor(() => phone.state == HostState.off, 'the phone\'s never stopped');
      expect([phone.on, computer.state], [true, HostState.up], reason: 'stopped, not switched off');
      phone.appAway(false);
      await waitFor(() => phone.state == HostState.up, 'the phone\'s never started again');
      // Put away and back within the minute: never stopped.
      phone.appAway(true);
      await clock.pass(const Duration(seconds: 30));
      phone.appAway(false);
      await clock.pass(const Duration(minutes: 2));
      expect(phone.state, HostState.up);
    });
  });

  group('over Direct', () {
    late World w;
    const helper = 'https://link.example';
    setUp(() => w = World(helpers: const [helper]));
    tearDown(() => w.stop());

    test('a device anywhere reaches it by its node id on channel 1, Direct on at both ends, and it and this app reach each other', () async {
      final hostDevice = w.install(w.account('hana'), computer: true), joiner = w.install(w.account('jo'), network: 'cafe');
      await hostDevice.start();
      await joiner.start();
      final k = Kept();
      final host = makeHost(k, timer: w.clock.timer, p2p: () => hostDevice.p2p);
      addTearDown(host.shutdown);
      await host.setOn(true);
      await w.until(() => host.directUrl != null, 'the relay never had an address over Direct');
      final address = GhostRelayAddress.parse(host.directUrl!)!;
      expect([address.relay, address.node, address.via], [host.relayId, hostDevice.p2p.nodeId, 'wss://gogho.st/hub']);
      expect(hostDevice.node.calls['openToAll'], greaterThan(0));
      // Over Direct: the joiner's node opens a stream on channel 1 to the host's, which lets anyone in on it.
      final jo = HubCarrier(url: host.directUrl!, signer: KeysSigner(joiner.account.keys), retry: const Duration(hours: 1), now: w.clock.now, dial: (url) => dialOverDirect(joiner.p2p, GhostRelayAddress.parse(url)!));
      final joGot = <Arrived>[];
      jo.arrived.listen(joGot.add);
      await jo.start();
      await w.until(() => jo.state.value == CarrierState.up, 'the joiner never signed in over Direct: ${jo.problem}');
      expect(w.mesh.dials.where((d) => d.channel == P2pChannel.hub).map((d) => d.to), [hostDevice.p2p.nodeId]);
      expect(host.hub!.signsV2(joiner.account.id), isTrue, reason: 'bound to the node it dialled, which the direct network proves');
      // And this app, in memory, on the same relay.
      final hana = OnHost(host);
      await hana.up();
      expect(await jo.send(Peer(id: hana.id), Uint8List.fromList([1, 2, 3])), Handed.passed);
      await w.until(() => hana.got.isNotEmpty, 'what came over Direct never reached this app');
      expect([hana.got.single.from, hana.got.single.bytes], [joiner.account.id, [1, 2, 3]]);
      expect(await hana.carrier.send(Peer(id: joiner.account.id), Uint8List.fromList([4, 5])), Handed.passed);
      await w.until(() => joGot.isNotEmpty, 'what this app sent never went back over Direct');
      expect([joGot.single.from, joGot.single.bytes], [hana.id, [4, 5]]);
      await jo.stop();
      await hana.carrier.stop();
    });

    test('a first message longer than any door takes (16 KB), or a frame that is neither kind, ends the stream', () async {
      final hostDevice = w.install(w.account('hana'), computer: true), joiner = w.install(w.account('jo'), network: 'cafe');
      await hostDevice.start();
      await joiner.start();
      final host = makeHost(Kept(), timer: w.clock.timer, p2p: () => hostDevice.p2p);
      addTearDown(host.shutdown);
      await host.setOn(true);
      await w.until(() => host.directUrl != null, 'the relay never had an address over Direct');
      await joiner.p2p.up();
      Future<({P2pStream s, List<Object?> said, bool Function() done})> open() async {
        final s = await joiner.p2p.node.open(hostDevice.p2p.nodeId!, P2pChannel.hub, hint: const Whereabouts(helper: helper));
        final said = <Object?>[];
        var done = false;
        s.frames.listen((f) => said.add(DirectFrames.decode(f)), onDone: () => done = true);
        await w.until(() => said.isNotEmpty, 'the hub never said hello');
        return (s: s, said: said, done: () => done);
      }

      // A good hello, signed, made longer than 16 KB: refused for its length alone, before it is read. (One of 15 KB
      // signs in.)
      Future<String> hello(({P2pStream s, List<Object?> said, bool Function() done}) line, NetKeys keys, int length) async {
        final nonce = NetCrypto.unhex((jsonDecode(line.said.first as String) as Map)['hello'] as String);
        final sig = NetCrypto.sign(keys, [...utf8.encode(HubCarrier.greeting), ...nonce]);
        final m = jsonEncode({'id': keys.id, 'key': base64Encode(keys.public), 'sig': base64Encode(sig), 'pad': ''});
        return m.replaceFirst('"pad":""', '"pad":"${'x' * (length - m.length)}"');
      }

      final fits = await open(), fitsKeys = NetKeys.generate();
      await fits.s.add(DirectFrames.encode(await hello(fits, fitsKeys, 15 << 10)));
      await w.until(() => fits.said.length > 1, 'a hello of 15 KB was never answered');
      expect((jsonDecode(fits.said[1] as String) as Map)['ok'], true);
      await fits.s.close();
      await w.until(() => host.connections == 0, 'it never left');
      final long = await open(), longKeys = NetKeys.generate();
      await long.s.add(DirectFrames.encode(await hello(long, longKeys, 17 << 10)));
      await w.until(long.done, 'a first message of 17 KB was taken');
      expect(long.said, hasLength(1), reason: 'nothing said back but the hub\'s own hello');
      final odd = await open();
      await odd.s.add(Uint8List.fromList([9, 1, 2, 3]));
      await w.until(odd.done, 'a frame of no kind was taken');
      expect(host.connections, 0);
    });

    test('with Direct off at the joiner\'s end it isn\'t dialled, and says why; off at the host\'s, the channel is closed to everyone', () async {
      final hostDevice = w.install(w.account('hana'), computer: true), joiner = w.install(w.account('jo'), network: 'cafe');
      await hostDevice.start();
      await joiner.start();
      final host = makeHost(Kept(), timer: w.clock.timer, p2p: () => hostDevice.p2p);
      addTearDown(host.shutdown);
      await host.setOn(true);
      await w.until(() => host.directUrl != null, 'the relay never had an address over Direct');
      final address = GhostRelayAddress.parse(host.directUrl!)!;
      joiner.p2p.setOn(false);
      await expectLater(dialOverDirect(joiner.p2p, address), throwsA(isA<DirectDialError>().having((e) => e.message, 'message', contains('Direct is switched off on this device'))));
      await expectLater(dialOverDirect(null, address), throwsA(isA<DirectDialError>()));
      await expectLater(dialOverDirect(joiner.p2p, address.withNode(null)), throwsA(isA<DirectDialError>().having((e) => e.message, 'message', contains('names no device'))));
      joiner.p2p.setOn(true);
      hostDevice.p2p.setOn(false);
      await w.settle();
      expect(host.directUrl, isNull);
      final dial = dialOverDirect(joiner.p2p, address, timeout: const Duration(seconds: 5));
      final failed = expectLater(dial, throwsA(isA<DirectDialError>()));
      await w.clock.pass(const Duration(seconds: 6));
      await failed;
    });
  });
}
