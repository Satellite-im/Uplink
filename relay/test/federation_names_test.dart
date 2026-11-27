import 'dart:convert';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// Names across relays (lib/federation.dart; docs/OPEN_NETWORK.md, section 4): `@maya@b.test` is asked of b.test over
/// a link, and answered to the app with her name, key and home record.
void main() {
  late FakeNet net;
  late TestRelay a, b;
  late Install alice, maya;
  late Map<String, Object> mayas;

  Future<void> make({TestRelay Function()? makeA, TestRelay Function()? makeB}) async {
    net = FakeNet();
    a = makeA?.call() ?? TestRelay(net, 'a.test', seed: 1);
    b = makeB?.call() ?? TestRelay(net, 'b.test', seed: 2);
    alice = Install();
    maya = Install();
    await alice.signIn(a);
    await maya.signIn(b);
    await maya.claim('maya');
    mayas = await maya.giveHome(b);
    alice.said.clear();
  }

  Future<Map> ask(String name, String at, {Install? as}) async {
    final who = as ?? alice;
    who.say({'dir': 'whois', 'name': name, 'at': at});
    await net.settle();
    await net.settle();
    return who.said.last;
  }

  test('a username on another relay: asked over a link, and answered with their name, key and home record', () async {
    await make();
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'id': maya.id, 'key': base64Encode(maya.key), 'home': mayas});
    expect(net.dialled, [b.url, a.url]);
    // What crossed the link: the question, numbered, and its answer.
    expect(net.made[b.url]!.single.other.heard.last, {'fed': 'whois', 'q': 1, 'name': 'maya'});
    expect(net.made[b.url]!.single.heard.last, {'fed': 'whois', 'q': 1, 'id': maya.id, 'key': base64Encode(maya.key), 'home': mayas});
    // Her record is kept by Alice's relay too: a packet to her can be routed with nothing more said.
    expect(a.fed.homes.of(maya.id)!.n, 1);
    await alice.giveHome(a);
    alice.said.clear();
    final n = alice.send(maya.id, [1]);
    await net.settle();
    expect(alice.answerTo(n), {'ack': n, 'here': false, 'fed': true});
    // As typed: with an @, in capitals.
    expect((await ask('@Maya', 'B.Test'))['id'], maya.id);
  });

  test('nobody has that name there, or it is not a username at all', () async {
    await make();
    expect(await ask('nobody', 'b.test'), {'dir': 'whois', 'name': 'nobody', 'at': 'b.test', 'none': true});
    expect(await ask('x', 'b.test'), {'dir': 'whois', 'name': 'x', 'at': 'b.test', 'none': true}, reason: 'too short to be one: not asked');
    expect(net.made[b.url]!.single.other.heard.whereType<Map>().where((m) => m['fed'] == 'whois'), hasLength(1));
  });

  test('someone with no home record there: their name and key, and no record', () async {
    await make();
    final old = Install();
    await old.signIn(b);
    await old.claim('oldapp');
    expect(await ask('oldapp', 'b.test'), {'dir': 'whois', 'name': 'oldapp', 'at': 'b.test', 'id': old.id, 'key': base64Encode(old.key)});
  });

  test('a relay named by itself is an ordinary lookup, under the ordinary limit', () async {
    await make();
    await alice.claim('alice');
    final local = Install();
    await local.signIn(a);
    expect(await ask('alice', 'a.test', as: local), {'dir': 'whois', 'name': 'alice', 'id': alice.id, 'key': base64Encode(alice.key), 'at': 'a.test', 'here': true});
    expect(await ask('nobody', 'a.test', as: local), {'dir': 'whois', 'name': 'nobody', 'none': true, 'at': 'a.test', 'here': true});
    expect(net.dialled, isEmpty);
  });

  test('what is not a host is nobody\'s relay', () async {
    await make();
    for (final at in ['', 'b.test/hub', 'wss://b.test/hub', 'b.test?x=1', 'user@b.test', 'b test', '-b.test', 'x' * 130]) {
      expect(await ask('maya', at), {'dir': 'whois', 'name': 'maya', 'at': at, 'none': true}, reason: at);
    }
    expect(net.dialled, isEmpty);
    expect(Federation.hubAt('Relay.Example.com'), 'wss://relay.example.com/hub');
    expect(Federation.hubAt('relay.example.com:8443'), 'wss://relay.example.com:8443/hub');
    expect(Federation.hubAt('relay.example.com:443'), 'wss://relay.example.com/hub');
  });

  test('why not, where it is not that nobody has the name: this relay doesn\'t talk to that one, that one won\'t, or it can\'t be reached', () async {
    // Off, a relay answers as a relay from before: an ordinary lookup of the name here (an app asks such a relay no
    // such thing: its hello says it doesn't talk to others, and the app asks the other relay itself).
    await make(makeA: () => TestRelay(net, 'a.test', mode: FedMode.off));
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'none': true});
    expect(net.dialled, isEmpty);
    await make(makeA: () => TestRelay(net, 'a.test', block: {'b.test'}));
    expect((await ask('maya', 'b.test'))['why'], 'off');
    await make(makeA: () => TestRelay(net, 'a.test', mode: FedMode.list, allow: {'c.test'}));
    expect((await ask('maya', 'b.test'))['why'], 'off');
    expect(net.dialled, isEmpty);
    await make(makeB: () => TestRelay(net, 'b.test', seed: 2, mode: FedMode.off));
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'refused'});
    expect((await ask('maya', 'b.test'))['why'], 'refused', reason: 'and it is not dialled again for a while');
    expect(net.dialled, [b.url]);
    await make();
    net.down.add(b.url);
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'down'});
    expect(await ask('maya', 'nowhere.test'), {'dir': 'whois', 'name': 'maya', 'at': 'nowhere.test', 'none': true, 'why': 'down'});
    // A port that is not dialled.
    expect((await ask('maya', 'b.test:8443'))['why'], 'off');
  });

  test('a relay that never answers the question: the app is told in good time that it couldn\'t be reached', () async {
    await make();
    final real = HandRelay();
    net.hubs.remove(b.url);
    net.hand[b.url] = (s) {
      s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': real.id, 'key': base64Encode(real.key)}}));
      s.incoming.listen((d) {
        final m = d is String ? jsonDecode(d) as Map : null;
        if (m?['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: unhex(m!['c'] as String), dialler: m['id'] as String, answerer: real.id, dialled: b.url), someBytes(32)))}));
      });
    };
    alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
    await net.settle();
    expect(alice.said, isEmpty);
    await net.pass(Federation.whoisWithin);
    expect(alice.said.single, {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'down'});
    // A relay that never finishes its hello, the same.
    await make();
    net.hubs.remove(b.url);
    net.hand[b.url] = (s) {};
    alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
    await net.settle();
    expect(alice.said, isEmpty);
    await net.pass(Federation.whoisWithin);
    expect(alice.said.single['why'], 'down');
  });

  test('who has a username here is told with where they live, where relays talk: what someone on another relay needs to add them', () async {
    await make();
    final stranger = Install();
    await stranger.signIn(b);
    stranger.say({'dir': 'whois', 'name': 'maya'});
    await pumpEventQueue();
    expect(stranger.said.last, {'dir': 'whois', 'name': 'maya', 'id': maya.id, 'key': base64Encode(maya.key), 'home': mayas});
    // Off, the answer is the one a relay always gave.
    final off = TestRelay(net, 'off.test', seed: 7, mode: FedMode.off);
    final olga = Install(), asker = Install();
    await olga.signIn(off);
    await olga.claim('olga');
    olga.say({'dir': 'home', 'rec': olga.record([off.url])});
    await asker.signIn(off);
    asker.say({'dir': 'whois', 'name': 'olga'});
    await pumpEventQueue();
    expect(asker.said.last, {'dir': 'whois', 'name': 'olga', 'id': olga.id, 'key': base64Encode(olga.key)});
  });

  test('an answer whose key is not a key is not believed, and a why that is not one of the words is not passed on', () async {
    await make();
    final real = HandRelay();
    net.hubs.remove(b.url);
    var answer = <String, Object?>{};
    net.hand[b.url] = (s) {
      s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': real.id, 'key': base64Encode(real.key)}}));
      s.incoming.listen((d) {
        final m = d is String ? jsonDecode(d) as Map : null;
        if (m?['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: unhex(m!['c'] as String), dialler: m['id'] as String, answerer: real.id, dialled: b.url), someBytes(32)))}));
        if (m?['fed'] == 'whois') s.add(jsonEncode({'fed': 'whois', 'q': m!['q'], ...answer}));
      });
    };
    // Five bytes, with the name made from them: no key at all.
    final junk = [1, 2, 3, 4, 5];
    answer = {'id': Hub.nameOf(junk), 'key': base64Encode(junk)};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true});
    // 33 bytes that name no point on the curve.
    final notAPoint = [2, ...List.filled(32, 0xff)];
    answer = {'id': Hub.nameOf(notAPoint), 'key': base64Encode(notAPoint)};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true});
    // A reason of its own making is dropped; one of the words is passed on.
    answer = {'none': true, 'why': 'Ask at evil.example instead'};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true});
    answer = {'none': true, 'why': 'busy'};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'busy'});
  });

  test('an answer whose name is not its key\'s, or whose record is someone else\'s, is not believed', () async {
    await make();
    final real = HandRelay(), other = Install();
    net.hubs.remove(b.url);
    var answer = <String, Object?>{};
    net.hand[b.url] = (s) {
      s.add(jsonEncode({'hello': 'ab' * 32, 'relay': {'id': real.id, 'key': base64Encode(real.key)}}));
      s.incoming.listen((d) {
        final m = d is String ? jsonDecode(d) as Map : null;
        if (m?['fed'] == 1) s.add(jsonEncode({'ok': true, 'fed': 1, 'id': real.id, 'key': base64Encode(real.key), 'sig': base64Encode(P256.sign(real.scalar, Federation.answerBytes(c: unhex(m!['c'] as String), dialler: m['id'] as String, answerer: real.id, dialled: b.url), someBytes(32)))}));
        if (m?['fed'] == 'whois') s.add(jsonEncode({'fed': 'whois', 'q': m!['q'], ...answer}));
      });
    };
    // Maya's name with another key.
    answer = {'id': maya.id, 'key': base64Encode(other.key)};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true});
    // Her name and key, with someone else's record, and with her own record forged.
    answer = {'id': maya.id, 'key': base64Encode(maya.key), 'home': other.record([b.url])};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'id': maya.id, 'key': base64Encode(maya.key)});
    answer = {'id': maya.id, 'key': base64Encode(maya.key), 'home': homeRecord(maya.scalar, ['wss://evil.test/hub'], n: 5, signWith: someBytes(32))};
    expect(await ask('maya', 'b.test'), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'id': maya.id, 'key': base64Encode(maya.key)});
    expect(a.fed.homes.of(maya.id), isNull, reason: 'nothing was kept of either');
    expect(a.fed.homes.of(other.id), isNull);
  });

  test('the existing limit on lookups applies: so many an hour for one install, here and elsewhere together', () async {
    await make();
    await alice.claim('alice');
    final asker = Install();
    await asker.signIn(a);
    // Half here, half there: one count.
    for (var i = 0; i < Handles.lookupsAnHour; i++) {
      asker.say(i.isEven ? {'dir': 'whois', 'name': 'alice'} : {'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
    }
    await net.settle();
    await net.settle();
    expect(asker.said.where((m) => m['dir'] == 'whois' && m['id'] != null), hasLength(Handles.lookupsAnHour));
    asker.said.clear();
    expect(await ask('maya', 'b.test', as: asker), {'dir': 'err', 'about': 'whois', 'at': 'b.test', 'err': 'Too many lookups. Try again in a while.'}, reason: 'said with the host, so an app can tell it from an answer to a name here');
    asker.say({'dir': 'whois', 'name': 'alice'});
    await pumpEventQueue();
    expect(asker.said.last, {'dir': 'err', 'about': 'whois', 'p': null, 'err': 'Too many lookups. Try again in a while.'});
    await net.pass(const Duration(hours: 1, seconds: 1));
    expect((await ask('maya', 'b.test', as: asker))['id'], maya.id);
  });

  test('and one relay may ask after only so many names an hour', () async {
    await make(makeB: () => TestRelay(net, 'b.test', seed: 2, lookupsAnHour: 3));
    final askers = [for (var i = 0; i < 4; i++) Install()];
    for (final x in askers) {
      await x.signIn(a);
    }
    for (var i = 0; i < 3; i++) {
      expect((await ask('maya', 'b.test', as: askers[i]))['id'], maya.id);
    }
    expect(await ask('maya', 'b.test', as: askers[3]), {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'busy'});
    await net.pass(const Duration(minutes: 9));
    expect((await ask('maya', 'b.test', as: askers[3]))['why'], 'busy');
    await net.pass(const Duration(minutes: 52));
    expect((await ask('maya', 'b.test', as: askers[3]))['id'], maya.id);
  });

  test('no more names waiting on one relay than its most', () async {
    await make();
    net.hubs.remove(b.url);
    net.hand[b.url] = (s) {}; // answers nothing: every question waits
    for (var i = 0; i < Federation.asksWaiting + 1; i++) {
      alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
    }
    await pumpEventQueue();
    expect(alice.said.single, {'dir': 'whois', 'name': 'maya', 'at': 'b.test', 'none': true, 'why': 'busy'});
    await net.pass(Federation.helloWithin);
    expect(alice.said.where((m) => m['why'] == 'down'), hasLength(Federation.asksWaiting));
  });

  test('a linked relay asks who has a username here: their name, key and record, or that nobody does; a question with no number is not answered', () async {
    await make();
    final h = HandRelay();
    await h.link(b);
    h.say({'fed': 'whois', 'q': 7, 'name': 'maya'});
    h.say({'fed': 'whois', 'q': 8, 'name': 'nobody'});
    h.say({'fed': 'whois', 'q': 9, 'name': 'not a name'});
    h.say({'fed': 'whois', 'name': 'maya'});
    await pumpEventQueue();
    expect(h.said, [{'fed': 'whois', 'q': 7, 'id': maya.id, 'key': base64Encode(maya.key), 'home': mayas}, {'fed': 'whois', 'q': 8, 'none': true}, {'fed': 'whois', 'q': 9, 'none': true}]);
  });
}
