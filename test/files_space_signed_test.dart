// A Files space's log, signed (Matt, 2026-11-17: "Finish the missing pieces that went unfinished" (of Circles and Files
// spaces, released in 0.9.2)): each entry its author's signature over the space, its place and the roster revision it
// was written under; each judged by that revision; a moderator's delete that frees the blob on the relay; and 0.9.2's
// unsigned entries still read, as they were.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/files/files_api.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

import 'files_space_test.dart' show FakeHub, FakeRoute, until, bytesOf;

void main() {
  final maya = KeysSigner(NetKeys.generate()), sam = KeysSigner(NetKeys.generate()), theo = KeysSigner(NetKeys.generate());
  final owner = NetCrypto.hex(maya.publicKey);
  const room = '0123456789abcdef0123456789abcdef';

  SpaceFile file(String id, String by) => SpaceFile(id: id, name: '$id.txt', size: 3, mime: 'text/plain', sha: '', key: Uint8List(32), prefix: Uint8List(8), by: by, byName: by, at: 1);

  Future<Map<String, Object?>> signed(KeysSigner who, Map<String, Object?> op, {required int prev, int rv = 0, String space = room}) =>
      FileOp.sign(op, space: space, prev: prev, rv: rv, publicKey: who.publicKey, sign: who.sign);

  LoggedOp at(int seq, String by, Map<String, Object?> op, {int? relayRv}) => LoggedOp(seq: seq, by: by, at: seq, op: op, relayRv: relayRv).checked(room);

  /// The space's rosters as its owner signs them: Sam a moderator at 1, a member again at 2.
  Future<Roster> rosterAt(int version, {Map<String, String> assigned = const {}}) async {
    var r = Roster.first(owner, kind: SpaceKind.files);
    for (var v = 1; v <= version; v++) {
      r = r.next(assigned: v == version ? assigned : const {});
    }
    return r.signedBy(maya.id, maya.publicKey, maya.sign);
  }

  BelievedRoster? logged(Object? j, BelievedRoster? previous) {
    final r = Roster.fromJson(j);
    return r != null && r.trustedFor(owner) ? (version: r.version, rules: RosterRules(r), held: r) : null;
  }

  /// [sig] (r then s) as its twin, r and n - s, which checks out as well.
  Uint8List twin(Uint8List sig) {
    final n = BigInt.parse('ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551', radix: 16);
    final s = BigInt.parse(NetCrypto.hex(sig.sublist(32)), radix: 16);
    return Uint8List.fromList([...sig.sublist(0, 32), ...NetCrypto.unhex((n - s).toRadixString(16).padLeft(64, '0'))]);
  }

  group('a signed entry', () {
    test('checks out for its author, space and place, and not when anything is changed', () async {
      final op = await signed(sam, FileOp.rename('a' * 32, 'plan.txt'), prev: 4, rv: 2);
      final c = FileOp.check(op, space: room, seq: 5, by: sam.id);
      expect(c.trust, OpTrust.signed);
      expect(c.rv, 2);
      // Read back with its keys in another order: the same.
      final shuffled = (jsonDecode(jsonEncode(Map.fromEntries(op.entries.toList().reversed))) as Map).cast<String, Object?>();
      expect(FileOp.check(shuffled, space: room, seq: 5, by: sam.id).trust, OpTrust.signed);
      expect(FileOp.check({...op, 'n': 'other.txt'}, space: room, seq: 5, by: sam.id).trust, OpTrust.bad, reason: 'what it says, changed');
      expect(FileOp.check(op, space: room, seq: 5, by: maya.id).trust, OpTrust.bad, reason: 'the relay putting another name on it');
      expect(FileOp.check(op, space: 'f' * 32, seq: 5, by: sam.id).trust, OpTrust.bad, reason: 'played into another space');
      expect(FileOp.check(op, space: room, seq: 3, by: sam.id).trust, OpTrust.bad, reason: 'before its author could have written it');
      expect(FileOp.check(op, space: room, seq: 9, by: sam.id).trust, OpTrust.moved, reason: 'later than its author put it');
      expect(FileOp.check(FileOp.rename('a' * 32, 'x'), space: room, seq: 1, by: sam.id).trust, OpTrust.unsigned);
      expect(FileOp.check({...FileOp.rename('a' * 32, 'x'), 'gs': 'AAAA'}, space: room, seq: 1, by: sam.id).trust, OpTrust.bad);
    });

    test('a list: replays, bad ones and unsigned ones in a signer\'s name are skipped; 0.9.2\'s read as before', () async {
      final a = file('a' * 32, sam.id), b = file('b' * 32, theo.id);
      final rename = await signed(sam, FileOp.rename(a.id, 'one.txt'), prev: 2);
      final list = FilesList.read([
        at(1, theo.id, FileOp.add(b)), // 0.9.2: unsigned, read as it was
        at(2, sam.id, await signed(sam, FileOp.add(a), prev: 1)),
        at(3, sam.id, rename),
        at(4, sam.id, await signed(sam, FileOp.rename(a.id, 'two.txt'), prev: 3)),
        at(5, sam.id, rename), // the first rename played again: misplaced, and seen before
        at(6, sam.id, FileOp.rename(a.id, 'forged.txt')), // unsigned in the name of someone who signs: not theirs
        at(7, theo.id, FileOp.rename(b.id, 'theirs.txt')), // 0.9.2's own author, still unsigned: theirs
        at(8, sam.id, {...await signed(sam, FileOp.move(a.id, 'X'), prev: 7), 'd': 'Y'}), // changed: bad
      ], const OwnerRules(null));
      expect(list.files[a.id]!.name, 'two.txt');
      expect(list.files[a.id]!.folder, isNull);
      expect(list.files[b.id]!.name, 'theirs.txt');
      expect(list.files[a.id]!.verified, isTrue, reason: 'added under its author\'s own signature');
      expect(list.files[b.id]!.verified, isFalse, reason: 'added by 0.9.2: the relay\'s word alone');
    });

    test('played again however its signature is written: once only', () async {
      final a = file('a' * 32, sam.id);
      final first = await signed(sam, FileOp.rename(a.id, 'one.txt'), prev: 2);
      final second = await signed(sam, FileOp.rename(a.id, 'two.txt'), prev: 3);
      final sig = base64Decode(first['gs'] as String);
      final asTwin = {...first, 'gs': base64Encode(twin(sig))};
      expect(FileOp.check(asTwin, space: room, seq: 3, by: sam.id).trust, OpTrust.signed, reason: 'the twin checks out');
      final urlSafe = {...first, 'gs': base64Url.encode(sig)};
      if (urlSafe['gs'] != first['gs']) {
        expect(FileOp.check(urlSafe, space: room, seq: 5, by: sam.id).trust, OpTrust.bad, reason: 'only the one way of writing it');
      }
      final list = FilesList.read([
        at(2, sam.id, await signed(sam, FileOp.add(a), prev: 1)),
        at(3, sam.id, first),
        at(4, sam.id, second),
        at(5, sam.id, asTwin), // the first again, as its twin: seen before
      ], const OwnerRules(null));
      expect(list.files[a.id]!.name, 'two.txt');
    });

    test('an entry naming bytes before it that aren\'t there is not believed; one that names them truly is', () async {
      final a = file('a' * 32, sam.id);
      final shown = [1, 2, 3], other = [4, 5, 6];
      LoggedOp sealedAt(int seq, String by, Map<String, Object?> op, List<int> sealed) =>
          LoggedOp(seq: seq, by: by, at: seq, op: op, sh: FileOp.sealedHash(sealed)).checked(room);
      final add = await FileOp.sign(FileOp.add(a), space: room, prev: 0, rv: 0, publicKey: sam.publicKey, sign: sam.sign);
      final truly = await FileOp.sign(FileOp.rename(a.id, 'true.txt'), space: room, prev: 1, prevHash: FileOp.sealedHash(shown), rv: 0, publicKey: sam.publicKey, sign: sam.sign);
      final forked = await FileOp.sign(FileOp.rename(a.id, 'fork.txt'), space: room, prev: 2, prevHash: FileOp.sealedHash(other), rv: 0, publicKey: sam.publicKey, sign: sam.sign);
      final list = FilesList.read([sealedAt(1, sam.id, add, shown), sealedAt(2, sam.id, truly, [7]), sealedAt(3, sam.id, forked, [8])], const OwnerRules(null));
      expect(list.files[a.id]!.name, 'true.txt');
    });

    test('moved by a relay that takes ?after=: not believed', () async {
      final a = file('a' * 32, sam.id);
      final add = await signed(sam, FileOp.add(a), prev: 0);
      final ren = await signed(sam, FileOp.rename(a.id, 'moved.txt'), prev: 1);
      LoggedOp line(int seq, Map<String, Object?> op, {bool cas = false}) => LoggedOp(seq: seq, by: sam.id, at: seq, op: op, cas: cas).checked(room);
      // Two written at once on a relay from before: believed as far as an unsigned one.
      expect(FilesList.read([line(1, add), line(3, ren)], const OwnerRules(null)).files[a.id]!.name, 'moved.txt');
      // The relay says it takes ?after=, or this device heard so before the entry came: moved by the relay.
      expect(FilesList.read([line(1, add), line(3, ren, cas: true)], const OwnerRules(null)).files[a.id]!.name, a.name);
      expect(FilesList.read([line(1, add), line(3, ren)], const OwnerRules(null), strictAfter: 1).files[a.id]!.name, a.name);
    });

    test('an unsigned entry put ahead of its author\'s first signed one, after what they had read: not theirs', () async {
      final a = file('a' * 32, theo.id);
      final list = FilesList.read([
        at(1, theo.id, FileOp.add(a)),
        at(2, sam.id, FileOp.rename(a.id, 'forged.txt')), // in Sam's name, though Sam had read entry 1 when he signed
        at(3, sam.id, await signed(sam, FileOp.folder('Plans'), prev: 1)), // moved: 2 was put in ahead of it
      ], RosterRules(await rosterAt(1, assigned: {sam.id: Role.moderator})));
      expect(list.files[a.id]!.name, a.name);
      expect(list.folders, {'Plans'});
    });
  });

  group('rules by roster revision', () {
    test('a moderator\'s delete stands after a demotion, and a demoted one can\'t sign under the roster from before', () async {
      final v1 = await rosterAt(1, assigned: {sam.id: Role.moderator}), v2 = await rosterAt(2);
      final f1 = file('1' * 32, theo.id), f2 = file('2' * 32, theo.id), f3 = file('3' * 32, theo.id);
      final log = [
        at(1, maya.id, await signed(maya, FileOp.roster(v1.toJson()), prev: 0, rv: 1)),
        at(2, theo.id, await signed(theo, FileOp.add(f1), prev: 1, rv: 1)),
        at(3, theo.id, await signed(theo, FileOp.add(f2), prev: 2, rv: 1)),
        at(4, theo.id, await signed(theo, FileOp.add(f3), prev: 3, rv: 1)),
        at(5, sam.id, await signed(sam, FileOp.delete(f1.id), prev: 4, rv: 1)), // a moderator then
        at(6, maya.id, await signed(maya, FileOp.roster(v2.toJson()), prev: 5, rv: 2)),
        at(7, sam.id, await signed(sam, FileOp.delete(f2.id), prev: 6, rv: 1)), // claims the old roster: v2 is in the log
      ];
      // Read today, with Sam demoted: the delete he made as a moderator stands; the one after does not.
      final today = FilesList.read(log, RosterRules(v2), rosters: logged, rulesVersion: 2);
      expect(today.files.keys, [f2.id, f3.id]);
      expect(today.rosterVersion, 2);
      // Without v2 in the log, the relay's word that it had believed v2 when the entry came does the same.
      final noV2 = [...log.take(5), at(6, sam.id, await signed(sam, FileOp.delete(f3.id), prev: 5, rv: 1), relayRv: 2)];
      expect(FilesList.read(noV2, RosterRules(v2), rosters: logged, rulesVersion: 2).files.keys, [f2.id, f3.id]);
      // 0.9.2's unsigned entries, from people who never signed: today's roles decide, as they always did.
      final oldWay = [at(1, theo.id, FileOp.add(f1)), at(2, theo.id, FileOp.add(f2)), at(3, sam.id, FileOp.delete(f1.id))];
      expect(FilesList.read(oldWay, RosterRules(v1), rosters: logged, rulesVersion: 1).files.keys, [f2.id], reason: 'a moderator today');
      expect(FilesList.read(oldWay, RosterRules(v2), rosters: logged, rulesVersion: 2).files.keys, [f1.id, f2.id], reason: 'a member today');
      // And once Theo signs, an unsigned entry in his name is not his.
      final afterSigning = [...log.take(4), at(5, theo.id, FileOp.delete(f3.id))];
      expect(FilesList.read(afterSigning, RosterRules(v2), rosters: logged, rulesVersion: 2).files.keys, [f1.id, f2.id, f3.id]);
    });

    test('a revision no roster has shown yet: only what both the newest shown and today\'s allow', () async {
      final v1 = await rosterAt(1), v2 = await rosterAt(2, assigned: {sam.id: Role.moderator});
      final f = file('1' * 32, theo.id), g = file('2' * 32, theo.id);
      final log = [
        at(1, maya.id, await signed(maya, FileOp.roster(v1.toJson()), prev: 0, rv: 1)),
        at(2, theo.id, await signed(theo, FileOp.add(f), prev: 1, rv: 1)),
        at(3, theo.id, await signed(theo, FileOp.add(g), prev: 2, rv: 1)),
        // A member, signing as if under version 2 before it was made: the promotion later doesn't make it good.
        at(4, sam.id, await signed(sam, FileOp.delete(f.id), prev: 3, rv: 2)),
        at(5, maya.id, await signed(maya, FileOp.roster(v2.toJson()), prev: 4, rv: 2)),
        // Under version 2, shown: a moderator's delete.
        at(6, sam.id, await signed(sam, FileOp.delete(g.id), prev: 5, rv: 2)),
      ];
      expect(FilesList.read(log, RosterRules(v2), rosters: logged, rulesVersion: 2).files.keys, [f.id]);
    });

    test('a roster in the log is believed only signed by the owner, and only newer than the last', () async {
      final v2 = await rosterAt(2, assigned: {sam.id: Role.moderator});
      final forged = await (await rosterAt(3, assigned: {sam.id: Role.admin})).signedBy(sam.id, sam.publicKey, sam.sign);
      final f = file('1' * 32, theo.id);
      final list = FilesList.read([
        at(1, maya.id, await signed(maya, FileOp.roster(v2.toJson()), prev: 0, rv: 2)),
        at(2, sam.id, await signed(sam, FileOp.roster(forged.toJson()), prev: 1, rv: 3)),
        at(3, theo.id, await signed(theo, FileOp.add(f), prev: 2, rv: 2)),
      ], RosterRules(await rosterAt(1)), rosters: logged, rulesVersion: 1);
      expect(list.rosterVersion, 2);
      expect(list.files.keys, [f.id]);
    });

    test('a demoted admin\'s roster doesn\'t follow the one that demoted them, nor skip ahead', () async {
      final ada = KeysSigner(NetKeys.generate());
      final grant = NetCrypto.hex(await maya.sign(Roster.grantMessage(owner, ada.id)));
      final v1 = await Roster.first(owner, kind: SpaceKind.files).next(assigned: {ada.id: Role.admin}, adminGrants: {ada.id: grant}).signedBy(maya.id, maya.publicKey, maya.sign);
      expect(v1.version, 1);
      final v2 = await v1.next(assigned: const {}).signedBy(maya.id, maya.publicKey, maya.sign); // Ada demoted
      Future<Roster> byAda(Roster from, {int skip = 0}) async {
        var r = from.next(assigned: {ada.id: Role.admin, sam.id: Role.moderator}, adminGrants: {ada.id: grant});
        for (var i = 0; i < skip; i++) {
          r = r.next();
        }
        return r.signedBy(ada.id, ada.publicKey, ada.sign);
      }

      final back = await byAda(v2);
      expect(back.trustedFor(owner), isTrue, reason: 'her grant can\'t be taken back, so her roster checks out');
      expect(FilesStore.chained(back, v2, v2), isFalse, reason: 'not an admin in the roster before it');
      expect(FilesStore.chained(back, v2, null), isFalse);
      final rival = await byAda(v1); // version 2, as if the owner's version 2 weren't there
      expect(FilesStore.chained(rival, v1, null), isTrue, reason: 'a device that knows only version 1 can\'t tell');
      expect(FilesStore.chained(rival, v1, v2), isFalse, reason: 'one that holds the owner\'s version 2 can');
      expect(FilesStore.chained(await byAda(v1, skip: 3), v1, null), isFalse, reason: 'an admin\'s roster goes one version on, no more');
      expect(FilesStore.chained(v2, v1, null), isTrue, reason: 'the owner\'s, at any version');
      expect(FilesStore.chained(await v2.next().next().signedBy(maya.id, maya.publicKey, maya.sign), v1, null), isTrue);
    });
  });

  group('devices and the relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    late FakeHub hub;
    late VoiceChannel space;
    final stores = <FilesStore>[];
    Roster? roster;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ghost-files-signed');
      hub = FakeHub();
      space = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Drop box', kind: SpaceKind.files, owner: owner);
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay')));
      base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
      roster = await rosterAt(1, assigned: {sam.id: Role.moderator});
    });

    tearDown(() async {
      for (final s in stores) {
        await s.clear();
      }
      stores.clear();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    FilesStore device(KeysSigner who, String name) {
      final s = FilesStore.forTest(base: base, signer: who, data: Directory('${dir.path}/$name'), route: FakeRoute(hub, who.id), name: name, piece: 2, roster: (_) => roster);
      stores.add(s);
      return s;
    }

    File fileOf(String name, Uint8List bytes) => File('${dir.path}/in/$name')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    test('entries go up signed, the roster first; a moderator\'s delete frees the blob on the relay', () async {
      final m = device(maya, 'Maya'), t = device(theo, 'Theo'), s = device(sam, 'Sam');
      await m.open(space); // the owner opens it first: the relay takes her key as its owner
      t.upload(space, [fileOf('notes.txt', bytesOf(5000, 1)).path]);
      await until(() => t.of(space).files.isNotEmpty, reason: '${t.transfers.firstOrNull?.error}');
      await s.open(space);
      final log = s.of(space).log;
      expect(log.map((e) => e.op?['t']), ['roster', 'add'], reason: 'the first writer under a newer roster puts it in first');
      expect(log.map((e) => e.trust), [OpTrust.signed, OpTrust.signed]);
      expect(log.last.rv, 1);
      final f = s.of(space).files.values.single;
      expect(s.canChange(space, f), isTrue, reason: 'a moderator over a member');
      final blobs = Directory('${dir.path}/relay/${FileSeal.filesRoom(space.seed)}/blobs');
      expect(blobs.listSync(), hasLength(1));
      expect(await s.delete(space, f), isTrue);
      await until(() => blobs.listSync().isEmpty, reason: 'the relay let the blob go for the moderator');
      await t.open(space);
      await until(() => t.of(space).files.isEmpty);
    });

    test('a 0.9.2 device\'s unsigned entries are read, as unverified, beside signed ones', () async {
      final m = device(maya, 'Maya');
      await m.open(space);
      // Written the way 0.9.2 writes: sealed, unsigned, no ?after=.
      final old = FilesApi(base: base, space: FileSeal.filesRoom(space.seed), token: FileSeal.filesToken(space.seed), signer: theo);
      await old.ensure();
      final f = file('c' * 32, theo.id);
      await old.append(FileOp.seal(FileSeal.filesKey(space.seed), FileOp.add(f)));
      old.close();
      expect(await m.newFolder(space, 'Plans'), isTrue);
      await m.of(space).refresh();
      expect(m.of(space).files.keys, [f.id]);
      expect(m.of(space).files[f.id]!.by, theo.id);
      expect(m.of(space).folders, {'Plans'});
      final trust = <Object?, OpTrust>{for (final e in m.of(space).log) (e.op?['t']): e.trust};
      expect(trust['add'], OpTrust.unsigned);
      expect(trust['dir'], OpTrust.signed);
    });

    test('a member\'s roster in the log that reuses the real one\'s signature is not believed', () async {
      final m = device(maya, 'Maya'), s = device(sam, 'Sam');
      await m.open(space);
      s.upload(space, [fileOf('plan.txt', bytesOf(3000, 2)).path]);
      await until(() => s.of(space).files.isNotEmpty, reason: '${s.transfers.firstOrNull?.error}');
      await m.of(space).refresh();
      expect(m.of(space).files, hasLength(1));
      expect(m.of(space).log.first.op?['t'], 'roster');
      // Theo, a member with the files key, puts in version 2 naming himself a moderator and banning Sam, under version 1's
      // signature, and then deletes Sam's file under it.
      final rj = {...roster!.toJson(), 'v': 2, 'a': {theo.id: Role.moderator}, 'b': [sam.id]};
      final api = FilesApi(base: base, space: FileSeal.filesRoom(space.seed), token: FileSeal.filesToken(space.seed), signer: theo);
      final key = FileSeal.filesKey(space.seed), roomName = FileSeal.filesRoom(space.seed);
      var seq = m.of(space).seq;
      Future<void> write(Map<String, Object?> op, int rv) async {
        seq = await api.append(FileOp.seal(key, await FileOp.sign(op, space: roomName, prev: seq, rv: rv, publicKey: theo.publicKey, sign: theo.sign)), after: seq);
      }

      await write(FileOp.roster(rj), 2);
      await write(FileOp.delete(m.of(space).files.keys.single), 2);
      api.close();
      await m.of(space).refresh();
      expect(m.of(space).files, hasLength(1), reason: 'the forged roster was not believed, so Theo\'s delete wasn\'t');
    });

    test('a relay whose list started again (swept, or its data lost): writes still land, from its start', () async {
      final m = device(maya, 'Maya');
      await m.open(space);
      expect(await m.newFolder(space, 'Before'), isTrue);
      expect(m.of(space).seq, greaterThan(0));
      final port = base.port;
      await relay.stop();
      await Directory('${dir.path}/relay/${FileSeal.filesRoom(space.seed)}').delete(recursive: true);
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay')));
      await relay.start(port: port);
      expect(await m.newFolder(space, 'After'), isTrue, reason: '${m.of(space).error}');
      expect(m.of(space).folders, {'After'});
      // And swept while the app was closed: a device opening it again starts from the relay's start too.
      final again = device(maya, 'Maya2');
      final kept = Directory('${dir.path}/Maya2/spaces')..createSync(recursive: true);
      File('${kept.path}/${FileSeal.filesRoom(space.seed)}.json').writeAsStringSync(jsonEncode({'seq': 40, 'log': const []}));
      await again.open(space);
      expect(again.of(space).seq, m.of(space).seq);
      expect(await again.newFolder(space, 'Later'), isTrue, reason: '${again.of(space).error}');
    });

    test('a roster changed on the owner\'s device reaches the relay and the log at once, not as the roster itself', () async {
      final m = device(maya, 'Maya');
      await m.open(space);
      final room = FileSeal.filesRoom(space.seed);
      Map meta() => jsonDecode(File('${dir.path}/relay/$room/meta.json').readAsStringSync()) as Map;
      await until(() => meta()['rv'] == 1);
      roster = await rosterAt(2);
      await m.pushRoster(space);
      expect(m.of(space).log.last.op?['t'], 'roster');
      expect(m.of(space).log.last.op?['r'], isA<Map>());
      expect((m.of(space).log.last.op!['r'] as Map)['v'], 2);
      await until(() => meta()['rv'] == 2);
      expect(meta()['rh'], NetCrypto.hex(NetCrypto.sha256(roster!.signed)));
      expect(meta().toString(), isNot(contains(sam.id)), reason: 'the relay is told the revision, not who has which role');
    });

    test('two devices writing at once: each entry is signed for the place it lands in', () async {
      final m = device(maya, 'Maya'), t = device(theo, 'Theo');
      await m.open(space);
      await t.open(space);
      final ok = await Future.wait([for (var i = 0; i < 4; i++) m.newFolder(space, 'M$i'), for (var i = 0; i < 4; i++) t.newFolder(space, 'T$i')]);
      expect(ok, everyElement(isTrue));
      await m.of(space).refresh();
      expect(m.of(space).folders, hasLength(8));
      expect(m.of(space).log.where((e) => e.op?['t'] == 'dir').map((e) => e.trust).toSet(), {OpTrust.signed});
    });
  });
}
