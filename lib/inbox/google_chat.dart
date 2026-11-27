import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../app_state.dart';
import 'inbox.dart';

/// Google Chat, read and answered from here (Matt, 2026-11-17: "Let's add support for matrix, microsoft teams and
/// google chat").
///
/// The Google Chat API (`chat.googleapis.com/v1`) with the person's own sign-in. Google lets user sign-in reach the Chat
/// API from Google Workspace accounts (work or school) only: its docs list "A Business or Enterprise Google Workspace
/// account with access to Google Chat" as the prerequisite, so a personal Gmail account is not offered.
///
/// Signing in is OAuth 2.0 for installed apps with PKCE and a loopback redirect: Uplink listens on 127.0.0.1 at a free
/// port, opens Google's consent page in the browser, takes the code it is sent back to that address, and exchanges it
/// (with the verifier) for tokens. Google's device flow does not allow Chat scopes. Only the refresh token and the
/// account are kept (AppState `googlechat_session`); access tokens live in memory and are refreshed as they run out.
///
/// The app's client id and secret are a "Desktop app" OAuth client given at build time (`--dart-define
/// GHOST_GCHAT_CLIENT_ID=… GHOST_GCHAT_CLIENT_SECRET=…`); Google itself says such a secret is not confidential.
///
/// Names: a message names its sender as `users/{id}` and under user sign-in gives a display name only for people in the
/// space or with prior affinity. Uplink takes names from a space's memberships first and asks the People API
/// (`people:batchGet`, `directory.readonly`) for anyone still nameless; the Chat user id is the People API's person id.
///
/// No push: the spaces are asked for every [_idle], the open one every [_open], and a 429 doubles the wait.
class GoogleChat extends InboxNetwork {
  GoogleChat({
    HttpClient? client,
    this.soon = false,
    String? clientId,
    String? clientSecret,
    this.authUrl = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenUrl = 'https://oauth2.googleapis.com/token',
    this.revokeUrl = 'https://oauth2.googleapis.com/revoke',
    this.chatBase = 'https://chat.googleapis.com/v1',
    this.peopleBase = 'https://people.googleapis.com/v1',
  })  : clientId = clientId ?? const String.fromEnvironment('GHOST_GCHAT_CLIENT_ID'),
        clientSecret = clientSecret ?? const String.fromEnvironment('GHOST_GCHAT_CLIENT_SECRET'),
        _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  final HttpClient _client;

  /// The app's OAuth client, given at build time; empty in a build made without one.
  final String clientId, clientSecret;

  /// Google's addresses, each injectable for a test.
  final String authUrl, tokenUrl, revokeUrl, chatBase, peopleBase;

  @override
  final bool soon;

  static const _g = 'https://www.googleapis.com/auth';

  /// What Uplink asks for. The first two are needed; without the others names, unread counts or reactions go without.
  static const needed = ['$_g/chat.spaces.readonly', '$_g/chat.messages'];
  static const scopes = [
    'openid',
    'email',
    ...needed,
    '$_g/chat.messages.reactions',
    '$_g/chat.memberships.readonly',
    '$_g/chat.users.readstate',
    '$_g/directory.readonly',
  ];

  // How often the spaces and the open one are asked for, and the choice the session is kept under.
  static const _idle = Duration(seconds: 30);
  static const _open = Duration(seconds: 6);
  static const _sessionKey = 'googlechat_session';

  @override
  String get id => 'googlechat';
  @override
  String get name => 'Google Chat';

  AppState? _app;
  InboxState _state = InboxState.signedOut;
  String? _error;

  /// The refresh token, the access token and when it runs out, the account's Google id (`sub`) and email.
  String? _refresh, _access, _me, _email;
  DateTime _accessUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// The scopes the person granted, which may be fewer than [scopes].
  Set<String> _granted = const {};

  List<InboxChat> _chats = const [];
  final Map<String, List<InboxMessage>> _messages = {};

  /// Each message's thread (`spaces/…/threads/…`), what a reply goes into.
  final Map<String, String> _threadOf = {};

  /// Each space's last active time as last seen, its read time, its title once worked out, older messages' page token.
  final Map<String, String> _seenActive = {};
  final Map<String, DateTime> _readAt = {};
  final Map<String, String> _titles = {};
  final Map<String, String?> _avatars = {};
  final Map<String, String?> _older = {};
  final Map<String, InboxMessage> _last = {};

  /// People's names (`users/{id}` → name) and pictures, as learnt.
  final Map<String, String> _names = {};
  final Map<String, String> _photos = {};

  Timer? _tick, _openTick;
  String? _watching;
  int _sent = 0;

  /// Waiting after a 429: nothing is asked until then. [_wait] doubles each time, back to nothing on success.
  DateTime? _pausedUntil;
  Duration _wait = Duration.zero;

  @visibleForTesting
  DateTime? get pausedUntil => _pausedUntil;

  // Signing in: the loopback listener and what it waits for.
  HttpServer? _listener;
  String? _verifier, _stateWord, _redirect;
  Completer<void>? _pending;

  /// Finishes when the sign-in begun by [begin] has ended, either way.
  Future<void>? get pending => _pending?.future;

  /// Whether this build was made with a Google app id, so it can sign in at all.
  bool get configured => clientId.isNotEmpty;

  @override
  InboxState get state => configured ? _state : InboxState.unavailable;
  @override
  InboxStep get step => _state == InboxState.signingIn ? InboxStep.elsewhere : InboxStep.none;
  @override
  String? get error => configured ? _error : 'This build has no Google app id yet, so Google Chat can\'t sign in here.';
  @override
  String? get account => _email;
  @override
  List<InboxChat> get chats => _chats;
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];

  @override
  bool get canReply => true;
  @override
  bool get canReact => true;

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (!configured) return;
    final kept = app.choice(_sessionKey, '');
    if (kept.isEmpty) return;
    try {
      final s = jsonDecode(kept) as Map;
      _refresh = s['refresh'] as String?;
      _me = s['me'] as String?;
      _email = s['email'] as String?;
      _granted = {...((s['scopes'] as List?) ?? const []).cast<String>()};
      if (_refresh == null) return;
      _ready();
    } catch (_) {}
  }

  // --- signing in -----------------------------------------------------------------------------------------------------

  /// Starts listening on 127.0.0.1 and answers Google's consent page to open in the browser; null where it can't
  /// begin. The rest happens as the browser comes back: [state] turns ready, or [error] says why not.
  Future<String?> begin() async {
    if (!configured) return null;
    await cancel();
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _listener = listener;
      _redirect = 'http://127.0.0.1:${listener.port}';
      _verifier = _randomWord(64);
      _stateWord = _randomWord(24);
      final done = _pending = Completer<void>();
      listener.listen(_arrived, onError: (_) {});
      // Given up after ten minutes: the page was closed, or left.
      Future<void>.delayed(const Duration(minutes: 10), () {
        if (identical(_pending, done) && !done.isCompleted) _failSignIn('The sign-in waited too long. Try again.');
      });
      return Uri.parse(authUrl).replace(queryParameters: {
        'client_id': clientId,
        'redirect_uri': _redirect!,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'code_challenge': challengeOf(_verifier!),
        'code_challenge_method': 'S256',
        'state': _stateWord!,
        'access_type': 'offline',
        'prompt': 'consent',
        'include_granted_scopes': 'true',
      }).toString();
    } catch (e) {
      await _closeListener();
      _state = InboxState.signedOut;
      _error = 'Uplink could not listen for Google\'s answer on this device ($e).';
      notifyListeners();
      return null;
    }
  }

  /// Stops waiting for a sign-in begun with [begin].
  Future<void> cancel() async {
    if (_listener == null) return;
    await _closeListener();
    if (_state == InboxState.signingIn) _state = InboxState.signedOut;
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete();
    notifyListeners();
  }

  /// Stops listening on the loopback address.
  Future<void> _closeListener() async {
    final l = _listener;
    _listener = null;
    await l?.close(force: true);
  }

  /// The browser came back to the loopback address.
  Future<void> _arrived(HttpRequest req) async {
    final q = req.uri.queryParameters;
    if (!q.containsKey('code') && !q.containsKey('error')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (q['state'] != _stateWord) {
      await _page(req, 400, 'This answer was not for Uplink\'s sign-in. Go back to Uplink and try again.');
      return;
    }
    final refused = q['error'];
    if (refused != null) {
      await _page(req, 200, 'Uplink was not signed in. You can close this tab.');
      await _closeListener();
      _failSignIn(switch (refused) {
        'access_denied' => 'Google Chat was not allowed. Sign in again when you\'re ready, and allow what Uplink asks for.',
        'admin_policy_enforced' || 'org_internal' => 'Your organisation\'s admin hasn\'t allowed Uplink. Ask them to allow it in the Google Admin console.',
        _ => 'Google said: $refused',
      });
      return;
    }
    await _page(req, 200, 'Signed in. You can close this tab and go back to Uplink.');
    await _closeListener();
    await _exchange(q['code']!);
  }

  /// Answers the browser, sent back to the loopback address, with a small page saying [words].
  Future<void> _page(HttpRequest req, int code, String words) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.html;
    req.response.write('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
        '<title>Uplink</title><body style="font-family:system-ui;margin:3em auto;max-width:28em;padding:0 1em">'
        '<p>${const HtmlEscape().convert(words)}</p></body>');
    await req.response.close();
  }

  /// Trades the code the browser brought back, with the PKCE verifier, for tokens, and ends the sign-in either way.
  Future<void> _exchange(String code) async {
    try {
      final t = await _form(tokenUrl, {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': _redirect!,
        'code_verifier': _verifier!,
      });
      final refresh = t['refresh_token'] as String?;
      if (refresh == null) throw const _Said('Google gave no lasting sign-in. Try again.');
      final granted = '${t['scope'] ?? ''}'.split(' ').where((s) => s.isNotEmpty).toSet();
      final missing = [for (final s in needed) if (granted.isNotEmpty && !granted.contains(s)) s];
      if (missing.isNotEmpty) {
        _revokeQuietly(refresh);
        throw const _Said('Uplink needs to read your spaces and your messages. Sign in again and leave those ticked.');
      }
      final claims = _claims(t['id_token'] as String?);
      _refresh = refresh;
      _access = t['access_token'] as String?;
      _accessUntil = DateTime.now().add(Duration(seconds: ((t['expires_in'] as num?) ?? 3600).toInt() - 60));
      _me = claims['sub'] as String?;
      _email = claims['email'] as String?;
      _granted = granted;
      _keep();
      _finishSignIn();
      _ready();
    } catch (e) {
      _failSignIn(_plain(e));
    }
  }

  /// Tells whoever waits on [pending] that the sign-in has ended.
  void _finishSignIn() {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete();
  }

  /// Ends the sign-in as failed, with [words] to show.
  void _failSignIn(String words) {
    _closeListener();
    _state = InboxState.signedOut;
    _error = words;
    _finishSignIn();
    notifyListeners();
  }

  /// Saves what signs in again next time: the refresh token, the account and the scopes granted.
  void _keep() => _app?.set(_sessionKey, jsonEncode({'refresh': _refresh, 'me': _me, 'email': _email, 'scopes': _granted.toList()}));

  /// The S256 challenge of a PKCE [verifier].
  static String challengeOf(String verifier) =>
      base64Url.encode(SHA256Digest().process(Uint8List.fromList(ascii.encode(verifier)))).replaceAll('=', '');

  /// [length] random characters from those a PKCE verifier may hold (RFC 7636's unreserved set).
  static String _randomWord(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return String.fromCharCodes([for (var i = 0; i < length; i++) chars.codeUnitAt(r.nextInt(chars.length))]);
  }

  /// What an ID token says (its middle part, decoded); empty where it can't be read. Its signature is not checked:
  /// it came straight from Google's token address.
  static Map _claims(String? idToken) {
    if (idToken == null) return const {};
    try {
      final part = idToken.split('.')[1];
      return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(part)))) as Map;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> signOut() async {
    await cancel();
    _tick?.cancel();
    _openTick?.cancel();
    final refresh = _refresh;
    _forget();
    _error = null;
    notifyListeners();
    if (refresh != null) _revokeQuietly(refresh);
  }

  /// Forgets the session and everything held of the account.
  void _forget() {
    _refresh = _access = _me = _email = null;
    _granted = const {};
    _chats = const [];
    _messages.clear();
    _threadOf.clear();
    _seenActive.clear();
    _readAt.clear();
    _titles.clear();
    _older.clear();
    _last.clear();
    _state = InboxState.signedOut;
    _app?.set(_sessionKey, '');
  }

  /// Asks Google to take [token] back, without waiting and whether or not it answers.
  void _revokeQuietly(String token) {
    _form(revokeUrl, {'token': token}).catchError((_) => const {});
  }

  /// Signed in: the spaces are asked for now and every [_idle] after.
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

  /// Whether Google's 429 still asks Uplink to wait.
  bool get _paused => _pausedUntil != null && DateTime.now().isBefore(_pausedUntil!);

  // --- spaces ---------------------------------------------------------------------------------------------------------

  /// Asks for the spaces again now; the ones that changed since are read further (read state, last message, title).
  Future<void> refresh() async {
    if (_state != InboxState.ready || _paused) return;
    try {
      final spaces = <Map>[];
      String? page;
      for (var i = 0; i < 3; i++) {
        final r = await _get('$chatBase/spaces', {'pageSize': '100', 'pageToken': ?page});
        spaces.addAll(((r['spaces'] as List?) ?? const []).cast<Map>());
        page = r['nextPageToken'] as String?;
        if (page == null || page.isEmpty) break;
      }
      final next = <InboxChat>[];
      for (final s in spaces) {
        final type = s['spaceType'] as String? ?? s['type'] as String? ?? '';
        if (type != 'DIRECT_MESSAGE' && type != 'GROUP_CHAT' && type != 'SPACE' && type != 'ROOM' && type != 'DM') continue;
        final chatId = s['name'] as String;
        final active = s['lastActiveTime'] as String? ?? s['createTime'] as String? ?? '';
        if (_seenActive[chatId] != active) {
          await _freshen(chatId, s, type);
          _seenActive[chatId] = active;
        }
        final last = _last[chatId];
        final date = DateTime.tryParse(active)?.toLocal() ?? last?.date ?? DateTime.fromMillisecondsSinceEpoch(0);
        next.add(InboxChat(
          network: id,
          id: chatId,
          title: _titles[chatId] ?? 'Google Chat',
          date: date,
          snippet: last == null ? '' : (last.mine || type == 'DIRECT_MESSAGE' || last.sender.isEmpty ? last.text : '${last.sender}: ${last.text}'),
          unread: _unread(chatId, date),
          group: type != 'DIRECT_MESSAGE' && type != 'DM',
          avatar: _avatars[chatId],
          lastFromMe: last?.mine ?? false,
        ));
      }
      next.sort((a, b) => b.date.compareTo(a.date));
      // Asked every so often: the listeners are told only when something is different (InboxNetwork.sameChats).
      final same = _error == null && InboxNetwork.sameChats(_chats, next);
      _chats = next;
      _error = null;
      _calm();
      if (!same) notifyListeners();
    } catch (e) {
      _setError(e);
    }
  }

  /// How many unread in [chatId]: those held after its read time and not this account's, at least one when the space
  /// was active after it.
  int _unread(String chatId, DateTime active) {
    final read = _readAt[chatId];
    if (read == null || !active.isAfter(read)) return 0;
    final n = messagesOf(chatId).where((m) => !m.mine && m.date.isAfter(read)).length;
    return max(1, n);
  }

  /// A space that changed: its title (once), its read time, its newest message.
  Future<void> _freshen(String chatId, Map s, String type) async {
    final shown = (s['displayName'] as String?)?.trim() ?? '';
    if (shown.isNotEmpty) {
      _titles[chatId] = shown;
    } else if (!_titles.containsKey(chatId)) {
      _titles[chatId] = await _titleFromMembers(chatId, type);
    }
    if (_granted.isEmpty || _granted.contains('$_g/chat.users.readstate')) {
      try {
        final rs = await _get('$chatBase/users/me/$chatId/spaceReadState');
        final at = DateTime.tryParse(rs['lastReadTime'] as String? ?? '');
        if (at != null) _readAt[chatId] = at.toLocal();
      } on _Status catch (e) {
        if (e.code == 429) rethrow;
      }
    }
    try {
      final r = await _get('$chatBase/$chatId/messages', {'pageSize': '1', 'orderBy': 'createTime desc'});
      final list = ((r['messages'] as List?) ?? const []).cast<Map>();
      if (list.isNotEmpty) {
        await _learnNames(list);
        _last[chatId] = _message(list.first);
      }
    } on _Status catch (e) {
      if (e.code == 429 || e.code == 401) rethrow;
    }
  }

  /// A space without a name: the others in it, by name.
  Future<String> _titleFromMembers(String chatId, String type) async {
    try {
      final r = await _get('$chatBase/$chatId/members', {'pageSize': '20'});
      final others = <String>[];
      for (final m in ((r['memberships'] as List?) ?? const []).cast<Map>()) {
        final who = m['member'] as Map?;
        final user = who?['name'] as String?;
        if (user == null || user == 'users/$_me' || who?['type'] == 'BOT') continue;
        final n = (who?['displayName'] as String?)?.trim() ?? '';
        if (n.isNotEmpty) _names[user] = n;
        others.add(user);
      }
      await _people(others);
      if (type == 'DIRECT_MESSAGE' && others.length == 1) _avatars[chatId] = _photos[others.first];
      final names = [for (final u in others) _names[u] ?? 'Someone'];
      if (names.isEmpty) return 'Just you';
      return names.length > 4 ? '${names.take(3).join(', ')} and ${names.length - 3} more' : names.join(', ');
    } on _Status catch (e) {
      if (e.code == 429) rethrow;
      return type == 'DIRECT_MESSAGE' ? 'Direct message' : 'Group chat';
    }
  }

  /// Senders' names the messages give, then the People API for the rest.
  Future<void> _learnNames(List<Map> messages) async {
    final want = <String>{};
    for (final m in messages) {
      final s = m['sender'] as Map?;
      final user = s?['name'] as String?;
      if (user == null || user == 'users/$_me') continue;
      final n = (s?['displayName'] as String?)?.trim() ?? '';
      if (n.isNotEmpty) {
        _names[user] = n;
      } else if (!_names.containsKey(user)) {
        want.add(user);
      }
    }
    await _people(want);
  }

  /// Names and pictures of [users] (`users/{id}`) from the People API, where it knows them (the organisation's
  /// directory). Those it doesn't stay nameless.
  Future<void> _people(Iterable<String> users) async {
    final ask = [for (final u in users) if (!_names.containsKey(u) && u.startsWith('users/')) u];
    if (ask.isEmpty || (_granted.isNotEmpty && !_granted.contains('$_g/directory.readonly'))) return;
    try {
      final qs = [for (final u in ask) 'resourceNames=${Uri.encodeQueryComponent('people/${u.substring(6)}')}'].join('&');
      final r = await _getUrl('$peopleBase/people:batchGet?$qs&personFields=names,photos');
      for (final x in ((r['responses'] as List?) ?? const []).cast<Map>()) {
        final asked = x['requestedResourceName'] as String? ?? '';
        final p = x['person'] as Map?;
        if (p == null || !asked.startsWith('people/')) continue;
        final user = 'users/${asked.substring(7)}';
        final names = ((p['names'] as List?) ?? const []).cast<Map>();
        final n = names.isEmpty ? '' : '${names.first['displayName'] ?? ''}'.trim();
        if (n.isNotEmpty) _names[user] = n;
        final photos = ((p['photos'] as List?) ?? const []).cast<Map>();
        if (photos.isNotEmpty && photos.first['url'] is String) _photos[user] = photos.first['url'] as String;
      }
    } on _Status catch (e) {
      if (e.code == 429) rethrow;
    } catch (_) {}
  }

  // --- messages -------------------------------------------------------------------------------------------------------

  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready || _paused) return;
    if (older && _older[chatId] == null) return;
    try {
      final r = await _get('$chatBase/$chatId/messages', {
        'pageSize': '50',
        'orderBy': 'createTime desc',
        if (older) 'pageToken': _older[chatId]!,
      });
      final list = ((r['messages'] as List?) ?? const []).cast<Map>();
      if (older || !_older.containsKey(chatId)) _older[chatId] = (r['nextPageToken'] as String?)?.isNotEmpty == true ? r['nextPageToken'] as String : null;
      await _learnNames(list);
      final held = {for (final m in messagesOf(chatId)) if (m.state == 'sent') m.id: m};
      for (final raw in list) {
        final m = _message(raw);
        held[m.id] = m;
      }
      final sorted = _withReplies(held.values.toList()..sort((a, b) => a.date.compareTo(b.date)));
      final pending = [for (final m in messagesOf(chatId)) if (m.state != 'sent') m];
      _messages[chatId] = [...sorted, ...pending];
      if (sorted.isNotEmpty) _last[chatId] = sorted.last;
      _error = null;
      _calm();
      notifyListeners();
    } catch (e) {
      _setError(e);
    }
  }

  /// Replies in a thread shown inline: each says which message started its thread, and what that said.
  List<InboxMessage> _withReplies(List<InboxMessage> sorted) {
    final roots = <String, InboxMessage>{};
    for (final m in sorted) {
      final t = _threadOf[m.id];
      if (t != null) roots.putIfAbsent(t, () => m);
    }
    return [
      for (final m in sorted)
        if (_threadOf[m.id] case final t? when roots[t] != null && roots[t]!.id != m.id)
          InboxMessage(
            id: m.id, text: m.text, date: m.date, mine: m.mine, sender: m.sender, senderId: m.senderId, state: m.state, reactions: m.reactions,
            replyTo: roots[t]!.id, replyText: roots[t]!.text, replySender: roots[t]!.mine ? 'You' : roots[t]!.sender,
          )
        else
          m,
    ];
  }

  @override
  String? faceOf(String user) => _photos[user];

  /// A message as the Chat API gives it. Notes its thread on the way, for a reply to go into.
  InboxMessage _message(Map p) {
    final name = p['name'] as String;
    final thread = (p['thread'] as Map?)?['name'] as String?;
    if (thread != null) _threadOf[name] = thread;
    final sender = p['sender'] as Map?;
    final user = sender?['name'] as String? ?? '';
    final mine = _me != null && user == 'users/$_me';
    var text = (p['text'] as String?) ?? _plainFormatted(p['formattedText'] as String? ?? '');
    final files = [
      for (final a in ((p['attachment'] as List?) ?? const []).cast<Map>()) '📎 ${a['contentName'] ?? 'Attachment'}',
    ];
    if (files.isNotEmpty) text = [if (text.trim().isNotEmpty) text, ...files].join('\n');
    if (text.trim().isEmpty && p['cardsV2'] != null) text = 'Card';
    return InboxMessage(
      id: name,
      text: text,
      date: DateTime.tryParse(p['createTime'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      mine: mine,
      sender: mine ? '' : (_names[user] ?? (sender?['displayName'] as String?) ?? 'Someone'),
      senderId: user,
      reactions: [
        for (final r in ((p['emojiReactionSummaries'] as List?) ?? const []).cast<Map>())
          if ((r['emoji'] as Map?)?['unicode'] is String) InboxReaction(emoji: (r['emoji'] as Map)['unicode'] as String, count: (r['reactionCount'] as num?)?.toInt() ?? 1),
      ],
    );
  }

  /// Chat's formatted text without its markup: `*bold*`, `_italic_`, `~strike~`, `<users/1>` mentions, `<url|words>`.
  static String _plainFormatted(String s) => s
      .replaceAllMapped(RegExp(r'<(https?://[^|>]+)\|([^>]+)>'), (m) => m[2]!)
      .replaceAll(RegExp(r'<users/[^>]+>'), '@someone')
      .replaceAllMapped(RegExp(r'([*_~])(\S(?:.*?\S)?)\1'), (m) => m[2]!);

  @override
  Future<void> send(String chatId, String text) => _post(chatId, text, null);

  @override
  Future<void> reply(String chatId, String messageId, String text) => _post(chatId, text, _threadOf[messageId]);

  /// Sends [text], into [thread] where given: shown at once as "sending", then as Google has it, or "failed".
  Future<void> _post(String chatId, String text, String? thread) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final local = 'local-${++_sent}';
    _messages[chatId] = [...messagesOf(chatId), InboxMessage(id: local, text: text, date: DateTime.now(), mine: true, state: 'sending')];
    notifyListeners();
    try {
      final p = await _call('POST', '$chatBase/$chatId/messages',
          query: thread == null ? null : {'messageReplyOption': 'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD'},
          body: {'text': text, if (thread != null) 'thread': {'name': thread}});
      final sent = _message(p);
      _messages[chatId] = _withReplies([for (final x in messagesOf(chatId)) x.id == local ? sent : x]);
      _last[chatId] = sent;
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
    final now = DateTime.now();
    _readAt[chatId] = now;
    _chats = [for (final c in _chats) c.id == chatId ? c.copyWith(unread: 0) : c];
    notifyListeners();
    try {
      await _call('PATCH', '$chatBase/users/me/$chatId/spaceReadState',
          query: {'updateMask': 'lastReadTime'}, body: {'lastReadTime': now.toUtc().toIso8601String()});
    } catch (_) {}
  }

  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine;

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    final mine = messagesOf(chatId).any((m) => m.id == messageId && m.mine);
    if (!mine) return super.deleteMessage(chatId, messageId);
    try {
      await _call('DELETE', '$chatBase/$messageId');
      _messages[chatId] = [for (final x in messagesOf(chatId)) if (x.id != messageId) x];
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (!remove) {
      await _call('POST', '$chatBase/$messageId/reactions', body: {'emoji': {'unicode': emoji}});
    } else {
      final r = await _get('$chatBase/$messageId/reactions', {'filter': 'emoji.unicode = "$emoji" AND user.name = "users/me"'});
      for (final x in ((r['reactions'] as List?) ?? const []).cast<Map>()) {
        await _call('DELETE', '$chatBase/${x['name']}');
      }
    }
    _messages[chatId] = [
      for (final m in messagesOf(chatId))
        if (m.id == messageId) _reacted(m, emoji, remove) else m,
    ];
    notifyListeners();
  }

  /// [m] with this account's [emoji] put on or taken off: what is shown at once, before Google answers.
  static InboxMessage _reacted(InboxMessage m, String emoji, bool remove) {
    final rs = [...m.reactions];
    final i = rs.indexWhere((r) => r.emoji == emoji);
    if (remove) {
      if (i >= 0) rs[i].count <= 1 ? rs.removeAt(i) : rs[i] = InboxReaction(emoji: emoji, count: rs[i].count - 1);
    } else {
      i >= 0 ? rs[i] = InboxReaction(emoji: emoji, count: rs[i].count + 1, mine: true) : rs.add(InboxReaction(emoji: emoji, mine: true));
    }
    return InboxMessage(id: m.id, text: m.text, date: m.date, mine: m.mine, sender: m.sender, senderId: m.senderId, state: m.state, reactions: rs,
        replyTo: m.replyTo, replyText: m.replyText, replySender: m.replySender);
  }

  // --- calls ----------------------------------------------------------------------------------------------------------

  /// A call worked: the wait after a 429 is over.
  void _calm() {
    _wait = Duration.zero;
    _pausedUntil = null;
  }

  /// Takes a failure: a 429 pauses everything (as long as Google asks, else doubling up to ten minutes), access
  /// taken away signs out, and the words go to the page.
  void _setError(Object e) {
    if (e is _Status && e.code == 429) {
      final asked = e.retryAfter;
      _wait = asked ?? (_wait == Duration.zero ? _idle : (_wait * 2 > const Duration(minutes: 10) ? const Duration(minutes: 10) : _wait * 2));
      _pausedUntil = DateTime.now().add(_wait);
    }
    if (e is _Revoked) {
      _tick?.cancel();
      _openTick?.cancel();
      _forget();
    }
    _error = _plain(e);
    notifyListeners();
  }

  /// An access token that is good now: refreshed with the refresh token where it ran out.
  Future<String> _token({bool force = false}) async {
    final a = _access;
    if (!force && a != null && DateTime.now().isBefore(_accessUntil)) return a;
    final refresh = _refresh;
    if (refresh == null) throw const _Revoked();
    try {
      final t = await _form(tokenUrl, {'grant_type': 'refresh_token', 'refresh_token': refresh, 'client_id': clientId, 'client_secret': clientSecret});
      _access = t['access_token'] as String?;
      _accessUntil = DateTime.now().add(Duration(seconds: ((t['expires_in'] as num?) ?? 3600).toInt() - 60));
      if (_access == null) throw const _Revoked();
      return _access!;
    } on _Status catch (e) {
      if (e.code == 400 || e.code == 401) throw const _Revoked();
      rethrow;
    }
  }

  Future<Map> _get(String url, [Map<String, String>? query]) => _call('GET', url, query: query);

  Future<Map> _getUrl(String url) => _call('GET', url);

  /// A call with the access token; on a 401 the token is asked for afresh and the call made once more.
  Future<Map> _call(String method, String url, {Map<String, String>? query, Object? body}) async {
    var uri = Uri.parse(url);
    if (query != null) uri = uri.replace(queryParameters: {...uri.queryParameters, ...query});
    try {
      final r = await _raw(method, uri, bearer: await _token(), body: body);
      return r is Map ? r : const {};
    } on _Status catch (e) {
      if (e.code != 401) rethrow;
      final r = await _raw(method, uri, bearer: await _token(force: true), body: body);
      return r is Map ? r : const {};
    }
  }

  /// A form POST to Google's OAuth endpoints.
  Future<Map> _form(String url, Map<String, String> fields) async {
    final r = await _raw('POST', Uri.parse(url), form: fields);
    return r is Map ? r : const {};
  }

  /// One HTTP call, with [body] as JSON or [form] as a form; the answer's JSON. Throws on 400 and up.
  Future<Object?> _raw(String method, Uri uri, {String? bearer, Object? body, Map<String, String>? form}) async {
    final req = await _client.openUrl(method, uri);
    req.headers.set('accept', 'application/json');
    if (bearer != null) req.headers.set('authorization', 'Bearer $bearer');
    if (form != null) {
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.add(utf8.encode(Uri(queryParameters: form).query));
    } else if (body != null) {
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
      final err = m['error'];
      final words = err is Map ? err['message'] as String? : (m['error_description'] as String? ?? err as String?);
      final after = int.tryParse(res.headers.value('retry-after') ?? '');
      throw _Status(res.statusCode, words, retryAfter: after == null ? null : Duration(seconds: after));
    }
    return json;
  }

  /// What went wrong, in words for the page.
  static String _plain(Object e) {
    if (e is _Said) return e.message;
    if (e is _Revoked) return 'Google no longer lets Uplink into your Google Chat (the access was removed or ran out). Sign in again.';
    if (e is _Status) {
      if (e.code == 401) return 'Google did not let Uplink in. Sign in again.';
      if (e.code == 403) return e.error ?? 'Google Chat refused. Your organisation may not allow Uplink, or this isn\'t a Google Workspace account.';
      if (e.code == 429) return 'Google Chat asks to slow down. Uplink will try again shortly.';
      return e.error ?? 'Google answered ${e.code}.';
    }
    if (e is SocketException || e is TimeoutException || e is HandshakeException) return 'Google can\'t be reached just now.';
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
    _closeListener();
    super.dispose();
  }
}

/// An answer of 400 or more: its status, Google's message, and how long it asked to wait where it did (429).
class _Status implements Exception {
  const _Status(this.code, this.error, {this.retryAfter});
  final int code;
  final String? error;
  final Duration? retryAfter;
  @override
  String toString() => 'Google Chat $code ${error ?? ''}'.trim();
}

/// Google no longer takes the refresh token: the access was removed or ran out, and only signing in again mends it.
class _Revoked implements Exception {
  const _Revoked();
}

/// A failure already in words for the person.
class _Said implements Exception {
  const _Said(this.message);
  final String message;
  @override
  String toString() => message;
}
