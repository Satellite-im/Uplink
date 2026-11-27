import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/links.dart';
import 'package:ghost_messaging/message_format.dart';

/// The words as drawn, each formatted stretch in brackets naming how: "[b:bold] and plain". Markers are not drawn;
/// a quote's bar is "▍", a list item's mark is in braces as it is drawn ("{•}", "{2.}").
String drawn(String text, {List<(int, int)> keep = const []}) {
  final links = [for (final l in MessageLink.find(text)) (l.start, l.end)];
  final f = MessageFormat.parse(text, keep: keep, links: links);
  final out = StringBuffer();
  for (final r in f.runs) {
    if (r.marker) continue;
    if (r.bar) {
      out.write('▍');
      continue;
    }
    final words = text.substring(r.start, r.end);
    if (r.item) {
      out.write('{${MessageFormat.itemMark(words).$1}}');
      continue;
    }
    final kinds = [
      if (r.has(Fmt.bold)) 'b',
      if (r.has(Fmt.italic)) 'i',
      if (r.has(Fmt.strike)) 's',
      if (r.has(Fmt.block)) 'pre' else if (r.has(Fmt.code)) 'c',
      if (r.has(Fmt.quote)) 'q',
      if (r.has(Fmt.spoiler)) 'sp${r.spoiler}',
      if (r.has(Fmt.link)) 'l${r.link}',
    ];
    out.write(kinds.isEmpty ? words : '[${kinds.join(',')}:$words]');
  }
  return out.toString();
}

void main() {
  group('MessageFormat.parse', () {
    test('plain words are one plain run', () {
      final f = MessageFormat.parse('hello there');
      expect(f.isPlain, isTrue);
      expect(f.runs.single.end, 11);
      expect(MessageFormat.parse('').runs, isEmpty);
    });

    test('bold, italic, strike, code', () {
      expect(drawn('a **bold** b'), 'a [b:bold] b');
      expect(drawn('a *it* b _too_'), 'a [i:it] b [i:too]');
      expect(drawn('~~gone~~ now'), '[s:gone] now');
      expect(drawn('run `ls -la` here'), 'run [c:ls -la] here');
    });

    test('nesting', () {
      expect(drawn('**bold *and it***'), '[b:bold ][b,i:and it]');
      expect(drawn('***both***'), '[b,i:both]');
      expect(drawn('*a **b** c*'), '[i:a ][b,i:b][i: c]');
      expect(drawn('~~**x**~~'), '[b,s:x]');
    });

    test('everyday asterisks and underscores stay as written', () {
      expect(drawn('2*3*4 = 24'), '2*3*4 = 24');
      expect(drawn('snake_case_name'), 'snake_case_name');
      expect(drawn('a * b * c'), 'a * b * c');
      expect(drawn('** not bold **'), '** not bold **');
      expect(drawn('*unclosed'), '*unclosed');
      expect(drawn('****'), '****');
      expect(drawn('||'), '||');
      expect(drawn('``'), '``');
      expect(drawn('5 > 3'), '5 > 3');
    });

    test('formatting does not cross lines', () {
      expect(drawn('**one\ntwo**'), '**one\ntwo**');
      expect(drawn('*a*\n*b*'), '[i:a]\n[i:b]');
    });

    test('nothing inside code is formatted', () {
      expect(drawn('`**not bold**`'), '[c:**not bold**]');
      expect(drawn('**a `*b*` c**'), '[b:a ][b,c:*b*][b: c]');
      expect(drawn('*a `*` b*'), '[i:a ][i,c:*][i: b]');
    });

    test('code blocks', () {
      expect(drawn('look:\n```\nfinal x = **1**;\n```\ndone'), 'look:\n[pre:final x = **1**;]\ndone');
      expect(drawn('```dart\nvoid main() {}\n```'), '[pre:void main() {}]');
      expect(drawn('```inline```'), '[pre:inline]');
      expect(drawn('```\n> not a quote\n```'), '[pre:> not a quote]');
      expect(drawn('```unclosed'), '```unclosed');
      expect(drawn('``````'), '``````');
    });

    test('quotes', () {
      expect(drawn('> said this\nand I said'), '▍[q:said this]\nand I said');
      expect(drawn('> **loud** quote'), '▍[b,q:loud][q: quote]');
      expect(drawn('>no space'), '>no space');
      expect(drawn('a > b'), 'a > b');
    });

    test('lists (GMFB-35)', () {
      expect(drawn('- milk\n- **two** eggs'), '{•}milk\n{•}[b:two] eggs');
      expect(drawn('* one\n* *two*'), '{•}one\n{•}[i:two]');
      expect(drawn('to buy:\n1. milk\n2) eggs\nthanks'), 'to buy:\n{1.}milk\n{2)}eggs\nthanks');
      expect(MessageFormat.itemMark('    - '), ('•', 2));
      expect(MessageFormat.itemMark('12. '), ('12.', 0));
      expect(MessageFormat.parse('- a').hasItems, isTrue);
      // Everyday words stay as they are.
      for (final plain in ['-5 outside', 'well - maybe', '2020. What a year', '3.5 stars', '- ', '1.', 'a\n-b']) {
        expect(MessageFormat.parse(plain).isPlain, isTrue, reason: plain);
      }
      // Not in a block of code, nor a quote; and the words go as written.
      expect(drawn('```\n- a\n```'), '[pre:- a]');
      expect(drawn('> - said'), '▍[q:- said]');
      expect(MessageFormat.plain('- **milk**\n1. eggs'), '- milk\n1. eggs');
    });

    test('spoilers are counted', () {
      expect(drawn('||one|| and ||two||'), '[sp0:one] and [sp1:two]');
      expect(MessageFormat.parse('||one|| and ||two||').spoilers, 2);
      expect(drawn('||**bold** secret||'), '[b,sp0:bold][sp0: secret]');
    });

    test('a backslash writes the marker', () {
      expect(drawn(r'\*not\* it'), '*not* it');
      expect(drawn(r'**a \* b**'), '[b:a ][b:* b]');
    });

    test('links stay whole and work inside formatting', () {
      expect(drawn('see https://x.com/a_b_c here'), 'see https://x.com/a_b_c here');
      expect(drawn('**https://x.com/a*b**'), '[b:https://x.com/a*b]');
      expect(drawn('_https://example.com/some_path_'), '[i:https://example.com/some_path]');
    });

    test('a link under other words', () {
      final text = 'read [the docs](https://gogho.st/docs) now';
      expect(drawn(text), 'read [l0:the docs] now');
      expect(drawn('**[docs](https://gogho.st)**'), '[b,l0:docs]');
      // Words that are an address themselves are not put over another one.
      expect(drawn('[paypal.com](https://evil.example)'), '[paypal.com](https://evil.example)');
      expect(drawn('[https://a.com](https://b.com)'), '[https://a.com](https://b.com)');
      // Only a web link: anything else stays as written.
      expect(drawn('[x](javascript:alert(1))'), '[x](javascript:alert(1))');
    });

    test('mentions are kept whole', () {
      const text = '**@snake_case_guy** hi *@Maya*';
      expect(drawn(text, keep: [(2, 17), (24, 29)]), '[b:@snake_case_guy] hi [i:@Maya]');
      // A marker inside a mention is the mention's.
      expect(drawn('@a*b and c*', keep: [(0, 4)]), '@a*b and c*');
    });

    test('runs cover the words in order', () {
      const text = '> **a** `b` ||c|| [d](https://e.com)\n```\nf\n```';
      final f = MessageFormat.parse(text, links: [for (final l in MessageLink.find(text)) (l.start, l.end)]);
      var at = 0;
      for (final r in f.runs) {
        expect(r.start, at);
        expect(r.end, greaterThan(r.start));
        at = r.end;
      }
      expect(at, text.length);
    });

    test('emoji inside formatting', () {
      expect(drawn('**hi 😂**'), '[b:hi 😂]');
      expect(drawn('😂 *x* 🎉'), '😂 [i:x] 🎉');
    });
  });

  group('MessageFormat.plain', () {
    test('drops the markers', () {
      expect(MessageFormat.plain('**bold** and *it* ~~x~~ `c`'), 'bold and it x c');
      expect(MessageFormat.plain('> quoted\nreply'), 'quoted\nreply');
      expect(MessageFormat.plain('```\ncode\n```'), 'code');
      expect(MessageFormat.plain('[docs](https://gogho.st/docs)'), 'docs');
    });

    test('hides spoilers', () {
      expect(MessageFormat.plain('the end: ||he dies||'), 'the end: ▒▒▒▒▒▒▒');
      expect(MessageFormat.plain('||a very long secret indeed||'), '▒' * 8);
    });

    test('leaves plain words alone', () {
      expect(MessageFormat.plain('2*3*4 and snake_case'), '2*3*4 and snake_case');
      expect(MessageFormat.plain('https://x.com/a_b_'), 'https://x.com/a_b_');
    });
  });
}
