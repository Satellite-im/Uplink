import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/mentions.dart';

/// Mentions as words and numbers (lib/mentions.dart; Matt, 2026-11-19: "Add mentions support to spaces and circles
/// with the @user prefix"): what a message's mentions are believed for, the "@…" found at the cursor, who it finds,
/// and what editing the words does to the mentions already in them.
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _dev = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('what a message\'s mentions are believed for', () {
    test('a mention at an "@" inside the words is kept, in order', () {
      const text = 'hi @Maya Chen and @Dev';
      final kept = Mention.checked(const [Mention(18, 4, _dev), Mention(3, 10, _maya)], text);
      expect(kept, const [Mention(3, 10, _maya), Mention(18, 4, _dev)]);
      expect(text.substring(kept[0].start, kept[0].end), '@Maya Chen');
      expect(text.substring(kept[1].start, kept[1].end), '@Dev');
    });

    test('one that is not at an "@", runs past the end, is one letter, or names no id is left out', () {
      const text = 'hi @Maya and more';
      expect(Mention.checked(const [Mention(0, 2, _maya)], text), isEmpty, reason: 'not at an @: it would call someone the words do not show');
      expect(Mention.checked(const [Mention(3, 40, _maya)], text), isEmpty, reason: 'past the end');
      expect(Mention.checked(const [Mention(3, 1, _maya)], text), isEmpty, reason: 'the @ alone');
      expect(Mention.checked(const [Mention(3, 5, '')], text), isEmpty);
      expect(Mention.checked(const [Mention(3, 5, 'not an id')], text), isEmpty);
      expect(Mention.checked(const [Mention(-1, 5, _maya)], text), isEmpty);
      expect(Mention.checked(const [Mention(3, 5, _maya)], text), const [Mention(3, 5, _maya)]);
    });

    test('of two over each other the first stands, and a name is on one line with no space at its end', () {
      const text = '@Maya Chen\n@Dev ';
      expect(Mention.checked(const [Mention(0, 10, _maya), Mention(0, 5, _dev)], text), const [Mention(0, 5, _dev)], reason: 'the shorter of two at one place comes first');
      expect(Mention.checked(const [Mention(0, 5, _maya), Mention(4, 6, _dev)], text), const [Mention(0, 5, _maya)]);
      expect(Mention.checked(const [Mention(0, 15, _maya)], text), isEmpty, reason: 'over a new line');
      expect(Mention.checked(const [Mention(11, 5, _dev)], text), isEmpty, reason: 'ends in a space');
    });

    test('a mention may not end between the two halves of a character, and one after an emoji counts it as two', () {
      const text = '😀 @Zoë😀 hi';
      expect(text.indexOf('@'), 3, reason: 'the emoji is two code units');
      expect(Mention.checked(const [Mention(3, 4, _maya)], text), const [Mention(3, 4, _maya)]);
      expect(Mention.checked(const [Mention(3, 5, _maya)], text), isEmpty, reason: 'half of the emoji after the name');
      expect(Mention.checked(const [Mention(3, 6, _maya)], text), const [Mention(3, 6, _maya)]);
    });

    test('no more than a message may carry are kept, however many are sent', () {
      final text = [for (var i = 0; i < 60; i++) '@ab'].join(' ');
      final many = [for (var i = 0; i < 60; i++) Mention(i * 4, 3, _maya)];
      expect(Mention.checked(many, text), hasLength(Mention.most));
      expect(Mention.listFromJson([for (final m in many) m.toJson()], text), hasLength(Mention.most));
    });

    test('from the wire: three things each, and anything else passed over', () {
      const text = 'yo @Maya';
      expect(Mention.listFromJson([[3, 5, _maya]], text), const [Mention(3, 5, _maya)]);
      expect(Mention.listFromJson([[3, 5, _maya], 'x', [1], [3.5, 5, _maya], [3, '5', _maya], [3, 5, 7], null], text), const [Mention(3, 5, _maya)]);
      expect(Mention.listFromJson('nope', text), isEmpty);
      expect(Mention.listFromJson(null, text), isEmpty);
      expect(const Mention(3, 5, _maya).toJson(), [3, 5, _maya]);
    });

    test('written in the composer with space round the words, they are counted from the words as sent', () {
      const text = '  hey @Maya  ';
      expect(Mention.trimmed(const [Mention(6, 5, _maya)], text), const [Mention(4, 5, _maya)]);
      expect(text.trim().substring(4, 9), '@Maya');
      expect(Mention.trimmed(const [Mention(6, 5, _maya)], 'x' * 20), isEmpty, reason: 'no longer at an @');
    });

    test('whether someone is meant', () {
      expect(Mention.names(const [Mention(3, 5, _maya)], _maya), isTrue);
      expect(Mention.names(const [Mention(3, 5, _maya)], _dev), isFalse);
      expect(Mention.names(const [], _maya), isFalse);
    });
  });

  group('the "@…" at the cursor', () {
    MentionQuery? at(String words, {int? cursor, List<Mention> mentions = const []}) => MentionQuery.at(words, cursor ?? words.length, mentions: mentions);

    test('an "@" at the start of the words or of a word starts one, with what follows it', () {
      expect(at('@'), const MentionQuery(0, ''));
      expect(at('@ma'), const MentionQuery(0, 'ma'));
      expect(at('hello @ma'), const MentionQuery(6, 'ma'));
      expect(at('hello\n@ma'), const MentionQuery(6, 'ma'));
      expect(at('(@ma'), const MentionQuery(1, 'ma'));
      expect(at('😀@ma'), const MentionQuery(2, 'ma'), reason: 'an emoji is not a letter');
      expect(at('hello @ma', cursor: 8), const MentionQuery(6, 'm'), reason: 'only up to the cursor');
      expect(at('@ma')!.end, 3);
    });

    test('a name of two words is followed across its space', () {
      expect(at('@maya ch'), const MentionQuery(0, 'maya ch'));
      expect(at('hey @maya chen is'), const MentionQuery(4, 'maya chen is'), reason: 'ended by finding nobody, not here');
    });

    test('an address, a link, a bare "@ " and another line start none', () {
      expect(at('maya@example'), isNull);
      expect(at('https://x.com/@ma'), isNull);
      expect(at('a.@ma'), isNull);
      expect(at('@ ma'), isNull, reason: 'a space straight after the @');
      expect(at('@ma\nmore'), isNull, reason: 'the @ is on the line before');
      expect(at('no at here'), isNull);
      expect(at(''), isNull);
      expect(at('@ma', cursor: 0), isNull);
      expect(at('@ma', cursor: 9), isNull, reason: 'a cursor outside the words');
    });

    test('too far back is not followed', () {
      final far = '@${'a' * MentionQuery.longest}';
      expect(at(far), MentionQuery(0, 'a' * MentionQuery.longest));
      expect(at('${far}a'), isNull);
    });

    test('a mention already made is not asked for again, but a new "@" after it is', () {
      const made = [Mention(0, 10, _maya)];
      expect(at('@Maya Chen ', mentions: made), isNull);
      expect(at('@Maya Chen', cursor: 5, mentions: made), isNull, reason: 'the cursor inside it');
      expect(at('@Maya Chen @d', mentions: made), const MentionQuery(11, 'd'));
    });
  });

  group('who a query finds', () {
    const people = [
      MentionPerson(id: 'a', name: 'Maya Chen', username: 'mchen'),
      MentionPerson(id: 'b', name: 'Dev Patel', here: true),
      MentionPerson(id: 'c', name: 'Chen Li', last: 50),
      MentionPerson(id: 'd', name: 'Sam', here: true, last: 90),
      MentionPerson(id: 'e', name: 'Samantha', last: 10),
      MentionPerson(id: 'f', name: ''),
    ];
    List<String> ids(String q, {int most = 8}) => [for (final p in matchMentions(q, people, most: most)) p.id];

    test('nothing written finds everyone with a name: people here first, then whoever wrote last, then by name', () {
      expect(ids(''), ['d', 'b', 'c', 'e', 'a']);
    });

    test('a name that begins with it comes before a later word or a username that does, and those before one that only has it', () {
      expect(ids('ch'), ['c', 'a'], reason: 'Chen Li begins with it; Maya Chen has it as a later word');
      expect(ids('mc'), ['a'], reason: 'her username');
      expect(ids('sam'), ['d', 'e']);
      expect(ids('SAM'), ['d', 'e'], reason: 'capitals are not told apart');
      expect(ids('an'), ['e'], reason: 'two letters anywhere in a name: Samantha');
      expect(ids('a'), isEmpty, reason: 'one letter must begin a word');
      expect(ids('maya ch'), ['a']);
      expect(ids('maya chen '), isEmpty, reason: 'past the name: the list closes');
      expect(ids('zz'), isEmpty);
    });

    test('no more than asked for', () {
      expect(ids('', most: 2), ['d', 'b']);
    });

    test('a name as it is written into a message: one line, no space at its ends, not too long', () {
      expect(MentionPerson.written('  Maya \n Chen '), 'Maya Chen');
      expect(MentionPerson.written('a' * 200).length, Mention.longest - 1);
      final cut = MentionPerson.written('${'a' * (Mention.longest - 2)}😀😀');
      expect(cut, 'a' * (Mention.longest - 2), reason: 'not cut through an emoji');
      expect(MentionPerson.written(''), '');
    });
  });

  group('editing the words with mentions in them', () {
    // "hey @Maya Chen and @Dev!"
    const was = 'hey @Maya Chen and @Dev!';
    const maya = Mention(4, 10, _maya);
    const dev = Mention(19, 4, _dev);
    const both = [maya, dev];

    MentionEdit typed(String now, {required int from, int? to, required int cursor}) => MentionEdit.of(both, was: was, now: now, wasStart: from, wasEnd: to ?? from, nowCursor: cursor);

    test('written before them, they move along; after them, they stay', () {
      final before = typed('oh hey @Maya Chen and @Dev!', from: 0, cursor: 3);
      expect(before.mentions, const [Mention(7, 10, _maya), Mention(22, 4, _dev)]);
      expect(before.text, isNull);
      final after = typed('$was ok', from: was.length, cursor: was.length + 3);
      expect(after.mentions, both);
      final between = typed('hey @Maya Chen and so @Dev!', from: 18, cursor: 21);
      expect(between.mentions, const [maya, Mention(22, 4, _dev)]);
    });

    test('written straight after a mention or straight before it, it is still that mention', () {
      expect(typed('hey @Maya Chens and @Dev!', from: 14, cursor: 15).mentions, const [maya, Mention(20, 4, _dev)]);
      expect(typed('hey x@Maya Chen and @Dev!', from: 4, cursor: 5).mentions, const [Mention(5, 10, _maya), Mention(20, 4, _dev)]);
    });

    test('written inside a mention, it is a mention no longer and its letters stay', () {
      final e = typed('hey @Mayax Chen and @Dev!', from: 9, cursor: 10);
      expect(e.mentions, const [Mention(20, 4, _dev)]);
      expect(e.text, isNull);
    });

    test('the cursor says which of two edits that make the same words was made', () {
      // "@Anna" then "a" typed inside it (after "@Ann") or after it: both make "@Annaa".
      const one = [Mention(0, 5, _maya)];
      expect(MentionEdit.of(one, was: '@Anna', now: '@Annaa', wasStart: 5, wasEnd: 5, nowCursor: 6).mentions, one, reason: 'after it');
      expect(MentionEdit.of(one, was: '@Anna', now: '@Annaa', wasStart: 4, wasEnd: 4, nowCursor: 5).mentions, isEmpty, reason: 'inside it');
      expect(MentionEdit.of(one, was: '@Anna', now: '@Annaa').mentions, one, reason: 'with no cursor to go by, whatever the two have in common');
    });

    test('a backspace into a mention takes all of it', () {
      // The cursor after "@Maya Chen", one letter deleted.
      final e = typed('hey @Maya Che and @Dev!', from: 14, cursor: 13);
      expect(e.text, 'hey  and @Dev!');
      expect(e.cursor, 4);
      expect(e.mentions, const [Mention(9, 4, _dev)]);
    });

    test('a forward delete at its start takes all of it, and the space after a mention deleted leaves it be', () {
      final forward = typed('hey Maya Chen and @Dev!', from: 4, cursor: 4);
      expect(forward.text, 'hey  and @Dev!');
      expect(forward.cursor, 4);
      final space = typed('hey @Maya Chenand @Dev!', from: 15, cursor: 14);
      expect(space.text, isNull);
      expect(space.mentions, const [maya, Mention(18, 4, _dev)]);
    });

    test('a selection deleted that ends part way into a mention takes the rest of it too', () {
      // "ey @Ma" selected (1 to 7) and deleted.
      final e = typed('hya Chen and @Dev!', from: 1, to: 7, cursor: 1);
      expect(e.text, 'h and @Dev!');
      expect(e.cursor, 1);
      expect(e.mentions, const [Mention(6, 4, _dev)]);
    });

    test('a selection deleted or typed over that holds a whole mention just loses it', () {
      final gone = typed('hey and @Dev!', from: 4, to: 15, cursor: 4);
      expect(gone.text, isNull);
      expect(gone.mentions, const [Mention(8, 4, _dev)]);
      final over = typed('hey you and @Dev!', from: 4, to: 14, cursor: 7);
      expect(over.text, isNull);
      expect(over.mentions, const [Mention(12, 4, _dev)]);
    });

    test('typed over a selection that ends part way into a mention, the mention is plain words and nothing more is taken', () {
      final e = typed('hey Xya Chen and @Dev!', from: 4, to: 7, cursor: 5);
      expect(e.text, isNull);
      expect(e.mentions, const [Mention(17, 4, _dev)]);
    });

    test('all of it cleared, or replaced by other words, leaves none', () {
      expect(MentionEdit.of(both, was: was, now: '').mentions, isEmpty);
      expect(MentionEdit.of(both, was: was, now: 'something else entirely').mentions, isEmpty);
    });

    test('a word before them corrected by the keyboard moves them by what it changed', () {
      // "hey" made "heya" with the cursor left at the end of the words.
      final e = MentionEdit.of(both, was: was, now: 'heya @Maya Chen and @Dev!', wasStart: was.length, wasEnd: was.length, nowCursor: was.length + 1);
      expect(e.mentions, const [Mention(5, 10, _maya), Mention(20, 4, _dev)]);
    });

    test('nothing to do with no mentions, or no change', () {
      expect(MentionEdit.of(const [], was: 'a', now: 'b').mentions, isEmpty);
      expect(identical(MentionEdit.of(both, was: was, now: was).mentions, both), isTrue);
    });

    test('the stretch that changed, by the cursor where it explains it and by what is in common where not', () {
      expect(MentionEdit.region('abc', 'abXc', wasStart: 2, wasEnd: 2, nowCursor: 3), (start: 2, oldEnd: 2, newEnd: 3));
      expect(MentionEdit.region('abcdef', 'abcX', wasStart: 3, wasEnd: 6, nowCursor: 4), (start: 3, oldEnd: 6, newEnd: 4));
      expect(MentionEdit.region('abc', 'ab', wasStart: 3, wasEnd: 3, nowCursor: 2), (start: 2, oldEnd: 3, newEnd: 2));
      expect(MentionEdit.region('abc', 'bc', wasStart: 0, wasEnd: 0, nowCursor: 0), (start: 0, oldEnd: 1, newEnd: 0));
      expect(MentionEdit.region('teh cat', 'the cat', wasStart: 7, wasEnd: 7, nowCursor: 7), (start: 1, oldEnd: 3, newEnd: 3));
      expect(MentionEdit.region('abc', 'abc', wasStart: 1, wasEnd: 1, nowCursor: 2), (start: 3, oldEnd: 3, newEnd: 3));
      expect(MentionEdit.region('abc', 'xyz'), (start: 0, oldEnd: 3, newEnd: 3));
      expect(MentionEdit.region('aaa', 'aa'), (start: 2, oldEnd: 3, newEnd: 2));
      expect(MentionEdit.region('abc', 'abcd', wasStart: -1, wasEnd: -1, nowCursor: 4), (start: 3, oldEnd: 3, newEnd: 4));
    });
  });
}
