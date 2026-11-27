import 'dart:convert';
import 'dart:typed_data';

import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// An app from before relays talked to each other, against the hub as it is now (lib/federation.dart): it reads no
/// `relay` in the hello and never says `home`, and everything it does is answered exactly as it always was. The same
/// things are done to a hub with no federation at all, to one with it off (as it is unless its keeper says
/// otherwise) and to one with it on, and what each said is compared whole.
void main() {
  /// Everything two installs do that an app from before does, and everything the hub said to each, in order.
  Future<String> script(TestRelay relay) async {
    final a = Install(), b = Install(), c = Install();
    final heard = <Object>[];
    void note(String who, Install i) {
      heard.add([who, 'hello', Map.of(i.hello)..remove('relay')]);
      heard.add([who, 'signed in', i.signedIn]);
    }

    await a.signIn(relay, device: 'phone');
    note('a', a);
    await b.signIn(relay);
    note('b', b);
    // A username, and looking one up; something the directory has no answer for.
    a.say({'dir': 'claim', 'name': 'anna'});
    b.say({'dir': 'whois', 'name': 'anna'});
    b.say({'dir': 'whois', 'name': 'nobody'});
    b.say({'dir': 'no such thing'});
    b.say({'dir': 'name'});
    // Who is here.
    a.say({'watch': [b.id, c.id]});
    // A packet to someone here, to someone away, and to its own name.
    a.send(b.id, [1, 2, 3]);
    a.send(c.id, [4]);
    a.send(a.id, [5]);
    await pumpEventQueue();
    // The one away comes, and is handed what was kept.
    await c.signIn(relay);
    note('c', c);
    // A room.
    a.say({'join': 'ab' * 16, 'token': 'cd' * 32});
    b.say({'join': 'ab' * 16, 'token': 'cd' * 32});
    await pumpEventQueue();
    b.socket.add(Uint8List.fromList([Hub.toRoom, ...unhex('ab' * 16), 9, 9]));
    a.say({'ping': 7});
    a.say({'away': true});
    b.say({'mode': 'busy'});
    await pumpEventQueue();
    // A mailbox filled to its most, and one more.
    final d = Install();
    for (var i = 0; i < Hub.mailboxFrames + 1; i++) {
      a.send(d.id, [i & 0xff]);
    }
    await pumpEventQueue();
    c.leave();
    await pumpEventQueue();
    // A look, not a coming.
    await d.signIn(relay);
    note('d', d);
    String hex(List<int> b) => [for (final v in b) v.toRadixString(16).padLeft(2, '0')].join();
    for (final (who, i) in [('a', a), ('b', b), ('c', c), ('d', d)]) {
      heard.add([who, 'said', i.said, 'frames', i.frames.length, i.frames.take(3).map(hex).toList()]);
    }
    heard.add(['held', relay.hub.holding, relay.hub.connected, relay.hub.rooms]);
    // Each install has a new key every time: written as who they are in the script, so two runs can be compared.
    var text = jsonEncode(heard);
    for (final (who, i) in [('a', a), ('b', b), ('c', c), ('d', d)]) {
      text = text.replaceAll(i.id, '<$who>').replaceAll(base64Encode(i.key), '<$who\'s key>');
    }
    return text.replaceAll(RegExp(r'"hello":"[0-9a-f]{64}"'), '"hello":"<number>"').replaceAll(RegExp(r'"k":"[0-9a-f]{64}"'), '"k":"<name hash>"');
  }

  /// Where two transcripts first differ, with a little of each around it; null where they are the same.
  String? differ(String x, String y) {
    if (x == y) return null;
    var i = 0;
    while (i < x.length && i < y.length && x[i] == y[i]) {
      i++;
    }
    String around(String s) => s.substring(i < 60 ? 0 : i - 60, i + 60 > s.length ? s.length : i + 60);
    return 'at $i: "${around(x)}" against "${around(y)}"';
  }

  test('a hub with federation, off or on, says to an app from before exactly what a hub with none says', () async {
    final runs = <String, String>{};
    for (final (name, make) in [
      ('none', (FakeNet net) => TestRelay(net, 'a.test', fed: false)),
      ('off', (FakeNet net) => TestRelay(net, 'a.test', mode: FedMode.off)),
      ('open', (FakeNet net) => TestRelay(net, 'a.test', mode: FedMode.open)),
      ('list', (FakeNet net) => TestRelay(net, 'a.test', mode: FedMode.list, allow: {'b.test'})),
    ]) {
      final net = FakeNet();
      final relay = make(net);
      runs[name] = await script(relay);
      expect(net.dialled, isEmpty, reason: '$name: nothing an app from before does makes a relay dial');
      expect(relay.fed.waiting, 0);
    }
    for (final name in ['off', 'open', 'list']) {
      expect(differ(runs[name]!, runs['none']!), isNull, reason: 'federation $name');
    }
    // And the script did what it meant to: the answers an app from before has always had.
    final none = jsonDecode(runs['none']!) as List;
    List of(String who, String what) => none.firstWhere((e) => e[0] == who && e[1] == what) as List;
    final a = (of('a', 'said')[2] as List).cast<Map>();
    expect(a.where((m) => m.containsKey('ack')).take(3).toList(), [{'ack': 1, 'here': true}, {'ack': 2, 'here': false}, {'ack': 3, 'here': false}], reason: 'an answer to a packet is ack and here, and nothing more');
    expect(a.where((m) => m['err'] == 'full'), hasLength(1));
    expect(of('b', 'said')[2], anyElement(equals({'dir': 'whois', 'name': 'anna', 'id': '<a>', 'key': '<a\'s key>'})));
    expect(withoutClock(of('c', 'signed in')[2] as Map), {'ok': true, 'held': 1});
    expect(withoutClock(of('d', 'signed in')[2] as Map), {'ok': true, 'held': Hub.mailboxFrames});
    expect(of('b', 'said')[5], ['01${'<a>'}010203'], reason: 'a packet handed over is [1], who sent it, and the packet');
  });

  test('the hello gains this relay\'s name and key where federation is on, and nothing at all where it is off', () async {
    final net = FakeNet();
    final plain = Install(), off = Install(), on = Install();
    await plain.signIn(TestRelay(net, 'a.test', fed: false));
    await off.signIn(TestRelay(net, 'b.test', mode: FedMode.off));
    final c = TestRelay(net, 'c.test', seed: 3);
    await on.signIn(c);
    expect(plain.hello.keys, ['hello', 'peek', 'react']);
    expect(off.hello.keys, ['hello', 'peek', 'react'], reason: 'off, the hello is the one it always was');
    expect(on.hello.keys, ['hello', 'peek', 'react', 'relay']);
    expect(on.hello['relay'], {'id': c.id, 'key': base64Encode(c.fed.key), 'url': c.url, 'fed': true});
    expect(Hub.nameOf(c.fed.key), c.id, reason: 'its name is made from its key as an install\'s is');
  });

  test('with federation off, what federation answers is answered as a relay from before answers it, and nothing is kept or passed on', () async {
    Future<List<Map>> asked(TestRelay relay) async {
      final alice = Install(), bob = Install();
      await alice.signIn(relay);
      final mine = alice.record([relay.url]);
      alice.say({'dir': 'home', 'rec': mine});
      alice.say({'dir': 'home', 'rec': bob.record(['wss://b.test/hub'])});
      alice.say({'dir': 'home?', 'a': alice.id});
      alice.say({'dir': 'whois', 'name': 'maya', 'at': 'b.test'});
      await pumpEventQueue();
      final n = alice.send(bob.id, [1]);
      await relay.net.settle();
      await relay.net.pass(const Duration(minutes: 1));
      expect(alice.answerTo(n), {'ack': n, 'here': false}, reason: 'kept here, as a hub always kept it: nothing says it crossed');
      expect([relay.hub.heldFor(bob.id), relay.net.dialled], [1, isEmpty]);
      return [for (final m in alice.said) if (!m.containsKey('ack')) m];
    }

    final none = await asked(TestRelay(FakeNet(), 'a.test', fed: false));
    final net = FakeNet();
    final off = TestRelay(net, 'a.test', mode: FedMode.off);
    TestRelay(net, 'b.test', seed: 2);
    expect(await asked(off), none);
    expect([off.fed.homes.own, off.fed.homes.others, off.fed.links, off.fed.waiting], [0, 0, 0, 0]);
    expect(none, isNotEmpty);
  });
}
