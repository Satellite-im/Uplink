import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/files/files_api.dart' show FilesError;
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/mentions.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Hangouts' chat and roles (lib/voice/hangout.dart, lib/voice/roles.dart). Matt, 2026-11-15: "Implement a
/// permissions system similar to discord for hangouts and add a chat to hangouts so the whole group can send messages
/// to the hangout as well as voice and video, make default roles such as admin, moderator, member".
///
/// The hub is stood in for (rooms: join, leave, a packet to everyone else, who came and went), as in
/// voice_channels_test, and each install has a real key, so rosters are really signed and checked.
class _Hub {
  final Map<String, Map<String, _Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  /// Everything this install sent, to see a forged packet go in.
  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= {};
    final others = r.keys.toList();
    r[me] = this;
    for (final o in r.values) {
      if (o != this) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    r?.remove(me);
    for (final o in r?.values ?? const <_Route>[]) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    for (final o in hub.rooms[room]?.values ?? const <_Route>[]) {
      if (o != this) scheduleMicrotask(() => o._packets.add((room: room, from: me, bytes: bytes)));
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

/// A chat's files sent up nowhere: each named in [failing] fails, the rest come back as a file at once.
class _Uploads implements ChatUploads {
  final Set<String> failing = {};
  final Map<String, int> asked = {};
  final List<String> dropped = [];
  int? thumbMost;

  @override
  Future<SpaceFile> uploadForChat(VoiceChannel c, OutgoingFile f, {required String byName, required int thumbMost, required void Function() moved}) async {
    asked[f.name] = (asked[f.name] ?? 0) + 1;
    this.thumbMost = thumbMost;
    f.progress = 0.5;
    moved();
    if (failing.contains(f.name)) throw FilesError(0, 'Can\'t reach the files server.');
    return SpaceFile(id: NetCrypto.hex(NetCrypto.randomBytes(16)), name: f.name, size: f.size, mime: f.mime, sha: '', key: NetCrypto.randomBytes(32), prefix: NetCrypto.randomBytes(8), by: c.owner, byName: byName, at: 0);
  }

  @override
  void drop(OutgoingFile f) => dropped.add(f.name);
}

class _Install {
  _Install(this.hub, this.name) : keys = NetKeys.generate();
  final _Hub hub;
  final String name;
  final NetKeys keys;
  final store = MemoryHangoutStore();
  late final route = _Route(hub, keys.id);
  String get id => keys.id;
  String get key => NetCrypto.hex(keys.public);

  HangoutRoom room(VoiceChannel c) => HangoutRoom(channel: c, route: route, name: name, signer: KeysSigner(keys), store: store);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Hub hub;
  late _Install owner, ann, bob, cat;
  late VoiceChannel channel;

  setUp(() {
    hub = _Hub();
    owner = _Install(hub, 'Matt');
    ann = _Install(hub, 'Ann');
    bob = _Install(hub, 'Bob');
    cat = _Install(hub, 'Cat');
    channel = VoiceChannel.make('Friday hang', owner: owner.key);
  });

  group('roles', () {
    test('a hangout starts with admin, moderator and member; the owner can do anything, a newcomer is a member', () {
      final r = Roster.first(owner.key);
      expect(r.ranked.map((x) => x.id), [Role.admin, Role.moderator, Role.member]);
      expect(r.isOwner(owner.id), isTrue);
      expect(r.roleOf(owner.id).id, Role.admin);
      expect(r.roleOf(ann.id).id, Role.member);
      for (final p in Perm.values) {
        expect(r.can(owner.id, p), isTrue, reason: '$p');
      }
      expect(r.can(ann.id, Perm.speak), isTrue);
      expect(r.can(ann.id, Perm.chat), isTrue);
      expect(r.can(ann.id, Perm.removeMembers), isFalse);
      expect(r.can(ann.id, Perm.ban), isFalse);
      // A moderator: mute, remove and delete messages; not ban, not roles.
      final mod = r.next(assigned: {bob.id: Role.moderator});
      expect(mod.can(bob.id, Perm.muteOthers), isTrue);
      expect(mod.can(bob.id, Perm.removeMembers), isTrue);
      expect(mod.can(bob.id, Perm.manageMessages), isTrue);
      expect(mod.can(bob.id, Perm.ban), isFalse);
      expect(mod.canManage(bob.id), isFalse);
      expect(mod.outranks(bob.id, ann.id), isTrue);
      expect(mod.outranks(ann.id, bob.id), isFalse);
      expect(mod.outranks(bob.id, owner.id), isFalse, reason: 'no one acts on the owner');
    });

    test('a roster is believed only when the owner, or an admin the owner made, signed it', () async {
      final first = Roster.first(owner.key);
      final byOwner = await first.next(assigned: {ann.id: Role.moderator}).signedBy(owner.id, owner.keys.public, (m) async => NetCrypto.sign(owner.keys, m));
      expect(byOwner.trustedFor(owner.key), isTrue);
      expect(Roster.fromJson(byOwner.toJson())!.trustedFor(owner.key), isTrue, reason: 'it travels as JSON');

      // Ann signs one making herself admin: not believed, she was never granted it.
      final forged = await byOwner.next(assigned: {ann.id: Role.admin}).signedBy(ann.id, ann.keys.public, (m) async => NetCrypto.sign(ann.keys, m));
      expect(forged.trustedFor(owner.key), isFalse);
      // One changed after it was signed: not believed.
      final changed = Roster.fromJson({...byOwner.toJson(), 'b': [owner.id]})!;
      expect(changed.trustedFor(owner.key), isFalse);
      // Signed by the owner of another hangout: not this one's.
      expect(byOwner.trustedFor(bob.key), isFalse);

      // The owner makes Bob an admin (a grant only the owner can sign); Bob's own rosters are then believed.
      final grant = NetCrypto.hex(NetCrypto.sign(owner.keys, Roster.grantMessage(owner.key, bob.id)));
      final withBob = await byOwner.next(assigned: {...byOwner.assigned, bob.id: Role.admin}, adminGrants: {bob.id: grant}).signedBy(owner.id, owner.keys.public, (m) async => NetCrypto.sign(owner.keys, m));
      expect(withBob.trustedFor(owner.key), isTrue);
      final bobs = await withBob.next(assigned: {...withBob.assigned, cat.id: Role.moderator}).signedBy(bob.id, bob.keys.public, (m) async => NetCrypto.sign(bob.keys, m));
      expect(bobs.trustedFor(owner.key), isTrue);
      // But Bob can't make Cat an admin: he has no grant to give.
      final bobMakesAdmin = await withBob.next(assigned: {...withBob.assigned, cat.id: Role.admin}).signedBy(bob.id, bob.keys.public, (m) async => NetCrypto.sign(bob.keys, m));
      expect(bobMakesAdmin.trustedFor(owner.key), isFalse);
      // A grant copied to someone else is not theirs.
      final stolen = await withBob.next(assigned: {...withBob.assigned, cat.id: Role.admin}, adminGrants: {...withBob.adminGrants, cat.id: grant}).signedBy(owner.id, owner.keys.public, (m) async => NetCrypto.sign(owner.keys, m));
      expect(stolen.trustedFor(owner.key), isFalse);
    });

    test('a hangout from before roles: everyone a member, no one can change anything', () {
      final r = Roster.first('');
      expect(r.can(ann.id, Perm.speak), isTrue);
      expect(r.can(ann.id, Perm.ban), isFalse);
      expect(r.canManage(ann.id), isFalse);
    });
  });

  group('chat', () {
    test('the whole hangout sees what is written, and someone coming in later gets what they missed', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      expect(o.present[ann.id]?.name, 'Ann');
      expect(a.present[owner.id]?.name, 'Matt');
      // The song someone plays to the call is in their greeting, while they are in the call; said to the space, sealed.
      o.sayMusic('Bones');
      await _settle();
      expect(a.musicInCall, isNull, reason: 'not in the call');
      o.sayMe(inVoice: true);
      await _settle();
      expect(a.musicInCall, 'Bones');
      o.sayMusic('x' * 500);
      await _settle();
      expect(a.musicInCall!.length, HangoutPerson.musicMost);
      o.sayMusic('');
      await _settle();
      expect(a.musicInCall, isNull);
      // And what they show the call, their camera or their screen (GMFB-66), in the same greeting.
      expect(a.present[owner.id]!.camera, isFalse);
      o.sayPicture(camera: true, screen: false);
      await _settle();
      expect((a.present[owner.id]!.camera, a.present[owner.id]!.screen), (true, false));
      o.sayPicture(camera: true, screen: true);
      await _settle();
      expect((a.present[owner.id]!.camera, a.present[owner.id]!.screen), (false, true), reason: 'a screen is sent in the camera\'s place');
      o.sayMe(inVoice: false);
      await _settle();
      expect((a.present[owner.id]!.camera, a.present[owner.id]!.screen), (false, false), reason: 'out of the call, nothing shown');

      expect(o.send('Who is around?'), isTrue);
      // The answer is written a moment later, as a person's would be: two messages in the same millisecond have no
      // order of their own, and every device puts them in the same one by id (HangoutRoom._add), which need not be
      // the order they were written in. Sent back to back here they sometimes shared a millisecond.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(a.send('Me!'), isTrue);
      await _settle();
      expect(o.messages.map((m) => m.text), ['Who is around?', 'Me!']);
      expect(a.messages.map((m) => m.text), ['Who is around?', 'Me!']);
      expect(a.messages.first.from, owner.id);

      // Bob comes later: one copy of the history, from the lowest id there, not one from each.
      final b = bob.room(channel);
      await b.open();
      await _settle();
      expect(b.messages.map((m) => m.text), ['Who is around?', 'Me!']);
    });

    test('a thread (GMFB-36): its replies reach everyone in it, off the chat, quoting where they hang for builds from before', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      expect(o.send('Plans for Friday?'), isTrue);
      await _settle();
      final root = a.messages.single;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(a.send('Dinner at 7', thread: root.id), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(o.send('Works for me', thread: root.id), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(a.send('Also: who has the key?'), isTrue);
      await _settle();
      for (final r in [o, a]) {
        expect(r.timeline.map((m) => m.text), ['Plans for Friday?', 'Also: who has the key?']);
        expect(r.threadOf(root.id).map((m) => m.text), ['Dinner at 7', 'Works for me']);
        expect(r.threads[root.id]!.count, 2);
        expect(r.threads[root.id]!.last.text, 'Works for me');
      }
      // Each quotes the message it hangs from, which is what a build that knows nothing of threads shows.
      final reply = o.threadOf(root.id).first;
      expect(reply.reply?.id, root.id);
      expect(reply.reply?.text, 'Plans for Friday?');
      // As it travels, and as a build from before reads it: `th` kept, and a message can't be its own thread.
      final wire = reply.toJson();
      expect(wire['th'], root.id);
      expect(HangoutMessage.fromJson({...wire}, ann.id)!.thread, root.id);
      expect(HangoutMessage.fromJson({...wire, 'th': wire['id']}, ann.id)!.thread, isNull);
      // Someone coming in later has the thread too.
      final b = bob.room(channel);
      await b.open();
      await _settle();
      expect(b.threadOf(root.id).length, 2);
      expect(b.timeline.length, 2);
    });

    test('a member deletes their own message; a moderator deletes anyone\'s below them; a member can\'t delete others\'', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      for (final r in [o, a, b]) {
        await r.open();
      }
      await _settle();
      a.send('first');
      b.send('second');
      await _settle();
      // Ann tries Bob's: not hers, she can't.
      final bobs = a.messages.firstWhere((m) => m.text == 'second');
      expect(a.canDelete(bobs), isFalse);
      // Ann deletes her own.
      a.delete(a.messages.firstWhere((m) => m.text == 'first'));
      await _settle();
      expect(o.messages.map((m) => m.text), ['second']);
      // The owner makes Ann a moderator; she deletes Bob's, everywhere.
      expect(await o.setRole(ann.id, Role.moderator), isTrue);
      await _settle();
      expect(a.roster.roleOf(ann.id).id, Role.moderator);
      expect(a.canDelete(bobs), isTrue);
      a.delete(bobs);
      await _settle();
      expect(b.messages, isEmpty);
      expect(o.messages, isEmpty);
    });

    test('a role without Send messages can\'t write, and what it sends anyway is not shown', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      final member = o.roster.roleById(Role.member)!;
      expect(await o.saveRole(member.copyWith(perms: {...member.perms}..remove(Perm.chat))), isTrue);
      await _settle();
      expect(a.can(Perm.chat), isFalse);
      expect(a.send('hello?'), isFalse);
      expect(o.messages, isEmpty);
    });
  });

  // Matt, 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other
  // chats".
  group('files and stickers', () {
    SpaceFile file(String name, {int size = 2048, Uint8List? thumb, int w = 0, int h = 0}) => SpaceFile(
          id: NetCrypto.hex(NetCrypto.randomBytes(16)),
          name: name,
          size: size,
          mime: FileKind.mimeOf(name),
          sha: NetCrypto.hex(NetCrypto.randomBytes(32)),
          key: NetCrypto.randomBytes(32),
          prefix: NetCrypto.randomBytes(8),
          by: '',
          byName: '',
          at: 0,
          thumb: thumb,
          width: w,
          height: h,
        );

    test('files and a sticker reach the others with their words; a build from before reads a line saying what came', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      final photo = file('photo.jpg', thumb: Uint8List.fromList(List.filled(300, 7)), w: 1200, h: 800), report = file('report.pdf', size: 90000);
      expect(o.sendWith(text: 'From Friday', files: [photo, report]), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(o.sendWith(sticker: 'love-03'), isTrue);
      await _settle();
      expect(a.messages, hasLength(2));
      final got = a.messages.first;
      expect(got.text, 'From Friday');
      expect(got.files.map((f) => f.name), ['photo.jpg', 'report.pdf']);
      expect(got.files.first.by, owner.id, reason: 'who added it is who the hub says sent the message');
      expect(got.files.first.byName, 'Matt');
      expect(got.files.first.id, photo.id);
      expect(got.files.first.key, photo.key);
      expect(got.files.first.sha, photo.sha);
      expect(got.files.first.thumb, photo.thumb);
      expect((got.files.first.width, got.files.first.height), (1200, 800));
      expect(got.files.last.size, 90000);
      expect(a.messages.last.sticker, 'love-03');
      expect(a.messages.last.text, isEmpty);

      // On the wire: `x` is what a build from before shows (it reads only id, x, at, n and drops a message whose x is
      // empty), so it says what came.
      final wire = got.toJson();
      expect(wire['x'], '📎 photo.jpg, report.pdf\nFrom Friday');
      expect(wire['w'], 'From Friday');
      expect(a.messages.last.toJson()['x'], 'Sticker');
      expect(a.messages.last.toJson().containsKey('a'), isFalse, reason: 'a sticker goes by its name; nothing went up');
      // As 0.9.13 reads it: the fallback words, and nothing else.
      final old = HangoutMessage.fromJson({'id': wire['id'], 'x': wire['x'], 'at': wire['at'], 'n': wire['n']}, owner.id)!;
      expect(old.text, '📎 photo.jpg, report.pdf\nFrom Friday');
      expect(old.files, isEmpty);

      // Kept on the device and read back the same (AppHangoutStore keeps toStored()).
      final back = HangoutMessage.fromJson(jsonDecode(jsonEncode(got.toStored())) as Map<String, dynamic>, owner.id)!;
      expect(back.files.map((f) => (f.id, f.name, f.size, f.mime)), got.files.map((f) => (f.id, f.name, f.size, f.mime)));
      expect(back.text, 'From Friday');
      expect(back.summary, '📎 photo.jpg, report.pdf · From Friday');
    });

    // Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user prefix".
    test('a mention reaches everyone with the words, and only the one meant is mentioned', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      await o.open();
      await a.open();
      await b.open();
      await _settle();
      // Written with space round it in the composer: counted from the words as sent.
      expect(o.send('  @Ann are you in?  ', mentions: [Mention(2, 4, ann.id)]), isTrue);
      await _settle();
      for (final r in [o, a, b]) {
        final m = r.messages.single;
        expect(m.text, '@Ann are you in?');
        expect(m.mentions, [Mention(0, 4, ann.id)]);
      }
      expect(a.messages.single.mentionsOf(ann.id), isTrue);
      expect(b.messages.single.mentionsOf(bob.id), isFalse);
      // Someone coming in later gets it with its mention, from the history.
      final c = cat.room(channel);
      await c.open();
      await _settle();
      expect(c.messages.single.mentions, [Mention(0, 4, ann.id)]);
    });

    test('a mention that the words do not show is not believed, and a build from before reads the name as words', () {
      final m = HangoutMessage.fromJson({'id': 'a', 'x': 'hey @Ann', 'at': 1, 'n': 'Bob', 'mn': [[4, 4, ann.id], [0, 3, cat.id], [4, 40, cat.id]]}, bob.id)!;
      expect(m.mentions, [Mention(4, 4, ann.id)], reason: 'only the one at an @ in the words');
      expect(m.mentionsOf(cat.id), isFalse, reason: 'Cat is named nowhere in the words: no hidden call');
      final sent = HangoutMessage(id: 'b', from: bob.id, name: 'Bob', text: 'hey @Ann', at: 1, mentions: const [Mention(4, 4, 'aa')]);
      final wire = sent.toJson();
      expect(wire['x'], 'hey @Ann', reason: 'what a build from before reads');
      expect(wire['mn'], [[4, 4, 'aa']]);
      expect(HangoutMessage(id: 'c', from: bob.id, name: 'Bob', text: 'plain', at: 1).toJson().containsKey('mn'), isFalse);
      // With words that came with space round them, and with files, where the words are `w`.
      expect(HangoutMessage.fromJson({'id': 'd', 'x': '  @Ann hi', 'at': 1, 'mn': [[2, 4, ann.id]]}, bob.id)!.mentions, [Mention(0, 4, ann.id)]);
      final withFiles = HangoutMessage.fromJson({'id': 'e', 'x': 'Sticker\n@Ann', 'w': '@Ann', 'st': 'love-03', 'at': 1, 'mn': [[0, 4, ann.id]]}, bob.id)!;
      expect(withFiles.mentions, [Mention(0, 4, ann.id)]);
      // Words cut short to the most a message holds take the mentions past the cut with them.
      final long = '${'a' * 3998} @Ann';
      expect(HangoutMessage.fromJson({'id': 'f', 'x': long, 'at': 1, 'mn': [[3999, 4, ann.id]]}, bob.id)!.mentions, isEmpty);
    });

    test('a mention of someone\'s phone is a mention of their paired computer too, known by the same username', () async {
      // Ann's phone and her computer, two installs that say one username.
      final phone = ann.room(channel)..username = 'ann';
      final desk = _Install(hub, 'Ann').room(channel)..username = 'ann';
      final o = owner.room(channel);
      await phone.open();
      await desk.open();
      await o.open();
      await _settle();
      expect(o.send('@Ann look', mentions: [Mention(0, 4, ann.id)]), isTrue);
      await _settle();
      expect(phone.mentionsMe(phone.messages.single), isTrue);
      expect(desk.mentionsMe(desk.messages.single), isTrue, reason: 'her computer heard her phone say its username');
      expect(o.mentionsMe(o.messages.single), isFalse);
      // Written on her phone, naming her computer: hers, not news to her.
      expect(phone.send('@Ann note to self', mentions: [Mention(0, 4, desk.me)]), isTrue);
      await _settle();
      expect(desk.mentionsMe(desk.messages.last), isFalse);
    });

    test('the chat says what it took in that it did not have, once', () async {
      final o = owner.room(channel), a = ann.room(channel);
      final heard = <String>[];
      a.onFresh = (fresh) => heard.addAll(fresh.map((m) => m.text));
      await o.open();
      await a.open();
      await _settle();
      expect(o.send('one'), isTrue);
      await _settle();
      expect(heard, ['one']);
    });

    test('a message from a build from before still reads, and one whose files can\'t be read shows its line', () {
      expect(HangoutMessage.fromJson({'id': 'a', 'x': 'hello', 'at': 1, 'n': 'Ann'}, ann.id)!.text, 'hello');
      expect(HangoutMessage.fromJson({'id': 'a', 'x': '', 'at': 1, 'n': 'Ann'}, ann.id), isNull);
      final broken = HangoutMessage.fromJson({'id': 'b', 'x': '📎 a.png', 'w': '', 'a': [{'id': 'nope'}], 'at': 1}, ann.id)!;
      expect(broken.files, isEmpty);
      expect(broken.text, '📎 a.png');
      expect(HangoutMessage.fromJson({'id': 'c', 'x': 'Sticker', 'st': '../../etc', 'at': 1}, ann.id)!.sticker, isNull, reason: 'a sticker name is a pack and a number, nothing else');
      final voice = HangoutMessage(id: 'v', from: ann.id, name: 'Ann', text: '', at: 1, files: [file('voice.m4a')], voice: true);
      expect(voice.toJson()['x'], '🎤 Voice message');
      expect(HangoutMessage.fromJson(voice.toJson(), ann.id)!.voice, isTrue);
    });

    test('a message too big for one packet lets its small pictures go; what was missed comes in lots that each fit', () {
      final big = [for (var i = 0; i < 10; i++) file('p$i.png', thumb: Uint8List.fromList(List.generate(SpaceFile.maxThumb, (j) => (i * 31 + j) & 0xff)))];
      final m = HangoutRoom.fitted(HangoutMessage(id: 'x', from: owner.id, name: 'Matt', text: 'lots', at: 1, files: big));
      expect(utf8.encode(jsonEncode({'t': 'msg', ...m.toJson()})).length, lessThanOrEqualTo(HangoutRoom.wireMost));
      expect(m.files, hasLength(10), reason: 'every file still goes');
      expect(m.files.where((f) => f.thumb != null), isNotEmpty, reason: 'as many pictures as fit stay');
      final lots = HangoutRoom.histLots([for (var i = 0; i < 6; i++) HangoutMessage(id: '$i', from: owner.id, name: 'Matt', text: '', at: i, files: m.files)]);
      expect(lots.length, greaterThan(1));
      expect(lots.expand((l) => l).length, 6);
      for (final l in lots) {
        expect(utf8.encode(jsonEncode({'t': 'hist', 'to': ann.id, 'm': l})).length, lessThan(HangoutRoom.wireMost + 1024));
      }
    });

    test('files go up first, then the message; one that fails is kept with a try again; someone who may not write sends nothing', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      final dir = await Directory.systemTemp.createTemp('space-files');
      addTearDown(() => dir.delete(recursive: true));
      final one = File('${dir.path}/beach.gif')..writeAsBytesSync(List.filled(4000, 1));
      final two = File('${dir.path}/notes.txt')..writeAsBytesSync(List.filled(10, 2));
      final up = _Uploads()..failing.add('notes.txt');
      final sent = a.sendFiles([(path: one.path, owned: false), (path: two.path, owned: false)], up, text: 'Look');
      expect(sent, isNotNull);
      expect(a.outgoing, [sent]);
      await _settle();
      expect(sent!.failed, isTrue);
      expect(sent.retryable, isTrue);
      expect(o.messages, isEmpty, reason: 'nothing is said until every file is there');
      expect(up.asked['beach.gif'], 1);
      expect(up.thumbMost, lessThanOrEqualTo(SpaceFile.maxThumb));

      up.failing.clear();
      a.retry(sent, up);
      await _settle();
      expect(a.outgoing, isEmpty);
      expect(up.asked['beach.gif'], 1, reason: 'the one that went up is not sent again');
      expect(up.asked['notes.txt'], 2);
      expect(o.messages.single.files.map((f) => f.name), ['beach.gif', 'notes.txt']);
      expect(o.messages.single.text, 'Look');
      expect(o.messages.single.id, sent.id);
      expect(a.messages.single.id, sent.id);

      // Not sent after all: its files are let go of.
      final gone = a.sendFiles([(path: two.path, owned: false)], up..failing.add('notes.txt'));
      await _settle();
      a.discard(gone!, up);
      expect(a.outgoing, isEmpty);
      expect(up.dropped, ['notes.txt']);

      // A role without Send messages: no files, no sticker (the rule: HangoutRoom.mayWrite).
      final member = o.roster.roleById(Role.member)!;
      expect(await o.saveRole(member.copyWith(perms: {...member.perms}..remove(Perm.chat))), isTrue);
      await _settle();
      expect(a.mayWrite, isFalse);
      expect(a.sendFiles([(path: one.path, owned: false)], up), isNull);
      expect(a.sendWith(sticker: 'love-03'), isFalse);
    });
  });

  group('moderation', () {
    test('the roster reaches someone who comes in later, and a forged one sent to the room is ignored', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      expect(await o.setRole(ann.id, Role.moderator), isTrue);
      await o.close();
      await _settle();
      // The owner is gone; Bob comes in and takes the roster from Ann.
      final b = bob.room(channel);
      await b.open();
      await _settle();
      expect(b.roster.version, o.roster.version);
      expect(b.roster.roleOf(ann.id).id, Role.moderator);

      // Cat signs a roster making himself admin and banning Ann: no one takes it.
      final c = cat.room(channel);
      await c.open();
      await _settle();
      final forged = await b.roster.next(assigned: {cat.id: Role.admin}, banned: {ann.id}).signedBy(cat.id, cat.keys.public, (m) async => NetCrypto.sign(cat.keys, m));
      expect(await c.setRole(ann.id, Role.member), isFalse, reason: 'a member can\'t change roles');
      expect(await c.ban(ann.id), isFalse);
      // Sent by hand, as a modified app would.
      cat.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'roster', 'r': forged.toJson()}))));
      cat.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'kick', 'to': ann.id}))));
      await _settle();
      expect(b.roster.banned, isEmpty);
      expect(a.putOut, isNull);
    });

    test('a moderator removes a member, who leaves; a member can\'t remove anyone', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      for (final r in [o, a, b]) {
        await r.open();
      }
      await _settle();
      expect(b.remove(ann.id), isFalse);
      await o.setRole(bob.id, Role.moderator);
      await _settle();
      expect(b.remove(ann.id), isTrue);
      await _settle();
      expect(a.putOut, contains('removed'));
      // And she can't remove him back.
      expect(a.remove(bob.id), isFalse);
    });

    test('a ban keeps someone out for good: put out now, their messages not shown, refused next time', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      for (final r in [o, a, b]) {
        await r.open();
      }
      await _settle();
      expect(await o.ban(bob.id), isTrue);
      await _settle();
      expect(b.putOut, contains('banned'));
      expect(a.roster.banned, contains(bob.id));
      expect(b.send('let me back'), isFalse);
      await b.close();
      await _settle();
      final again = bob.room(channel);
      await again.open();
      expect(again.putOut, contains('banned'), reason: 'his own device kept the roster that bans him');
    });

    test('muted for everyone: a moderator\'s mute holds while they are there, an admin\'s stands in the roster', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      for (final r in [o, a, b]) {
        await r.open();
      }
      await _settle();
      await o.setRole(ann.id, Role.moderator);
      await _settle();
      expect(await a.muteForAll(bob.id, true), isTrue);
      await _settle();
      expect(o.heard(bob.id), isFalse);
      expect(b.heard(bob.id), isFalse, reason: 'his own device locks his microphone');
      await a.muteForAll(bob.id, false);
      await _settle();
      expect(o.heard(bob.id), isTrue);
      // The owner's mute is in the roster.
      expect(await o.muteForAll(bob.id, true), isTrue);
      await _settle();
      expect(a.roster.muted, contains(bob.id));
      expect(a.heard(bob.id), isFalse);
      // A moderator can't unmute what an admin muted in the roster: the roster still says so.
      await a.muteForAll(bob.id, false);
      await _settle();
      expect(o.heard(bob.id), isFalse);
    });

    // GMFB-49 (Kevin: "admins/ moderators can mute users if needed while not allowing that user to unmute themselves").
    test('a moderator\'s mute holds for someone who comes in later, the muted can\'t lift it, and an admin can', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      for (final r in [o, a, b]) {
        await r.open();
      }
      await _settle();
      await o.setRole(ann.id, Role.moderator);
      await _settle();
      expect(await a.muteForAll(bob.id, true), isTrue);
      await _settle();
      expect(b.mutedForAll(bob.id), isTrue);
      expect(b.micLockedWhy, contains('muted you for everyone'));
      expect(a.micLockedWhy, isNull);
      // He can't unmute himself, whatever his app says to the room.
      expect(await b.muteForAll(bob.id, false), isFalse);
      bob.route.send(channel.chatRoom, NetCrypto.seal(channel.key, utf8.encode(jsonEncode({'t': 'mute', 'who': bob.id, 'on': false}))));
      await _settle();
      expect(o.heard(bob.id), isFalse);
      // Cat comes in afterwards: her app silences him too.
      final c = cat.room(channel);
      await c.open();
      await _settle();
      expect(c.heard(bob.id), isFalse, reason: 'told of the mute by the moderator there');
      expect(c.mutedForAll(bob.id), isTrue);
      // The owner lifts the moderator's mute: everyone hears him again.
      expect(o.mutedForAll(bob.id), isTrue);
      expect(await o.muteForAll(bob.id, false), isTrue);
      await _settle();
      for (final r in [o, a, b, c]) {
        expect(r.heard(bob.id), isTrue);
        expect(r.mutedForAll(bob.id), isFalse);
      }
      expect(b.micLockedWhy, isNull);
    });

    test('an admin edits a role and adds one; the newcomers\' role can be changed', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      expect(await o.saveRole(const Role(id: 'dj', name: 'DJ', rank: 15, perms: {Perm.speak, Perm.chat, Perm.video})), isTrue);
      expect(await o.setNewcomer('dj'), isTrue);
      await _settle();
      expect(a.roster.ranked.map((r) => r.name), ['Admin', 'Moderator', 'DJ', 'Member']);
      expect(a.roster.roleOf(ann.id).id, 'dj');
      expect(a.can(Perm.invite), isFalse);
      // Admin keeps every permission whatever is saved: every one a space of this kind has. Adding and managing files
      // are a Files space's alone (Perm.of, HangoutRoom.saveRole), so this voice space's admin is not given them; the
      // test asked for Perm.values from before those two were added.
      await o.saveRole(o.roster.roleById(Role.admin)!.copyWith(perms: {Perm.chat}));
      expect(o.roster.roleById(Role.admin)!.perms, Perm.of(channel.kind));
      expect(o.roster.roleById(Role.admin)!.perms.intersection(Perm.files), isEmpty);
      expect(await o.deleteRole('dj'), isFalse, reason: 'newcomers have it');
      await o.setNewcomer(Role.member);
      expect(await o.deleteRole('dj'), isTrue);
    });

    // GMFB-29, from the Uplink gap review: "A stage/stream mode: some people speak, many listen, with a listener count".
    test('a stage: newcomers listen, someone brought up speaks, and ending it lets everyone speak again', () async {
      final o = owner.room(channel), a = ann.room(channel), b = bob.room(channel);
      await o.open();
      await a.open();
      await b.open();
      await _settle();
      expect(o.stage, isFalse);
      expect(await a.setStage(true), isFalse, reason: 'only whoever manages the space');

      expect(await o.setStage(true), isTrue);
      await _settle();
      for (final r in [o, a, b]) {
        expect(r.stage, isTrue);
        expect(r.listens(ann.id), isTrue);
        expect(r.listens(bob.id), isTrue);
        expect(r.listens(owner.id), isFalse, reason: 'the owner speaks');
      }
      expect(a.heard(ann.id), isFalse, reason: 'a listener is not heard');
      expect(a.can(Perm.chat), isTrue, reason: 'a listener may still write in the chat');

      expect(await o.setSpeaker(ann.id, true), isTrue);
      await _settle();
      expect(b.listens(ann.id), isFalse);
      expect(b.heard(ann.id), isTrue);
      expect(await o.setSpeaker(ann.id, false), isTrue);
      await _settle();
      expect(b.listens(ann.id), isTrue, reason: 'back to the audience');

      expect(await o.setStage(false), isTrue);
      await _settle();
      expect(b.stage, isFalse);
      expect(b.listens(ann.id), isFalse);
      expect(b.heard(ann.id), isTrue, reason: 'everyone who was listening is a member again');
      expect(b.roster.roleOf(ann.id).id, Role.member);
    });
  });

  // Matt, 2026-11-19: "add Polls as a default feature".
  group('polls', () {
    test('a poll is asked as a message; votes are counted on each device, one per person, the latest theirs; a latecomer gets them', () async {
      final o = owner.room(channel), a = ann.room(channel);
      await o.open();
      await a.open();
      await _settle();
      expect(o.sendPoll('  Pizza or tacos?  ', PollSpec.of(['Pizza', 'Tacos', '  '])!), isTrue);
      await _settle();
      final poll = a.messages.single;
      expect(poll.text, 'Pizza or tacos?');
      expect(poll.poll, const PollSpec(options: ['Pizza', 'Tacos']));
      expect(poll.summary, '📊 Poll · Pizza or tacos?', reason: 'a list\'s preview');
      expect(poll.toJson()['x'], '📊 Poll\nPizza or tacos?', reason: 'what a build from before shows');

      expect(a.vote(poll, [1]), isTrue);
      await _settle();
      expect(o.tally(o.messages.single).counts, [0, 1]);
      expect(a.tally(poll).mine, [1]);
      // Ann changes her mind; still one vote of hers.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      a.vote(poll, [0, 1]);
      await _settle();
      expect(o.tally(o.messages.single).counts, [1, 0], reason: 'one answer where only one may be chosen');
      expect(o.tally(o.messages.single).voters, 1);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      o.vote(o.messages.single, [0]);
      await _settle();
      expect(a.tally(poll).counts, [2, 0]);

      // Bob comes later and is told every vote with the poll.
      final b = bob.room(channel);
      await b.open();
      await _settle();
      expect(b.tally(b.messages.single).counts, [2, 0]);
      expect(b.tally(b.messages.single).voters, 2);

      // Ann takes hers back.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      a.vote(poll, []);
      await _settle();
      expect(b.tally(b.messages.single).voters, 1);
      expect(o.tally(o.messages.single).counts, [1, 0]);
    });

    test('where more than one may be chosen each counts; votes are kept with the room; a vote for no answer it has is nothing', () async {
      final o = owner.room(channel);
      await o.open();
      expect(o.sendPoll('Which days?', PollSpec.of(['Fri', 'Sat', 'Sun'], multi: true)!), isTrue);
      final poll = o.messages.single;
      o.vote(poll, [2, 0, 0, 9]);
      expect(o.tally(poll).mine, [0, 2]);
      expect(o.tally(poll).counts, [1, 0, 1]);
      await o.close();
      // Opened again from what the device kept.
      final again = owner.room(channel);
      await again.open();
      expect(again.tally(again.messages.single).mine, [0, 2]);
    });

    test('a poll needs a question and two answers; at most ten, each cut to its length', () {
      expect(PollSpec.of(['Only one']), isNull);
      expect(PollSpec.fromJson({'o': ['a']}), isNull);
      final many = PollSpec.of([for (var i = 0; i < 14; i++) 'Answer $i', 'x' * 200])!;
      expect(many.options, hasLength(PollSpec.most));
      expect(PollSpec.fromJson({'o': ['a', 'b' * 200]})!.options.last.length, PollSpec.optionMost);
      expect(PollSpec.fromJson({'o': ['a', 'b'], 'm': 1})!.multi, isTrue);
    });
  });
}
