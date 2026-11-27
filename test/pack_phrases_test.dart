import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// The phrase language plugins from other developers match texts with (lib/plugins/pack/phrases.dart; Matt,
/// 2026-11-20: "I would like users to be able to develop and submit their own plugins to our plugin marketplace"):
/// every vector of the format's A.10.11, the two patterns the format pins, the person's own words, the text as it is
/// prepared, and what a phrase may not hold; then its speed, a full pack of every token on texts made to be slow, and
/// sixteen packs over a conversation's bubbles (each a median, and proven with every core busy: 0.3 of the spec).
void main() {
  PhraseHit? hit(String phrase, String text) => Phrase.compile(phrase).find(PreparedText(text));

  group('A.10.11 matches', () {
    // Phrase, text, and the token's capture where the phrase has a token, else the whole match; null for none.
    const vectors = <(String, String, String?)>[
      ('your code is {digits:4-8}', 'Your code is 123456.', '123456'),
      ('your code is {digits:4-8}', 'Your code is 1234567890', null),
      ('code {code:4-8}', 'Use code AB12CD to sign in', 'AB12CD'),
      ('code {code:4-8}', 'Use code ABCDEF to sign in', null),
      ('amount due {amount}', 'Amount due \$1,234.56 by Friday', '\$1,234.56'),
      ('amount due {amount}', 'Amount due 45 by Friday', null),
      ('amount due {amount}', 'Amount due: 45,00 EUR', null),
      ('amount due: {amount}', 'Amount due: 45,00 EUR.', '45,00 EUR'),
      ('your {words:0-3} has shipped', 'Your parcel has shipped', 'parcel'),
      ('your {words:0-3} has shipped', 'Your new blue parcel has shipped!', 'new blue parcel'),
      ('your {words:0-3} has shipped', 'Your very big new blue parcel has shipped', null),
      ('bill', 'Your billing statement', null),
      ('bill', 'Your bill is ready', 'bill'),
      ('track {url}', 'Track it: https://example.com/t/123', null),
      ('track {url}', 'track https://example.com/t/123 now', 'https://example.com/t/123'),
      ('{phone}', 'Call +1 (555) 010-0100 today', '+1 (555) 010-0100'),
      ('on {date}', 'Your appointment on March 5th at 3pm', 'March 5th'),
      ('on {date}', 'Booked on 12/03/2026.', '12/03/2026'),
      ('on {date}', 'See you on 5 jan', '5 jan'),
      ('at {time}', 'See you at 3pm', '3pm'),
      ('at {time}', 'See you at 10:30 a.m. sharp', '10:30 a.m.'),
      ('don\'t forget', 'Don\u2019t forget your parcel', 'Don\'t forget'),
      ('your appt', 'YOUR APPT is at 9', 'YOUR APPT'),
      ('café', 'Le CAFÉ est ouvert', 'CAFÉ'),
      ('from {email}', 'Reply from bob.smith+x@mail.example.co.uk.', 'bob.smith+x@mail.example.co.uk'),
      ('ref #{digits:4-10}', 'Booking ref #88213 confirmed', '88213'),
      ('{word} delivery', 'Your Acme delivery is near', 'Acme'),
      ('order {number}', 'Order 1,234 shipped', '1,234'),
      ('order {number}', 'Order 98765 shipped', '98765'),
      ('tracking no. {code:8-24}', 'Tracking no. JD014600006295117', 'JD014600006295117'),
      ('ticket {{ref}} {digits:3}', 'Ticket {ref} 123', '123'),
      ('50% off', 'Get 50% off today', '50% off'),
      ('a.b.c', 'see aXbXc here', null),
    ];
    for (final (phrase, text, want) in vectors) {
      test('"$phrase" in "$text"', () {
        final found = hit(phrase, text);
        if (want == null) {
          expect(found, isNull);
          return;
        }
        expect(found, isNotNull);
        expect(Phrase.compile(phrase).hasToken ? found!.token : found!.match, want);
      });
    }

    test('{words:0-3} with no words between matches, its capture empty, which a detail reads as none', () {
      final found = hit('your {words:0-3} has shipped', 'Your has shipped');
      expect(found, isNotNull);
      expect(found!.token, '');
      expect(found.match, 'Your has shipped');
    });

    test('a phrase without a token gives no capture, only the whole match', () {
      expect(hit('bill', 'Your bill is ready')!.token, isNull);
      expect(hit('order {number}', 'Order 98765 shipped')!.match, 'Order 98765');
    });
  });

  test('A.10.11 anchors', () {
    expect(Phrase.compile('your code is {digits:4-8}').anchor, 'your', reason: 'the first of the two longest');
    expect(Phrase.compile('{phone}').anchor, isNull);
    expect(Phrase.compile('{phone}').anchorless, isTrue);
    expect(Phrase.compile('café au lait').anchor, 'lait', reason: 'café is not ASCII');
    expect(Phrase.compile('at {time}').anchor, isNull, reason: 'at is too short');
    expect(Phrase.compile('tracking no. {code:8-24}').anchor, 'tracking');
    expect(Phrase.compile('YOUR Bill').anchor, 'your', reason: 'lower-cased');
  });

  test('a text without its anchor is not matched, whatever the pattern would say', () {
    final p = Phrase.compile('your statement is ready');
    expect(p.find(PreparedText('Your statement is ready')), isNotNull);
    // \u017F folds to s in the pattern, but the text's lower-case form has no "statement" in it.
    expect(p.find(PreparedText('Your \u017Ftatement is ready')), isNull);
  });

  group('A.10.11 errors', () {
    const vectors = <(String, String)>[
      ('bill{digits:4}', 'phrase_token_touches_word'),
      ('{digits:4}{digits:4}', 'phrase_tokens_touch'),
      ('{words:1-2} bill', 'phrase_words_edge'),
      ('{digits:0}', 'phrase_bad_token'),
      ('{digits:9-4}', 'phrase_bad_token'),
      ('{foo}', 'phrase_bad_token'),
      ('code {code:3}', 'phrase_bad_token'),
      ('go {words:5}', 'phrase_bad_token'),
      ('x {word:2} y', 'phrase_bad_token'),
      ('bill }', 'phrase_bad_token'),
      ('a', 'phrase_too_short'),
      ('', 'phrase_bad_text'),
      (' bill', 'phrase_bad_text'),
      ('{url}.', 'phrase_url_followed'),
      ('a {digits} b {digits} c {digits} d {digits} e {digits}', 'phrase_too_many_tokens'),
      // and the rest of each rule
      ('bill {', 'phrase_bad_token'),
      ('{digits:25}', 'phrase_bad_token'),
      ('your {words} has {words} been', 'phrase_too_many_tokens'),
      ('go {url} and {url}', 'phrase_too_many_tokens'),
      ('bill {words:1-2}', 'phrase_words_edge'),
      ('{{', 'phrase_too_short'),
    ];
    for (final (phrase, code) in vectors) {
      test('"$phrase" is $code', () {
        expect(() => Phrase.compile(phrase), throwsA(isA<PhraseError>().having((e) => e.code, 'code', code)));
      });
    }

    test('a phrase of 121 characters is phrase_bad_text, of 120 it is fine', () {
      expect(() => Phrase.compile('a' * 121), throwsA(isA<PhraseError>().having((e) => e.code, 'code', 'phrase_bad_text')));
      expect(Phrase.compile('a' * 120).source, hasLength(120));
    });

    test('a phrase holding U+202E, U+200B or a newline is phrase_bad_text', () {
      for (final bad in ['your\u202Ebill', 'your\u200Bbill', 'your\nbill', 'your\tbill', 'bill\u2028due']) {
        expect(() => Phrase.compile(bad), throwsA(isA<PhraseError>().having((e) => e.code, 'code', 'phrase_bad_text')), reason: bad.runes.map((r) => r.toRadixString(16)).join(' '));
      }
    });
  });

  test('B.4 pins two patterns exactly', () {
    expect(Phrase.compile('your code is {digits:4-8}').pattern, r'(?<![\p{L}\p{N}])your\s+code\s+is\s+((?<![0-9])[0-9]{4,8}(?![0-9]))');
    expect(Phrase.compile('your {words:0-3} has shipped').pattern, r'(?<![\p{L}\p{N}])your\s+((?:\S{1,32}\s+){0,3})has\s+shipped(?![\p{L}\p{N}])');
  });

  test('the person\'s own words are literal: braces doubled, and one letter refused', () {
    final p = Phrase.literal('{council} tax');
    expect(p.source, '{{council}} tax');
    expect(p.hasToken, isFalse);
    expect(p.find(PreparedText('Your {council} tax is due'))!.match, '{council} tax');
    expect(p.find(PreparedText('Your council tax is due')), isNull);
    expect(Phrase.literal('{digits}').find(PreparedText('pay {digits} now'))!.match, '{digits}');
    expect(() => Phrase.literal('a'), throwsA(isA<PhraseError>().having((e) => e.code, 'code', 'phrase_too_short')));
  });

  test('a run of spaces is one separator, and any run of whitespace matches it', () {
    expect(Phrase.compile('your  bill').pattern, r'(?<![\p{L}\p{N}])your\s+bill(?![\p{L}\p{N}])');
    expect(hit('your bill', 'your \u00A0  bill'), isNotNull);
  });

  test('literal characters a pattern would read are escaped, and match only themselves', () {
    final p = Phrase.compile(r'a+b (c) [d] $5 ^x | y?');
    expect(p.find(PreparedText(r'see a+b (c) [d] $5 ^x | y? now')), isNotNull);
    expect(p.find(PreparedText('see aab c d 5 x y now')), isNull);
  });

  group('PreparedText', () {
    test('the look-alikes are made plain, one for one', () {
      final t = PreparedText('a\u00A0b\u2007c\u202Fd \u2018e\u2019 \u201Bf\u02BC \u201Cg\u201D\u201F h\u2010i\u2011j\u2012k\u2013l\u2014m');
      expect(t.text, 'a b c d \'e\' \'f\' "g"" h-i-j-k-l-m');
      expect(normalizeForPhrases('plain'), 'plain');
    });

    test('a text is cut to its first 2,000 code units, never ending on half a character', () {
      expect(PreparedText('a' * 2500).text, hasLength(2000));
      final split = '${'a' * 1999}👻 and more';
      expect(PreparedText(split).text, 'a' * 1999, reason: 'the ghost\'s high half was cut from its low half');
      expect(PreparedText('${'a' * 1998}👻').text, hasLength(2000));
      expect(PreparedText('ABC').lower, 'abc');
    });
  });

  group('speed', () {
    // Every token, with anchors of every kind: words the texts below are full of among them, so some patterns run on
    // every one of those, and the eight anchorless ones run on all.
    const anchorless = ['{phone}', '{date}', '{time}', '{email}', '{url}', '{amount}', 'at {time}', 'on {date}'];
    const words = ['order', 'payment', 'parcel', 'ticket', 'booking', 'account', 'invoice', 'refund', 'delivery', 'appointment', 'march', 'www', 'aaa', 'a1a1', '111'];
    const shapes = ['your {w} {digits:4-12} is ready', '{w} of {amount} is due', '{w} code {code:4-8} to sign in', '{word} {w} is near', 'your {w} {words:1-3} has shipped', '{w} visit {url} now', '{w} reply to {email} today', '{w} call {phone} now', '{w} booked on {date} at {time}', '{w} {number} shipped', '{w} ref #{digits:4-10}', '{w} total {amount}', '{w} on {date}'];
    List<String> phrases() {
      final out = [...anchorless];
      for (var i = 0; out.length < 200; i++) {
        out.add(shapes[i % shapes.length].replaceAll('{w}', '${words[i % words.length]}${i ~/ (words.length * shapes.length) == 0 ? '' : ' n${i ~/ (words.length * shapes.length)}'}'));
      }
      return out;
    }

    PluginPack full(String id) {
      final all = phrases();
      final rules = <Map<String, Object?>>[
        for (var r = 0; r * 30 < all.length; r++) {'tag': 'p$r', 'any': all.sublist(r * 30, (r * 30 + 30).clamp(0, all.length)), 'detail': {'from': 'token'}},
      ];
      final parse = parsePackJson({
        'format': 'ghost-plugin/1', 'id': id, 'version': '1.0.0', 'name': 'Everything $id', 'tagline': 'Every token at once', 'description': 'A pack made to be slow.',
        'hue': 'slate', 'shelf': 'tools', 'labels': ['sorting'], 'permissions': [], 'rules': {'tags': rules},
      }, appVersion: '0.10.1');
      expect(parse.errors, isEmpty);
      return parse.pack!;
    }

    String fill(String unit) => (unit * (2000 ~/ unit.length + 1)).substring(0, 2000);
    final adversarial = {
      '1': fill('1'), '1,1,1': fill('1,'), '1.111.111': fill('1.111'), 'a': fill('a'), 'a1': fill('a1'), 'x a a a': 'x${fill(' a').substring(1)}',
      'a@a@': fill('a@'), 'a.a.@': '${fill('a.').substring(0, 1900)}@${fill('a.').substring(0, 99)}', '1 (1)': fill('1 (1) '), 'www.': fill('www.'),
      'march march': fill('march '), '1:11': fill('1:11 '), r'$1,111.1': fill(r'$1,111.1 '),
    };

    int medianMicros(void Function() run, {int times = 5}) {
      final took = <int>[];
      for (var i = 0; i < times; i++) {
        final watch = Stopwatch()..start();
        run();
        took.add(watch.elapsedMicroseconds);
      }
      took.sort();
      return took[times ~/ 2];
    }

    MessageFacts textOf(String words) => MessageFacts(thread: 1, senders: const ['72975'], text: words, contact: false, outgoing: false);

    test('a pack of 200 phrases using every token, 8 anchorless, classifies each 2,000-character text made to be slow in under 20 ms', () {
      final pack = full('everything');
      expect(pack.rules.tags.expand((r) => r.any).length, 200);
      expect(pack.rules.tags.expand((r) => r.any).where((p) => p.anchorless).length, 8);
      expect(phraseTokenNames.every((t) => pack.rules.tags.expand((r) => r.any).any((p) => p.source.contains('{$t'))), isTrue, reason: 'every token is in it');
      // A clock that never moves: the pack never pauses itself here, and what is timed is the matching alone.
      final plugin = PackPlugin(pack, source: PluginSource.dev, now: () => DateTime(2026));
      final registry = PluginRegistry([plugin]);
      final store = MemoryStore({'plugin_${plugin.id}': 'on'});
      final times = <String, int>{};
      for (final e in adversarial.entries) {
        expect(e.value.length, 2000);
        times[e.key] = medianMicros(() => registry.classify(textOf(e.value), store));
      }
      // ignore: avoid_print
      print('slowest text: ${times.entries.reduce((a, b) => a.value > b.value ? a : b)} µs; all: $times');
      for (final e in times.entries) {
        expect(e.value, lessThan(20000), reason: '"${e.key}" took ${e.value} µs');
      }
    });

    test('a phrase chaining one token four times stays fast on a stranger\'s run of it, whatever joins them', () {
      // {phone} and {number} once stopped after any group of a run and started again after any separator, so four in a
      // row tried some 9^4 ways at every start: one search on "1 1 1 …" took 0.8 s, and a stranger could pause the
      // pack with a few texts (review, 2026-11-20). The two the review found, then every token four times over with
      // each joiner a phrase may put between them, on a run of what that token and the joiner make.
      final cases = <(String, String)>[
        ('{phone} {phone} {phone} {phone} due', '${'1 ' * 994}x due'),
        ('{number}.{number}.{number}.{number} due', '${'111.' * 497}x due'),
        ('{phone}-{phone}-{phone}-{phone} due', '${'1-' * 994}x due'),
      ];
      const units = {'digits': '1', 'number': '111', 'amount': r'$1', 'code': 'a1', 'word': 'a', 'email': 'a@a.aa', 'phone': '1', 'date': '1/1', 'time': '1:11'};
      for (final token in units.keys) {
        for (final join in [' ', '-', '.', ',', '/', ':', ' (']) {
          final phrase = '${List.filled(4, '{$token}').join(join)} due';
          for (final unit in {units[token]!, '1', 'a'}) {
            final run = unit + join;
            cases.add((phrase, '${run * (1995 ~/ run.length)}x due'));
          }
        }
      }
      final slow = <String>[];
      var worst = (0, '');
      for (final (phrase, text) in cases) {
        final p = Phrase.compile(phrase);
        final t = PreparedText(text);
        p.find(t); // compiled on its first use, which isn't what is timed
        final took = medianMicros(() => p.find(t), times: 3);
        if (took > worst.$1) worst = (took, '"$phrase" on "${text.substring(0, 12)}…"');
        if (took >= 20000) slow.add('"$phrase" on "${text.substring(0, 12)}…": $took µs');
      }
      // ignore: avoid_print
      print('${cases.length} chained phrases, the slowest ${worst.$1} µs: ${worst.$2}');
      expect(slow, isEmpty, reason: 'each search is under the 20 ms a strike takes (A.10.9)');
    });

    test('a phone and a number take the whole run they sit on, or nothing', () {
      String? capture(String phrase, String text) => Phrase.compile(phrase).find(PreparedText(text))?.token;
      expect(capture('{phone}', 'Call +1 (555) 010-0100 today'), '+1 (555) 010-0100');
      expect(capture('call {phone}', 'call 555 010 0100 or 555 0199'), '555 010 0100');
      // Sixteen digits joined as a phone's are none: no seven of them is a phone on its own.
      expect(capture('{phone}', 'Ref 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6'), isNull);
      expect(capture('{phone} {phone}', '5550100100 5550100199'), isNull, reason: 'one run, one phone at most');
      expect(capture('order {number}', 'Order 1,234 shipped'), '1,234');
      expect(capture('order {number}', 'Order 1,234. Thanks'), '1,234');
      expect(capture('amount due {amount}', 'Amount due €12,50 today'), '€12,50');
      expect(capture('{number}', 'Address 192.168.1.1'), isNull, reason: 'a run of numbers and dots is no number');
      expect(capture('{number}, {number}', '3, 4'), '3');
    });

    test('sixteen such packs over a 50-bubble build take under 250 ms', () {
      final packs = [for (var i = 0; i < 16; i++) PackPlugin(full('every${String.fromCharCode(0x61 + i)}'), source: PluginSource.dev, now: () => DateTime(2026))];
      final registry = PluginRegistry(packs);
      final store = MemoryStore({for (final p in packs) 'plugin_${p.id}': 'on'});
      // 3,200 phrases: twice what one device may hold (PackLimits.phrasesInAll), so this is more than a phone ever runs.
      expect(registry.plugins.fold<int>(0, (n, p) => n + (p as PackPlugin).pack.rules.tags.expand((r) => r.any).length), 2 * PackLimits.phrasesInAll);
      // A conversation's bubbles: the sample texts, ordinary words, and the slow texts above at a text's length.
      final bubbles = [
        for (var i = 0; i < 50; i++)
          switch (i % 3) {
            0 => packSamples[i % packSamples.length].text,
            1 => adversarial.values.elementAt(i % adversarial.length).substring(0, 160),
            _ => 'See you at ${i % 12 + 1}pm on March ${i % 28 + 1}? Order $i ships to www.example.com/t/$i, call +1 555 010 ${1000 + i}.',
          },
      ];
      final took = medianMicros(() {
        for (final b in bubbles) {
          registry.classify(textOf(b), store);
        }
      });
      // ignore: avoid_print
      print('16 packs over 50 bubbles: ${(took / 1000).toStringAsFixed(1)} ms');
      expect(took, lessThan(250000));
    });
  });
}
