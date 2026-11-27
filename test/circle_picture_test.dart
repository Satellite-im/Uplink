import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/me/picture_make.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/circles/circle_picture.dart';
import 'package:image/image.dart' as img;

import 'support/list_harness.dart';

/// A circle's picture and banner (lib/ui/circles/circle_picture.dart; Matt, 2026-11-27: "uploading the banner from my
/// desktop to AlphaTesters circle says 'cannot use image'", then "uploading the pictures for banners and the circle
/// profile picture should use a cropping / zooming tool and upload at full resolution, right now they're super low
/// resolution"): positioned under a window, kept as a stand-in sharp enough to draw and as the part chosen cut at
/// the picture's own resolution, sent from a copy of the app's own, and said plainly where one can't be used.
/// Every picture here is made in the test.

/// Grain on a gradient with stars: detail everywhere, as a photo or a piece of art has, which is what a PNG can't
/// make small.
Uint8List art(int w, int h, {int seed = 3}) {
  final r = Random(seed);
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    final g = (p.x / w * 90 + p.y / h * 60).round(), n = r.nextInt(28) - 14;
    p
      ..r = (20 + g + n).clamp(0, 255)
      ..g = (10 + g ~/ 2 + n).clamp(0, 255)
      ..b = (60 + g + n).clamp(0, 255);
    if (r.nextInt(180) == 0) {
      p
        ..r = 255
        ..g = 255
        ..b = 255;
    }
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 92));
}

/// Its left half red and its right half blue.
Uint8List halves(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (final p in im) {
    p
      ..r = p.x < w ~/ 2 ? 220 : 10
      ..g = 10
      ..b = p.x < w ~/ 2 ? 10 : 220;
  }
  return Uint8List.fromList(img.encodePng(im));
}

/// A white disc on no ground at all: a logo.
Uint8List logo(int side) {
  final im = img.Image(width: side, height: side, numChannels: 4);
  for (final p in im) {
    final dx = p.x - side / 2, dy = p.y - side / 2;
    final inside = dx * dx + dy * dy < side * side / 9;
    p
      ..r = 255
      ..g = 255
      ..b = 255
      ..a = inside ? 255 : 0;
  }
  return Uint8List.fromList(img.encodePng(im));
}

img.Image shown(String b64) => img.decodeImage(base64.decode(b64))!;
bool isJpeg(List<int> b) => b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;
bool isPng(List<int> b) => b.length > 3 && b[0] == 0x89 && b[1] == 0x50;

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the stand-in the circle carries', () {
    test('a picture full of detail is still sharp: a face 256 across and a banner 300 or more, where a PNG gave 96 and 192', () async {
      final square = art(1200, 1200), wide = art(3000, 1000);
      final face = (await circlePictureOf(square))!;
      expect(face.length, lessThanOrEqualTo(circlePictureMax));
      expect(isJpeg(base64.decode(face)), isTrue);
      expect([shown(face).width, shown(face).height], [256, 256]);
      final banner = (await circleBannerOf(wide))!;
      expect(banner.length, lessThanOrEqualTo(circleBannerMax));
      expect(isJpeg(base64.decode(banner)), isTrue);
      expect(shown(banner).width, greaterThanOrEqualTo(300));
      expect(shown(banner).width, shown(banner).height * 3, reason: 'three wide to one high');
    });

    test('the part chosen is the part kept', () async {
      final bytes = halves(1200, 600);
      // The right half, whole: all blue.
      final right = shown((await circlePictureOf(bytes, crop: const ui.Rect.fromLTWH(0.5, 0, 0.5, 1)))!);
      final a = right.getPixel(right.width ~/ 2, right.height ~/ 2);
      expect(a.b > 180 && a.r < 60, isTrue, reason: 'blue, the half chosen: r${a.r} b${a.b}');
      // A band of the left half as a banner: all red.
      final left = shown((await circleBannerOf(bytes, crop: const ui.Rect.fromLTWH(0, 0.25, 0.5, 1 / 3)))!);
      final b = left.getPixel(left.width - 2, left.height ~/ 2);
      expect(b.r > 180 && b.b < 60, isTrue, reason: 'red to its far edge: r${b.r} b${b.b}');
      // None chosen: the middle, which holds both.
      final middle = shown((await circleBannerOf(bytes))!);
      expect(middle.getPixel(2, 2).r > 180 && middle.getPixel(middle.width - 3, 2).b > 180, isTrue);
    });

    test('a logo on no ground keeps it (a PNG), and a small one is not blown up', () async {
      final face = (await circlePictureOf(logo(600)))!;
      expect(isPng(base64.decode(face)), isTrue, reason: 'a JPEG would put it on black');
      final d = shown(face);
      expect(d.getPixel(1, 1).a, 0, reason: 'its corner is still clear');
      expect(d.getPixel(d.width ~/ 2, d.height ~/ 2).a, 255);
      final small = shown((await circlePictureOf(art(100, 100)))!);
      expect([small.width, small.height], [100, 100], reason: 'no larger than it is');
    });

    test('a lighter one, for a circle with little room left, is the same part in a third of the characters', () async {
      final wide = art(3000, 1000);
      final light = (await circleBannerOf(wide, most: circleBannerMax ~/ 3))!;
      expect(light.length, lessThanOrEqualTo(circleBannerMax ~/ 3));
      expect(shown(light).width, greaterThanOrEqualTo(150));
    });

    test('what is no picture is said to be none, and makes nothing', () async {
      final words = Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>'));
      expect(await pictureSizeOf(words), isNull);
      expect(await circleBannerOf(words), isNull);
      expect(await circlePictureOf(words), isNull);
      expect(await cutPictureOf(words, shape: 3, mostAcross: 100), isNull);
      expect(await pictureSizeOf(art(320, 200)), const ui.Size(320, 200));
    });
  });

  group('the part chosen, cut at the picture\'s own resolution', () {
    test('every pixel it has there: a band of 1800 by 600 out of 3000 by 2000', () async {
      final cut = (await cutPictureOf(art(3000, 2000), crop: const ui.Rect.fromLTWH(0.1, 0.2, 0.6, 0.3), shape: 3, mostAcross: circleBannerMost))!;
      expect([cut.width, cut.height, cut.kind], [1800, 600, 'jpg']);
      expect(isJpeg(cut.bytes), isTrue);
      final d = img.decodeJpg(cut.bytes)!;
      expect([d.width, d.height], [1800, 600]);
    });

    test('no larger than the picture is, and brought down only past the most a screen shows', () async {
      final small = (await cutPictureOf(art(900, 300), shape: 3, mostAcross: circleBannerMost))!;
      expect([small.width, small.height], [900, 300], reason: 'not made larger');
      final large = (await cutPictureOf(art(3000, 1000), shape: 3, mostAcross: 1200))!;
      expect([large.width, large.height], [1200, 400]);
      final face = (await cutPictureOf(art(1500, 1000), crop: const ui.Rect.fromLTWH(0, 0, 0.5, 0.75), shape: 1, mostAcross: circleFaceMost))!;
      expect([face.width, face.height], [750, 750], reason: 'the square chosen');
    });

    test('a logo on no ground goes up as a PNG, its ground still clear', () async {
      final cut = (await cutPictureOf(logo(600), shape: 1, mostAcross: circleFaceMost))!;
      expect([cut.kind, cut.width, cut.height], ['png', 600, 600]);
      final d = img.decodePng(cut.bytes)!;
      expect(d.getPixel(2, 2).a, 0);
    });
  });

  group('how the circle names its picture at full size', () {
    final file = SpaceFile.fromJson({'id': 'cd' * 16, 'n': 'picture.jpg', 'z': 310000, 'm': 'image/jpeg', 'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'p': 'AAAAAAAAAAA=', 'u': 'Book Club', 'at': 1}, by: 'x')!;
    final banner = SpaceFile.fromJson({'id': 'ab' * 16, 'n': 'banner.jpg', 'z': 900000, 'm': 'image/jpeg', 'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'p': 'AAAAAAAAAAA=', 'u': 'Book Club', 'at': 1}, by: 'x')!;

    test('beside its stand-in, kept through other changes, and gone with the picture', () async {
      final circles = Circles.forTest(signer: KeysSigner(NetKeys.generate()));
      addTearDown(circles.clear);
      var c = (await circles.make(name: 'Book Club'))!;
      Circle now() => circles.bySeed(c.seed)!;
      expect(now().pictureFile, isNull);
      expect(await circles.edit(c, picture: 'c21hbGw=', pictureFile: file.withoutThumb().toJson()), isTrue);
      expect(now().picture, 'c21hbGw=');
      expect(SpaceFile.fromJson(now().pictureFile, by: '')!.name, 'picture.jpg');
      // A banner set and the circle renamed: the picture's file is still named.
      expect(await circles.edit(now(), banner: 'YmFubmVy', bannerFile: banner.withoutThumb().toJson()), isTrue);
      expect(await circles.edit(now(), name: 'Book Club 2'), isTrue);
      expect(SpaceFile.fromJson(now().pictureFile, by: '')!.id, file.id);
      expect(SpaceFile.fromJson(now().manifest.bannerFile, by: '')!.id, banner.id);
      // Read again from what goes round: the same.
      final again = CircleManifest.fromJson(now().manifest.toJson())!;
      expect(SpaceFile.fromJson(again.pictureFile, by: '')!.size, 310000);
      // Another picture with no file of its own (its upload failed): the old picture's file does not stand in for it.
      expect(await circles.edit(now(), picture: 'bmV3'), isTrue);
      expect([now().picture, now().pictureFile], ['bmV3', isNull]);
      expect(now().manifest.bannerFile, isNotNull, reason: 'the banner is another matter');
      // And the icon instead: nothing of a picture is left.
      expect(await circles.edit(now(), picture: 'c21hbGw=', pictureFile: file.withoutThumb().toJson()), isTrue);
      expect(await circles.edit(now(), clearPicture: true), isTrue);
      expect([now().picture, now().pictureFile, now().manifest.extra.containsKey('pf')], [isNull, isNull, isFalse]);
    });

    test('a build from before this changes the picture and passes the old file on: it is not drawn for the new one', () {
      final m = CircleManifest(owner: '02${'ab' * 32}', name: 'Book Club', version: 2, picture: 'c21hbGw=');
      final set = m.next(extra: {...m.extra, 'pf': {...file.withoutThumb().toJson(), 'of': CircleManifest.pictureMark('c21hbGw=')}});
      expect(set.pictureFile, isNotNull);
      // The older build: a new picture, and every field it doesn't know kept as it was.
      final older = set.next(picture: 'b3RoZXI=');
      expect(older.extra.containsKey('pf'), isTrue, reason: 'passed on, as any field it does not know');
      expect(older.pictureFile, isNull, reason: 'it is the whole of another picture');
      expect(set.next(name: 'Other').pictureFile, isNotNull);
    });
  });

  // The whole of it, as a computer does it: the picture is the person's own file, read where it lies.
  group('choosing one on a computer', () {
    final circle = Circle(seed: '7' * 64, owner: '', manifest: CircleManifest.placeholder(owner: '', name: 'Book Club'));

    /// Real time and frames by turns, until [done]: a picture is read and squeezed off the page's own clock.
    Future<void> until(WidgetTester tester, bool Function() done, String what) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue, reason: 'still waiting for $what');
    }

    Future<void> ask(WidgetTester tester, Future<void> Function(BuildContext context) flow) async {
      final sheet = await loadSheet(tester);
      await pumpScreen(
        tester,
        sheet,
        Builder(
          builder: (context) => Center(
            child: GestureDetector(key: const ValueKey('ask'), onTap: () => flow(context), child: const SizedBox(width: 40, height: 40, child: ColoredBox(color: Color(0xFF888888)))),
          ),
        ),
        AppState(),
        size: const Size(900, 760),
        platform: 'desktop',
      );
      await tester.tap(_key('ask'));
    }

    testWidgets('a banner: positioned, sent whole from a copy of the app\'s own, and the picture chosen left as it was', (tester) async {
      final folder = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('own-pictures-')))!;
      addTearDown(() => folder.deleteSync(recursive: true));
      final own = File('${folder.path}/Holiday banner.jpg')..writeAsBytesSync((await tester.runAsync(() async => art(2400, 1600)))!);
      final before = own.readAsBytesSync();
      final sent = <({String path, String name, int width, int height})>[];
      String? standIn;
      Map<String, Object?>? named;
      bool? set;
      await ask(tester, (context) async {
        set = await chooseCircleBanner(
          context,
          circle,
          choose: () async => [own.path],
          up: (c, file, name) async {
            final d = img.decodeImage(file.readAsBytesSync())!;
            sent.add((path: file.path, name: name, width: d.width, height: d.height));
            return {'id': 'ab' * 16, 'n': name, 'z': file.lengthSync()};
          },
          change: (c, {picture, pictureFile, banner, bannerFile}) async {
            standIn = banner;
            named = bannerFile;
            return true;
          },
        );
      });
      await until(tester, () => _key('picture-crop').evaluate().isNotEmpty, 'the window to position it under');
      expect(find.text('Position your banner'), findsOneWidget);
      await tester.tap(_key('picture-crop-use'));
      await until(tester, () => set != null, 'the banner to be set');

      expect(set, isTrue);
      expect(sent, hasLength(1));
      // The band chosen (the middle, three to one, of 2400 by 1600), every pixel of it.
      expect([sent.single.name, sent.single.width, sent.single.height], ['banner.jpg', 2400, 800]);
      expect(sent.single.path, isNot(own.path), reason: 'what goes up is a file the app made');
      expect(File(sent.single.path).existsSync(), isFalse, reason: 'and lets go of once it is up');
      expect(named, {'id': 'ab' * 16, 'n': 'banner.jpg', 'z': isA<int>()});
      expect(isJpeg(base64.decode(standIn!)), isTrue);
      expect(shown(standIn!).width, greaterThanOrEqualTo(300));
      // The person's own picture: still there, and not a byte of it changed.
      expect(own.existsSync(), isTrue);
      expect(own.readAsBytesSync(), before);
      expect(find.text('Banner set'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('a picture for its face: a round window, the square chosen whole, and the stand-in with its file', (tester) async {
      final folder = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('own-pictures-')))!;
      addTearDown(() => folder.deleteSync(recursive: true));
      final own = File('${folder.path}/logo.png')..writeAsBytesSync((await tester.runAsync(() async => art(1500, 1000)))!);
      final sent = <({String name, int width, int height})>[];
      String? standIn;
      Map<String, Object?>? named;
      bool? set;
      await ask(tester, (context) async {
        set = await chooseCirclePicture(
          context,
          circle,
          choose: () async => [own.path],
          up: (c, file, name) async {
            final d = img.decodeImage(file.readAsBytesSync())!;
            sent.add((name: name, width: d.width, height: d.height));
            return {'id': 'cd' * 16, 'n': name};
          },
          change: (c, {picture, pictureFile, banner, bannerFile}) async {
            standIn = picture;
            named = pictureFile;
            return true;
          },
        );
      });
      await until(tester, () => _key('picture-crop').evaluate().isNotEmpty, 'the window to position it under');
      expect(find.text('Position your picture'), findsOneWidget);
      await tester.tap(_key('picture-crop-use'));
      await until(tester, () => set != null, 'the picture to be set');
      expect(set, isTrue);
      expect(sent.single, (name: 'picture.jpg', width: 1000, height: 1000), reason: 'the middle square, at the picture\'s own size');
      expect([shown(standIn!).width, named?['n']], [256, 'picture.jpg']);
      expect(own.existsSync(), isTrue);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('one that can\'t be used says why: not a picture, a full copy that didn\'t go up, a circle that can\'t be changed', (tester) async {
      final folder = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('own-pictures-')))!;
      addTearDown(() => folder.deleteSync(recursive: true));
      final drawing = File('${folder.path}/drawing.svg')..writeAsStringSync('<svg xmlns="http://www.w3.org/2000/svg"/>');
      final photo = File('${folder.path}/photo.jpg')..writeAsBytesSync((await tester.runAsync(() async => art(1200, 800)))!);
      // Not a picture this device reads: named, and nothing is asked of the circle.
      var changed = 0;
      bool? set;
      await ask(tester, (context) async {
        set = await chooseCircleBanner(context, circle, choose: () async => [drawing.path], up: (c, f, n) async => {}, change: (c, {picture, pictureFile, banner, bannerFile}) async {
          changed++;
          return true;
        });
      });
      await until(tester, () => set != null, 'it to be turned away');
      expect([set, changed], [false, 0]);
      expect(find.text('drawing.svg isn\'t a picture this device can read. Try a JPEG or a PNG.'), findsOneWidget);
      expect(_key('picture-crop'), findsNothing);
      await tester.pump(const Duration(seconds: 8));

      // The full copy doesn't go up: the banner is still set, from its stand-in, and what the relay said is told.
      Map<String, Object?>? named = {'unset': 1};
      set = null;
      await ask(tester, (context) async {
        set = await chooseCircleBanner(context, circle, choose: () async => [photo.path], up: (c, f, n) async => throw StateError('This space is full.'), change: (c, {picture, pictureFile, banner, bannerFile}) async {
          named = bannerFile;
          return banner != null;
        });
      });
      await until(tester, () => _key('picture-crop').evaluate().isNotEmpty, 'the window');
      await tester.tap(_key('picture-crop-use'));
      await until(tester, () => set != null, 'the banner to be set');
      expect([set, named], [true, isNull]);
      expect(find.text('The banner is set, but its full-size copy didn\'t go up: This space is full.. Choose it again to try once more.'), findsNothing, reason: 'said once, without a doubled stop');
      expect(find.textContaining('its full-size copy didn\'t go up: This space is full'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));

      // The circle can't be changed from here: said, and why.
      set = null;
      await ask(tester, (context) async {
        set = await chooseCircleBanner(context, circle, choose: () async => [photo.path], up: (c, f, n) async => {'id': 'ab' * 16}, change: (c, {picture, pictureFile, banner, bannerFile}) async => false);
      });
      await until(tester, () => _key('picture-crop').evaluate().isNotEmpty, 'the window');
      await tester.tap(_key('picture-crop-use'));
      await until(tester, () => set != null, 'it to be refused');
      expect(set, isFalse);
      expect(find.textContaining('The banner couldn\'t be set:'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
    });

    testWidgets('thought better of at the window: nothing is sent and nothing changed', (tester) async {
      final folder = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('own-pictures-')))!;
      addTearDown(() => folder.deleteSync(recursive: true));
      final own = File('${folder.path}/photo.jpg')..writeAsBytesSync((await tester.runAsync(() async => art(1200, 800)))!);
      var asked = 0;
      bool? set;
      await ask(tester, (context) async {
        set = await chooseCircleBanner(context, circle, choose: () async => [own.path], up: (c, f, n) async {
          asked++;
          return {};
        }, change: (c, {picture, pictureFile, banner, bannerFile}) async {
          asked++;
          return true;
        });
      });
      await until(tester, () => _key('picture-crop').evaluate().isNotEmpty, 'the window');
      await tester.tap(_key('picture-crop-cancel'));
      await until(tester, () => set != null, 'it to be let go');
      expect([set, asked], [false, 0]);
      expect(own.existsSync(), isTrue);
    });
  });
}
