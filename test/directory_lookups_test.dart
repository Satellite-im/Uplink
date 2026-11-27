import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

// Lookups in the relay's directory (Me.whois) against a real relay, as friends by username make them (found in the
// review of the who-sent fix, 2026-11-23, its probes 6, 7 and 9). Me kept one waiting slot for every lookup, filled by
// whichever answer came: two at once took each other's answers. Each test here failed on the code before.

Future<void> _until(bool Function() done, {String? reason}) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

/// An install signed in to the relay: its hub's route and its Me.
class _Install {
  _Install(String url) : hub = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()));
  final HubCarrier hub;
  final store = MemoryMeStore();
  final routes = ChangeNotifier();
  late Me me = Me.forTest();

  NetKeys get keys => (hub.signer as KeysSigner).keys;
  String get id => hub.signer.id;

  Future<void> open() async {
    await hub.start();
    await _until(() => hub.state.value == CarrierState.up, reason: hub.problem);
    await me.start(store, routes, () => hub);
    me.wake();
    await _until(() => me.ready);
  }

  Future<void> close() => hub.stop();
}

void main() {
  late Relay relay;
  late Directory dir;
  late String url;
  late _Install maya, ben, me;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('lookups');
    relay = Relay(hub: Hub(handles: Handles(dataDir: dir, fetch: (m, u, {headers = const {}, body, outside = false}) async => const Fetched(404, ''), config: const HandlesConfig(publicUrl: 'http://127.0.0.1'))));
    url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
    maya = _Install(url);
    ben = _Install(url);
    me = _Install(url);
    for (final i in [maya, ben, me]) {
      await i.open();
    }
    await maya.me.claimUsername('maya');
    await ben.me.claimUsername('benny');
  });
  tearDown(() async {
    for (final i in [maya, ben, me]) {
      await i.close();
    }
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  test('two lookups at once each get the answer to their own name; one of a name already being looked up shares it', () async {
    final got = await Future.wait([
      for (final name in ['maya', 'benny', 'nobody.here', 'Maya']) me.me.whois(name).then((r) => r?.id, onError: (Object e) => 'error: $e'),
    ]);
    expect(got, [maya.id, ben.id, null, maya.id]);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('two real friend requests the relay hands over together are both kept, each checked', () async {
    final port = _MePort(me.me, me.keys);
    final buddies = Buddies(port);
    await buddies.start();
    for (final (from, name) in [(maya, 'maya'), (ben, 'benny')]) {
      port.hellos.add((from: from.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': name, 'n': name, 'k': base64Encode(from.keys.public)})));
    }
    await _until(() => buddies.requests.where((r) => r.checked).length == 2, reason: '${buddies.requests.map((r) => '${r.username} checked: ${r.checked}')}');
    expect({for (final r in buddies.requests) r.username: r.id}, {'maya': maya.id, 'benny': ben.id});
    buddies.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('a friend added by username while another lookup is in flight is the one the directory gives for that name', () async {
    final port = _MePort(me.me, me.keys);
    final buddies = Buddies(port);
    await buddies.start();
    // A request from Maya being checked as it comes, say.
    unawaited(me.me.whois('maya').then((_) {}, onError: (Object _) {}));
    final asked = await buddies.add('benny');
    expect([asked.username, asked.id == ben.id, asked.id == maya.id], ['benny', true, false]);
    buddies.dispose();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('the relay\'s refusal of too many lookups is the one lookup in flight\'s, said at once, not a wait for an answer', () async {
    // Up to the relay's limit an hour (relay/lib/handles.dart, lookupsAnHour), then one more.
    for (var i = 0; i < Handles.lookupsAnHour; i++) {
      await me.me.whois(i.isEven ? 'maya' : 'benny');
    }
    final began = DateTime.now();
    await expectLater(me.me.whois('maya'), throwsA(isA<MeError>().having((e) => e.message, 'says why', contains('Too many lookups'))));
    expect(DateTime.now().difference(began), lessThan(const Duration(seconds: 20)), reason: 'not the 25 seconds of waiting for an answer that never comes');
    // And the next lookup is asked, and refused for the same reason, rather than waiting on the first.
    await expectLater(me.me.whois('benny'), throwsA(isA<MeError>()));
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// Friends by username over the real Me, and so the real relay's directory, with routes that go nowhere.
class _MePort implements BuddiesPort {
  _MePort(this.directory, this.keys);
  final Me directory;
  final NetKeys keys;
  final hellos = StreamController<({String from, Envelope envelope})>.broadcast();
  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  String list = '[]';
  @override
  Future<({String id, String key})> me() async => (id: keys.id, key: base64Encode(keys.public));
  @override
  String? get username => 'me.here';
  @override
  String get displayName => '';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) => directory.whois(username);
  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => hellos.stream;
}
