import 'package:ghost_relay/federation.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// A relay with no address of its own, as one hosted from an app is (lib/federation.dart; docs/OPEN_NETWORK.md,
/// sections 4 and 5): it dials a public relay and stays linked (`via`). Its people's records say
/// `ghost-relay://<its name>?…&via=<that relay>`; they are reached over the standing link, and another relay reaches
/// them by sending the public one a `[6]` naming the hosted one. Never further than that.
///
/// Here: `r` is the hosted relay, `v` the public relay it stays linked to, `d` a third, public relay. Xena is on r,
/// Zed on v, Yuri on d.
void main() {
  late FakeNet net;
  late TestRelay r, v, d;
  late Install xena, zed, yuri;
  late Map<String, Object> xenas, zeds, yuris;

  /// Where someone on r lives, as their record says it.
  String hosted(TestRelay relay, TestRelay via) => 'ghost-relay://${relay.id}?n=abc123&via=${Uri.encodeQueryComponent(via.url)}';

  setUp(() async {
    net = FakeNet();
    // v lets relays with no address stay linked to it (off unless its keeper says so: below).
    v = TestRelay(net, 'v.test', seed: 1, standingOpen: true);
    d = TestRelay(net, 'd.test', seed: 2);
    r = TestRelay(net, 'r.test', seed: 3, public: false, via: v.url);
    xena = Install();
    zed = Install();
    yuri = Install();
    await xena.signIn(r);
    await zed.signIn(v);
    await yuri.signIn(d);
    xenas = xena.record([hosted(r, v)]);
    xena.say({'dir': 'home', 'rec': xenas});
    zeds = await zed.giveHome(v);
    yuris = await yuri.giveHome(d);
    await net.settle();
    for (final i in [xena, zed, yuri]) {
      i.said.clear();
    }
  });

  test('it dials the relay it stays linked to as it starts, says it stays, and claims no address', () async {
    expect(net.dialled, [v.url]);
    final hello = net.made[v.url]!.single.other.heard.single as Map;
    expect(hello.keys, containsAll(['fed', 'id', 'key', 'sig', 'c', 'stay']));
    expect([hello['stay'], hello.containsKey('url'), hello['id']], [true, false, r.id]);
    expect([r.fed.linkedWith(v.id), v.fed.linkedWith(r.id)], [true, true]);
    expect(r.fed.card, {'id': r.id, 'key': isA<String>(), 'via': v.url, 'fed': true}, reason: 'its hub tells its apps which relay it is reached through');
    // It is not let go for being idle, on either side.
    await net.pass(const Duration(hours: 3));
    expect([r.fed.linkedWith(v.id), v.fed.linkedWith(r.id), net.dialled], [true, true, [v.url]]);
  });

  test('lost, the link is dialled again, later each time while the public relay is away', () async {
    net.down.add(v.url);
    net.cut(v.url);
    await net.settle();
    expect(r.fed.linkedWith(v.id), isFalse);
    final after = net.dialled.length;
    await net.pass(const Duration(seconds: 5));
    await net.pass(const Duration(seconds: 10));
    expect(net.dialled.length, after + 2);
    net.down.remove(v.url);
    await net.pass(const Duration(seconds: 20));
    await net.settle();
    expect([r.fed.linkedWith(v.id), v.fed.linkedWith(r.id)], [true, true]);
  });

  test('someone on the public relay reaches someone on the hosted one over the standing link, and is reached back', () async {
    zed.say({'dir': 'home', 'rec': xenas});
    await net.settle();
    final n = zed.send(xena.id, [1]);
    await net.settle();
    expect(xena.frames.single, handed(zed.id, [1]));
    expect(zed.answerTo(n), {'ack': n, 'here': false, 'fed': true});
    xena.say({'dir': 'home', 'rec': zeds});
    await net.settle();
    final m = xena.send(zed.id, [2]);
    await net.settle();
    expect(zed.frames.single, handed(xena.id, [2]));
    expect(xena.answerTo(m), {'ack': m, 'here': false, 'fed': true});
    expect(net.dialled, [v.url], reason: 'nothing but the standing link was ever dialled');
  });

  test('someone on a third relay reaches them through a [6] to the public relay, which passes it over the standing link', () async {
    yuri.say({'dir': 'home', 'rec': xenas});
    await net.settle();
    final n = yuri.send(xena.id, [3]);
    await net.settle();
    await net.settle();
    expect(xena.frames.single, handed(yuri.id, [3]));
    expect(yuri.answerTo(n), {'ack': n, 'here': false, 'fed': true});
    // What d said to v: Yuri's record and Xena's, then a [6] naming r.
    final crossed = net.made[v.url]!.last.other.heard;
    expect(crossed.whereType<Map>().map((m) => m['fed']).toList(), [1, 'home', 'home']);
    final frame = crossed.whereType<List<int>>().single;
    expect(frame.sublist(0, 53), [Federation.toRelayVia, 0, 0, 0, 1, ...unhex(xena.id), ...unhex(yuri.id), ...unhex(r.id)]);
    expect([d.fed.linkedWith(r.id), r.fed.linkedWith(d.id)], [false, false], reason: 'd and r never link: only through v');
  });

  test('and they reach someone on a third relay the same way back: two links, no more', () async {
    xena.say({'dir': 'home', 'rec': yuris});
    await net.settle();
    final n = xena.send(yuri.id, [4]);
    await net.settle();
    await net.settle();
    expect(yuri.frames.single, handed(xena.id, [4]));
    expect(xena.answerTo(n), {'ack': n, 'here': false, 'fed': true});
    expect(net.dialled.toSet(), {v.url, d.url}, reason: 'r dialled v, v dialled d (and d looked at v\'s address)');
    expect([d.fed.linkedWith(r.id), r.fed.linkedWith(d.id)], [false, false]);
  });

  test('with the hosted relay away, what is for its people is kept at the public relay and goes when it links again', () async {
    zed.say({'dir': 'home', 'rec': xenas});
    yuri.say({'dir': 'home', 'rec': xenas});
    await net.settle();
    net.down.add(v.url);
    net.cut(v.url);
    await net.settle();
    expect(v.fed.linkedWith(r.id), isFalse);
    final n = zed.send(xena.id, [1]);
    await pumpEventQueue();
    expect(zed.answerTo(n), {'ack': n, 'here': false, 'fed': true, 'waiting': true}, reason: 'told at once: a relay with no address can only be waited for');
    net.down.remove(v.url);
    final m = yuri.send(xena.id, [2]);
    await pumpEventQueue();
    await pumpEventQueue();
    expect(yuri.answerTo(m), {'ack': m, 'here': false, 'fed': true}, reason: 'a [6] for a relay not linked is kept for it');
    expect(v.fed.waitingForRelay(r.id), 2);
    expect(xena.frames, isEmpty);
    await net.pass(const Duration(seconds: 5));
    await net.settle();
    expect(xena.frames, [handed(zed.id, [1]), handed(yuri.id, [2])]);
    expect([v.fed.waitingForRelay(r.id), v.fed.waiting], [0, 0]);
  });

  test('what is kept for a relay not linked is capped, and past the cap a [6] is refused, not kept', () async {
    net = FakeNet();
    v = TestRelay(net, 'v.test', seed: 1, queuePackets: 2, standingOpen: true);
    final h = HandRelay();
    final c = TestRelay(net, 'c.test', seed: 5, dataDir: folderWithKey(h.scalar));
    expect((await h.link(v, url: c.url))['ok'], isTrue);
    final carol = Install(), ghost = Install();
    final away = 'ee' * 16; // a hosted relay that is not linked to v
    h.say({'fed': 'home', 'rec': carol.record([c.url])});
    h.say({'fed': 'home', 'rec': ghost.record(['ghost-relay://$away?via=${Uri.encodeQueryComponent(v.url)}'])});
    final sent = [for (var i = 0; i < 3; i++) h.send(ghost.id, carol.id, [i], relay: away)];
    await pumpEventQueue();
    expect([for (final n in sent) h.answerTo(n)], [{'ack': 1}, {'ack': 2}, {'nak': 3, 'err': 'full'}]);
    expect(v.fed.waitingForRelay(away), 2);
    expect(net.dialled, [c.url], reason: 'the relay named is never dialled: only c\'s own address, to see its key');
    // And it lasts seven days, no longer.
    await net.pass(const Duration(days: 7));
    expect([v.fed.waitingForRelay(away), v.fed.waiting], [0, 0]);
  });

  test('what other relays have this one keep is a quarter of what may wait: its own people\'s room is theirs', () async {
    net = FakeNet();
    v = TestRelay(net, 'v.test', seed: 1, queuedBytes: 2000, standingOpen: true);
    final h = HandRelay();
    final c = TestRelay(net, 'c.test', seed: 5, dataDir: folderWithKey(h.scalar));
    await h.link(v, url: c.url);
    final carol = Install();
    h.say({'fed': 'home', 'rec': carol.record([c.url])});
    String away(int i) => 'e$i' * 16;
    final ghosts = [for (var i = 0; i < 1; i++) Install()];
    for (var i = 0; i < 1; i++) {
      h.say({'fed': 'home', 'rec': ghosts[i].record(['ghost-relay://${away(i)}?via=${Uri.encodeQueryComponent(v.url)}'])});
    }
    // 484 bytes each as counted: one fits in a quarter of 2000, a second does not.
    final first = h.send(ghosts[0].id, carol.id, List.filled(100, 1), relay: away(0)), second = h.send(ghosts[0].id, carol.id, List.filled(100, 2), relay: away(0));
    await pumpEventQueue();
    expect([h.answerTo(first), h.answerTo(second)], [{'ack': first}, {'nak': second, 'err': 'full'}]);
    // Someone signed in to v still has the rest of the room for a relay that is down.
    final zoe = Install(), dan = Install();
    await zoe.signIn(v);
    await zoe.giveHome(v);
    zoe.say({'dir': 'home', 'rec': dan.record(['wss://down.test/hub'])});
    await pumpEventQueue();
    final mine = [for (var i = 0; i < 3; i++) zoe.send(dan.id, List.filled(100, i))];
    await pumpEventQueue();
    expect([for (final n in mine) zoe.answerTo(n)?['err']], [null, null, null]);
  });

  test('and of the relays it waits on, a quarter at most are ones another relay named', () async {
    net = FakeNet();
    v = TestRelay(net, 'v.test', seed: 1, maxPeers: 8, standingOpen: true);
    final h = HandRelay();
    final c = TestRelay(net, 'c.test', seed: 5, dataDir: folderWithKey(h.scalar));
    await h.link(v, url: c.url);
    final carol = Install();
    h.say({'fed': 'home', 'rec': carol.record([c.url])});
    String away(int i) => 'e$i' * 16;
    final sent = <int>[];
    for (var i = 0; i < 3; i++) {
      final ghost = Install();
      h.say({'fed': 'home', 'rec': ghost.record(['ghost-relay://${away(i)}?via=${Uri.encodeQueryComponent(v.url)}'])});
      sent.add(h.send(ghost.id, carol.id, [i], relay: away(i)));
      // A second for the same relay is no new relay.
      sent.add(h.send(ghost.id, carol.id, [i], relay: away(i)));
    }
    await pumpEventQueue();
    expect([for (final n in sent) h.answerTo(n)?['err']], [null, null, null, null, 'full', 'full'], reason: 'two of eight, and no third');
    expect([for (var i = 0; i < 3; i++) v.fed.waitingForRelay(away(i))], [2, 2, 0]);
  });

  test('a [6] is taken only for someone whose own record says that relay, through this one', () async {
    final h = HandRelay();
    final c = TestRelay(net, 'c.test', seed: 5, dataDir: folderWithKey(h.scalar));
    expect((await h.link(v, url: c.url))['ok'], isTrue);
    final carol = Install();
    h.say({'fed': 'home', 'rec': carol.record([c.url])});
    // No record of Xena's is given: refused for want of it.
    var n = h.send(xena.id, carol.id, [1], relay: r.id);
    await pumpEventQueue();
    expect(h.answerTo(n), {'nak': n, 'err': 'to'});
    // Zed lives on v itself, not on r: a [6] can't be used to push packets at a relay's people through another.
    n = h.send(zed.id, carol.id, [1], relay: r.id);
    await pumpEventQueue();
    expect(h.answerTo(n), {'nak': n, 'err': 'to'});
    // A record that names r through another relay than this one.
    final other = Install();
    h.say({'fed': 'home', 'rec': other.record(['ghost-relay://${r.id}?via=${Uri.encodeQueryComponent('wss://elsewhere.test/hub')}'])});
    n = h.send(other.id, carol.id, [1], relay: r.id);
    await pumpEventQueue();
    expect(h.answerTo(n), {'nak': n, 'err': 'to'});
    // With Xena's record it goes; and the sender must still be one this relay speaks for.
    h.say({'fed': 'home', 'rec': xenas});
    n = h.send(xena.id, carol.id, [7], relay: r.id);
    await pumpEventQueue();
    await pumpEventQueue();
    expect(h.answerTo(n), {'ack': n});
    expect(xena.frames.single, handed(carol.id, [7]));
    n = h.send(xena.id, zed.id, [8], relay: r.id);
    await pumpEventQueue();
    expect(h.answerTo(n), {'nak': n, 'err': 'home'});
    expect(xena.frames, hasLength(1));
  });

  test('the public relay passes on only for the hosted relay\'s own people who name it, and never a third link on', () async {
    // From someone whose record does not name r: refused.
    final h = HandRelay();
    expect((await h.link(v, stay: true))['ok'], isTrue);
    final pat = Install(), far = Install();
    h.say({'fed': 'home', 'rec': zeds});
    var n = h.send(yuri.id, zed.id, [1]);
    await pumpEventQueue();
    expect(h.answerTo(n), {'nak': n, 'err': 'home'});
    // From its own person, to someone on a third relay: passed on to that relay.
    h.say({'fed': 'home', 'rec': pat.record(['ghost-relay://${h.id}?via=${Uri.encodeQueryComponent(v.url)}'])});
    h.say({'fed': 'home', 'rec': yuris});
    n = h.send(yuri.id, pat.id, [2]);
    await net.settle();
    await net.settle();
    expect(h.answerTo(n), {'ack': n});
    expect(yuri.frames.single, handed(pat.id, [2]));
    // To someone on a relay hosted behind another public relay: that would be a third link, and is not made.
    h.say({'fed': 'home', 'rec': far.record(['ghost-relay://${'ab' * 16}?via=${Uri.encodeQueryComponent(d.url)}'])});
    n = h.send(far.id, pat.id, [3]);
    await net.settle();
    expect(h.answerTo(n), {'nak': n, 'err': 'far'});
    // From its own person whose record names another relay as the way out: not passed on by this one.
    final stray = Install();
    h.say({'fed': 'home', 'rec': stray.record(['ghost-relay://${h.id}?via=${Uri.encodeQueryComponent('wss://elsewhere.test/hub')}'])});
    n = h.send(yuri.id, stray.id, [4]);
    await net.settle();
    expect(h.answerTo(n), {'nak': n, 'err': 'moved'}, reason: 'handled as any relay\'s packet for someone who lives elsewhere: told where, and not passed on');
    expect(yuri.frames, hasLength(1));
  });

  test('the hosted relay believes the relay it stays linked to as an app believes its relay, and no other', () async {
    // What v passes it is handed over whoever it is from (the first test above); a stranger relay can't dial r at
    // all (it has no address), and one r dialled that is not its via speaks only for its own.
    expect(net.hubs.keys, isNot(contains(r.url)));
    final carol = Install();
    // Carol has signed in to d (it keeps nothing for a name that never has).
    await carol.signIn(d);
    carol.leave();
    xena.say({'dir': 'home', 'rec': carol.record([d.url])});
    await net.settle();
    // r sends everything not for its own people through v, even to d: it never dials d.
    xena.send(carol.id, [1]);
    await net.settle();
    await net.settle();
    expect(net.dialled.where((u) => u == d.url), hasLength(1), reason: 'v dialled d; r did not');
    expect(r.fed.links, 1);
    expect(d.hub.heldFor(carol.id), 1);
  });
}
