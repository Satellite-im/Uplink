import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/loading_logo.dart';

import 'support/drawn_ink.dart';

/// The logo as it turns while the app loads (lib/art/loading_logo.dart; Matt, 2026-11-27: "update the update screen to
/// use the loading_logo.mp4 and make it larger so it is visible, also on the phone add a loading splash screen using
/// the same logo"): his film of it, carried as a picture that moves and drawn in the page's ink. Pictures in
/// build/themes/loading-logo.
void main() {
  test('the film is in the app, whole: every frame of it, going round for good', () async {
    final file = File(LoadingLogo.asset);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), lessThan(1200 * 1024), reason: 'under 1.2 MB of every platform\'s download');
    final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
    expect(codec.frameCount, 97, reason: 'the film\'s 97 frames (art/loading_logo.mp4, tool/loading_logo.sh)');
    expect(codec.repetitionCount, -1, reason: 'round and round, for as long as it is shown');
    final first = await codec.getNextFrame();
    expect((first.image.width, first.image.height), (640, 548));
    expect(first.image.width / first.image.height, closeTo(LoadingLogo.shape, 0.0001));
    expect(first.duration, const Duration(milliseconds: 42), reason: 'the film\'s 24 frames a second');
    // It comes back to where it began: the last frame is the first, near enough that going round shows no jump.
    final a = (await first.image.toByteData())!;
    ui.FrameInfo? last;
    for (var i = 1; i < codec.frameCount; i++) {
      last?.image.dispose();
      last = await codec.getNextFrame();
    }
    final b = (await last!.image.toByteData())!;
    var apart = 0;
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if ((a.getUint8(i) - b.getUint8(i)).abs() > 96) apart++;
    }
    expect(apart / (a.lengthInBytes / 4), lessThan(0.01), reason: 'under one dot in a hundred differs much between the last frame and the first');
    // And its first frame by itself, for a device asked to move less: the same picture, near enough, and small.
    final stillFile = File(LoadingLogo.still);
    expect(stillFile.lengthSync(), lessThan(40 * 1024));
    final stillCodec = await ui.instantiateImageCodec(stillFile.readAsBytesSync());
    expect(stillCodec.frameCount, 1);
    final still = await stillCodec.getNextFrame();
    expect((still.image.width, still.image.height), (640, 548));
    final c = (await still.image.toByteData())!;
    var off = 0;
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if ((a.getUint8(i) - c.getUint8(i)).abs() > 96) off++;
    }
    expect(off / (a.lengthInBytes / 4), lessThan(0.005), reason: 'the still is where the film begins');
    still.image.dispose();
    stillCodec.dispose();
    first.image.dispose();
    last.image.dispose();
    codec.dispose();
  });

  test('a black and white picture is drawn in a colour: as solid as the picture is bright', () {
    final m = LoadingLogo.inked(const Color(0xFF204060));
    expect([m[4], m[9], m[14]], [0x20, 0x40, 0x60], reason: 'the colour\'s own red, green and blue, whatever the picture has');
    for (final i in [0, 1, 2, 3, 5, 6, 7, 8, 10, 11, 12, 13, 16, 17, 18]) {
      expect(m[i], 0, reason: 'nothing of the picture\'s own colour, and how solid comes of its red alone ($i)');
    }
    // How solid, for how bright the picture is there: none at the film's black and a little over it (what packing
    // the film small leaves in the black), all of it at its white and a little under.
    double solid(double bright) => (m[15] * bright + m[19]).clamp(0, 255);
    expect(solid(0), 0);
    expect(solid(LoadingLogo.floor), closeTo(0, 0.001));
    expect(solid(LoadingLogo.ceiling), closeTo(255, 0.001));
    expect(solid(255), 255);
    expect(solid(127.5), closeTo(127.5, 0.5), reason: 'half bright is half solid: an edge is as soft as the film has it');
  });

  // On a light page, a dark one, and one that is neither black nor white: the logo in the ink, the page everywhere
  // else, and nothing of the film's black.
  for (final (name, page, ink) in [
    ('light', const Color(0xFFFFFFFF), const Color(0xFF000000)),
    ('dark', const Color(0xFF000000), const Color(0xFFFFFFFF)),
    ('coloured', const Color(0xFFFDF6E3), const Color(0xFF2B6CB0)),
  ]) {
    testWidgets('it is drawn in the page\'s ink on the page ($name)', (tester) async {
      tester.view.physicalSize = const Size(300, 340) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ColoredBox(color: page, child: Center(child: LoadingLogo(width: 248, color: ink))));
      // Nothing in its place until the film's first frame is read, and nothing wrong.
      expect(tester.getSize(find.byType(LoadingLogo)), Size(248, 248 / LoadingLogo.shape));
      expect(tester.takeException(), isNull);
      expect(find.byType(RawImage), findsNothing);
      await filmShown(tester, find.byType(RawImage));
      final drawn = await Drawn.of(tester, tester.element(find.byType(LoadingLogo)));
      drawn.keep('build/themes/loading-logo/$name.png');
      final box = tester.getRect(find.byType(LoadingLogo));
      final shares = drawn.shares(box, ink: ink, page: page);
      // At rest the logo's bubble is about two fifths of its place and the page the rest of it (the letters, and
      // round it): a black slab where the logo should be would have no page in it, a logo not drawn no ink.
      expect(shares.ink, inInclusiveRange(0.15, 0.4), reason: '$shares');
      expect(shares.page, inInclusiveRange(0.5, 0.85), reason: '$shares');
      expect(shares.ink + shares.page, greaterThan(0.93), reason: 'only its edges are between the two: $shares');
      expect(shares.other, 0, reason: 'no colour but the ink, the page and between them: $shares');
      // The page untouched round it, to the last part in 255: the film's black is nothing, not nearly black.
      expect(drawn.at(const Offset(4, 4)), page);
      expect(drawn.not(Rect.fromLTWH(box.left, box.top, 40, 30), page), 0, reason: 'the corner of its place, where the logo never is');
      expect(drawn.not(Rect.fromLTWH(box.right - 40, box.bottom - 30, 40, 30), page), 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a see-through ink is the solid one drawn see-through', (tester) async {
    await tester.pumpWidget(const Center(child: LoadingLogo(width: 248, color: Color(0x80204060))));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, closeTo(0x80 / 255, 0.001));
    expect(LoadingLogo.inked(const Color(0x80204060)), LoadingLogo.inked(const Color(0xFF204060)));
    await tester.pumpWidget(const Center(child: LoadingLogo(width: 248, color: Color(0xFF204060))));
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('a device asked to move less shows the film\'s first frame and no more, drawn the same way', (tester) async {
    tester.view.physicalSize = const Size(300, 340) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    const page = Color(0xFFFFFFFF), ink = Color(0xFF112233);
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: ColoredBox(color: page, child: Center(child: LoadingLogo(width: 248, color: ink))),
    ));
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, LoadingLogo.still);
    expect(image.color, isNull, reason: 'drawn in the ink as the film is, not tinted: a tinted picture left a line round its place on a phone');
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(tester.getSize(find.byType(LoadingLogo)), Size(248, 248 / LoadingLogo.shape));
    await filmShown(tester, find.byType(RawImage));
    final drawn = await Drawn.of(tester, tester.element(find.byType(LoadingLogo)));
    drawn.keep('build/themes/loading-logo/still.png');
    final box = tester.getRect(find.byType(LoadingLogo));
    final shares = drawn.shares(box, ink: ink, page: page);
    expect(shares.ink, inInclusiveRange(0.15, 0.4), reason: '$shares');
    expect(shares.page, inInclusiveRange(0.5, 0.85), reason: '$shares');
    expect(shares.other, 0, reason: '$shares');
    // Nothing along the edges of its place.
    for (final edge in [Rect.fromLTWH(box.left, box.top, box.width, 3), Rect.fromLTWH(box.left, box.bottom - 3, box.width, 3), Rect.fromLTWH(box.left, box.top, 3, box.height), Rect.fromLTWH(box.right - 3, box.top, 3, box.height)]) {
      expect(drawn.not(edge, page), 0, reason: 'a line along $edge');
    }
  });

  testWidgets('it says once when it is first on the page', (tester) async {
    final said = <bool>[];
    await tester.pumpWidget(Center(child: LoadingLogo(width: 248, color: const Color(0xFF000000), onShown: said.add)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(said, isEmpty, reason: 'not before the film\'s first frame is read');
    await filmShown(tester, find.byType(RawImage));
    await tester.pump();
    expect(said, [true]);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(said, [true], reason: 'once, not at every frame of the film');
  });

  testWidgets('a build that can\'t read it leaves its place empty and says so', (tester) async {
    final said = <bool>[];
    await tester.pumpWidget(DefaultAssetBundle(
      bundle: _Nothing(),
      child: Center(child: LoadingLogo(width: 248, color: const Color(0xFF000000), onShown: said.add)),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(said, [false]);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.getSize(find.byType(LoadingLogo)), Size(248, 248 / LoadingLogo.shape));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the film is let go of once the logo is gone', (tester) async {
    await tester.pumpWidget(const Center(child: LoadingLogo(width: 248, color: Color(0xFF000000))));
    await filmShown(tester, find.byType(RawImage));
    late Object key;
    await tester.runAsync(() async => key = await const AssetImage(LoadingLogo.asset).obtainKey(ImageConfiguration.empty));
    expect(imageCache.containsKey(key), isTrue);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(imageCache.containsKey(key), isFalse, reason: 'not kept for as long as the app runs');
  });
}

/// A build with none of the app's pictures in it.
class _Nothing extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw FlutterError('no $key in this build');
}
