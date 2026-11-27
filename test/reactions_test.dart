import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/reactions.dart';
import 'package:ghost_messaging/sms.dart';

Message _m(int id, String body, {bool out = false, String from = '+15550001111', int minute = 0, bool picture = false}) => Message(
      id: id,
      kind: picture ? 'mms' : 'sms',
      address: out ? '' : from,
      body: body,
      date: DateTime(2026, 11, 13, 12, minute),
      outgoing: out,
      state: out ? 'sent' : 'received',
      attachments: picture ? const [Attachment(id: 1, type: 'image/jpeg')] : const [],
    );

void main() {
  group('parseReaction', () {
    test('Google Messages', () {
      final r = parseReaction('❤️ to "See you at 7"')!;
      expect(r.emoji, '❤️');
      expect(r.quote, 'See you at 7');
      expect(parseReaction('👍🏽 to “ok”')!.emoji, '👍🏽');
      expect(parseReaction('Reacted 😂 to “lol what”')!.emoji, '😂');
      final gone = parseReaction('Removed ❤️ from “See you at 7”')!;
      expect(gone.removed, isTrue);
      expect(gone.emoji, '❤️');
    });

    test('iPhone', () {
      expect(parseReaction('Loved “See you at 7”')!.emoji, '❤️');
      expect(parseReaction('Liked "ok"')!.emoji, '👍');
      expect(parseReaction('Disliked “no”')!.emoji, '👎');
      expect(parseReaction('Laughed at “lol”')!.emoji, '😂');
      expect(parseReaction('Emphasized “now”')!.emoji, '‼️');
      expect(parseReaction('Questioned “why”')!.emoji, '❓');
      expect(parseReaction('Reacted 🎉 to “we did it”')!.emoji, '🎉');
      final picture = parseReaction('Loved an image')!;
      expect(picture.media, isTrue);
      final off = parseReaction('Removed a heart from “See you at 7”')!;
      expect(off.removed, isTrue);
      expect(off.emoji, '❤️');
    });

    test('ordinary messages are not reactions', () {
      expect(parseReaction('Loved it'), isNull);
      expect(parseReaction('I loved "Dune"'), isNull);
      expect(parseReaction('Going to "the park"'), isNull);
      expect(parseReaction('5 to "go"'), isNull);
      expect(parseReaction('Liked "a" and "b"\nmore'), isNull);
      expect(parseReaction(''), isNull);
    });
  });

  test('quoteMatches: exact, quotes and spacing, and a quote cut short', () {
    expect(quoteMatches("Don’t forget", "Don't forget"), isTrue);
    expect(quoteMatches('See  you at 7', 'see you at 7'), isTrue);
    expect(quoteMatches('This is a long message that the phone…', 'This is a long message that the phone cut short because it was long'), isTrue);
    expect(quoteMatches('Hello', 'Hello there'), isFalse);
  });

  // Google Messages quotes a message without its emoji (Matt, 2026-11-15: "Reactions are not being properly parsed on
  // the RCS version").
  test('quoteMatches: a quote without the emoji the message has', () {
    expect(quoteMatches('Lmao i knew we had two!', 'Lmao i knew we had two! 😂'), isTrue);
    expect(quoteMatches('On my way', '🚗 On my way 💨'), isTrue);
    expect(quoteMatches('Lmao', 'Lmao i knew we had two! 😂'), isFalse);
    expect(quoteMatches('😂', '😂😂'), isFalse, reason: 'emoji alone are not matched with the emoji left out');
  });

  test('foldReactions: the RCS reaction from the screenshot hangs on its message', () {
    final f = foldReactions([
      _m(3, '😂 to “Lmao i knew we had two!”', minute: 3),
      _m(2, 'Lmao i knew we had two! 😂', out: true, minute: 2),
    ]);
    expect(f.messages.map((m) => m.body), ['Lmao i knew we had two! 😂']);
    expect(f.reactions.values.single.single.emoji, '😂');
  });

  group('foldReactions', () {
    test('a reaction hangs on its message and its bubble goes', () {
      final msgs = [
        _m(3, '❤️ to “See you at 7”', minute: 3),
        _m(2, 'See you at 7', out: true, minute: 2),
        _m(1, 'Dinner?', minute: 1),
      ];
      final f = foldReactions(msgs);
      expect(f.messages.map((m) => m.id), [2, 1]);
      expect(f.reactions['sms:2']!.single.emoji, '❤️');
      expect(f.reactions['sms:2']!.single.by, '+15550001111');
    });

    test('the newest match wins, and a removal takes it off', () {
      final msgs = [
        _m(5, 'Removed ❤️ from “ok”', minute: 5),
        _m(4, 'Loved “ok”', minute: 4),
        _m(3, 'ok', out: true, minute: 3),
        _m(2, 'ok', out: true, minute: 2),
      ];
      final f = foldReactions(msgs);
      expect(f.messages.map((m) => m.id), [3, 2]);
      expect(f.reactions, isEmpty);
    });

    test('several people, and your own reactions', () {
      final msgs = [
        _m(4, 'Laughed at “lol”', out: true, minute: 4),
        _m(3, '😂 to "lol"', from: '+15550002222', minute: 3),
        _m(2, 'Liked “lol”', from: '+15550003333', minute: 2),
        _m(1, 'lol', minute: 1),
      ];
      final f = foldReactions(msgs);
      expect(f.messages.map((m) => m.id), [1]);
      expect(f.reactions['sms:1']!.map((r) => r.emoji), ['👍', '😂', '😂']);
      expect(f.reactions['sms:1']!.last.by, '');
    });

    test('a picture', () {
      final f = foldReactions([_m(2, 'Loved an image', minute: 2), _m(1, '', out: true, picture: true, minute: 1)]);
      expect(f.messages.length, 1);
      expect(f.reactions['mms:1']!.single.emoji, '❤️');
    });

    test('a reaction that names no message stays a bubble', () {
      final f = foldReactions([_m(2, '❤️ to “something from last year”', minute: 2), _m(1, 'hi', minute: 1)]);
      expect(f.messages.length, 2);
      expect(f.reactions, isEmpty);
    });
  });

  test('reactionSnippet', () {
    expect(reactionSnippet('Loved “See you at 7”'), 'Reacted ❤️ to “See you at 7”');
    expect(reactionSnippet('hello'), isNull);
  });

  // Matt, 2026-11-17: "When people react to a message we sent we see double reactions".
  test('a reaction Google Messages keeps on a message and its reaction text are one reaction, not two', () {
    final mine = Message(id: 1, kind: 'rcs', address: '', body: 'Damn we were going to have a party', date: DateTime(2026, 11, 17, 10, 8), outgoing: true, state: 'delivered', reactions: const ['😂']);
    final text = _m(2, 'Laughed at “Damn we were going to have a party”', minute: 9);
    final f = foldReactions([text, mine]);
    expect(f.messages.single.body, 'Damn we were going to have a party', reason: 'the words alone, no emoji in them');
    expect(f.reactions[mine.key]!.map((r) => r.emoji), ['😂']);
    // Kept on the message alone, with no reaction text: still shown once, by no one in particular.
    final alone = foldReactions([mine]);
    expect(alone.reactions[mine.key]!.single.by, '?');
    expect(Message.from({'id': 3, 'kind': 'rcs', 'body': 'hi', 'date': 0, 'outgoing': true, 'reactions': ['❤️', '👍']}).reactions, ['❤️', '👍']);
  });
}
