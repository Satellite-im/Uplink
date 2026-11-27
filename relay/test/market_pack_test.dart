// The relay's copy of what it checks in a plugin pack (lib/market_pack.dart; Matt, 2026-11-20: "I would like users to be
// able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the
// store through a review process"), held to the same vectors and cases as the app's lib/plugins/pack/, and its lists
// to the app's own, read out of ../lib/plugins/pack/format.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ghost_relay/market_pack.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

import 'market_fixtures.dart';

/// Bills with an id of its own (an example's id is refused for a submission), and [changes] made, [drop] taken out.
Map<String, Object?> pack({Map<String, Object?> changes = const {}, List<String> drop = const []}) {
  final j = (jsonDecode(billsPack) as Map).cast<String, Object?>()..['id'] = 'mybills';
  for (final k in drop) {
    j.remove(k);
  }
  return j..addAll(changes);
}

List<(String, String)> issues(Object? p, {bool needIcon = true, bool needSupport = true}) => [for (final i in checkPackTop(p, needIcon: needIcon, needSupport: needSupport).issues) (i.code, i.path)];

String icon(List<int> bytes) => base64Encode(bytes);

/// The bracketed value given to [name] in Dart source [src], comments left out; null where there is none.
String? valueOf(String src, String name) {
  final m = RegExp('\\b$name\\s*=\\s*(?:const\\s+)?(?:<[^=;{\\[]*>\\s*)?([\\[{])').firstMatch(src);
  return m == null ? null : bracketed(src, m.end - 1);
}

String? bracketed(String src, int open) {
  final out = StringBuffer();
  var depth = 0;
  var i = open;
  while (i < src.length) {
    final c = src[i];
    if (src.startsWith('//', i)) {
      final end = src.indexOf('\n', i);
      i = end < 0 ? src.length : end;
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      i = end < 0 ? src.length : end + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      final start = i++;
      while (i < src.length && src[i] != c) {
        if (src[i] == '\\') i++;
        i++;
      }
      i++;
      out.write(src.substring(start, min(i, src.length)));
      continue;
    }
    if ('[{('.contains(c)) depth++;
    if (']})'.contains(c) && --depth == 0) return (out..write(c)).toString();
    out.write(c);
    i++;
  }
  return null;
}

List<String> stringsIn(String text) => [for (final m in RegExp(r"'([^'\\]*)'" '|' r'"([^"\\]*)"').allMatches(text)) m.group(1) ?? m.group(2)!];

void main() {
  group('canonical JSON', () {
    // The app's vectors (lib/plugins/pack/canonical.dart): the relay's copy must give the same bytes and hashes.
    final vectors = [
      (r'{"b":1,"a":[true,false,null],"c":{"y":"é\"\\\n","x":-5}}', r'{"a":[true,false,null],"b":1,"c":{"x":-5,"y":"é\"\\\n"}}', 57, '4157b09b53d6d810c08dc572c9b40fdb8ea1b09626f8a5a7b13e7aef2899b5fd'),
      (r'{"z":"\u0001\t\u001f","emoji":"👻","slash":"a/b","lt":"<&>"}', r'{"emoji":"👻","lt":"<&>","slash":"a/b","z":"\u0001\t\u001f"}', 62, '45b8ee121777576252e347968447e5cddbc0772ab78c5b729744d2a8130965f0'),
      ('{"b":0,"B":0,"a":0,"_":0,"wordsFrom":1,"when":2}', '{"B":0,"_":0,"a":0,"b":0,"when":2,"wordsFrom":1}', 48, '017d8fea09cd7f8525ea10ca1954727b8c6000c75296982ed9b0b05cb8f1745f'),
      ('[]', '[]', 2, '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'),
      ('{"nested":{"list":[{"k":"v","a":[]},"x"],"empty":{}}}', '{"nested":{"empty":{},"list":[{"a":[],"k":"v"},"x"]}}', 53, '6b10ee38785e35387bd511c8a4be0c824eb88cb951d72de3feca80c5f44baf11'),
    ];
    for (final (input, text, length, sha) in vectors) {
      test(input, () {
        final v = jsonDecode(input);
        expect(canonicalJson(v), text);
        expect(canonicalBytes(v).length, length);
        expect(hexOf(sha256(canonicalBytes(v))), sha);
      });
    }

    test('the empty body\'s SHA-256, and a fraction anywhere throws', () {
      expect(hexOf(sha256(const [])), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(() => canonicalJson({'a': [1, 2.5]}), throwsArgumentError);
      expect(() => canonicalJson(jsonDecode('{"a":1.0}')), throwsArgumentError, reason: '1.0 is read as a double');
    });

    test('the nesting pass: eight deep is fine, nine is not, brackets inside a string are not counted, and 131,072 deep is found at once', () {
      List<int> b(String s) => utf8.encode(s);
      expect(jsonDepthOk(b('[[[[[[[[1]]]]]]]]')), isTrue);
      expect(jsonDepthOk(b('[[[[[[[[[1]]]]]]]]]')), isFalse);
      expect(jsonDepthOk(b('{"a":"[[[[[[[[[[["}')), isTrue);
      expect(jsonDepthOk(b(r'{"a":"\"[[[[[[[[[["}')), isTrue, reason: 'an escaped quote doesn\'t end the string');
      final deep = [...List.filled(131072, 0x5B), ...List.filled(131072, 0x5D)];
      expect(jsonDepthOk(deep), isFalse);
      // Timed as a median of five, so a busy machine doesn't fail it: it stops at the ninth byte.
      final times = <int>[];
      for (var i = 0; i < 5; i++) {
        final sw = Stopwatch()..start();
        jsonDepthOk(deep);
        times.add(sw.elapsedMicroseconds);
      }
      times.sort();
      expect(times[2], lessThan(1000), reason: 'well under a millisecond');
    });
  });

  group('words', () {
    test('control, format, private-use and blank-looking characters, a line break where none is allowed, a lone surrogate, and space at either end are refused', () {
      for (final bad in ['Bi\u2028lls', 'Bills\uF8FF', '\u3164Bills', 'Bills\u{E0041}', 'Bi\u202Ells', 'Bi\u200Blls', 'Bi\nlls', 'Bi\u0085lls', 'Bi\u00ADlls', 'Bi\uD800lls', 'Bi\uDC00lls', ' Bills', 'Bills ', 'Bi\u0000lls', 'Bi\u2800lls']) {
        expect(packTextOk(bad), isFalse, reason: jsonEncode(bad));
      }
      for (final good in ['Bills', 'Café & co', 'Payé 👻', 'A (big) one: yes!', 'Ελληνικά']) {
        expect(packTextOk(good), isTrue, reason: good);
      }
      expect(packTextOk('Line one\nLine two', newlines: true), isTrue);
      expect(packTextOk('Line one\r\nLine two', newlines: true), isFalse, reason: 'U+000A only');
    });

    test('a name holding U+2028, U+F8FF, U+3164 or U+E0041 is bad_text, as the app says', () {
      for (final c in ['\u2028', '\uF8FF', '\u3164', '\u{E0041}']) {
        expect(issues(pack(changes: {'name': 'Bi${c}lls'})), [('bad_text', 'name')], reason: jsonEncode(c));
      }
      expect(issues(pack(changes: {'description': 'One line.\nAnother.'})), isEmpty, reason: 'a description may have lines');
      expect(issues(pack(changes: {'tagline': 'One line.\nAnother.'})), [('bad_text', 'tagline')]);
    });
  });

  group('addresses', () {
    test('an https address of a public site: not an IP, not punycode, not a local name, not ours', () {
      for (final bad in ['https://192.168.1.1/x', 'https://xn--pple-43d.com', 'https://printer.local/', 'https://gogho.st/join/x', 'https://a.ghost-sms.com/', 'http://example.com/', 'https://user@example.com/', 'https://example.com:8443/', 'https://example.com/#top', 'https://example.com/{tag:x}', 'https://example.com/a b', 'https://Example.com/', 'https://example.com:443/', 'https://example.com/#', 'https://192.168.257/', 'https://0x7f.1/', 'https://example.123/', 'https://localhost/', 'https://router.lan/', 'https://box.home/', 'https://x.internal/', 'https://1.0.0.127.in-addr.arpa/', 'https://[::1]/', 'https://-bad.com/', 'https://example.com./', 'https://${'a' * 64}.com/', 'https://example.com/${'a' * 200}', 'example.com', 'https:example.com']) {
        expect(packAddressIssue(bad), 'bad_url', reason: bad);
      }
      for (final good in ['https://example.com/plugins/bills', 'https://example.com/plugins/parcels/help', 'https://help.example.co.uk/a?b=c', 'https://ghost-sms.example.com/']) {
        expect(packAddressIssue(good), isNull, reason: good);
      }
    });

    test('an email address for a help link, its domain held to the same rules', () {
      expect(packAddressIssue('help@example.com', email: true), isNull);
      expect(packAddressIssue('Maya.B+plugins@Example.COM', email: true), isNull);
      for (final bad in ['help@printer.local', 'help@xn--pple-43d.com', 'help@gogho.st', 'help@192.168.1.1', 'help@example', 'help@example.c0m', 'he lp@example.com', '${'a' * 65}@example.com']) {
        expect(packAddressIssue(bad, email: true), 'bad_email', reason: bad);
      }
      expect(packAddressIssue('help@example.com'), 'bad_url', reason: 'a link is never an email');
      expect(issues(pack(changes: {'support': 'help@example.com'})), isEmpty);
      expect(issues(pack(changes: {'support': 'help@printer.local'})), [('bad_email', 'support')]);
      expect(issues(pack(changes: {'support': 'https://printer.local/'})), [('bad_url', 'support')]);
      expect(issues(pack(changes: {'links': ['https://printer.local/']})), [('bad_url', 'links[0]')]);
      expect(issues(pack(changes: {'links': ['https://example.com/a', 'https://example.com/b']})), [('too_many', 'links')], reason: 'one link at most');
    });
  });

  group('the example packs', () {
    for (final MapEntry(key: name, value: text) in examplePacks.entries) {
      test('$name is canonical in its canonical form, as the docs give it, and is refused only for its id', () {
        final canonical = canonicalBytes(jsonDecode(text));
        expect(canonical.length, {'bills': 2193, 'parcels': 2943}[name]);
        expect(hexOf(sha256(canonical)), {'bills': '5c07c72f99f594ea3538046d4144515ed99756e9816b614a77a513c6afd562e7', 'parcels': '81ca3c8f307f3c6a4f12d4bfd5030ebe9002fd1acc3c6df0e1319995ff0c70a2'}[name]);
        expect(canonicalBytes(jsonDecode(utf8.decode(canonical))), canonical);
        expect(issues(jsonDecode(utf8.decode(canonical))), [('id_example', 'id')]);
        expect(issues(jsonDecode(text)..['id'] = 'my$name'), isEmpty);
      });
    }

    final mine = appFixtures();
    test('are the app\'s test/fixtures/packs byte for byte', () {
      for (final MapEntry(key: name, value: bytes) in mine.entries) {
        expect(examplePacks.containsKey(name), isTrue, reason: '$name: a fixture the relay\'s tests don\'t know');
        expect(utf8.decode(bytes), examplePacks[name], reason: name);
        expect(issues(jsonDecode(utf8.decode(canonicalBytes(jsonDecode(utf8.decode(bytes)))))), [('id_example', 'id')], reason: name);
      }
      expect(mine.keys.toSet(), examplePacks.keys.toSet());
    }, skip: mine.isEmpty ? '../test/fixtures/packs isn\'t on this branch yet (the app\'s, merged first)' : null);
  });

  group('each issue the relay gives', () {
    test('the file, its format and its fields', () {
      expect(issues([pack()]), [('not_object', '')]);
      expect(issues('pack'), [('not_object', '')]);
      expect(issues(pack(changes: {'format': 'ghost-plugin/2'})), [('format_unknown', 'format')]);
      expect(issues(pack(drop: ['format'])), [('format_unknown', 'format')]);
      expect(issues(pack(changes: {'title': 'Bills'})), [('unknown_field', 'title')]);
      expect(issues(pack(changes: {'text': {}})), [('unknown_field', 'text')], reason: 'no text rules in this format');
      for (final field in ['id', 'version', 'name', 'tagline', 'description', 'icon', 'hue', 'shelf', 'labels', 'permissions', 'developer', 'support', 'rules']) {
        expect(issues(pack(drop: [field])), [('missing', field)], reason: field);
      }
      expect(issues(pack(drop: ['icon', 'support']), needIcon: false, needSupport: false), isEmpty, reason: 'a check before the form has them');
      expect(issues(pack(drop: ['symbol', 'links', 'shots', 'whatsNew', 'minApp', 'settings'])), isEmpty, reason: 'none of these is needed');
      expect(issues(pack(changes: {'name': 5})), [('wrong_type', 'name')]);
      expect(issues(pack(changes: {'whatsNew': null})), [('wrong_type', 'whatsNew')]);
      expect(issues(pack(changes: {'labels': 'bills'})), [('wrong_type', 'labels')]);
      expect(issues(pack(changes: {'settings': {}})), [('wrong_type', 'settings')]);
      expect(issues(pack(changes: {'rules': []})), [('wrong_type', 'rules')]);
    });

    test('ids, versions and words', () {
      for (final bad in ['Bills', 'ab', '1bills', 'my-bills', 'a' * 25]) {
        expect(issues(pack(changes: {'id': bad})), [('bad_id', 'id')], reason: bad);
      }
      for (final id in [...reservedPackIds, 'myghostpack', 'goghoplugin']) {
        expect(issues(pack(changes: {'id': id})), [('id_reserved', 'id')], reason: id);
      }
      for (final id in examplePackIds) {
        expect(issues(pack(changes: {'id': id})), [('id_example', 'id')], reason: id);
      }
      for (final bad in ['1.0', '01.0.0', '1.0.0-beta', '100000.0.0', 'v1.0.0']) {
        expect(issues(pack(changes: {'version': bad})), [('bad_version', 'version')], reason: bad);
      }
      expect(issues(pack(changes: {'version': '99999.0.10'})), isEmpty);
      expect(issues(pack(changes: {'minApp': '0.10'})), [('bad_version', 'minApp')]);
      expect(issues(pack(changes: {'minApp': '0.10.1'})), isEmpty);
      expect(issues(pack(changes: {'name': ''})), [('too_short', 'name')]);
      expect(issues(pack(changes: {'name': 'a' * 33})), [('too_long', 'name')]);
      expect(issues(pack(changes: {'name': 'a' * 32})), isEmpty);
      expect(issues(pack(changes: {'tagline': 'a' * 61})), [('too_long', 'tagline')]);
      expect(issues(pack(changes: {'description': 'a' * 1501})), [('too_long', 'description')]);
      expect(issues(pack(changes: {'whatsNew': 'a' * 501})), [('too_long', 'whatsNew')]);
      expect(issues(pack(changes: {'whatsNew': ''})), isEmpty, reason: '0 to 500');
      expect(issues(pack(changes: {'whatsNew': 'Fixed it.\u202E'})), [('bad_text', 'whatsNew')]);
      expect(issues(pack(changes: {'symbol': 'a' * 41})), [('too_long', 'symbol')]);
      expect(issues(pack(changes: {'symbol': 'not-an-icon-the-relay-knows'})), isEmpty, reason: 'the relay doesn\'t check icon names');
      expect(issues(pack(changes: {'support': 'https://example.com/${'a' * 200}'})), [('too_long', 'support')]);
    });

    test('the vocabularies, the counts, the duplicates', () {
      expect(issues(pack(changes: {'hue': 'beige'})), [('bad_hue', 'hue')]);
      expect(issues(pack(changes: {'shelf': 'fun'})), [('bad_shelf', 'shelf')]);
      expect(issues(pack(changes: {'labels': ['bills', 'cats']})), [('bad_label', 'labels[1]')]);
      expect(issues(pack(changes: {'labels': []})), [('too_few', 'labels')]);
      expect(issues(pack(changes: {'labels': ['bills', 'money', 'sorting', 'work', 'travel']})), [('too_many', 'labels')]);
      expect(issues(pack(changes: {'labels': ['bills', 'bills']})), [('duplicate', 'labels[1]')]);
      expect(issues(pack(changes: {'permissions': ['sort', 'hide']})), [('bad_permission', 'permissions[1]')], reason: 'no hide in this format');
      expect(issues(pack(changes: {'permissions': ['sort', 'sort']})), [('duplicate', 'permissions[1]')]);
      expect(issues(pack(changes: {'permissions': []})), isEmpty, reason: 'may be empty: what the rules need is the app\'s to check');
      expect(issues(pack(changes: {'shots': ['A' * 64]})), [('bad_shot', 'shots[0]')]);
      expect(issues(pack(changes: {'shots': ['a' * 63]})), [('bad_shot', 'shots[0]')]);
      expect(issues(pack(changes: {'shots': List.filled(2, 'a' * 64)})), [('duplicate', 'shots[1]')]);
      expect(issues(pack(changes: {'shots': [for (var i = 0; i < 5; i++) '$i' * 64]})), [('too_many', 'shots')]);
      expect(issues(pack(changes: {'shots': [for (var i = 0; i < 4; i++) '$i' * 64]})), isEmpty);
    });

    test('a list past its cap is read only as far as the cap, and a check keeps its first hundred problems', () {
      // Any fresh key's 256 KiB package of 87,000 empty permissions came back as 87,000 issues, a 14 MB answer built on
      // the hub's one isolate before its owner was even asked (review, 2026-11-20); the app's check keeps a hundred.
      expect(issues(pack(changes: {'permissions': [...packPermissions, 'sort']})), [('too_many', 'permissions')], reason: 'seven at most, as the app says');
      final many = checkPackTop(pack(changes: {'permissions': List.filled(87307, '')})).issues;
      expect([for (final i in many) i.code], ['too_many', ...List.filled(packPermissions.length, 'bad_permission')], reason: 'the cap said once, then the seven a pack may have');
      final labels = checkPackTop(pack(changes: {'labels': List.filled(130978, '')})).issues;
      expect([for (final i in labels) i.code], ['too_many', 'bad_label', 'bad_label', 'bad_label', 'bad_label'], reason: 'only the four a pack may have are read');
      final unknown = checkPackTop(pack(changes: {for (var i = 0; i < 24820; i++) 'k$i': 1})).issues;
      expect(unknown, hasLength(packIssuesMost));
      expect(unknown.last.code, 'too_many_issues');
      expect(unknown.last.message, 'And 24721 more problems like these: fix the ones above and check it again.');
      expect(utf8.encode(jsonEncode([for (final i in unknown) i.toJson()])).length, lessThan(16 * 1024), reason: 'an answer of a few KB');
    });

    test('the developer: a username with no reserved word anywhere in it', () {
      for (final bad in ['ghostdev', 'officialbills', 'goghostore', 'verifiedmaya', 'mayasupport', 'Maya', 'ma', 'ma..ya', '.maya', 'maya!', 'a' * 21]) {
        expect(issues(pack(changes: {'developer': bad})), [('bad_developer', 'developer')], reason: bad);
      }
      for (final good in ['maya', 'maya.b', 'maya_b', '123', 'yourname']) {
        expect(issues(pack(changes: {'developer': good})), isEmpty, reason: good);
      }
    });
  });

  group('pictures', () {
    test('an icon: a square PNG of 64 to 512 pixels holding only the allowed chunks, nothing after IEND, at most 36,000 bytes of base64', () {
      expect(issues(pack(changes: {'icon': icon(png(64, 64))})), isEmpty);
      expect(issues(pack(changes: {'icon': icon(png(512, 512))})), isEmpty);
      expect(issues(pack(changes: {'icon': icon(png(64, 64, chunks: [('sRGB', [0]), ('gAMA', [0, 0, 0xb1, 0x8f]), ('pHYs', List.filled(9, 1)), ('PLTE', [0, 0, 0]), ('tRNS', [0]), ('IDAT', [1, 2, 3])]))})), isEmpty);
      final bad = {
        '63 px': png(63, 63),
        '513 px': png(513, 513),
        'not square': png(64, 128),
        'animated': png(64, 64, chunks: [('acTL', List.filled(8, 0)), ('IDAT', [1])]),
        'text': png(64, 64, chunks: [('tEXt', ascii.encode('Comment\u0000hello')), ('IDAT', [1])]),
        'a colour profile': png(64, 64, chunks: [('iCCP', List.filled(12, 0)), ('IDAT', [1])]),
        'EXIF': png(64, 64, chunks: [('eXIf', List.filled(12, 0)), ('IDAT', [1])]),
        'bytes after IEND': png(64, 64, after: [0]),
        'no IEND': png(64, 64, iend: false),
        'no IHDR first': png(64, 64, ihdr: false),
        '36,001 bytes': () {
          final base = png(64, 64, chunks: [('IDAT', const [])]);
          return png(64, 64, chunks: [('IDAT', List.filled(36001 - base.length, 7))]);
        }(),
        'a chunk running past the end': png(64, 64).sublist(0, 40),
      };
      expect(bad['36,001 bytes']!.length, 36001);
      for (final MapEntry(key: why, value: bytes) in bad.entries) {
        expect(issues(pack(changes: {'icon': icon(bytes)})), [('bad_icon', 'icon')], reason: why);
      }
      for (final text in ['iVBOR!!!', '${icon(png(64, 64))}\n', 'iVBORw0KGgo', '${icon(png(64, 64))}A===', icon(png(64, 64)).replaceAll('/', '_'), '']) {
        expect(issues(pack(changes: {'icon': text})), [('bad_icon', 'icon')], reason: 'not base64 as the app writes it: ${jsonEncode(text.length > 12 ? text.substring(text.length - 12) : text)}');
      }
      for (final text in examplePacks.values) {
        final i = (jsonDecode(text) as Map)['icon'] as String;
        expect(iconProblem(i), isNull, reason: 'the examples\' icons');
        expect(pngInfo(base64Decode(i))!.chunks, ['IHDR', 'IDAT', 'IEND']);
      }
    });

    test('a screenshot: a PNG of 64 to 2,400 pixels a side with only the allowed chunks; never another kind of picture', () {
      String? shot(List<int> bytes) => pngProblem(bytes, min: PackLimits.shotMin, max: PackLimits.shotMax);
      expect(shot(png(64, 2400)), isNull);
      expect(shot(png(1080, 2400)), isNull);
      expect(shot(png(63, 400)), isNotNull);
      expect(shot(png(2401, 400)), isNotNull);
      expect(shot(png(400, 2401)), isNotNull);
      expect(shot(png(400, 400, chunks: [('tEXt', ascii.encode('Author\u0000me')), ('IDAT', [1])])), contains('tEXt'));
      expect(shot([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, ...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]), isNotNull, reason: 'a JPEG');
      final info = pngInfo(png(300, 200, chunks: [('PLTE', [0, 0, 0]), ('IDAT', [1])]))!;
      expect([info.width, info.height, info.bitDepth, info.colorType, info.interlace], [300, 200, 8, 6, 0]);
      expect(info.chunks, ['IHDR', 'PLTE', 'IDAT', 'IEND']);
      expect(pngChunksAllowed, {'IHDR', 'PLTE', 'tRNS', 'sRGB', 'gAMA', 'pHYs', 'IDAT', 'IEND'});
    });
  });

  group('the vocabularies', () {
    final file = File('../lib/plugins/pack/format.dart');
    final there = file.existsSync();
    test('are the app\'s own lists, read out of lib/plugins/pack/format.dart', () {
      final src = file.readAsStringSync();
      List<String> listOf(String name) {
        final v = valueOf(src, name);
        expect(v, isNotNull, reason: '$name in format.dart');
        return stringsIn(v!);
      }

      expect(listOf('reservedPackIds').toSet(), reservedPackIds);
      expect(reservedPackIds, hasLength(38));
      expect(listOf('examplePackIds').toSet(), examplePackIds);
      expect(listOf('reservedDeveloperWords'), reservedDeveloperWords);
      expect(listOf('packHues'), packHues);
      final labels = listOf('packLabels');
      expect([for (var i = 0; i < labels.length; i += 2) labels[i]], packLabels, reason: 'the wire names, in order');
      expect(listOf('packShelves'), packShelves);
      final at = src.indexOf(RegExp(r'enum\s+PackPermission\b'));
      expect(at, greaterThanOrEqualTo(0), reason: 'enum PackPermission in format.dart');
      final body = bracketed(src, src.indexOf('{', at))!;
      expect([for (final m in RegExp(r"\(\s*'([a-z]+)'\s*\)").allMatches(body)) m.group(1)], packPermissions);
    }, skip: there ? null : 'lib/plugins/pack/format.dart isn\'t on this branch yet (the app\'s, merged first)');
  });
}
