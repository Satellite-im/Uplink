import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sms.dart';

/// The conversations the list shows, as they are read from wherever this device keeps them (the phone's own store, the
/// phone a computer is paired with, an account's own chats): [items], the newest first, and how the reading stands.
///
/// Matt, 2026-11-26: "Please go through and rework how we load chats into the sidebar and sort them to clean things
/// up right now they don't always show the last message". The reading was the list's own, among its drawing
/// (lib/ui/conversations.dart). Here it is one thing, with one rule: **a conversation's row is the newest reading of
/// it, and a reading never puts an older copy over a newer one**.
///
/// - [load] reads everything: the first lot at once (what fills the screen, and what heads it however old: the
///   pinned, the newest unread), then the rest a lot at a time behind it. What was shown before stays until it is read
///   again, and what the whole reading did not find has gone. A conversation read twice in one reading (a pinned one
///   comes with the first lot and again in its place) keeps the copy with the newer message: a phone's later lot used
///   to lay a conversation's last SMS over the newer RCS message the first lot had for it.
/// - [changed] is for a text that came or went: the newest lot is read again, and the conversation named is read by
///   itself where that lot did not bring it (one far down the list whose newest message was deleted, or was read on
///   another device), and taken out where it is gone.
/// - [refresh] reads one conversation's row again and nothing else: it was read here, or come back from.
/// - [patch], [patchAll] and [remove] change what is held at once, before the phone has answered: a row changes as
///   the finger lets go, not when the reading that follows comes back.
class ConversationFeed extends ChangeNotifier {
  ConversationFeed({this.archived = false, this.onRead});

  /// The archived conversations alone, which are few: asked for by name, all at once.
  final bool archived;

  /// Told of each lot as it is read, before it is shown: the plugins sort what is new (lib/plugins).
  final void Function(List<Conversation> lot)? onRead;

  /// The first lot: what fills the screen a few times over. And each lot after it.
  static const first = 40;
  static const lot = 250;

  /// How many conversations said to have changed are each read by themselves after the newest lot. More than that at
  /// once and everything is read again, which is one reading in place of many.
  static const mostAlone = 12;

  /// How long a run of changes is waited out before reading, and the longest a reading is put off by changes that
  /// keep coming (a phone taking in a hundred texts at once).
  static const settle = Duration(milliseconds: 250);
  static const settleMost = Duration(seconds: 1);

  /// The conversations held, the newest first; null until the first reading answers.
  List<Conversation>? get items => _items;
  List<Conversation>? _items;

  /// Why the last whole reading failed, in the phone's words; null when it did not.
  String? get error => _error;
  String? _error;

  /// A reading has been going for long enough to say so.
  bool get slow => _slow;
  bool _slow = false;

  /// Older conversations are still being read behind the ones held.
  bool get more => _more;
  bool _more = false;

  /// While [more]: the date every conversation newer than which is held. Older ones may be held too (the pinned, the
  /// newest unread, what was held before), with others still to come between them.
  DateTime? get floor => _more ? _floor : null;
  DateTime? _floor;

  /// How many whole readings have ended: after each, [items] is all there is.
  int get whole => _whole;
  int _whole = 0;

  bool _gone = false;
  int _reads = 0;
  bool _reading = false;
  Timer? _slowTimer;

  /// What to read once the changes have settled: the newest lot, and these conversations by themselves. [_soon] is
  /// put off by each change that comes; [_atMost] runs from the first of a run, and is not.
  bool _wantNewest = false;
  final Set<int> _wanted = {};
  Timer? _soon;
  Timer? _atMost;

  @override
  void dispose() {
    _gone = true;
    _slowTimer?.cancel();
    _unwait();
    super.dispose();
  }

  void _say() {
    if (!_gone) notifyListeners();
  }

  /// Whether [id] is among the conversations held.
  bool has(int id) => _items?.any((c) => c.id == id) ?? false;

  /// Reads the conversations, the newest first (Matt, 2026-11-13: "Users with a ton of messages stored on their phone
  /// are taking forever to load, see if we can load by most recent first so that things are faster").
  Future<void> load() async {
    final read = ++_reads;
    _reading = true;
    // Whatever was waiting to be read is read by this.
    _unwait();
    _wantNewest = false;
    _wanted.clear();
    // Said only once it has taken a moment: a quick reading would only flicker.
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(milliseconds: 350), () {
      if (_gone || read != _reads || _slow) return;
      _slow = true;
      _say();
    });
    void quiet() {
      _slowTimer?.cancel();
      _slow = false;
    }

    try {
      if (archived) {
        final page = await Sms.instance.conversationsPage(archived: true);
        if (_gone || read != _reads) return;
        onRead?.call(page.items);
        quiet();
        _items = page.items;
        _error = null;
        _more = false;
        _whole++;
        _say();
        return;
      }
      // This reading's own, by id: the copy of each with the newest message.
      final got = <int, Conversation>{};
      int? at = 0;
      while (at != null) {
        final page = await Sms.instance.conversationsPage(limit: at == 0 ? first : lot, offset: at, pinned: at == 0);
        if (_gone || read != _reads) return;
        final last = page.next == null;
        final fresh = _newerOf(got, page.items);
        onRead?.call(page.items);
        _items = mergeConversations(_items, fresh, only: last ? got.keys.toSet() : null);
        _error = null;
        _more = !last;
        _floor = last ? null : (page.floor ?? _oldest(page.items));
        if (last) _whole++;
        // The screen has its conversations: the rest arrive without a word.
        if (at == 0) quiet();
        _say();
        at = page.next;
      }
    } catch (e) {
      if (_gone || read != _reads) return;
      _items ??= const [];
      _error = '$e';
      _more = false;
      _say();
    } finally {
      if (read == _reads) {
        final was = _slow;
        quiet();
        _reading = false;
        if (was) _say();
        // A text came or went while everything was being read: the newest are read again now it has ended.
        if (!_gone && (_wantNewest || _wanted.isNotEmpty)) _later(Duration.zero);
      }
    }
  }

  /// The conversations of [lot] this reading has no newer copy of, each noted in [got] as the one it has now.
  static List<Conversation> _newerOf(Map<int, Conversation> got, List<Conversation> lot) {
    final out = <Conversation>[];
    for (final c in lot) {
      final had = got[c.id];
      if (had != null && had.date.isAfter(c.date)) continue;
      got[c.id] = c;
      out.add(c);
    }
    return out;
  }

  /// The oldest of a lot's own, for a phone that does not say where the lot ends: not a pinned one, which comes with
  /// the first lot however old it is.
  static DateTime? _oldest(List<Conversation> lot) {
    DateTime? oldest;
    for (final c in lot) {
      if (!c.pinned && (oldest == null || c.date.isBefore(oldest))) oldest = c.date;
    }
    return oldest;
  }

  /// A text came or went in [thread] (-1: in some conversation, which is not known): the newest lot is read again a
  /// moment from now, once for a run of them, and [thread] by itself where that lot does not bring it.
  void changed([int thread = -1]) {
    _wantNewest = true;
    if (thread != -1) _wanted.add(thread);
    _later(settle);
  }

  /// [thread]'s row is read again a moment from now, and nothing else: it was marked read here, or come back from.
  void refresh(int thread) {
    if (thread == -1) return changed();
    _wanted.add(thread);
    _later(const Duration(milliseconds: 60));
  }

  void _later(Duration wait) {
    if (_gone) return;
    _soon?.cancel();
    _soon = Timer(wait, _catchUp);
    // Changes that keep coming put the reading off for [settleMost] at the longest.
    _atMost ??= Timer(settleMost, _catchUp);
  }

  void _unwait() {
    _soon?.cancel();
    _atMost?.cancel();
    _soon = _atMost = null;
  }

  /// Reads what [changed] and [refresh] asked for. A whole reading under way is left to finish, and this follows it.
  Future<void> _catchUp() async {
    _unwait();
    if (_gone) return;
    if (_reading) return;
    // Nothing held yet, the archive (asked for all at once), or more changed than is worth reading one by one.
    if (archived || _items == null || _wanted.length > mostAlone) return load();
    final read = _reads;
    final newest = _wantNewest;
    final wanted = _wanted.toSet();
    _wantNewest = false;
    _wanted.clear();
    try {
      var next = _items!;
      if (newest) {
        final page = await Sms.instance.conversationsPage(limit: first, pinned: true);
        if (_gone || read != _reads) return;
        onRead?.call(page.items);
        // A list short enough to come in one lot came whole: what it has not is gone.
        final all = page.next == null;
        next = mergeConversations(next, page.items, only: all ? {for (final c in page.items) c.id} : null);
        if (all) {
          _more = false;
          _whole++;
        }
        wanted.removeAll([for (final c in page.items) c.id]);
        // Gone with a whole list that did not have them.
        if (all) wanted.clear();
      }
      for (final thread in wanted) {
        final c = await Sms.instance.conversation(thread);
        if (_gone || read != _reads) return;
        if (c == null) {
          next = [for (final x in next) if (x.id != thread) x];
        } else {
          onRead?.call([c]);
          next = mergeConversations(next, [c]);
        }
      }
      _items = next;
      _error = null;
      _say();
    } catch (_) {
      // The list shown stands; the next whole reading says what is wrong.
    }
  }

  /// What is held of conversation [id] is changed at once.
  void patch(int id, Conversation Function(Conversation) change) => patchAll({id}, change);

  /// What is held of each of [ids] is changed at once.
  void patchAll(Set<int> ids, Conversation Function(Conversation) change) {
    final held = _items;
    if (held == null || ids.isEmpty) return;
    _items = [for (final c in held) ids.contains(c.id) ? change(c) : c];
    _say();
  }

  /// [ids] are gone from what is held, at once.
  void remove(Iterable<int> ids) {
    final held = _items;
    final gone = ids.toSet();
    if (held == null || gone.isEmpty) return;
    _items = [for (final c in held) if (!gone.contains(c.id)) c];
    _say();
  }
}
