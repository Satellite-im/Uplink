import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/home_record.dart';
import 'package:ghost_messaging/net/homes.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/hub_link.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_messaging/voice/friend_calls.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_relay/federation.dart' show FedMode;

import 'support/hub_pair.dart';
import 'support/relay_app.dart';
import 'support/relay_net.dart';

/// What the review of relays that talk found on the app's side (2026-11-23), each a test that fails without its fix:
/// a name looked up on another relay handing that relay a sign-in as the account, a sign-in signature tied to no relay,
/// two names of one relay taken for two relays, answers taken for the wrong question, a relay's word taken for the
/// account's own count, strangers' records said at every sign-in, and a friend told once and never again.

/// What "wss://evil.test/hub" is to an app that dials it: a man in the middle. It dials the app's own relay, hands the
/// app that relay's number as its own hello (as one from before, or saying it takes v2), and says the app's signed
/// answer there under a device name of its own.
class _Mitm implements HubLink {
  _Mitm(this.home, {this.sayV2 = false});
  final MemoryHub home;
  final bool sayV2;
  final _toApp = StreamController<Object>();
  late final HubLink up;
  final List<Object> heard = [];
  bool? inAsVictim;
  String? signedAs;
  bool _helloed = false, _passed = false;

  Future<void> open() async {
    up = await home.dial(home.url);
    up.said.listen((data) {
      if (data is String) {
        final m = jsonDecode(data) as Map;
        if (m['hello'] is String && !_helloed) {
          _helloed = true;
          _toApp.add(jsonEncode({'hello': m['hello'], if (sayV2) 'v2': true}));
          return;
        }
        if (m.containsKey('ok') && inAsVictim == null) inAsVictim = m['ok'] == true;
      }
      heard.add(data);
    });
  }

  @override
  Stream<Object> get said => _toApp.stream;

  @override
  void say(Object message) {
    if (message is! String) return;
    final m = jsonDecode(message) as Map;
    if (m['sig'] is String && !_passed) {
      _passed = true;
      signedAs = m['id'] as String?;
      up.say(jsonEncode({...m, 'device': 'ee' * 16, 'mode': 'invisible'}));
      _toApp.add(jsonEncode({'ok': true, 'held': 0}));
    } else if (m['dir'] == 'whois') {
      _toApp.add(jsonEncode({'dir': 'whois', 'name': m['name'], 'none': true}));
    }
  }

  @override
  Future<void> close() async {}
}

/// A host whose every dial reaches a [_Mitm] in front of [home].
class _EvilHost extends MemoryHub {
  _EvilHost(this.home, {this.sayV2 = false}) : super(null, 'wss://evil.test/hub');
  final MemoryHub home;
  final bool sayV2;
  _Mitm? last;
  @override
  Future<HubLink> dial(String url) async {
    final m = last = _Mitm(home, sayV2: sayV2);
    await m.open();
    return m;
  }
}

/// A hub link the test speaks for: it signs the app in, keeps what the app says, and says what the test gives it.
class _Script implements HubLink {
  _Script({this.card});
  final Map<String, Object?>? card;
  final _toApp = StreamController<Object>();
  final List<Map> saidByApp = [];
  void start() => _toApp.add(jsonEncode({'hello': 'ab' * 32, 'peek': true, 'react': true, 'relay': ?card}));
  void tell(Map<String, Object?> m) => _toApp.add(jsonEncode(m));
  @override
  Stream<Object> get said => _toApp.stream;
  @override
  void say(Object message) {
    if (message is! String) return;
    final m = jsonDecode(message) as Map;
    saidByApp.add(m);
    if (m['sig'] is String) tell({'ok': true, 'held': 0});
  }

  @override
  Future<void> close() async {}
}

class _Store implements MeStore {
  final Map<String, String> kept = {};
  @override
  String choice(String key, String fallback) => kept[key] ?? fallback;
  @override
  bool flag(String key, {bool fallback = true}) => kept[key] == null ? fallback : kept[key] == 'on';
  @override
  void set(String key, String value) => kept[key] = value;
  @override
  void setFlag(String key, bool on) => kept[key] = on ? 'on' : 'off';
}

extension on RelayApp {
  Buddy get friend => buddies.friends.single;
}

class _CallPort implements FriendCallsPort {
  _CallPort(this.myId);
  @override
  final String myId;
  final sent = <Envelope>[];
  @override
  Peer? peerOf(String id) => Peer(id: id, key: Uint8List(32));
  @override
  Future<bool> send(Peer peer, Envelope envelope, {bool urgent = false}) async {
    sent.add(envelope);
    return true;
  }

  @override
  Future<void> sendMine(Envelope envelope) async {}
}

class _Notes implements CallNotes {
  final lines = <String>[];
  @override
  void note(String address, String words, {required bool out}) => lines.add(words);
}

void main() {
  final apps = <RelayApp>[];
  tearDown(() async {
    for (final x in apps) {
      await x.stop();
    }
    apps.clear();
  });

  group('a name looked up on another relay', () {
    test('as it is typed nobody is dialled; on Add, that relay is asked under a key of no account\'s, and gets no sign-in as this one', () async {
      final net = RelayNet();
      // The victim's relay as the live one is: usernames, no federation, says nothing of itself.
      final home = net.relay('home.test', federation: false);
      final evil = _EvilHost(home);
      net.byUrl[evil.url] = evil;
      final victim = RelayApp(net, 'victim', home), friend = RelayApp(net, 'friend', home);
      apps.addAll([victim, friend]);
      await victim.start();
      await friend.start();
      expect(victim.homes.relayTalks, isFalse);
      // What the add-friend drawer does as "eve@evil.test" is typed or pasted: nothing is dialled.
      expect(await victim.buddies.lookup('eve@evil.test'), BuddyLookup.elsewhere);
      expect(evil.last, isNull, reason: 'nobody was dialled as the name was typed');
      // Add pressed: evil.test is asked, under a key made for the one question.
      await expectLater(victim.buddies.add('eve@evil.test'), throwsA(isA<MeError>()));
      final mitm = evil.last!;
      await until(() => mitm.inAsVictim != null, 'evil.test never passed the signature on');
      expect(mitm.signedAs, isNot(victim.id), reason: 'the signature handed over is no account\'s');
      expect(home.hub.connected, 3, reason: 'the victim, the friend, and evil.test signed in as nobody: not one more device of the victim\'s');
      // What the friend sends the victim goes to the victim alone.
      expect(await friend.hub.send(Peer(id: victim.id), Uint8List.fromList([1, 2, 3])), Handed.passed);
      await pumpEventQueue();
      expect(mitm.heard.whereType<Uint8List>(), isEmpty);
    });

    test('a name asked of a relay that offers v2 is asked under a v1 sign-in: the key thrown away is not kept there among those it holds to', () async {
      final net = RelayNet();
      final home = net.relay('home.test', federation: false);
      final there = net.relay('there.test', federation: false, names: {'there.test'});
      final asker = RelayApp(net, 'asker', home), maya = RelayApp(net, 'maya', there);
      apps.addAll([asker, maya]);
      await asker.start();
      await maya.start();
      expect(there.hub.keptV2, 1, reason: 'Maya\'s own app signs v2 there');
      // (Found, and refused as on a relay that passes nothing on: what matters is how it was asked.)
      await asker.buddies.add('maya@there.test').then((_) {}, onError: (_) {});
      await until(() => net.asked.contains(there.url), 'there.test was never asked');
      await pumpEventQueue();
      expect(there.hub.keptV2, 1, reason: 'the lookup\'s key was not kept');
    });

    test('where this app\'s relay says it won\'t talk to that one, the app doesn\'t go around it; and a host it wouldn\'t dial is asked of nobody', () async {
      final net = RelayNet();
      final a = net.relay('a.test'), closed = net.relay('closed.test', block: {'a.test'});
      final alex = RelayApp(net, 'alex', a), zoe = RelayApp(net, 'zoe', closed);
      apps.addAll([alex, zoe]);
      await alex.start();
      await zoe.start();
      await expectLater(alex.homes.whois('zoe', 'closed.test'), throwsA(isA<HomeError>().having((e) => e.message, 'message', 'closed.test doesn\'t take messages from your relay.')));
      expect(net.asked, isEmpty);
      for (final host in ['192.168.1.1', 'b.test:22', 'metadata.google.internal', 'nas.local', '127.0.0.1']) {
        await expectLater(alex.homes.whois('x', host), throwsA(isA<HomeError>()), reason: host);
      }
      expect([net.asked, net.dialled.where((u) => !u.contains('closed') && !u.contains('a.test'))], [isEmpty, isEmpty]);
      expect([dialableRelayHost('relay.example.com'), dialableRelayHost('relay.example.com:443'), dialableRelayHost('93.184.216.34')], [true, true, true]);
    });
  });

  group('a sign-in bound to the relay (v2)', () {
    test('the app signs v2 to a relay that takes it, bound to the host it dialled, and v1 to one from before', () async {
      final net = RelayNet();
      final bound = net.relay('a.test', names: {'a.test'}), old = net.relay('old.test', federation: false);
      final alex = RelayApp(net, 'alex', bound), olga = RelayApp(net, 'olga', old);
      apps.addAll([alex, olga]);
      await alex.start();
      await olga.start();
      expect(bound.hub.signsV2(alex.id), isTrue, reason: 'it signed in with v2 there');
      expect(HubCarrier.hostOf('wss://A.test:443/hub'), 'a.test');
      expect(HubCarrier.hostOf('ws://10.0.0.5:8787/hub'), '10.0.0.5:8787');
      expect(old.hub.signsV2(olga.id), isFalse);
      expect(olga.hub.state.value, CarrierState.up, reason: 'and a relay from before is signed in to as ever');
    });

    test('the number of this app\'s own relay passed on by another relay is worth nothing there, whichever way the app is asked to sign', () async {
      for (final sayV2 in [true, false]) {
        final net = RelayNet();
        final home = net.relay('home.test', names: {'home.test'});
        final victim = RelayApp(net, 'victim', home);
        apps.add(victim);
        await victim.start();
        expect(home.hub.signsV2(victim.id), isTrue);
        // The victim's own route dials evil.test (pointed there, or asking it a name the old way): evil.test hands it
        // the number of the victim's relay, saying it takes v2 or pretending to be from before.
        final evil = _EvilHost(home, sayV2: sayV2);
        final route = HubCarrier(url: evil.url, signer: victim.signer, dial: evil.dial);
        addTearDown(route.stop);
        await route.start();
        await until(() => evil.last?.inAsVictim != null, 'evil.test never passed the signature on');
        expect(evil.last!.inAsVictim, isFalse, reason: sayV2 ? 'signed for evil.test: not a host of the victim\'s relay' : 'v1 from a key that signed in with v2 there');
        expect(home.hub.connected, 1, reason: 'only the victim\'s own connection');
      }
    });
  });

  test('two names of Uplink\'s own relay are one relay where it names none of its own', () async {
    final signer = KeysSigner(NetKeys.generate());
    final link = _Script();
    final hub = HubCarrier(url: 'wss://gogho.st/hub', signer: signer, dial: (_) async => link);
    final homes = Homes(signer: signer, read: (_) => '', write: (_, _) {})..attach(hub);
    addTearDown(() async {
      homes.dispose();
      await hub.stop();
    });
    await hub.start();
    link.start();
    await until(() => hub.state.value == CarrierState.up, 'never signed in');
    expect([homes.namesHere(['wss://ghost-sms.com/hub']), homes.namesHere(['wss://www.gogho.st/hub']), homes.namesHere(['wss://gogho.st/hub'])], [true, true, true]);
    expect([homes.isHere('ghost-sms.com'), homes.isHere('www.gogho.st'), homes.isHere('relay.example.com')], [true, true, false]);
    expect(homes.namesHere(['wss://relay.example.com/hub']), isFalse);
  });

  test('Me.whois takes only the answer for the name asked here, never one asked of another relay', () async {
    final signer = KeysSigner(NetKeys.generate());
    final relay = NetKeys.generate();
    final link = _Script(card: {'id': relay.id, 'key': base64Encode(relay.public), 'url': 'wss://a.test/hub', 'fed': true});
    final hub = HubCarrier(url: 'wss://a.test/hub', signer: signer, dial: (_) async => link);
    final homes = Homes(signer: signer, read: (_) => '', write: (_, _) {}, answerWithin: const Duration(seconds: 2))..attach(hub);
    final me = Me.forTest();
    await me.start(_Store(), ValueNotifier(0), () => hub);
    addTearDown(() async {
      homes.dispose();
      await hub.stop();
    });
    await hub.start();
    link.start();
    await until(() => hub.state.value == CarrierState.up && homes.relayTalks, 'never signed in to a relay that talks');
    // The same name asked of another relay and here at once: each takes its own answer, whichever comes first.
    final far = homes.whois('maya', 'b.test');
    await pumpEventQueue();
    final near = me.whois('maya');
    await pumpEventQueue();
    final mayaThere = NetKeys.generate(), mayaHere = NetKeys.generate(), bob = NetKeys.generate(), cara = NetKeys.generate();
    link.tell({'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'id': mayaThere.id, 'key': base64Encode(mayaThere.public)});
    link.tell({'dir': 'whois', 'name': 'maya', 'id': mayaHere.id, 'key': base64Encode(mayaHere.public)});
    expect((await far)!.id, mayaThere.id);
    expect((await near)!.id, mayaHere.id, reason: 'the other relay\'s answer for the same name is not this lookup\'s');
    // Two names asked here: one at a time, each its own answer (Me.whois).
    final bobLooked = me.whois('bob'), caraLooked = me.whois('cara');
    await until(() => link.saidByApp.any((m) => m['dir'] == 'whois' && m['name'] == 'bob'), 'bob was never asked');
    link.tell({'dir': 'whois', 'name': 'bob', 'id': bob.id, 'key': base64Encode(bob.public)});
    await until(() => link.saidByApp.any((m) => m['dir'] == 'whois' && m['name'] == 'cara'), 'cara was never asked');
    link.tell({'dir': 'whois', 'name': 'cara', 'id': cara.id, 'key': base64Encode(cara.public)});
    expect([(await bobLooked)!.id, (await caraLooked)!.id], [bob.id, cara.id], reason: 'each name its own answer');
    // An error about a name asked of another relay is that lookup's alone: one asked here still gets its own answer.
    final farAgain = homes.whois('dan', 'b.test');
    await pumpEventQueue();
    final nearAgain = me.whois('erin');
    await pumpEventQueue();
    link.tell({'dir': 'err', 'about': 'whois', 'at': 'b.test', 'err': 'Too many lookups. Try again in a while.'});
    final erin = NetKeys.generate();
    link.tell({'dir': 'whois', 'name': 'erin', 'id': erin.id, 'key': base64Encode(erin.public)});
    await expectLater(farAgain, throwsA(isA<HomeError>().having((e) => e.message, 'message', contains('Too many lookups'))));
    expect((await nearAgain)!.id, erin.id);
  });

  test('a relay\'s word that a newer record exists is not taken for the count: the record is asked back and held to this account\'s key', () async {
    final signer = KeysSigner(NetKeys.generate());
    final choices = <String, String>{};
    final link = _Script();
    final hub = HubCarrier(url: 'wss://a.test/hub', signer: signer, dial: (_) async => link);
    final homes = Homes(signer: signer, read: (k) => choices[k] ?? '', write: (k, v) => choices[k] = v)..attach(hub);
    addTearDown(() async {
      homes.dispose();
      await hub.stop();
    });
    await hub.start();
    link.start();
    await until(() => homes.mine != null, 'no record was made');
    final n = homes.mine!.n;
    link.tell({'dir': 'home', 'a': signer.id, 'ok': true, 'n': HomeRecord.maxCount});
    await until(() => link.saidByApp.any((m) => m['dir'] == 'home?' && m['a'] == signer.id), 'the record was not asked back');
    // The relay answers with nothing, or with a record that isn't this account's: the count stands.
    link.tell({'dir': 'home?', 'a': signer.id, 'none': true});
    final mallory = KeysSigner(NetKeys.generate());
    link.tell({'dir': 'home?', 'a': signer.id, 'rec': (await HomeRecord.make(mallory, addresses: ['wss://a.test/hub'], count: HomeRecord.maxCount)).toJson()});
    await pumpEventQueue();
    expect([homes.count, choices['net_home_n']], [n, '$n']);
    await homes.moveTo('wss://b.test/hub');
    expect(homes.mine!.h, ['wss://b.test/hub'], reason: 'a record can still be made for the next relay');
  });

  test('a stranger\'s request doesn\'t make this app say their record at sign-in; a yes does', () async {
    final net = RelayNet();
    final a = net.relay('a.test'), b = net.relay('b.test');
    final alex = RelayApp(net, 'alex', a);
    apps.add(alex);
    await alex.start();
    // Someone on relay b asks, whose name b's directory gives them (so the request can be checked, and said yes to).
    final pat = RelayApp(net, 'patrick', b);
    apps.add(pat);
    await pat.start();
    await pat.buddies.add('alex@a.test');
    final strangers = [for (var i = 0; i < 4; i++) KeysSigner(NetKeys.generate())];
    for (final s in strangers) {
      final rec = await HomeRecord.make(s, addresses: ['wss://far${strangers.indexOf(s)}.example/hub'], count: 1);
      final carrier = HubCarrier(url: a.url, signer: s, dial: a.dial);
      await carrier.start();
      await until(() => carrier.state.value == CarrierState.up, 'a stranger never signed in');
      final hello = Envelope(kind: 'hello', body: {'buddy': 'ask', 'k': base64Encode(s.publicKey), 'u': 'spam${strangers.indexOf(s)}', 'h': rec.toJson()});
      await carrier.send(Peer(id: alex.id), Packet.wrap(from: s.id, sealed: false, payload: hello.encode()));
      await carrier.stop();
    }
    await until(() => alex.buddies.requests.length == strangers.length + 1, 'the requests never came');
    List<Map> others() => [for (final m in alex.hub.onSignIn!()) if ((m['rec'] as Map)['a'] != alex.id) m];
    expect(others(), isEmpty, reason: 'nobody answered them: their records are not said');
    await alex.buddies.accept(alex.buddies.requests.firstWhere((r) => r.id == pat.id));
    expect([for (final m in others()) (m['rec'] as Map)['a']], [pat.id], reason: 'one said yes to: theirs is');
  });

  test('a friend told once while on an app from before is told again when they are first heard from, and counts as told only when they say so', () async {
    final net = RelayNet();
    final a = net.relay('a.test'), b = net.relay('b.test');
    final alexKeys = NetKeys.generate(), mayaKeys = NetKeys.generate();
    Map<String, Object> friendOf(String name, NetKeys k) => {'u': name, 'i': k.id, 'k': base64Encode(k.public), 's': 'yes', 'a': 0};
    // Friends from before relays talked, both on relay a. Alex's app of the build before counted Maya as told (her
    // app was from before, and passed his record over): that state is not read.
    final alex = RelayApp(net, 'alex', a, keys: alexKeys, kept: {'buddies_home_told': jsonEncode({mayaKeys.id: 1})})..list = jsonEncode([friendOf('maya', mayaKeys)]);
    final maya = RelayApp(net, 'maya', a, keys: mayaKeys)..list = jsonEncode([friendOf('alex', alexKeys)]);
    apps.addAll([alex, maya]);
    await alex.start();
    await maya.start();
    // Both on one relay: nobody is told anything at the first start (no burst of envelopes, no "New message" pushes).
    expect([alex.buddies.waitingToHear, maya.buddies.waitingToHear], [0, 0]);
    // She moves to relay b, and tells him: he hears her record for the first time, and answers with his.
    await maya.moveTo(b);
    expect(await maya.buddies.tellNext(), isTrue);
    await until(() => alex.friend.homeHost == 'b.test', 'he never heard hers');
    await until(() => maya.friend.home != null, 'she was never told his');
    expect(HomeRecord.check(maya.friend.home, forId: alex.id), isNotNull);
    // So relay b knows where he lives (her app says it at sign-in), and what she writes reaches him.
    await until(() => net.feds[b.url]!.homes.of(alex.id) != null, 'relay b was never told where he lives');
    final d = await maya.write(alex, 'hello from b');
    expect(d.sent, isTrue);
    await until(() => alex.texts.any((t) => t.text == 'hello from b'), 'what she wrote never reached him');
    // And he is labelled by where she lives now.
    expect(alex.friend.username, 'maya@b.test');
  });

  test('a ring from a friend on another relay doesn\'t ring: it is kept as missed, and why', () async {
    final net = RelayNet();
    final a = net.relay('a.test'), b = net.relay('b.test');
    final alex = RelayApp(net, 'alex', a), maya = RelayApp(net, 'maya', b);
    apps.addAll([alex, maya]);
    await alex.start();
    await maya.start();
    await alex.buddies.add('maya@b.test');
    await until(() => maya.buddies.requests.isNotEmpty, 'the request never reached Maya');
    await maya.buddies.accept(maya.buddies.requests.single);
    await until(() => alex.buddies.friends.isNotEmpty && alex.friend.home != null, 'they never became friends');
    expect([alex.buddies.apart(alex.friend), alex.buddies.elsewhere(alex.friend)], [true, true]);
    // Her ring comes: not rung, kept as missed with why; and calling her is not even tried.
    Buddies.instance = alex.buddies;
    addTearDown(() => Buddies.instance = null);
    final notes = _Notes(), port = _CallPort(alex.id);
    final calls = FriendCalls(port: port, notes: notes);
    expect(calls.received(Received(Peer(id: maya.id, key: Uint8List(32)), Envelope(kind: 'voice', body: {'t': 'call', 'i': 'c1', 'v': false}), 'hub'), mine: false), isTrue);
    expect(Voice.instance.ringing, isNull, reason: 'answering would join a room here she never comes into');
    expect(notes.lines, ['Missed call · calls don\'t reach another relay yet']);
    expect(await calls.call(alex.friend, join: (_, _) async => fail('not joined')), isFalse);
    expect(port.sent, isEmpty);
    // Where this app's relay doesn't talk to others, a friend is taken to be here for calls and who is here.
    final island = net.relay('island.test', mode: FedMode.off);
    final ida = RelayApp(net, 'ida', island);
    apps.add(ida);
    await ida.start();
    await ida.buddies.takeAll(jsonEncode([Buddy(username: 'maya@b.test', id: maya.id, key: base64Encode(maya.keys.public), state: 'yes', home: maya.homes.mine!.toJson()).toJson()]));
    expect([ida.buddies.elsewhere(ida.friend), ida.buddies.apart(ida.friend)], [true, false]);
    expect(alex.buddies.roomFriends, isEmpty, reason: 'a circle, a space or a call can\'t take a friend on another relay');
  });
}
