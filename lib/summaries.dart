import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'local_ai.dart';
import 'sms.dart';

/// Summaries of unread conversations, made by the phone's own model (Matt, 2026-11-14: "Use a local AI to summarize
/// unread message conversations like apple does"; android/.../Summaries.kt says which model, and that nothing leaves
/// the phone). A conversation with several unread texts in a row, or one long one, is summed up in a line, which the
/// list shows in place of its last words, marked as a summary; reading the conversation puts the words back.
///
/// Asked for as a row is drawn, one conversation at a time, the newest first, and kept against the conversation's
/// newest text: the same unread texts are summed up once, also across the app being closed (`summary_<thread>`), and
/// a new text makes a new summary. Off where the phone has no such model, on a computer, or where the person turned
/// it off (Settings › Messages › Summaries).
class Summaries extends ChangeNotifier {
  Summaries._();
  static final Summaries instance = Summaries._();

  /// Where the phone's model stands: "available", "downloading", "downloadable", "unavailable", or "unknown" until
  /// asked.
  String status = 'unknown';

  AppState? _app;

  /// Each conversation's summary and the time of the newest text it was made for (milliseconds); a null text is
  /// one tried and not worth making, so it is not tried again for the same texts.
  final Map<int, ({int at, String? text})> _made = {};

  /// The conversations waiting for a summary, and their ids, so none waits twice. One is made at a time.
  final Queue<Conversation> _queue = Queue();
  final Set<int> _queued = {};
  bool _working = false;

  /// The fewest unread texts in a row that are summed up, and the length of one text alone that is.
  static const fewest = 2;
  static const long = 180;

  /// The person's choice, on unless they turned it off.
  static bool chosen(AppState app) => app.flag('summaries', fallback: true);

  /// Asks the phone where its model stands, and asks for it where it can be had.
  Future<void> start(AppState app) async {
    _app = app;
    // The phone's model, or a Mac's or an iPhone's own (lib/local_ai.dart).
    status = await LocalAi.instance.status();
    if (status == 'downloadable' && chosen(app) && !Sms.remote) status = await Sms.instance.summaryPrepare();
    notifyListeners();
  }

  /// The summary of [c]'s unread texts as they stand, or null: none yet, none worth making, or none to be had.
  String? of(Conversation c) {
    final app = _app;
    if (app == null || !c.unread || !chosen(app)) return null;
    final at = c.date.millisecondsSinceEpoch;
    final made = _made[c.id] ?? _kept(app, c.id);
    return made != null && made.at == at ? made.text : null;
  }

  /// The summary kept across the app being closed (`summary_<thread>`: the time, a tab, the words), read into
  /// memory; null where none is kept.
  ({int at, String? text})? _kept(AppState app, int thread) {
    final raw = app.choice('summary_$thread', '');
    final tab = raw.indexOf('\t');
    if (tab <= 0) return null;
    final at = int.tryParse(raw.substring(0, tab));
    if (at == null) return null;
    final text = raw.substring(tab + 1);
    return _made[thread] = (at: at, text: text.isEmpty ? null : text);
  }

  /// [c] is on the screen: its summary is made, in turn, where it has none for its newest text.
  void want(Conversation c) {
    final app = _app;
    if (app == null || status != 'available' || !c.unread || !chosen(app)) return;
    final at = c.date.millisecondsSinceEpoch;
    final made = _made[c.id] ?? _kept(app, c.id);
    if (made != null && made.at == at) return;
    if (!_queued.add(c.id)) return;
    _queue.add(c);
    unawaited(_work());
  }

  /// Makes the summaries waiting, one after another, and keeps each; the list is told where one has words.
  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_queue.isNotEmpty) {
        final c = _queue.removeFirst();
        _queued.remove(c.id);
        final text = await _make(c);
        final at = c.date.millisecondsSinceEpoch;
        _made[c.id] = (at: at, text: text);
        _app?.set('summary_${c.id}', '$at\t${text ?? ''}');
        if (text != null) notifyListeners();
      }
    } finally {
      _working = false;
    }
  }

  /// Reads [c]'s newest thirty messages and has the phone's model sum up the unread run; null where there is too
  /// little, or it cannot be done.
  Future<String?> _make(Conversation c) async {
    final List<Message> recent;
    try {
      recent = await Sms.instance.messages(c.id, limit: 30);
    } catch (_) {
      return null;
    }
    final lines = conversationFor(recent, c.people);
    return lines == null ? null : LocalAi.instance.summarize(lines);
  }

  /// The unread run of [recent] (newest first, as the phone gives them: the texts since the person last wrote) as
  /// the model reads a conversation, oldest first, a line a text, `<name>: <words>`; null where there is too little
  /// to sum up (one short text), so the text itself is shown.
  static String? conversationFor(List<Message> recent, List<Person> people) {
    final run = <Message>[];
    for (final m in recent) {
      if (m.outgoing) break;
      if (m.body.trim().isNotEmpty) run.add(m);
    }
    if (run.isEmpty) return null;
    if (run.length < fewest && run.first.body.trim().length < long) return null;
    String name(String address) {
      for (final p in people) {
        if (p.address == address && (p.name ?? '').trim().isNotEmpty) return p.name!.trim();
      }
      return people.length == 1 && (people.first.name ?? '').trim().isNotEmpty ? people.first.name!.trim() : 'Them';
    }

    return [for (final m in run.reversed) '${name(m.address)}: ${m.body.replaceAll('\n', ' ').trim()}'].join('\n');
  }
}
