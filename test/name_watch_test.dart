import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/lookup_budget.dart';
import 'package:ghost_messaging/me/me.dart' show Me, MeError;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/name_watch.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart' show P2pPolicy;
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/people.dart' show quietly;
import 'package:ghost_relay/handles.dart' show Handles;

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';

/// The name watch (lib/net/name_watch.dart; docs/OPEN_NETWORK.md, section 3): the relay's "@name is this key" checked by
/// asking it again, each friend's username once a day and this person's own at each sign-in, needing no direct route.
/// After the review (2026-11-23): each relay is its own directory, and another account under a friend's username is
/// said only where that relay named their key under it before; a friend who changed their username is followed; this
/// person's own username is said calmly and once, with what usually causes it; the account's devices share the relay's
/// lookups. The reviewer's probes 1-4 and 8 are here, turned round: each holds the fixed behaviour. After the second
/// review: the devices share the days, not the friends, so every device sees what the relay says of every friend, and a
/// device asks again what it shows (probes 10 and 11, turned round).

const _day = Duration(days: 1);
const _relay = 'wss://memory.test/hub';

/// The relay's directory of usernames, as a test makes it answer: who holds each, which name a key holds (the relay's
/// `name` question), and every question asked of it.
class _Directory {
  _Directory(this.clock);
  final FakeClock clock;
  final names = <String, NetKeys>{};
  final asked = <({String name, int at})>[];
  bool down = false, refuses = false;

  /// Answers held until a test lets them go.
  Completer<void>? hold;

  Future<({String id, String key})?> whois(String name) async {
    asked.add((name: name, at: clock.ms));
    if (refuses) throw MeError('Too many lookups. Try again in a while.');
    if (down) throw StateError('The relay server can\'t be reached right now.');
    final h = hold;
    if (h != null) await h.future;
    final k = names[name];
    return k == null ? null : (id: k.id, key: base64Encode(k.public));
  }

  /// Which username [keys] holds here: the name's hash (Me.nameKeyOf), or null.
  String? heldBy(NetKeys keys) {
    for (final e in names.entries) {
      if (e.value.id == keys.id) return Me.nameKeyOf(e.key);
    }
    return null;
  }
}

/// [i]'s name watch, as the app makes it (lib/people.dart): its username, its friends by username as added, the
/// directory's answers, a friend told by the relay and by an open direct link (Switchboard.sendEveryWay); and the
/// envelopes of its kind that come to [i] heard by it.
NameWatch _watchOf(World w, Install i, String username, Map<String, Account> friends, _Directory dir, {Map<String, String>? kept}) {
  final store = kept ?? <String, String>{};
  final watch = NameWatch(
    me: () => i.account.id,
    username: () => username,
    friends: () => [for (final e in friends.entries) WatchedName(e.key, e.value.id, base64Encode(e.value.keys.public))],
    whois: dir.whois,
    held: () async => dir.heldBy(i.account.keys),
    relay: () => _relay,
    tell: (id, e) async {
      final peer = i.byId(id);
      if (peer != null) await i.board.sendEveryWay(peer, e);
    },
    read: (name) => store[name] ?? '',
    write: (name, value) => store[name] = value,
    now: w.clock.now,
    timer: w.clock.timer,
  );
  i.board.received.listen((r) {
    if (r.envelope.kind == NameWatch.kind) watch.heard(r.peer.id, r.envelope, sealed: r.sealed);
  });
  return watch;
}

/// A watch with no installs under it: its own clock, the directory, and what it keeps.
NameWatch _bare(FakeClock clock, _Directory dir, {required String me, String? Function()? username, List<WatchedName> Function()? friends, Map<String, String>? kept, String Function()? relay, Future<String?> Function()? held, ({int index, int of}) Function()? share, List<(String, Envelope)>? told, List<({String name, int at})>? asked, LookupBudget? lookups}) {
  final store = kept ?? <String, String>{};
  return NameWatch(
    me: () => me,
    username: username ?? () => null,
    friends: friends ?? () => const [],
    whois: (name) {
      asked?.add((name: name, at: clock.ms));
      return dir.whois(name);
    },
    held: held,
    relay: relay ?? () => _relay,
    share: share,
    lookups: lookups,
    tell: (id, e) async => told?.add((id, e)),
    read: (name) => store[name] ?? '',
    write: (name, value) => store[name] = value,
    now: clock.now,
    timer: clock.timer,
  )..start();
}

WatchedName _friend(String username, NetKeys keys) => WatchedName(username, keys.id, base64Encode(keys.public));

/// Friends by username over the directory: what this phone asks of the relay, and what friends send it sealed.
class _Port implements BuddiesPort {
  _Port(this.dir, this.keys);
  final _Directory dir;
  final NetKeys keys;
  String list = '[]';
  final sealed = StreamController<({String from, Envelope envelope})>.broadcast();
  final hellos = StreamController<({String from, Envelope envelope})>.broadcast();
  @override
  Future<({String id, String key})> me() async => (id: keys.id, key: base64Encode(keys.public));
  @override
  String? get username => 'sam';
  @override
  String get displayName => 'Sam';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) => dir.whois(username);
  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => sealed.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => hellos.stream;
}

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.stop());

  test('a friend\'s username the relay now gives to another account, once it named their key: shown on them, the friend told by the relay and by an open direct link and never by a dial, and cleared when nobody holds it', () async {
    final maya = w.account('maya'), sam = w.account('sam'), mallory = w.account('mallory');
    // Computers whose direct links stay open while nothing is said on them for days: a link open when the word goes.
    const open = P2pPolicy(stayUp: true, quiet: Duration(days: 4));
    final a = w.install(maya, policy: open), b = w.install(sam, policy: open);
    w.friends(a, b);
    await a.start();
    await b.start();
    final dir = _Directory(w.clock)
      ..names['maya'] = maya.keys
      ..names['sam'] = sam.keys;
    final wa = _watchOf(w, a, 'maya', {'sam': sam}, dir), wb = _watchOf(w, b, 'sam', {'maya': maya}, dir);
    wa.start();
    wb.start();
    // Within the day each is asked, and the relay names the keys that were added: confirmed there.
    await w.clock.pass(_day);
    expect(dir.asked.map((x) => x.name).toSet(), {'sam', 'maya'});
    expect([wa.changeFor(sam.id), wb.toldMe], [isNull, isEmpty]);

    // The relay now gives @sam to another account, and drops what reaches Sam's computer through it. No direct link is
    // open: the word goes by the relay alone, and nothing is dialled for it (D8).
    dir.names['sam'] = mallory.keys;
    b.pair!.dropToApp = (said) => said is List<int> && said.isNotEmpty && said[0] == 1;
    final dials = w.mesh.dials.length;
    await w.clock.pass(_day);
    final change = wa.changeFor(sam.id)!;
    expect([change.username, change.other, change.kind], ['sam', mallory.id, NameKind.friend]);
    expect(w.mesh.dials.length, dials, reason: 'nothing dialled for the name watch');
    expect(wb.toldMe, isEmpty, reason: 'the relay dropped it, and no link was open');
    // With a link open, the next day's word goes by it too, and reaches him.
    b.pair!.dropToApp = null;
    expect((await a.text(sam, 'a link', only: {'p2p'})).acked, isTrue);
    b.pair!.dropToApp = (said) => said is List<int> && said.isNotEmpty && said[0] == 1;
    await w.clock.pass(_day);
    expect(a.p2p.carrier.linked(a.to(sam)), isTrue);
    expect([wb.toldMe.single.by, wb.toldMe.single.other, wb.toldMe.single.kind], [maya.id, mallory.id, NameKind.told]);
    expect([for (final r in b.got) if (r.envelope.kind == NameWatch.kind) '${r.via} ${r.sealed}'], ['p2p true']);
    expect(wb.notice.value?.by, maya.id, reason: 'said at once, the first time');
    b.pair!.dropToApp = null;
    // Nothing changes who Sam is to Maya.
    expect((await a.text(sam, 'still you')).acked, isTrue);
    // Nobody holds @sam now: the word on him goes (M2).
    dir.names.remove('sam');
    await w.clock.pass(_day);
    expect(wa.changeFor(sam.id), isNull);
    wa.dispose();
    wb.dispose();
  });

  test('PROBE 1, fixed: a friend who changed their username is followed once the relay names their key for the new one, and a stranger taking the old one says nothing; unfollowed, what is said goes when nobody holds the name', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate(), stranger = NetKeys.generate();
    dir.names['maya'] = maya;
    final told = <(String, Envelope)>[];
    final friends = [_friend('maya', maya)];
    final w1 = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => friends, told: told);
    await clock.pass(_day);
    expect(w1.changeFor(maya.id), isNull);
    // Maya changes to @maya.k (the relay lets @maya go) and says so in her sealed profile.
    dir.names
      ..remove('maya')
      ..['maya.k'] = maya;
    w1.saidName(maya.id, 'Maya.K');
    await clock.pass(const Duration(minutes: 2));
    expect(dir.asked.last.name, 'maya.k', reason: 'looked up before it is taken');
    final before = dir.asked.where((x) => x.name == 'maya').length;
    // A stranger takes @maya: nothing is said, and @maya is asked about no more.
    dir.names['maya'] = stranger;
    await clock.pass(const Duration(days: 3));
    expect([w1.changeFor(maya.id), told], [isNull, isEmpty]);
    expect(dir.asked.where((x) => x.name == 'maya').length, before);
    expect(dir.asked.where((x) => x.name == 'maya.k').length, greaterThanOrEqualTo(3));
    // A name a friend says that the relay gives to someone else is not taken.
    final followed = dir.asked.where((x) => x.name == 'maya.k').length;
    w1.saidName(maya.id, 'maya');
    await clock.pass(const Duration(hours: 2));
    expect(dir.asked.last.name, 'maya');
    await clock.pass(_day);
    expect(dir.asked.where((x) => x.name == 'maya.k').length, greaterThan(followed), reason: 'still asked about @maya.k');
    w1.dispose();

    // Not followed (she said nothing): the stranger's @maya is said, and goes once nobody holds it.
    dir.names['maya'] = maya;
    final w2 = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => friends, kept: {});
    await clock.pass(_day);
    dir.names['maya'] = stranger;
    await clock.pass(_day);
    expect(w2.changeFor(maya.id)?.other, stranger.id);
    dir.names.remove('maya');
    await clock.pass(_day);
    expect(w2.changeFor(maya.id), isNull, reason: 'nobody holds it: nothing is said');
    w2.dispose();
  });

  test('PROBE 3, fixed: another relay is another directory: nobody\'s username is said to be someone else\'s there until that relay has named their key under it, and its own is not asked where it was never held', () async {
    final clock = FakeClock();
    final home = _Directory(clock), other = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate(), someone = NetKeys.generate(), someone2 = NetKeys.generate();
    home.names['maya'] = maya;
    home.names['sam'] = me;
    other.names['maya'] = someone;
    other.names['sam'] = someone2;
    var dir = home, relay = 'wss://gogho.st/hub';
    final w1 = NameWatch(
      me: () => me.id,
      username: () => 'sam',
      friends: () => [_friend('maya', maya)],
      whois: (n) => dir.whois(n),
      held: () async => dir.heldBy(me),
      relay: () => relay,
      tell: (_, _) async {},
      read: (_) => '',
      write: (_, _) {},
      now: clock.now,
      timer: clock.timer,
    )..start();
    await w1.signedIn();
    await clock.pass(_day);
    expect([w1.changeFor(maya.id), w1.own], [isNull, isNull]);
    // A relay of one's own, chosen in Settings › Routes.
    dir = other;
    relay = 'wss://relay.example/hub';
    await clock.pass(const Duration(minutes: 11));
    await w1.signedIn();
    await clock.pass(_day);
    expect([w1.changeFor(maya.id), w1.own], [isNull, isNull]);
    expect(other.asked.where((x) => x.name == 'sam'), isEmpty, reason: 'never held there: not asked');
    expect(other.asked.where((x) => x.name == 'maya'), isNotEmpty, reason: 'asked, and nothing said');
    // Back on the relay it was found on, it is still watched there.
    dir = home;
    relay = 'wss://gogho.st/hub';
    home.names['maya'] = someone;
    await clock.pass(const Duration(days: 2));
    expect(w1.changeFor(maya.id)?.other, someone.id);
    w1.dispose();
  });

  test('PROBE 4, fixed: someone kept under a username they only claimed (the relay never named their key for it) is told nothing, and nothing is said of them', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), alice = NetKeys.generate(), mallory = NetKeys.generate();
    dir.names['alice'] = alice;
    final told = <(String, Envelope)>[];
    final w1 = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => [_friend('alice', mallory)], told: told);
    await clock.pass(const Duration(days: 2));
    expect([w1.changeFor(mallory.id), told], [isNull, isEmpty], reason: 'the real holder\'s id is told to no one');
    w1.dispose();
  });

  test('an add that found them under the name is what the relay is held to: the first daily answer naming another account is said', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate(), mallory = NetKeys.generate();
    final w1 = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => [_friend('maya', maya)]);
    // Buddies.add looked her up and the relay named her key: the watch is told (no lookup of its own).
    w1.confirmed(maya.id, 'maya');
    final added = clock.ms;
    dir.names['maya'] = mallory;
    await clock.pass(const Duration(hours: 25));
    expect(w1.changeFor(maya.id)?.other, mallory.id);
    expect(dir.asked.where((x) => x.name == 'maya'), hasLength(1), reason: 'first asked a day after the add');
    expect(dir.asked.single.at - added, greaterThanOrEqualTo(_day.inMilliseconds), reason: 'not sooner, whatever the turn');
    w1.dispose();
  });

  test('friends by username tell the watch: an add that found them is what the relay is held to, and a new username they say in their sealed profile is looked up', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate(), mallory = NetKeys.generate();
    dir.names['maya'] = maya;
    final port = _Port(dir, me);
    final buddies = Buddies(port);
    await buddies.start();
    final watch = NameWatch.instance = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => [for (final b in buddies.friends) WatchedName(b.username, b.id, b.key)]);
    addTearDown(() => NameWatch.instance = null);
    // As the app has it (lib/people.dart): the friends changing, the watch plans again.
    buddies.addListener(watch.friendsChanged);
    await buddies.add('maya');
    // She says yes: a friend now, under the name the add found her by.
    port.sealed.add((from: maya.id, envelope: Envelope(kind: 'buddy', body: {'s': 'yes', 'u': 'maya', 'n': 'Maya'})));
    await clock.settle();
    expect(buddies.friends.single.username, 'maya');
    final asked = dir.asked.length;
    dir.names['maya'] = mallory;
    await clock.pass(const Duration(hours: 25));
    expect(watch.changeFor(maya.id)?.other, mallory.id, reason: 'held to what the add found');
    expect(dir.asked.length - asked, 1);
    // She says, sealed, that she goes by @maya.k now: looked up.
    dir.names['maya.k'] = maya;
    port.sealed.add((from: maya.id, envelope: Envelope(kind: 'buddy', body: {'s': 'me', 'u': 'maya.k', 'n': 'Maya'})));
    await clock.pass(const Duration(minutes: 2));
    expect(dir.asked.last.name, 'maya.k');
    expect(watch.changeFor(maya.id), isNull, reason: 'followed: the old name is nothing to say now');
    watch.dispose();
    buddies.dispose();
  });

  test('PROBE 4 at its root: a friend request is said yes to only where the relay says its username is its sender\'s; one that isn\'t never is, and stays until declined; one that can\'t be checked waits; and one that is gives the watch what to hold the relay to', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), alice = NetKeys.generate(), mallory = NetKeys.generate();
    dir.names['alice'] = alice;
    final port = _Port(dir, me);
    final buddies = Buddies(port);
    await buddies.start();
    final watch = NameWatch.instance = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => [for (final b in buddies.friends) WatchedName(b.username, b.id, b.key)]);
    addTearDown(() => NameWatch.instance = null);
    buddies.addListener(watch.friendsChanged);
    Envelope ask(String u, NetKeys k) => Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': u, 'k': base64Encode(k.public), 'n': u});
    // Mallory asks, calling herself @alice: the directory gives @alice to someone else, so it isn't kept.
    port.hellos.add((from: mallory.id, envelope: ask('alice', mallory)));
    await clock.settle();
    expect(buddies.requests, isEmpty);
    // She asks again within the hour (not looked up again of the phone's own accord): kept, not checked. Accept asks,
    // and it is someone else's: not said yes to, and it stays, saying so, until declined.
    port.hellos.add((from: mallory.id, envelope: ask('alice', mallory)));
    await clock.settle();
    expect(buddies.requests.single.checked, isFalse);
    await expectLater(buddies.accept(buddies.requests.single), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('someone else'))));
    expect(buddies.friends, isEmpty);
    expect(buddies.requests.single.check, 'other');
    await buddies.decline(buddies.requests.single);
    // Alice asks while the relay can't be asked: it waits, and Accept says why.
    dir.down = true;
    port.hellos.add((from: alice.id, envelope: ask('alice', alice)));
    await clock.settle();
    await expectLater(buddies.accept(buddies.requests.single), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('can\'t be checked'))));
    expect(buddies.requests, hasLength(1));
    // It can now: a friend, and the watch holds the relay to @alice being hers.
    dir.down = false;
    await buddies.accept(buddies.requests.single);
    expect(buddies.friends.single.id, alice.id);
    dir.names['alice'] = mallory;
    await clock.pass(const Duration(hours: 25));
    expect(watch.changeFor(alice.id)?.other, mallory.id);
    watch.dispose();
    buddies.dispose();
  });

  test('PROBE 12, fixed: a real friend\'s request whose username nobody holds now (she changed it since asking) is not said to be someone else\'s, nor removed: it waits, saying the relay doesn\'t know the name', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate();
    final port = _Port(dir, me)..list = jsonEncode([Buddy(username: 'maya', id: maya.id, key: base64Encode(maya.public), state: 'invited', at: clock.ms).toJson()]);
    final buddies = Buddies(port);
    await buddies.start();
    dir.names['maya.k'] = maya;
    await expectLater(buddies.accept(buddies.all.single), throwsA(isA<MeError>().having((e) => e.message, 'message', allOf(contains('doesn\'t know'), isNot(contains('someone else'))))));
    expect(buddies.requests.map((r) => (r.username, r.check)).toList(), [('maya', 'nobody')]);
    buddies.dispose();
  });

  test('PROBE 13, fixed: adding her by her new username while her request under the old one waits makes her a friend under the new one, the request being hers by the key the relay names', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate();
    final port = _Port(dir, me)..list = jsonEncode([Buddy(username: 'maya', id: maya.id, key: base64Encode(maya.public), state: 'invited', at: clock.ms).toJson()]);
    final buddies = Buddies(port);
    await buddies.start();
    dir.names['maya.k'] = maya;
    final watch = NameWatch.instance = _bare(clock, dir, me: me.id, username: () => 'sam', friends: () => [for (final b in buddies.friends) WatchedName(b.username, b.id, b.key)]);
    addTearDown(() => NameWatch.instance = null);
    buddies.addListener(watch.friendsChanged);
    final added = await buddies.add('maya.k');
    expect([added.username, added.state], ['maya.k', 'yes']);
    expect(buddies.friends.map((b) => (b.username, b.id)).toList(), [('maya.k', maya.id)]);
    expect(buddies.requests, isEmpty);
    // And the watch holds the relay to @maya.k being hers.
    dir.names['maya.k'] = NetKeys.generate();
    await clock.pass(const Duration(hours: 25));
    expect(watch.changeFor(maya.id)?.username, 'maya.k');
    watch.dispose();
    buddies.dispose();
  });

  test('Accept, where the relay refuses the lookup as one too many in the hour: says so, and by when one frees up, never to connect; the request waits, and nothing more is looked up of the app\'s own accord for the hour', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), maya = NetKeys.generate(), theo = NetKeys.generate();
    final budget = LookupBudget(now: clock.now);
    final port = _Port(dir, me)
      ..list = jsonEncode([
        for (final (u, k) in [('maya', maya), ('theo', theo)]) Buddy(username: u, id: k.id, key: base64Encode(k.public), state: 'invited', at: clock.ms).toJson(),
      ]);
    final buddies = Buddies(port, lookups: budget);
    await buddies.start();
    dir.names['maya'] = maya;
    dir.names['theo'] = theo;
    dir.refuses = true;
    Object? said;
    try {
      await buddies.accept(buddies.all.first);
    } catch (e) {
      said = e;
    }
    expect(said, isA<MeError>());
    expect('$said', allOf(contains('only so many lookups an hour'), contains('within the hour'), isNot(contains('connected'))));
    expect(buddies.requests, hasLength(2));
    // Nothing of the app's own accord until the hour is up: the requests' checks, and the name watch, which shares it.
    final at = dir.asked.length;
    expect(await buddies.checkRequests(), 0);
    final cleo = NetKeys.generate();
    final watch = _bare(clock, dir, me: me.id, friends: () => [_friend('cleo', cleo)], kept: {NameWatch.keptName: jsonEncode({'me': me.id, 'r': {_relay: {'c': {cleo.id: clock.ms - const Duration(days: 10).inMilliseconds}}}})}, lookups: budget);
    await clock.pass(const Duration(minutes: 59));
    expect(dir.asked.length, at);
    watch.dispose();
    buddies.dispose();
    // By when one frees up: an hour after the first lookup the relay was still counting, where this device made one.
    final b2 = LookupBudget(now: clock.now)..took();
    await clock.pass(const Duration(minutes: 20));
    b2.refused();
    expect(b2.freesBy, clock.ms + const Duration(minutes: 40).inMilliseconds);
    expect(Buddies.busyWords('maya', b2.freesBy, now: clock.now()), contains('within 40 minutes'));
  });

  test('one budget for what the account looks up of the app\'s own accord: the name watch\'s lookups and the friend requests\' checks together, shared out among the account\'s devices; the requests leave the watch a third, and the relay saying too many to either stops both', () async {
    expect(LookupBudget.mostAnHour, lessThanOrEqualTo(Handles.lookupsAnHour ~/ 4), reason: 'most of the relay\'s lookups are left to the person');
    expect([LookupBudget().perDevice, LookupBudget().forRequests], [30, 20]);
    final clock = FakeClock();
    final dir = _Directory(clock);
    // One of three devices: ten an hour, of which the requests' checks may take seven.
    final budget = LookupBudget(share: () => (index: 1, of: 3), now: clock.now);
    expect([budget.perDevice, budget.forRequests], [10, 7]);
    final me = NetKeys.generate();
    final port = _Port(dir, me);
    final buddies = Buddies(port, lookups: budget);
    await buddies.start();
    // Strangers' requests, each looked up as it comes: seven, and no more this hour.
    for (var i = 0; i < 12; i++) {
      final s = NetKeys.generate();
      dir.names['stranger$i'] = s;
      port.hellos.add((from: s.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'stranger$i', 'k': base64Encode(s.public)})));
    }
    await clock.settle();
    expect(dir.asked, hasLength(7));
    expect(buddies.requests, hasLength(12));
    // The watch has its third left: three of its friends, all due, are asked this hour, and no more.
    final friends = [for (var i = 0; i < 6; i++) _friend('friend$i', NetKeys.generate())];
    final long = clock.ms - const Duration(days: 10).inMilliseconds;
    final watch = _bare(clock, dir, me: me.id, friends: () => friends, share: () => (index: 1, of: 3), lookups: budget, kept: {
      NameWatch.keptName: jsonEncode({
        'me': me.id,
        'r': {
          _relay: {'c': {for (final f in friends) f.id: long}},
        },
      }),
    });
    await clock.pass(const Duration(minutes: 30));
    expect(dir.asked.where((x) => x.name.startsWith('friend')), hasLength(3));
    expect(await buddies.checkRequests(), 0);
    expect(dir.asked, hasLength(10), reason: 'ten this hour, all told');
    // An hour on: the relay says too many to a request's check, and the watch asks nothing for the hour after.
    await clock.pass(const Duration(minutes: 31));
    dir.refuses = true;
    final before = dir.asked.length;
    await buddies.checkRequests();
    expect(dir.asked.length, greaterThan(before));
    final refused = dir.asked.length;
    await clock.pass(const Duration(minutes: 59));
    expect(dir.asked.length, refused, reason: 'neither the watch nor the requests asked');
    // And the other way: the watch told too many, the requests' checks wait.
    dir.refuses = false;
    await clock.pass(const Duration(minutes: 2));
    final budget2 = LookupBudget(now: clock.now);
    final port2 = _Port(dir, me);
    final buddies2 = Buddies(port2, lookups: budget2);
    await buddies2.start();
    final w2 = _bare(clock, dir, me: me.id, friends: () => friends, lookups: budget2, kept: {
      NameWatch.keptName: jsonEncode({
        'me': me.id,
        'r': {
          _relay: {'c': {for (final f in friends) f.id: long}},
        },
      }),
    });
    dir.refuses = true;
    await clock.pass(const Duration(minutes: 1));
    expect(budget2.refusedUntil, isNotNull);
    dir.refuses = false;
    final s = NetKeys.generate();
    dir.names['late'] = s;
    final n = dir.asked.length;
    port2.hellos.add((from: s.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'late', 'k': base64Encode(s.public)})));
    await clock.settle();
    expect(dir.asked.length, n, reason: 'not looked up of the phone\'s own accord');
    expect(buddies2.requests.single.checked, isFalse);
    w2.dispose();
    buddies2.dispose();
    watch.dispose();
    buddies.dispose();
  });

  test('PROBE 2, fixed: its own username given up or changed on another device and taken since: said calmly and once, not at every sign-in; gone when this device\'s username changes or is given up, or nobody holds it', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), stranger = NetKeys.generate();
    String? username = 'matt';
    var holds = Me.nameKeyOf('matt');
    final w1 = _bare(clock, dir, me: me.id, username: () => username, held: () async => holds.isEmpty ? null : holds);
    NameWatch.instance = w1;
    addTearDown(() => NameWatch.instance = null);
    var notices = 0;
    final sub = NameWatch.notices.listen((_) => notices++);
    dir.names['matt'] = me;
    await w1.signedIn();
    expect([w1.own, notices], [isNull, 0], reason: 'held here, and by this key');
    // Given up on the Mac, and taken since; this phone still says @matt. The relay says this key holds no name.
    dir.names['matt'] = stranger;
    holds = '';
    for (var i = 0; i < 6; i++) {
      await clock.pass(const Duration(minutes: 11));
      await w1.signedIn();
    }
    await clock.settle();
    expect([w1.own?.kind, w1.own?.other, notices], [NameKind.none, stranger.id, 1], reason: 'said once, not six times');
    // Changed on another device to another name this key now holds.
    holds = Me.nameKeyOf('matt.k');
    await clock.pass(const Duration(minutes: 11));
    await w1.signedIn();
    expect(w1.own?.kind, NameKind.changed);
    // Given up here too: what was said of it goes.
    username = null;
    w1.usernameChanged();
    expect(w1.own, isNull);
    username = 'matt';
    await clock.pass(const Duration(minutes: 11));
    await w1.signedIn();
    expect(w1.own, isNotNull);
    // Nobody holds it now: gone too.
    dir.names.remove('matt');
    await clock.pass(const Duration(minutes: 11));
    await w1.signedIn();
    expect(w1.own, isNull);
    await sub.cancel();
    w1.dispose();
  });

  test('its own username still held by this device\'s old key (a new key made): said as that; and where the relay says this key holds it yet gives it to another account, said as the relay contradicting itself', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final old = NetKeys.generate(), now = NetKeys.generate(), stranger = NetKeys.generate();
    final kept = <String, String>{};
    // Before the new key: @matt claimed and held under the old one.
    dir.names['matt'] = old;
    final before = _bare(clock, dir, me: old.id, username: () => 'matt', held: () async => dir.heldBy(old), kept: kept);
    before.claimed('matt');
    await before.signedIn();
    expect(before.own, isNull);
    before.dispose();
    // "New key for this phone": another identity, the username still the phone's, the relay still giving it to the old.
    final after = _bare(clock, dir, me: now.id, username: () => 'matt', held: () async => dir.heldBy(now), kept: kept);
    await clock.pass(const Duration(minutes: 11));
    await after.signedIn();
    expect([after.own?.kind, after.own?.other], [NameKind.old, old.id]);
    after.dispose();
    // The relay says this key holds @matt, and gives @matt to someone else when asked.
    final mine = NetKeys.generate();
    final lying = _bare(clock, dir, me: mine.id, username: () => 'matt', held: () async => Me.nameKeyOf('matt'), kept: {});
    dir.names['matt'] = stranger;
    await clock.pass(const Duration(minutes: 11));
    await lying.signedIn();
    expect(lying.own?.kind, NameKind.contradicts);
    lying.dispose();
  });

  test('a friend\'s word about its own username: taken only from a friend, sealed, for this username and another account; said at once only when new that week', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), sam = NetKeys.generate(), cleo = NetKeys.generate(), mallory = NetKeys.generate(), stranger = NetKeys.generate();
    final w1 = _bare(clock, dir, me: me.id, username: () => 'maya', friends: () => [_friend('sam', sam), _friend('cleo', cleo)]);
    final shown = <NameChange?>[];
    w1.notice.addListener(() => shown.add(w1.notice.value));
    Envelope said(String u, String i) => Envelope(kind: NameWatch.kind, body: {'u': u, 'i': i, 'at': clock.ms});
    w1.heard(stranger.id, said('maya', mallory.id));
    w1.heard(sam.id, said('someone', mallory.id));
    w1.heard(sam.id, said('maya', me.id));
    w1.heard(sam.id, said('maya', mallory.id), sealed: false);
    w1.heard(sam.id, said('maya', 'not a name'));
    expect([w1.toldMe, shown], [isEmpty, isEmpty]);
    w1.heard(sam.id, said('@Maya', mallory.id));
    expect([w1.toldMe.single.by, shown.single?.by], [sam.id, sam.id]);
    // The same from another friend, and again from Sam's other device an hour on: kept, not said again this week.
    w1.heard(cleo.id, said('maya', mallory.id));
    await clock.pass(const Duration(hours: 1));
    w1.heard(sam.id, said('maya', mallory.id));
    expect([w1.toldMe.length, shown.length], [2, 1]);
    // A week on, it is said again where it is still so.
    await clock.pass(const Duration(days: 7));
    w1.heard(cleo.id, said('maya', mallory.id));
    expect(shown.length, 2);
    w1.dispose();
  });

  test('S9: what was kept for another identity (an account signed in to without signing out) is not shown', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final before = NetKeys.generate(), after = NetKeys.generate(), sam = NetKeys.generate(), stranger = NetKeys.generate();
    final kept = <String, String>{};
    dir.names['matt'] = before;
    final w1 = _bare(clock, dir, me: before.id, username: () => 'matt', friends: () => [_friend('sam', sam)], held: () async => dir.heldBy(before), kept: kept);
    await w1.signedIn();
    dir.names['matt'] = stranger;
    await clock.pass(const Duration(minutes: 11));
    await w1.signedIn();
    w1.heard(sam.id, Envelope(kind: NameWatch.kind, body: {'u': 'matt', 'i': stranger.id}));
    expect([w1.own, w1.toldMe], [isNotNull, isNotEmpty]);
    w1.dispose();
    final w2 = _bare(clock, dir, me: after.id, username: () => 'matt', friends: () => [_friend('sam', sam)], kept: kept);
    expect([w2.own, w2.toldMe, w2.changes], [isNull, isEmpty, isEmpty]);
    w2.dispose();
  });

  test('S6: a sign-in while a friend\'s lookup is under way: its own username is asked as soon as that one ends, not skipped', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final me = NetKeys.generate(), sam = NetKeys.generate();
    dir.names
      ..['matt'] = me
      ..['sam'] = sam;
    final w1 = _bare(clock, dir, me: me.id, username: () => 'matt', friends: () => [_friend('sam', sam)], held: () async => Me.nameKeyOf('matt'));
    dir.hold = Completer<void>();
    // The friend's lookup starts and waits for its answer.
    await clock.pass(_day);
    expect(dir.asked.last.name, 'sam');
    await w1.signedIn();
    expect(dir.asked.where((x) => x.name == 'matt'), isEmpty, reason: 'not while the friend\'s is under way');
    dir.hold!.complete();
    dir.hold = null;
    await clock.pass(const Duration(minutes: 2));
    expect(dir.asked.where((x) => x.name == 'matt'), hasLength(1));
    w1.dispose();
  });

  test('S7 and S2: times kept from a clock that was ahead are held to now, and a phone that runs less than a day still comes to every friend (PROBE 8)', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final friends = [for (var i = 0; i < 60; i++) WatchedName('friend$i', NetCrypto.hex(NetCrypto.randomBytes(16)), 'k')];
    final start = clock.ms;
    // Kept by a clock two days ahead: five friends "asked" in the future.
    final ahead = start + const Duration(days: 2).inMilliseconds;
    final kept = <String, String>{
      NameWatch.keptName: jsonEncode({
        'me': 'a' * 32,
        'r': {
          _relay: {
            'c': {for (final f in friends.take(5)) f.id: ahead},
          },
        },
      }),
    };
    // Five days of a process started again every ten hours, on the same choices.
    for (var i = 0; i < 12; i++) {
      final w1 = _bare(clock, dir, me: 'a' * 32, friends: () => friends, kept: kept);
      await clock.pass(const Duration(hours: 10));
      w1.dispose();
    }
    final asked = dir.asked.map((x) => x.name).toSet();
    expect([for (final f in friends) if (!asked.contains(f.username)) f.username], isEmpty, reason: 'every friend asked');
    final friend0 = [for (final x in dir.asked) if (x.name == 'friend0') x.at];
    expect(friend0.first - start, lessThanOrEqualTo(const Duration(days: 1, hours: 1).inMilliseconds), reason: 'not held back two days by a clock that was ahead');
  });

  test('S1 and N2: the relay\'s lookups are the account\'s, so its devices share the days between them, not the friends, and the watch\'s share of an hour: each friend asked once a day by one device, and every device asks about every friend in n days; told too many, a device asks nothing for an hour', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final friends = [for (var i = 0; i < 90; i++) WatchedName('friend$i', NetCrypto.hex(NetCrypto.randomBytes(16)), 'k')];
    final start = clock.ms;
    final byDevice = [for (var d = 0; d < 3; d++) <({String name, int at})>[]];
    final devices = [for (var d = 0; d < 3; d++) _bare(clock, dir, me: 'a' * 32, friends: () => friends, share: () => (index: d, of: 3), kept: {}, asked: byDevice[d])];
    await clock.pass(const Duration(days: 3, hours: 2));
    // Each friend asked by one device a day, never by two: the account's rate is what one device's was.
    final firstDay = [for (final x in dir.asked) if (x.at - start < _day.inMilliseconds) x.name];
    expect([firstDay.toSet().length, firstDay.length], [90, 90]);
    for (final f in friends) {
      final times = [for (final x in dir.asked) if (x.name == f.username) x.at];
      for (var i = 1; i < times.length; i++) {
        expect(times[i] - times[i - 1], inInclusiveRange(const Duration(hours: 23).inMilliseconds, const Duration(hours: 25).inMilliseconds), reason: '${f.username} a day apart');
      }
    }
    // And each device asked about every friend, every three days: none of them knows of only some (the review, N2).
    for (final (d, asked) in byDevice.indexed) {
      expect(asked.map((x) => x.name).toSet(), hasLength(90), reason: 'device $d');
      for (final f in friends) {
        final times = [for (final x in asked) if (x.name == f.username) x.at];
        for (var i = 1; i < times.length; i++) {
          expect(times[i] - times[i - 1], greaterThanOrEqualTo(const Duration(days: 3, hours: -1).inMilliseconds), reason: '${f.username} on device $d');
        }
      }
    }
    // A third of the friends each day, not all of them every third day: no device's day needs more lookups than its share
    // of the hour gives (the days counted from 1970, as the devices reckon them).
    final firstWhole = (start + _day.inMilliseconds - 1) ~/ _day.inMilliseconds, end = clock.ms ~/ _day.inMilliseconds;
    for (final (d, asked) in byDevice.indexed) {
      for (var k = firstWhole; k < end; k++) {
        expect(asked.where((x) => x.at ~/ _day.inMilliseconds == k).length, inInclusiveRange(10, 60), reason: 'device $d, day $k');
      }
    }
    // Never more than the account's share an hour, all devices together.
    final times = [for (final x in dir.asked) x.at];
    for (final t in times) {
      expect(times.where((u) => u >= t && u - t < const Duration(hours: 1).inMilliseconds).length, lessThanOrEqualTo(LookupBudget.mostAnHour));
    }
    for (final d in devices) {
      d.dispose();
    }
    // Told too many: nothing for an hour.
    final one = _bare(clock, dir, me: 'b' * 32, friends: () => friends, kept: {});
    await clock.pass(_day);
    dir.refuses = true;
    final at = dir.asked.length;
    await clock.pass(const Duration(minutes: 59));
    expect(dir.asked.length - at, 1, reason: 'the refused one, and nothing after it within the hour');
    one.dispose();
  });

  test('PROBE 10, fixed: a friend\'s username given to another account is shown on every device of the account, not only on one: each asks about every friend, on days of its own', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final keys = [for (var i = 0; i < 8; i++) NetKeys.generate()];
    final friends = [for (var i = 0; i < 8; i++) _friend('friend$i', keys[i])];
    for (var i = 0; i < 8; i++) {
      dir.names['friend$i'] = keys[i];
    }
    final phone = _bare(clock, dir, me: 'a' * 32, friends: () => friends, share: () => (index: 0, of: 2), kept: {});
    final mac = _bare(clock, dir, me: 'a' * 32, friends: () => friends, share: () => (index: 1, of: 2), kept: {});
    await clock.pass(const Duration(days: 2));
    expect(dir.asked, hasLength(16), reason: 'each friend once a day, the two devices in turn');
    final stranger = NetKeys.generate();
    for (var i = 0; i < 8; i++) {
      dir.names['friend$i'] = stranger;
    }
    await clock.pass(const Duration(days: 2));
    final all = [for (final f in friends) f.username];
    expect([for (final f in friends) if (phone.changeFor(f.id) != null) f.username], all, reason: 'the phone');
    expect([for (final f in friends) if (mac.changeFor(f.id) != null) f.username], all, reason: 'the Mac');
    phone.dispose();
    mac.dispose();
  });

  test('PROBE 11, fixed: what a device shows of a friend it asks again itself, after the account\'s devices are counted again too, and it goes once nobody holds the name', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final keys = [for (var i = 0; i < 8; i++) NetKeys.generate()];
    final friends = [for (var i = 0; i < 8; i++) _friend('friend$i', keys[i])];
    for (var i = 0; i < 8; i++) {
      dir.names['friend$i'] = keys[i];
    }
    var share = (index: 0, of: 1);
    final watch = _bare(clock, dir, me: 'a' * 32, friends: () => friends, share: () => share, kept: {});
    await clock.pass(const Duration(days: 2));
    final stranger = NetKeys.generate();
    for (var i = 0; i < 8; i++) {
      dir.names['friend$i'] = stranger;
    }
    await clock.pass(const Duration(days: 2));
    expect([for (final f in friends) watch.changeFor(f.id)].whereType<NameChange>(), hasLength(8));
    // Another device of the account comes along; then nobody holds any of the names.
    share = (index: 0, of: 2);
    for (var i = 0; i < 8; i++) {
      dir.names.remove('friend$i');
    }
    await clock.pass(const Duration(days: 3));
    expect([for (final f in friends) if (watch.changeFor(f.id) != null) f.username], isEmpty);
    watch.dispose();
  });

  test('N3: what a device shows of a friend is asked again a day on, whatever its turn, and goes once nobody holds the name; nothing is shown of someone no longer a friend', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final maya = NetKeys.generate();
    var friends = [_friend('maya', maya)];
    dir.names['maya'] = maya;
    // One of four devices: its turn for Maya is every four days.
    final watch = _bare(clock, dir, me: 'a' * 32, friends: () => friends, share: () => (index: 2, of: 4), kept: {});
    await clock.pass(const Duration(days: 4));
    expect(dir.asked, hasLength(1));
    // At the device's next turn, four days on, the relay names someone else.
    dir.names['maya'] = NetKeys.generate();
    for (var h = 0; h <= 4 * 24 && dir.asked.length < 2; h++) {
      await clock.pass(const Duration(hours: 1));
    }
    expect(dir.asked, hasLength(2));
    expect(dir.asked[1].at - dir.asked[0].at, const Duration(days: 4).inMilliseconds);
    expect(watch.changeFor(maya.id), isNotNull);
    final shown = dir.asked.last.at;
    // Still someone else's a day on: asked again, and still shown.
    await clock.pass(Duration(milliseconds: shown + const Duration(days: 1, minutes: 5).inMilliseconds - clock.ms));
    expect(dir.asked, hasLength(3));
    expect(watch.changeFor(maya.id), isNotNull);
    // Nobody's now: gone at the next day's asking, not at the device's next turn days on.
    dir.names.remove('maya');
    await clock.pass(const Duration(days: 1));
    expect(dir.asked, hasLength(4));
    expect(watch.changeFor(maya.id), isNull);
    // Someone takes it again: shown at the device's next turn; then she is no longer a friend, and it goes at once.
    dir.names['maya'] = NetKeys.generate();
    await clock.pass(const Duration(days: 4, minutes: 5));
    expect(watch.changeFor(maya.id), isNotNull);
    friends = [];
    watch.friendsChanged();
    expect(watch.changeFor(maya.id), isNull);
    expect(watch.changes, isEmpty);
    watch.dispose();
  });

  test('the lookups are spread through the day, each friend once, never more than so many an hour or closer than a minute; a relay that can\'t be reached is asked again ten minutes on', () async {
    final clock = FakeClock();
    final dir = _Directory(clock);
    final friends = [for (var i = 0; i < 300; i++) WatchedName('friend$i', NetCrypto.hex(NetCrypto.randomBytes(16)), 'k')];
    final kept = <String, String>{};
    NameWatch make() => _bare(clock, dir, me: 'a' * 32, friends: () => friends, kept: kept);
    final watch = make();
    final start = clock.ms;
    await clock.pass(const Duration(hours: 26));
    final times = [for (final x in dir.asked) x.at];
    expect(dir.asked.map((x) => x.name).toSet(), hasLength(300));
    final firstDay = [for (final x in dir.asked) if (x.at - start < _day.inMilliseconds) x.name];
    expect(firstDay.toSet().length, firstDay.length);
    for (var i = 1; i < times.length; i++) {
      expect(times[i] - times[i - 1], greaterThanOrEqualTo(NameWatch.gap.inMilliseconds));
    }
    for (final t in times) {
      expect(times.where((u) => u >= t && u - t < const Duration(hours: 1).inMilliseconds).length, lessThanOrEqualTo(LookupBudget.mostAnHour));
    }
    for (var h = 0; h < 24; h++) {
      expect(times.any((t) => t - start >= h * 3600000 && t - start < (h + 1) * 3600000), isTrue, reason: 'hour $h');
    }
    watch.dispose();
    final again = make();
    final before = dir.asked.length;
    await clock.pass(const Duration(minutes: 30));
    expect(dir.asked.length - before, lessThanOrEqualTo(30 ~/ NameWatch.gap.inMinutes + 1));
    dir.down = true;
    final downAt = dir.asked.length;
    await clock.pass(const Duration(hours: 2));
    expect(dir.asked.length - downAt, lessThanOrEqualTo(13));
    again.dispose();
  });

  test('S5: what checks the relay starts quietly: nothing it throws, at once or later, stops what starts after it', () async {
    var after = false;
    await Future<void>.value()
        .then((_) => quietly(() => throw StateError('at once')))
        .then((_) => quietly(() async {
              await Future<void>.delayed(Duration.zero);
              throw StateError('later');
            }))
        .then((_) => after = true);
    expect(after, isTrue);
  });
}
