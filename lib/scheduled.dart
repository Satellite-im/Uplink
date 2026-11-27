/// Messages written now and sent later (Matt, 2026-11-20: "Add support for scheduling messages by pressing and holding
/// or right clicking on the send button"). Pressed and held, or right-clicked, Send offers Schedule message; what is
/// written is kept here with when it goes, and sent then by the same way the conversation's Send would have taken.
///
/// Kept with the app's choices (AppState, so on a computer in its own folder), and sent by this app while it runs: a
/// message whose time came while Uplink was closed goes as soon as it opens again. Words only, no pictures.
///
/// Four kinds of conversation, by [ScheduledMessage.kind]:
/// - `text`: a text, or to a friend by the app's routes where one is up, as the conversation's Send does
///   ([ScheduledMessage.target] the addresses, comma separated);
/// - `group`: a group of friends (its id);
/// - `inbox`: a chat on a linked network, Telegram, Signal and the rest (`network:chatId`);
/// - `space`: a space's or a circle's chat (its seed).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'friends/friends.dart';
import 'friends/groups.dart';
import 'inbox/inbox.dart';
import 'sms.dart';
import 'standalone/chats.dart';
import 'voice/channels.dart';

/// One message waiting for its time. Kept as JSON under short keys ([toJson]).
@immutable
class ScheduledMessage {
  const ScheduledMessage({required this.id, required this.kind, required this.target, required this.text, required this.at, this.who = '', this.tries = 0, this.problem});

  final String id;
  final String kind;
  final String target;
  final String text;

  /// When it goes, in milliseconds since the epoch.
  final int at;

  /// Who or where it goes to, as the conversation was called when it was written: for the list in Settings.
  final String who;

  /// Times sending it failed; after [Scheduled.maxTries] it waits for Send now or Cancel.
  final int tries;

  /// Why the last try failed, in words.
  final String? problem;

  DateTime get when => DateTime.fromMillisecondsSinceEpoch(at);

  /// Which conversation: [kind] and [target] together.
  String get conversation => '$kind:$target';

  /// Failed as often as it is tried by itself: it is not sent again until the person says.
  bool get stuck => tries >= Scheduled.maxTries;

  ScheduledMessage copyWith({int? at, int? tries, String? problem}) =>
      ScheduledMessage(id: id, kind: kind, target: target, text: text, at: at ?? this.at, who: who, tries: tries ?? this.tries, problem: problem ?? this.problem);

  Map<String, Object?> toJson() => {'id': id, 'k': kind, 't': target, 'x': text, 'at': at, if (who.isNotEmpty) 'w': who, if (tries > 0) 'n': tries, if (problem != null) 'p': problem};

  static ScheduledMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], kind = j['k'], target = j['t'], text = j['x'], at = j['at'];
    if (id is! String || kind is! String || target is! String || text is! String || at is! int) return null;
    return ScheduledMessage(id: id, kind: kind, target: target, text: text, at: at, who: j['w'] as String? ?? '', tries: j['n'] as int? ?? 0, problem: j['p'] as String?);
  }
}

/// A conversation's key for scheduling: the kind and target a [ScheduledMessage] carries.
typedef ScheduleTarget = ({String kind, String target, String who});

/// The messages waiting, and the timer that sends each when its time comes. Tells its listeners on any change.
class Scheduled extends ChangeNotifier {
  Scheduled._();
  static final Scheduled instance = Scheduled._();

  /// The app's choice the list is kept under, and how many times a message is tried before it is left [stuck].
  static const storeKey = 'scheduled_messages';
  static const maxTries = 3;

  /// How a message is sent: true where it went. A test puts its own here.
  static Future<bool> Function(ScheduledMessage m) sender = sendScheduled;

  /// What time it is: a test puts its own clock here.
  static DateTime Function() now = DateTime.now;

  AppState? _app;
  Timer? _timer;
  bool _sending = false;

  /// How many were made in this run: put after the time in an id, so two made in the same instant differ.
  int _made = 0;
  List<ScheduledMessage> _all = [];

  /// Every message waiting, soonest first.
  List<ScheduledMessage> get all => List.unmodifiable(_all);

  /// Those waiting for one conversation, soonest first.
  List<ScheduledMessage> forConversation(String kind, String target) => [for (final m in _all) if (m.kind == kind && m.target == target) m];

  /// Read what was kept and look once a quarter of a minute for what is due (and now, for what came due while the app
  /// was closed).
  void start(AppState app) {
    _app = app;
    _all = _read(app.choice(storeKey, '[]'));
    notifyListeners();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => sendDue());
    unawaited(sendDue());
  }

  @visibleForTesting
  void reset() {
    _timer?.cancel();
    _timer = null;
    _app = null;
    _all = [];
    _sending = false;
  }

  static List<ScheduledMessage> _read(String raw) {
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [for (final j in list) ?ScheduledMessage.fromJson(j)]..sort((a, b) => a.at.compareTo(b.at));
    } catch (_) {
      return [];
    }
  }

  /// Sorts the list, writes it to the app's choices and tells the listeners: after every change.
  void _keep() {
    _all.sort((a, b) => a.at.compareTo(b.at));
    _app?.set(storeKey, jsonEncode([for (final m in _all) m.toJson()]));
    notifyListeners();
  }

  /// Keeps [text] for [to], to go at [at].
  ScheduledMessage add(ScheduleTarget to, String text, DateTime at) {
    final m = ScheduledMessage(id: '${DateTime.now().microsecondsSinceEpoch}-${_made++}', kind: to.kind, target: to.target, text: text, at: at.millisecondsSinceEpoch, who: to.who);
    _all.add(m);
    _keep();
    return m;
  }

  void cancel(String id) {
    _all.removeWhere((m) => m.id == id);
    _keep();
  }

  /// Sends one now, whatever its time; true where it went.
  Future<bool> sendNow(String id) async {
    final m = _all.where((m) => m.id == id).firstOrNull;
    if (m == null) return false;
    return _try(m.copyWith(tries: 0));
  }

  /// Sends whatever is due. One pass at a time.
  Future<void> sendDue() async {
    if (_sending) return;
    _sending = true;
    try {
      final at = now().millisecondsSinceEpoch;
      for (final m in [for (final m in _all) if (m.at <= at && !m.stuck) m]) {
        await _try(m);
      }
    } finally {
      _sending = false;
    }
  }

  /// Sends [m]: gone from the list where it went, else kept with one more try against it and why. One cancelled
  /// while it was being sent is left gone.
  Future<bool> _try(ScheduledMessage m) async {
    String? problem;
    var ok = false;
    try {
      ok = await sender(m);
      if (!ok) problem = 'Couldn\'t reach them just now.';
    } catch (e) {
      problem = '$e';
    }
    final i = _all.indexWhere((x) => x.id == m.id);
    if (i < 0) return ok;
    if (ok) {
      _all.removeAt(i);
    } else {
      _all[i] = m.copyWith(tries: m.tries + 1, problem: problem);
    }
    _keep();
    return ok;
  }
}

/// Sends [m] the way its conversation's Send does (lib/ui/thread.dart, inbox_ui.dart, hangout_screen.dart).
Future<bool> sendScheduled(ScheduledMessage m) async {
  switch (m.kind) {
    case 'text':
      final to = m.target.split(',').where((a) => a.isNotEmpty).toList();
      if (to.isEmpty) return false;
      // As thread.dart's Send: to a friend by the app's routes where one is up, else as a text.
      final own = !Sms.paired || (Sms.ownNetwork && to.length == 1 && UsernameChats.isUsername(to.first));
      final byRoute = to.length == 1 && own && await Friends.instance.sendText(to.first, m.text);
      if (!byRoute) await Sms.instance.send(to, m.text);
      return true;
    case 'group':
      return Groups.instance.sendText(m.target, m.text);
    case 'inbox':
      final cut = m.target.indexOf(':');
      if (cut < 0) return false;
      final network = Inbox.instance.named(m.target.substring(0, cut));
      if (network == null) return false;
      await network.send(m.target.substring(cut + 1), m.text);
      return true;
    case 'space':
      final channel = Voice.instance.channels.where((c) => c.seed == m.target).firstOrNull;
      final room = channel == null ? null : Voice.instance.hangoutFor(channel);
      return room != null && room.send(m.text);
    default:
      return false;
  }
}
