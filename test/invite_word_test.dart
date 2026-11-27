import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/circles/invite_word.dart';

/// A circle's invite word (lib/circles/invite_word.dart; Matt, 2026-11-19: "add the custom invite code word as a default
/// feature"). With WORD_FIXTURE=1 it also writes build/word-check/, which the site's /c/ page is checked against.
void main() {
  final link = 'https://gogho.st/join/#c.${'7' * 64}.${base64Url.encode(utf8.encode('Book Club')).replaceAll('=', '')}';

  test('a word is tidied, and refused where it can\'t be one or is kept', () {
    expect(tidyInviteWord('  Book Club! '), 'book-club');
    expect(tidyInviteWord('https://gogho.st/c/BookClub'), 'bookclub');
    expect(tidyInviteWord('--a__b--'), 'a-b');
    expect(tidyInviteWord('ab'), isNull);
    expect(tidyInviteWord('x' * 33), isNull);
    expect(inviteWordProblem('support'), contains('kept'));
    expect(inviteWordProblem('bookclub'), isNull);
    expect(inviteWordIn('Join us: https://gogho.st/c/bookclub tonight'), 'bookclub');
    expect(inviteWordIn('https://gogho.st/join/#c.abc'), isNull);
  });

  test('the link sealed under a word opens with that word alone, and the relay is told only a hash', () {
    final blob = sealInviteWord('bookclub', link);
    expect(openInviteWord('bookclub', blob), link);
    expect(openInviteWord('bookclubs', blob), isNull);
    expect(inviteWordHash('bookclub'), hasLength(64));
    expect(inviteWordHash('bookclub'), isNot(contains('bookclub')));
    expect(inviteWordHash('bookclub'), inviteWordHash('bookclub'));
    // Anything but a circle's link is not taken, sealed right or not.
    expect(openInviteWord('bookclub', sealInviteWord('bookclub', 'https://example.com/')), isNull);
    if (Platform.environment['WORD_FIXTURE'] == '1') {
      Directory('build/word-check/word').createSync(recursive: true);
      File('build/word-check/word/${inviteWordHash('bookclub')}').writeAsStringSync(jsonEncode({'b': blob}));
      File('build/word-check/expected.txt').writeAsStringSync(link);
    }
  });

  test('set, found and taken through the relay\'s words', () async {
    final held = <String, ({String owner, String b})>{};
    InviteWords as(String who) => InviteWords(ask: (what) async {
          final h = what['h'] as String;
          switch (what['dir']) {
            case 'word-set':
              if (held[h] != null && held[h]!.owner != who) throw StateError('taken');
              held[h] = (owner: who, b: what['b'] as String);
              return {'dir': 'word-set', 'ok': true};
            case 'word':
              return {'dir': 'word', 'b': held[h]?.b};
            default:
              held.remove(h);
              return {'dir': 'word-drop', 'ok': true};
          }
        });
    await as('maya').claim('bookclub', link);
    expect(await as('sam').resolve('bookclub'), link);
    expect(await as('sam').resolve('nobody-here'), isNull);
    await expectLater(as('sam').claim('bookclub', link), throwsStateError);
    expect(Circles.linkIn(link), link);
  });
}
