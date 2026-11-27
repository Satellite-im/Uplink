import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/circles/circle_screen.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/circles/circle_list.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/space_chat_files.dart' show spaceMayAttach, spaceMayWrite;
import 'package:ghost_messaging/voice/hangout.dart' show HangoutRoom, MemoryHangoutStore;
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// Circles (lib/circles, lib/ui/circles). Matt, 2026-11-17: "Let's do a circle for now, remove all of the code related
/// to the server UIs and make a new design for [circles]. We want it to be simpler and easier to digest with it's own
/// sidebar full of spaces each space should be able to act as a chat and a voice chat, or just a texting space".
///
/// The hub is stood in for, as in hangout_test (rooms: join, leave, a packet to everyone else, who came and went), and
/// each install has a real key, so manifests are really signed and checked.
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
  int sent = 0;

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
    sent++;
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

Future<void> _settle([int ms = 0]) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits until [ok] holds (or five seconds go by): not a fixed sleep, which a busy machine outruns.
Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
}

void main() {
  group('space kinds', () {
    test('a space from before kinds is a voice space; kinds go round its JSON and its link', () {
      final old = VoiceChannel.fromJson({'s': 'a' * 64, 'n': 'Old'})!;
      expect(old.kind, SpaceKind.voice);
      expect(old.hasVoice, isTrue);
      expect(old.toJson().containsKey('k'), isFalse, reason: 'a voice space writes no kind, so older builds read it as before');

      final text = VoiceChannel.make('Notes', kind: SpaceKind.text);
      expect(text.toJson()['k'], 'text');
      expect(VoiceChannel.fromJson(text.toJson())!.kind, SpaceKind.text);
      expect(text.hasVoice, isFalse);
      // A kind from a newer build reads as voice here, not as nothing.
      expect(VoiceChannel.fromJson({'s': 'b' * 64, 'n': 'X', 'k': 'board'})!.kind, SpaceKind.voice);

      final owner = '02${'c' * 64}';
      final files = VoiceChannel(seed: 'd' * 64, name: 'Drop box', owner: owner, kind: SpaceKind.files);
      expect(files.link, endsWith('.$owner.files'));
      final back = VoiceChannel.fromLink(files.link)!;
      expect((back.seed, back.name, back.owner, back.kind), (files.seed, 'Drop box', owner, SpaceKind.files));
      final voice = VoiceChannel.fromLink(VoiceChannel(seed: 'e' * 64, name: 'Lounge').link)!;
      expect((voice.name, voice.owner, voice.kind), ('Lounge', '', SpaceKind.voice));
      expect(VoiceChannel.fromLink('https://gogho.st/join/#c.${'e' * 64}.Q2lyY2xl'), isNull, reason: 'a circle\'s link is not a space\'s');
    });

    test('a texting space is never joined', () async {
      await expectLater(Voice.instance.join(VoiceChannel.make('Notes', kind: SpaceKind.text)), throwsStateError);
    });

    test('a Files space\'s roles carry its permissions; a voice space\'s never name them', () {
      final voice = Role.defaultsFor(SpaceKind.voice), files = Role.defaultsFor(SpaceKind.files);
      for (final r in voice) {
        expect(r.perms.intersection(Perm.files), isEmpty, reason: r.id);
      }
      Role byId(List<Role> l, String id) => l.firstWhere((r) => r.id == id);
      expect(byId(files, Role.member).perms, contains(Perm.uploadFiles));
      expect(byId(files, Role.member).perms, isNot(contains(Perm.manageFiles)));
      expect(byId(files, Role.moderator).perms, containsAll([Perm.uploadFiles, Perm.manageFiles]));
      expect(byId(files, Role.admin).perms, containsAll(Perm.values));
      // A permission this build doesn't know is kept, after the known ones, so a roster written again is as signed.
      final j = {'id': 'member', 'n': 'Member', 'r': 10, 'p': ['speak', 'chat', 'paintWalls']};
      expect(Role.fromJson(j)!.toJson()['p'], ['speak', 'chat', 'paintWalls']);
    });
  });

  group('manifest', () {
    final owner = NetKeys.generate(), admin = NetKeys.generate(), stranger = NetKeys.generate();
    final ownerKey = NetCrypto.hex(owner.public);

    test('signed by the owner, it checks out and goes round its JSON; changed, it does not', () async {
      final m = await _sign(CircleManifest(owner: ownerKey, version: 1, name: 'Book club', hue: 'rose', icon: 'book', spaces: [CircleSpace.make('General', kind: SpaceKind.text), CircleSpace.make('Lounge', order: 1)]), owner);
      expect(m.trustedFor(ownerKey), isTrue);
      final back = CircleManifest.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(back.trustedFor(ownerKey), isTrue);
      expect((back.name, back.hue, back.icon, back.spaces.length), ('Book club', 'rose', 'book', 2));
      expect(back.ordered.first.kind, SpaceKind.text);
      final forged = m.toJson()..['b'] = (m.toJson()['b'] as String).replaceAll('Book club', 'Spam club');
      expect(CircleManifest.fromJson(forged)!.trustedFor(ownerKey), isFalse);
      expect(m.trustedFor(NetCrypto.hex(stranger.public)), isFalse, reason: 'for another owner');
    });

    test('a newer build\'s fields still check out here', () async {
      final body = jsonEncode({'o': ownerKey, 'v': 3, 'n': 'Future', 'h': 'mint', 'i': 'users', 'sp': [{'s': 'f' * 64, 'n': 'Board', 'k': 'board', 'o': 0, 'z': 1}], 'g': {}, 'theme': 'x'});
      final unsigned = CircleManifest.fromJson({'b': body})!;
      final signed = await _sign(unsigned, owner);
      final back = CircleManifest.fromJson(jsonDecode(jsonEncode(signed.toJson())))!;
      expect(back.trustedFor(ownerKey), isTrue);
      expect(back.raw, body);
    });

    test('an admin the owner granted may sign; a stranger may not; an admin can\'t change who the admins are', () async {
      final v1 = await _sign(CircleManifest(owner: ownerKey, version: 1, name: 'C'), owner);
      final grant = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)));
      final v2 = await _sign(v1.next(adminGrants: {admin.id: grant}), owner);
      expect(v2.follows(v1, ownerKey), isTrue);
      final v3 = await _sign(v2.next(name: 'Renamed by admin'), admin);
      expect(v3.trustedFor(ownerKey), isTrue);
      expect(v3.follows(v2, ownerKey), isTrue);
      final byStranger = await _sign(v2.next(name: 'Mine now'), stranger);
      expect(byStranger.follows(v2, ownerKey), isFalse);
      // An admin making another admin (the grant is real, but only the owner may add it).
      final other = NetKeys.generate();
      final otherGrant = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, other.id)));
      final sneaky = await _sign(v3.next(adminGrants: {...v3.adminGrants, other.id: otherGrant}), admin);
      expect(sneaky.follows(v3, ownerKey), isFalse);
      // An older one never replaces a newer one.
      expect(v2.follows(v3, ownerKey), isFalse);
      expect(v3.follows(v3, ownerKey), isFalse);
    });

    test('a circle\'s link and invite give back the circle; its spaces are spaces owned by its owner', () async {
      final m = await _sign(CircleManifest(owner: ownerKey, version: 1, name: 'Night Owls', spaces: [CircleSpace.make('Lounge'), CircleSpace.make('Drop', kind: SpaceKind.files, order: 1, section: 'Stuff')]), owner);
      final c = Circle(seed: '1' * 64, owner: ownerKey, manifest: m, mine: true);
      expect(c.link, startsWith('https://gogho.st/join/#c.${'1' * 64}.'));
      final fromLink = Circle.fromLink(c.link)!;
      expect((fromLink.seed, fromLink.owner, fromLink.name, fromLink.manifest.version), (c.seed, ownerKey, 'Night Owls', 0));
      expect(Circle.fromLink('#${'1' * 64}.TmlnaHQ'), isNull, reason: 'a space\'s link is not a circle\'s');
      expect(fromLink.merged(m), isNotNull, reason: 'the real manifest replaces what the link said');

      final invite = Circles.fromInvite(Circles.inviteBody(c, 'Maya'))!;
      expect(invite.manifest.trustedFor(ownerKey), isTrue);
      expect(invite.spaces.map((s) => s.name), ['Lounge', 'Drop']);
      final drop = invite.channels.last;
      expect((drop.kind, drop.owner, drop.circle, drop.hangout), (SpaceKind.files, ownerKey, c.seed, true));

      final kept = Circle.fromJson(jsonDecode(jsonEncode(c.toJson())))!;
      expect((kept.seed, kept.mine, kept.manifest.trustedFor(ownerKey)), (c.seed, true, true));
      expect(kept.manifest.sections, [null, 'Stuff']);
      expect(c.room, isNot(Circle(seed: '2' * 64, owner: ownerKey, manifest: m).room));
    });
  });

  // Matt, 2026-11-18: "Build custom roles".
  group('roles', () {
    test('what each may do: the owner everything, an admin with no role everything, everyone the circle\'s default, a role its own', () async {
      final owner = NetKeys.generate(), admin = NetKeys.generate(), mod = NetKeys.generate(), member = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final grant = (NetKeys k) => NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, k.id)));
      final mods = CircleRole.make('Mods', hue: 'green', perms: {CirclePerm.spaces, CirclePerm.invite});
      final quiet = CircleRole.make('Quiet', perms: {});
      final base = CircleManifest(owner: ownerKey, version: 1, name: 'C', adminGrants: {admin.id: grant(admin), mod.id: grant(mod)});
      final m = await _sign(base.next(extra: base.withRoles(roles: [mods, quiet], assignments: {mod.id: [mods.id], member.id: [quiet.id]}, everyone: {CirclePerm.write, CirclePerm.voice})), owner);
      expect(m.permsOf(owner.id), CirclePerm.values.toSet());
      expect(m.permsOf(admin.id), CirclePerm.values.toSet(), reason: 'an admin as before roles');
      expect(m.permsOf(mod.id), {CirclePerm.spaces, CirclePerm.invite, CirclePerm.write, CirclePerm.voice}, reason: 'the role and everyone\'s, not the circle itself');
      expect(m.permsOf(member.id), {CirclePerm.write, CirclePerm.voice});
      expect(m.permsOf(NetKeys.generate().id), {CirclePerm.write, CirclePerm.voice}, reason: 'everyone else: the circle\'s default');
      // Round its JSON, and as a version from before roles keeps it (its own fields, signed with the rest).
      final back = CircleManifest.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(back.trustedFor(ownerKey), isTrue);
      expect(back.roles, [mods, quiet]);
      expect(back.rolesOf(mod.id).single.name, 'Mods');
      // A role that changes things, held by someone without the owner's grant: not theirs.
      final ungranted = await _sign(m.next(extra: m.withRoles(assignments: {member.id: [mods.id]})), owner);
      expect(ungranted.permsOf(member.id).contains(CirclePerm.spaces), isFalse, reason: 'no grant, no signing, no managing');
      expect(ungranted.permsOf(member.id).contains(CirclePerm.invite), isTrue);
    });

    test('roles made, given and taken: a role that manages brings the owner\'s admin grant, and taking it away takes the grant', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      addTearDown(() => mine.clear());
      final c = (await mine.make(name: 'Book club'))!;
      expect(mine.can(c, CirclePerm.roles), isTrue);
      final mods = CircleRole.make('Mods', perms: {CirclePerm.spaces});
      final talkers = CircleRole.make('Talkers', perms: {CirclePerm.voice});
      expect(await mine.saveRole(c, mods), isTrue);
      expect(await mine.saveRole(mine.bySeed(c.seed)!, talkers), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.roles.map((r) => r.name), ['Mods', 'Talkers']);

      expect(await mine.setRolesOf(mine.bySeed(c.seed)!, maya.id, [talkers.id]), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.granted(maya.id), isFalse, reason: 'talking signs nothing');
      expect(await mine.setRolesOf(mine.bySeed(c.seed)!, maya.id, [mods.id, talkers.id]), isTrue);
      var m = mine.bySeed(c.seed)!.manifest;
      expect(m.granted(maya.id), isTrue, reason: 'managing spaces: she must be able to sign');
      expect(m.permsOf(maya.id), containsAll([CirclePerm.spaces, CirclePerm.voice]));
      expect(m.permsOf(maya.id).contains(CirclePerm.circle), isFalse);

      expect(await mine.deleteRole(mine.bySeed(c.seed)!, mods.id), isTrue);
      m = mine.bySeed(c.seed)!.manifest;
      expect(m.roles.map((r) => r.name), ['Talkers']);
      expect(m.granted(maya.id), isFalse, reason: 'the role that made her an admin is gone');
      expect(m.rolesOf(maya.id).map((r) => r.name), ['Talkers']);

      // Everyone may never change the circle.
      expect(await mine.setEveryone(mine.bySeed(c.seed)!, {CirclePerm.write, CirclePerm.circle}), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.everyone, {CirclePerm.write});
    });
  });

  // Matt, 2026-11-18: "The roles and settings in circles can be cleaned up a lot to be closer to discord server settings
  // please overhaul them and make it easier to use with tri toggles for permissions and permission hierarchy".
  group('hierarchy and overrides', () {
    test('roles in their order: who stands where, who may manage which, and a name in its highest coloured role\'s colour', () async {
      final owner = NetKeys.generate(), lead = NetKeys.generate(), mod = NetKeys.generate(), member = NetKeys.generate(), admin = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      String grant(NetKeys k) => NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, k.id)));
      final leads = CircleRole.make('Leads', hue: 'rose', perms: {CirclePerm.roles});
      final mods = CircleRole.make('Mods', hue: circleRoleNoHue, perms: {CirclePerm.roles});
      final helpers = CircleRole.make('Helpers', hue: 'green');
      final base = CircleManifest(owner: ownerKey, version: 1, name: 'C', adminGrants: {lead.id: grant(lead), mod.id: grant(mod), admin.id: grant(admin)});
      final m = await _sign(base.next(extra: base.withRoles(roles: [leads, mods, helpers], assignments: {lead.id: [leads.id], mod.id: [mods.id, helpers.id], member.id: [helpers.id]})), owner);
      expect([m.rankOf(owner.id), m.rankOf(admin.id), m.rankOf(lead.id), m.rankOf(mod.id), m.rankOf(member.id), m.rankOf(NetKeys.generate().id)], [-2, -1, 0, 1, 2, 3]);
      // Only roles under one's own highest; the owner any.
      expect(m.mayManageRole(owner.id, leads.id), isTrue);
      expect(m.mayManageRole(lead.id, leads.id), isFalse, reason: 'not their own');
      expect(m.mayManageRole(lead.id, mods.id), isTrue);
      expect(m.mayManageRole(mod.id, mods.id), isFalse);
      expect(m.mayManageRole(mod.id, leads.id), isFalse, reason: 'not one above');
      expect(m.mayManageRole(mod.id, helpers.id), isTrue);
      expect(m.mayManageRole(member.id, helpers.id), isFalse, reason: 'Helpers can\'t manage roles at all');
      expect(m.mayManageRole(mod.id, 'new-role'), isTrue, reason: 'a new role is made at the bottom');
      // Ordering: only what is under one's own highest moves.
      expect(m.mayOrder(mod.id, [leads.id, mods.id, helpers.id]), isTrue);
      expect(m.mayOrder(mod.id, [leads.id, helpers.id, mods.id]), isFalse, reason: 'Helpers can\'t go above Mods for a Mod');
      expect(m.mayOrder(lead.id, [leads.id, helpers.id, mods.id]), isTrue);
      expect(m.mayOrder(lead.id, [mods.id, leads.id, helpers.id]), isFalse);
      expect(m.mayOrder(owner.id, [helpers.id, mods.id, leads.id]), isTrue);
      expect(m.mayOrder(owner.id, [helpers.id, mods.id]), isFalse, reason: 'every role, once');
      // A name takes the highest role's colour that has one: Mods have none, so Helpers' green.
      expect(m.nameHueOf(lead.id), 'rose');
      expect(m.nameHueOf(mod.id), 'green');
      expect(m.nameHueOf(NetKeys.generate().id), isNull);
      expect(m.holdersOf(helpers.id), 2);
    });

    test('a space\'s overrides as Discord works them out: everyone\'s, then the roles\' (deny, then allow); the owner and admins never held back', () async {
      final owner = NetKeys.generate(), admin = NetKeys.generate(), quiet = NetKeys.generate(), both = NetKeys.generate(), plain = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final grant = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, admin.id)));
      final general = CircleSpace.make('General', kind: SpaceKind.text), lounge = CircleSpace.make('Lounge', order: 1);
      final muted = CircleRole.make('Muted'), speakers = CircleRole.make('Speakers');
      final base = CircleManifest(owner: ownerKey, version: 1, name: 'C', spaces: [general, lounge], adminGrants: {admin.id: grant});
      final roles = base.next(extra: base.withRoles(roles: [speakers, muted], assignments: {quiet.id: [muted.id], both.id: [muted.id, speakers.id]}));
      final m = await _sign(roles.next(extra: roles.withOverrides({
        general.seed: {
          CircleManifest.everyoneId: const CircleOverride(allow: {CirclePerm.write}, deny: {CirclePerm.invite}),
          muted.id: const CircleOverride(deny: {CirclePerm.write}),
          speakers.id: const CircleOverride(allow: {CirclePerm.write, CirclePerm.invite}),
        },
        // Files can't be said of a voice space: left alone.
        lounge.seed: {muted.id: const CircleOverride(deny: {CirclePerm.voice, CirclePerm.files})},
        'gone': {muted.id: const CircleOverride(deny: {CirclePerm.voice})},
      })), owner);
      expect(m.overrides.keys.toSet(), {general.seed, lounge.seed}, reason: 'a space that is gone is left out');
      expect(m.overrideOf(general.seed, muted.id).of(CirclePerm.write), PermOverride.deny);
      expect(m.overrideOf(general.seed, muted.id).of(CirclePerm.voice), PermOverride.inherit);
      // Everyone's: invite taken away here, writing as the circle gives it.
      expect(m.permsIn(plain.id, general.seed), {CirclePerm.write, CirclePerm.voice, CirclePerm.files});
      // A role's Deny outweighs everyone's Allow.
      expect(m.permsIn(quiet.id, general.seed).contains(CirclePerm.write), isFalse);
      // One role's Allow outweighs another's Deny (deny first, then allow), and everyone's Deny.
      expect(m.permsIn(both.id, general.seed), containsAll([CirclePerm.write, CirclePerm.invite]));
      // Only what a space of its kind can say.
      expect(m.permsIn(quiet.id, lounge.seed).contains(CirclePerm.voice), isFalse);
      expect(m.permsIn(quiet.id, lounge.seed).contains(CirclePerm.files), isTrue);
      expect(m.permsIn(quiet.id, 'elsewhere'), m.permsOf(quiet.id), reason: 'a space with no overrides: as the circle says');
      // Never the owner or an admin.
      expect(m.permsIn(owner.id, general.seed), CirclePerm.values.toSet());
      expect(m.permsIn(admin.id, general.seed), CirclePerm.values.toSet());

      // Round its JSON, signed; written compactly as allow/deny letters.
      final back = CircleManifest.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(back.trustedFor(ownerKey), isTrue);
      expect(back.overrides, m.overrides);
      expect((jsonDecode(m.raw) as Map)['po'][general.seed][muted.id], '/w');
      expect((jsonDecode(m.raw) as Map)['po'][general.seed][CircleManifest.everyoneId], 'w/i');
      expect(m.fitsAPacket, isTrue);
    });

    test('a manifest with overrides and order, as an older build passes it on: its fields kept and still signed', () async {
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final s = CircleSpace.make('General', kind: SpaceKind.text);
      final a = CircleRole.make('A'), b = CircleRole.make('B');
      final base = CircleManifest(owner: ownerKey, version: 1, name: 'C', spaces: [s], extra: const {'zz': 'from a newer build'});
      final roles = base.next(extra: base.withRoles(roles: [b, a], assignments: {maya.id: [a.id]}));
      final m = await _sign(roles.next(extra: roles.withOverrides({s.seed: {a.id: const CircleOverride(deny: {CirclePerm.write})}})), owner);
      // An older build reads the body as fields it knows and keeps the rest ('ro', 'ra', 'po' among them) as they came.
      final raw = jsonDecode(m.raw) as Map;
      expect(raw.keys, containsAll(['ro', 'ra', 'po', 'zz']));
      final old = CircleManifest.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
      expect(old.extra['zz'], 'from a newer build');
      // Changed there (its name), the next version still has them, in their order.
      final renamed = await _sign(old.next(name: 'Renamed'), owner);
      expect(renamed.roles.map((r) => r.name), ['B', 'A']);
      expect(renamed.overrideOf(s.seed, a.id).of(CirclePerm.write), PermOverride.deny);
      expect(renamed.extra['zz'], 'from a newer build');
      // Clearing every override takes the field away altogether.
      expect(renamed.withOverrides(const {}).containsKey('po'), isFalse);
      // A role's hue as this build writes "no colour" reads as blue to a build that doesn't know it, never as an error.
      expect(CircleRole.fromJson({'id': 'x', 'n': 'X', 'h': 'mauve'})!.hue, 'blue');
      expect(CircleRole.fromJson({'id': 'x', 'n': 'X', 'h': circleRoleNoHue})!.hue, circleRoleNoHue);
      expect(CircleOverride.fromWire('wv/w'), const CircleOverride(allow: {CirclePerm.voice}, deny: {CirclePerm.write}), reason: 'written both ways: denied');
      expect(CircleOverride.fromWire(42), CircleOverride.none);
    });

    test('Circles holds everyone to the order: a member who manages roles changes only those under theirs', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), lead = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final hers = Circles.forTest(signer: KeysSigner(lead), route: _Route(hub, lead.id));
      addTearDown(() async {
        await mine.clear();
        await hers.clear();
      });
      final c = (await mine.make(name: 'Book club'))!;
      final top = CircleRole.make('Top'), leads = CircleRole.make('Leads', perms: {CirclePerm.roles}), helpers = CircleRole.make('Helpers'), guests = CircleRole.make('Guests');
      for (final r in [top, leads, helpers, guests]) {
        expect(await mine.saveRole(mine.bySeed(c.seed)!, r), isTrue);
      }
      expect(await mine.setRolesOf(mine.bySeed(c.seed)!, lead.id, [leads.id]), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.granted(lead.id), isTrue, reason: 'managing roles signs');
      await _settle();
      hers.join(Circle.fromLink(c.link)!);
      await _until(() => hers.bySeed(c.seed)!.manifest.roles.length == 4 && hers.bySeed(c.seed)!.manifest.granted(lead.id));
      final h = hers.bySeed(c.seed)!;
      expect(hers.mayManageRole(h, top.id), isFalse);
      expect(await hers.saveRole(h, top.copyWith(name: 'Mine now')), isFalse, reason: 'above her');
      expect(await hers.saveRole(h, leads.copyWith(hue: 'rose')), isFalse, reason: 'her own');
      expect(await hers.deleteRole(h, top.id), isFalse);
      expect(await hers.moveRole(h, guests.id, 0), isFalse, reason: 'not above her');
      expect(await hers.moveRole(h, guests.id, 2), isTrue, reason: 'Guests over Helpers, both under her');
      expect(hers.bySeed(c.seed)!.manifest.roles.map((r) => r.name), ['Top', 'Leads', 'Guests', 'Helpers']);
      expect(await hers.setRolesOf(hers.bySeed(c.seed)!, NetKeys.generate().id, [top.id]), isFalse, reason: 'she can\'t give a role above her');
      expect(await hers.saveRole(hers.bySeed(c.seed)!, helpers.copyWith(name: 'Helping hands')), isTrue);
      // The owner moves anything.
      await _until(() => mine.bySeed(c.seed)!.manifest.roles.any((r) => r.name == 'Helping hands'));
      expect(await mine.moveRole(mine.bySeed(c.seed)!, top.id, 3), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.roles.last.name, 'Top');
    });

    test('slow mode is a space\'s, set by whoever manages spaces, and holds members, not those who manage spaces (Matt, 2026-11-19: "add ... slow mode")', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      addTearDown(() async {
        await mine.clear();
        await hers.clear();
      });
      final c = (await mine.make(name: 'Book club'))!;
      await _settle();
      hers.join(Circle.fromLink(c.link)!);
      await _until(() => hers.bySeed(c.seed)!.manifest.version >= 1);
      final general = c.spaces.firstWhere((s) => s.kind == SpaceKind.text);
      VoiceChannel ch(Circles who) => who.bySeed(c.seed)!.channelOf(general);
      expect(hers.slowModeFor(ch(hers)), 0, reason: 'off to start with');
      expect(await mine.setSlowMode(mine.bySeed(c.seed)!, general.seed, 42), isFalse, reason: 'not one of the waits offered');
      expect(await mine.setSlowMode(mine.bySeed(c.seed)!, general.seed, 30), isTrue);
      await _until(() => hers.slowModeFor(ch(hers)) == 30);
      expect(slowModeOf(hers.bySeed(c.seed)!.space(general.seed)!), 30);
      expect(mine.slowModeFor(ch(mine)), 0, reason: 'the owner manages spaces and does not wait');
      expect(await hers.setSlowMode(hers.bySeed(c.seed)!, general.seed, 0), isFalse, reason: 'she does not manage spaces');
      expect(await mine.setSlowMode(mine.bySeed(c.seed)!, general.seed, 0), isTrue);
      await _until(() => hers.slowModeFor(ch(hers)) == 0);
      expect(hers.bySeed(c.seed)!.space(general.seed)!.extra.containsKey('slow'), isFalse, reason: 'off says nothing');
      expect([slowModeLabel(0), slowModeLabel(30), slowModeLabel(60), slowModeLabel(300), slowModeLabel(3600)], ['Off', '30 seconds', '1 minute', '5 minutes', '1 hour']);
      expect(slowModeLeft(const Duration(seconds: 11, milliseconds: 200)), '0:12');
      expect(slowModeLeft(const Duration(minutes: 4, seconds: 5)), '4:05');
    });

    test('allows() obeys a space\'s overrides: writing taken away in one space alone, then given back to a role there', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      addTearDown(() async {
        await mine.clear();
        await hers.clear();
      });
      final c = (await mine.make(name: 'Book club'))!;
      await _settle();
      hers.join(Circle.fromLink(c.link)!);
      await _until(() => hers.bySeed(c.seed)!.manifest.version >= 1);
      final general = c.spaces.firstWhere((s) => s.kind == SpaceKind.text), lounge = c.spaces.firstWhere((s) => s.kind == SpaceKind.voice);
      VoiceChannel ch(CircleSpace s) => hers.bySeed(c.seed)!.channelOf(s);
      expect(hers.allows(ch(general), CirclePerm.write), isTrue);
      expect(await mine.setOverride(mine.bySeed(c.seed)!, general.seed, CircleManifest.everyoneId, CirclePerm.write, PermOverride.deny), isTrue);
      expect(await mine.setOverride(mine.bySeed(c.seed)!, general.seed, CircleManifest.everyoneId, CirclePerm.voice, PermOverride.deny), isFalse, reason: 'a texting space has no talking to take away');
      await _until(() => !hers.allows(ch(general), CirclePerm.write));
      expect(hers.allows(ch(general), CirclePerm.write), isFalse);
      expect(hers.allows(ch(lounge), CirclePerm.write), isTrue, reason: 'only that space');
      expect(mine.allows(mine.bySeed(c.seed)!.channelOf(general), CirclePerm.write), isTrue, reason: 'the owner is never held back');
      final room = HangoutRoom(channel: ch(general), route: _Route(hub, maya.id), name: 'Maya', store: MemoryHangoutStore());
      expect(spaceMayWrite(room, circles: hers), isFalse, reason: 'the chat asks allows()');

      final writers = CircleRole.make('Writers');
      await mine.saveRole(mine.bySeed(c.seed)!, writers);
      await mine.setRolesOf(mine.bySeed(c.seed)!, maya.id, [writers.id]);
      expect(await mine.setOverride(mine.bySeed(c.seed)!, general.seed, writers.id, CirclePerm.write, PermOverride.allow), isTrue);
      await _until(() => hers.allows(ch(general), CirclePerm.write));
      expect(hers.allows(ch(general), CirclePerm.write), isTrue, reason: 'her role\'s Allow outweighs everyone\'s Deny');
      // Deleting the role takes its overrides with it.
      expect(await mine.deleteRole(mine.bySeed(c.seed)!, writers.id), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.overrideOf(general.seed, writers.id).isEmpty, isTrue);
      expect(await mine.clearOverrides(mine.bySeed(c.seed)!, general.seed, CircleManifest.everyoneId), isTrue);
      expect(mine.bySeed(c.seed)!.manifest.overrides, isEmpty);
      expect(mine.bySeed(c.seed)!.manifest.extra.containsKey('po'), isFalse);
    });
  });

  test('roles reach the others: with writing taken from everyone, a member may not write in its spaces, then may with a role', () async {
    final hub = _Hub();
    final owner = NetKeys.generate(), maya = NetKeys.generate();
    final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
    final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
    addTearDown(() async {
      await mine.clear();
      await hers.clear();
    });
    final c = (await mine.make(name: 'Book club'))!;
    await _settle();
    hers.join(Circle.fromLink(c.link)!);
    await _until(() => hers.bySeed(c.seed)!.manifest.version >= 1);
    final general = hers.bySeed(c.seed)!.channels.first;
    expect(hers.allows(general, CirclePerm.write), isTrue, reason: 'everyone writes, to start');
    expect(hers.can(hers.bySeed(c.seed)!, CirclePerm.spaces), isFalse);

    await mine.setEveryone(mine.bySeed(c.seed)!, {CirclePerm.voice, CirclePerm.files});
    await _until(() => !hers.allows(general, CirclePerm.write));
    expect(hers.allows(general, CirclePerm.write), isFalse);

    final writers = CircleRole.make('Writers', perms: {CirclePerm.write});
    await mine.saveRole(mine.bySeed(c.seed)!, writers);
    await mine.setRolesOf(mine.bySeed(c.seed)!, maya.id, [writers.id]);
    await _until(() => hers.allows(general, CirclePerm.write));
    expect(hers.allows(general, CirclePerm.write), isTrue, reason: 'her role gives it back');
  });

  // Matt, 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other
  // chats". Whoever may write in a circle's chat space may send a sticker; files need the circle's Share files too.
  test('in a circle\'s chat space, files need Share files and stickers only writing; neither without writing', () async {
    final hub = _Hub();
    final owner = NetKeys.generate(), maya = NetKeys.generate();
    final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
    final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
    addTearDown(() async {
      await mine.clear();
      await hers.clear();
    });
    final c = (await mine.make(name: 'Book club'))!;
    await _settle();
    hers.join(Circle.fromLink(c.link)!);
    await _until(() => hers.bySeed(c.seed)!.manifest.version >= 1);
    final general = hers.bySeed(c.seed)!.channels.first;
    final room = HangoutRoom(channel: general, route: _Route(hub, maya.id), name: 'Maya', store: MemoryHangoutStore());
    expect(spaceMayWrite(room, circles: hers), isTrue);
    expect(spaceMayAttach(room, circles: hers), isTrue, reason: 'everyone shares files, to start');

    await mine.setEveryone(mine.bySeed(c.seed)!, {CirclePerm.write, CirclePerm.voice});
    await _until(() => !hers.allows(general, CirclePerm.files));
    expect(spaceMayWrite(room, circles: hers), isTrue, reason: 'stickers and words still go');
    expect(spaceMayAttach(room, circles: hers), isFalse);

    await mine.setEveryone(mine.bySeed(c.seed)!, {CirclePerm.voice, CirclePerm.files});
    await _until(() => !hers.allows(general, CirclePerm.write));
    expect(spaceMayWrite(room, circles: hers), isFalse);
    expect(spaceMayAttach(room, circles: hers), isFalse, reason: 'Share files without writing sends nothing in a chat');
  });

  group('gossip', () {
    test('a change goes round the circle\'s room; a newcomer is given the newest manifest; a forged one is refused', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate(), sam = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      addTearDown(() async {
        await mine.clear();
        await hers.clear();
      });
      final c = (await mine.make(name: 'Book club', hue: 'rose', icon: 'book'))!;
      expect(c.spaces.map((s) => s.kind), [SpaceKind.text, SpaceKind.voice], reason: 'a texting space and a voice space to start');
      await _settle();

      // Maya comes in by the link alone: the manifest comes from the room.
      hers.join(Circle.fromLink(c.link)!);
      await _until(() => hers.bySeed(c.seed)!.manifest.version == 1);
      expect(hers.bySeed(c.seed)!.manifest.version, 1);
      expect(hers.bySeed(c.seed)!.spaces.length, 2);
      expect(hers.canEdit(hers.bySeed(c.seed)!), isFalse);

      // The owner adds a Files space: it reaches her.
      final drop = await mine.addSpace(mine.bySeed(c.seed)!, 'Drop box', kind: SpaceKind.files, section: 'Sharing');
      expect(drop, isNotNull);
      await _until(() => hers.bySeed(c.seed)!.manifest.version == 2);
      final seen = hers.bySeed(c.seed)!;
      expect(seen.manifest.version, 2);
      expect(seen.space(drop!.seed)?.kind, SpaceKind.files);
      expect(seen.space(drop.seed)?.section, 'Sharing');

      // She can't change it.
      expect(await hers.addSpace(seen, 'Mine'), isNull);

      // A forged manifest said in the room by someone with the seed is refused.
      final forger = CircleRoom(circle: seen, route: _Route(hub, sam.id), onManifest: (_, _) {});
      await forger.open();
      forger.say(await _sign(seen.manifest.next(name: 'Taken over'), sam));
      await _settle(50);
      expect(hers.bySeed(c.seed)!.name, 'Book club');
      expect(mine.bySeed(c.seed)!.name, 'Book club');
      await forger.close();

      // Moved and renamed: the order and the name reach her.
      final lounge = mine.bySeed(c.seed)!.spaces.firstWhere((s) => s.kind == SpaceKind.voice);
      await mine.moveSpace(mine.bySeed(c.seed)!, lounge.seed, 0);
      await mine.updateSpace(mine.bySeed(c.seed)!, lounge.seed, name: 'Living room');
      await _until(() => hers.bySeed(c.seed)!.spaces.first.name == 'Living room');
      expect(hers.bySeed(c.seed)!.spaces.first.name, 'Living room');

      // Left: off her list, its room left.
      await hers.leave(hers.bySeed(c.seed)!);
      expect(hers.bySeed(c.seed), isNull);
      expect(hers.removed(c.seed), isTrue);
    });

    test('a device that was away takes the newer manifest when it comes back', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final mine = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      addTearDown(mine.clear);
      final c = (await mine.make(name: 'Night Owls'))!;
      final old = c.manifest;
      await mine.edit(mine.bySeed(c.seed)!, name: 'Night Owls Club', hue: 'mint');
      await _settle();
      // Maya held version 1 from an invite.
      final hers = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      addTearDown(hers.clear);
      hers.join(Circle(seed: c.seed, owner: c.owner, manifest: old));
      await _until(() => hers.bySeed(c.seed)!.manifest.version == 2);
      expect(hers.bySeed(c.seed)!.name, 'Night Owls Club');
      expect(hers.bySeed(c.seed)!.hue, 'mint');
    });
  });

  group('screens', () {
    setUpAll(_fonts);
    setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

    Future<Circle> aCircle() async {
      final keys = NetKeys.generate();
      final m = await _sign(
        CircleManifest(owner: NetCrypto.hex(keys.public), version: 1, name: 'Night Owls', hue: 'indigo', icon: 'book', spaces: [
          CircleSpace.make('General', kind: SpaceKind.text),
          CircleSpace.make('Lounge', order: 1),
          CircleSpace.make('Drop box', kind: SpaceKind.files, order: 2, section: 'Sharing'),
        ]),
        keys,
      );
      return Circle(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), owner: NetCrypto.hex(keys.public), manifest: m);
    }

    // Under the rail the Messages toggle has no Circles tab: the rail lists the circles (Matt, 2026-11-20: "remove the
    // circles icon from the segmented toggle on the messages view since circles are now shown in the sidebar").
    testWidgets('the rail lists a circle, which takes the list\'s place with its spaces; back is the conversations', (tester) async {
      final c = (await tester.runAsync(aCircle))!;
      Circles.instance.join(c);
      addTearDown(Circles.instance.clear);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(412, 892));
      await settle(tester);
      expect(find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.circleDot), findsNothing, reason: 'no Circles tab under the rail');
      await tester.tap(find.byKey(ValueKey('rail-circle-${c.seed}')));
      await settle(tester);
      expect(find.byType(CircleScreen), findsOneWidget);
      expect(find.byType(CircleSpaceTile), findsNWidgets(3));
      expect(find.text('SHARING'), findsOneWidget, reason: 'a space under its heading');
      expect(find.byType(CircleSpaceTile).evaluate().map((e) => (e.widget as CircleSpaceTile).space.kind), [SpaceKind.text, SpaceKind.voice, SpaceKind.files]);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Back').first);
      await settle(tester);
      expect(find.byType(CircleScreen), findsNothing);
    });

    testWidgets('on a wide window the circle\'s first space opens beside it', (tester) async {
      final c = (await tester.runAsync(aCircle))!;
      Circles.instance.join(c);
      addTearDown(() async {
        openCircleSpaceSeed.value = null;
        await Circles.instance.clear();
      });
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(1240, 900));
      await settle(tester);
      tester.state<AppShellState>(find.byType(AppShell)).openCircle(c);
      await settle(tester);
      expect(find.byType(CircleScreen), findsOneWidget);
      expect(openCircleSpaceSeed.value, c.spaces.first.seed);
      final tile = tester.widget<CircleSpaceTile>(find.byWidgetPredicate((w) => w is CircleSpaceTile && w.space.seed == c.spaces.first.seed));
      expect(tile.selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a circle is always its list: no layout to choose, whatever an older build kept', (tester) async {
      final c = (await tester.runAsync(aCircle))!;
      Circles.instance.join(c);
      addTearDown(Circles.instance.clear);
      final sheet = await loadSheet(tester);
      // An older build's choice of another layout is left alone and means nothing now.
      final app = AppState()..set('circle_layout', 'orbit');
      await pumpScreen(tester, sheet, CircleScreen(seed: c.seed, onBack: () {}), app, size: const Size(412, 892));
      await settle(tester);
      expect(find.byType(CircleList), findsOneWidget);
      expect(find.byType(CircleSpaceTile), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  });

  // Matt, 2026-11-17: "spaces outside of servers move to the main chat list and can be swiped to leave a space or
  // delete / archive" (from the server preview's test, which went with it).
  group('spaces in Messages', () {
    setUpAll(_fonts);
    setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

    testWidgets('a space of one\'s own is in Messages, swiped left to Archive; a circle\'s is not', (tester) async {
      final space = VoiceChannel.make('Book club');
      final v = Voice.instance;
      v.own = [space];
      v.setCircled([VoiceChannel(seed: '9' * 64, name: 'Circle lounge', circle: '8' * 64)]);
      addTearDown(() {
        v.archive(space, false);
        v.own = [];
        v.setCircled(const []);
      });
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(412, 892));
      await settle(tester);
      expect(find.text('Book club'), findsOneWidget, reason: 'a space of one\'s own is in Messages');
      expect(find.text('Circle lounge'), findsNothing, reason: 'a circle\'s space is in its circle');

      await tester.drag(find.text('Book club'), const Offset(-100, 0));
      await settle(tester);
      expect(v.archived(space), isTrue);
      expect(find.text('Book club'), findsNothing);
    });
  });
}
