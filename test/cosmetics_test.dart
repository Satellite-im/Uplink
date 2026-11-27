import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/cosmetics.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/cosmetics_picker.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/profile.dart';
import 'package:ghost_messaging/net/net.dart';

import 'support/space_call_harness.dart';

/// Profile cosmetics (GMFB-34; Matt, 2026-11-22: "get ready for supporting profile decorations, profile picture
/// borders, custom name effects and more like discord supports"): what is sent, what a friend's card wears, and the
/// picker that puts a piece on.
// Maya as the harness's space has her ('a'), and as a friend by the same id.
const _maya = 'a';
const _dressed = {'d': 'wisp-halo', 'r': 'neon-tube', 'bn': 'aurora', 'ne': 'rainbow', 'pe': 'embers'};

class _Friends implements BuddiesPort {
  final sent = <Envelope>[];
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'me';
  @override
  String get displayName => 'Me';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => jsonEncode([
        {'u': 'maya', 'i': _maya, 'k': 'k', 'n': 'Maya Chen', 's': 'yes', 'st': 'Out walking', 'cx': _dressed},
      ]);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async {
    sent.add(envelope);
    return true;
  }

  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void main() {
  group('what is sent', () {
    test('ids by kind, empty ones left out, and read back the same', () {
      const c = Cosmetics(banner: 'aurora', name: 'flame');
      expect(c.toJson(), {'bn': 'aurora', 'ne': 'flame'});
      expect(Cosmetics.fromJson(c.toJson()), c);
      // The decoration, the border and the profile effect are not worn any more (Matt, 2026-11-25: "remove the profile
      // decoration, the profile border and the profile effect"): not sent, and not read from a build that sends them.
      expect(const Cosmetics(decoration: 'cat-ears', border: 'neon-tube', effect: 'embers', banner: 'aurora').toJson(), {'bn': 'aurora'});
      expect(Cosmetics.fromJson({'d': 'cat-ears', 'r': 'neon-tube', 'pe': 'embers', 'ne': 'flame'}), const Cosmetics(name: 'flame'));
      expect(Cosmetics.none.toJson(), isEmpty);
      expect(Cosmetics.fromJson(null), isNull, reason: 'a build from before says nothing');
    });

    test('a newer build\'s piece is kept to be drawn later; anything not shaped like an id is not', () {
      final c = Cosmetics.fromJson({'bn': 'jetpack-2027', 'r': '<script>', 'ne': 'x' * 60})!;
      expect(c.banner, 'jetpack-2027');
      expect(CosmeticCatalog.find(CosmeticKind.banner, c.banner), isNull, reason: 'unknown here: drawn as nothing');
      expect((c.border, c.name), ('', ''));
      expect(Cosmetics.fromJson({'ne': 42})!.name, '');
    });

    test('a friend\'s profile carries it, and a friend\'s kept record keeps it', () {
      final said = Buddies.saidOf({'st': '', 'cx': _dressed});
      expect(said.cosmetics, Cosmetics.fromJson(_dressed));
      expect(Buddies.saidOf({'st': ''}).cosmetics, isNull, reason: 'a build from before: what was known stays');
      final b = Buddy(username: 'maya', id: _maya, key: 'k', cosmetics: Cosmetics.fromJson(_dressed)!);
      expect(Buddy.fromJson(b.toJson())!.cosmetics, b.cosmetics);
      expect(Buddy(username: 'maya', id: _maya, key: 'k').toJson().containsKey('cx'), isFalse, reason: 'nothing worn, nothing kept');
    });

    test('the catalog has the forty pieces asked of Lovart and the Uplink pack, each with its file name, and the app\'s own name effects', () {
      expect(CosmeticCatalog.all.where((c) => !c.coded), hasLength(42));
      expect({for (final k in CosmeticKind.values) k: CosmeticCatalog.of(k).where((c) => !c.coded).length},
          {CosmeticKind.decoration: 13, CosmeticKind.border: 8, CosmeticKind.banner: 10, CosmeticKind.name: 6, CosmeticKind.effect: 5});
      expect(CosmeticCatalog.of(CosmeticKind.decoration).first.id, 'ghost-ring', reason: 'the Uplink pack first');
      expect(CosmeticCatalog.of(CosmeticKind.effect).first.id, 'haunted');
      expect(CosmeticCatalog.find(CosmeticKind.decoration, 'wisp-halo')!.asset, 'assets/cosmetics/decorations/wisp-halo.png');
      expect(CosmeticCatalog.all.where((c) => c.coded).map((c) => c.id), containsAll(['shimmer', 'rainbow', 'spectral-glow']));
      expect(CosmeticCatalog.all.map((c) => '${c.kind}/${c.id}').toSet(), hasLength(CosmeticCatalog.all.length), reason: 'no id twice in a kind');
    });
  });

  test('a piece that moves is drawn from its animation, and from its still where motion is off', () {
    final ring = CosmeticCatalog.find(CosmeticKind.decoration, 'ghost-ring')!;
    final art = CosmeticArt.instance;
    art.reset({ring.asset, ring.animated});
    expect(art.artOf(ring, moving: true), 'assets/cosmetics/decorations/ghost-ring.webp');
    expect(art.artOf(ring, moving: false), 'assets/cosmetics/decorations/ghost-ring.png');
    art.reset({ring.animated});
    expect(art.artOf(ring, moving: false), ring.animated, reason: 'no still: the animation, which Flutter draws still');
    art.reset(const {});
    expect(art.artOf(ring, moving: true), isNull, reason: 'neither: its stand-in');
    expect(art.has(ring), isFalse);
    art.reset();
  });

  group('on screen', () {
    late _Friends friends;
    setUp(() async {
      friends = _Friends();
      Buddies.instance = Buddies(friends);
      await Buddies.instance.start();
      CosmeticArt.instance.reset();
    });
    tearDown(() => Buddies.instance = null);

    for (final dark in [false, true]) {
      testWidgets('a friend\'s card wears their banner and name effect, and no decoration, border or profile effect (${dark ? 'dark' : 'light'})', (tester) async {
        final h = await SpaceHarness.load(tester);
        final room = h.room();
        await room.open();
        await h.shoot(tester, GhostPage(title: '# Friday hang', body: HangoutChat(room: room)), 'cosmetics-card', dark: dark);
        // Maya the friend: her card, from her kept profile.
        await tester.runAsync(() async {});
        final chat = find.text('Maya Chen').first;
        await tester.tap(chat);
        await tester.pump(const Duration(milliseconds: 400));
        for (final key in ['banner-aurora', 'name-rainbow']) {
          expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        }
        for (final key in ['decoration-wisp-halo', 'border-neon-tube', 'effect-embers']) {
          expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
        }
        await h.again(tester, 'cosmetics-card-open', dark: dark);
        await tester.pump(const Duration(seconds: 1));
      });
    }

    for (final dark in [false, true]) {
      testWidgets('Profile has Show me as and Look; choosing Busy keeps it and tells the hub (${dark ? 'dark' : 'light'})', (tester) async {
        final h = await SpaceHarness.load(tester);
        final store = MemoryMeStore()
          ..set('me_username', 'matt')
          ..set('me_display', 'Matt')
          ..set('me_cosmetics', jsonEncode(const Cosmetics(decoration: 'frost-crystals', banner: 'deep-space', name: 'shimmer').toJson()));
        await tester.runAsync(() => Me.instance.start(store, ValueNotifier(0), () => null));
        addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
        Me.instance.hear({'dir': 'souls', 'n': 5, 'special': ['alpha', 'bughunter'], 'show': 'alpha'});
        addTearDown(() => Me.instance.hear({'dir': 'souls', 'n': 0, 'special': const <String>[], 'show': ''}));
        await h.shoot(tester, const ProfileScreen(), 'profile-look', dark: dark, size: const Size(412, 1900));
        expect(find.byKey(const ValueKey('look-preview')), findsOneWidget);
        expect(find.byKey(const ValueKey('decoration-frost-crystals')), findsNothing);
        expect(find.byKey(const ValueKey('look-banner')), findsOneWidget);
        expect(find.byKey(const ValueKey('look-name')), findsOneWidget);
        for (final gone in ['look-decoration', 'look-border', 'look-effect']) {
          expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
        }
        expect(find.byType(BadgeSection), findsOneWidget, reason: 'the badge is chosen on the profile page');
        await tester.tap(find.byKey(const ValueKey('presence-mode-busy')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(Me.instance.presenceMode, 'busy');
        expect(store.kept['me_presence'], 'busy');
        // The badges you have, the one shown ticked; a press shows another beside your name.
        expect(find.byKey(const ValueKey('profile-badge-alpha')), findsOneWidget);
        expect(Me.instance.showcase, 'alpha');
        await tester.ensureVisible(find.byKey(const ValueKey('profile-badge-bughunter')));
        await tester.tap(find.byKey(const ValueKey('profile-badge-bughunter')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(Me.instance.showcase, 'bughunter');
        Net.instance.setMode('online');
        await tester.pump(const Duration(seconds: 1));
      });
    }

    testWidgets('the picker puts a piece on, tells friends, and None takes it off', (tester) async {
      final h = await SpaceHarness.load(tester);
      final store = MemoryMeStore()..set('me_username', 'me')..set('me_display', 'Matt');
      await tester.runAsync(() => Me.instance.start(store, ValueNotifier(0), () => null));
      addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
      await h.shoot(tester, const CosmeticPickerScreen(kind: CosmeticKind.banner), 'cosmetics-picker-banner');
      await tester.tap(find.byKey(const ValueKey('piece-aurora')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(Me.instance.cosmetics.banner, 'aurora');
      expect(store.kept['me_cosmetics'], contains('aurora'), reason: 'kept');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(friends.sent.where((e) => (e.body['cx'] as Map?)?['bn'] == 'aurora'), isNotEmpty, reason: 'friends told');
      await h.again(tester, 'cosmetics-picker-banner-worn');
      await tester.tap(find.byKey(const ValueKey('piece-none')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(Me.instance.cosmetics.banner, '');
      // The other kind's grid builds too.
      await h.shoot(tester, const CosmeticPickerScreen(kind: CosmeticKind.name), 'cosmetics-picker-name');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
