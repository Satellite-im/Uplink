import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'inbox.dart';

/// Bluesky's direct messages (chat.bsky.convo), read and answered from here.
///
/// Signing in takes a handle and an **app password made with direct messages allowed** (bsky.app › Settings ›
/// Privacy and security › App passwords › "Allow access to your direct messages"): an app password can be taken back
/// by itself, and the account's own password is never asked for. The handle is resolved to the account's own server
/// (its PDS), the session is made there, and every chat call goes to that server with the header that hands it on to
/// Bluesky's chat service. Only the session's refresh token is kept (AppState `bsky_session`); the password is not.
///
/// There is no push: the chats are asked for every [_idle] while the app runs, and the open chat every [_open].
class Bluesky extends InboxNetwork {
  Bluesky({this.entryway = 'https://bsky.social', this.plc = 'https://plc.directory', HttpClient? client, this.soon = false})
      : _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  /// Where a handle is resolved, and the directory a did:plc is looked up in. Stand-ins in tests.
  final String entryway;
  final String plc;
  final HttpClient _client;

  @override
  final bool soon;

  // The chat service the account's server is asked to pass chat calls on to; and how often the chats are asked for
  // again, and the open chat's messages.
  static const _proxy = 'did:web:api.bsky.chat#bsky_chat';
  static const _idle = Duration(seconds: 20);
  static const _open = Duration(seconds: 4);

  @override
  String get id => 'bluesky';
  @override
  String get name => 'Bluesky';

  AppState? _app;
  InboxState _state = InboxState.signedOut;
  String? _error;
  String? _pds, _did, _handle, _access, _refresh;
  List<InboxChat> _chats = const [];
  final Map<String, List<InboxMessage>> _messages = {};
  /// Each chat's cursor to the messages before the oldest held; null once there are none.
  final Map<String, String?> _older = {};
  Timer? _tick, _openTick;
  String? _watching;

  /// Counts this run's sends, for the id a message has until Bluesky gives it one (`local-<n>`).
  int _sent = 0;

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut ? InboxStep.credentials : InboxStep.none;
  @override
  String? get error => _error;
  @override
  String? get account => _handle;
  @override
  List<InboxChat> get chats => _chats;
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];

  @override
  Future<void> start(AppState app) async {
    _app = app;
    final kept = app.choice('bsky_session', '');
    if (kept.isEmpty) return;
    try {
      final s = jsonDecode(kept) as Map;
      _pds = s['pds'] as String?;
      _did = s['did'] as String?;
      _handle = s['handle'] as String?;
      _refresh = s['refresh'] as String?;
      if (_pds == null || _refresh == null) return;
      await _refreshSession();
      _ready();
    } catch (e) {
      // Kept, but not taken: the session may have been taken back. Signing in again mends it.
      _error = 'Sign in to Bluesky again: $e';
      _state = InboxState.signedOut;
      notifyListeners();
    }
  }

  /// Signs in as [handle] with an app password.
  Future<void> signIn(String handle, String appPassword) async {
    handle = handle.trim().replaceFirst(RegExp(r'^@'), '');
    if (!handle.contains('.')) handle = '$handle.bsky.social';
    _state = InboxState.signingIn;
    _error = null;
    notifyListeners();
    try {
      final pds = await _pdsOf(handle);
      final s = await _call('POST', '$pds/xrpc/com.atproto.server.createSession', body: {'identifier': handle, 'password': appPassword.trim()}, auth: false);
      _pds = pds;
      _take(s);
      // An app password made without direct messages allowed signs in, and is refused by the chat service: found
      // out now, while the person is on the sign-in page, rather than as an empty tab.
      await _chat('GET', 'chat.bsky.convo.listConvos', query: {'limit': '1'});
      _keep();
      _ready();
    } catch (e) {
      _state = InboxState.signedOut;
      _error = _plain(e);
      _access = _refresh = null;
      notifyListeners();
    }
  }

  @override
  Future<void> signOut() async {
    _tick?.cancel();
    _openTick?.cancel();
    final pds = _pds, refresh = _refresh;
    _pds = _did = _handle = _access = _refresh = null;
    _chats = const [];
    _messages.clear();
    _state = InboxState.signedOut;
    _error = null;
    _app?.set('bsky_session', '');
    notifyListeners();
    if (pds != null && refresh != null) {
      try {
        await _call('POST', '$pds/xrpc/com.atproto.server.deleteSession', token: refresh);
      } catch (_) {}
    }
  }

  @override
  set watching(String? chatId) {
    _watching = chatId;
    _openTick?.cancel();
    if (chatId == null || _state != InboxState.ready) return;
    _openTick = Timer.periodic(_open, (_) => load(chatId));
  }

  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready) return;
    try {
      final r = await _chat('GET', 'chat.bsky.convo.getMessages', query: {
        'convoId': chatId,
        'limit': '50',
        if (older && _older[chatId] != null) 'cursor': _older[chatId]!,
      });
      final got = [for (final m in (r['messages'] as List? ?? const [])) ?_message(m as Map)];
      final held = {for (final m in messagesOf(chatId)) if (m.state == 'sent') m.id: m};
      for (final m in got) {
        held[m.id] = m;
      }
      // Messages still on their way stay at the end until the network has them.
      final pending = [for (final m in messagesOf(chatId)) if (m.state != 'sent') m];
      final all = held.values.toList()..sort((a, b) => a.date.compareTo(b.date));
      _messages[chatId] = [...all, ...pending];
      if (older || _older[chatId] == null) _older[chatId] = r['cursor'] as String?;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = _plain(e);
      notifyListeners();
    }
  }

  /// Whether [chatId] has messages before the oldest held.
  bool hasOlder(String chatId) => _older[chatId] != null;

  @override
  Future<void> send(String chatId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final local = 'local-${++_sent}';
    final mine = InboxMessage(id: local, text: text, date: DateTime.now(), mine: true, state: 'sending');
    _messages[chatId] = [...messagesOf(chatId), mine];
    notifyListeners();
    try {
      final m = await _chat('POST', 'chat.bsky.convo.sendMessage', body: {
        'convoId': chatId,
        'message': {'text': text},
      });
      final sent = _message(m) ?? InboxMessage(id: local, text: text, date: DateTime.now(), mine: true);
      _messages[chatId] = [for (final x in messagesOf(chatId)) x.id == local ? sent : x];
      _chats = [for (final c in _chats) c.id == chatId ? c.copyWith(snippet: text, date: sent.date, lastFromMe: true) : c]..sort((a, b) => b.date.compareTo(a.date));
      _error = null;
    } catch (e) {
      _messages[chatId] = [for (final x in messagesOf(chatId)) x.id == local ? InboxMessage(id: local, text: text, date: x.date, mine: true, state: 'failed') : x];
      _error = _plain(e);
    }
    notifyListeners();
  }

  @override
  Future<void> markRead(String chatId) async {
    if (_state != InboxState.ready) return;
    final was = _chats.where((c) => c.id == chatId && c.unread > 0);
    if (was.isEmpty) return;
    _chats = [for (final c in _chats) c.id == chatId ? c.copyWith(unread: 0) : c];
    notifyListeners();
    try {
      await _chat('POST', 'chat.bsky.convo.updateRead', body: {'convoId': chatId});
    } catch (_) {}
  }

  /// Left, as Bluesky's own Leave conversation does: gone from this account's chats.
  @override
  Future<void> deleteChat(String chatId) async {
    try {
      await _chat('POST', 'chat.bsky.convo.leaveConvo', body: {'convoId': chatId});
      _chats = [for (final c in _chats) if (c.id != chatId) c];
      _messages.remove(chatId);
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  /// Deleted for this account, as Bluesky's own Delete for me does (Bluesky deletes for no one else).
  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    try {
      await _chat('POST', 'chat.bsky.convo.deleteMessageForSelf', body: {'convoId': chatId, 'messageId': messageId});
      _messages[chatId] = [for (final x in messagesOf(chatId)) if (x.id != messageId) x];
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  /// Asks for the chats again now.
  Future<void> refresh() async {
    if (_state != InboxState.ready) return;
    try {
      final r = await _chat('GET', 'chat.bsky.convo.listConvos', query: {'limit': '50'});
      final next = <InboxChat>[];
      for (final c in (r['convos'] as List? ?? const [])) {
        final chat = _convo(c as Map);
        if (chat != null) next.add(chat);
      }
      next.sort((a, b) => b.date.compareTo(a.date));
      // Asked every so often: the listeners are told only when something is different (InboxNetwork.sameChats).
      final same = _error == null && InboxNetwork.sameChats(_chats, next);
      _chats = next;
      _error = null;
      if (!same) notifyListeners();
    } catch (e) {
      _error = _plain(e);
      notifyListeners();
    }
  }

  // --- what the chat service says, as the app holds it -------------------------------------------------------------

  /// A conversation as the chat service lists it: named for everyone in it but this account.
  InboxChat? _convo(Map c) {
    final convoId = c['id'] as String?;
    if (convoId == null) return null;
    final others = [for (final m in (c['members'] as List? ?? const [])) if ((m as Map)['did'] != _did) m];
    String nameOf(Map m) {
      final shown = (m['displayName'] as String?)?.trim();
      return shown == null || shown.isEmpty ? (m['handle'] as String? ?? 'Someone') : shown;
    }

    final last = c['lastMessage'] as Map?;
    final lastText = last == null ? '' : (last['text'] as String? ?? (last[r'$type'] == 'chat.bsky.convo.defs#deletedMessageView' ? 'Message deleted' : ''));
    final sentAt = DateTime.tryParse(last?['sentAt'] as String? ?? '')?.toLocal();
    return InboxChat(
      network: id,
      id: convoId,
      title: others.isEmpty ? 'Just you' : others.map(nameOf).join(', '),
      date: sentAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      snippet: lastText,
      unread: (c['unreadCount'] as num?)?.toInt() ?? 0,
      group: others.length > 1,
      avatar: others.length == 1 ? others.first['avatar'] as String? : null,
      lastFromMe: (last?['sender'] as Map?)?['did'] == _did,
    );
  }

  /// A message as the chat service gives it; null for one with no words (a deleted one).
  InboxMessage? _message(Map m) {
    final id = m['id'] as String?;
    final text = m['text'] as String?;
    if (id == null || text == null) return null;
    final from = (m['sender'] as Map?)?['did'] as String?;
    return InboxMessage(id: id, text: text, date: DateTime.tryParse(m['sentAt'] as String? ?? '')?.toLocal() ?? DateTime.now(), mine: from == _did, sender: from ?? '');
  }

  // --- the session ---------------------------------------------------------------------------------------------------

  /// Takes a session as createSession or refreshSession answers it: a new access token, and whatever else it names.
  void _take(Map s) {
    _access = s['accessJwt'] as String?;
    _refresh = s['refreshJwt'] as String? ?? _refresh;
    _did = s['did'] as String? ?? _did;
    _handle = s['handle'] as String? ?? _handle;
  }

  /// Saves what signs in again next time. The access token is not kept: a new one is asked for with the refresh token.
  void _keep() => _app?.set('bsky_session', jsonEncode({'pds': _pds, 'did': _did, 'handle': _handle, 'refresh': _refresh}));

  /// Trades the refresh token for a new session, and keeps it.
  Future<void> _refreshSession() async {
    final s = await _call('POST', '$_pds/xrpc/com.atproto.server.refreshSession', token: _refresh);
    _take(s);
    _keep();
  }

  /// Signed in: the chats are asked for now and every [_idle] after.
  void _ready() {
    _state = InboxState.ready;
    _error = null;
    notifyListeners();
    _tick?.cancel();
    _tick = Timer.periodic(_idle, (_) => refresh());
    refresh();
    if (_watching != null) watching = _watching;
  }

  /// The account's own server, from its handle: the handle's DID, then the DID's document.
  Future<String> _pdsOf(String handle) async {
    final r = await _call('GET', '$entryway/xrpc/com.atproto.identity.resolveHandle?handle=${Uri.encodeQueryComponent(handle)}', auth: false);
    final did = r['did'] as String?;
    if (did == null) throw const _Said('That handle was not found on Bluesky.');
    final Map doc;
    if (did.startsWith('did:plc:')) {
      doc = await _call('GET', '$plc/$did', auth: false);
    } else if (did.startsWith('did:web:')) {
      doc = await _call('GET', 'https://${did.substring(8)}/.well-known/did.json', auth: false);
    } else {
      throw _Said('Accounts named by $did are not understood here yet.');
    }
    for (final s in (doc['service'] as List? ?? const [])) {
      if ((s as Map)['id'] == '#atproto_pds' && s['serviceEndpoint'] is String) return (s['serviceEndpoint'] as String).replaceAll(RegExp(r'/+$'), '');
    }
    throw const _Said('That account names no server to sign in to.');
  }

  /// A call to the chat service, through the account's server, signing in again once if the session has run out.
  Future<Map> _chat(String method, String nsid, {Map<String, String>? query, Object? body}) async {
    final url = Uri.parse('$_pds/xrpc/$nsid').replace(queryParameters: query).toString();
    try {
      return await _call(method, url, body: body, proxy: true);
    } on _Status catch (e) {
      if (e.code != 401 && e.error != 'ExpiredToken') rethrow;
      await _refreshSession();
      return _call(method, url, body: body, proxy: true);
    }
  }

  /// One HTTP call; the answer's JSON. [token] is sent in place of the access token (the refresh token, for the calls
  /// that want it); [proxy] asks the account's server to pass it on to the chat service. Throws [_Status] on 400 and
  /// up.
  Future<Map> _call(String method, String url, {Object? body, bool auth = true, String? token, bool proxy = false}) async {
    final req = await _client.openUrl(method, Uri.parse(url));
    req.headers.set('accept', 'application/json');
    final bearer = token ?? (auth ? _access : null);
    if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
    if (proxy) req.headers.set('atproto-proxy', _proxy);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    Object? json;
    try {
      json = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
    } catch (_) {
      json = null;
    }
    if (res.statusCode >= 400) {
      final m = json is Map ? json : const {};
      throw _Status(res.statusCode, m['error'] as String?, m['message'] as String?);
    }
    return json is Map ? json : const {};
  }

  /// What went wrong, in words for the page.
  static String _plain(Object e) {
    if (e is _Said) return e.message;
    if (e is _Status) {
      if (e.error == 'AuthenticationRequired' || (e.code == 401 && e.message?.contains('password') == true)) return 'That handle and app password don\'t match.';
      if (e.message?.toLowerCase().contains('scope') == true) {
        return 'This app password can\'t read direct messages. Make a new one with "Allow access to your direct messages" ticked.';
      }
      if (e.error == 'AuthFactorTokenRequired') return 'Use an app password here, not your account\'s password.';
      if (e.code == 429) return 'Bluesky asks to slow down. Try again in a minute.';
      return e.message ?? e.error ?? 'Bluesky answered ${e.code}.';
    }
    if (e is SocketException || e is TimeoutException || e is HandshakeException) return 'Bluesky can\'t be reached just now.';
    return '$e';
  }

  bool _disposed = false;

  /// Answers still coming after the app let go of it (a sign-out, a test's end) change nothing.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _openTick?.cancel();
    super.dispose();
  }
}

/// An answer of 400 or more: its status, and the error's name and message as the server's JSON gave them.
class _Status implements Exception {
  const _Status(this.code, this.error, this.message);
  final int code;
  final String? error;
  final String? message;
  @override
  String toString() => 'Bluesky $code ${error ?? ''} ${message ?? ''}'.trim();
}

/// A failure already in words for the person.
class _Said implements Exception {
  const _Said(this.message);
  final String message;
  @override
  String toString() => message;
}

/// [Bluesky._plain], for a test of its words.
@visibleForTesting
String blueskyPlain(Object e) => Bluesky._plain(e);
