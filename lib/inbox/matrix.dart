import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../app_state.dart';
import '../desktop/store.dart';
import '../sms.dart';
import 'inbox.dart';
import 'kept_writer.dart';

/// What the Matrix helper is to the app: lines out, lines in. A process in the app; a stand-in in a test.
abstract class MatrixLink {
  Stream<Map<String, Object?>> get heard;
  void say(Map<String, Object?> line);
  Future<void> close();
}

/// Matrix, signed in to the person's account as a device of its own, as Element is (Matt, 2026-11-17: "Let's add
/// support for matrix, microsoft teams and google chat"): the helper `matrix-sidecar` (sidecar/matrix, on mautrix-go,
/// MPL-2.0) runs as a child process and speaks sidecar/matrix/PROTOCOL.md.
///
/// Signing in is the browser (single sign-on: the helper gives the homeserver's address, the browser comes back to
/// this device on 127.0.0.1 with a login token: [signInWithBrowser]) or a password where the server takes one
/// ([signInWithPassword]). Most Matrix direct messages are end-to-end encrypted: the helper is a full encryption
/// device, and the person's recovery key ([unlock]) signs it with their cross-signing keys and brings the key backup
/// down, so older messages decrypt. Direct chats and group rooms both show; a group is a group chat here. The server
/// keeps history, so [load] brings what came before; what has been seen is kept in [_file] to show at once.
class Matrix extends InboxNetwork {
  Matrix({this.soon = false, this.link, this.folder});

  @override
  final bool soon;

  /// The helper, in a test. Null: the process, once [start] finds it.
  final Future<MatrixLink?> Function()? link;

  /// Where the helper's store and the chats kept here are. Null: this app's own folder.
  final String? folder;

  @override
  String get id => 'matrix';
  @override
  String get name => 'Matrix';

  MatrixLink? _link;
  StreamSubscription<Map<String, Object?>>? _sub;
  AppState? _app;
  InboxState _state = InboxState.unavailable;
  String? _error, _account, _me;
  bool _verified = false;

  /// Requests to the helper are numbered; each waits here, by its number, for the helper's answer ([_ask], [_heard]).
  int _asked = 0;
  final Map<int, Completer<Object?>> _waiting = {};

  /// The rooms as the helper last gave them (sidecar/matrix PROTOCOL.md's room), by id.
  final Map<String, Map<String, Object?>> _rooms = {};

  /// Each room's messages held here, oldest first, as the helper gave them, with 'state' and 'reactions' (reaction
  /// event id → {from, emoji}) kept beside.
  final Map<String, List<Map<String, Object?>>> _messages = {};

  /// Where older messages begin, for [load] with older (the helper's `end`); '' once there are none older.
  final Map<String, String> _end = {};

  /// Media by the number the screens know them by, and their files once brought down.
  final Map<int, Map<String, Object?>> _media = {};
  final Map<int, String> _files = {};

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut || _state == InboxState.signingIn ? InboxStep.credentials : InboxStep.none;
  @override
  String? get error => _error;
  @override
  String? get account => _account;

  /// This account's user id (@me:server), once signed in.
  String? get userId => _me;

  /// Whether the recovery key has signed this device ([unlock]).
  bool get verified => _verified;

  String get _dir => folder ?? (PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/matrix' : '${DeskStore.defaultDir().path}/matrix');
  File get _file => File('$_dir/chats.json');

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (soon) return;
    final link = await (this.link ?? _process)();
    if (link == null) {
      _state = InboxState.unavailable;
      _error = 'The Matrix helper isn\'t in this build.';
      notifyListeners();
      return;
    }
    _link = link;
    _read();
    _sub = link.heard.listen(_heard);
    _state = InboxState.signedOut;
    notifyListeners();
    try {
      final s = (await _ask('status') as Map?) ?? const {};
      if (s['logged_in'] == true) {
        _signedIn(s);
      } else if (s['resuming'] == true) {
        // Signed in before; the helper waits for the network to start. What was kept shows meanwhile.
        _me = s['user_id'] as String?;
        _account = _me;
        _state = InboxState.ready;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// The helper: beside the app on a computer (Contents/Helpers on a Mac), the phone's native libraries on Android.
  Future<MatrixLink?> _process() async {
    String? binary;
    if (PlatformInfo.isAndroid) {
      try {
        binary = await const MethodChannel('ghost_messaging/sms').invokeMethod<String>('helperPath', {'name': 'matrixsidecar'});
      } catch (_) {}
    } else if (PlatformInfo.isMacOS || PlatformInfo.isWindows) {
      final named = PlatformInfo.environment['GHOST_MATRIXSIDECAR'];
      final exe = File(PlatformInfo.resolvedExecutable).parent.path;
      for (final c in [
        ?named,
        if (PlatformInfo.isWindows) '$exe\\matrix-sidecar.exe' else '$exe/../Helpers/matrix-sidecar',
        '${Directory.current.path}/build/matrix-sidecar/${PlatformInfo.isWindows ? 'windows/matrix-sidecar.exe' : 'mac/matrix-sidecar'}',
      ]) {
        if (File(c).existsSync()) {
          binary = c;
          break;
        }
      }
    }
    if (binary == null || !File(binary).existsSync()) return null;
    await Directory(_dir).create(recursive: true);
    try {
      return _ProcessLink(await Process.start(binary, ['--dir', _dir]));
    } catch (_) {
      return null;
    }
  }

  // --- signing in ---------------------------------------------------------------------------------------------------

  /// The helper says who is signed in: ready, and the rooms asked for.
  void _signedIn(Map s) {
    _me = s['user_id'] as String?;
    final shown = '${s['name'] ?? ''}'.trim();
    _account = shown.isEmpty ? _me : '$shown ($_me)';
    _verified = s['verified'] == true;
    _state = InboxState.ready;
    _error = null;
    _save();
    notifyListeners();
    unawaited(_refreshRooms());
  }

  /// A sign-in that didn't work: signed out, with the helper's reason to show.
  void _failed(Object e) {
    _error = '$e'.replaceFirst('Bad state: ', '');
    _state = InboxState.signedOut;
    notifyListeners();
  }

  /// Signs in with a user name and password. [homeserver] is a server name, an address, or a user id; empty is
  /// matrix.org. Servers on Matrix Authentication Service (matrix.org among them) may take only the browser.
  Future<void> signInWithPassword(String homeserver, String user, String password) async {
    if (_link == null) return;
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final s = await _ask('login_password', {'homeserver': homeserver.trim(), 'user': user.trim(), 'password': password}) as Map?;
      _signedIn(s ?? const {});
    } catch (e) {
      _failed(e);
    }
  }

  HttpServer? _loopback;

  /// Signs in with the browser (Matrix's single sign-on, which matrix.org's Matrix Authentication Service keeps for
  /// apps like this one): a listener on 127.0.0.1 on a free port, the homeserver's sign-in opened by [open], and the
  /// login token the browser brings back to the listener. Waits up to ten minutes; [cancelBrowser] stops waiting.
  Future<void> signInWithBrowser(String homeserver, {required Future<bool> Function(String url) open}) async {
    if (_link == null) return;
    await cancelBrowser();
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (e) {
      _failed('This device wouldn\'t let Uplink listen for the browser: $e');
      return;
    }
    _loopback = server;
    final token = Completer<String?>();
    server.listen((req) async {
      final got = req.uri.queryParameters['loginToken'];
      req.response.headers.contentType = ContentType.html;
      req.response.write(got == null || got.isEmpty
          ? '<!doctype html><meta charset="utf-8"><title>Uplink</title><p style="font:16px system-ui;margin:3em">Waiting for Matrix to sign you in…</p>'
          : '<!doctype html><meta charset="utf-8"><title>Uplink</title><p style="font:16px system-ui;margin:3em">Signed in to Matrix. You can close this page and go back to Uplink.</p>');
      await req.response.close();
      if (got != null && got.isNotEmpty && !token.isCompleted) token.complete(got);
    }, onDone: () {
      if (!token.isCompleted) token.complete(null);
    });
    try {
      final r = await _ask('sso_url', {'homeserver': homeserver.trim(), 'redirect': 'http://127.0.0.1:${server.port}/'}) as Map?;
      final url = r?['url'] as String?;
      if (url == null) throw StateError('Matrix gave no sign-in page');
      await open(url);
      final got = await token.future.timeout(const Duration(minutes: 10), onTimeout: () => null);
      if (got == null) {
        if (_state == InboxState.signingIn) _failed('Signing in with the browser didn\'t finish. Try again.');
        return;
      }
      final s = await _ask('login_token', {'token': got}) as Map?;
      _signedIn(s ?? const {});
    } catch (e) {
      _failed(e);
    } finally {
      await server.close(force: true);
      if (identical(_loopback, server)) _loopback = null;
    }
  }

  /// Stops waiting for the browser.
  Future<void> cancelBrowser() async {
    final s = _loopback;
    _loopback = null;
    await s?.close(force: true);
  }

  /// Unlocks older messages with the person's recovery key (Element's Security Key): this device is signed with the
  /// account's cross-signing keys, so other devices trust it, and the key backup comes down, so messages from before
  /// it was signed in decrypt. The chats open are fetched again. Throws with the helper's reason.
  Future<void> unlock(String recoveryKey) async {
    final r = await _ask('verify_recovery_key', {'key': recoveryKey.trim()}) as Map?;
    _verified = r?['verified'] == true;
    notifyListeners();
    // Those that could not be read before are asked for again.
    for (final room in [for (final e in _messages.entries) if (e.value.any((m) => m['undecryptable'] == true)) e.key]) {
      unawaited(load(room));
    }
  }

  @override
  Future<void> signOut() async {
    await cancelBrowser();
    try {
      await _ask('logout');
    } catch (_) {}
    _rooms.clear();
    _messages.clear();
    _end.clear();
    _account = null;
    _me = null;
    _verified = false;
    _state = _link == null ? InboxState.unavailable : InboxState.signedOut;
    _save();
    notifyListeners();
  }

  // --- what the helper says ---------------------------------------------------------------------------------------

  /// One line from the helper: an answer to a numbered request (`id` with `ok`), or an event (`ev`) of its own.
  void _heard(Map<String, Object?> m) {
    final id = m['id'];
    if (id is num && m.containsKey('ok')) {
      final w = _waiting.remove(id.toInt());
      if (w == null) return;
      m['ok'] == true ? w.complete(m['result']) : w.completeError(StateError('${m['error'] ?? 'Matrix did not answer'}'));
      return;
    }
    switch (m['ev']) {
      case 'synced':
        unawaited(_refreshRooms());
      case 'room':
        _rooms['${m['id']}'] = Map<String, Object?>.from(m)..remove('ev');
        _save();
        notifyListeners();
      case 'room_gone':
        _rooms.remove('${m['room']}');
        _messages.remove('${m['room']}');
        _save();
        notifyListeners();
      case 'message':
        _message(Map<String, Object?>.from(m)..remove('ev'));
      case 'reaction':
        _reaction(m);
      case 'redacted':
        _redacted('${m['room']}', '${m['target']}');
      case 'receipt':
        final list = _messages['${m['room']}'];
        if (list == null) return;
        final at = list.indexWhere((x) => x['id'] == m['id']);
        if (at < 0) return;
        for (final x in list.take(at + 1)) {
          if (x['mine'] == true && x['state'] != 'sending' && x['state'] != 'failed') x['state'] = 'read';
        }
        _save();
        notifyListeners();
      case 'logged_out':
        _rooms.clear();
        _messages.clear();
        _end.clear();
        _account = null;
        _me = null;
        _verified = false;
        _state = InboxState.signedOut;
        _error = (m['error'] as String?) ?? 'Matrix signed this device out. Sign in again to carry on.';
        _save();
        notifyListeners();
    }
  }

  /// Asks the helper for the rooms as they are now; messages of rooms no longer there are let go.
  Future<void> _refreshRooms() async {
    try {
      final list = (await _ask('rooms')) as List? ?? const [];
      final fresh = <String, Map<String, Object?>>{for (final r in list) '${(r as Map)['id']}': r.cast<String, Object?>()};
      _rooms
        ..clear()
        ..addAll(fresh);
      _messages.removeWhere((k, _) => !_rooms.containsKey(k));
      _save();
      notifyListeners();
    } catch (_) {}
  }

  /// A message into its room's list: kept once by its event id; an edit changes the message it replaces; this account's
  /// own, echoed back by the sync before the send answered, takes the place of the one shown as sending.
  void _message(Map<String, Object?> m) {
    final room = '${m['room']}';
    final list = _messages.putIfAbsent(room, () => []);
    final replaces = m['replaces'] as String?;
    if (replaces != null) {
      final target = list.where((x) => x['id'] == replaces).firstOrNull;
      if (target != null && target['from'] == m['from']) {
        target['text'] = m['text'];
        target['edited'] = true;
        _save();
        notifyListeners();
      }
      return;
    }
    final known = list.indexWhere((x) => x['id'] == m['id']);
    if (known >= 0) {
      // A message that could not be read before, decrypted now: its words in its place.
      final was = list[known];
      list[known] = {...m, 'state': was['state'] ?? 'sent', 'reactions': was['reactions'] ?? const {}};
    } else {
      final echo = m['mine'] == true ? list.indexWhere((x) => x['state'] == 'sending' && x['text'] == m['text'] && '${x['id']}'.startsWith('local-')) : -1;
      if (echo >= 0) {
        list[echo] = {...m, 'state': 'sent', 'reactions': list[echo]['reactions'] ?? const {}};
      } else {
        list.add({...m, 'state': m['mine'] == true ? 'sent' : 'received'});
      }
    }
    _sort(list);
    final r = _rooms.putIfAbsent(room, () => {'id': room, 'title': 'Matrix', 'is_direct': false, 'unread': 0, 'ts': 0});
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    if (ts >= ((r['ts'] as num?)?.toInt() ?? 0)) {
      r['ts'] = ts;
      r['last'] = {'id': m['id'], 'from': m['from'], 'text': m['text'], 'ts': ts, 'mine': m['mine'], 'media': (m['media'] as List? ?? const []).isNotEmpty, 'undecryptable': m['undecryptable'] == true};
    }
    _save();
    notifyListeners();
  }

  /// Messages into order of time, oldest first.
  static void _sort(List<Map<String, Object?>> list) => list.sort((a, b) => ((a['ts'] as num?) ?? 0).compareTo((b['ts'] as num?) ?? 0));

  /// A reaction the helper heard: kept on its message under the reaction event's own id. Dropped where the message
  /// isn't held.
  void _reaction(Map m) {
    final msg = (_messages['${m['room']}'] ?? const <Map<String, Object?>>[]).where((x) => x['id'] == m['target']).firstOrNull;
    if (msg == null) return;
    final reactions = Map<String, Object?>.from(msg['reactions'] as Map? ?? const {});
    reactions['${m['id']}'] = {'from': '${m['from']}', 'emoji': '${m['emoji']}'};
    msg['reactions'] = reactions;
    _save();
    notifyListeners();
  }

  /// [target] taken away in [room]: a message, or a reaction on one.
  void _redacted(String room, String target) {
    final list = _messages[room];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((x) => x['id'] == target);
    if (list.length == before) {
      for (final x in list) {
        final r = x['reactions'] as Map?;
        if (r != null && r.containsKey(target)) x['reactions'] = Map<String, Object?>.from(r)..remove(target);
      }
    }
    _save();
    notifyListeners();
  }

  // --- the chats and their messages, as the screens have them -----------------------------------------------------

  /// Whether [chatId] is an invite not yet answered.
  bool isInvite(String chatId) => _rooms[chatId]?['invite'] == true;

  /// Accepts the invite [chatId] (a direct chat's kept as one, as Element keeps it).
  Future<void> acceptInvite(String chatId) async {
    await _ask('join', {'room': chatId});
    _rooms[chatId]?['invite'] = false;
    notifyListeners();
    unawaited(load(chatId));
  }

  /// Declines the invite [chatId].
  Future<void> declineInvite(String chatId) async {
    await _ask('leave', {'room': chatId});
    _rooms.remove(chatId);
    _save();
    notifyListeners();
  }

  @override
  List<InboxChat> get chats {
    final out = <InboxChat>[];
    for (final r in _rooms.values) {
      final last = r['last'] as Map?;
      final invite = r['invite'] == true;
      out.add(InboxChat(
        network: id,
        id: '${r['id']}',
        title: '${r['title'] ?? ''}'.trim().isEmpty ? 'Matrix room' : '${r['title']}',
        date: DateTime.fromMillisecondsSinceEpoch((r['ts'] as num?)?.toInt() ?? 0),
        snippet: invite ? (r['is_direct'] == true ? 'Wants to chat with you' : 'Invited you to this room') : _snippet(last),
        unread: invite ? 1 : (r['unread'] as num?)?.toInt() ?? 0,
        group: r['is_direct'] != true,
        avatar: r['avatar'] as String?,
        lastFromMe: last?['mine'] == true,
        stranger: invite,
      ));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// A room's newest message in a line, for the list.
  static String _snippet(Map? last) {
    if (last == null) return '';
    if (last['undecryptable'] == true) return 'Encrypted message';
    final text = '${last['text'] ?? ''}'.trim();
    if (text.isNotEmpty) return text;
    return last['media'] == true ? 'Attachment' : '';
  }

  /// What a message that can't be decrypted yet says.
  static const lockedText = 'This message is encrypted and this device has no key for it yet.';

  @override
  List<InboxMessage> messagesOf(String chatId) {
    final list = _messages[chatId] ?? const <Map<String, Object?>>[];
    final byId = {for (final m in list) '${m['id']}': m};
    return [
      for (final m in list)
        InboxMessage(
          id: '${m['id']}',
          text: m['undecryptable'] == true ? lockedText : '${m['text'] ?? ''}',
          date: DateTime.fromMillisecondsSinceEpoch((m['ts'] as num?)?.toInt() ?? 0),
          mine: m['mine'] == true,
          sender: m['mine'] == true ? '' : _nameOf(m),
          senderId: '${m['from'] ?? ''}',
          state: switch (m['state']) { 'sending' => 'sending', 'failed' => 'failed', _ => 'sent' },
          media: [for (final a in (m['media'] as List? ?? const [])) _mediaOf(a as Map, sticker: m['kind'] == 'm.sticker' || a['sticker'] == true)],
          reactions: matrixReactions(m['reactions'] as Map?, me: _me),
          replyTo: m['reply_to'] as String?,
          replyText: m['reply_to'] == null ? null : (byId[m['reply_to']]?['text'] as String?),
          replySender: m['reply_to'] == null || byId[m['reply_to']] == null ? null : (byId[m['reply_to']]!['mine'] == true ? 'You' : _nameOf(byId[m['reply_to']]!)),
        ),
    ];
  }

  /// A sender's name as the room has it, else their user id's name part.
  static String _nameOf(Map m) {
    final n = '${m['name'] ?? ''}'.trim();
    if (n.isNotEmpty) return n;
    final from = '${m['from'] ?? ''}';
    return from.startsWith('@') && from.contains(':') ? from.substring(1, from.indexOf(':')) : from;
  }

  InboxMedia _mediaOf(Map a, {bool sticker = false}) {
    final key = '${a['mxc'] ?? a['local'] ?? ''}'.hashCode & 0x3fffffff;
    _media[key] = a.cast<String, Object?>();
    final mime = '${a['mime'] ?? ''}';
    return InboxMedia(
      // An m.sticker event, or one of Uplink's sent from here: drawn on its own, with no bubble.
      kind: InboxMedia.kindOf(mime, sticker: sticker),
      fileId: key,
      path: _files[key],
      name: a['name'] as String?,
      size: (a['size'] as num?)?.toInt() ?? 0,
      width: (a['width'] as num?)?.toInt() ?? 0,
      height: (a['height'] as num?)?.toInt() ?? 0,
      duration: ((a['duration'] as num?)?.toInt() ?? 0) ~/ 1000,
    );
  }

  /// Brings [chatId]'s latest messages from the server, or, with [older], those before the ones held.
  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready || isInvite(chatId)) return;
    final from = older ? _end[chatId] : null;
    if (older && (from == null || from.isEmpty)) return;
    try {
      final r = (await _ask('messages', {'room': chatId, 'from': ?from, 'limit': 30}) as Map?) ?? const {};
      for (final m in (r['messages'] as List? ?? const []).reversed) {
        _message((m as Map).cast<String, Object?>());
      }
      for (final x in (r['reactions'] as List? ?? const [])) {
        _reaction(x as Map);
      }
      if (older || !_end.containsKey(chatId)) _end[chatId] = '${r['end'] ?? ''}';
      _save();
      notifyListeners();
    } catch (e) {
      _error = '$e';
      notifyListeners();
    }
  }

  @override
  set watching(String? chatId) {}

  @override
  Future<void> send(String chatId, String text) => _send(chatId, text, null);

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) => _send(chatId, text, messageId);

  /// Sends [text], as a reply to [replyTo] where given.
  Future<void> _send(String chatId, String text, String? replyTo) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    // Answering an invite accepts it.
    if (isInvite(chatId)) {
      try {
        await acceptInvite(chatId);
      } catch (e) {
        _error = '$e';
        notifyListeners();
        return;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = <String, Object?>{'id': 'local-$now', 'room': chatId, 'from': _me ?? '', 'mine': true, 'ts': now, 'text': text, 'media': const [], 'state': 'sending', 'reply_to': ?replyTo};
    _messages.putIfAbsent(chatId, () => []).add(local);
    notifyListeners();
    try {
      final r = (await _ask('send', {'room': chatId, 'text': text, 'reply_to': ?replyTo}) as Map?) ?? const {};
      final eventId = r['id'] as String?;
      final list = _messages[chatId] ?? [];
      // The sync may have brought it back already, as itself.
      if (eventId != null && list.any((x) => x['id'] == eventId && !identical(x, local))) {
        list.remove(local);
      } else {
        local['id'] = eventId ?? local['id'];
        local['state'] = 'sent';
      }
      _error = null;
    } catch (e) {
      local['state'] = 'failed';
      _error = '$e';
    }
    _save();
    notifyListeners();
  }

  @override
  Future<void> markRead(String chatId) async {
    final r = _rooms[chatId];
    if (r == null) return;
    final list = _messages[chatId] ?? const <Map<String, Object?>>[];
    final last = list.lastWhere((m) => !'${m['id']}'.startsWith('local-') && m['mine'] != true, orElse: () => const {});
    final lastId = (last['id'] as String?) ?? (r['last'] as Map?)?['id'] as String?;
    if (((r['unread'] as num?) ?? 0) == 0 && lastId == r['read_up_to']) return;
    r['unread'] = 0;
    r['read_up_to'] = lastId;
    _save();
    notifyListeners();
    try {
      await _ask('read', {'room': chatId, 'event': ?lastId});
    } catch (_) {}
  }

  @override
  bool get canReact => true;

  /// Puts [emoji] on a message, or takes this account's own [emoji] off it (Matrix takes a reaction off by deleting it).
  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (_state != InboxState.ready) throw StateError('Matrix isn\'t connected');
    final msg = (_messages[chatId] ?? const <Map<String, Object?>>[]).where((x) => x['id'] == messageId).firstOrNull;
    if (remove) {
      final reactions = (msg?['reactions'] as Map?) ?? const {};
      final mine = [for (final e in reactions.entries) if ((e.value as Map)['from'] == _me && (e.value as Map)['emoji'] == emoji) '${e.key}'];
      for (final r in mine) {
        await _ask('redact', {'room': chatId, 'event': r});
        _redacted(chatId, r);
      }
      return;
    }
    final r = (await _ask('react', {'room': chatId, 'event': messageId, 'emoji': emoji}) as Map?) ?? const {};
    _reaction({'room': chatId, 'id': r['id'] ?? 'local-${DateTime.now().millisecondsSinceEpoch}', 'target': messageId, 'from': _me ?? '', 'emoji': emoji});
  }

  /// Your own message can be deleted for everyone (a redaction); anyone else's only here.
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine && !message.id.startsWith('local-');

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    if (!forEveryone) return super.deleteMessage(chatId, messageId);
    try {
      await _ask('redact', {'room': chatId, 'event': messageId});
      _redacted(chatId, messageId);
    } catch (e) {
      _error = '$e';
      notifyListeners();
    }
  }

  @override
  bool get canSendFiles => true;

  @override
  Future<void> sendFiles(String chatId, List<String> paths, {String caption = '', bool voice = false, bool sticker = false}) async {
    if (_state != InboxState.ready) return;
    for (final (i, path) in paths.indexed) {
      final ext = path.split('.').last.toLowerCase();
      // A voice message changed by Voice changer is an MP3 (lib/voice/voice_changer.dart), and says so.
      final mime = ext == 'mp3'
          ? 'audio/mpeg'
          : voice || ext == 'm4a'
          ? 'audio/mp4'
          : const {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic', 'mp4': 'video/mp4', 'mov': 'video/quicktime', 'pdf': 'application/pdf'}[ext] ??
              'application/octet-stream';
      final name = path.split(PlatformInfo.pathSeparator).last;
      final text = i == paths.length - 1 ? caption : '';
      try {
        final r = (await _ask('send_media', {'room': chatId, 'path': path, 'mime': mime, 'name': name, 'text': text}) as Map?) ?? const {};
        final now = DateTime.now().millisecondsSinceEpoch;
        // A copy kept in Matrix's own folder for the bubble (the picked file is a copy Android may clear); the media's
        // address and key come back with it, to fetch it again should the copy go.
        final kept = await _keepSent(path, now, i, name);
        final media = {...(r['media'] as Map? ?? const {}).cast<String, Object?>(), 'local': kept, if (sticker) 'sticker': true};
        final eventId = '${r['id'] ?? 'local-$now-$i'}';
        final list = _messages.putIfAbsent(chatId, () => []);
        final echoed = list.where((x) => x['id'] == eventId).firstOrNull;
        if (echoed != null) {
          echoed['media'] = [media];
        } else {
          list.add({'id': eventId, 'room': chatId, 'from': _me ?? '', 'mine': true, 'ts': now, 'text': text, 'media': [media], 'state': 'sent'});
        }
        _files['${media['mxc'] ?? kept}'.hashCode & 0x3fffffff] = kept;
      } catch (e) {
        _error = '$e';
        break;
      }
    }
    _save();
    notifyListeners();
  }

  /// Copies a file being sent into this network's own folder, so its bubble still has it after the place it was
  /// picked from is gone; the copy's path, or [path] itself where it can't be copied.
  Future<String> _keepSent(String path, int ts, int i, String name) async {
    try {
      final ext = name.contains('.') ? '.${name.split('.').last}' : '';
      final kept = '$_dir/files/sent-$ts-$i$ext';
      await Directory('$_dir/files').create(recursive: true);
      await File(path).copy(kept);
      return kept;
    } catch (_) {
      return path;
    }
  }

  @override
  void wantFile(int fileId) => unawaited(fileOf(fileId));

  /// Files being brought down now, by id: asked for again while one is coming (a picture asks each time it is drawn),
  /// the one download is waited for, as lib/inbox/signal.dart and lib/inbox/account_helper.dart do. Two at once wrote
  /// one path through one `.part` file, and the second found it renamed away.
  final Map<int, Future<String?>> _fetching = {};

  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null && File(known).existsSync()) return known;
    // A block, not an arrow: remove's value is this very future, which whenComplete would wait for, forever.
    return _fetching[fileId] ??= _fetch(fileId).whenComplete(() {
      _fetching.remove(fileId);
    });
  }

  /// Brings the file [fileId] down through the helper; its path on this device, or null where it can't be had.
  Future<String?> _fetch(int fileId) async {
    final a = _media[fileId];
    if (a == null) return null;
    final local = a['local'] as String?;
    if (local != null && File(local).existsSync()) return _files[fileId] = local;
    final mxc = a['mxc'] as String?;
    if (mxc == null || mxc.isEmpty) return null;
    final name = '${a['name'] ?? ''}';
    final ext = name.contains('.') ? '.${name.split('.').last}' : '';
    final path = '$_dir/files/$fileId$ext';
    if (File(path).existsSync()) return _files[fileId] = path;
    try {
      await Directory('$_dir/files').create(recursive: true);
      await _ask('download', {'mxc': mxc, 'file': a['file'], 'path': path});
      _files[fileId] = path;
      notifyListeners();
      return path;
    } catch (e) {
      _error = '$e';
      return null;
    }
  }

  /// A group room's people, for its drawer. Matrix's own room settings (names, power levels) stay in Element; leaving
  /// is offered here.
  @override
  Future<GroupDetails?> groupDetails(String chatId) async {
    final r = _rooms[chatId];
    if (r == null || r['is_direct'] == true) return null;
    final names = <String, String>{};
    for (final m in _messages[chatId] ?? const <Map<String, Object?>>[]) {
      final n = '${m['name'] ?? ''}'.trim();
      if (n.isNotEmpty) names['${m['from']}'] = n;
    }
    return GroupDetails(
      title: '${r['title'] ?? 'Matrix room'}',
      photo: r['avatar'] as String?,
      people: [
        if (_me != null) GroupPerson(id: _me!, name: 'You', me: true),
        for (final u in (r['members'] as List? ?? const [])) GroupPerson(id: '$u', name: names['$u'] ?? _nameOf({'from': u})),
      ],
      supports: const {GroupFeature.leave},
    );
  }

  @override
  Future<GroupDetails?> changeGroup(String chatId, GroupChange change) async {
    if (!change.leave) throw UnsupportedError('Change this room in Element: Uplink can leave it');
    await _ask('leave', {'room': chatId});
    _rooms.remove(chatId);
    _messages.remove(chatId);
    _save();
    notifyListeners();
    return null;
  }

  /// Gone from here: leaving the room on Matrix is the group drawer's Leave.
  @override
  Future<void> deleteChat(String chatId) => super.deleteChat(chatId);

  // --- keeping ------------------------------------------------------------------------------------------------------

  /// At most this many messages a room are kept on this device; the server has the rest.
  static const kept = 200;

  /// What goes in the file: the account, the rooms, the newest [kept] messages of each, and where older ones begin.
  Map<String, Object?> _keptNow() => {
        'me': _me,
        'account': _account,
        'verified': _verified,
        'rooms': _rooms,
        'messages': {for (final e in _messages.entries) e.key: e.value.length > kept ? e.value.sublist(e.value.length - kept) : e.value},
        'end': _end,
      };

  /// Reads the file back, to show what was seen before the helper has said anything.
  void _read() {
    try {
      if (!_file.existsSync()) return;
      final all = jsonDecode(_file.readAsStringSync()) as Map;
      _me = all['me'] as String?;
      _account = all['account'] as String?;
      _verified = all['verified'] == true;
      (all['rooms'] as Map? ?? const {}).forEach((k, v) => _rooms['$k'] = (v as Map).cast<String, Object?>());
      (all['messages'] as Map? ?? const {}).forEach((k, v) => _messages['$k'] = [for (final m in v as List) (m as Map).cast<String, Object?>()]);
      (all['end'] as Map? ?? const {}).forEach((k, v) => _end['$k'] = '$v');
    } catch (_) {}
  }

  late final KeptWriter _writer = KeptWriter(file: () => _file, snapshot: _keptNow);
  void _save() => _writer.save();

  /// Writes what is kept now (a test's end, the app going).
  @visibleForTesting
  void flush() => _writer.flush();

  /// Asks the helper to do [op] and waits for its answer; fails with the helper's reason, or where it never answers.
  Future<Object?> _ask(String op, [Map<String, Object?> args = const {}]) {
    final link = _link;
    if (link == null) return Future.error(StateError('Matrix isn\'t running'));
    final id = ++_asked;
    final done = Completer<Object?>();
    _waiting[id] = done;
    link.say({'id': id, 'op': op, ...args});
    // Longer than the helper gives each (sidecar/matrix's do: a minute, three for files and the key backup), so its
    // own reason arrives.
    final wait = switch (op) {
      'download' || 'send_media' || 'verify_recovery_key' => 190,
      'login_password' || 'login_token' || 'sso_url' || 'send' || 'react' || 'redact' || 'read' || 'messages' || 'join' || 'leave' || 'logout' => 75,
      _ => 30,
    };
    return done.future.timeout(Duration(seconds: wait), onTimeout: () {
      _waiting.remove(id);
      throw StateError('Matrix took too long to answer');
    });
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    flush();
    unawaited(cancelBrowser());
    _sub?.cancel();
    unawaited(_link?.close());
    super.dispose();
  }

  /// The app's preferences, for later use (a chat's own settings).
  AppState? get app => _app;
}

/// The helper's log, as the Developer log keeps it (_ProcessLink).
abstract final class MatrixLog {
  /// One line of the helper's log, shortened, where it is worth keeping: the helper's own lines about requests, and
  /// anything mautrix warns of; null for the rest. Neither logs a message's words at these levels.
  static String? keep(String line) {
    Map? m;
    try {
      final d = jsonDecode(line);
      if (d is Map) m = d;
    } catch (_) {}
    if (m == null) return line.trim().isEmpty ? null : (line.length > 300 ? line.substring(0, 300) : line);
    final level = '${m['level'] ?? ''}';
    final message = '${m['message'] ?? ''}';
    if (level != 'warn' && level != 'error' && level != 'fatal' && message != 'asked' && message != 'answered') return null;
    const fields = ['op', 'req', 'took', 'error', 'component', 'room_id', 'event_id'];
    final out = [level, message, for (final k in fields) if (m[k] != null) '$k=${m[k]}'].join(' ');
    return out.length > 300 ? out.substring(0, 300) : out;
  }
}

/// The helper as a process: a line of JSON each way on its stdin and stdout, and its log on stderr, of which what is
/// worth keeping goes to the Developer log.
class _ProcessLink implements MatrixLink {
  _ProcessLink(this.p) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = jsonDecode(line);
        if (m is Map) _in.add(m.cast<String, Object?>());
      } catch (_) {}
    });
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final kept = MatrixLog.keep(line);
      if (kept != null) Sms.instance.devLog('matrix', kept);
    });
  }

  final Process p;
  final _in = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get heard => _in.stream;

  @override
  void say(Map<String, Object?> line) {
    try {
      p.stdin.writeln(jsonEncode(line));
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    try {
      await p.stdin.close();
    } catch (_) {}
    p.kill();
  }
}

/// A message's reactions as Matrix keeps them (reaction event id → {from, emoji}; one person may give several), as
/// kinds: each emoji, how many gave it, and whether [me] is among them. In the order first given.
List<InboxReaction> matrixReactions(Map? byId, {String? me}) {
  if (byId == null || byId.isEmpty) return const [];
  final order = <String>[];
  final count = <String, int>{};
  final mine = <String>{};
  for (final r in byId.values) {
    final e = '${(r as Map)['emoji']}';
    if (!count.containsKey(e)) order.add(e);
    count[e] = (count[e] ?? 0) + 1;
    if (me != null && r['from'] == me) mine.add(e);
  }
  return [for (final e in order) InboxReaction(emoji: e, count: count[e]!, mine: mine.contains(e))];
}
