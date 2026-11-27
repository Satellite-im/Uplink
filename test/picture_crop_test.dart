import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/picture_crop.dart';

import 'support/list_harness.dart';

/// Choosing which part of a picture is your profile picture (lib/ui/picture_crop.dart; Matt, 2026-11-25: "show a
/// profile picture cropping feature"): the square the window shows, as shares of the picture.
Finder _key(String k) => find.byKey(ValueKey(k));

/// One clear pixel: the card is asked about its window, not about what is drawn in it.
final _dot = MemoryImage(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));

void main() {
  test('the window over a picture untouched is its middle square', () {
    // A wide picture drawn 400 by 200 under a window 200 across, its middle in the window.
    final r = cropShares(Matrix4.translationValues(-100, 0, 0), 200, const Size(400, 200));
    expect(r.left, closeTo(0.25, 1e-9));
    expect(r.top, closeTo(0, 1e-9));
    expect(r.width, closeTo(0.5, 1e-9));
    expect(r.height, closeTo(1, 1e-9));
  });

  test('made twice as large and dragged to its top left corner, the window holds that quarter', () {
    final r = cropShares(Matrix4.identity()..scaleByDouble(2, 2, 1, 1), 200, const Size(400, 200));
    expect(r.left, closeTo(0, 1e-9));
    expect(r.top, closeTo(0, 1e-9));
    expect(r.width, closeTo(0.25, 1e-9));
    expect(r.height, closeTo(0.5, 1e-9));
  });

  testWidgets('the card: Use picture gives the middle square, Larger a smaller part of it, Cancel nothing', (tester) async {
    final sheet = await loadSheet(tester);
    Object? got = 'unasked';
    Future<void> open() async {
      got = 'unasked';
      await pumpScreen(
        tester,
        sheet,
        Builder(
          builder: (context) => Center(
            child: GestureDetector(
              key: const ValueKey('ask'),
              onTap: () async => got = await Navigator.of(context).push<Rect>(PageRouteBuilder<Rect>(opaque: false, pageBuilder: (context, _, _) => PictureCrop(image: _dot, size: const Size(1200, 600)))),
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
    }

    await open();
    expect(_key('picture-crop'), findsOneWidget);
    await tester.tap(_key('picture-crop-use'));
    await settle(tester);
    final whole = got as Rect;
    expect(whole.left, closeTo(0.25, 0.001));
    expect(whole.width, closeTo(0.5, 0.001));
    expect(whole.height, closeTo(1, 0.001));

    await open();
    await tester.tap(_key('picture-crop-larger'));
    await settle(tester);
    await tester.tap(_key('picture-crop-use'));
    await settle(tester);
    final part = got as Rect;
    expect(part.width, closeTo(0.4, 0.001), reason: 'a quarter larger: four fifths of what it held');
    expect(part.height, closeTo(0.8, 0.001));
    expect(part.center.dx, closeTo(0.5, 0.001), reason: 'about its middle');
    expect(part.center.dy, closeTo(0.5, 0.001));

    await open();
    // Dragged right: the window holds what was further left.
    await tester.drag(_key('picture-crop-view'), const Offset(60, 0));
    await settle(tester);
    await tester.tap(_key('picture-crop-use'));
    await settle(tester);
    expect((got as Rect).left, lessThan(0.25));

    await open();
    await tester.tap(_key('picture-crop-cancel'));
    await settle(tester);
    expect(got, isNull);
  });
}
