import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/codes.dart' show signInCode;
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// The pack format "ghost-plugin/1" (lib/plugins/pack/manifest.dart; Matt, 2026-11-20: "I would like users to be able
/// to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the
/// store through a review process"): the two example packs as the format gives them, then, for each issue code, a pack
/// that breaks that and gives it at its path. The packs are the docs' (test/fixtures/packs, the format's A.15).
void main() {
  final billsBytes = File('test/fixtures/packs/bills.ghostplugin').readAsBytesSync();
  final parcelsBytes = File('test/fixtures/packs/parcels.ghostplugin').readAsBytesSync();
  Map<String, dynamic> bills() => jsonDecode(utf8.decode(billsBytes)) as Map<String, dynamic>;
  Map<String, dynamic> parcels() => jsonDecode(utf8.decode(parcelsBytes)) as Map<String, dynamic>;
  PackParse check(Object? json, {bool submission = false, bool checkMinApp = true}) => parsePackJson(json, appVersion: '0.10.1', submission: submission, checkMinApp: checkMinApp);

  /// [p] has the error [code] at [path], and no pack; [alone]: and no other kind of error.
  void expectError(PackParse p, String code, String path, {bool alone = true}) {
    final errors = p.errors.toList();
    expect(errors.any((e) => e.code == code && e.path == path), isTrue, reason: 'wanted $code at "$path"; got ${errors.join('; ')}');
    if (alone) expect(errors.map((e) => e.code).toSet(), {code}, reason: errors.join('; '));
    expect(p.pack, isNull);
    expect(p.ok, isFalse);
  }

  group('the A.15 packs', () {
    test('Bills parses with no error and no warning, its canonical bytes 2,193 with the format\'s SHA-256', () {
      final p = parsePack(billsBytes, appVersion: '0.10.1');
      expect(p.issues, isEmpty);
      expect(p.ok, isTrue);
      expect(p.canonical, hasLength(2193));
      expect(p.sha256, '5c07c72f99f594ea3538046d4144515ed99756e9816b614a77a513c6afd562e7');
      final pack = p.pack!;
      expect(pack.registryId, 'xbills');
      expect(pack.labels, ['bills', 'money', 'sorting']);
      expect(pack.permissions, {PackPermission.sort, PackPermission.copy, PackPermission.markRead});
      expect(pack.rules.tags.map((r) => r.tag), ['bill', 'paid']);
      expect(pack.rules.sections.map((s) => '${s.key}:${s.kind}'), ['bills:tab', 'receipts:filter']);
      expect(pack.icon, isNotNull);
      expect(pngInfo(pack.icon!)!.width, 64);
      expect(() => (pack.json['rules'] as Map)['tags'] = [], throwsUnsupportedError, reason: 'the pack\'s JSON is changed on a copy, never in place');
    });

    test('Parcels parses with no error and one warning, opens_links, its canonical bytes 2,943', () {
      final p = parsePack(parcelsBytes, appVersion: '0.10.1');
      expect(p.errors, isEmpty);
      expect(p.warnings.map((w) => '${w.code} ${w.path}'), ['opens_links links[0]']);
      expect(p.warnings.single.message, contains('Opens https://example.com/plugins/parcels/help when pressed: check it is the developer\'s own page.'));
      expect(p.canonical, hasLength(2943));
      expect(p.sha256, '81ca3c8f307f3c6a4f12d4bfd5030ebe9002fd1acc3c6df0e1319995ff0c70a2');
    });

    test('submitted, each gives exactly one error, id_example', () {
      for (final bytes in [billsBytes, parcelsBytes]) {
        final p = parsePack(bytes, appVersion: '0.10.1', submission: true);
        expect(p.errors.map((e) => '${e.code} ${e.path}'), ['id_example id']);
        expect(p.errors.single.message, 'id: That\'s the example\'s id: give your plugin an id of its own.');
      }
    });

    test('a leading BOM and any form of the JSON load; the canonical bytes are the same', () {
      final pretty = utf8.encode(const JsonEncoder.withIndent('    ').convert(bills()));
      final p = parsePack([0xEF, 0xBB, 0xBF, ...pretty], appVersion: '0.10.1');
      expect(p.ok, isTrue);
      expect(p.sha256, '5c07c72f99f594ea3538046d4144515ed99756e9816b614a77a513c6afd562e7');
    });
  });

  group('before anything is decoded', () {
    test('too_large', () {
      final p = parsePack(List.filled(262145, 0x20), appVersion: '0.10.1');
      expect(p.issues.map((i) => '${i.code} ${i.path}'), ['too_large ']);
    });

    test('too_deep: nine deep, and a 131,072-deep file, at once', () {
      expect(parsePack(utf8.encode('{"a":[[[[[[[[1]]]]]]]]}'), appVersion: '0.10.1').issues.single.code, 'too_deep');
      final deep = [...List.filled(131072, 0x5B), ...List.filled(131072, 0x5D)];
      final watch = Stopwatch()..start();
      final p = parsePack(deep, appVersion: '0.10.1');
      expect(p.issues.single.code, 'too_deep');
      expect(watch.elapsedMilliseconds, lessThan(250));
    });

    test('bad_utf8, bad_json, not_object', () {
      expect(parsePack([0x7B, 0xFF, 0x7D], appVersion: '0.10.1').issues.single.code, 'bad_utf8');
      expect(parsePack(utf8.encode('{"id": '), appVersion: '0.10.1').issues.single.code, 'bad_json');
      expect(parsePack(const [], appVersion: '0.10.1').issues.single.code, 'bad_json');
      final list = parsePack(utf8.encode('[]'), appVersion: '0.10.1');
      expect(list.issues.single.code, 'not_object');
      expect(list.canonical, utf8.encode('[]'), reason: 'canonical wherever it was JSON without fractions');
    });

    test('parsePackJson never throws, whatever it is given', () {
      expect(check(Object()).errors.single.code, 'wrong_type');
      expect(check(null).errors.single.code, 'not_object');
      expect(check({1: 2}).errors.first.code, 'wrong_type');
    });
  });

  group('the top level', () {
    test('format_unknown', () {
      expectError(check(bills()..['format'] = 'ghost-plugin/2'), 'format_unknown', 'format');
      expectError(check(bills()..remove('format')), 'format_unknown', 'format');
    });

    test('needs_newer_app, and none where minApp is left unchecked', () {
      expectError(check(bills()..['minApp'] = '99.0.0'), 'needs_newer_app', 'minApp');
      expect(check(bills()..['minApp'] = '99.0.0', checkMinApp: false).ok, isTrue);
      expect(check(bills()..['minApp'] = '0.10.1').ok, isTrue);
      expect(parsePackJson(bills()..['minApp'] = '0.10.2', appVersion: '0.10.1+7').errors.single.code, 'needs_newer_app');
    });

    test('unknown_field, at the top and at depth', () {
      expectError(check(bills()..['colour'] = 'amber'), 'unknown_field', 'colour');
      expectError(check(bills()..['settings'][0]['colour'] = 'amber'), 'unknown_field', 'settings[0].colour');
      expectError(check(bills()..['settings'][1]['default'] = 'x'), 'unknown_field', 'settings[1].default');
      expectError(check(bills()..['rules']['actions'][0]['colour'] = 'amber'), 'unknown_field', 'rules.actions[0].colour');
      expectError(check(bills()..['rules']['text'] = []), 'unknown_field', 'rules.text');
    });

    test('a row\'s title, a section\'s hidden and a condition\'s group are unknown_field', () {
      expectError(check(bills()..['rules']['sections'][0]['row']['title'] = 'Bills'), 'unknown_field', 'rules.sections[0].row.title');
      expectError(check(bills()..['rules']['sections'][1]['hidden'] = true), 'unknown_field', 'rules.sections[1].hidden');
      expectError(check(bills()..['rules']['sections'][0]['takes']['group'] = false), 'unknown_field', 'rules.sections[0].takes.group');
    });

    test('missing, and in a submission icon, developer and support', () {
      expectError(check(bills()..remove('name')), 'missing', 'name');
      expectError(check(bills()..remove('rules')), 'missing', 'rules');
      final noIcon = bills()..remove('icon');
      expect(check(noIcon).ok, isTrue, reason: 'loading in developer mode needs no icon');
      expect(check(noIcon).pack!.icon, isNull);
      final submitted = check(bills()
        ..['id'] = 'mybills'
        ..remove('icon')
        ..remove('developer')
        ..remove('support'), submission: true);
      expect(submitted.errors.map((e) => '${e.code} ${e.path}').toSet(), {'missing icon', 'missing developer', 'missing support'});
      expect(check(bills()..['id'] = 'mybills', submission: true).ok, isTrue);
    });

    test('wrong_type and fraction', () {
      expectError(check(bills()..['name'] = 5), 'wrong_type', 'name');
      expectError(check(bills()..['labels'] = 'bills'), 'wrong_type', 'labels');
      expectError(check(bills()..['icon'] = null), 'wrong_type', 'icon');
      expectError(check(bills()..['settings'][0]['default'] = 'no'), 'wrong_type', 'settings[0].default');
      expectError(check(bills()..['rules']['tags'][0]['atLeast'] = 1.5), 'fraction', 'rules.tags[0].atLeast');
      expectError(check(bills()..['rules']['tags'][0]['atLeast'] = 1.0), 'fraction', 'rules.tags[0].atLeast');
      final p = parsePack(utf8.encode(utf8.decode(billsBytes).replaceFirst('"version": "1.0.0"', '"version": "1.0.0", "n": 1e3')), appVersion: '0.10.1');
      expect(p.errors.map((e) => e.code).toSet(), {'fraction', 'unknown_field'});
      expect(p.canonical, isNull, reason: 'a fraction has no canonical form');
    });

    test('bad_text: a name holding U+2028, U+F8FF, U+3164 or U+E0041, and more', () {
      for (final bad in ['Bi\u2028lls', 'Bills \uF8FF', '\u3164Bills', 'Bills\u{E0041}', 'Bi\u200Blls', 'Bills ', 'Bi\nlls', 'Bi\u202Ells', 'Bi\u0085lls', '\uD800Bills']) {
        expectError(check(bills()..['name'] = bad), 'bad_text', 'name');
      }
      expect(check(bills()..['description'] = 'Two\nlines.').ok, isTrue, reason: 'a description may have lines');
      expectError(check(bills()..['tagline'] = 'Two\nlines'), 'bad_text', 'tagline');
    });

    test('too_long and too_short', () {
      expectError(check(bills()..['name'] = 'B' * 33), 'too_long', 'name');
      expect(check(bills()..['name'] = 'B' * 32).ok, isTrue);
      expectError(check(bills()..['name'] = ''), 'too_short', 'name');
      expectError(check(bills()..['tagline'] = 't' * 61), 'too_long', 'tagline');
      expectError(check(bills()..['description'] = 'd' * 1501), 'too_long', 'description');
      expectError(check(bills()..['whatsNew'] = 'w' * 501), 'too_long', 'whatsNew');
      expect(check(bills()..['whatsNew'] = '').ok, isTrue);
    });

    test('too_many, too_few and duplicate', () {
      expectError(check(bills()..['labels'] = ['bills', 'money', 'sorting', 'work', 'travel']), 'too_many', 'labels');
      expectError(check(bills()..['labels'] = []), 'too_few', 'labels');
      expectError(check(bills()..['labels'] = ['bills', 'bills']), 'duplicate', 'labels[1]');
      expectError(check(bills()..['permissions'] = ['sort', 'copy', 'markread', 'copy']), 'duplicate', 'permissions[3]');
      expectError(check(bills()..['shots'] = ['a' * 64, 'a' * 64]), 'duplicate', 'shots[1]');
      expectError(check(bills()..['shots'] = ['a' * 64, 'b' * 64, 'c' * 64, 'd' * 64, 'e' * 64]), 'too_many', 'shots');
      expectError(check(bills()..['rules']['tags'][0]['any'] = [for (var i = 0; i < 31; i++) 'your bill number $i']), 'too_many', 'rules.tags[0].any');
    });

    test('bad_id, every reserved id, myghostpack, and an example\'s id only in a submission', () {
      for (final bad in ['Bills', 'bi', '1bills', 'bills-pay', 'b' * 25]) {
        expectError(check(bills()..['id'] = bad), 'bad_id', 'id');
      }
      for (final id in [...reservedPackIds, 'myghostpack', 'goghobills']) {
        expectError(check(bills()..['id'] = id), 'id_reserved', 'id');
      }
      expect(reservedPackIds, hasLength(38));
      expect(check(bills()..['id'] = 'bills').ok, isTrue);
      expectError(check(bills(), submission: true), 'id_example', 'id');
    });

    test('bad_version, bad_hue, bad_shelf, bad_label, bad_permission', () {
      expectError(check(bills()..['version'] = '1.0'), 'bad_version', 'version');
      expectError(check(bills()..['version'] = '01.0.0'), 'bad_version', 'version');
      expectError(check(bills()..['minApp'] = 'soon'), 'bad_version', 'minApp');
      expectError(check(bills()..['hue'] = 'teal'), 'bad_hue', 'hue');
      expectError(check(bills()..['shelf'] = 'fun'), 'bad_shelf', 'shelf');
      expectError(check(bills()..['labels'] = ['bills', 'crypto']), 'bad_label', 'labels[1]');
      expectError(check(bills()..['permissions'] = ['sort', 'copy', 'markread', 'hide']), 'bad_permission', 'permissions[3]');
    });

    test('bad_icon_name for ghost, store and shield-check, and a name that isn\'t an icon', () {
      for (final name in ['ghost', 'store', 'shield-check', 'not-an-icon']) {
        expectError(check(bills()..['symbol'] = name), 'bad_icon_name', 'symbol');
      }
      expectError(check(bills()..['rules']['sections'][0]['icon'] = 'ghost'), 'bad_icon_name', 'rules.sections[0].icon');
      expectError(check(bills()..['rules']['actions'][0]['icon'] = 'store'), 'bad_icon_name', 'rules.actions[0].icon');
      expectError(check(bills()..['settings'][0]['icon'] = 'shield-check'), 'bad_icon_name', 'settings[0].icon');
    });

    test('bad_shot, bad_developer', () {
      expectError(check(bills()..['shots'] = ['ABC']), 'bad_shot', 'shots[0]');
      expectError(check(bills()..['shots'] = ['A' * 64]), 'bad_shot', 'shots[0]');
      expect(check(bills()..['shots'] = ['a' * 64]).pack!.shots, ['a' * 64]);
      for (final bad in ['ghostdev', 'officialbills', 'my.support', 'verified1', 'Maya', 'a..b', 'ab', '_maya', 'm' * 21]) {
        expectError(check(bills()..['developer'] = bad), 'bad_developer', 'developer');
      }
      expect(check(bills()..['developer'] = 'maya.k_2').ok, isTrue);
    });
  });

  group('the icon', () {
    List<int> u32(int n) => [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
    List<int> chunk(String type, List<int> data) => [...u32(data.length), ...ascii.encode(type), ...data, 0, 0, 0, 0];
    List<int> png(int w, int h, {List<String> extra = const [], int idat = 1, List<int> after = const []}) => [
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
          ...chunk('IHDR', [...u32(w), ...u32(h), 8, 6, 0, 0, 0]),
          for (final t in extra) ...chunk(t, const [0]),
          ...chunk('IDAT', List.filled(idat, 0)),
          ...chunk('IEND', const []),
          ...after,
        ];
    PackParse withIcon(List<int> bytes) => check(bills()..['icon'] = base64Encode(bytes));

    test('a square PNG of 64 to 512 holding only its pixels is fine', () {
      expect(withIcon(png(64, 64)).ok, isTrue);
      expect(withIcon(png(512, 512, extra: ['PLTE', 'tRNS', 'sRGB', 'gAMA', 'pHYs'])).ok, isTrue);
    });

    test('63 and 513 px, not square, acTL, tEXt, iCCP, eXIf, bytes after IEND, 36,001 bytes, bad base64', () {
      for (final bad in [
        png(63, 63),
        png(513, 513),
        png(64, 65),
        png(64, 64, extra: ['acTL']),
        png(64, 64, extra: ['tEXt']),
        png(64, 64, extra: ['iCCP']),
        png(64, 64, extra: ['eXIf']),
        png(64, 64, after: const [0]),
        png(64, 64, idat: 36001 - png(64, 64, idat: 0).length),
        const [1, 2, 3],
      ]) {
        expectError(withIcon(bad), 'bad_icon', 'icon');
      }
      expect(png(64, 64, idat: 36001 - png(64, 64, idat: 0).length), hasLength(36001));
      expect(withIcon(png(64, 64, idat: 36000 - png(64, 64, idat: 0).length)).ok, isTrue, reason: '36,000 bytes is the most');
      for (final bad in ['not base64!', '${base64Encode(png(64, 64))}\n', base64Encode(png(64, 64)).replaceAll('=', ''), '${base64Url.encode(png(64, 64))}-']) {
        expectError(check(bills()..['icon'] = bad), 'bad_icon', 'icon');
      }
    });

    test('base64 whose last bits aren\'t zero is bad_icon at icon beside every other problem, not the whole file\'s bad_json', () {
      // "AB==" and "AAB=" have the right shape, but Dart's decoder refuses them ("Invalid encoding before padding"):
      // that once ended the check, so the developer heard the file couldn't be read and nothing else.
      final real = bills()['icon'] as String;
      expect(real, endsWith('=='), reason: 'the fixture\'s icon ends in a group with unused bits to set');
      // "…Jggg==" made "…Jggh==": h is 33, so the four bits after its first two aren't zero.
      final stray = '${real.substring(0, real.length - 3)}h==';
      for (final icon in ['AB==', 'AAB=', stray]) {
        for (final submission in [false, true]) {
          final json = bills()
            ..['icon'] = icon
            ..['hue'] = 'nope';
          if (submission) json['id'] = 'mybills';
          final p = check(json, submission: submission);
          expect(p.errors.map((e) => '${e.code} ${e.path}').toSet(), {'bad_icon icon', 'bad_hue hue'}, reason: '$icon: ${p.issues.join('; ')}');
          expect(p.canonical, isNotNull, reason: 'the file is JSON without fractions');
          expect(p.sha256, hasLength(64));
        }
        final bytes = utf8.encode(jsonEncode(bills()
          ..['icon'] = icon
          ..['hue'] = 'nope'));
        expect(parsePack(bytes, appVersion: '0.10.1').errors.map((e) => '${e.code} ${e.path}').toSet(), {'bad_icon icon', 'bad_hue hue'}, reason: 'developer loading, from the bytes');
      }
    });
  });

  group('names like the app\'s own', () {
    test('name_reserved for Codes, a Cyrillic \u0421odes, fullwidth Ｃｏｄｅｓ, Kinds of text, Uplink Helper and a section called Spam', () {
      for (final name in ['Codes', '\u0421odes', 'Ｃｏｄｅｓ', 'Kinds of text', 'Uplink Helper', 'UpIink tools', 'Up1ink', 'Ghost Helper', 'Códes', 'C o d e s', 'Gh0st Helper', 'Spam filter', 'GOGHO']) {
        expectError(check(bills()..['name'] = name), 'name_reserved', 'name');
      }
      expectError(check(bills()..['rules']['sections'][0]['label'] = 'Spam'), 'name_reserved', 'rules.sections[0].label');
      expect(check(bills()..['name'] = 'Bill tracker').ok, isTrue);
    });

    test('packFold folds the look-alikes the format pins', () {
      expect(packFold('\u0421odes'), 'codes');
      expect(packFold('Ｃｏｄｅｓ'), 'codes');
      expect(packFold('Códes'), 'codes');
      expect(packFold('C o d e s'), 'codes');
      expect(packFold('Gh0st Helper'), 'ghosthelper');
      expect(packFold('Straße'), 'strasse');
      expect(packFold('\u039Dotes'), 'notes', reason: 'a capital Greek \u039D is an N');
      expect(reservedPluginNames, containsAll(['codes', 'kindsoftext', 'spam', 'spamfilter', 'paymentreminders', 'deliveriestracking']));
    });
  });

  group('addresses', () {
    test('bad_url for an address, a punycode host, a local name, Uplink\'s own, and more', () {
      final withLink = parcels();
      for (final bad in ['https://192.168.1.1/x', 'https://xn--pple-43d.com', 'https://printer.local/', 'https://gogho.st/join/x', 'https://a.ghost-sms.com/', 'http://example.com/', 'https://example.com:8443/', 'https://me@example.com/', 'https://example.com/#top', 'https://localhost/', 'https://example.com/{x}', 'https://192.168.257/', 'https://exa mple.com/']) {
        final p = check(parcels()
          ..['links'] = [bad]
          ..['rules']['actions'][2]['url'] = bad);
        expect(p.errors.any((e) => e.code == 'bad_url' && e.path == 'links[0]'), isTrue, reason: '$bad: ${p.errors.join('; ')}');
        expectError(check(parcels()..['support'] = bad), 'bad_url', 'support');
      }
      expect(check(withLink).ok, isTrue);
      expect(check(parcels()..['support'] = 'https://example.com/help?topic=parcels').ok, isTrue, reason: 'a fixed query is fine');
      expect(check(parcels()..['support'] = 'help@example.com').ok, isTrue);
    });

    test('bad_email', () {
      for (final bad in ['help@localhost', 'help@printer.local', 'help@gogho.st', 'he lp@example.com', 'help@xn--pple-43d.com']) {
        expectError(check(parcels()..['support'] = bad), 'bad_email', 'support');
      }
    });

    test('two links are too_many, and a link action\'s address must be the pack\'s one', () {
      expectError(check(parcels()..['links'] = ['https://example.com/plugins/parcels/help', 'https://example.com/b']), 'too_many', 'links');
      expectError(check(parcels()..['rules']['actions'][2]['url'] = 'https://example.com/elsewhere'), 'link_not_declared', 'rules.actions[2].url');
    });
  });

  group('rules', () {
    test('not_object for a rule, a setting and a condition', () {
      expectError(check(bills()..['rules']['tags'][1] = 'paid'), 'not_object', 'rules.tags[1]', alone: false);
      expectError(check(bills()..['settings'][1] = 'words'), 'not_object', 'settings[1]', alone: false);
      expectError(check(bills()..['rules']['tags'][0]['when'] = 'always'), 'not_object', 'rules.tags[0].when');
      expectError(check(bills()..['rules'] = []), 'not_object', 'rules');
    });

    test('bad_key for a setting key, a section key, a tag, an action id and an option value', () {
      expectError(check(bills()..['settings'][1]['key'] = 'Extra'), 'bad_key', 'settings[1].key', alone: false);
      expectError(check(bills()..['rules']['sections'][1]['key'] = 'receipts2'), 'bad_key', 'rules.sections[1].key', alone: false);
      expectError(check(bills()..['rules']['tags'][1]['tag'] = 'Paid'), 'bad_key', 'rules.tags[1].tag', alone: false);
      expectError(check(bills()..['rules']['actions'][0]['id'] = 'copy-amount'), 'bad_key', 'rules.actions[0].id', alone: false);
      expectError(check(parcels()..['settings'][0]['options'][1]['value'] = 'Loose!'), 'bad_key', 'settings[0].options[1].value', alone: false);
    });

    test('duplicate keys, ids and option values', () {
      expectError(check(bills()..['settings'][1]['key'] = 'autoread'), 'duplicate', 'settings[1].key', alone: false);
      final twice = bills();
      twice['rules']['sections'][1]['key'] = 'bills';
      expectError(check(twice), 'duplicate', 'rules.sections[1].key', alone: false);
      final twoActions = bills();
      (twoActions['rules']['actions'] as List).add({'id': 'copyamount', 'label': 'Say hi', 'icon': 'copy', 'slots': ['list.conversation.menu'], 'do': 'say', 'text': 'Hi'});
      expectError(check(twoActions), 'duplicate', 'rules.actions[1].id');
      expectError(check(parcels()..['settings'][0]['options'][1]['value'] = 'strict'), 'duplicate', 'settings[0].options[1].value', alone: false);
      final setting = parcels();
      setting['settings'][0]['type'] = 'slider';
      expectError(check(setting), 'wrong_type', 'settings[0].type', alone: false);
    });

    test('bad_slot, bad_verb, verb_fields', () {
      expectError(check(bills()..['rules']['actions'][0]['slots'] = ['row', 'list.header']), 'bad_slot', 'rules.actions[0].slots[1]');
      expectError(check(bills()..['rules']['actions'][0]['do'] = 'delete'), 'bad_verb', 'rules.actions[0].do', alone: false);
      expectError(check(bills()..['rules']['sections'][0]['kind'] = 'drawer'), 'bad_verb', 'rules.sections[0].kind', alone: false);
      expectError(check(bills()..['rules']['incoming'][0]['do'] = ['archive']), 'bad_verb', 'rules.incoming[0].do[0]', alone: false);
      expectError(check(bills()..['rules']['actions'][0].remove('text')), 'verb_fields', 'rules.actions[0].text');
      expectError(check(bills()..['rules']['actions'][0]['to'] = 'main'), 'verb_fields', 'rules.actions[0].to');
      expectError(check(parcels()..['rules']['actions'][2].remove('url')), 'verb_fields', 'rules.actions[2].url');
    });

    test('verb_not_here: write in the list\'s menu, move in a message\'s, move to a filter, a row\'s tap that isn\'t a copy', () {
      expectError(check(parcels()..['rules']['actions'][1]['slots'] = ['row']), 'verb_not_here', 'rules.actions[1].slots[0]');
      // Parcels has three in the list's menu already, so a fourth is slot_full too.
      expectError(check(parcels()..['rules']['actions'][1]['slots'] = ['list.conversation.menu']), 'verb_not_here', 'rules.actions[1].slots[0]', alone: false);
      expectError(check(parcels()..['rules']['actions'][3]['slots'] = ['conversation.message.menu']), 'verb_not_here', 'rules.actions[3].slots[0]');
      final toFilter = bills();
      toFilter['permissions'] = ['sort', 'copy', 'markread', 'move'];
      (toFilter['rules']['actions'] as List).add({'id': 'toreceipts', 'label': 'It\'s a receipt', 'icon': 'check-check', 'slots': ['list.conversation.menu'], 'do': 'move', 'to': 'receipts'});
      expectError(check(toFilter), 'verb_not_here', 'rules.actions[1].to');
      final tapLink = parcels();
      tapLink['rules']['actions'][2]['slots'] = ['list.conversation.menu', 'row'];
      tapLink['rules']['sections'][0]['row']['tap'] = 'help';
      expectError(check(tapLink), 'verb_not_here', 'rules.sections[0].row.tap');
      final rowWrite = parcels();
      rowWrite['rules']['actions'][1]['slots'] = ['conversation.message.menu', 'row'];
      rowWrite['rules']['sections'][0]['row']['word'] = 'neighbour';
      expectError(check(rowWrite), 'verb_not_here', 'rules.sections[0].row.word', alone: false);
    });

    test('unknown_setting, unknown_tag, unknown_section, unknown_action', () {
      expectError(check(bills()..['rules']['tags'][0]['wordsFrom'] = 'autoread'), 'unknown_setting', 'rules.tags[0].wordsFrom');
      expectError(check(bills()..['rules']['tags'][1]['when'] = {'setting': 'extra'}), 'unknown_setting', 'rules.tags[1].when.setting');
      expectError(check(parcels()..['rules']['tags'][1]['when']['setting']['is'] = 'medium'), 'unknown_setting', 'rules.tags[1].when.setting.is');
      expectError(check(bills()..['rules']['incoming'][0]['setting'] = 'nope'), 'unknown_setting', 'rules.incoming[0].setting');
      expectError(check(bills()..['rules']['sections'][0]['takes']['tagged'] = ['nope']), 'unknown_tag', 'rules.sections[0].takes.tagged[0]');
      expectError(check(bills()..['rules']['sections'][0]['row']['value'] = '{tag:nope}'), 'unknown_tag', 'rules.sections[0].row.value');
      expectError(check(bills()..['rules']['incoming'][0]['in'] = 'nope'), 'unknown_section', 'rules.incoming[0].in');
      expectError(check(parcels()..['rules']['actions'][3]['when']['section'] = 'nope'), 'unknown_section', 'rules.actions[3].when.section');
      expectError(check(bills()..['rules']['sections'][0]['row']['end'] = 'nope'), 'unknown_action', 'rules.sections[0].row.end');
      expectError(check(parcels()..['rules']['sections'][0]['row']['end'] = 'neighbour'), 'unknown_action', 'rules.sections[0].row.end', alone: false);
    });

    test('a tag rule\'s tagged names only the tags of the rules before it', () {
      expectError(check(bills()..['rules']['tags'][0]['when'] = {'tagged': ['paid']}), 'unknown_tag', 'rules.tags[0].when.tagged[0]');
      expectError(check(bills()..['rules']['tags'][0]['when'] = {'untagged': ['bill']}), 'unknown_tag', 'rules.tags[0].when.untagged[0]');
      expect(check(bills()..['rules']['tags'][1]['when'] = {'untagged': ['bill']}).ok, isTrue);
    });

    test('section_condition, from_with_incoming, bad_link_when', () {
      expectError(check(bills()..['rules']['sections'][0]['takes']['section'] = 'main'), 'section_condition', 'rules.sections[0].takes.section');
      expectError(check(bills()..['rules']['tags'][0]['when'] = {'section': 'bills'}), 'section_condition', 'rules.tags[0].when.section');
      expectError(check(bills()..['rules']['tags'][0]['when'] = {'from': ['72975']}), 'from_with_incoming', 'rules.tags[0].when.from');
      expectError(check(bills()..['rules']['sections'][1]['takes']['from'] = ['72975']), 'from_with_incoming', 'rules.sections[1].takes.from');
      final noIncoming = parcels()
        ..['permissions'] = ['sort', 'copy', 'write', 'move', 'links']
        ..['rules'].remove('incoming');
      expect(check(noIncoming).ok, isTrue);
      expectError(check(jsonDecode(jsonEncode(noIncoming))..['rules']['actions'][2]['when']['from'] = ['72975']), 'bad_link_when', 'rules.actions[2].when.from');
      // A pack with a link picks no texts by sender anywhere: a tag given by sender, a tab that takes by sender or that
      // tab's row would offer its link for those numbers alone just the same (review, 2026-11-20).
      expectError(check(jsonDecode(jsonEncode(noIncoming))..['rules']['tags'][0]['when'] = {'from': ['72975', '+1 (555) 010-0100']}), 'bad_link_when', 'rules.tags[0].when.from');
      expectError(check(jsonDecode(jsonEncode(noIncoming))..['rules']['sections'][0]['takes'] = {'from': ['72975']}), 'bad_link_when', 'rules.sections[0].takes.from');
      final noLink = jsonDecode(jsonEncode(noIncoming))
        ..['permissions'] = ['sort', 'copy', 'write', 'move']
        ..['links'] = []
        ..['rules']['actions'].removeAt(2);
      expect(check(noLink).ok, isTrue);
      expect(check(jsonDecode(jsonEncode(noLink))..['rules']['tags'][0]['when'] = {'from': ['72975', '+1 (555) 010-0100']}).ok, isTrue, reason: 'from is fine without incoming rules or a link');
      expect(check(jsonDecode(jsonEncode(noLink))..['rules']['sections'][0]['takes'] = {'tagged': ['parcel'], 'from': ['72975']}).ok, isTrue);
    });

    test('thousands of problems give the first hundred, the last saying how many more; nothing past a list\'s cap is looked at', () {
      // A package of 256 KiB held some 65,000 problems, every one listed and drawn on the review screen (review,
      // 2026-11-20).
      final flood = bills();
      flood['rules']['tags'][0] = {...flood['rules']['tags'][0] as Map, for (var i = 0; i < 4000; i++) 'k$i': 1};
      final parse = check(flood);
      expect(parse.pack, isNull);
      expect(parse.issues, hasLength(packIssuesMost));
      expect(parse.issues.take(packIssuesMost - 1).every((i) => i.code == 'unknown_field'), isTrue);
      expect([parse.issues.last.code, parse.issues.last.message], ['too_many_issues', 'And 3901 more problems like these: fix the ones above and check it again.']);
      final long = bills();
      long['rules']['tags'][0]['any'] = List.filled(65000, 'a');
      final errors = check(long).errors.toList();
      expect(errors.where((e) => e.code == 'too_many').single.path, 'rules.tags[0].any');
      expect(errors.where((e) => e.code == 'phrase_too_short'), hasLength(PackLimits.any), reason: 'only as many as a rule may have are read');
      expect(errors, hasLength(PackLimits.any + 1));
    });

    test('a from entry with nothing to compare holds for no one, never for everyone', () {
      // "(-)" is three characters a pack may hold and no number or name at all. Dropped, it left the condition with no
      // senders, which then held for every one (review, 2026-11-20).
      final json = bills()
        ..['permissions'] = ['sort', 'copy']
        ..['settings'] = [(bills()['settings'] as List)[1]]
        ..['rules'].remove('incoming');
      json['rules']['sections'][0]['takes'] = {'tagged': ['bill'], 'from': ['(-)']};
      final parse = check(json);
      expect(parse.errors, isEmpty);
      final takes = parse.pack!.rules.sections[0].takes;
      expect(takes.from, ['']);
      final plugin = PackPlugin(parse.pack!, source: PluginSource.dev, now: () => DateTime(2026));
      final registry = PluginRegistry([plugin]);
      final store = MemoryStore({'plugin_xbills': 'on'});
      for (final sender in ['+15550100100', '72975', '']) {
        final facts = MessageFacts(thread: 1, senders: [sender], text: packSamples.first.text, contact: false, outgoing: false);
        final tags = registry.classify(facts, store);
        expect(tags.has('xbills.bill'), isTrue, reason: 'it is still tagged');
        expect(registry.sectionOf(facts, tags, store), isNull, reason: 'its tab takes no one\'s: "$sender"');
      }
      // Alone in a condition it is still a condition: a tab that takes by it, or a rule given by it, is no mistake.
      final alone = jsonDecode(jsonEncode(json));
      alone['rules']['sections'][0]['takes'] = {'from': ['+ -']};
      expect(check(alone).errors, isEmpty);
    });

    test('needs_permission and permission_unused', () {
      expectError(check(bills()..['permissions'] = ['sort', 'markread']), 'needs_permission', 'permissions');
      expectError(check(bills()..['permissions'] = ['sort', 'copy', 'markread', 'write']), 'permission_unused', 'permissions[3]');
      expectError(check(parcels()..['permissions'] = ['sort', 'copy', 'write', 'move', 'links']), 'needs_permission', 'permissions');
      expectError(check(bills()..['permissions'] = ['copy', 'markread']), 'needs_permission', 'permissions');
    });

    test('incoming_needs_toggle, takes_nothing, tag_rule_no_trigger, leaves_main_on_filter, choice_default', () {
      expectError(check(bills()..['settings'][0]['default'] = true), 'incoming_needs_toggle', 'rules.incoming[0].setting');
      expectError(check(bills()..['rules']['incoming'][0]['setting'] = 'extra'), 'incoming_needs_toggle', 'rules.incoming[0].setting');
      expectError(check(bills()..['rules']['sections'][1]['takes'] = {'untagged': ['bill']}), 'takes_nothing', 'rules.sections[1].takes');
      final noTrigger = bills();
      (noTrigger['rules']['tags'] as List).add({'tag': 'bill', 'none': ['unsubscribe']});
      expectError(check(noTrigger), 'tag_rule_no_trigger', 'rules.tags[2]');
      final emptyAny = bills();
      (emptyAny['rules']['tags'] as List).add({'tag': 'bill', 'any': []});
      expectError(check(emptyAny), 'tag_rule_no_trigger', 'rules.tags[2]');
      expectError(check(bills()..['rules']['sections'][1]['leavesMain'] = false), 'leaves_main_on_filter', 'rules.sections[1].leavesMain');
      expectError(check(parcels()..['settings'][0]['default'] = 'medium'), 'choice_default', 'settings[0].default');
    });

    test('atLeast: 1 to 5, and no more than its phrases unless the person adds words', () {
      expectError(check(bills()..['rules']['tags'][1]['atLeast'] = 0), 'too_few', 'rules.tags[1].atLeast');
      expectError(check(bills()..['rules']['tags'][1]['atLeast'] = 6), 'too_many', 'rules.tags[1].atLeast');
      expectError(check(bills()..['rules']['tags'][1]['atLeast'] = 5), 'too_many', 'rules.tags[1].atLeast');
      expect(check(bills()..['rules']['tags'][1]['atLeast'] = 4).ok, isTrue);
      expect(check(bills()..['rules']['tags'][0]['atLeast'] = 5).ok, isTrue, reason: 'wordsFrom can bring more');
    });

    test('header_full and slot_full', () {
      expectError(check(parcels()..['rules']['actions'][1]['slots'] = ['conversation.message.menu', 'conversation.header']), 'header_full', 'rules.actions[1].slots[1]');
      final full = bills();
      for (var i = 0; i < 3; i++) {
        (full['rules']['actions'] as List).add({'id': 'say$i', 'label': 'Say $i', 'icon': 'info', 'slots': ['list.conversation.menu'], 'do': 'say', 'text': 'Hello'});
      }
      expectError(check(full), 'slot_full', 'rules.actions[3].slots[0]');
    });

    test('bad_template: a face name with a placeholder, one in a label, a say and a write, and a bad {…}', () {
      final face = parcels();
      face['rules']['sections'][0]['row']['face']['name'] = '{tag:track}';
      expectError(check(face), 'bad_template', 'rules.sections[0].row.face.name');
      expectError(check(bills()..['rules']['actions'][0]['label'] = 'Copy {tag:bill}'), 'bad_template', 'rules.actions[0].label');
      expectError(check(bills()..['rules']['actions'][0]['say'] = 'Copied {tag:bill}'), 'bad_template', 'rules.actions[0].say');
      expectError(check(parcels()..['rules']['actions'][1]['text'] = 'Leave it at {tag:track}'), 'bad_template', 'rules.actions[1].text');
      expectError(check(bills()..['rules']['sections'][0]['row']['value'] = '{bill}'), 'bad_template', 'rules.sections[0].row.value');
      expectError(check(bills()..['rules']['sections'][0]['row']['caption'] = 'A bill }'), 'bad_template', 'rules.sections[0].row.caption');
      expectError(check(bills()..['rules']['sections'][0]['label'] = 'Bills {tag:bill}'), 'bad_template', 'rules.sections[0].label');
      expect(check(bills()..['rules']['sections'][0]['row']['caption'] = 'A {{bill}}: {tag:bill}').ok, isTrue);
    });

    test('bad_color', () {
      expectError(check(parcels()..['rules']['sections'][0]['row']['face']['color'] = '#4F46E'), 'bad_color', 'rules.sections[0].row.face.color');
      expectError(check(parcels()..['rules']['sections'][0]['row']['face']['color'] = 'indigo'), 'bad_color', 'rules.sections[0].row.face.color');
      final face = parcels();
      face['rules']['sections'][0]['row']['face']['domain'] = 'example.com';
      expectError(check(face), 'unknown_field', 'rules.sections[0].row.face.domain');
    });

    test('empty_pack', () {
      expectError(check(bills()
        ..['permissions'] = []
        ..['settings'] = []
        ..['rules'] = {}), 'empty_pack', 'rules');
    });

    test('every phrase_* code at its phrase\'s own path', () {
      const cases = {
        'bill{digits:4}': 'phrase_token_touches_word',
        '{digits:4}{digits:4}': 'phrase_tokens_touch',
        '{words:1-2} bill': 'phrase_words_edge',
        '{foo}': 'phrase_bad_token',
        'a': 'phrase_too_short',
        ' bill': 'phrase_bad_text',
        'your\u202Ebill': 'phrase_bad_text',
        '{url}.': 'phrase_url_followed',
        'a {digits} b {digits} c {digits} d {digits} e {digits}': 'phrase_too_many_tokens',
      };
      for (final e in cases.entries) {
        expectError(check(bills()..['rules']['tags'][1]['any'][2] = e.key), e.value, 'rules.tags[1].any[2]');
      }
      expectError(check(bills()..['rules']['tags'][1]['none'] = ['b']), 'phrase_too_short', 'rules.tags[1].none[0]');
      expectError(check(bills()..['rules']['tags'][1]['all'] = [5]), 'wrong_type', 'rules.tags[1].all[0]');
    });

    test('the counts: 201 phrases, 9 anchorless', () {
      final many = bills();
      final tags = many['rules']['tags'] as List;
      // Bills has 10; these make 201.
      for (var r = 0, n = 0; n < 191; r++) {
        final count = (191 - n).clamp(0, 30);
        tags.add({'tag': 'paid', 'any': [for (var i = 0; i < count; i++) 'thank you payment number ${n + i}']});
        n += count;
      }
      expectError(check(many), 'too_many_phrases', 'rules.tags');
      (tags.last['any'] as List).removeLast();
      expect(check(many).ok, isTrue, reason: '200 is the most');
      final anchorless = bills();
      (anchorless['rules']['tags'] as List).add({'tag': 'paid', 'any': ['{phone}', '{date}', '{time}', '{email}', '{url}', '{number}', '{amount}', '{digits}', '{word}']});
      expectError(check(anchorless), 'too_many_anchorless', 'rules.tags');
      ((anchorless['rules']['tags'] as List).last['any'] as List).removeLast();
      expect(check(anchorless).ok, isTrue, reason: '8 is the most');
    });

    test('the number of tag rules, sections, actions, incoming rules and settings', () {
      final rules = bills();
      rules['rules']['tags'] = [for (var i = 0; i < 33; i++) {'tag': 'bill', 'any': ['your bill is ready']}];
      expectError(check(rules), 'too_many', 'rules.tags', alone: false);
      final settings = bills();
      settings['settings'] = [...settings['settings'] as List, for (var i = 0; i < 23; i++) {'type': 'note', 'label': 'Note $i'}];
      expectError(check(settings), 'too_many', 'settings');
    });

    test('a pack\'s settings as the format gives them', () {
      final pack = check(parcels()).pack!;
      final level = pack.settings.first;
      expect(level.type, 'choice');
      expect(level.options.map((o) => o.value), ['strict', 'loose']);
      expect(level.options.last.hint, 'Catches more, and now and then a text that isn\'t about a parcel.');
      expect(level.choice, 'strict');
      final quiet = pack.settings.last;
      expect([quiet.type, quiet.key, quiet.fallback, quiet.icon], ['toggle', 'quiet', false, 'bell']);
    });
  });

  group('PackIssue', () {
    test('its JSON, and the relay\'s back', () {
      const i = PackIssue('bad_hue', 'hue', 'hue: "teal" isn\'t a colour here.');
      expect(i.toJson(), {'code': 'bad_hue', 'path': 'hue', 'message': 'hue: "teal" isn\'t a colour here.', 'severity': 'error'});
      final back = PackIssue.fromJson(i.toJson());
      expect([back.code, back.path, back.message, back.isError], ['bad_hue', 'hue', i.message, true]);
      expect(PackIssue.fromJson(const {'code': 'opens_links', 'severity': 'warning'}).isError, isFalse);
      expect(PackIssue.fromJson(const {}).code, 'invalid');
    });
  });

  group('lints', () {
    test('broad_phrase, description_link and unused_tag, each a warning', () {
      final broad = bills()..['rules']['tags'][1]['any'][0] = 'paid';
      expect(check(broad).warnings.map((w) => '${w.code} ${w.path}'), ['broad_phrase rules.tags[1].any[0]']);
      expect(check(bills()..['rules']['tags'][1]['any'][0] = 'thanks').warnings.single.code, 'broad_phrase');
      expect(check(bills()..['description'] = 'Bills. See www.example.com for more.').warnings.single.code, 'description_link');
      final unused = bills();
      (unused['rules']['tags'] as List).add({'tag': 'late', 'any': ['your payment is late']});
      final p = check(unused);
      expect(p.ok, isTrue);
      expect(p.warnings.map((w) => '${w.code} ${w.path}'), ['unused_tag rules.tags[2].tag']);
      expect(p.issues.every((i) => !i.isError), isTrue);
      expect(lintPack(p.pack!), hasLength(1));
    });
  });

  group('sign-in codes a pack never acts on', () {
    // Codes' finder (signInCode, Notifier.otp's rule to the letter) misses these, so a pack took them out of Messages,
    // marked them read and silenced them under words that said it never would (review, 2026-11-20).
    const missed = [
      'G-482913 is your Google verification code.',
      'FB-48291 is your Facebook confirmation code',
      'Your Steam Guard code: 4F8KQ',
      'Ваш код подтверждения: 482913',
      '【腾讯】验证码 482913，请勿泄露',
      'Dein Bestätigungscode lautet 482913',
    ];
    MessageFacts stranger(String text) => MessageFacts(thread: 1, senders: const ['22000'], text: text, contact: false, outgoing: false, unread: true);

    test('the texts Codes misses still keep a pack\'s hands off, as do 123-456, a code in words of no spaces and one past 400 characters', () {
      for (final text in [
        ...missed,
        'Your WhatsApp code: 482-913',
        '您的验证码是482913请勿泄露',
        'Hello from your bank. ${'We will never ask you for it. ' * 14}Your one-time passcode is 482913.',
      ]) {
        expect(packSees(stranger(text)), isTrue, reason: 'a pack may still tag it: $text');
        expect(packMayHoldCode(text), isTrue, reason: text);
        expect(packMayAct(stranger(text)), isFalse, reason: text);
      }
      expect(missed.every((t) => signInCode(t) == null), isTrue, reason: 'Codes\' own rule stays Notifier\'s');
    });

    test('the samples\' bills, receipts and parcels are still a pack\'s to act on', () {
      for (final s in packSamples.where((s) => s.id.compareTo('s12') < 0)) {
        expect(packMayHoldCode(s.text), isFalse, reason: s.text);
        expect(packMayAct(stranger(s.text)), isTrue, reason: s.text);
      }
      for (final text in ['Your code is 482913.', 'Use code SAVE20 at checkout']) {
        expect(packMayAct(stranger(text)), isFalse, reason: 'wider than it need be, which only leaves a text alone: $text');
      }
      expect(packMayHoldCode('Your PIN has been changed. If this wasn\'t you, call us.'), isFalse, reason: 'no code in it');
      expect(packMayHoldCode('Free shopping delivery on orders over 5000'), isFalse, reason: '"pin" in "shopping" isn\'t a word');
    });

    test('Try it: a pack that takes Google\'s texts and marks them read leaves "G-482913" alone', () {
      final google = bills();
      (google['rules']['tags'][1]['any'] as List).add('your google verification code');
      final pack = parsePackJson(google, appVersion: '0.10.1').pack!;
      final g = tryPack(pack, text: missed.first, from: '22000', switchesOn: true, store: MemoryStore({}));
      expect(g.seen, isTrue);
      expect(g.tags.keys, contains('paid'), reason: 'tagged, as a pack may tag a code');
      expect(g.section, isNull);
      expect(g.incoming, isEmpty);
      final control = tryPack(pack, text: 'Your google verification code was used. Thank you for your payment.', from: '22000', switchesOn: true, store: MemoryStore({}));
      expect(control.section, 'receipts');
      expect(control.incoming, ['markread']);
    });
  });
}
