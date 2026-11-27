import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/list_order.dart';

// The list's one order (lib/ui/list_order.dart). Matt, 2026-11-24: "also sort unread messages at the top in the app,
// new messages should come first (before unreads)"; and 2026-11-26: "clicking a message to read it shoots it down the
// list if it's old which is un desirable".
void main() {
  final noon = DateTime(2026, 11, 24, 12);
  Conversation text(int id, int minutesAgo, {bool unread = false, bool muted = false, bool pinned = false}) =>
      Conversation(id: id, date: noon.subtract(Duration(minutes: minutesAgo)), people: const [], snippet: 'text $id', unread: unread, error: false, archived: false, muted: muted, pinned: pinned);
  InboxChat chat(String id, int minutesAgo, {int unread = 0, bool muted = false}) =>
      InboxChat(network: 'telegram', id: id, title: id, date: noon.subtract(Duration(minutes: minutesAgo)), unread: unread, muted: muted);
  List<ListEntry> entries(List<Object> rows) => [for (final r in rows) listEntry(r, pinned: r is Conversation && r.pinned)];
  List<Object> ids(Iterable<ListEntry> rows) => [for (final e in rows) e.row is Conversation ? (e.row as Conversation).id : (e.row as InboxChat).id];
  List<Object> order(List<Object> rows, {Set<String> held = const {}}) => ids(arranged(entries(rows), held: held));

  test('unread conversations come first, the newest of them at the very top, and everything read after', () {
    final rows = <Object>[text(1, 1), text(2, 5, unread: true), chat('a', 9), chat('b', 20, unread: 3), text(3, 40), text(4, 90, unread: true)];
    expect(order(rows), [2, 'b', 4, 1, 'a', 3]);
    // A message that has just come is unread and the newest: it is first of all.
    expect(order([...rows, text(9, 0, unread: true)]).first, 9);
  });

  test('however the rows arrive, they stand in the same order', () {
    final rows = <Object>[text(1, 1), text(2, 5, unread: true), chat('a', 9), chat('b', 20, unread: 3), text(3, 40), text(4, 90, unread: true)];
    expect(order(rows.reversed.toList()), order(rows));
    // Two written in the same minute: by their own names, not by which came first.
    expect(order([text(7, 3), text(8, 3), chat('c', 3)]), order([chat('c', 3), text(8, 3), text(7, 3)]));
  });

  test('nothing unread, or everything unread, is the newest first', () {
    expect(order([chat('a', 9), text(3, 40), text(1, 1)]), [1, 'a', 3]);
    expect(order([text(3, 40, unread: true), text(1, 1, unread: true), chat('a', 9, unread: 1)]), [1, 'a', 3]);
    expect(arranged(const []), isEmpty);
  });

  test('a muted conversation is not brought up for what is said in it', () {
    expect(isUnreadRow(text(1, 1, unread: true)), isTrue);
    expect(isUnreadRow(text(1, 1, unread: true, muted: true)), isFalse);
    expect(isUnreadRow(chat('a', 1, unread: 2, muted: true)), isFalse);
    expect(order([text(1, 1), text(2, 5, unread: true, muted: true), text(3, 9, unread: true)]), [3, 1, 2]);
  });

  test('the pinned head the list, unread first among themselves as among the rest', () {
    final rows = <Object>[text(1, 1), text(2, 5, unread: true), text(3, 30, pinned: true), text(4, 600, pinned: true, unread: true)];
    expect(order(rows), [4, 3, 2, 1]);
  });

  group('a conversation that is read stays where it is while the list is looked at', () {
    // An old unread text stands at the top, over newer ones that are read.
    List<Object> rows({bool read = false, int minutesAgo = 9000}) => [text(1, 1), text(2, 5, unread: true), text(3, 40), text(4, minutesAgo, unread: !read)];

    test('read, it keeps its place; looked away from, it goes to where its date puts it', () {
      final hold = ListHold();
      var e = entries(rows());
      expect(ids(arranged(e, held: hold.follow(e))), [2, 4, 1, 3]);
      // Pressed and read: nothing moves.
      e = entries(rows(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [2, 4, 1, 3]);
      expect(hold.held, {'t:4'});
      // Drawn again and again (a summary arriving, a call starting): still nothing.
      e = entries(rows(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [2, 4, 1, 3]);
      // The window left: it is put straight.
      expect(hold.settle(), isTrue);
      e = entries(rows(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [2, 1, 3, 4]);
      expect(hold.settle(), isFalse, reason: 'nothing held, nothing to draw again');
    });

    test('a message that comes or goes takes its conversation to the top, held or not', () {
      final hold = ListHold();
      var e = entries(rows());
      hold.follow(e);
      e = entries(rows(read: true));
      hold.follow(e);
      // Answered: its newest message is this minute's, and it is still among the ones up, now first of them.
      e = entries(rows(read: true, minutesAgo: 0));
      expect(ids(arranged(e, held: hold.follow(e))), [4, 2, 1, 3]);
      // Something new comes in it: unread again, up by itself, and held no longer.
      e = entries(rows(minutesAgo: 0));
      expect(ids(arranged(e, held: hold.follow(e))), [4, 2, 1, 3]);
      expect(hold.held, isEmpty);
    });

    test('read with the app put away (on another device), it goes straight to its place', () {
      final hold = ListHold();
      var e = entries(rows());
      hold.follow(e);
      hold.watching = false;
      e = entries(rows(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [2, 1, 3, 4]);
      // Looked at again: nothing is brought back up.
      hold.watching = true;
      e = entries(rows(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [2, 1, 3, 4]);
    });

    test('every one marked read at once stays, and one that leaves the list is forgotten', () {
      final hold = ListHold();
      var e = entries(rows());
      hold.follow(e);
      e = entries([text(1, 1), text(2, 5), text(3, 40), text(4, 9000)]);
      expect(ids(arranged(e, held: hold.follow(e))), [2, 4, 1, 3]);
      expect(hold.held, {'t:2', 't:4'});
      // Archived: not in the list, not held; back in it (unarchived), it is where its date puts it.
      e = entries([text(1, 1), text(2, 5), text(3, 40)]);
      hold.follow(e);
      expect(hold.held, {'t:2'});
      e = entries([text(1, 1), text(2, 5), text(3, 40), text(4, 9000)]);
      expect(ids(arranged(e, held: hold.follow(e))), [2, 1, 3, 4]);
    });

    test('another network\'s chat and a pinned conversation are held as a text is', () {
      final hold = ListHold();
      List<Object> made({required bool read}) => [text(1, 1), chat('b', 500, unread: read ? 0 : 2), text(5, 20, pinned: true), text(6, 900, pinned: true, unread: !read)];
      var e = entries(made(read: false));
      expect(ids(arranged(e, held: hold.follow(e))), [6, 5, 'b', 1]);
      e = entries(made(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [6, 5, 'b', 1]);
      hold.settle();
      e = entries(made(read: true));
      expect(ids(arranged(e, held: hold.follow(e))), [5, 6, 1, 'b']);
    });
  });
}
