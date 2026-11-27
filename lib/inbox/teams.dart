import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_state.dart';
import 'inbox.dart';

/// Microsoft Teams chats, read and answered from here (Matt, 2026-11-17: "Let's add support for matrix, microsoft teams
/// and google chat").
///
/// Teams through Microsoft Graph (v1.0), on this device alone: nothing goes through Uplink's servers. Signing in is
/// Microsoft's device code flow with a public client (no secret): Uplink asks for a short code, the person types it on
/// microsoft.com/devicelogin in the browser and approves, and Uplink is given a token. Only the refresh token and the
/// account are kept (AppState `teams_session`); the access token is asked for again as it runs out.
///
/// Work and school accounts only: Graph's chat APIs don't serve personal Microsoft accounts (Teams free). Some
/// organisations let no app in until their IT admin approves it.
///
/// There is no push: the chats are asked for every [_idle], the open one every [_open], and a 429 waits as long as
/// Graph's Retry-After says.
class Teams extends InboxNetwork {
  Teams({
    String? clientId,
    this.login = 'https://login.microsoftonline.com/organizations',
    this.graph = 'https://graph.microsoft.com/v1.0',
    this.folder,
    HttpClient? client,
    this.slowDown = const Duration(seconds: 5),
    this.soon = false,
  })  : clientId = clientId ?? const String.fromEnvironment('GHOST_TEAMS_CLIENT_ID'),
        _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 10));

  /// The app registration's id in Microsoft Entra; empty in a build made without one.
  final String clientId;

  /// The sign-in authority (`…/organizations`, work and school accounts) and Graph, each injectable for a test.
  final String login, graph;

  /// Where pictures in messages are kept once brought down; a folder in the system's temporary one by default.
  final String? folder;

  /// How much longer to wait between polls when Microsoft says `slow_down`.
  final Duration slowDown;

  final HttpClient _client;

  @override
  final bool soon;

  // What Uplink asks leave to do, the page the code is typed on, and how often the chats and the open one are asked for.
  static const scopes = 'offline_access User.Read Chat.ReadWrite ChatMessage.Send';
  static const devicePage = 'https://microsoft.com/devicelogin';
  static const _idle = Duration(seconds: 30);
  static const _open = Duration(seconds: 6);

  // What the page says for the two refusals that are not the person's mistake.
  static const workOnly = 'Microsoft Teams works with work and school accounts only. Personal Microsoft accounts (Teams free) can\'t be read by other apps.';
  static const adminNeeded = 'Your organisation needs its IT admin to approve Uplink before you can sign in. Ask them to allow it in Microsoft Entra, then try again.';

  @override
  String get id => 'teams';
  @override
  String get name => 'Microsoft Teams';

  AppState? _app;
  InboxState _state = InboxState.signedOut;
  String? _error;

  /// The refresh token kept; the access token and when it runs out, held only while the app runs.
  String? _refresh, _access;
  DateTime _accessUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Who signed in: Graph's user id, their tenant, and their address (or name) to show.
  String? _me, _tenant, _account;

  /// The code to type on Microsoft's page, while signing in.
  TeamsCode? _code;
  Timer? _codePoll;

  List<InboxChat> _chats = const [];
  final Map<String, List<InboxMessage>> _messages = {};
  /// Each chat's link to the page of messages before the oldest held, as Graph gave it; null once there are none.
  final Map<String, String?> _olderLink = {};

  /// Pictures in messages (a hosted content's address), by the number [InboxMedia.fileId] gives them, and where each
  /// is once brought down.
  final Map<int, String> _hosted = {};
  final Map<int, String> _files = {};

  Timer? _tick, _openTick;
  String? _watching;
  int _sent = 0;

  /// Graph asked Uplink to wait (429) until then.
  DateTime _wait = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  InboxState get state => clientId.isEmpty ? InboxState.unavailable : _state;
  @override
  InboxStep get step => _code != null && _state == InboxState.signingIn ? InboxStep.elsewhere : InboxStep.none;
  @override
  String? get error => clientId.isEmpty ? 'This build has no Microsoft app id yet, so Teams can\'t sign in here.' : _error;
  @override
  String? get account => _account;
  @override
  List<InboxChat> get chats => _chats;
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];

  /// The code being shown, while signing in.
  TeamsCode? get code => _code;

  /// The open chat's poll and the list's wait for Graph's Retry-After; for a test.
  DateTime get waitingUntil => _wait;

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (clientId.isEmpty) return;
    final kept = app.choice('teams_session', '');
    if (kept.isEmpty) return;
    try {
      final s = jsonDecode(kept) as Map;
      _refresh = s['refresh'] as String?;
      _me = s['me'] as String?;
      _tenant = s['tenant'] as String?;
      _account = s['account'] as String?;
      if (_refresh == null || _me == null) return;
      _ready();
    } catch (_) {}
  }

  // --- signing in -----------------------------------------------------------------------------------------------------

  /// Asks Microsoft for a code to type on [TeamsCode.page], and waits for it to be approved there. Null where it
  /// can't (the reason in [error]).
  Future<TeamsCode?> begin() async {
    if (clientId.isEmpty) return null;
    _codePoll?.cancel();
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final r = await _form('$login/oauth2/v2.0/devicecode', {'client_id': clientId, 'scope': scopes});
      final device = r['device_code'] as String?, user = r['user_code'] as String?;
      if (device == null || user == null) throw const _Said('Microsoft did not give a sign-in code. Try again.');
      final code = TeamsCode(
        user: user,
        page: (r['verification_uri'] as String?) ?? devicePage,
        until: DateTime.now().add(Duration(seconds: _int(r['expires_in'], 900))),
      );
      _code = code;
      notifyListeners();
      _schedulePoll(device, Duration(seconds: _int(r['interval'], 5)));
      return code;
    } catch (e) {
      _state = InboxState.signedOut;
      _code = null;
      _error = _plain(e);
      notifyListeners();
      return null;
    }
  }

  /// Stops waiting for a code to be approved.
  void cancel() {
    _codePoll?.cancel();
    _code = null;
    if (_state == InboxState.signingIn) _state = InboxState.signedOut;
    notifyListeners();
  }

  /// Asks again, [every] from now, whether the code has been approved.
  void _schedulePoll(String device, Duration every) {
    _codePoll?.cancel();
    _codePoll = Timer(every, () => _poll(device, every));
  }

  /// One asking of Microsoft whether the person has approved the code yet: a token where they have, another wait
  /// where they haven't, the sign-in ended where the code ran out or was refused.
  Future<void> _poll(String device, Duration every) async {
    if (_state != InboxState.signingIn || _code == null) return;
    final Map r;
    try {
      r = await _form('$login/oauth2/v2.0/token', {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': clientId,
        'device_code': device,
      }, throwOnError: false);
    } catch (_) {
      // No answer this time (the network away): ask again, until the code runs out.
      if (_code != null && DateTime.now().isBefore(_code!.until)) _schedulePoll(device, every);
      return;
    }
    if (_state != InboxState.signingIn || _code == null) return;
    final err = r['error'] as String?;
    if (err == null && r['access_token'] != null) {
      try {
        _took(r);
        final me = await _call('GET', '$graph/me?\$select=id,displayName,userPrincipalName,mail');
        _me = me['id'] as String?;
        _account = (me['userPrincipalName'] ?? me['mail'] ?? me['displayName']) as String?;
        _tenant ??= _tid(_access);
        if (_me == null) throw const _Said('Microsoft did not say who signed in. Try again.');
        _code = null;
        _save();
        _ready();
      } catch (e) {
        _access = _refresh = null;
        _code = null;
        _state = InboxState.signedOut;
        _error = _plain(e);
        notifyListeners();
      }
      return;
    }
    switch (err) {
      case 'authorization_pending':
        _schedulePoll(device, every);
      case 'slow_down':
        _schedulePoll(device, every + slowDown);
      default:
        _code = null;
        _state = InboxState.signedOut;
        _error = _tokenError(r);
        notifyListeners();
    }
  }

  /// A token answer's words: the codes a refused sign-in comes with, in plain words.
  static String _tokenError(Map r) {
    final err = r['error'] as String?;
    final desc = '${r['error_description'] ?? ''}';
    final codes = [for (final c in (r['error_codes'] as List? ?? const [])) '$c'];
    bool has(String code) => codes.contains(code) || desc.contains('AADSTS$code');
    if (has('65001') || has('90094') || has('90095') || desc.contains('admin approval') || desc.contains('needs permission')) return adminNeeded;
    if (err == 'expired_token' || has('70020')) return 'The code ran out before it was used. Ask for a new one.';
    if (err == 'authorization_declined' || has('70019') || has('65004')) return 'Sign-in was declined on Microsoft\'s page.';
    if (has('50020') || has('9002331') || desc.contains('Microsoft Account') || desc.contains('personal')) return workOnly;
    if (has('700016')) return 'Microsoft doesn\'t know this build\'s app id. It needs to be registered in Microsoft Entra.';
    if (err == 'invalid_grant') return 'Microsoft wants you to sign in again.';
    return desc.isNotEmpty ? desc.split('\r\n').first : 'Microsoft refused the sign-in ($err).';
  }

  /// Takes a token answer: the access token and when it runs out, and a new refresh token where one came.
  void _took(Map r) {
    _access = r['access_token'] as String?;
    final refresh = r['refresh_token'] as String?;
    if (refresh != null) _refresh = refresh;
    // A minute's margin, so a token isn't used as it runs out.
    _accessUntil = DateTime.now().add(Duration(seconds: _int(r['expires_in'], 3600) - 60));
  }

  /// Saves what signs in again next time: the refresh token and who signed in, never the access token.
  void _save() => _app?.set('teams_session', jsonEncode({'refresh': _refresh, 'me': _me, 'tenant': _tenant, 'account': _account}));

  /// An access token that has not run out, from the refresh token where it has.
  Future<String> _token() async {
    final a = _access;
    if (a != null && DateTime.now().isBefore(_accessUntil)) return a;
    final refresh = _refresh;
    if (refresh == null) throw const _Said('Sign in to Microsoft Teams again.');
    final r = await _form('$login/oauth2/v2.0/token', {'grant_type': 'refresh_token', 'client_id': clientId, 'refresh_token': refresh, 'scope': scopes}, throwOnError: false);
    if (r['access_token'] == null) {
      _access = null;
      throw _Said(_tokenError(r));
    }
    _took(r);
    _tenant ??= _tid(_access);
    _save();
    return _access!;
  }

  /// The tenant in an access token, where it is a JWT that says.
  static String? _tid(String? token) {
    final parts = token?.split('.') ?? const [];
    if (parts.length != 3) return null;
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
      return claims['tid'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    _tick?.cancel();
    _openTick?.cancel();
    _codePoll?.cancel();
    _refresh = _access = _me = _tenant = _account = null;
    _code = null;
    _chats = const [];
    _messages.clear();
    _olderLink.clear();
    _state = InboxState.signedOut;
    _error = null;
    _app?.set('teams_session', '');
    notifyListeners();
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

  @override
  set watching(String? chatId) {
    _watching = chatId;
    _openTick?.cancel();
    if (chatId == null || _state != InboxState.ready) return;
    _openTick = Timer.periodic(_open, (_) => load(chatId));
  }

  // --- chats ----------------------------------------------------------------------------------------------------------

  /// Asks for the chats again now (unless Graph asked Uplink to wait).
  Future<void> refresh() async {
    if (_state != InboxState.ready || DateTime.now().isBefore(_wait)) return;
    try {
      final next = <InboxChat>[];
      String? url = '$graph/me/chats?\$expand=members,lastMessagePreview&\$orderby=lastMessagePreview/createdDateTime%20desc&\$top=50';
      // Four pages at most: the 200 latest chats.
      for (var page = 0; url != null && page < 4; page++) {
        final r = await _call('GET', url);
        for (final c in (r['value'] as List? ?? const [])) {
          final chat = _chat(c as Map);
          if (chat != null) next.add(chat);
        }
        url = r['@odata.nextLink'] as String?;
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

  /// A chat as Graph lists it, with its members. Learns this account's tenant from its own membership on the way.
  InboxChat? _chat(Map c) {
    final cid = c['id'] as String?;
    if (cid == null) return null;
    final members = [for (final m in (c['members'] as List? ?? const [])) m as Map];
    for (final m in members) {
      if (m['userId'] == _me && _tenant == null) _tenant = m['tenantId'] as String?;
    }
    final others = [for (final m in members) if (m['userId'] != _me) m];
    final type = c['chatType'] as String? ?? 'group';
    final topic = (c['topic'] as String?)?.trim();
    final names = [for (final m in others) ((m['displayName'] as String?)?.trim().isNotEmpty ?? false) ? (m['displayName'] as String).trim() : 'Someone'];
    final title = topic != null && topic.isNotEmpty ? topic : (names.isEmpty ? 'Just you' : names.join(', '));
    final last = c['lastMessagePreview'] as Map?;
    final lastAt = _date(last?['createdDateTime']) ?? _date(c['lastUpdatedDateTime']) ?? _date(c['createdDateTime']) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final lastFrom = ((last?['from'] as Map?)?['user'] as Map?)?['id'];
    final read = _date((c['viewpoint'] as Map?)?['lastMessageReadDateTime']);
    final fromMe = lastFrom != null && lastFrom == _me;
    final unread = last != null && !fromMe && (read == null || lastAt.isAfter(read)) ? 1 : 0;
    var snippet = last == null ? '' : _bodyText(last['body'] as Map?);
    if (last?['isDeleted'] == true) snippet = 'Message deleted';
    if (type != 'oneOnOne' && !fromMe && snippet.isNotEmpty) {
      final who = ((last?['from'] as Map?)?['user'] as Map?)?['displayName'] as String?;
      if (who != null && who.isNotEmpty) snippet = '${who.split(' ').first}: $snippet';
    }
    return InboxChat(network: id, id: cid, title: title, date: lastAt, snippet: snippet, unread: unread, group: type != 'oneOnOne', lastFromMe: fromMe);
  }

  // --- messages -------------------------------------------------------------------------------------------------------

  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready || DateTime.now().isBefore(_wait)) return;
    final link = older ? _olderLink[chatId] : '$graph/chats/${_seg(chatId)}/messages?\$top=50';
    if (link == null) return;
    try {
      final r = await _call('GET', link);
      final held = {for (final m in messagesOf(chatId)) if (m.state == 'sent') m.id: m};
      if (!older) {
        // The newest page again: those in it replace what was held of them, and those deleted since go.
        for (final raw in (r['value'] as List? ?? const [])) {
          held.remove((raw as Map)['id']);
        }
      }
      for (final raw in (r['value'] as List? ?? const [])) {
        final m = _message(chatId, raw as Map);
        if (m != null) held[m.id] = m;
      }
      if (older || !_olderLink.containsKey(chatId)) _olderLink[chatId] = r['@odata.nextLink'] as String?;
      final pending = [for (final m in messagesOf(chatId)) if (m.state != 'sent') m];
      _messages[chatId] = [...held.values.toList()..sort((a, b) => a.date.compareTo(b.date)), ...pending];
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = _plain(e);
      notifyListeners();
    }
  }

  /// A message as Graph gives it; null for a deleted one, or an event Graph doesn't describe.
  InboxMessage? _message(String chatId, Map p) {
    final mid = p['id'] as String?;
    if (mid == null || p['deletedDateTime'] != null) return null;
    final date = _date(p['createdDateTime']) ?? DateTime.now();
    final type = p['messageType'] as String? ?? 'message';
    if (type != 'message') {
      // A member added, the chat renamed, a call: a plain line where Graph says what, else nothing.
      final what = _event(p['eventDetail'] as Map?);
      return what == null ? null : InboxMessage(id: mid, text: what, date: date, mine: false, sender: '', event: true);
    }
    final user = (p['from'] as Map?)?['user'] as Map?;
    final mine = user != null && user['id'] == _me;
    final body = p['body'] as Map?;
    var text = _bodyText(body);
    final media = <InboxMedia>[];
    String? replyTo, replyText, replySender;
    // Pictures pasted into a message: hosted contents, fetched with the token.
    for (final m in RegExp(r'''<img[^>]*src="([^"]*hostedContents/[^"]*)"''').allMatches('${body?['content'] ?? ''}')) {
      final url = m.group(1)!.replaceAll('&amp;', '&');
      final fid = _fileId(url);
      _hosted[fid] = url;
      media.add(InboxMedia(kind: 'photo', fileId: fid, path: _files[fid], name: 'Picture'));
    }
    final files = <String>[];
    for (final a in (p['attachments'] as List? ?? const [])) {
      final att = a as Map;
      final kind = att['contentType'] as String? ?? '';
      if (kind == 'messageReference') {
        try {
          final ref = jsonDecode(att['content'] as String? ?? '{}') as Map;
          replyTo = (ref['messageId'] ?? att['id']) as String?;
          replyText = ref['messagePreview'] as String?;
          replySender = (((ref['messageSender'] as Map?)?['user'] as Map?)?['displayName']) as String?;
        } catch (_) {
          replyTo = att['id'] as String?;
        }
      } else if (kind == 'reference' || kind.startsWith('image/') || kind.startsWith('application/')) {
        files.add(att['name'] as String? ?? 'a file');
      } else if (kind.startsWith('application/vnd.microsoft.card')) {
        files.add('a card');
      }
    }
    if (files.isNotEmpty) text = [if (text.isNotEmpty) text, for (final f in files) '[$f]'].join('\n');
    if (text.isEmpty && media.isEmpty) text = '[a message Uplink can\'t show]';
    return InboxMessage(
      id: mid,
      text: text,
      date: date,
      mine: mine,
      sender: mine ? '' : (user?['displayName'] as String? ?? ''),
      senderId: '${user?['id'] ?? ''}',
      media: media,
      reactions: _reactions(p['reactions'] as List?),
      replyTo: replyTo,
      replyText: replyText,
      replySender: replySender,
    );
  }

  /// The number a hosted picture goes by ([InboxMedia.fileId]): its address's hash, kept to 30 bits so it is never
  /// negative.
  static int _fileId(String url) => url.hashCode & 0x3fffffff;

  /// Graph's reactions, one a person, counted into one a kind, with this account's marked.
  List<InboxReaction> _reactions(List? raw) {
    final counts = <String, int>{};
    final mine = <String>{};
    for (final r in raw ?? const []) {
      final e = _emoji((r as Map)['reactionType'] as String? ?? '');
      counts[e] = (counts[e] ?? 0) + 1;
      if ((((r['user'] as Map?)?['user'] as Map?)?['id']) == _me) mine.add(e);
    }
    return [for (final e in counts.entries) InboxReaction(emoji: e.key, count: e.value, mine: mine.contains(e.key))];
  }

  /// Teams' older reaction names, as emoji; any other is already one.
  static const _named = {'like': '👍', 'heart': '❤️', 'laugh': '😂', 'surprised': '😮', 'sad': '😢', 'angry': '😡'};
  static String _emoji(String type) => _named[type] ?? type;

  /// A system message's event in a line ("Ana joined", "Call ended"); null for a kind not written out here.
  static String? _event(Map? e) {
    if (e == null) return null;
    final kind = '${e['@odata.type'] ?? ''}';
    String who(List? people) => [for (final m in people ?? const []) (m as Map)['displayName'] ?? 'Someone'].join(', ');
    if (kind.endsWith('membersAddedEventMessageDetail')) return '${who(e['members'] as List?)} joined';
    if (kind.endsWith('membersDeletedEventMessageDetail')) return '${who(e['members'] as List?)} left';
    if (kind.endsWith('chatRenamedEventMessageDetail')) return 'Chat renamed to ${e['chatDisplayName'] ?? ''}'.trim();
    if (kind.endsWith('callEndedEventMessageDetail')) return 'Call ended';
    if (kind.endsWith('callStartedEventMessageDetail')) return 'Call started';
    return null;
  }

  /// A message body's words: HTML made plain, line breaks kept, markup dropped.
  static String _bodyText(Map? body) {
    final content = '${body?['content'] ?? ''}';
    return body?['contentType'] == 'html' ? plainOf(content) : content.trim();
  }

  /// HTML as plain words: breaks and paragraphs as new lines, lists as bullets, the rest of the markup dropped.
  static String plainOf(String html) {
    var s = html.replaceAll(RegExp(r'\r?\n'), ' ');
    s = s.replaceAll(RegExp(r'<attachment[^>]*>\s*</attachment>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    s = s.replaceAll(RegExp(r'</(p|div|ul|ol|h[1-6]|blockquote|tr)>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
        .replaceAll('&amp;', '&');
    s = s.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim()).join('\n');
    return s.replaceAll(RegExp(r'\n\n+(?=• )'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  @override
  void wantFile(int fileId) => unawaited(fileOf(fileId));

  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null) return known;
    final url = _hosted[fileId];
    if (url == null || _state != InboxState.ready) return null;
    final dir = folder ?? '${Directory.systemTemp.path}/ghost-teams';
    final path = '$dir/$fileId.img';
    if (File(path).existsSync()) return _files[fileId] = path;
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set('authorization', 'Bearer ${await _token()}');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) {
        await res.drain<void>();
        return null;
      }
      await Directory(dir).create(recursive: true);
      await res.pipe(File(path).openWrite());
      _files[fileId] = path;
      for (final e in _messages.entries) {
        _messages[e.key] = [for (final m in e.value) m.media.any((x) => x.fileId == fileId) ? _withFile(m, fileId, path) : m];
      }
      notifyListeners();
      return path;
    } catch (_) {
      return null;
    }
  }

  static InboxMessage _withFile(InboxMessage m, int fileId, String path) => InboxMessage(
        id: m.id, text: m.text, date: m.date, mine: m.mine, sender: m.sender, senderId: m.senderId, state: m.state, reactions: m.reactions, event: m.event,
        replyTo: m.replyTo, replyText: m.replyText, replySender: m.replySender, media: [for (final x in m.media) x.withPath(fileId, path)]);

  // --- sending --------------------------------------------------------------------------------------------------------

  @override
  Future<void> send(String chatId, String text) => _send(chatId, text);

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) => _send(chatId, text, replyTo: messageId);

  /// Sends [text], as a reply to [replyTo] where given: shown at once as "sending", then as Graph has it, or "failed".
  Future<void> _send(String chatId, String text, {String? replyTo}) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final local = 'local-${++_sent}';
    final quoted = replyTo == null ? null : messagesOf(chatId).where((m) => m.id == replyTo).firstOrNull;
    _messages[chatId] = [
      ...messagesOf(chatId),
      InboxMessage(id: local, text: text, date: DateTime.now(), mine: true, state: 'sending', replyTo: quoted?.id, replyText: quoted?.text, replySender: quoted?.sender),
    ];
    notifyListeners();
    try {
      final Map<String, Object?> body;
      if (quoted == null) {
        body = {'body': {'contentType': 'text', 'content': text}};
      } else {
        // A reply quotes the message it answers: an attachment of kind messageReference, placed in an HTML body.
        String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
        body = {
          'body': {'contentType': 'html', 'content': '<attachment id="${esc(quoted.id)}"></attachment>${esc(text).replaceAll('\n', '<br>')}'},
          'attachments': [
            {
              'id': quoted.id,
              'contentType': 'messageReference',
              'content': jsonEncode({
                'messageId': quoted.id,
                'messagePreview': quoted.text.length > 200 ? quoted.text.substring(0, 200) : quoted.text,
                'messageSender': {
                  'user': {'displayName': quoted.mine ? (_account ?? '') : quoted.sender, 'userIdentityType': 'aadUser'},
                },
              }),
            },
          ],
        };
      }
      final r = await _call('POST', '$graph/chats/${_seg(chatId)}/messages', body: body);
      final sent = _message(chatId, r) ?? InboxMessage(id: r['id'] as String? ?? local, text: text, date: DateTime.now(), mine: true);
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
      await _call('POST', '$graph/chats/${_seg(chatId)}/markChatReadForUser', body: {
        'user': {'id': _me, if (_tenant != null) 'tenantId': _tenant},
      });
    } catch (_) {}
  }

  @override
  bool get canReact => true;

  @override
  List<String> get reactionChoices => const ['👍', '❤️', '😂', '😮', '😢', '😡', '🙏', '🔥', '🎉'];

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    await _call('POST', '$graph/chats/${_seg(chatId)}/messages/${_seg(messageId)}/${remove ? 'unsetReaction' : 'setReaction'}', body: {'reactionType': emoji});
    _messages[chatId] = [
      for (final m in messagesOf(chatId))
        if (m.id != messageId) m else _withReactions(m, _changed(m.reactions, emoji, remove)),
    ];
    notifyListeners();
  }

  /// [now] with this account's [emoji] put on or taken off: what is shown at once, before Graph answers.
  static List<InboxReaction> _changed(List<InboxReaction> now, String emoji, bool remove) {
    final out = <InboxReaction>[];
    var found = false;
    for (final r in now) {
      if (r.emoji != emoji) {
        out.add(r);
        continue;
      }
      found = true;
      if (remove && r.mine) {
        if (r.count > 1) out.add(InboxReaction(emoji: emoji, count: r.count - 1));
      } else if (!remove && !r.mine) {
        out.add(InboxReaction(emoji: emoji, count: r.count + 1, mine: true));
      } else {
        out.add(r);
      }
    }
    if (!found && !remove) out.add(InboxReaction(emoji: emoji, mine: true));
    return out;
  }

  static InboxMessage _withReactions(InboxMessage m, List<InboxReaction> reactions) => InboxMessage(
        id: m.id, text: m.text, date: m.date, mine: m.mine, sender: m.sender, senderId: m.senderId, state: m.state, media: m.media, event: m.event,
        replyTo: m.replyTo, replyText: m.replyText, replySender: m.replySender, reactions: reactions);

  /// Your own messages are deleted in Teams for everyone (Graph's softDelete); anyone else's only left out here.
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine && message.state == 'sent';

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    final mine = messagesOf(chatId).any((m) => m.id == messageId && m.mine);
    if (!mine || !forEveryone || _me == null) return super.deleteMessage(chatId, messageId);
    try {
      await _call('POST', '$graph/users/${_seg(_me!)}/chats/${_seg(chatId)}/messages/${_seg(messageId)}/softDelete');
      _messages[chatId] = [for (final x in messagesOf(chatId)) if (x.id != messageId) x];
    } catch (e) {
      _error = _plain(e);
    }
    notifyListeners();
  }

  // --- calls ----------------------------------------------------------------------------------------------------------

  /// A form posted to the sign-in authority; its answer, the error ones too where [throwOnError] is false.
  Future<Map> _form(String url, Map<String, String> fields, {bool throwOnError = true}) async {
    final req = await _client.postUrl(Uri.parse(url));
    req.headers.set('accept', 'application/json');
    req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    req.add(utf8.encode(Uri(queryParameters: fields).query));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    Map json;
    try {
      final j = text.isEmpty ? const {} : jsonDecode(text);
      json = j is Map ? j : const {};
    } catch (_) {
      json = const {};
    }
    if (res.statusCode >= 400 && throwOnError) throw _Said(_tokenError(json.isEmpty ? {'error': 'http_${res.statusCode}'} : json));
    return json;
  }

  /// A call to Graph with the access token: renewed once on a 401, and a 429 kept so Uplink waits as Graph asks.
  Future<Map> _call(String method, String url, {Object? body, bool again = true}) async {
    final req = await _client.openUrl(method, Uri.parse(url));
    req.headers.set('accept', 'application/json');
    req.headers.set('authorization', 'Bearer ${await _token()}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    } else if (method == 'POST') {
      req.headers.contentLength = 0;
    }
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    Object? json;
    try {
      json = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
    } catch (_) {
      json = null;
    }
    if (res.statusCode == 401 && again) {
      _access = null;
      return _call(method, url, body: body, again: false);
    }
    if (res.statusCode == 429) {
      final after = int.tryParse(res.headers.value('retry-after') ?? '') ?? 30;
      _wait = DateTime.now().add(Duration(seconds: after));
    }
    if (res.statusCode >= 400) {
      final e = json is Map ? json['error'] : null;
      throw _Status(res.statusCode, e is Map ? e['code'] as String? : null, e is Map ? e['message'] as String? : null);
    }
    return json is Map ? json : const {};
  }

  /// An id as one part of a Graph address: Teams' ids (`19:…@thread.v2`) keep their colon and at, as Graph's own
  /// examples write them; anything else unsafe is escaped.
  static String _seg(String id) => Uri.encodeComponent(id).replaceAll('%3A', ':').replaceAll('%40', '@');

  // Graph's time (ISO 8601) as local time, and a number that may have come as a string.
  static DateTime? _date(Object? s) => s is String ? DateTime.tryParse(s)?.toLocal() : null;
  static int _int(Object? v, int fallback) => v is int ? v : int.tryParse('${v ?? ''}') ?? fallback;

  /// What went wrong, in words for the page.
  static String _plain(Object e) {
    if (e is _Said) return e.message;
    if (e is _Status) {
      if (e.code == 401) return 'Microsoft did not let Uplink in. Sign in to Teams again.';
      if (e.code == 403) {
        if ((e.message ?? '').contains('MSA') || (e.message ?? '').toLowerCase().contains('personal')) return workOnly;
        return e.message ?? 'Microsoft says this account may not do that.';
      }
      if (e.code == 404) return 'Teams can\'t find that chat or message any more.';
      if (e.code == 429) return 'Microsoft asks Uplink to slow down. It will try again shortly.';
      return e.message ?? 'Microsoft Graph answered ${e.code}.';
    }
    if (e is SocketException || e is TimeoutException || e is HandshakeException) return 'Microsoft can\'t be reached just now.';
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
    _codePoll?.cancel();
    super.dispose();
  }
}

/// A code to type on Microsoft's page ([page]) to sign in, good until [until].
class TeamsCode {
  const TeamsCode({required this.user, required this.page, required this.until});
  final String user;
  final String page;
  final DateTime until;
}

/// An answer of 400 or more: its status, and Graph's error code and message.
class _Status implements Exception {
  const _Status(this.code, this.error, this.message);
  final int code;
  final String? error, message;
  @override
  String toString() => 'Microsoft Graph $code ${error ?? ''} ${message ?? ''}'.trim();
}

/// A failure already in words for the person.
class _Said implements Exception {
  const _Said(this.message);
  final String message;
  @override
  String toString() => message;
}
