import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/pixel_emoji.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

/// Emoji in square pixels under the look Runestone (lib/art/pixel_emoji.dart; Matt, 2026-11-27: "also add a shader to
/// pixelate emoji"): which words are emoji, that each is drawn small and kept, and that no other look does it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = TextStyle(fontSize: 16, fontFamily: 'Inter Variable', fontFamilyFallback: ['Ghost Emoji Noto']);

  setUpAll(() async {
    for (final (name, file) in [('Inter Variable', 'assets/fonts/InterVariable-latin.ttf'), ('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf')]) {
      final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
      await loader.load();
    }
  });
  tearDown(PixelEmoji.forget);

  test('only Runestone asks for it', () async {
    final sheet = await loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css']);
    for (final look in Look.values) {
      final t = Tokens.root(sheet, attrs: look.attrs(platform: 'mobile', theme: look.light ? 'light' : 'dark'));
      expect(pixelEmojiOn(t), look == Look.runestone, reason: look.name);
    }
  });

  test('words are left as words and each run of emoji is taken out of them, in order', () {
    List<String> said(String text) => [
          for (final s in pixelEmojiSpans([TextSpan(text: text)], style))
            s is WidgetSpan ? '[${(s.child as PixelEmoji).emoji}]' : (s as TextSpan).text!,
        ];
    expect(said('See you at 7!'), ['See you at 7!']);
    expect(said('Hey! Long time 👋'), ['Hey! Long time ', '[👋]']);
    expect(said('🎉🍿'), ['[🎉🍿]'], reason: 'side by side, one picture');
    expect(said('a ❤️ b 👍🏽 c'), ['a ', '[❤️]', ' b ', '[👍🏽]', ' c'], reason: 'a heart with its selector and a thumb with its tone are one emoji each');
    expect(said('👨‍👩‍👧 home'), ['[👨‍👩‍👧]', ' home'], reason: 'a family is one');
    expect(said('🇺🇸!'), ['[🇺🇸]', '!']);
    expect(said('5 > 3, 100% © 2026 #1'), ['5 > 3, 100% © 2026 #1'], reason: 'figures and signs are words');
    expect(said('ok… “fine” → no'), ['ok… “fine” → no'], reason: 'arrows and quotes are not pictures here');
    // What a span carried (a link's press, its style) stays on its words, and what was under it stays under it.
    final spans = pixelEmojiSpans([
      const TextSpan(text: 'tap 👻 here', style: TextStyle(fontWeight: FontWeight.w700), semanticsLabel: 'Link', children: [TextSpan(text: ' after')]),
    ], style);
    expect(spans, hasLength(4));
    expect((spans[0] as TextSpan).style!.fontWeight, FontWeight.w700);
    expect((spans[0] as TextSpan).semanticsLabel, 'Link');
    expect(spans[1], isA<WidgetSpan>());
    expect((spans[3] as TextSpan).text, ' after');
  });

  testWidgets('an emoji is drawn small, sixteen pixels to the em, and kept for the next time it is drawn', (tester) async {
    Widget page(String emoji) => Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: Text.rich(TextSpan(children: pixelEmojiSpans([TextSpan(text: 'hi $emoji')], style)), style: style)),
        );
    expect(PixelEmoji.made, 0);
    await tester.pumpWidget(page('👋'));
    expect(tester.takeException(), isNull);
    expect(PixelEmoji.made, 1);
    // As large on the line as the words would have drawn it.
    final box = tester.getSize(find.byType(PixelEmoji));
    expect(box.height, greaterThan(12));
    expect(box.width, greaterThan(12));
    expect(find.bySemanticsLabel(RegExp('👋')), findsWidgets, reason: 'still read aloud as the emoji it is');
    await tester.pumpWidget(page('👋'));
    expect(PixelEmoji.made, 1, reason: 'the same one, not made again');
    await tester.pumpWidget(page('🍿'));
    expect(PixelEmoji.made, 2);
  });
}
