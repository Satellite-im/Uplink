import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show FsStore, MemoryFsStore;
import 'package:ghost_messaging/net/ledger.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart' show P2pPolicy;
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_relay/hub.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';
import 'support/hub_pair.dart';

/// Checking the relay (docs/OPEN_NETWORK.md, section 3; Matt, 2026-11-22: "p2p as a secondary back up that validates
/// everything our relay says"): the ledger of what went to each friend and came from them (lib/net/ledger.dart), and
/// comparing it over a direct link to find what the relay dropped or kept back. Installs wired as the app wires them
/// (support/direct_world.dart), over a real hub in memory that a test can make drop what it says (support/hub_pair.dart)
/// and a stand-in for the direct network's core, on a clock the tests move by hand.

const _second = Duration(seconds: 1);
const _minute = Duration(minutes: 1);

/// A store whose writes wait while [hold] is set: how many are writing at once, and the most there were.
class _HeldStore implements FsStore {
  final kept = <String, String>{};
  int writing = 0, most = 0;
  Completer<void>? hold;
  @override
  Future<String?> read(String name) async => kept[name];
  @override
  Future<void> write(String name, String value) async {
    writing++;
    if (writing > most) most = writing;
    final h = hold;
    if (h != null) await h.future;
    kept[name] = value;
    writing--;
  }
}

/// [store], whose reads wait while [hold] is set.
class _HeldReads implements FsStore {
  _HeldReads(this.store);
  final MemoryFsStore store;
  Completer<void>? hold;
  @override
  Future<String?> read(String name) async {
    final h = hold;
    if (h != null) await h.future;
    return store.read(name);
  }

  @override
  Future<void> write(String name, String value) => store.write(name, value);
}

String _hex32() => NetCrypto.hex(NetCrypto.randomBytes(16));

/// Makes the relay drop the next packet it passes to [i] on its connection now, once: it tells the sender it passed
/// it on, and it never comes.
void _dropNextPacket(Install i) {
  var done = false;
  i.pair!.dropToApp = (said) {
    if (done || said is! List<int> || said.isEmpty || said[0] != 1) return false;
    done = true;
    return true;
  };
}

/// [from] sends [words] to [to] and the relay drops it on the way while saying it passed it on: the answer is waited
/// for (four seconds by the test's clock) and never comes.
Future<Delivery> _lost(World w, Install from, Install to, String words) async {
  _dropNextPacket(to);
  final sending = from.text(to.account, words);
  await w.clock.pass(const Duration(seconds: 5));
  final d = await sending;
  to.pair!.dropToApp = null;
  return d;
}

/// The texts [i] got, with the route each came by.
List<String> _textsBy(Install i) => [for (final r in i.got) if (r.envelope.kind == 'text') '${r.envelope.body['t']} by ${r.via}'];

/// The `ldg` envelopes [i] got, by the route each came by.
List<String> _ldgBy(Install i) => [for (final r in i.got) if (r.envelope.kind == LedgerCheck.kind) '${r.envelope.body['t']} by ${r.via}'];

RelayRecord? _record(World w, Install i) => i.ledger!.relays[w.memory.url];

void main() {
  group('the ledger', () {
    late FakeClock clock;
    late MemoryFsStore store;
    final friend = _hex32(), other = _hex32(), me = _hex32(), device = _hex32();
    Ledger make({String? on}) => Ledger(store: store, me: me, device: on ?? device, isFriend: (id) => id == friend, now: clock.now, timer: clock.timer);
    Peer peer(String id) => Peer(id: id, key: NetCrypto.randomBytes(32));

    setUp(() {
      clock = FakeClock();
      store = MemoryFsStore();
    });

    test('lists what asks for an answer to and from friends, with the route and what it said; never a test, typing, a card, its own, words, another account or this one\'s own', () async {
      final l = make();
      await l.load();
      final f = peer(friend);
      l.sent(f, Envelope(kind: 'text', body: {'t': 'the words of it'}), via: 'hub', handed: Handed.passed);
      l.sent(f, Envelope(kind: 'voice', body: {'t': 'call', 'i': 'x'}), via: 'p2p', handed: Handed.passed);
      l.sent(f, Envelope(kind: 'text', body: {'t': 'kept'}), via: 'hub', handed: Handed.held);
      // Not listed: a test, typing (asks no answer), a card, the comparing's own, a name the app would never make.
      l.sent(f, Envelope(kind: 'ping'), via: 'hub', handed: Handed.passed);
      l.sent(f, Envelope(kind: 'typing', ack: false), via: 'hub', handed: Handed.passed);
      l.sent(f, Envelope(kind: 'p2p', body: {'t': 'card'}, ack: false), via: 'hub', handed: Handed.passed);
      l.sent(f, Envelope(kind: LedgerCheck.kind, body: {'t': 'sum'}, ack: false), via: 'p2p', handed: Handed.passed);
      l.sent(f, Envelope(id: 'x' * 33, kind: 'text'), via: 'hub', handed: Handed.passed);
      // Nor anyone who is not a friend, nor this account's own other devices.
      l.sent(peer(other), Envelope(kind: 'text'), via: 'hub', handed: Handed.passed);
      l.sent(peer(me), Envelope(kind: 'mine'), via: 'hub', handed: Handed.passed);
      l.came(f, Envelope(kind: 'text', body: {'t': 'from them'}), via: 'p2p');
      l.came(f, Envelope(kind: 'typing', ack: false), via: 'hub');
      l.came(peer(other), Envelope(kind: 'text'), via: 'hub');
      expect([for (final x in l.sentTo(friend)) [x.via, x.kept]], [['hub', false], ['p2p', false], ['hub', true]]);
      expect([for (final x in l.gotFrom(friend)) x.via], ['p2p']);
      expect([l.sentTo(other), l.gotFrom(other), l.sentTo(me)], [isEmpty, isEmpty, isEmpty]);
      // Answered, as the switchboard says.
      l.answered(f, l.sentTo(friend).first.id);
      expect([for (final x in l.sentTo(friend)) x.answered], [true, false, false]);

      // Kept with the choices: the names, times, routes and what was said, and not a word.
      await l.flush();
      final kept = store.kept.values.join();
      for (final words in ['the words of it', 'kept', 'from them']) {
        expect(kept, isNot(contains(words)));
      }
      expect(store.kept.keys.toSet(), {Ledger.indexName, Ledger.bookName(friend)}, reason: 'nothing of the relay yet');
      final again = make();
      await again.load();
      expect([for (final x in again.sentTo(friend)) [x.id, x.via, x.kept, x.answered]], [for (final x in l.sentTo(friend)) [x.id, x.via, x.kept, x.answered]]);
      expect(again.horizon(friend), l.horizon(friend));
    });

    test('the relay\'s word is the one kept: sent again by another route it stays, sent again by the relay its latest takes its place', () async {
      final l = make();
      await l.load();
      final f = peer(friend), e = Envelope(kind: 'text');
      l.sent(f, e, via: 'hub', handed: Handed.held);
      await clock.pass(_minute);
      l.sent(f, e, via: 'p2p', handed: Handed.passed);
      expect([l.sentTo(friend).single.via, l.sentTo(friend).single.kept], ['hub', true]);
      await clock.pass(_minute);
      l.sent(f, e, via: 'hub', handed: Handed.passed);
      expect([l.sentTo(friend).single.via, l.sentTo(friend).single.kept, l.sentTo(friend).single.at], ['hub', false, clock.ms]);
    });

    test('at most five hundred of each for a friend and seven days of them: what is dropped moves where comparing begins', () async {
      final l = make();
      await l.load();
      final f = peer(friend);
      final start = clock.ms;
      for (var i = 0; i < 520; i++) {
        l.sent(f, Envelope(kind: 'text'), via: 'hub', handed: Handed.passed);
        l.came(f, Envelope(kind: 'text'), via: 'hub');
        await clock.pass(_second);
      }
      expect([l.sentTo(friend).length, l.gotFrom(friend).length], [Ledger.most, Ledger.most]);
      // What came before the oldest kept is no longer listed: not compared.
      expect(l.horizon(friend), greaterThan(start + 19 * 1000));
      expect(l.horizon(friend), lessThanOrEqualTo(l.gotFrom(friend).first.at));
      // A week on, all of it is gone with the next thing listed, and comparing begins a week back.
      await clock.pass(const Duration(days: 7, minutes: 1));
      l.came(f, Envelope(kind: 'text'), via: 'hub');
      expect([l.sentTo(friend).length, l.gotFrom(friend).length], [0, 1]);
      expect(l.horizon(friend), greaterThanOrEqualTo(clock.ms - Ledger.keepFor.inMilliseconds));
      // The relay's connections, the comparisons and the wrongs are capped too.
      for (var i = 0; i < Ledger.mostSessions + 20; i++) {
        l.relay('wss://r/hub', clock.ms + i, clock.ms + i + 5);
      }
      for (var i = 0; i < Ledger.mostChecks + 10; i++) {
        l.checked('wss://r/hub', friend, 'd$i', wrong: [LedgerWrong(LedgerWrongKind.passed, clock.ms, friend)]);
      }
      expect([l.sessions.length, l.relays['wss://r/hub']!.checks.length, l.relays['wss://r/hub']!.wrong.length], [Ledger.mostSessions, Ledger.mostChecks, Ledger.mostWrong]);
    });

    // Switching Direct off takes the ledger with the direct route while the app goes on (lib/net/net.dart): what came
    // then is listed nowhere. Compared afterwards as though it had been, whatever a friend's device said it sent
    // meanwhile read as dropped by the relay.
    test('Direct switched off: the ledger says so in what is kept, and the next one compares only what came after it began; what was listed stays', () async {
      final l = make();
      await l.load();
      final f = peer(friend), first = Envelope(kind: 'text');
      l.came(f, first, via: 'hub');
      l.sent(f, Envelope(kind: 'text'), via: 'hub', handed: Handed.passed);
      l.checked('wss://r/hub', friend, 'd1', matched: 1);
      final since = l.horizon(friend)!;
      await clock.pass(_minute);
      await l.pause();
      await l.shutdown();
      expect((jsonDecode(store.kept[Ledger.indexName]!) as Map)['p'], clock.ms);
      // An hour with Direct off: what came then was listed nowhere.
      await clock.pass(const Duration(hours: 1));
      final began = clock.ms;
      final next = make();
      await next.load();
      expect([since < began, next.horizon(friend)], [true, began], reason: 'only what came after it began is compared');
      expect([for (final x in next.gotFrom(friend)) x.id], [first.id], reason: 'what was listed stays');
      expect([next.sentTo(friend).length, next.relays['wss://r/hub']!.matched(clock.ms)], [1, 1]);
      // Written again without the mark, so the one after it compares from where this one began, not from its own start.
      await clock.pass(Ledger.saveAfter);
      expect((jsonDecode(store.kept[Ledger.indexName]!) as Map).containsKey('p'), isFalse);
      await next.shutdown();
      await clock.pass(const Duration(hours: 1));
      final after = make();
      await after.load();
      expect(after.horizon(friend), began);
    });

    test('switched off while what is kept is still being read: the mark waits for the reading, which is done once', () async {
      final l = make();
      await l.load();
      l.came(peer(friend), Envelope(kind: 'text'), via: 'hub');
      l.putMissing(friend, 'x1', 'made');
      await l.shutdown();
      final slow = _HeldReads(store)..hold = Completer<void>();
      final next = Ledger(store: slow, me: me, device: device, isFriend: (id) => id == friend, now: clock.now, timer: clock.timer);
      final loading = next.load(), pausing = next.pause();
      await clock.settle();
      slow.hold!.complete();
      await Future.wait([loading, pausing]);
      expect((jsonDecode(store.kept[Ledger.indexName]!) as Map)['p'], isA<int>());
      expect([next.gotFrom(friend).length, next.missingFrom(friend).length], [1, 1]);
    });

    test('what another device kept (its choices restored here) is not this device\'s: none of it is read, and it is written over', () async {
      final l = make();
      await l.load();
      l.came(peer(friend), Envelope(kind: 'text'), via: 'hub');
      l.relay('wss://r/hub', clock.ms, clock.ms + 60000);
      await l.flush();
      final elsewhere = make(on: _hex32());
      await elsewhere.load();
      expect([elsewhere.gotFrom(friend), elsewhere.sessions, elsewhere.horizon(friend)], [isEmpty, isEmpty, isNull]);
      await elsewhere.flush();
      expect(store.kept[Ledger.bookName(friend)], '');
      expect((jsonDecode(store.kept[Ledger.indexName]!) as Map)['f'], isEmpty);
      // Signing out: nothing is left.
      final again = make();
      await again.load();
      again.came(peer(friend), Envelope(kind: 'text'), via: 'hub');
      await again.flush();
      await again.wipe();
      expect(store.kept.values.where((v) => v.isNotEmpty), isEmpty);
    });
  });

  test('N5: the flush twenty seconds on, the flush as the app is put away and signing out\'s wipe write one after another, never two at once; a wipe while a flush is writing leaves nothing, a book it had not yet listed too', () async {
    final clock = FakeClock();
    final store = _HeldStore();
    final friend = _hex32(), friend2 = _hex32();
    final l = Ledger(store: store, me: _hex32(), device: _hex32(), isFriend: (id) => id == friend || id == friend2, now: clock.now, timer: clock.timer);
    await l.load();
    Peer peer(String id) => Peer(id: id, key: NetCrypto.randomBytes(32));
    l.came(peer(friend), Envelope(kind: 'text'), via: 'hub');
    store.hold = Completer<void>();
    final timed = l.flush();
    await clock.settle();
    expect(store.writing, 1);
    // Put away while the first is writing: the second waits for it.
    l.came(peer(friend), Envelope(kind: 'text'), via: 'hub');
    final away = l.flush();
    await clock.settle();
    expect(store.writing, 1);
    store.hold!.complete();
    store.hold = null;
    await Future.wait([timed, away]);
    expect(store.most, 1);
    expect((jsonDecode(store.kept[Ledger.indexName]!) as Map)['f'], [friend]);
    // A new friend's book being written as the person signs out: it goes too, though the index never listed it.
    l.came(peer(friend2), Envelope(kind: 'text'), via: 'hub');
    store.hold = Completer<void>();
    final last = l.flush();
    await clock.settle();
    final wiped = l.wipe();
    await clock.settle();
    store.hold!.complete();
    store.hold = null;
    await Future.wait([last, wiped]);
    expect(store.most, 1);
    expect({for (final e in store.kept.entries) if (e.value.isNotEmpty) e.key}, isEmpty);
  });

  group('comparing over a direct link', () {
    late World w;
    setUp(() => w = World(ledgers: true));
    tearDown(() => w.stop());

    test('finds a message the relay said it passed and never handed over, asks for it, gets it straight, and puts it down as the relay\'s fault', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(b.account, 'hello')).acked, isTrue);
      await w.clock.pass(const Duration(seconds: 20));
      // The relay says it passed this one on to Sam's computer, connected to it, and it never comes.
      final lost = await _lost(w, a, b, 'lost on the way');
      expect([lost.via, lost.handed, lost.acked], ['hub', Handed.passed, false]);
      // Something else comes on that connection after it: it was alive, so what the relay put on it before had come.
      await w.clock.pass(const Duration(seconds: 15));
      expect((await a.text(b.account, 'after it')).acked, isTrue);
      expect(_textsBy(b), ['hello by hub', 'after it by hub']);
      await w.clock.pass(const Duration(minutes: 3));
      // A direct link: the two compare on it, Sam's asks for what never came, and Maya's sends it straight.
      expect((await a.text(b.account, 'straight', only: {'p2p'})).acked, isTrue);
      await w.until(() => b.texts.contains('lost on the way'), 'the lost one came straight');
      await w.settle();
      expect(_textsBy(b), ['hello by hub', 'after it by hub', 'straight by p2p', 'lost on the way by p2p']);
      expect(_ldgBy(b), ['sum by p2p'], reason: 'only by the direct route');
      expect(_ldgBy(a), ['sum by p2p', 'dif by p2p']);
      // Put down as the relay's: it said it passed it on while Sam's computer was connected.
      final r = _record(w, b)!;
      expect([for (final x in r.wrong) [x.kind, x.friend]], [[LedgerWrongKind.passed, a.account.id]]);
      // It came straight: counted as that, now that it did (the review, D7).
      expect([r.matched(w.clock.ms), r.madeUp(w.clock.ms), r.devices], [2, 1, 1]);
      expect(b.ledger!.missingFrom(a.account.id).single.kind, 'passed');
      // Sent again, it was answered: nothing waits for it at Maya's.
      final entry = a.ledger!.sentTo(b.account.id).firstWhere((x) => x.id == lost.id);
      expect([entry.answered, entry.via, a.outbox.containsKey(lost.id)], [true, 'hub', false]);
      // Maya's found nothing wrong with what came to her.
      expect(_record(w, a)!.wrong, isEmpty);
      // Compared again a quarter of an hour on, while the link stays open: nothing is put down twice.
      for (var i = 0; i < 16; i++) {
        await w.clock.pass(_minute);
        await b.text(a.account, 'still here $i', only: {'p2p'});
      }
      await w.settle();
      expect(_ldgBy(b), ['sum by p2p', 'sum by p2p']);
      expect(_record(w, b)!.wrong, hasLength(1));
    });

    // Direct switched off on Sam's computer while the app went on, and on again after it started anew: the app takes the
    // ledger with the direct route (lib/net/net.dart). Maya's sum names what she sent meanwhile, which came by the relay
    // while no ledger listened: it was asked for again, sent straight, put down against the relay as passed on and
    // never come, and Sam had it twice.
    test('what came while Direct was switched off, listed nowhere, is never taken for something the relay dropped', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(b.account, 'hello')).acked, isTrue);
      await w.clock.pass(_minute);
      // Switched off at Sam's: his ledger goes with the direct route, as the app takes them down.
      await b.check!.stop();
      b.board.log = null;
      await b.ledger!.pause();
      await b.ledger!.shutdown();
      b
        ..ledger = null
        ..check = null;
      expect((await a.text(b.account, 'while it was off')).acked, isTrue);
      await w.clock.pass(_minute);
      // The app starts anew, Direct switched on again.
      await b.restart();
      await w.clock.pass(const Duration(minutes: 3));
      final sending = a.text(b.account, 'straight', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).acked, isTrue);
      await w.until(() => (_record(w, b)?.checks.length ?? 0) > 0, 'Sam\'s computer compared');
      await w.settle();
      expect([b.ledger!.missingFrom(a.account.id), _record(w, b)!.wrong], [isEmpty, isEmpty]);
      expect(_ldgBy(a), ['sum by p2p'], reason: 'nothing was asked for again');
      expect(b.texts, ['hello', 'while it was off', 'straight'], reason: 'nothing came twice');
    });

    test('one the relay kept and lost when it started again: put down as that, which is no fault of the relay\'s, once it came straight (D2)', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(b.account, 'hello')).acked, isTrue);
      await b.stop();
      final kept = await a.text(b.account, 'kept for sam');
      expect([kept.via, kept.handed], ['hub', Handed.held]);
      await w.clock.pass(const Duration(minutes: 1));
      // The relay starts again, and what it kept goes with it. It says when it started at each sign-in.
      final old = w.memory;
      w.memory = MemoryHub(Hub(now: w.clock.now));
      for (final p in old.pairs) {
        p.cut();
      }
      await w.settle();
      a.hub.nudge();
      await w.settle();
      await w.clock.pass(const Duration(seconds: 15));
      await b.start();
      expect(b.hub.relayStartedAt, greaterThan(w.clock.ms - const Duration(seconds: 20).inMilliseconds), reason: 'it said it started just now');
      await w.clock.pass(const Duration(seconds: 3));
      expect((await a.text(b.account, 'later')).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      final sending = a.text(b.account, 'straight', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).acked, isTrue);
      await w.until(() => b.texts.contains('kept for sam'), 'the kept one came straight');
      await w.settle();
      expect(_textsBy(b), ['hello by hub', 'later by hub', 'straight by p2p', 'kept for sam by p2p']);
      final r = _record(w, b)!;
      expect([r.wrong, r.madeUp(w.clock.ms), r.restarts(w.clock.ms)], [isEmpty, 1, 1]);
      expect(b.ledger!.missingFrom(a.account.id).single.kind, 'restart');
    });

    test('PROBE 9, fixed: kept, and another of the account\'s devices signed in first and was handed it: nothing is put down against the relay (D3)', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true), b1 = w.install(sam, computer: true), b2 = w.install(sam, computer: true, ledger: false);
      // Sam's second device has Direct switched off (as a build without the core, or a browser, has no direct route).
      b2.startOff = true;
      w.friends(a, b1);
      w.friends(a, b2);
      await a.start();
      await b1.start();
      expect((await a.text(sam, 'hello')).acked, isTrue);
      await b1.stop();
      final kept = await a.text(sam, 'kept for sam');
      expect([kept.via, kept.handed], ['hub', Handed.held]);
      // His other device signs in first: the relay hands it what it kept.
      await b2.start();
      await w.settle();
      expect(b2.texts, contains('kept for sam'));
      await b2.stop();
      await w.clock.pass(const Duration(seconds: 15));
      await b1.start();
      await w.clock.pass(const Duration(seconds: 3));
      expect((await a.text(sam, 'later')).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      final sending = a.text(sam, 'straight', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      await sending;
      await w.until(() => (_record(w, b1)?.checks.length ?? 0) > 0, 'Sam\'s first device compared');
      await w.settle();
      final r = _record(w, b1)!;
      expect(r.wrong, isEmpty, reason: 'an honest relay not blamed');
      expect(b1.ledger!.missingFrom(a.account.id).single.kind, 'made');
    });

    test('one made up for: another device of the account took it while this one was away, and nothing is put down against the relay', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true), b1 = w.install(sam, computer: true), b2 = w.install(sam, computer: true);
      w.friends(a, b1);
      w.friends(a, b2);
      for (final i in [a, b1, b2]) {
        await i.start();
      }
      expect((await a.text(sam, 'hello')).acked, isTrue);
      await w.settle();
      // Sam's first computer is closed; the relay passes the next to his second, which answers.
      await b1.stop();
      final d = await a.text(sam, 'while b1 was away');
      expect([d.via, d.handed, d.acked], ['hub', Handed.passed, true]);
      expect(b2.texts, ['hello', 'while b1 was away']);
      await b1.start();
      await w.clock.pass(const Duration(minutes: 3));
      final sending = a.text(sam, 'straight', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).acked, isTrue);
      await w.until(() => (_record(w, b1)?.checks.length ?? 0) > 0, 'Sam\'s first computer compared');
      await w.settle();
      final r = _record(w, b1)!;
      // Nothing came straight (his other device has it): not counted as having come, nor as the relay's (D7).
      expect([r.wrong, r.madeUp(w.clock.ms)], [isEmpty, 0]);
      expect([b1.ledger!.missingFrom(a.account.id).single.kind, b1.ledger!.missingFrom(a.account.id).single.came], ['made', false]);
      // Asked for, it is held by nobody now (it was answered), so nothing is sent again.
      expect(b1.texts, ['hello', 'straight']);
      // His second computer, which had it, finds it matched.
      await w.until(() => (_record(w, b2)?.checks.length ?? 0) > 0, 'Sam\'s second computer compared');
      expect([_record(w, b2)!.wrong, _record(w, b2)!.madeUp(w.clock.ms)], [isEmpty, 0]);
    });

    test('an answer the relay lost: what came there and was never answered here is marked answered, and nothing waits for it', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(b.account, 'hello')).acked, isTrue);
      // Sam's answer to the next is dropped on its way back to Maya.
      final acked = <String>[];
      a.board.acked.listen(acked.add);
      _dropNextPacket(a);
      final sending = a.text(b.account, 'its answer is lost');
      await w.clock.pass(const Duration(seconds: 5));
      final e = await sending;
      a.pair!.dropToApp = null;
      expect([e.acked, b.texts.contains('its answer is lost')], [false, true]);
      final entry = a.ledger!.sentTo(b.account.id).firstWhere((x) => x.id == e.id);
      expect([entry.answered, a.outbox.containsKey(e.id)], [false, true]);
      await w.clock.pass(const Duration(minutes: 3));
      expect((await a.text(b.account, 'straight', only: {'p2p'})).acked, isTrue);
      await w.until(() => acked.contains(e.id), 'taken as answered');
      expect([a.ledger!.sentTo(b.account.id).firstWhere((x) => x.id == e.id).answered, a.outbox.containsKey(e.id)], [true, false]);
      // Nothing came twice: Sam's computer was not sent it again.
      expect(b.texts.where((t) => t == 'its answer is lost'), hasLength(1));
    });

    /// Maya's and Sam's computers, their direct link kept open, the relay telling Sam's nothing of Maya being here from
    /// his next sign-in on; then two sums from Maya's a quarter of an hour apart. [setup] does what the test is about to
    /// Maya's computer first; [fresh]: Maya's hears from the relay just before each sum.
    Future<(Install, Install)> twoSums(World w, {void Function(Install a)? setup, bool fresh = true}) async {
      const open = P2pPolicy(stayUp: true, quiet: Duration(hours: 2));
      final a = w.install(w.account('maya'), policy: open), b = w.install(w.account('sam'), policy: open);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(b.account, 'hello')).acked, isTrue);
      b.dropToApp = (said) => said is String && (said.startsWith('{"here"') || said.contains('"came":"${a.account.id}"'));
      b.pair!.cut();
      await w.settle();
      b.hub.nudge();
      await w.settle();
      expect([b.hub.state.value, b.hub.here.value.contains(a.account.id), a.hub.here.value.contains(b.account.id)], [CarrierState.up, false, true]);
      setup?.call(a);
      await w.settle();
      await w.clock.pass(const Duration(minutes: 2));
      if (fresh) expect((await a.text(b.account, 'through the relay', only: {'hub'})).acked, isTrue);
      expect((await a.text(b.account, 'straight', only: {'p2p'})).acked, isTrue);
      await w.until(() => (_record(w, b)?.checks.length ?? 0) > 0, 'Sam\'s compared once');
      await w.clock.pass(const Duration(minutes: 14, seconds: 30));
      if (fresh) expect((await a.text(b.account, 'through the relay again', only: {'hub'})).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 1));
      await w.until(() => (_record(w, b)?.checks.length ?? 0) > 1, 'Sam\'s compared twice');
      return (a, b);
    }

    test('the relay wrong about who is here: Maya\'s device says, in two sums in a row, that it is connected to the same relay and heard from it just now, and the relay tells Sam\'s she is gone', () async {
      final (a, b) = await twoSums(w);
      expect([for (final x in _record(w, b)!.wrong) [x.kind, x.friend]], [[LedgerWrongKind.gone, a.account.id]]);
      // Maya's computer, told the truth of Sam, puts nothing down.
      expect(_record(w, a)!.wrong, isEmpty);
    });

    test('one sum alone is not enough to say the relay is wrong about who is here (D4)', () async {
      const open = P2pPolicy(stayUp: true, quiet: Duration(hours: 2));
      final a = w.install(w.account('maya'), policy: open), b = w.install(w.account('sam'), policy: open);
      w.friends(a, b);
      await a.start();
      await b.start();
      b.dropToApp = (said) => said is String && (said.startsWith('{"here"') || said.contains('"came":"${a.account.id}"'));
      b.pair!.cut();
      await w.settle();
      b.hub.nudge();
      await w.settle();
      await w.clock.pass(const Duration(minutes: 2));
      expect((await a.text(b.account, 'through the relay', only: {'hub'})).acked, isTrue);
      expect((await a.text(b.account, 'straight', only: {'p2p'})).acked, isTrue);
      await w.until(() => (_record(w, b)?.checks.length ?? 0) > 0, 'Sam\'s compared');
      expect(_record(w, b)!.wrong, isEmpty);
    });

    test('PROBE 5, fixed: a friend who chose Invisible says nothing of being connected, and the relay hiding her is not put down (D1)', () async {
      final (_, b) = await twoSums(w, setup: (a) => a.hub.mode = 'invisible');
      expect(_record(w, b)!.wrong, isEmpty, reason: 'an honest relay not blamed');
    });

    test('a friend\'s device whose connection to the relay has heard nothing for a while is not taken at its word that it is connected (D4)', () async {
      final (_, b) = await twoSums(w, fresh: false);
      expect(_record(w, b)!.wrong, isEmpty);
    });

    test('D5: what a friend\'s device says it sent that never came puts nothing down against the relay until the message comes; then it is put down as that device\'s word', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true, ledger: false), b = w.install(sam, computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(sam, 'hello')).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      expect((await a.text(sam, 'straight', only: {'p2p'})).acked, isTrue);
      await w.settle();
      // A sum from Maya's device that claims three messages the relay passed on while Sam's was connected, none sent.
      final now = w.clock.ms;
      final made = [for (var i = 0; i < 3; i++) NetCrypto.hex(NetCrypto.randomBytes(8))];
      expect((await a.board.send(a.to(sam), Envelope(kind: LedgerCheck.kind, ack: false, body: {
        't': 'sum',
        'w': [now - 600000, now],
        's': [for (final id in made) [id, now - 150000, 'p']],
        'g': <String>[],
        'h': {'u': w.memory.url, 'up': true, 't': now - 600000, 'heard': now},
      }), only: {'p2p'})).via, 'p2p');
      await w.settle();
      expect(b.ledger!.missingFrom(a.account.id).map((m) => m.kind).toSet(), {'passed'});
      expect([_record(w, b)!.wrong, _record(w, b)!.madeUp(w.clock.ms)], [isEmpty, 0], reason: 'their word alone puts nothing down');
      // One of them comes, straight, as Maya's device sends it: so it was sent, and the relay's word is held against it.
      await a.board.send(a.to(sam), Envelope(id: made.first, kind: 'text', body: {'t': 'it was sent'}, at: now - 150000), only: {'p2p'});
      await w.settle();
      final r = _record(w, b)!;
      expect([for (final x in r.wrong) [x.kind, x.friend]], [[LedgerWrongKind.passed, a.account.id]]);
      expect(r.madeUp(w.clock.ms), 1);
    });

    test('nothing is compared over the relay: a sum that comes by it is not weighed, and nothing of the comparing goes by it', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true, ledger: false), b = w.install(sam, computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(sam, 'hello')).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      // Maya's says a sum by the relay, as if it compared, claiming something Sam's never got.
      final now = w.clock.ms;
      final sum = Envelope(kind: LedgerCheck.kind, ack: false, body: {
        't': 'sum',
        'w': [now - 600000, now],
        's': [['0123456789abcdef', now - 200000, 'p']],
        'g': <String>[],
        'h': {'u': w.memory.url, 'up': true, 't': now - 600000},
      });
      expect((await a.board.send(a.to(sam), sum, only: {'hub'})).via, 'hub');
      await w.settle();
      expect(_ldgBy(b), ['sum by hub'], reason: 'it came, by the relay');
      expect([b.ledger!.relays, b.ledger!.missingFrom(a.account.id)], [isEmpty, isEmpty], reason: 'and was not weighed');
      await w.clock.pass(const Duration(minutes: 5));
      expect(_ldgBy(a), isEmpty, reason: 'nothing said back, by any route');
      // With a link, it is said on the link alone.
      expect((await a.text(sam, 'straight', only: {'p2p'})).acked, isTrue);
      await w.settle();
      expect(_ldgBy(a), ['sum by p2p']);
    });

    test('a friend\'s device can make this one do only so much: an oversized sum, a name too long, one sum too soon, a dif too big and too many difs are refused', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true, ledger: false), b = w.install(sam, computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect((await a.text(sam, 'hello')).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      expect((await a.text(sam, 'straight', only: {'p2p'})).acked, isTrue);
      await w.settle();
      final check = b.check!;
      Future<void> say(Map<String, dynamic> body) async {
        expect((await a.board.send(a.to(sam), Envelope(kind: LedgerCheck.kind, body: body, ack: false), only: {'p2p'})).via, 'p2p');
        await w.settle();
      }

      Map<String, dynamic> sum(int n, {String? id}) {
        final now = w.clock.ms;
        return {
          't': 'sum',
          'w': [now - 600000, now],
          's': [for (var i = 0; i < n; i++) [id ?? NetCrypto.hex(NetCrypto.randomBytes(8)), now - 300000, 'o']],
          'g': <String>[],
        };
      }

      await say(sum(Ledger.most + 1));
      await say(sum(3, id: 'x' * (Ledger.longestId + 1)));
      expect([check.refused, _record(w, b)], [2, isNull], reason: 'refused whole, weighed not at all');
      await say(sum(3));
      expect([check.refused, _record(w, b)!.checks.length], [2, 1]);
      await w.clock.pass(_minute);
      await say(sum(3));
      expect([check.refused, _record(w, b)!.checks.length], [3, 1], reason: 'one sum from a device every ten minutes');
      await say({'t': 'dif', 'want': [for (var i = 0; i <= LedgerCheck.mostWant; i++) NetCrypto.hex(NetCrypto.randomBytes(8))]});
      expect(check.refused, 4);
      for (var i = 0; i < LedgerCheck.difsAnHour; i++) {
        await say({'t': 'dif', 'want': ['0123456789abcdef']});
      }
      expect(check.refused, 4);
      await say({'t': 'dif', 'want': ['0123456789abcdef']});
      expect(check.refused, 5, reason: 'six difs an hour from one account');
    });

    test('"Check now" dials the friends the relay says are here, once a minute at most; with no link in use a round runs by itself while the app is in use', () async {
      final maya = w.account('maya');
      final a = w.install(maya), b = w.install(w.account('sam')), c = w.install(w.account('cleo'));
      w.friends(a, b);
      w.friends(a, c);
      for (final i in [a, b, c]) {
        await i.start();
      }
      await c.stop();
      final check = a.check!;
      expect(check.canCheckNow, isTrue);
      final dialling = check.checkNow();
      await w.clock.pass(const Duration(seconds: 6));
      expect(await dialling, 1, reason: 'Sam\'s phone alone: the relay says Cleo\'s is gone');
      await w.until(() => (_record(w, a)?.checks.length ?? 0) > 0, 'compared with Sam');
      expect(_record(w, a)!.checks.single.friend, b.account.id);
      expect(w.mesh.dialsTo(c.p2p.nodeId!), 0);
      expect([check.canCheckNow, await check.checkNow()], [false, 0], reason: 'once a minute at most');
      await w.clock.pass(_minute);
      expect(check.canCheckNow, isTrue);

      // A round by itself every six hours on a phone, while the app is in use and no link is open: Cleo, not compared
      // in a day, is dialled; Sam, compared within the day, is not.
      await c.start();
      await w.clock.pass(const Duration(minutes: 5));
      expect(a.p2p.carrier.linkedToSomeone, isFalse);
      final cleo = w.mesh.dialsTo(c.p2p.nodeId!), sam = w.mesh.dialsTo(b.p2p.nodeId!);
      await w.clock.pass(const Duration(hours: 6));
      expect(w.mesh.dialsTo(c.p2p.nodeId!), greaterThan(cleo));
      expect(w.mesh.dialsTo(b.p2p.nodeId!), sam);
      // Put away, no round runs.
      a.p2p.setAway(true);
      final now = w.mesh.dials.length;
      await w.clock.pass(const Duration(days: 2));
      expect(w.mesh.dials.where((d) => identical(d.from, a.node)).length, w.mesh.dials.sublist(0, now).where((d) => identical(d.from, a.node)).length);
    });
  });
}
