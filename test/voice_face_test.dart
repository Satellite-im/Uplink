import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/packs/resource_pack.dart';
import 'package:ghost_messaging/ui/dialup/dialup.dart';
import 'package:ghost_messaging/ui/ripple_avatar.dart';
import 'package:glacier/glacier.dart';

import 'resource_pack_test.dart' show madePack;

// A face in a call takes its look's shape, and its talking rings with it (lib/ui/ripple_avatar.dart, lib/ui/dialup/
// parts.dart's VoiceFace; Matt, 2026-11-27: "in voice chat I should have the square icons with the talking wobbles
// being square like they are in the sidebar and make the profile pictures a squircle with the same texture outline we
// use for the user profile pictures"): round where faces are round, square in Dial-Up, and in Runestone with a
// resource pack a squircle in the pack's own frame. It was a circle with round rings in every look.
//
// A picture, with VOICE_FACE_SHOTS=1: build/voice_face/<look>.png; THEME_PACK=<a pack's archive on this disk> draws
// Runestone with that pack in place of the flat one made here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const entry = PackEntry(id: 'pack-made', name: 'Made', author: '', commit: '0000000000000000000000000000000000000000');

  Future<void> draw(WidgetTester tester, AccentSheets accents, Look look) async {
    final app = AppState()..setLook(look);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: GlacierTheme(
        sheet: accents.of(app),
        attrs: ghostAttrs(app, 'desktop'),
        child: Builder(
          builder: (context) => ColoredBox(
            color: context.tokens.color('app-paper'),
            child: Center(
              child: RepaintBoundary(
                key: const ValueKey('shot'),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Row(mainAxisSize: MainAxisSize.min, spacing: 28, children: [
                    // Quiet with an initial, in a call and quiet, talking with an initial, talking with a picture, small.
                    const RippleAvatar(key: ValueKey('quiet'), name: 'Kevin', level: 0, size: 38),
                    const RippleAvatar(key: ValueKey('ringed'), name: 'Kevin', level: 0, size: 38, ringed: true),
                    const RippleAvatar(key: ValueKey('talking'), name: 'Maya', level: 0.5, size: 38),
                    RippleAvatar(key: const ValueKey('picture'), name: 'Matt', level: 0.5, size: 52, child: Image.file(File('assets/stickers/party/03.webp'), width: 52, height: 52, fit: BoxFit.cover)),
                    RippleAvatar(key: const ValueKey('small'), name: 'Matt', level: 0.5, size: 28, child: Image.file(File('assets/stickers/party/03.webp'), width: 28, height: 28, fit: BoxFit.cover)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(tester.takeException(), isNull, reason: look.name);
    if (Platform.environment['VOICE_FACE_SHOTS'] != '1') return;
    final element = find.byKey(const ValueKey('shot')).evaluate().single;
    await tester.runAsync(() async {
      final image = await (element.renderObject! as RenderRepaintBoundary).toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/voice_face/${look.name}.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  double? cornerOf(WidgetTester tester, String key) => tester.widget<VoiceRipples>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(VoiceRipples))).corner;
  Finder inside(String key, Finder what) => find.descendant(of: find.byKey(ValueKey(key)), matching: what);
  final squircle = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SquirclePainter);
  final green = find.descendant(of: find.byType(TalkingLine), matching: find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).border != null && w.child == null));

  testWidgets('round where faces are round, square in Dial-Up, a squircle in the pack\'s frame in Runestone', (tester) async {
    final accents = (await tester.runAsync(AccentSheets.load))!;
    addTearDown(() => ResourcePacks.instance.current = null);

    // A look of round faces: as it was.
    await draw(tester, accents, Look.values.firstWhere((l) => l != Look.dialup && l != Look.runestone));
    for (final key in ['quiet', 'talking', 'picture']) {
      expect(cornerOf(tester, key), isNull, reason: key);
      expect(inside(key, find.byType(VoiceFace)), findsNothing, reason: key);
    }

    // Dial-Up: square in the sunken ring, square rings, and the green line square round it while they talk.
    await draw(tester, accents, Look.dialup);
    for (final key in ['quiet', 'ringed', 'talking', 'picture', 'small']) {
      expect(cornerOf(tester, key), 0, reason: key);
      expect(inside(key, find.byType(DialupFace)), findsOneWidget, reason: key);
      expect(inside(key, squircle), findsNothing, reason: key);
    }
    expect(inside('quiet', green), findsNothing);
    for (final key in ['ringed', 'talking', 'picture']) {
      expect(tester.widget<DecoratedBox>(inside(key, green)).decoration, isA<BoxDecoration>().having((d) => d.borderRadius, 'corner', BorderRadius.zero), reason: key);
    }

    // Runestone with no pack fetched: Dial-Up's square, in flat stone.
    await draw(tester, accents, Look.runestone);
    expect(cornerOf(tester, 'talking'), 0);
    expect(inside('talking', squircle), findsNothing);

    // With a pack: each a squircle in the pack's orb, drawn out, the rings and the green line by its corner.
    final real = Platform.environment['THEME_PACK'];
    await tester.runAsync(() => ResourcePacks.instance.debugUse(entry, real == null ? madePack() : File(real).readAsBytesSync()));
    await draw(tester, accents, Look.runestone);
    for (final (key, size) in [('quiet', 38.0), ('ringed', 38.0), ('talking', 38.0), ('picture', 52.0), ('small', 28.0)]) {
      final corner = size * 17 / 44;
      expect(cornerOf(tester, key), corner, reason: key);
      expect(inside(key, squircle), findsOneWidget, reason: key);
      expect(inside(key, find.byWidgetPredicate((w) => w is CustomPaint && w.painter is OrbPainter)), findsNothing, reason: '$key: not the round orb');
      // The picture or the initial is cut to the frame's inner corner, inside its ring.
      final cut = tester.widget<ClipRRect>(inside(key, find.byType(ClipRRect)));
      expect(cut.borderRadius, BorderRadius.circular(13 * (size / 44)), reason: key);
      expect(tester.getSize(inside(key, find.byType(ClipRRect))).width, lessThan(size - 4), reason: '$key: inside the ring');
      expect(tester.getSize(find.byKey(ValueKey(key))), Size.square(size), reason: '$key: takes a face\'s room and no more');
    }
    expect(inside('quiet', green), findsNothing);
    expect(tester.widget<DecoratedBox>(inside('talking', green)).decoration, isA<BoxDecoration>().having((d) => d.borderRadius, 'corner', BorderRadius.circular(38 * 17 / 44 + 2.5)), reason: 'outside the textured frame, not over it');
  });
}
