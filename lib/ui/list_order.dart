/// The order of the list of conversations (lib/ui/conversations.dart), whatever each row is: a conversation of texts,
/// another network's chat, a space.
///
/// **One order, made in one place.** Pinned ones first. Then, among the pinned and among the rest alike, what is
/// brought up before what is not, and the newest message first throughout (Matt, 2026-11-24: "sort unread messages at
/// the top in the app, new messages should come first (before unreads)"). A row is brought up while something in it is
/// unread and it is not muted.
///
/// **Reading a conversation does not move it** (Matt, 2026-11-26: "clicking a message to read it shoots it down the
/// list if it's old which is un desirable"). An old unread conversation stands near the top; read, it used to fall to
/// where its date puts it, far down, as it was pressed: the row under the finger went, and every row under it moved up
/// one. Now a row that was up and has been read is held where it is ([ListHold]) for as long as the list is being
/// looked at. Nothing moves but for a message that comes or goes, which takes its conversation to the top as it does
/// everywhere. The list is put straight when it is looked away from: the app or its window left, another tab or a
/// search opened, the list pulled down to read it again. So it never moves under a hand, and it is tidy on coming back.
library;

/// One row as the order sees it.
class ListEntry {
  const ListEntry({required this.row, required this.key, required this.at, this.unread = false, this.pinned = false});

  /// What is drawn: a conversation, another network's chat, a space.
  final Object row;

  /// The row's own name, the same for as long as it is in the list: `t:<thread>` for a conversation of texts,
  /// `n:<network>:<id>` for another network's chat, `s:<room>` for a space.
  final String key;

  /// When its newest message was written.
  final DateTime at;

  /// Something in it is unread and it is not muted: what brings a row up.
  final bool unread;
  final bool pinned;

  static String textKey(int thread) => 't:$thread';
  static String chatKey(String network, String id) => 'n:$network:$id';
  static String spaceKey(String room) => 's:$room';
}

/// [entries] in the order the list shows them: the pinned first, and in each part what is brought up (unread, or
/// [held] there) before the rest, the newest first throughout. Two written at the same moment stand by their keys, so
/// the same rows are in the same order however they arrived.
List<ListEntry> arranged(Iterable<ListEntry> entries, {Set<String> held = const {}}) {
  int part(ListEntry e) => (e.pinned ? 0 : 2) + (e.unread || held.contains(e.key) ? 0 : 1);
  return entries.toList()
    ..sort((a, b) {
      final byPart = part(a).compareTo(part(b));
      if (byPart != 0) return byPart;
      final byDate = b.at.compareTo(a.at);
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });
}

/// The rows held where they are though they have been read: each was up (unread) when the list last showed it, and is
/// read now. [follow] is asked as the list is drawn; [settle] lets them all go to where their dates put them.
class ListHold {
  final Set<String> _held = {};

  /// The rows that were up the last time the list was drawn.
  final Set<String> _up = {};

  /// Whether the list is being looked at. While it is not, nothing new is held: a conversation read on another device
  /// with this one put away goes straight to its place.
  bool watching = true;

  /// The rows held up now.
  Set<String> get held => _held;

  /// Notes [entries], the rows the list is about to show, and answers with the keys of those held up: every one that
  /// was up and is read now, until [settle]. One that is unread again is up by itself and is held no longer; one that
  /// is no longer in the list is forgotten.
  Set<String> follow(Iterable<ListEntry> entries) {
    final seen = <String>{};
    final up = <String>{};
    for (final e in entries) {
      seen.add(e.key);
      if (e.unread) {
        _held.remove(e.key);
        up.add(e.key);
      } else if (_held.contains(e.key) || (watching && _up.contains(e.key))) {
        _held.add(e.key);
        up.add(e.key);
      }
    }
    _held.removeWhere((k) => !seen.contains(k));
    _up
      ..clear()
      ..addAll(up);
    return _held;
  }

  /// The list was looked away from: every row goes to where its date puts it. True where any was held.
  bool settle() {
    final any = _held.isNotEmpty;
    _held.clear();
    _up.clear();
    return any;
  }
}
