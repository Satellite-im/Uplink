import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show MemoryFsStore;
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A circle's key changed when someone is put out (GMFB-26, lib/circles/circle_keys.dart, docs/FORWARD_SECRECY.md):
/// the keys on their own, then circles on a stand-in for the relay's rooms, with a listener that keeps hearing what is
/// said after a ban, as a changed app could.

class _Hub {
  final Map<String, List<_Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  /// Everything this route heard, by room: what a listener that never leaves keeps.
  final Map<String, List<Uint8List>> heard = {};

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final first = !r.any((o) => o.me == me);
    final others = {for (final o in r) if (o.me != me) o.me}.toList();
    if (!r.contains(this)) r.add(this);
    if (first) {
      for (final o in r) {
        if (o.me != me) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
      }
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    if (r.any((o) => o.me == me)) return;
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    for (final o in [...?hub.rooms[room]]) {
      if (!identical(o, this)) {
        scheduleMicrotask(() {
          (o.heard[room] ??= []).add(bytes);
          o._packets.add((room: room, from: me, bytes: bytes));
        });
      }
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => _looks.stream;
}

Future<void> _until(bool Function() ok, {int seconds = 5}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

Circle _copy(Circle c) => Circle.fromJson(jsonDecode(jsonEncode(c.toJson())))!;

/// Whether [bytes] opens for anyone holding only the seeds (what a banned member keeps): the circle's own key or a
/// space's, the old way, or under an epoch [keys] holds.
bool _opensWithSeedsOnly(Circle c, Uint8List bytes, {CircleKeys? keys}) {
  if (NetCrypto.open(c.key, bytes) != null) return true;
  for (final s in c.spaces) {
    if (NetCrypto.open(c.channelOf(s).key, bytes) != null) return true;
  }
  if (keys != null) {
    if (keys.open(c.seed, c.key, 'circle', bytes).clear != null) return true;
    for (final s in c.spaces) {
      if (keys.open(c.seed, c.channelOf(s).key, 'space', bytes).clear != null) return true;
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CircleKeys.enabled = true;
  CircleKeys.makes = true;
  CircleKeys.offThread = false;
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  group('the keys', () {
    late NetKeys owner, maya, sam;
    late Circles mine;
    late Circle c;

    setUp(() async {
      owner = NetKeys.generate();
      maya = NetKeys.generate();
      sam = NetKeys.generate();
      mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(_Hub(), owner.id));
      c = (await mine.make(name: 'Book club'))!;
    });
    tearDown(() => mine.clear());

    Future<CircleInbox> inboxOf(CircleKeys keys, NetKeys who) async => CircleKeys.inboxOf(c.seed, who.id, await keys.inboxSaid(c.seed, KeysSigner(who)))!;

    test('an inbox is only its identity\'s: another name, or a changed key, is refused', () async {
      final k = CircleKeys.fresh();
      final said = await k.inboxSaid(c.seed, KeysSigner(maya));
      expect(CircleKeys.inboxOf(c.seed, maya.id, said), isNotNull);
      expect(CircleKeys.inboxOf(c.seed, sam.id, said), isNull, reason: 'said as someone else');
      expect(CircleKeys.inboxOf('${c.seed.substring(1)}0', maya.id, said), isNull, reason: 'another circle');
      expect(CircleKeys.inboxOf(c.seed, maya.id, {...said, 'b': NetCrypto.hex(NetKeys.generate().public)}), isNull, reason: 'another inbox under her signature');
    });

    test('after a change the seed alone opens nothing, an older key opens nothing newer, and the old sealing still opens', () async {
      final ownerKeys = mine.keys!, mayaKeys = CircleKeys.fresh(), samKeys = CircleKeys.fresh();
      final said = (await ownerKeys.rotate(c, KeysSigner(owner), [await inboxOf(mayaKeys, maya)]))!;
      expect(said.single['t'], 'rk');
      expect(mayaKeys.take(c, maya.id, said.single), isTrue);
      expect(samKeys.take(c, sam.id, said.single), isFalse, reason: 'no box for Sam');
      expect(mayaKeys.current(c.seed)!.epoch, 1);
      expect(samKeys.lacking(c.seed), isTrue, reason: 'he knows a newer key exists, and has none');

      final one = ownerKeys.seal(c.seed, c.key, 'circle', utf8.encode('said in epoch 1'))!;
      expect(utf8.decode(mayaKeys.open(c.seed, c.key, 'circle', one).clear!), 'said in epoch 1');
      expect(_opensWithSeedsOnly(c, one, keys: samKeys), isFalse);
      expect(samKeys.open(c.seed, c.key, 'circle', one).unknown, isTrue);
      expect(mayaKeys.open(c.seed, c.key, 'space', one).clear, isNull, reason: 'a room\'s and a space\'s keys are apart');

      // Changed again without her: what she holds opens nothing of epoch 2, and all of epoch 1 still.
      await ownerKeys.rotate(c, KeysSigner(owner), const []);
      final two = ownerKeys.seal(c.seed, c.key, 'circle', utf8.encode('said in epoch 2'))!;
      expect(mayaKeys.open(c.seed, c.key, 'circle', two).clear, isNull);
      expect(mayaKeys.open(c.seed, c.key, 'circle', two).unknown, isTrue);
      expect(mayaKeys.open(c.seed, c.key, 'circle', one).clear, isNotNull);
      expect(ownerKeys.open(c.seed, c.key, 'circle', one).clear, isNotNull, reason: 'the owner keeps every epoch it held');

      // What a build from before says, the old way, opens for everyone.
      final old = NetCrypto.seal(c.key, utf8.encode('from an old build'));
      for (final k in [ownerKeys, mayaKeys, samKeys]) {
        expect(k.open(c.seed, c.key, 'circle', old).clear, isNotNull);
      }
      // Changed by a byte: nothing.
      expect(mayaKeys.open(c.seed, c.key, 'circle', Uint8List.fromList(one)..[30] ^= 1).clear, isNull);
    });

    test('only the owner or an admin can change the key, and nobody can hand out a key of their own making', () async {
      final mayaKeys = CircleKeys.fresh(), samKeys = CircleKeys.fresh();
      final mayaInbox = await inboxOf(mayaKeys, maya);
      expect(await samKeys.rotate(c, KeysSigner(sam), [mayaInbox]), isNull, reason: 'Sam may not change the circle');

      // A header Sam signs himself is not believed even where it is put together by hand.
      final key = NetCrypto.randomBytes(32);
      final forged = CircleEpoch(seed: c.seed, epoch: 5, commit: CircleKeys.commitOf(c.seed, 5, key), by: sam.id, byKey: NetCrypto.hex(sam.public), at: 1, sig: '');
      final signedBySam = forged.withSig(NetCrypto.hex(NetCrypto.sign(sam, forged.signed)));
      expect(mayaKeys.take(c, maya.id, {'t': 'kb', 'h': signedBySam.toJson(), 'x': []}), isFalse);
      expect(mayaKeys.newest(c.seed), isNull);

      // The owner's real header, with a box Sam made for Maya holding a key of his: refused, it is not the key the
      // owner committed to.
      final real = (await mine.keys!.rotate(c, KeysSigner(owner), const []))!.single;
      final h = CircleEpoch.fromJson(real['h'])!;
      final once = NetKeys.generate();
      final shared = NetCrypto.agree(once, mayaInbox.key)!;
      final k = NetCrypto.hkdf(salt: c.key, ikm: shared, info: utf8.encode('ghost-circle box v1|${c.seed}|${h.epoch}|${h.commit}|${maya.id}|${mayaInbox.device}'));
      final box = {'i': maya.id, 'd': mayaInbox.device, 'o': NetCrypto.hex(once.public), 's': base64Encode(NetCrypto.seal(k, NetCrypto.randomBytes(32)))};
      expect(mayaKeys.take(c, maya.id, {'t': 'kb', 'h': real['h'], 'x': [box]}), isFalse);
      expect(mayaKeys.current(c.seed), isNull);
      // The real key, handed on by anyone who holds it: taken.
      final handed = mine.keys!.handOn(c, mayaInbox)!;
      expect(mayaKeys.take(c, maya.id, handed), isTrue);
      expect(mayaKeys.current(c.seed)!.epoch, h.epoch);
    });

    test('kept across a start, in the secret store; forgotten with the circle', () async {
      final store = MemoryFsStore();
      final k = CircleKeys(secrets: store);
      await k.load();
      final inbox = NetCrypto.hex(k.inboxKey);
      final said = (await mine.keys!.rotate(c, KeysSigner(owner), [await inboxOf(k, maya)]))!;
      expect(k.take(c, maya.id, said.single), isTrue);
      await k.flushed();
      final again = CircleKeys(secrets: store);
      await again.load();
      expect(NetCrypto.hex(again.inboxKey), inbox);
      expect(again.device, k.device);
      expect(again.current(c.seed)!.epoch, 1);
      final sealed = mine.keys!.seal(c.seed, c.key, 'space', [1, 2, 3])!;
      expect(again.open(c.seed, c.key, 'space', sealed).clear, [1, 2, 3]);
      await again.forget(c.seed);
      await again.flushed();
      final third = CircleKeys(secrets: store);
      await third.load();
      expect(third.current(c.seed), isNull);
    });

    test('knowing of a newer key than it holds, a device seals nothing at all, not under the older key', () async {
      final mayaKeys = CircleKeys.fresh();
      final first = (await mine.keys!.rotate(c, KeysSigner(owner), [await inboxOf(mayaKeys, maya)]))!.single;
      expect(mayaKeys.take(c, maya.id, first), isTrue);
      final second = (await mine.keys!.rotate(c, KeysSigner(owner), const []))!.single;
      mayaKeys.take(c, maya.id, second);
      expect(mayaKeys.lacking(c.seed), isTrue);
      expect(mayaKeys.seal(c.seed, c.key, 'space', [1]), isNull, reason: 'epoch 1, which someone put out at epoch 2 holds, is not used');
    });

    test('an asker away through several changes is handed every key after its own, oldest first', () async {
      final ownerKeys = mine.keys!, mayaKeys = CircleKeys.fresh();
      final inbox = await inboxOf(mayaKeys, maya);
      await ownerKeys.rotate(c, KeysSigner(owner), const []);
      final one = ownerKeys.seal(c.seed, c.key, 'space', utf8.encode('epoch one'))!;
      await ownerKeys.rotate(c, KeysSigner(owner), const []);
      final two = ownerKeys.seal(c.seed, c.key, 'space', utf8.encode('epoch two'))!;
      final handed = ownerKeys.handOnSince(c, inbox, 0);
      expect(handed.map((m) => (m['h'] as Map)['e']), [1, 2]);
      for (final m in handed) {
        mayaKeys.take(c, maya.id, m);
      }
      expect(utf8.decode(mayaKeys.open(c.seed, c.key, 'space', one).clear!), 'epoch one');
      expect(utf8.decode(mayaKeys.open(c.seed, c.key, 'space', two).clear!), 'epoch two');
      expect(ownerKeys.handOnSince(c, inbox, 1).map((m) => (m['h'] as Map)['e']), [2]);
    });

    test('a header taken stays believed when its signer stops being an admin; a new one from them is refused', () async {
      final admin = NetKeys.generate();
      expect(await mine.grantAdmin(mine.bySeed(c.seed)!, admin.id), isTrue);
      final adminKeys = CircleKeys.fresh(), mayaKeys = CircleKeys.fresh(), laterKeys = CircleKeys.fresh();
      final said = (await adminKeys.rotate(mine.bySeed(c.seed)!, KeysSigner(admin), [await inboxOf(mayaKeys, maya)]))!.single;
      expect(mayaKeys.take(mine.bySeed(c.seed)!, maya.id, said), isTrue);
      expect(CircleEpoch.fromJson(said['h'])!.gv, mine.bySeed(c.seed)!.manifest.grantsVersion, reason: 'the admin list it was made under is signed in');
      mine.keys!.take(mine.bySeed(c.seed)!, owner.id, said);
      // The admin is made not one: Maya keeps sealing under epoch 1, never falling back to the seed's key.
      expect(await mine.grantAdmin(mine.bySeed(c.seed)!, admin.id, on: false), isTrue);
      expect(mayaKeys.current(c.seed)?.epoch, 1);
      final sealed = mayaKeys.seal(c.seed, c.key, 'space', [1])!;
      expect(NetCrypto.open(c.key, sealed), isNull);
      // Someone who hadn't taken it refuses it now; and the owner made a new key, since the newest was theirs.
      expect(laterKeys.take(mine.bySeed(c.seed)!, maya.id, said), isFalse);
      expect(mine.keys!.newest(c.seed)?.by, owner.id, reason: 'the owner changed the key when the admin who made the newest stopped being one');
    });

    test('a header far ahead is known (so nothing is sealed until its key comes); one at the edge of the counter can\'t be read', () async {
      final mayaKeys = CircleKeys.fresh();
      final key = NetCrypto.randomBytes(32);
      CircleEpoch at(int e) {
        final u = CircleEpoch(seed: c.seed, epoch: e, commit: CircleKeys.commitOf(c.seed, e, key), by: owner.id, byKey: NetCrypto.hex(owner.public), at: 1, sig: '');
        return u.withSig(NetCrypto.hex(NetCrypto.sign(owner, u.signed)));
      }
      mayaKeys.take(mine.bySeed(c.seed)!, maya.id, {'h': at(12).toJson(), 'x': []});
      expect(mayaKeys.newest(c.seed)?.epoch, 12);
      expect(mayaKeys.lacking(c.seed), isTrue);
      expect(mayaKeys.seal(c.seed, c.key, 'space', [1]), isNull, reason: 'knowing epochs and holding none, never the seed\'s key');
      expect(CircleEpoch.fromJson(at(0xffffffff).toJson()), isNull);
    });

    test('two headers for one epoch: only the device that made the losing one changes it again, and once', () async {
      final admin = NetKeys.generate();
      expect(await mine.grantAdmin(mine.bySeed(c.seed)!, admin.id), isTrue);
      final adminKeys = CircleKeys.fresh(), ownersMac = CircleKeys.fresh();
      final a = (await mine.keys!.rotate(mine.bySeed(c.seed)!, KeysSigner(owner), const []))!.single;
      final b = (await adminKeys.rotate(mine.bySeed(c.seed)!, KeysSigner(admin), const []))!.single;
      for (final k in [mine.keys!, adminKeys, ownersMac]) {
        k.take(mine.bySeed(c.seed)!, owner.id, a);
        k.take(mine.bySeed(c.seed)!, admin.id, b);
        expect(k.split(c.seed), isTrue);
      }
      final ca = CircleEpoch.fromJson(a['h'])!.commit, cb = CircleEpoch.fromJson(b['h'])!.commit;
      final ownerLost = ca.compareTo(cb) > 0;
      expect(mine.keys!.shouldChangeAgain(c.seed), ownerLost);
      expect(adminKeys.shouldChangeAgain(c.seed), !ownerLost);
      expect(ownersMac.shouldChangeAgain(c.seed), isFalse, reason: 'the owner\'s other device didn\'t make it');
      final loser = ownerLost ? mine.keys! : adminKeys;
      loser.changingAgain(c.seed);
      expect(loser.shouldChangeAgain(c.seed), isFalse, reason: 'once per epoch');
    });

    test('kept inboxes: once a day; signing out forgets every key and makes a new inbox', () async {
      final k = CircleKeys.fresh();
      expect(k.keepInboxNow(c.seed), isTrue);
      k.keptInbox(c.seed);
      expect(k.keepInboxNow(c.seed), isFalse);
      await mine.keys!.rotate(c, KeysSigner(owner), const []);
      final inbox = NetCrypto.hex(mine.keys!.inboxKey);
      await mine.keys!.wipe();
      expect(mine.keys!.current(c.seed), isNull);
      expect(NetCrypto.hex(mine.keys!.inboxKey), isNot(inbox));
    });

    test('many members: the boxes go in several messages, each with the header', () async {
      final inboxes = [for (var i = 0; i < CircleKeys.boxesPerMessage + 5; i++) CircleInbox(id: NetCrypto.hex(NetCrypto.randomBytes(16)), device: NetCrypto.hex(NetCrypto.randomBytes(16)), key: NetKeys.generate().public)];
      final said = (await mine.keys!.rotate(c, KeysSigner(owner), inboxes))!;
      expect(said.map((m) => m['t']), ['rk', 'kb']);
      expect([for (final m in said) (m['x'] as List).length], [CircleKeys.boxesPerMessage, 5]);
      expect(utf8.encode(jsonEncode(said.first)).length, lessThan(64 * 1024));
    });
  });

  group('in circles', () {
    late _Hub hub;
    late NetKeys owner, maya, sam;
    late Circles mine, hers, his;
    late Circle c;
    final closing = <Future<void> Function()>[];

    setUp(() async {
      hub = _Hub();
      owner = NetKeys.generate();
      maya = NetKeys.generate();
      sam = NetKeys.generate();
      mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      c = (await mine.make(name: 'Book club'))!;
      hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      his = Circles.forTest(signer: KeysSigner(sam), route: _Route(hub, sam.id));
      hers.join(_copy(mine.bySeed(c.seed)!));
      his.join(_copy(mine.bySeed(c.seed)!));
      // Everyone in, and each one's inbox heard by the owner.
      await _until(() => mine.roomOf(c)!.inboxes.length == 2);
      expect(mine.roomOf(c)!.inboxes.keys.map((k) => k.split(':').first).toSet(), {maya.id, sam.id});
    });

    tearDown(() async {
      for (final f in closing.reversed) {
        await f();
      }
      closing.clear();
      for (final x in [mine, hers, his]) {
        await x.clear();
      }
    });

    /// A listener in [c]'s rooms under Sam's name that never leaves: what a changed app of his could keep hearing.
    Future<_Route> eavesdropper() async {
      final ear = _Route(hub, sam.id);
      await ear.join(c.room, c.token);
      for (final s in c.spaces) {
        await ear.join(c.channelOf(s).chatRoom, c.channelOf(s).chatToken);
      }
      return ear;
    }

    Future<HangoutRoom> space(Circles device, NetKeys who, String name) async {
      final text = mine.bySeed(c.seed)!.spaces.firstWhere((s) => s.kind == SpaceKind.text);
      final room = HangoutRoom(channel: mine.bySeed(c.seed)!.channelOf(text), route: _Route(hub, who.id), name: name, signer: KeysSigner(who))..circleKeys = device.keys;
      await room.open();
      closing.add(room.close);
      return room;
    }

    test('banned: everyone else gets the new key, and nothing said after opens for him, in the circle\'s room or its spaces', () async {
      final ear = await eavesdropper();
      final ownerSpace = await space(mine, owner, 'Owner'), hersSpace = await space(hers, maya, 'Maya');
      expect(ownerSpace.send('before the ban'), isTrue);
      await _until(() => hersSpace.messages.any((m) => m.text == 'before the ban'));

      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => his.bySeed(c.seed) == null);
      expect(his.bySeed(c.seed), isNull, reason: 'his own app left, as before');
      await _until(() => hers.keys!.current(c.seed) != null);
      expect(hers.keys!.current(c.seed)!.epoch, 1);
      expect(his.keys!.current(c.seed), isNull);

      final heardBefore = {for (final e in ear.heard.entries) e.key: e.value.length};
      await mine.edit(mine.bySeed(c.seed)!, name: 'Book club (new)');
      await _until(() => hers.bySeed(c.seed)!.name == 'Book club (new)');
      expect(hers.bySeed(c.seed)!.name, 'Book club (new)', reason: 'the manifest under the new key reaches her');
      expect(ownerSpace.send('after the ban'), isTrue);
      await _until(() => hersSpace.messages.any((m) => m.text == 'after the ban'));
      expect(hersSpace.messages.map((m) => m.text), contains('after the ban'));
      await _settle();

      final after = [
        for (final e in ear.heard.entries)
          ...e.value.skip(heardBefore[e.key] ?? 0),
      ];
      expect(after, isNotEmpty, reason: 'he still hears the packets');
      // The key's own messages (inboxes, boxes) are sealed with the seed's key: what he can open of those says nothing.
      final opened = [
        for (final b in after)
          if (_opensWithSeedsOnly(c, b, keys: his.keys)) jsonDecode(utf8.decode(NetCrypto.open(c.key, b) ?? [])) as Map,
      ];
      // The circle's own business (its manifest, joins, asking) goes under the seed's key so a member behind on the key
      // isn't stuck (B5); its spaces' words never.
      expect(opened.map((m) => m['t']).toSet().difference({'ik', 'k?', 'kb', 'rk', 'circle', 'sync?', 'joined'}), isEmpty, reason: 'no message: only the circle\'s own business');
      expect(opened.any((m) => jsonEncode(m).contains('after the ban')), isFalse);
    });

    // GMFB-26, step 1 of "Switching it on" (docs/FORWARD_SECRECY.md): every device takes part, none makes a key yet.
    test('a device that doesn\'t make keys changes nothing at a ban, and still takes and reads a key a device that does made', () async {
      final ownerSpace = await space(mine, owner, 'Owner'), hersSpace = await space(hers, maya, 'Maya');
      CircleKeys.makes = false;
      addTearDown(() => CircleKeys.makes = true);
      expect(await mine.rotateKey(mine.bySeed(c.seed)!), isFalse, reason: 'not made by this build');
      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => his.bySeed(c.seed) == null);
      await _settle();
      expect([mine.keys!.current(c.seed), hers.keys!.current(c.seed)], [isNull, isNull], reason: 'no new key at the ban');
      expect(ownerSpace.send('sealed as before'), isTrue);
      await _until(() => hersSpace.messages.any((m) => m.text == 'sealed as before'));
      // A device of a later build, which makes keys, changes it: this one, which doesn't, takes it and reads under it.
      CircleKeys.makes = true;
      expect(await mine.rotateKey(mine.bySeed(c.seed)!), isTrue);
      CircleKeys.makes = false;
      await _until(() => hers.keys!.current(c.seed) != null);
      expect(hers.keys!.current(c.seed)!.epoch, 1);
      expect(ownerSpace.send('under the new key'), isTrue);
      await _until(() => hersSpace.messages.any((m) => m.text == 'under the new key'));
      expect(hersSpace.messages.map((m) => m.text), contains('under the new key'));
      // And what she says goes under it too, which the owner reads.
      expect(hersSpace.send('her answer'), isTrue);
      await _until(() => ownerSpace.messages.any((m) => m.text == 'her answer'));
    });

    test('a banned member asking for the key is not answered; a second device of a member is', () async {
      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => hers.keys!.current(c.seed) != null);

      // Sam's changed app asks, with a real inbox of his.
      final samKeys = CircleKeys.fresh();
      final ear = await eavesdropper();
      ear.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'k?', 'ik': await samKeys.inboxSaid(c.seed, KeysSigner(sam))}))));
      await _settle(400);
      for (final b in ear.heard[c.room] ?? const <Uint8List>[]) {
        final clear = NetCrypto.open(c.key, b);
        if (clear != null) samKeys.take(c, sam.id, jsonDecode(utf8.decode(clear)) as Map);
      }
      expect(samKeys.current(c.seed), isNull);

      // Nor is he under a new key of his, slipped into the room with its token and never seen come in.
      final eve = NetKeys.generate(), eveKeys = CircleKeys.fresh();
      final eveEar = _Route(hub, eve.id);
      await eveEar.join(c.room, c.token);
      eveEar.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'k?', 'ik': await eveKeys.inboxSaid(c.seed, KeysSigner(eve))}))));
      await _settle(400);
      for (final b in eveEar.heard[c.room] ?? const <Uint8List>[]) {
        final clear = NetCrypto.open(c.key, b);
        if (clear != null) eveKeys.take(c, eve.id, jsonDecode(utf8.decode(clear)) as Map);
      }
      expect(eveKeys.current(c.seed), isNull);
      expect(mine.mayHaveKey(c.seed, eve.id), isFalse);

      // Maya's computer comes in after the change: it asks, is answered, and reads what is said.
      final hersToo = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      closing.add(hersToo.clear);
      hersToo.join(_copy(hers.bySeed(c.seed)!));
      await _until(() => hersToo.keys!.current(c.seed) != null);
      expect(hersToo.keys!.current(c.seed)!.epoch, 1);
      await mine.edit(mine.bySeed(c.seed)!, name: 'Read on her computer');
      await _until(() => hersToo.bySeed(c.seed)!.name == 'Read on her computer');
      expect(hersToo.bySeed(c.seed)!.name, 'Read on her computer');
    });

    test('a member without the new key waits to post, and posts under it once it comes; the banned one reads neither', () async {
      final ear = await eavesdropper();
      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => hers.keys!.current(c.seed) != null);
      // Maya's computer: in the room, knowing the new header, without its key yet.
      final laterKeys = CircleKeys.fresh();
      final h = hers.keys!.current(c.seed)!;
      laterKeys.take(hers.bySeed(c.seed)!, maya.id, {'h': h.toJson(), 'x': []});
      expect(laterKeys.lacking(c.seed), isTrue);
      final text = mine.bySeed(c.seed)!.spaces.firstWhere((s) => s.kind == SpaceKind.text);
      final channel = mine.bySeed(c.seed)!.channelOf(text);
      final later = HangoutRoom(channel: channel, route: _Route(hub, maya.id), name: 'Maya too', signer: KeysSigner(maya))..circleKeys = laterKeys;
      await later.open();
      closing.add(later.close);
      final ownerSpace = await space(mine, owner, 'Owner');
      final heardBefore = ear.heard[channel.chatRoom]?.length ?? 0;
      later.send('written while waiting');
      await _settle();
      expect(later.waitingForKey, isTrue);
      expect(ownerSpace.messages.any((m) => m.text == 'written while waiting'), isFalse);
      for (final b in (ear.heard[channel.chatRoom] ?? const <Uint8List>[]).skip(heardBefore)) {
        expect(_opensWithSeedsOnly(c, b), isFalse, reason: 'nothing under a key the banned one holds');
      }
      // Something said now under the new key can't be opened yet: kept.
      ownerSpace.send('said before the key came');
      await _settle();
      expect(later.messages.any((m) => m.text == 'said before the key came'), isFalse);
      // The owner's space is gone before the key comes, so nobody answers a sync: only what was kept can be read.
      await ownerSpace.close();
      final heardMid = ear.heard[channel.chatRoom]?.length ?? 0;
      // The key comes: what waited goes, and what was kept is read.
      final inbox = CircleKeys.inboxOf(c.seed, maya.id, await laterKeys.inboxSaid(c.seed, KeysSigner(maya)))!;
      expect(laterKeys.take(hers.bySeed(c.seed)!, maya.id, mine.keys!.handOn(mine.bySeed(c.seed)!, inbox)!), isTrue);
      await _until(() => later.messages.any((m) => m.text == 'said before the key came'));
      expect(later.messages.map((m) => m.text), contains('said before the key came'));
      await _settle();
      final out = [
        for (final b in (ear.heard[channel.chatRoom] ?? const <Uint8List>[]).skip(heardMid))
          if (mine.keys!.open(c.seed, channel.key, 'space', b).clear case final clear?) utf8.decode(clear),
      ];
      expect(out.any((w) => w.contains('written while waiting')), isTrue, reason: 'it went once the key came, under it');
      expect(later.waitingForKey, isFalse);
    });

    test('two admins change the key at once: it is changed again, past both', () async {
      final admin = NetKeys.generate();
      expect(await mine.grantAdmin(mine.bySeed(c.seed)!, admin.id), isTrue);
      final theirs = Circles.forTest(signer: KeysSigner(admin), route: _Route(hub, admin.id));
      closing.add(theirs.clear);
      theirs.join(_copy(mine.bySeed(c.seed)!));
      await _until(() => (theirs.bySeed(c.seed)?.manifest.canSign(admin.id) ?? false) && mine.roomOf(c)!.inboxes.length == 3);
      await Future.wait([mine.rotateKey(mine.bySeed(c.seed)!), theirs.rotateKey(theirs.bySeed(c.seed)!)]);
      await _until(() => (mine.keys!.newest(c.seed)?.epoch ?? 0) >= 2 && !mine.keys!.split(c.seed) && (hers.keys!.current(c.seed)?.epoch ?? 0) >= 2);
      expect(mine.keys!.newest(c.seed)!.epoch, 2);
      expect(mine.keys!.split(c.seed), isFalse);
      expect(hers.keys!.current(c.seed)!.epoch, 2);
    });

    test('inboxes: no more than eight kept for one id', () async {
      final ear = await eavesdropper();
      for (var i = 0; i < 12; i++) {
        final k = CircleKeys.fresh();
        ear.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode(await k.inboxSaid(c.seed, KeysSigner(sam))))));
      }
      await _settle();
      expect(mine.roomOf(c)!.inboxes.values.where((i) => i.id == sam.id).length, CircleRoom.mostInboxes);
    });

    test('two admins at once, the owner on two devices: changed again once, and it settles', () async {
      final admin = NetKeys.generate();
      expect(await mine.grantAdmin(mine.bySeed(c.seed)!, admin.id), isTrue);
      final ownersMac = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final theirs = Circles.forTest(signer: KeysSigner(admin), route: _Route(hub, admin.id));
      closing.add(ownersMac.clear);
      closing.add(theirs.clear);
      ownersMac.join(_copy(mine.bySeed(c.seed)!));
      theirs.join(_copy(mine.bySeed(c.seed)!));
      await _until(() => (theirs.bySeed(c.seed)?.manifest.canSign(admin.id) ?? false) && mine.roomOf(c)!.inboxes.length >= 3);
      await Future.wait([mine.rotateKey(mine.bySeed(c.seed)!), theirs.rotateKey(theirs.bySeed(c.seed)!)]);
      await _until(() => (mine.keys!.newest(c.seed)?.epoch ?? 0) >= 2 && !mine.keys!.split(c.seed));
      final settled = mine.keys!.newest(c.seed)!.epoch;
      await _settle(3000);
      expect(mine.keys!.newest(c.seed)!.epoch, settled, reason: 'no more changes: it doesn\'t loop');
      expect(settled, 2);
      expect(mine.keys!.split(c.seed), isFalse);
    });

    test('what waits for the key is kept across a restart, at most a hundred, and goes once the key comes', () async {
      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      final laterKeys = CircleKeys.fresh();
      final h = mine.keys!.current(c.seed)!;
      laterKeys.take(mine.bySeed(c.seed)!, maya.id, {'h': h.toJson(), 'x': []});
      final text = mine.bySeed(c.seed)!.spaces.firstWhere((s) => s.kind == SpaceKind.text);
      final channel = mine.bySeed(c.seed)!.channelOf(text);
      final store = MemoryHangoutStore();
      final first = HangoutRoom(channel: channel, route: _Route(hub, maya.id), name: 'Maya', signer: KeysSigner(maya), store: store)..circleKeys = laterKeys;
      await first.open();
      for (var i = 0; i < 105; i++) {
        first.send('waiting $i');
      }
      await first.close();
      // The app starts again: the same store, a new room.
      final again = HangoutRoom(channel: channel, route: _Route(hub, maya.id), name: 'Maya', signer: KeysSigner(maya), store: store)..circleKeys = laterKeys;
      expect(again.waitingForKey, isTrue);
      final ownerSpace = await space(mine, owner, 'Owner');
      await again.open();
      closing.add(again.close);
      final inbox = CircleKeys.inboxOf(c.seed, maya.id, await laterKeys.inboxSaid(c.seed, KeysSigner(maya)))!;
      laterKeys.take(mine.bySeed(c.seed)!, maya.id, mine.keys!.handOn(mine.bySeed(c.seed)!, inbox)!);
      await _until(() => ownerSpace.messages.any((m) => m.text == 'waiting 104'));
      final got = [for (final m in ownerSpace.messages) if (m.text.startsWith('waiting ')) m.text];
      expect(got.length, lessThanOrEqualTo(CircleRoom.mostWaiting + 1), reason: 'at most a hundred kept (a sync may be among them)');
      expect(got, contains('waiting 104'));
      expect(got, isNot(contains('waiting 0')), reason: 'the oldest went past the cap');
    });

    test('two devices of one member asking at once are each answered', () async {
      expect(await mine.removeMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => hers.keys!.current(c.seed) != null);
      final one = CircleKeys.fresh(), two = CircleKeys.fresh();
      final ear = _Route(hub, maya.id);
      await ear.join(c.room, c.token);
      for (final k in [one, two]) {
        ear.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'k?', 'ke': 0, 'ik': await k.inboxSaid(c.seed, KeysSigner(maya))}))));
      }
      await _settle(800);
      for (final b in ear.heard[c.room] ?? const <Uint8List>[]) {
        final clear = NetCrypto.open(c.key, b);
        if (clear == null) continue;
        final m = jsonDecode(utf8.decode(clear)) as Map;
        for (final k in [one, two]) {
          k.take(mine.bySeed(c.seed)!, maya.id, m);
        }
      }
      expect(one.current(c.seed), isNotNull);
      expect(two.current(c.seed), isNotNull);
    });

    test('kicked: a new key too; coming back openly by the link, he is given it again', () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await mine.kickMember(mine.bySeed(c.seed)!, sam.id), isTrue);
      await _until(() => his.bySeed(c.seed) == null);
      await _until(() => hers.keys!.current(c.seed) != null);
      expect(his.keys!.current(c.seed), isNull);
      expect(mine.mayHaveKey(c.seed, sam.id), isFalse);
      final whileOut = mine.keys!.seal(c.seed, c.key, 'space', utf8.encode('said while he was out'))!;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      his.removedFrom.value = null;
      his.join(Circle.fromLink(mine.bySeed(c.seed)!.link)!);
      await _until(() => his.keys!.current(c.seed) != null);
      expect(mine.mayHaveKey(c.seed, sam.id), isTrue, reason: 'he said he came, after the kick');
      // Not the key from while he was out (B9): a new one, made after he came back.
      expect(his.keys!.current(c.seed)!.epoch, 2);
      expect(his.keys!.open(c.seed, c.key, 'space', whileOut).clear, isNull, reason: 'what was said while he was out stays shut to him');
      expect(his.bySeed(c.seed), isNotNull);
    });
  });

  test('someone kicked who came back is still let have the key after the app starts again', () async {
    final app = AppState();
    final owner = NetKeys.generate(), sam = NetKeys.generate();
    final first = Circles.forTest(signer: KeysSigner(owner), route: _Route(_Hub(), owner.id), app: app);
    final c = (await first.make(name: 'Book club'))!;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await first.kickMember(first.bySeed(c.seed)!, sam.id), isTrue);
    expect(first.mayHaveKey(c.seed, sam.id), isFalse);
    first.heardJoined(first.bySeed(c.seed)!, sam.id, 'Sam', DateTime.now().millisecondsSinceEpoch + 1000);
    expect(first.mayHaveKey(c.seed, sam.id), isTrue);
    await first.clear();
    final again = Circles.forTest(signer: KeysSigner(owner), app: app);
    expect(again.mayHaveKey(c.seed, sam.id), isTrue);
  });

  test('when members last came is trimmed by who came longest ago, not by who was written first', () async {
    final app = AppState();
    final owner = NetKeys.generate();
    final circles = Circles.forTest(signer: KeysSigner(owner), route: _Route(_Hub(), owner.id), app: app);
    final c = (await circles.make(name: 'Big'))!;
    final now = DateTime.now().millisecondsSinceEpoch;
    circles.heardJoined(circles.bySeed(c.seed)!, 'recent', 'R', now);
    for (var i = 0; i < 400; i++) {
      circles.heardJoined(circles.bySeed(c.seed)!, 'm$i', 'M', now - 1000000 + i);
    }
    final kept = (jsonDecode(app.choice('circles_last_join', '{}')) as Map)[c.seed] as Map;
    expect(kept.containsKey('recent'), isTrue);
    expect(kept.containsKey('m0'), isFalse);
    await circles.clear();
  });

  group('with circle keys switched off', () {
    setUp(() => CircleKeys.enabled = false);
    tearDown(() => CircleKeys.enabled = true);

    test('what a build with them on left waiting in a space goes, under the seed\'s key', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      addTearDown(mine.clear);
      expect(mine.keys, isNull);
      final c = (await mine.make(name: 'Book club'))!;
      final text = c.spaces.firstWhere((s) => s.kind == SpaceKind.text);
      final channel = c.channelOf(text);
      final store = MemoryHangoutStore()..keepVotes('${channel.chatRoom}:u', jsonEncode([
            {'w': {'t': 'msg', 'id': 'm-left', 'x': 'left waiting', 'at': 1, 'n': 'Maya'}, 'k': true, 'r': false},
          ]));
      final theirs = HangoutRoom(channel: channel, route: _Route(hub, owner.id), name: 'Owner', signer: KeysSigner(owner));
      await theirs.open();
      addTearDown(theirs.close);
      final hers = HangoutRoom(channel: channel, route: _Route(hub, maya.id), name: 'Maya', signer: KeysSigner(maya), store: store);
      expect(hers.circleKeys, isNull);
      await hers.open();
      addTearDown(hers.close);
      await _until(() => theirs.messages.any((m) => m.text == 'left waiting'));
      expect(theirs.messages.map((m) => m.text), contains('left waiting'));
      expect(hers.waitingForKey, isFalse);
    });

    test('an inbox or a banned notice heard in a circle\'s room does nothing', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), sam = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final his = Circles.forTest(signer: KeysSigner(sam), route: _Route(hub, sam.id));
      addTearDown(mine.clear);
      addTearDown(his.clear);
      final c = (await mine.make(name: 'Book club'))!;
      his.join(_copy(mine.bySeed(c.seed)!));
      await _until(() => his.bySeed(c.seed)?.manifest.isSigned ?? false);
      final ear = _Route(hub, owner.id);
      await ear.join(c.room, c.token);
      final k = CircleKeys.fresh();
      ear.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode(await k.inboxSaid(c.seed, KeysSigner(owner))))));
      final at = DateTime.now().millisecondsSinceEpoch;
      final sig = NetCrypto.sign(owner, CircleRoom.outMessage(c.seed, sam.id, at));
      ear.send(c.room, NetCrypto.seal(c.key, utf8.encode(jsonEncode({'t': 'out', 'to': sam.id, 'at': at, 'k': NetCrypto.hex(owner.public), 'sig': NetCrypto.hex(sig)}))));
      await _settle(150);
      expect(mine.roomOf(c)!.inboxes, isEmpty);
      expect(his.bySeed(c.seed), isNotNull, reason: 'not put out by a notice the manifest doesn\'t back');
    });
  });
}
