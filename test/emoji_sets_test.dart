import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/emoji_sets.dart';
import 'package:ghost_messaging/main.dart' show ghostTypography;
import 'package:glacier/glacier.dart';

/// Every carried emoji set drawing the hard cases as messages draw them (Inter first, the set as its fallback):
/// joined families and professions, skin tones, flags, keycaps, a heart with its variation selector. Written to
/// test/shots/7-emoji-sets.png. Each sequence must come out as ONE glyph, which is also measured: a sequence a set
/// can't join would be as wide as its parts.
const _hard = ['👨‍👩‍👧', '🧑‍💻', '👍🏽', '🏳️‍🌈', '🇺🇸', '❤️‍🔥', '1️⃣', '❤️', '👩🏾‍🚀', '🫶🏻'];

void main() {
  setUpAll(() async {
    Future<void> family(String name, String file) async {
      final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
      await loader.load();
    }

    await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
    await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
    await family('Ghost Emoji Twemoji', 'assets/emoji/Twemoji.ttf');
    await family('Ghost Emoji OpenMoji', 'assets/emoji/OpenMoji.ttf');
    await family('Ghost Emoji Outline', 'assets/emoji/NotoOutline.ttf');
  });

  testWidgets('joined emoji are one glyph in every set', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    final sets = emojiSets.where((s) => s.family != null).toList();
    final widths = <String, List<double>>{};
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFFFFFFFF),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final set in sets)
            GlacierTheme(
              sheet: sheet,
              attrs: const {'platform': 'mobile', 'theme': 'light'},
              typography: ghostTypography(set.id),
              child: Builder(builder: (context) {
                final style = context.tokens.textAt(26, color: const Color(0xFF111111), height: 1.4);
                widths[set.id] = [
                  for (final e in _hard) (TextPainter(text: TextSpan(text: e, style: style), textDirection: TextDirection.ltr)..layout()).width,
                ];
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('${set.name}: ok ${_hard.join(' ')} done', style: style),
                );
              }),
            ),
        ]),
      ),
    ));
    await tester.pump();
    // The picture is Linux's: its test engine draws fonts with FreeType, as Android does. A Mac's draws them with
    // Core Text, which leaves Twemoji's row blank (seen 2026-11-13, Flutter 3.47.6), so there the picture is neither
    // compared nor written over, and the widths below are the check.
    if (Platform.isLinux) await expectLater(find.byType(ColoredBox), matchesGoldenFile('shots/7-emoji-sets.png'));
    for (final set in sets) {
      for (var i = 0; i < _hard.length; i++) {
        // One glyph is about one em wide (26 here); two or more unjoined would be 50 and up.
        expect(widths[set.id]![i], lessThan(40), reason: '${set.name} draws ${_hard[i]} as more than one glyph (${widths[set.id]![i]})');
      }
    }
  });
}
