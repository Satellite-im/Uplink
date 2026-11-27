import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/me/picture_make.dart';
import 'package:ghost_messaging/me/pictures.dart';
import 'package:image/image.dart' as img;

/// A photo-like picture, [w] by [h]: smooth light with shapes and a grain, as a phone's camera makes them.
Uint8List _photo(int w, int h, {double grain = 18}) {
  final r = Random(7);
  final p = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = sqrt(pow(x - w * 0.45, 2) + pow(y - h * 0.4, 2)) / w;
      final n = (r.nextDouble() - 0.5) * grain;
      final face = d < 0.22 ? 60.0 : 0.0;
      p.setPixelRgb(x, y, (200 - d * 180 + face + n).clamp(0, 255), (150 + sin(x / 23) * 30 + n).clamp(0, 255), (90 + y / h * 120 + n).clamp(0, 255));
    }
  }
  return img.encodeJpg(p, quality: 92);
}

int _sideOf(String b64) => img.decodeJpg(base64Decode(b64))!.width;

/// Profile pictures made sharp (Matt, 2026-11-20: "my uploaded profile picture is super blurry": a photo came out 72
/// pixels across, the most a PNG of 24000 characters held, and was drawn at up to 96 points).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a photo is made 256 pixels across as JPEG, with a small stand-in builds from before take', (tester) async {
    final made = (await tester.runAsync(() => profilePictureOf(_photo(1600, 1200))))!;
    expect(_sideOf(made.sharp), ProfilePictures.sharpSide);
    expect(img.decodeJpg(base64Decode(made.sharp))!.height, ProfilePictures.sharpSide, reason: 'square');
    expect(made.sharp.length, lessThanOrEqualTo(ProfilePictures.sharpMost));
    expect(made.small, isNotEmpty);
    expect(made.small.length, lessThanOrEqualTo(ProfilePictures.smallMost));
    expect(_sideOf(made.small), greaterThanOrEqualTo(64));
  });

  testWidgets('a picture all detail still fits, a little smaller', (tester) async {
    final made = (await tester.runAsync(() => profilePictureOf(_photo(1000, 1000, grain: 255))))!;
    expect(made.sharp.length, lessThanOrEqualTo(ProfilePictures.sharpMost));
    expect(made.small.length, lessThanOrEqualTo(ProfilePictures.smallMost));
    debugPrint('all detail: ${_sideOf(made.sharp)} px');
  });

  // Matt, 2026-11-25: "the profile picture itself is still very blurry on the profile popup"; "show a profile picture
  // cropping feature and store previous profile pictures so you can roll back easily".
  testWidgets('a larger one is made for this person\'s own screens, never larger than the photo, and none from a small one', (tester) async {
    final made = (await tester.runAsync(() => profilePictureOf(_photo(1600, 1200))))!;
    expect(_sideOf(made.full), ProfilePictures.fullSide);
    expect(made.full.length, lessThanOrEqualTo(ProfilePictures.fullMost));
    final middling = (await tester.runAsync(() => profilePictureOf(_photo(520, 700))))!;
    expect(_sideOf(middling.full), 512, reason: 'the largest size the photo holds');
    final small = (await tester.runAsync(() => profilePictureOf(_photo(300, 300))))!;
    expect(small.full, isEmpty);
    expect(_sideOf(small.sharp), ProfilePictures.sharpSide);
  });

  testWidgets('the part chosen is the part kept', (tester) async {
    // Left half red, right half blue.
    final p = img.Image(width: 800, height: 400);
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 800; x++) {
        p.setPixelRgb(x, y, x < 400 ? 220 : 20, 20, x < 400 ? 20 : 220);
      }
    }
    final bytes = img.encodeJpg(p, quality: 92);
    final left = (await tester.runAsync(() => profilePictureOf(bytes, crop: const Rect.fromLTWH(0, 0, 0.5, 1))))!;
    final right = (await tester.runAsync(() => profilePictureOf(bytes, crop: const Rect.fromLTWH(0.5, 0, 0.5, 1))))!;
    final l = img.decodeJpg(base64Decode(left.sharp))!.getPixel(128, 128), r = img.decodeJpg(base64Decode(right.sharp))!.getPixel(128, 128);
    expect(l.r, greaterThan(180));
    expect(l.b, lessThan(70));
    expect(r.b, greaterThan(180));
    expect(r.r, lessThan(70));
    // None given: the middle, half of each.
    final middle = img.decodeJpg(base64Decode((await tester.runAsync(() => profilePictureOf(bytes)))!.sharp))!;
    expect(middle.getPixel(20, 128).r, greaterThan(180));
    expect(middle.getPixel(236, 128).b, greaterThan(180));
  });

  test('Me draws its own screens from the larger one, and keeps the pictures it had before, the newest first', () async {
    final me = Me.forTest();
    final store = MemoryMeStore();
    await me.start(store, ValueNotifier(0), () => null);
    ProfilePicture pic(String n) => ProfilePicture(sharp: 'sharp$n', small: 'small$n', full: 'full$n');
    me.setPicture(pic('A'));
    expect(me.pictureOwn, 'fullA');
    expect(me.pictureSharp, 'sharpA', reason: 'what friends are sent is not the larger one');
    expect(me.picturesPast, isEmpty);
    me.setPicture(pic('B'));
    expect(me.picturesPast, ['fullA']);
    // One with no larger copy: its own screens draw the sharp one.
    me.setPicture(const ProfilePicture(sharp: 'sharpC', small: 'smallC'));
    expect(me.pictureOwn, 'sharpC');
    expect(me.picturesPast, ['fullB', 'fullA']);
    // Back to A as it was kept: it leaves the earlier ones, and C joins them.
    me.setPicture(const ProfilePicture(sharp: 'sharpA2', small: 'smallA2', full: 'fullA'));
    expect(me.pictureOwn, 'fullA');
    expect(me.picturesPast, ['sharpC', 'fullB']);
    // Taken away: still there to go back to.
    me.setPicture(null);
    expect(me.pictureOwn, isEmpty);
    expect(me.picturesPast, ['fullA', 'sharpC', 'fullB']);
    me.forgetPast('sharpC');
    expect(me.picturesPast, ['fullA', 'fullB']);
    // No more than a few are kept.
    for (var i = 0; i < 10; i++) {
      me.setPicture(pic('$i'));
    }
    expect(me.picturesPast, hasLength(Me.pastMost));
    expect(me.picturesPast.first, 'full8');
  });

  test('both go to friends in one packet of the hub\'s 60 KB, with room for the rest of a profile', () {
    expect(ProfilePictures.sharpMost + ProfilePictures.smallMost + 6000, lessThan(60 * 1024));
    expect(ProfilePictures.smallMost, lessThanOrEqualTo(ProfilePictures.oldMost));
    expect(ProfilePictures.sharpMost, lessThanOrEqualTo(ProfilePictures.most));
  });

  test('Me keeps both; the small one is the picture old builds and a greeting\'s mark know; taking it away clears both', () async {
    final me = Me.instance;
    await me.start(MemoryMeStore(), ValueNotifier(0), () => null);
    me.setPicture(const ProfilePicture(sharp: 'c2hhcnA=', small: 'c21hbGw='));
    expect((me.picture, me.pictureSharp), ('c21hbGw=', 'c2hhcnA='));
    me.setProfile(picture: 'b2xk');
    expect((me.picture, me.pictureSharp), ('b2xk', 'b2xk'), reason: 'set the old way: one picture');
    me.setPicture(const ProfilePicture(sharp: 'c2hhcnA=', small: 'c21hbGw='));
    me.setPicture(null);
    expect((me.picture, me.pictureSharp), ('', ''));
  });

  test('a friend\'s profile: the sharp one where it is said, else the small one', () {
    expect(Buddies.saidOf({'p': 'c21hbGw=', 'pp': 'c2hhcnA=', 'st': ''}).picture, 'c2hhcnA=');
    expect(Buddies.saidOf({'p': 'c21hbGw=', 'st': ''}).picture, 'c21hbGw=', reason: 'a build from before 0.10.4');
    expect(Buddies.saidOf({'st': ''}).picture, '', reason: 'none');
  });

  test('in a space the sharp one is kept under the small one\'s mark, which the greeting names', () {
    const small = 'c21hbGw=', sharp = 'c2hhcnA=';
    ProfilePictures.instance.keep('maya', sharp, markOf: small);
    expect(ProfilePictures.instance.of('maya', hash: ProfilePictures.hashOf(small)), sharp);
    expect(ProfilePictures.instance.of('maya', hash: ProfilePictures.hashOf('b3RoZXI=')), isNull, reason: 'a newer one');
  });
}
