import 'dart:async';
import 'dart:convert';
import 'dart:io';


import '../app_state.dart';
import 'inbox.dart';

/// Mastodon's direct messages, read and answered from here (Matt, 2026-11-15: "Wire up mastadon and bluesky and have
/// them set as coming soon until we get the API keys setup").
///
/// A direct message on Mastodon is a post seen only by the people it names (`visibility: direct`); the server groups
/// them into conversations (`/api/v1/conversations`). Signing in is the server's own OAuth: Uplink registers itself on
/// the person's server as it is asked (`/api/v1/apps`, nothing registered ahead), the person approves it on their
/// server's page in the browser, and pastes the code it shows back here (the out-of-band redirect, as apps without a
/// web address of their own use). Only the access token and the account are kept (AppState `mastodon_session`).
///
/// There is no push here: the conversations are asked for every [_idle], the open one every [_open]. Words alone for
/// now: a picture in a message is said, not drawn.
class Mastodon extends InboxNetwork {
  Mastodon({HttpClient? client, this.soon = false}) : _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final HttpClient _client;

  @override
  final bool soon;

  // The out-of-band redirect (the server shows the code for the person to paste), what Uplink asks leave to do, and
  // how often the conversations and the open one are asked for.
  static const _oob = 'urn:ietf:wg:oauth:2.0:oob';
  static const _scopes = 'read write';
  static const _idle = Duration(seconds: 30);
  static const _open = Duration(seconds: 6);

  @override
  String get id => 'mastodon';
  @override
  String get name => 'Mastodon';

  AppState? _app;
  InboxState _state = InboxState.signedOut;
  String? _error;

  /// The server (`https://mastodon.social`), the app Uplink registered there, the token, and who signed in.
  String? _server, _clientId, _clientSecret, _token, _me, _handle;
  List<InboxChat> _chats = const [];
  final Map<String, List<InboxMessage>> _messages = {};

  /// Each conversation's newest post (what a reply answers, and where its thread is read from) and the accounts in it.
  final Map<String, String> _lastStatus = {};
  final Map<String, List<String>> _accts = {};
  Timer? _tick, _openTick;
  String? _watching;
  int _sent = 0;

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut ? InboxStep.credentials : (_clientId != null && _token == null ? InboxStep.code : InboxStep.none);
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
    final kept = app.choice('mastodon_session', '');
    if (kept.isEmpty) return;
    try {
      final s = jsonDecode(kept) as Map;
      _server = s['server'] as String?;
      _token = s['token'] as String?;
      _me = s['me'] as String?;
      _handle = s['handle'] as String?;
      if (_server == null || _token == null) return;
      _ready();
    } catch (_) {}
  }

  /// The server a name or address points at: `mastodon.social`, `@me@mastodon.social` or `https://…`.
  static String serverOf(String said) {
    var s = said.trim();
    if (s.contains('@') && !s.startsWith('http')) s = s.split('@').where((x) => x.isNotEmpty).last;
    if (!s.startsWith('http')) s = 'https://$s';
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  /// Registers Uplink on the server [said] and answers the page to approve it on, where the code comes from.
  Future<String?> begin(String said) async {
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final server = serverOf(said);
      final app = await _call('POST', '$server/api/v1/apps', body: {'client_name': 'Uplink', 'redirect_uris': _oob, 'scopes': _scopes, 'website': 'https://gogho.st'}, auth: false);
      _server = server;
      _clientId = app['client_id'] as String?;
      _clientSecret = app['client_secret'] as String?;
      if (_clientId == null) throw const _Said('That server did not let Uplink sign in.');
      notifyListeners();
      return Uri.parse('$server/oauth/authorize').replace(queryParameters: {'client_id': _clientId!, 'redirect_uri': _oob, 'response_type': 'code', 'scope': _scopes}).toString();
    } catch (e) {
      _state = InboxState.signedOut;
      _error = _plain(e);
      notifyListeners();
      return null;
    }
  }

  /// Signs in with the code the server's page showed.
  Future<void> sendCode(String code) async {
    final server = _server, id = _clientId, secret = _clientSecret;
    if (server == null || id == null || secret == null) return;
    try {
      final t = await _call('POST', '$server/oauth/token', body: {
        'grant_type': 'authorization_code', 'code': code.trim(), 'client_id': id, 'client_secret': secret, 'redirect_uri': _oob, 'scope': _scopes,
      }, auth: false);
      _token = t['access_token'] as String?;
      if (_token == null) throw const _Said('That code was not taken. Copy it again from the page.');
      final me = await _call('GET', '$server/api/v1/accounts/verify_credentials');
      _me = '${me['id']}';
      _handle = '@${me['acct']}@${Uri.parse(server).host}';
      _app?.set('mastodon_session', jsonEncode({'server': server, 'token': _token, 'me': _me, 'handle': _handle}));
      _ready();
    } catch (e) {
      _token = null;
      _error = _plain(e);
      notifyListeners();
    }
  }

  @override
  Future<void> signOut() async {
    _tick?.cancel();
    _openTick?.cancel();
    final server = _server, token = _token, id = _clientId, secret = _clientSecret;
    _server = _clientId = _clientSecret = _token = _me = _handle = null;
    _chats = const [];
    _messages.clear();
    _state = InboxState.signedOut;
    _error = null;
    _app?.set('mastodon_session', '');
    notifyListeners();
    if (server != null && token != null && id != null && secret != null) {
      try {
        await _call('POST', '$server/oauth/revoke', body: {'client_id': id, 'client_secret': secret, 'token': token}, auth: false);
      } catch (_) {}
    }
  }

  /// Signed in: the conversations are asked for now and every [_idle] after.
  void _ready() {
    _state = InboxState.ready;
    _error = null;
    notifyListeners();
    _tick?.cancel();
    _tick = Timer.periodic(_idle, (_) => refresh());
    refresh();
    if (_watching != null) watching = _watching;
  }

  @override
  set watching(String? chatId) {
    _watching = chatId;
    _openTick?.cancel();
    if (chatId == null || _state != InboxState.ready) return;
    _openTick = Timer.periodic(_open, (_) => load(chatId));
  }

  /// Asks for the conversations again now.
  Future<void> refresh() async {
    if (_state != InboxState.ready) return;
    try {
      final list = await _callList('GET', '$_server/api/v1/conversations?limit=40');
      final next = <InboxChat>[];
      for (final c in list) {
        final chat = _conversation(c as Map);
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

  /// A conversation as the server lists it, named for everyone in it but this account. Notes its newest post and its
  /// accounts on the way, for sending.
  InboxChat? _conversation(Map c) {
    final cid = '${c['id']}';
    final last = c['last_status'] as Map?;
    final others = [for (final a in (c['accounts'] as List? ?? const [])) if ('${(a as Map)['id']}' != _me) a];
    if (last != null) _lastStatus[cid] = '${last['id']}';
    _accts[cid] = [for (final a in others) a['acct'] as String];
    String nameOf(Map a) {
      final shown = (a['display_name'] as String?)?.trim();
      return shown == null || shown.isEmpty ? '@${a['acct']}' : shown;
    }

    return InboxChat(
      network: id,
      id: cid,
      title: others.isEmpty ? 'Just you' : others.map(nameOf).join(', '),
      date: DateTime.tryParse(last?['created_at'] as String? ?? '')?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0),
      snippet: last == null ? '' : _words(last),
      unread: c['unread'] == true ? 1 : 0,
      group: others.length > 1,
      avatar: others.length == 1 ? others.first['avatar_static'] as String? : null,
      lastFromMe: '${(last?['account'] as Map?)?['id']}' == _me,
    );
  }

  @override
  Future<void> load(String chatId, {bool older = false}) async {
    final last = _lastStatus[chatId];
    if (_state != InboxState.ready || last == null) return;
    try {
      final ctx = await _call('GET', '$_server/api/v1/statuses/$last/context');
      final lastPost = await _call('GET', '$_server/api/v1/statuses/$last');
      final posts = [...(ctx['ancestors'] as List? ?? const []), lastPost, ...(ctx['descendants'] as List? ?? const [])].cast<Map>();
      final held = {for (final m in messagesOf(chatId)) if (m.state == 'sent') m.id: m};
      for (final p in posts) {
        if (p['visibility'] != 'direct') continue;
        final m = _message(p);
        held[m.id] = m;
      }
      final pending = [for (final m in messagesOf(chatId)) if (m.state != 'sent') m];
      _messages[chatId] = [...held.values.toList()..sort((a, b) => a.date.compareTo(b.date)), ...pending];
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = _plain(e);
      notifyListeners();
    }
  }

  /// A post as a message: its words, when, and who wrote it (their shown name, else their @account).
  InboxMessage _message(Map p) {
    final from = p['account'] as Map?;
    return InboxMessage(
      id: '${p['id']}',
      text: _words(p),
      date: DateTime.tryParse(p['created_at'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      mine: '${from?['id']}' == _me,
      sender: (from?['display_name'] as String?)?.trim().isNotEmpty == true ? from!['display_name'] as String : '@${from?['acct'] ?? ''}',
    );
  }

  /// A post's words without its markup and without the mentions a direct message starts with; a picture said.
  static String _words(Map p) {
    var html = (p['content'] as String? ?? '').replaceAll(RegExp(r'<br\s*/?>'), '\n').replaceAll(RegExp(r'</p>\s*<p>'), '\n\n');
    var text = html.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ');
    text = text.replaceFirst(RegExp(r'^(\s*@[\w.\-]+(@[\w.\-]+)?\s*)+'), '').trim();
    final media = (p['media_attachments'] as List? ?? const []).length;
    if (text.isEmpty && media > 0) return media == 1 ? 'Picture' : '$media pictures';
    return text;
  }

  @override
  Future<void> send(String chatId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final local = 'local-${++_sent}';
    _messages[chatId] = [...messagesOf(chatId), InboxMessage(id: local, text: text, date: DateTime.now(), mine: true, state: 'sending')];
    notifyListeners();
    try {
      // A direct message reaches those it names: each person in the conversation, then the words.
      final names = [for (final a in _accts[chatId] ?? const <String>[]) '@$a'].join(' ');
      final p = await _call('POST', '$_server/api/v1/statuses', body: {
        'status': names.isEmpty ? text : '$names $text',
        'visibility': 'direct',
        if (_lastStatus[chatId] != null) 'in_reply_to_id': _lastStatus[chatId],
      });
      final sent = _message(p);
      _lastStatus[chatId] = sent.id;
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
    if (_state != InboxState.ready || !_chats.any((c) => c.id == chatId && c.unread > 0)) return;
    _chats = [for (final c in _chats) c.id == chatId ? c.copyWith(unread: 0) : c];
    notifyListeners();
    try {
      await _call('POST', '$_server/api/v1/conversations/$chatId/read');
    } catch (_) {}
  }

  /// Gone from this account's conversations, as Mastodon's own Delete conversation does (the posts stay with the
  /// others in it).
  @override
  Future<void> deleteChat(String chatId) async {
    try {
      await _call('DELETE', '$_server/api/v1/conversations/$chatId');
      _chats = [for (final c in _chats) if (c.id != chatId) c];
      _messages.remove(chatId);
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  /// Your own posts can be deleted for everyone; anyone else's only left out here (Uplink's own list).
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine;

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    final mine = messagesOf(chatId).any((m) => m.id == messageId && m.mine);
    if (!mine) return super.deleteMessage(chatId, messageId);
    try {
      await _call('DELETE', '$_server/api/v1/statuses/$messageId');
      _messages[chatId] = [for (final x in messagesOf(chatId)) if (x.id != messageId) x];
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  // --- calls ----------------------------------------------------------------------------------------------------------

  // A call whose answer is a list, or an object; anything else comes back empty.
  Future<List> _callList(String method, String url) async {
    final r = await _raw(method, url);
    return r is List ? r : const [];
  }

  Future<Map> _call(String method, String url, {Object? body, bool auth = true}) async {
    final r = await _raw(method, url, body: body, auth: auth);
    return r is Map ? r : const {};
  }

  /// One HTTP call to the server, with the token where there is one; the answer's JSON. Throws [_Status] on 400 and up.
  Future<Object?> _raw(String method, String url, {Object? body, bool auth = true}) async {
    final req = await _client.openUrl(method, Uri.parse(url));
    req.headers.set('accept', 'application/json');
    if (auth && _token != null) req.headers.set('authorization', 'Bearer $_token');
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
      throw _Status(res.statusCode, m['error'] as String?);
    }
    return json;
  }

  /// What went wrong, in words for the page.
  static String _plain(Object e) {
    if (e is _Said) return e.message;
    if (e is _Status) {
      if (e.code == 401 || e.code == 403) return e.error ?? 'Mastodon did not let Uplink in. Sign in again.';
      if (e.code == 404) return 'That server doesn\'t look like a Mastodon server.';
      if (e.code == 429) return 'Mastodon asks to slow down. Try again in a minute.';
      return e.error ?? 'Mastodon answered ${e.code}.';
    }
    if (e is SocketException || e is TimeoutException || e is HandshakeException) return 'That server can\'t be reached just now.';
    return '$e';
  }

  bool _disposed = false;

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

/// An answer of 400 or more: its status, and the server's own word for what went wrong.
class _Status implements Exception {
  const _Status(this.code, this.error);
  final int code;
  final String? error;
  @override
  String toString() => 'Mastodon $code ${error ?? ''}'.trim();
}

/// A failure already in words for the person.
class _Said implements Exception {
  const _Said(this.message);
  final String message;
  @override
  String toString() => message;
}
