import 'package:flutter/foundation.dart';

import 'human_check.dart';
import 'inbox.dart';
import 'scams.dart';

/// One notification for a chat on another network.
@immutable
class InboxAlert {
  const InboxAlert({required this.key, required this.network, required this.title, required this.body, this.group = false, this.count = 1});

  /// `network:chat`: the notification's own name, and what a press on it opens (lib/main.dart).
  final String key;

  /// The network's name ("Signal"), shown under the chat's.
  final String network;
  final String title;
  final String body;
  final bool group;
  final int count;
}

/// Notifications for new Signal and Telegram messages, and the phone kept connected to them while Uplink is out of
/// sight (Matt, 2026-11-16, on "Ghost doesn't notify you about Signal messages yet": "Yes, build them").
///
/// Each signed-in network's list is watched: a chat whose unread count rises, whose newest message is not this
/// account's and is newer than the watching began, is notified, unless it is muted on the network, looks like spam
/// (scams.dart), is archived or deleted here ([InboxNetwork.shownChats]), or is open on the screen. A chat read to
/// nothing has its notification taken away. What was unread before Uplink started watching is never notified: the
/// chats a network loads as it starts, and the messages Signal holds for it while it was closed, are not news.
class InboxAlerts {
  InboxAlerts({required this.notify, required this.cancel, required this.keepAlive, required this.inFront, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final void Function(InboxAlert alert) notify;
  final void Function(String key) cancel;

  /// The names of the networks signed in, as they change: Android keeps Uplink running while there are any.
  final void Function(List<String> names) keepAlive;

  /// Whether Uplink is on the screen.
  final bool Function() inFront;
  final DateTime Function() _now;

  /// The chat on the screen (`network:chat`), set by its page (lib/ui/inbox_ui.dart): not notified while Uplink is in
  /// front.
  static String? showing;

  /// The app's own, once watching (lib/main.dart).
  static InboxAlerts? instance;

  /// Each network's chats' unread counts at the last look, by network id then chat id: a count that rose is news.
  final _unread = <String, Map<String, int>>{};

  /// When each network was first seen ready: nothing dated before that is notified.
  final _since = <String, DateTime>{};

  /// The names last given to [keepAlive], to tell it only of changes.
  List<String> _alive = const [];

  /// Begins watching every offered network of [inbox], looking at its list on each change.
  void watch(Inbox inbox) {
    for (final n in inbox.networks) {
      if (n.soon) continue;
      n.addListener(() => check(n, inbox));
      check(n, inbox);
    }
  }

  /// Looks at [n]'s list as it is now.
  @visibleForTesting
  void check(InboxNetwork n, Inbox inbox) {
    // A first message from someone new on a network the Human check guards is held before anything is told of it
    // (lib/inbox/human_check.dart; GMFB-23, Matt, Mac 0.12.6: "stay hidden from notificatoins"): held, it is not in
    // shownChats below, whichever of the two heard of the change first.
    HumanCheck.instance?.review(n);
    final alive = [for (final r in inbox.ready) r.name];
    if (!listEquals(alive, _alive)) {
      _alive = alive;
      keepAlive(alive);
    }
    if (n.state != InboxState.ready) {
      _unread.remove(n.id);
      _since.remove(n.id);
      return;
    }
    final since = _since[n.id] ??= _now();
    final before = _unread[n.id];
    final chats = n.shownChats;
    _unread[n.id] = {for (final c in chats) c.id: c.unread};
    // The first look only takes the counts down: what was unread already is not news.
    if (before == null) return;
    for (final c in chats) {
      final key = '${n.id}:${c.id}';
      final was = before[c.id] ?? 0;
      if (c.unread == 0) {
        if (was > 0) cancel(key);
        continue;
      }
      if (c.unread <= was || c.lastFromMe || c.muted || !c.date.isAfter(since)) continue;
      if (scamOf(c) != null) continue;
      if (showing == key && inFront()) continue;
      notify(InboxAlert(key: key, network: n.name, title: c.title, body: c.snippet, group: c.group, count: c.unread));
    }
  }

  /// [c] as it is now is not news: what it holds is not told when it next comes into the list. For a chat the person
  /// let in by hand from the Human check's held list, while looking at it.
  void seen(InboxNetwork n, InboxChat c) => _unread[n.id]?[c.id] = c.unread;
}
