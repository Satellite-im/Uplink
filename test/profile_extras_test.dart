import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/me/own_links.dart';
import 'package:ghost_messaging/me/picture_make.dart';
import 'package:ghost_messaging/me/pictures.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/ui/own_links_ui.dart';
import 'package:ghost_messaging/ui/picture_crop.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:image/image.dart' as img;

import 'support/list_harness.dart';
import 'support/vouch_world.dart';

/// Profile extras (GMFB-34): a banner picture of your own, where there were ten ready-made banners only, and links you
/// type yourself, shown on your card to friends as what you say. And the check beside a name that a friend of yours
/// vouches for (GMFB-33).
Finder _key(String k) => find.byKey(ValueKey(k));

/// A photo-like picture, [w] by [h], its left half red and its right half blue under a grain.
Uint8List _photo(int w, int h) {
  final r = Random(3);
  final p = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final n = (r.nextDouble() - 0.5) * 16;
      p.setPixelRgb(x, y, ((x < w / 2 ? 210 : 30) + n).clamp(0, 255), (60 + y / h * 80 + n).clamp(0, 255), ((x < w / 2 ? 30 : 210) + n).clamp(0, 255));
    }
  }
  return img.encodeJpg(p, quality: 92);
}

/// One clear pixel.
const _dot = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Future<void> _me(Map<String, String> kept) async {
  final store = MemoryMeStore();
  kept.forEach(store.set);
  await Me.instance.start(store, ValueNotifier(0), () => null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('links you type yourself', () {
    test('only an https address with a site\'s name, of a bounded length, with nothing unseen in it', () {
      String? p(String address, [String label = 'Website']) => OwnLink.problemOf(OwnLink.tidyLabel(label), OwnLink.tidyAddress(address));
      for (final good in ['https://example.com', 'example.com/maya', 'https://sub.example.co.uk/a?b=c#d', 'https://example.com:443/x', 'https://xn--bcher-kva.example/']) {
        expect(p(good), isNull, reason: good);
      }
      for (final bad in [
        'http://example.com',
        'ftp://example.com',
        'javascript://example.com/%0aalert(1)',
        'https://localhost',
        'https://192.168.1.1/',
        'https://example',
        'https://bank.com@evil.example/',
        'https://bank.com\\@evil.example/',
        'https://example.com:8443/',
        'https://%65xample.com/',
        'https://exa mple.com',
        'https://example.com/\u202Egnp.exe',
        'https://example.com/\u0007',
        'https://bücher.example/',
        'https://example.com/${'a' * 200}',
        '',
      ]) {
        expect(p(bad), isNotNull, reason: bad);
      }
      expect(p('example.com', ''), isNotNull, reason: 'a link has a name');
      expect(p('example.com', 'x' * 25), isNotNull);
      expect(p('example.com', 'Web\u200Bsite'), isNotNull);
      expect(OwnLink.tidyAddress(' example.com/maya '), 'https://example.com/maya');
      expect(const OwnLink('Site', 'https://example.com/').short, 'example.com');
      expect(const OwnLink('Site', 'https://example.com/maya').host, 'example.com');
    });

    test('what a friend sends is read by the same rules: five at most, each one that could be typed here', () {
      final said = OwnLink.listOf([
        {'l': 'Website', 'u': 'https://example.com/'},
        {'l': 'Bad', 'u': 'http://example.com/'},
        {'l': 'Again', 'u': 'https://example.com/'},
        'x',
        {'l': 5, 'u': 'https://example.org/'},
        for (var i = 0; i < 10; i++) {'l': 'N$i', 'u': 'https://n$i.example.org/'},
      ])!;
      expect(said.length, OwnLink.most);
      expect(said.first, const OwnLink('Website', 'https://example.com/'));
      expect(said.map((l) => l.address), isNot(contains('http://example.com/')));
      expect(OwnLink.listOf(null), isNull, reason: 'a build from before says nothing, and nothing is let go of');
      expect(OwnLink.listOf(const []), isEmpty);
    });

    test('Me keeps them; they go to friends sealed, never in a request; a friend keeps them round their record', () async {
      await _me({'me_username': 'sam'});
      addTearDown(() => _me({}));
      Me.instance.setOwnLinks([const OwnLink('Website', 'https://example.com/'), const OwnLink('Bad', 'http://example.com/')]);
      expect(Me.instance.ownLinks, [const OwnLink('Website', 'https://example.com/')]);

      final w = VouchWorld();
      final sam = VouchPort(w, 'sam'), maya = VouchPort(w, 'maya');
      final b = await makeFriends([(sam, maya)]);
      await b[sam]!.shareProfile();
      await pumpEventQueue();
      final samAtMaya = b[maya]!.byId(sam.keys.id)!;
      expect(samAtMaya.own, [const OwnLink('Website', 'https://example.com/')]);
      expect(Buddy.fromJson(jsonDecode(jsonEncode(samAtMaya.toJson())))!.own, samAtMaya.own);
      expect(sam.sent.where((s) => !s.sealed && s.envelope.body.containsKey('ol')), isEmpty);
      // Taken away: friends let go of them. A build from before, which says nothing of links, changes nothing.
      maya.deliver(sam, _says({'u': 'maya', 'n': '', 'b': '', 'st': ''}));
      Me.instance.setOwnLinks(const []);
      await b[sam]!.shareProfile();
      await pumpEventQueue();
      expect(b[maya]!.byId(sam.keys.id)!.own, isEmpty);
      for (final x in b.values) {
        x.dispose();
      }
    });

    testWidgets('a friend\'s card lists them under Elsewhere as what they say, and a press shows the whole address before anything opens', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      final sheet = await loadSheet(tester);
      final w = VouchWorld();
      final sam = VouchPort(w, 'sam'), maya = VouchPort(w, 'maya'), theo = VouchPort(w, 'theo');
      final b = (await tester.runAsync(() async {
        final b = await makeFriends([(sam, maya), (sam, theo), (maya, theo)]);
        maya.deliver(sam, _says({'u': 'maya', 'n': 'Maya', 'b': '', 'st': '', 'bp': _dot, 'ol': [{'l': 'Website', 'u': 'https://maya.example.com/hello'}]}));
        // Theo, Sam's friend, vouches for Maya.
        await b[theo]!.vouch(b[theo]!.byId(maya.keys.id)!);
        await pumpEventQueue();
        return b;
      }))!;
      Buddies.instance = b[sam]!;
      addTearDown(() => Buddies.instance = null);
      await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(onTap: () => showProfile(context, ProfileSubject.ghost(id: maya.keys.id)), child: const Text('open'))), AppState(), size: const Size(412, 1400));
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(_key('banner-own'), findsOneWidget, reason: 'her own picture as the banner');
      expect(_key('profile-vouch-mark'), findsOneWidget, reason: 'a friend of the viewer vouches for her');
      await tester.ensureVisible(find.byKey(const ValueKey('profile-own-links'), skipOffstage: false));
      await settle(tester);
      expect(find.text(ownLinksWords('Maya')), findsOneWidget);
      expect(find.text('maya.example.com/hello'), findsOneWidget);
      expect(find.textContaining('https://maya.example.com/hello'), findsNothing);
      await tester.tap(_key('profile-own-link-0'));
      await settle(tester);
      expect(find.textContaining('https://maya.example.com/hello'), findsOneWidget, reason: 'the whole address, before it is opened');
      expect(find.text('Open maya.example.com'), findsOneWidget);
      // Sam, whom no friend of Sam's vouches for here, has no mark on a card.
      for (final x in b.values) {
        x.dispose();
      }
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Profile › Links: one is added with a name and an address, a bad address is said, a press removes one', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      final sheet = await loadSheet(tester);
      await tester.runAsync(() => _me({'me_username': 'sam'}));
      addTearDown(() => tester.runAsync(() => _me({})));
      final w = VouchWorld();
      final sam = VouchPort(w, 'sam');
      Buddies.instance = Buddies(sam);
      addTearDown(() => Buddies.instance = null);
      await pumpScreen(tester, sheet, const SingleChildScrollView(child: OwnLinksSection()), AppState(), size: const Size(412, 900));
      await tester.enterText(_key('own-link-label'), 'Website');
      await tester.enterText(_key('own-link-address'), 'http://example.com');
      await tester.tap(_key('own-link-add'));
      await settle(tester);
      expect(_key('own-links-problem'), findsOneWidget);
      expect(Me.instance.ownLinks, isEmpty);
      await tester.enterText(_key('own-link-address'), 'example.com/sam');
      await tester.tap(_key('own-link-add'));
      await settle(tester);
      expect(Me.instance.ownLinks, [const OwnLink('Website', 'https://example.com/sam')]);
      expect(_key('own-links-problem'), findsNothing);
      // The toast that said it was added goes, and the link's row is pressed.
      await tester.pump(const Duration(seconds: 6));
      await settle(tester);
      await tester.tap(_key('own-link-0'));
      await settle(tester);
      await tester.tap(find.text('Remove this link'));
      await settle(tester);
      expect(Me.instance.ownLinks, isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('a banner picture of your own', () {
    testWidgets('a photo is made a band three wide to one high, as a small JPEG, from the part chosen', (tester) async {
      final made = (await tester.runAsync(() => bannerPictureOf(_photo(1600, 1200))))!;
      final band = img.decodeJpg(base64Decode(made))!;
      expect(band.width, ProfilePictures.bannerWide);
      expect(band.height, (ProfilePictures.bannerWide / ProfilePictures.bannerShape).round());
      expect(made.length, lessThanOrEqualTo(ProfilePictures.bannerMost));
      expect(ProfilePictures.goodBanner(made), isTrue);
      // The right half chosen: all blue.
      final half = await tester.runAsync(() => bannerPictureOf(_photo(1600, 1200), crop: const Rect.fromLTWH(0.5, 0.25, 0.5, 0.25)));
      final right = img.decodeJpg(base64Decode(half!))!;
      expect(right.getPixel(8, 20).b, greaterThan(150));
      expect(right.getPixel(8, 20).r, lessThan(90));
      // With less room it is made smaller, never longer than asked.
      final small = (await tester.runAsync(() => bannerPictureOf(_photo(1600, 1200), most: 5000)))!;
      expect(small.length, lessThanOrEqualTo(5000));
      expect(await tester.runAsync(() => bannerPictureOf(Uint8List.fromList([1, 2, 3]))), isNull);
    });

    testWidgets('the cropper\'s wide window gives a band of the banner\'s shape', (tester) async {
      final sheet = await loadSheet(tester);
      Object? got = 'unasked';
      await pumpScreen(
        tester,
        sheet,
        Builder(
          builder: (context) => Center(
            child: GestureDetector(
              key: const ValueKey('ask'),
              onTap: () async => got = await Navigator.of(context).push<Rect>(PageRouteBuilder<Rect>(opaque: false, pageBuilder: (context, _, _) => PictureCrop(image: MemoryImage(base64Decode(_dot)), size: const Size(1200, 1200), shape: 3))),
              child: const SizedBox(width: 40, height: 40, child: ColoredBox(color: Color(0xFF888888))),
            ),
          ),
        ),
        AppState(),
        size: const Size(800, 700),
        platform: 'desktop',
      );
      await tester.tap(_key('ask'));
      await settle(tester);
      expect(find.text('Position your banner'), findsOneWidget);
      await tester.tap(_key('picture-crop-use'));
      await settle(tester);
      final band = got as Rect;
      // A square picture under a window three to one: its whole width, the middle third of its height.
      expect(band.width, closeTo(1, 0.001));
      expect(band.height, closeTo(1 / 3, 0.001));
      expect(band.top, closeTo(1 / 3, 0.001));
    });

    test('it goes to friends in the profile where there is room, and in an envelope of its own where the pictures leave none; a build from before is sent the ready-made one too', () async {
      final banner = base64Encode(List.filled(6000, 7));
      await _me({'me_username': 'sam', 'me_cosmetics': '{"bn":"aurora"}'});
      addTearDown(() => _me({}));
      Me.instance.setBanner(banner);
      expect(Me.instance.banner, banner);
      final w = VouchWorld();
      final sam = VouchPort(w, 'sam'), maya = VouchPort(w, 'maya');
      final b = await makeFriends([(sam, maya)]);
      await b[sam]!.shareProfile();
      await pumpEventQueue();
      var told = sam.sent.where((s) => s.envelope.kind == 'buddy').toList();
      expect(told.single.envelope.body['bp'], banner);
      expect((told.single.envelope.body['cx'] as Map)['bn'], 'aurora', reason: 'what a build from before draws');
      expect(told.single.sealed, isTrue);
      expect(b[maya]!.byId(sam.keys.id)!.banner, banner);
      expect(Buddy.fromJson(jsonDecode(jsonEncode(b[maya]!.byId(sam.keys.id)!.toJson())))!.banner, banner);

      // Both profile pictures as long as they can be: the banner has no room beside them, and follows.
      sam.sent.clear();
      Me.instance.setPicture(ProfilePicture(sharp: 'A' * ProfilePictures.sharpMost, small: 'B' * ProfilePictures.smallMost));
      Me.instance.setBanner('${banner}AAAA');
      await b[sam]!.shareProfile();
      await pumpEventQueue();
      told = sam.sent.where((s) => s.envelope.kind == 'buddy').toList();
      expect([for (final t in told) t.envelope.body['s']], ['me', 'bn']);
      expect(told.first.envelope.body.containsKey('bp'), isFalse);
      for (final t in told) {
        expect(utf8.encode(jsonEncode(t.envelope.body)).length, lessThan(58 * 1024), reason: 'each fits a packet of the hub\'s 60 KB with room for its sealing');
      }
      expect(b[maya]!.byId(sam.keys.id)!.banner, '${banner}AAAA');
      expect(b[maya]!.byId(sam.keys.id)!.picture, 'A' * ProfilePictures.sharpMost, reason: 'the pictures came as they do');

      // Taken away: said as none, and the friend lets go of it. One too long, or not a picture's letters, is never kept.
      Me.instance.setPicture(null);
      Me.instance.setBanner(null);
      await b[sam]!.shareProfile();
      await pumpEventQueue();
      expect(b[maya]!.byId(sam.keys.id)!.banner, '');
      expect(Buddies.saidOf({'bp': 'A' * (ProfilePictures.bannerMost + 1)}).banner, '');
      expect(Buddies.saidOf({'bp': '<svg onload=x>'}).banner, '');
      expect(Buddies.saidOf({'st': ''}).banner, isNull, reason: 'a build from before says nothing of it');
      Me.instance.setBanner('A' * (ProfilePictures.bannerMost + 1));
      expect(Me.instance.banner, '');
      for (final x in b.values) {
        x.dispose();
      }
    });
  });
}

/// A friend's sealed profile as it comes (`buddy`, step `me`).
Envelope _says(Map<String, Object> body) => Envelope(kind: 'buddy', body: {'s': 'me', ...body});
