import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';

/// The list of conversations is read the newest first, a lot at a time (Matt, 2026-11-13: "Users with a ton of
/// messages stored on their phone are taking forever to load, see if we can load by most recent first"): what each
/// lot does to the ones already held.
Conversation _c(int id, int date, {String snippet = ''}) => Conversation.from({'id': id, 'date': date, 'people': const [], 'snippet': snippet});

void main() {
  test('a later lot goes after the newest, in order of date', () {
    final first = mergeConversations(null, [_c(1, 900), _c(2, 800)]);
    final all = mergeConversations(first, [_c(3, 700), _c(4, 600)]);
    expect(all.map((c) => c.id), [1, 2, 3, 4]);
  });

  test('a conversation read again replaces the one held, and moves to where its date puts it', () {
    final held = [_c(1, 900), _c(2, 800), _c(3, 700)];
    // A text arrives in the oldest: it comes back in the newest lot, with its new words.
    final all = mergeConversations(held, [_c(3, 950, snippet: 'new'), _c(1, 900)]);
    expect(all.map((c) => c.id), [3, 1, 2]);
    expect(all.first.snippet, 'new');
    expect(all, hasLength(3));
  });

  test('a pinned one handed over with the first lot and again in its own place is held once', () {
    final first = mergeConversations(null, [_c(1, 900), _c(9, 100)]);
    final all = mergeConversations(first, [_c(2, 800), _c(9, 100)]);
    expect(all.map((c) => c.id), [1, 2, 9]);
  });

  test('what a whole read did not find has gone, and nothing goes before the read is whole', () {
    final held = [_c(1, 900), _c(2, 800), _c(3, 700)];
    // Part way: the second is not in this lot, and stays.
    expect(mergeConversations(held, [_c(1, 900)]).map((c) => c.id), [1, 2, 3]);
    // The read is whole and never met the second: it was deleted.
    expect(mergeConversations(held, [_c(3, 700)], only: {1, 3}).map((c) => c.id), [1, 3]);
  });

  test('two of one date keep one order', () {
    final a = mergeConversations(null, [_c(1, 500), _c(2, 500)]);
    final b = mergeConversations(null, [_c(2, 500), _c(1, 500)]);
    expect(a.map((c) => c.id), b.map((c) => c.id));
  });
}
