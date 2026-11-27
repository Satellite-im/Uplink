import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/mentions.dart';
import 'package:ghost_messaging/ui/markdown_field.dart';
import 'package:ghost_messaging/ui/thread.dart' show LinkedText;

/// A message's formatting as LinkedText draws it (GMFB-35): markers not drawn, links and mentions still pressable
/// inside formatting, a spoiler inked over until pressed.
const _ink = Color(0xFF222222);

Widget _host(Widget child) => Directionality(textDirection: TextDirection.ltr, child: Center(child: child));

List<TextSpan> _spans(WidgetTester tester) {
  final rich = tester.widget<RichText>(find.byType(RichText).first);
  final out = <TextSpan>[];
  rich.text.visitChildren((s) {
    if (s is TextSpan && s.text != null) out.add(s);
    return true;
  });
  return out;
}

void main() {
  testWidgets('markers are not drawn and the words are formatted', (tester) async {
    await tester.pumpWidget(_host(const LinkedText('a **bold** and ~~gone~~ `x`', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    final spans = _spans(tester);
    expect(spans.map((s) => s.text).join(), 'a bold and gone x');
    expect(spans.firstWhere((s) => s.text == 'bold').style!.fontWeight, FontWeight.w700);
    expect(spans.firstWhere((s) => s.text == 'gone').style!.decoration, TextDecoration.lineThrough);
    expect(spans.firstWhere((s) => s.text == 'x').style!.fontFamily, 'JetBrains Mono Variable');
  });

  testWidgets('a link and a mention inside formatting still press', (tester) async {
    Mention? pressed;
    const text = '**see https://x.com** *@Maya*';
    await tester.pumpWidget(_host(LinkedText(text, ink: _ink, style: const TextStyle(fontSize: 14, color: _ink), mentions: const [Mention(23, 5, 'maya1')], onMention: (m) => pressed = m)));
    final spans = _spans(tester);
    expect(spans.map((s) => s.text).join(), 'see https://x.com @Maya');
    final link = spans.firstWhere((s) => s.text == 'https://x.com');
    expect(link.recognizer, isA<TapGestureRecognizer>());
    expect(link.style!.fontWeight, FontWeight.w700);
    final mention = spans.firstWhere((s) => s.text == '@Maya');
    expect(mention.style!.fontStyle, FontStyle.italic);
    (mention.recognizer! as TapGestureRecognizer).onTap!();
    expect(pressed, const Mention(23, 5, 'maya1'));
  });

  testWidgets('a link written in code is not a link', (tester) async {
    await tester.pumpWidget(_host(const LinkedText('`https://x.com`', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    expect(_spans(tester).single.recognizer, isNull);
  });

  testWidgets('a spoiler is inked over until pressed', (tester) async {
    await tester.pumpWidget(_host(const LinkedText('the end: ||he dies||', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    var secret = _spans(tester).firstWhere((s) => s.text == 'he dies');
    expect(secret.style!.backgroundColor, _ink);
    expect(secret.semanticsLabel, 'Spoiler, tap to reveal');
    (secret.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
    secret = _spans(tester).firstWhere((s) => s.text == 'he dies');
    expect(secret.style!.backgroundColor, isNot(_ink));
    expect(secret.recognizer, isNull);
  });

  testWidgets('a quote has a bar in place of its marker', (tester) async {
    await tester.pumpWidget(_host(const LinkedText('> said\nok', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    expect(_spans(tester).map((s) => s.text).join(), '▍ said\nok');
  });

  testWidgets('a list has a bullet or a number beside each item, the item still formatted (GMFB-35)', (tester) async {
    await tester.pumpWidget(_host(SizedBox(
      width: 120,
      child: LinkedText('to buy:\n- **milk** and a great deal more of it besides\n  - oat\n2. eggs\nthanks', ink: _ink, style: const TextStyle(fontSize: 14, color: _ink), before: const [TextSpan(text: 'Ann: ')], after: const [TextSpan(text: ' 5:43')]),
    )));
    String words(RichText r) => r.text.toPlainText();
    final drawn = [for (final r in tester.widgetList<RichText>(find.byType(RichText))) words(r)];
    expect(drawn, ['Ann: to buy:', '\u2022', 'milk and a great deal more of it besides', '\u2022', 'oat', '2.', 'eggs', 'thanks 5:43']);
    final bold = <TextSpan>[];
    tester.widget<RichText>(find.byType(RichText).at(2)).text.visitChildren((s) {
      if (s is TextSpan && s.text == 'milk') bold.add(s);
      return true;
    });
    expect(bold.single.style!.fontWeight, FontWeight.w700);
    // The item's second line hangs under its first, not under the bullet; an item two spaces in stands further in.
    final bullet = tester.getTopLeft(find.byType(RichText).at(1)), item = tester.getRect(find.byType(RichText).at(2));
    expect(item.left, greaterThan(bullet.dx));
    expect(item.height, greaterThan(tester.getSize(find.byType(RichText).at(1)).height), reason: 'it wraps');
    expect(tester.getTopLeft(find.byType(RichText).at(3)).dx, greaterThan(bullet.dx));
    // No list: one run of words as ever.
    await tester.pumpWidget(_host(const LinkedText('well - maybe\n-5 outside', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    expect(find.byType(RichText), findsOneWidget);
    expect(find.byType(Row), findsNothing);
  });

  testWidgets('words under a link open its address', (tester) async {
    await tester.pumpWidget(_host(const LinkedText('read [the docs](https://gogho.st/docs)', ink: _ink, style: TextStyle(fontSize: 14, color: _ink))));
    final spans = _spans(tester);
    expect(spans.map((s) => s.text).join(), 'read the docs');
    final words = spans.firstWhere((s) => s.text == 'the docs');
    expect(words.recognizer, isA<TapGestureRecognizer>());
    expect(words.semanticsLabel, 'Link: the docs, https://gogho.st/docs');
  });

  group('MarkdownController', () {
    testWidgets('dims the markers in the composer', (tester) async {
      final c = MarkdownController(text: 'a **b** c');
      late BuildContext ctx;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        ctx = context;
        return const SizedBox();
      })));
      final span = c.buildTextSpan(context: ctx, style: const TextStyle(color: _ink), withComposing: false);
      final parts = [for (final s in span.children!) s as TextSpan];
      expect(parts.map((s) => s.text).join(), 'a **b** c');
      expect(parts.where((s) => s.text == '**').every((s) => s.style!.color!.a < 0.5), isTrue);
      expect(parts.firstWhere((s) => s.text == 'b').style!.fontWeight, FontWeight.w700);
      expect(parts.firstWhere((s) => s.text == 'a ').style, isNull);
      // Matt's line, 2026-11-25: bold, "__" bold too, and code on its ground in the code's letters.
      c.text = '**this** is __a__ test `for` _it_';
      final drawn = [for (final s in c.buildTextSpan(context: ctx, style: const TextStyle(color: _ink), withComposing: false).children!) s as TextSpan];
      expect(drawn.map((s) => s.text).join(), c.text);
      expect(drawn.firstWhere((s) => s.text == 'this').style!.fontWeight, FontWeight.w700);
      expect(drawn.firstWhere((s) => s.text == 'a').style!.fontWeight, FontWeight.w700);
      expect(drawn.where((s) => s.text == '__').every((s) => s.style!.color!.a < 0.5), isTrue);
      expect(drawn.firstWhere((s) => s.text == 'for').style!.fontFamily, 'JetBrains Mono Variable');
      expect(drawn.firstWhere((s) => s.text == 'for').style!.backgroundColor, isNotNull);
      expect(drawn.firstWhere((s) => s.text == 'it').style!.fontStyle, FontStyle.italic);
      expect(drawn.firstWhere((s) => s.text == ' test ').style, isNull);
      // A list is drawn as typed, its items formatted.
      c.text = '- **milk**\n1. eggs';
      final list = [for (final s in c.buildTextSpan(context: ctx, style: const TextStyle(color: _ink), withComposing: false).children!) s as TextSpan];
      expect(list.map((s) => s.text).join(), c.text);
      expect(list.firstWhere((s) => s.text == '- ').style, isNull);
      expect(list.firstWhere((s) => s.text == 'milk').style!.fontWeight, FontWeight.w700);
      c.dims = () => false;
      expect(c.buildTextSpan(context: ctx, style: const TextStyle(color: _ink), withComposing: false).children, isNull);
    });

    test('wraps the selection', () {
      final c = MarkdownController(text: 'make this bold');
      c.selection = const TextSelection(baseOffset: 5, extentOffset: 9);
      c.wrapSelection('**');
      expect(c.text, 'make **this** bold');
      expect(c.selection, const TextSelection(baseOffset: 7, extentOffset: 11));
      c.selection = const TextSelection.collapsed(offset: 0);
      c.wrapSelection('`');
      expect(c.text, '``make **this** bold');
      expect(c.selection, const TextSelection.collapsed(offset: 1));
    });
  });
}
