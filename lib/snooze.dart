/// Snoozing a conversation (GMFB-36, from the Uplink gap review: snoozed messages were in Uplink's backlog, #53): it
/// leaves Messages until the time chosen, then comes back at the top with a notification, and stays at the top until
/// it is opened.
///
/// Kept with the app's choices (AppState), by the conversation's key (`text:<thread>`, or `space:<room>` for a
/// space's chat in Messages), and looked at by this app while it runs: a snooze whose time came while Uplink was closed
/// ends as soon as it opens again. Where the device has no notification for it (a computer), the app says it itself
/// while it is open ([Snoozed.back]).
///
/// One message can be snoozed too, by its conversation's key and its own id ([Snoozed.message]): it comes back as a
/// notification and as a reminder pinned at the top of its conversation, which shows it, and its conversation comes to
/// the top of Messages as a snoozed one does. Kept beside the conversations', on this device alone.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_state.dart';

/// The conversations snoozed and those just back from a snooze; whoever listens is told as either changes.
class Snoozed extends ChangeNotifier {
  Snoozed._();
  static final Snoozed instance = Snoozed._();

  /// The name it is kept under with the app's choices.
  static const storeKey = 'snoozed';

  /// What time it is: a test puts its own clock here.
  static DateTime Function() now = DateTime.now;

  /// Says a snooze is over ([key], what it was called): a notification on the phone. A test puts its own here.
  static void Function(String key, String title) woke = (_, _) {};

  /// Says one message's snooze is over ([chat], the conversation's key, and the message's [id]; [title], what the
  /// conversation was called, and [words], the message's): a notification on the phone. A test puts its own here.
  static void Function(String chat, String id, String title, String words) wokeMessage = (_, _, _, _) {};

  /// Whether this device puts up a notification as a snooze ends; where it doesn't, [back] says it.
  static bool notifies = false;

  /// Says a snooze is over inside the app, where the device puts up no notification of it: [title] is what the
  /// conversation was called. Messages sets it while it is on the screen (lib/ui/conversations.dart) and says so in
  /// a toast; null while there is nowhere to say it.
  static void Function(String title)? back;

  AppState? _app;
  Timer? _timer;

  /// Each snoozed conversation's key: until when (ms), and what it was called when snoozed.
  Map<String, ({int until, String title})> _until = {};

  /// Those back from a snooze and not yet opened: at the top of Messages.
  Set<String> _woken = {};

  /// Each snoozed message's key ([message]): until when (ms), what its conversation was called, and its words.
  Map<String, ({int until, String title, String words})> _messages = {};

  /// The messages back from a snooze, pinned at the top of their conversation until shown or put away: when each came
  /// back (ms), what its conversation was called, and its words.
  Map<String, ({int until, String title, String words})> _reminders = {};

  /// A message to show as its conversation opens (a notification of its snooze was pressed): its key.
  String? _show;

  /// Reads what was kept, ends the snoozes whose time has come, and looks again every half minute.
  void start(AppState app) {
    _app = app;
    _read(app.choice(storeKey, '{}'));
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => wakeDue());
    wakeDue();
  }

  /// For a test: as it was before [start].
  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _app = null;
    _until = {};
    _woken = {};
    _messages = {};
    _reminders = {};
    _show = null;
  }

  /// What was kept: `{"u": {key: {"at": ms, "t": title}}, "w": [keys back and not yet opened], "m": {message key: {"at":
  /// ms, "t": title, "x": words}}, "r": {message key back: the same}}`.
  void _read(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return;
      final u = j['u'], w = j['w'];
      Map<String, ({int until, String title, String words})> messages(Object? m) => {
            if (m is Map)
              for (final e in m.entries)
                if (e.key is String && e.value is Map && (e.value as Map)['at'] is int)
                  e.key as String: (until: (e.value as Map)['at'] as int, title: '${(e.value as Map)['t'] ?? ''}', words: '${(e.value as Map)['x'] ?? ''}'),
          };
      _messages = messages(j['m']);
      _reminders = messages(j['r']);
      _until = {
        if (u is Map)
          for (final e in u.entries)
            if (e.key is String && e.value is Map && (e.value as Map)['at'] is int) e.key as String: (until: (e.value as Map)['at'] as int, title: '${(e.value as Map)['t'] ?? ''}'),
      };
      _woken = {if (w is List) for (final k in w) if (k is String) k};
    } catch (_) {}
  }

  /// Keeps both, and tells whoever listens.
  void _save() {
    _app?.set(storeKey, jsonEncode({
      'u': {for (final e in _until.entries) e.key: {'at': e.value.until, 't': e.value.title}},
      'w': [..._woken],
      if (_messages.isNotEmpty) 'm': {for (final e in _messages.entries) e.key: {'at': e.value.until, 't': e.value.title, 'x': e.value.words}},
      if (_reminders.isNotEmpty) 'r': {for (final e in _reminders.entries) e.key: {'at': e.value.until, 't': e.value.title, 'x': e.value.words}},
    }));
    notifyListeners();
  }

  /// The key of a conversation of texts or with a friend, by its thread.
  static String text(int thread) => 'text:$thread';

  /// The key of a space's chat in Messages, by its room.
  static String space(String room) => 'space:$room';

  /// The key of one message, [id], in the conversation kept under [chat] ([text] or [space]).
  static String message(String chat, String id) => '$chat#$id';

  /// The conversation's key in a message's [key], or [key] itself where it is a conversation's.
  static String chatOf(String key) {
    final at = key.indexOf('#');
    return at < 0 ? key : key.substring(0, at);
  }

  /// Whether [key] is out of Messages now.
  bool hides(String key) => _until.containsKey(key);

  /// Whether [key] is back from a snooze and not yet opened.
  bool woken(String key) => _woken.contains(key);

  /// When [key]'s snooze ends, where it is snoozed.
  DateTime? until(String key) => _until[key] == null ? null : DateTime.fromMillisecondsSinceEpoch(_until[key]!.until);

  /// How many are snoozed now.
  int get count => _until.length;

  /// Puts [key] away until [when].
  void snooze(String key, DateTime when, {String title = ''}) {
    _until[key] = (until: when.millisecondsSinceEpoch, title: title);
    _woken.remove(key);
    _save();
  }

  /// Brings [key] back now, without a notification.
  void unsnooze(String key) {
    if (_until.remove(key) == null) return;
    _save();
  }

  /// [key] was opened: it goes back to its place by date.
  void opened(String key) {
    if (!_woken.remove(key)) return;
    _save();
  }

  /// When message [id] in [chat] comes back, where it is snoozed.
  DateTime? messageUntil(String chat, String id) {
    final m = _messages[message(chat, id)];
    return m == null ? null : DateTime.fromMillisecondsSinceEpoch(m.until);
  }

  /// Puts message [id] in [chat] away until [when]: [title] is what the conversation is called, [words] the message's.
  void snoozeMessage(String chat, String id, DateTime when, {String title = '', String words = ''}) {
    final key = message(chat, id);
    _messages[key] = (until: when.millisecondsSinceEpoch, title: title, words: words);
    _reminders.remove(key);
    _save();
  }

  /// Takes message [id] in [chat]'s snooze off, without a reminder.
  void unsnoozeMessage(String chat, String id) {
    if (_messages.remove(message(chat, id)) == null) return;
    _save();
  }

  /// The messages in [chat] back from a snooze and not yet shown or put away, the first back first.
  List<({String id, String words, DateTime at})> remindersIn(String chat) {
    final start = '$chat#';
    final list = [
      for (final e in _reminders.entries)
        if (e.key.startsWith(start)) (id: e.key.substring(start.length), words: e.value.words, at: DateTime.fromMillisecondsSinceEpoch(e.value.until)),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  /// Message [id] in [chat]'s reminder is put away (shown, or closed).
  void dismiss(String chat, String id) {
    if (_reminders.remove(message(chat, id)) == null) return;
    _save();
  }

  /// A notification of message [id]'s snooze in [chat] was pressed: it is shown as its conversation opens ([takeShow]).
  void showOnOpen(String chat, String id) => _show = message(chat, id);

  /// The message to show in [chat] as it opens, once: its id, or null.
  String? takeShow(String chat) {
    final s = _show;
    if (s == null || chatOf(s) != chat) return null;
    _show = null;
    return s.substring(chat.length + 1);
  }

  /// Ends every snooze whose time has come, each with its notification: a conversation's back at the top of Messages,
  /// a message's pinned at the top of its conversation, which comes to the top of Messages too.
  void wakeDue() {
    final at = now().millisecondsSinceEpoch;
    final due = [for (final e in _until.entries) if (e.value.until <= at) e];
    final dueMessages = [for (final e in _messages.entries) if (e.value.until <= at) e];
    if (due.isEmpty && dueMessages.isEmpty) return;
    for (final e in due) {
      _until.remove(e.key);
      _woken.add(e.key);
      woke(e.key, e.value.title);
    }
    for (final e in dueMessages) {
      _messages.remove(e.key);
      _reminders[e.key] = (until: at, title: e.value.title, words: e.value.words);
      final chat = chatOf(e.key);
      _woken.add(chat);
      wokeMessage(chat, e.key.substring(chat.length + 1), e.value.title, e.value.words);
    }
    _save();
  }

  /// The times offered, from [from]: in an hour, in three hours, this evening at six (while it is before five), tomorrow
  /// at nine, and next Monday at nine.
  static List<({String label, DateTime at})> choices(DateTime from) {
    final day = DateTime(from.year, from.month, from.day);
    final tomorrow = day.add(const Duration(days: 1));
    final monday = day.add(Duration(days: 8 - from.weekday));
    return [
      (label: 'For an hour', at: from.add(const Duration(hours: 1))),
      (label: 'For 3 hours', at: from.add(const Duration(hours: 3))),
      if (from.hour < 17) (label: 'Until this evening (6 PM)', at: day.add(const Duration(hours: 18))),
      (label: 'Until tomorrow (9 AM)', at: tomorrow.add(const Duration(hours: 9))),
      (label: 'Until next week (Monday, 9 AM)', at: monday.add(const Duration(hours: 9))),
    ];
  }
}
