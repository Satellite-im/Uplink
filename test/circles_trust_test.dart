// Who a circle's members believe, and what a phone and its computer keep in step (the review of Circles, 2026-11-17):
// an admin the owner removed can't take the circle back with a manifest numbered higher, nor lock it with the highest
// number there is; a manifest of the wrong shape is no manifest, never an error; a kind of space from a newer build
// survives an edit here; a manifest too big to pass on is never published; a circle joined again after leaving stays;
// and a phone's sync that changes nothing changes nothing.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';

Future<CircleManifest> _sign(CircleManifest m, NetKeys k) => m.signedBy(k.id, k.public, (b) async => NetCrypto.sign(k, b));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the admin list', () {
    test('a removed admin\'s manifest, however high its number, loses to the owner\'s removal, for a new joiner too', () async {
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final circles = Circles.forTest(signer: KeysSigner(owner));
      addTearDown(circles.clear);
      final c = (await circles.make(name: 'Night Owls'))!;
      expect(await circles.grantAdmin(c, maya.id), isTrue);
      final withMaya = circles.bySeed(c.seed)!.manifest;
      expect(withMaya.granted(maya.id), isTrue);
      expect(withMaya.grantsVersion, 1);
      // While still an admin, Maya signs one numbered far beyond anything the owner will reach.
      final hijack = await _sign(withMaya.next(name: 'Mine now').next(), maya);
      final far = await _sign(CircleManifest.fromJson({...hijack.toJson(), 'b': jsonEncode({...jsonDecode(hijack.raw) as Map, 'v': 1 << 50})})!, maya);
      expect(far.version, 1 << 50);
      expect(far.trustedFor(c.owner), isTrue, reason: 'signed by an admin of that list');
      // The owner removes her.
      expect(await circles.grantAdmin(c, maya.id, on: false), isTrue);
      final removal = circles.bySeed(c.seed)!.manifest;
      expect(removal.grantsVersion, 2);
      expect(removal.granted(maya.id), isFalse);
      // Held by a member: hers doesn't follow the owner's.
      expect(far.follows(removal, c.owner), isFalse);
      // A new joiner who took hers first takes the owner's when it comes.
      final placeholder = CircleManifest.placeholder(owner: c.owner, name: 'Night Owls');
      expect(far.follows(placeholder, c.owner), isTrue);
      expect(removal.follows(far, c.owner), isTrue, reason: 'a newer admin list outranks any version under the older one');
      // And the owner changes the circle again after it.
      expect(await circles.edit(c, name: 'Night Owls'), isTrue);
    });

    test('an admin list not signed by the owner grants nobody', () async {
      final owner = NetKeys.generate(), maya = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final grant = NetCrypto.hex(NetCrypto.sign(owner, CircleManifest.grantMessage(ownerKey, maya.id)));
      // Maya puts a higher generation on the owner's own grant to her, signing the list herself.
      final forged = CircleManifest(owner: ownerKey, name: 'X', version: 1, adminGrants: {maya.id: grant}, grantsVersion: 9, grantsSig: NetCrypto.hex(NetCrypto.sign(maya, CircleManifest.grantsMessage(ownerKey, 9, {maya.id: grant}))));
      expect(forged.grantsTrusted, isFalse);
      expect(forged.granted(maya.id), isFalse);
      expect((await _sign(forged, maya)).trustedFor(ownerKey), isFalse);
    });

    test('the highest numbers are refused, and the owner starts again under a new list rather than being locked out', () async {
      final owner = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final top = await _sign(CircleManifest(owner: ownerKey, name: 'X', version: CircleManifest.versionCap - 1), owner);
      expect(CircleManifest.fromJson(top.toJson()), isNotNull);
      final over = {...top.toJson(), 'b': jsonEncode({...jsonDecode(top.raw) as Map, 'v': CircleManifest.versionCap})};
      expect(CircleManifest.fromJson(over), isNull);
      final circles = Circles.forTest(signer: KeysSigner(owner));
      addTearDown(circles.clear);
      final c = circles.join(Circle(seed: 'a' * 64, owner: ownerKey, manifest: top));
      expect(await circles.edit(c, name: 'Y'), isTrue);
      final now = circles.bySeed(c.seed)!.manifest;
      expect(now.name, 'Y');
      expect(now.version, 1);
      expect(now.grantsVersion, 1);
      expect(now.follows(top, ownerKey), isTrue);
    });
  });

  group('reading what anyone sends', () {
    test('a manifest of the wrong shape is no manifest, not an error', () {
      for (final body in <Map<String, Object?>>[
        {'o': '', 'v': 1, 'n': 'x', 'sp': {}},
        {'o': '', 'v': 1, 'n': 'x', 'g': []},
        {'o': '', 'v': -1, 'n': 'x'},
      ]) {
        final m = CircleManifest.fromJson({'b': jsonEncode(body)});
        expect(m == null || m.spaces.isEmpty && m.adminGrants.isEmpty, isTrue, reason: '$body');
      }
      expect(CircleManifest.fromJson({'b': jsonEncode({'o': '', 'v': 1, 'n': 'x'}), 'by': 1}), isNull);
      expect(CircleManifest.fromJson({'b': jsonEncode({'o': '', 'v': 1, 'n': 'x'}), 's': ['x']}), isNull);
    });

    test('a kind and fields from a newer build survive an edit here, drawn meanwhile as texting', () async {
      final owner = NetKeys.generate();
      final ownerKey = NetCrypto.hex(owner.public);
      final body = {
        'o': ownerKey,
        'v': 1,
        'n': 'Lab',
        'h': 'indigo',
        'i': 'users',
        'sp': [
          {'s': 'b' * 64, 'n': 'Board', 'k': 'whiteboard', 'o': 0, 'pin': true},
        ],
        'g': {},
        'theme': 'night',
      };
      final m = await _sign(CircleManifest.fromJson({'b': jsonEncode(body)})!, owner);
      final space = m.spaces.single;
      expect(space.kind, SpaceKind.text, reason: 'no call offered for a kind this build doesn\'t know');
      final circles = Circles.forTest(signer: KeysSigner(owner));
      addTearDown(circles.clear);
      final c = circles.join(Circle(seed: 'c' * 64, owner: ownerKey, manifest: m));
      expect(await circles.updateSpace(c, space.seed, name: 'Big board'), isTrue);
      final written = jsonDecode(circles.bySeed(c.seed)!.manifest.raw) as Map;
      final s = (written['sp'] as List).single as Map;
      expect(s['k'], 'whiteboard');
      expect(s['pin'], true);
      expect(s['n'], 'Big board');
      expect(written['theme'], 'night');
      // A kind chosen here replaces it.
      expect(await circles.updateSpace(circles.bySeed(c.seed)!, space.seed, kind: SpaceKind.files), isTrue);
      expect(((jsonDecode(circles.bySeed(c.seed)!.manifest.raw) as Map)['sp'] as List).single['k'], 'files');
    });

    test('names are cut to 100 characters, and a manifest too big to pass on is not published', () async {
      final owner = NetKeys.generate();
      final circles = Circles.forTest(signer: KeysSigner(owner));
      addTearDown(circles.clear);
      final c = (await circles.make(name: 'x' * 500))!;
      expect(c.name.length, 100);
      var held = circles.bySeed(c.seed)!;
      for (var i = 0; i < 400 && held.manifest.raw.length < 50000; i++) {
        await circles.addSpace(held, 'A space with a long name number $i ${'y' * 60}');
        held = circles.bySeed(c.seed)!;
      }
      final before = held.manifest.version;
      var refused = false;
      for (var i = 0; i < 200 && !refused; i++) {
        refused = await circles.addSpace(held, 'One more $i ${'z' * 90}') == null;
        held = circles.bySeed(c.seed)!;
      }
      expect(refused, isTrue);
      expect(held.manifest.fitsAPacket, isTrue);
      expect(held.manifest.version, greaterThanOrEqualTo(before));
      expect(Circle.fromJson(held.toJson()), isNotNull, reason: 'what is kept still reads back');
    });
  });

  group('the phone and its computer', () {
    test('a circle left and joined again on the phone comes back here, and a sync that changes nothing tells nobody', () async {
      final owner = NetKeys.generate();
      final circles = Circles.forTest(signer: KeysSigner(owner));
      addTearDown(circles.clear);
      final c = (await circles.make(name: 'Night Owls'))!;
      await circles.leave(c);
      expect(circles.bySeed(c.seed), isNull);
      expect(circles.removed(c.seed), isTrue);
      // The phone has it (joined again there) and not as left.
      circles.fromPhone({'circles': [c.toJson()], 'circles_gone': <String>[]});
      expect(circles.bySeed(c.seed), isNotNull);
      expect(circles.removed(c.seed), isFalse);
      var told = 0;
      circles.addListener(() => told++);
      circles.fromPhone({'circles': [c.toJson()], 'circles_gone': <String>[]});
      circles.fromPhone({'circles': [c.toJson()], 'circles_gone': <String>[]});
      expect(told, 0, reason: 'every 8 s a sync rewrote every circle and rebuilt every list');
      // Left on the phone: left here.
      circles.fromPhone({'circles': const [], 'circles_gone': [c.seed]});
      expect(circles.bySeed(c.seed), isNull);
      expect(told, 1);
    });
  });
}
