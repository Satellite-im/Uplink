import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../desktop/store.dart';
import 'inbox.dart';
import 'kept_writer.dart';
import 'td_json.dart';

/// Telegram, as a Telegram app: TDLib (Telegram's own client library, lib/inbox/td_json.dart) signed in to the
/// person's account, its private chats and groups in a tab of the list, and replies sent from here.
///
/// Signing in is Telegram's own: a phone number, the code Telegram sends to the person's other Telegram apps (or by
/// text), and the two-step password where the account has one. TDLib keeps the session in its database in this app's
/// own folder; nothing about it leaves the device but to Telegram.
///
/// A Telegram app needs an app id and hash of its own, registered at my.telegram.org (Telegram's API terms: one per
/// developer; never the sample ones). They are given to the build (`--dart-define=TELEGRAM_API_ID=…` and
/// `TELEGRAM_API_HASH`, which tool/release.mjs and tool/release-mac.mjs read from ~/.config/ghostmessaging/telegram.env)
/// and are never in the repository. Without them, or without the library in the app, Telegram is [InboxState.unavailable].
class Telegram extends InboxNetwork {
  @override
  bool get official => true;

  // A private chat Telegram does not mark as a stranger's is a contact's: is_contact, or no "Report spam" bar.
  @override
  bool get marksStrangers => true;

  Telegram({this.transport, this.apiId = const int.fromEnvironment('TELEGRAM_API_ID'), this.apiHash = const String.fromEnvironment('TELEGRAM_API_HASH'), this.folder});

  /// A stand-in for TDLib, in tests. Null: TDLib itself, once [start] finds it.
  final Future<TdTransport?> Function()? transport;

  /// The app's own id and hash on Telegram, given at build time; 0 and empty in a build made without them.
  final int apiId;
  final String apiHash;

  /// Where TDLib keeps its database. Null: this app's own folder.
  final String? folder;

  @override
  String get id => 'telegram';
  @override
  String get name => 'Telegram';

  TdTransport? _td;
  StreamSubscription<Map<String, Object?>>? _sub;
  AppState? _app;
  InboxState _state = InboxState.unavailable;
  InboxStep _step = InboxStep.none;
  String? _error, _account, _passwordHint, _codeWhere;

  /// This account's own user id, from getMe.
  int? _meId;

  /// Requests to TDLib are numbered (`q<n>`, sent as "@extra"); each waits here for the answer that carries its key.
  int _asked = 0;
  final Map<String, Completer<Map<String, Object?>>> _waiting = {};

  /// What TDLib has said of each chat and user, by id.
  final Map<int, Map<String, Object?>> _chatsById = {};
  final Map<int, int> _order = {};
  final Map<int, String> _users = {};
  final Map<String, List<InboxMessage>> _messages = {};
  final Set<String> _exhausted = {};
  List<InboxChat> _chats = const [];
  String? _watching;

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _step;
  @override
  String? get error => _error;
  @override
  String? get account => _account;
  /// The chats the list shows: those in the main list that can be written in (private chats and groups, not
  /// channels), the newest first, as they stand among the texts.
  @override
  List<InboxChat> get chats {
    _settle();
    return _chats;
  }
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];

  /// The hint for the two-step password, where Telegram has one.
  String? get passwordHint => _passwordHint;

  /// Where the code was sent ("your Telegram app", "a text to …"), once asked.
  String? get codeWhere => _codeWhere;

  // --- signed in by the phone (Matt, 2026-11-16: "Build the Telegram phone sign-in approval"; before that, "It seems i
  // have to setup signal and telegram on each device is it possible to proxy through thr phone") ---------------------
  // A computer asks Telegram for a login link (requestQrCodeAuthentication), the phone's own signed-in session approves
  // it (confirmQrCodeAuthentication), and the computer has a session of its own: no number, no code. The link goes
  // from the computer to the phone over their sealed link (Sms.telegram on the computer, [answerComputer] on the phone).

  /// The login link Telegram gave this device to be approved elsewhere, while it waits (tg://login?token=…).
  String? get loginLink => _loginLink;
  String? _loginLink;
  Completer<String>? _linkWanted;

  /// Asks Telegram for a login link for this device, to be approved by another device signed in to the account; the
  /// link, or a [StateError] with Telegram's reason. Telegram renews the link every half minute while it waits.
  Future<String> askLoginLink() async {
    if (_td == null) await begin();
    final wanted = _linkWanted = Completer<String>();
    final r = await _ask({'@type': 'requestQrCodeAuthentication', 'other_user_ids': const <int>[]});
    if (r['@type'] == 'error') {
      _linkWanted = null;
      throw StateError(_plain(r));
    }
    return wanted.future.timeout(const Duration(seconds: 20), onTimeout: () => throw StateError('Telegram didn\'t give a login link'));
  }

  /// On the phone: approves [link] (another device's login link) with this signed-in session. Null when approved, or
  /// why not.
  Future<String?> approveLogin(String link) async {
    if (_state != InboxState.ready) return 'Telegram isn\'t signed in on your phone.';
    if (!RegExp(r'^tg://login\?token=[A-Za-z0-9_\-=]+$').hasMatch(link.trim())) return 'That isn\'t a Telegram login link.';
    final r = await _ask({'@type': 'confirmQrCodeAuthentication', 'link': link.trim()});
    return r['@type'] == 'session' ? null : (r['@type'] == 'error' ? _plain(r) : 'Telegram didn\'t approve it.');
  }

  /// On the phone: what its paired computer asks of its Telegram (android DartAsk "telegram"). `status`: whether it is
  /// signed in, and as whom. `approve`: approves the computer's login link.
  Future<Object?> answerComputer(Map<String, Object?> args) async {
    final what = (args['what'] as Map?)?.cast<String, Object?>() ?? args;
    switch (what['dir']) {
      case 'status':
        return {'ready': _state == InboxState.ready, 'account': _account};
      case 'approve':
        final why = await approveLogin('${what['link'] ?? ''}');
        if (why != null) throw StateError(why);
        return {'approved': true};
    }
    throw StateError('The phone does not do that for a computer.');
  }

  /// Whether this build can run Telegram at all: it has an app id, and (on a Mac or Android) the library.
  bool get configured => apiId != 0 && apiHash.isNotEmpty;

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (!configured) return;
    // TDLib is started only for someone who began signing in: until then the app does not load it at all.
    if (!app.flag('tg_used', fallback: false)) {
      _state = InboxState.signedOut;
      notifyListeners();
      return;
    }
    await _open();
  }

  /// Begins signing in (or, after an app restart, carries on where it was).
  Future<void> begin() async {
    if (!configured) {
      _state = InboxState.unavailable;
      _error = 'Telegram isn\'t in this build of the app.';
      notifyListeners();
      return;
    }
    _app?.setFlag('tg_used', true);
    _error = null;
    if (_td == null) {
      await _open();
    } else {
      notifyListeners();
    }
  }

  /// Starts TDLib (or the test's stand-in) and listens to it, once. Unavailable where the library isn't in the build.
  Future<void> _open() async {
    if (_td != null) return;
    final td = await (transport ?? TdJson.start)();
    if (td == null) {
      _state = InboxState.unavailable;
      _error = 'Telegram isn\'t in this build of the app.';
      notifyListeners();
      return;
    }
    _td = td;
    _sub = td.received.listen(_received);
    _state = InboxState.signingIn;
    notifyListeners();
    // Asking for the state makes TDLib say it (updateAuthorizationState follows).
    td.send({'@type': 'getAuthorizationState'});
  }

  // --- signing in ----------------------------------------------------------------------------------------------------

  // What the sign-in page gives for each step ([step]): the number, the code Telegram sent, the two-step password.
  // A refusal shows as [error]; the next step comes as TDLib's authorization state changes.
  Future<void> sendPhone(String phone) => _auth({'@type': 'setAuthenticationPhoneNumber', 'phone_number': phone.trim()});
  Future<void> sendCode(String code) => _auth({'@type': 'checkAuthenticationCode', 'code': code.trim()});
  Future<void> sendPassword(String password) => _auth({'@type': 'checkAuthenticationPassword', 'password': password});

  /// Sends one sign-in step to TDLib, and shows its reason where it refuses.
  Future<void> _auth(Map<String, Object?> request) async {
    _error = null;
    notifyListeners();
    final r = await _ask(request);
    if (r['@type'] == 'error') {
      _error = _plain(r);
      notifyListeners();
    }
  }

  @override
  Future<void> signOut() async {
    final td = _td;
    _app?.setFlag('tg_used', false);
    if (td != null && _state == InboxState.ready) {
      await _ask({'@type': 'logOut'}).timeout(const Duration(seconds: 10), onTimeout: () => const {});
    }
    _forget();
    _state = configured ? InboxState.signedOut : InboxState.unavailable;
    _step = InboxStep.none;
    notifyListeners();
  }

  /// Forgets everything held of the account in memory.
  void _forget() {
    _chatsById.clear();
    _order.clear();
    _users.clear();
    _messages.clear();
    _exhausted.clear();
    _chats = const [];
    _account = null;
    _contactIds.clear();
  }

  /// TDLib's authorization state changed: sets [state] and what the sign-in waits for next ([step]).
  void _authState(Map<String, Object?> s) {
    _step = InboxStep.none;
    switch (s['@type']) {
      case 'authorizationStateWaitTdlibParameters':
        _parameters();
        return;
      case 'authorizationStateWaitPhoneNumber':
        _state = InboxState.signingIn;
        _step = InboxStep.phone;
      case 'authorizationStateWaitCode':
        _state = InboxState.signingIn;
        _step = InboxStep.code;
        final info = s['code_info'] as Map?;
        _codeWhere = switch ((info?['type'] as Map?)?['@type']) {
          'authenticationCodeTypeTelegramMessage' => 'your Telegram app on another device',
          'authenticationCodeTypeSms' || 'authenticationCodeTypeSmsWord' || 'authenticationCodeTypeSmsPhrase' => 'a text to ${info?['phone_number'] ?? 'your phone'}',
          'authenticationCodeTypeCall' => 'a phone call',
          'authenticationCodeTypeFragment' => 'Fragment',
          'authenticationCodeTypeFirebaseAndroid' || 'authenticationCodeTypeFirebaseIos' => 'a text to ${info?['phone_number'] ?? 'your phone'}',
          _ => 'Telegram',
        };
      case 'authorizationStateWaitPassword':
        _state = InboxState.signingIn;
        _step = InboxStep.password;
        final hint = (s['password_hint'] as String?)?.trim();
        _passwordHint = hint == null || hint.isEmpty ? null : hint;
      case 'authorizationStateWaitEmailAddress' || 'authorizationStateWaitEmailCode' || 'authorizationStateWaitRegistration':
        _state = InboxState.signingIn;
        _step = InboxStep.phone;
        _error = 'Finish setting up this account in Telegram\'s own app first, then sign in here.';
      case 'authorizationStateWaitOtherDeviceConfirmation':
        // A login link to be approved by another device (askLoginLink): renewed by Telegram while it waits.
        _state = InboxState.signingIn;
        _step = InboxStep.elsewhere;
        _error = null;
        _loginLink = s['link'] as String?;
        final wanted = _linkWanted;
        if (wanted != null && !wanted.isCompleted && _loginLink != null) wanted.complete(_loginLink);
      case 'authorizationStateReady':
        _state = InboxState.ready;
        _error = null;
        _ready();
      case 'authorizationStateLoggingOut' || 'authorizationStateClosing':
        _state = InboxState.signingIn;
      case 'authorizationStateClosed':
        // TDLib closes for good after a log out: a new client is made for the next sign-in.
        _sub?.cancel();
        _td?.close();
        _td = null;
        _forget();
        _state = configured ? InboxState.signedOut : InboxState.unavailable;
    }
    notifyListeners();
  }

  /// Answers TDLib's first question: where its database and files go, and which app this is.
  void _parameters() {
    final dir = folder ?? _folder();
    _td?.send({
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': '$dir/db',
      'files_directory': '$dir/files',
      'database_encryption_key': '',
      'use_file_database': false,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': apiId,
      'api_hash': apiHash,
      'system_language_code': 'en',
      'device_model': PlatformInfo.isMacOS ? 'Mac' : 'Android',
      'system_version': PlatformInfo.operatingSystemVersion,
      'application_version': const String.fromEnvironment('FLUTTER_BUILD_NAME', defaultValue: 'Uplink'),
    });
  }

  /// This app's own folder: Android's private data folder (the cache folder's parent), the Mac's support folder.
  static String _folder() {
    if (PlatformInfo.isAndroid) return '${Directory.systemTemp.parent.path}/files/tdlib';
    return '${DeskStore.defaultDir().path}/tdlib';
  }

  /// Signed in: asks who this account is (shown as its @username, else its name) and loads its chats.
  void _ready() {
    _ask({'@type': 'getMe'}).then((me) {
      if (me['@type'] != 'user') return;
      _meId = (me['id'] as num?)?.toInt();
      final name = [me['first_name'], me['last_name']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
      final usernames = (me['usernames'] as Map?)?['active_usernames'] as List?;
      _account = usernames != null && usernames.isNotEmpty ? '@${usernames.first}' : (name.isEmpty ? null : name);
      notifyListeners();
    });
    unawaited(_loadAll());
    unawaited(_loadContacts());
  }

  // --- contacts (Matt, 2026-11-16: "Show telegram and signal contacts when linked") ---------------------------------

  /// The users in this account's Telegram contacts.
  final Set<int> _contactIds = {};

  /// Telegram's contact list; each user comes as updateUser, and any not yet heard of is asked for.
  Future<void> _loadContacts() async {
    final r = await _ask({'@type': 'getContacts'});
    if (r['@type'] != 'users') return;
    _contactIds
      ..clear()
      ..addAll([for (final x in (r['user_ids'] as List? ?? const [])) (x as num).toInt()]);
    for (final id in _contactIds.toList()) {
      if (_people.containsKey(id)) continue;
      final u = await _ask({'@type': 'getUser', 'user_id': id});
      if (u['@type'] == 'user') _people[id] = u;
    }
    notifyListeners();
  }

  @override
  List<InboxContact> get contacts {
    final out = <InboxContact>[];
    for (final id in _contactIds) {
      final u = _people[id];
      if (u == null || id == 777000 || _bots.contains(id)) continue;
      final name = [u['first_name'], u['last_name']].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim();
      final phone = '${u['phone_number'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
      final usernames = (u['usernames'] as Map?)?['active_usernames'] as List?;
      out.add(InboxContact(
        network: this.id,
        id: '$id',
        name: name.isEmpty ? (usernames != null && usernames.isNotEmpty ? '@${usernames.first}' : 'Someone') : name,
        number: phone.isEmpty ? null : '+$phone',
        avatar: _userPhoto(u),
        handle: usernames != null && usernames.isNotEmpty ? '@${usernames.first}' : null,
      ));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// A user's picture as a file on this device, asked for the first time it is wanted.
  String? _userPhoto(Map u) {
    final small = ((u['profile_photo'] as Map?)?['small'] as Map?);
    if (small == null) return null;
    final local = small['local'] as Map?;
    final path = local?['path'] as String?;
    if (local?['is_downloading_completed'] == true && path != null && path.isNotEmpty) return path;
    final file = (small['id'] as num?)?.toInt();
    if (file != null && _photosAsked.add(file)) {
      _td?.send({'@type': 'downloadFile', 'file_id': file, 'priority': 1, 'offset': 0, 'limit': 0, 'synchronous': false});
    }
    return null;
  }

  @override
  String? faceOf(String user) {
    final u = _people[int.tryParse(user)];
    return u == null ? null : _userPhoto(u);
  }

  @override
  bool get hasProfiles => true;

  @override
  Future<String?> chatWith(InboxContact contact) async {
    final user = int.tryParse(contact.id);
    if (user == null || _state != InboxState.ready) return null;
    final r = await _ask({'@type': 'createPrivateChat', 'user_id': user, 'force': false});
    return r['@type'] == 'chat' ? '${r['id']}' : null;
  }

  /// Every chat, not only the first hundred (Matt, 2026-11-15: "import telegram chats sorted by most recent with the
  /// profile pictures and all"): TDLib is asked for more until it says there are none (a 404).
  Future<void> _loadAll() async {
    for (var i = 0; i < 50; i++) {
      final r = await _ask({'@type': 'loadChats', 'chat_list': {'@type': 'chatListMain'}, 'limit': 100});
      if (r['@type'] == 'error') break;
    }
    // And Telegram's archive, which Uplink's Archived page shows among archived texts.
    for (var i = 0; i < 20; i++) {
      final r = await _ask({'@type': 'loadChats', 'chat_list': {'@type': 'chatListArchive'}, 'limit': 100});
      if (r['@type'] == 'error') break;
    }
  }

  /// The file ids of chats' pictures asked for, so each is asked for once.
  final Set<int> _photosAsked = {};

  /// The chat's picture as a file on this device, once TDLib has brought it down; asked for the first time it is seen.
  String? _photo(Map<String, Object?> c) {
    final small = ((c['photo'] as Map?)?['small'] as Map?);
    if (small == null) return null;
    final local = small['local'] as Map?;
    final path = local?['path'] as String?;
    if (local?['is_downloading_completed'] == true && path != null && path.isNotEmpty) return path;
    final file = (small['id'] as num?)?.toInt();
    if (file != null && _photosAsked.add(file)) {
      _td?.send({'@type': 'downloadFile', 'file_id': file, 'priority': 1, 'offset': 0, 'limit': 0, 'synchronous': false});
    }
    return null;
  }

  /// A file TDLib brought down: the chats whose picture it is take it.
  void _fileUpdated(Map file) {
    final fileId = (file['id'] as num?)?.toInt();
    if (fileId == null || (file['local'] as Map?)?['is_downloading_completed'] != true) return;
    var changed = false;
    for (final e in _chatsById.entries.toList()) {
      final photo = e.value['photo'] as Map?;
      if ((((photo?['small'] as Map?)?['id']) as num?)?.toInt() != fileId) continue;
      _chatsById[e.key] = {...e.value, 'photo': {...photo!, 'small': file}};
      changed = true;
    }
    if (changed) _rebuild();
    // And the contacts whose picture it is.
    var people = false;
    for (final e in _people.entries.toList()) {
      final photo = e.value['profile_photo'] as Map?;
      if ((((photo?['small'] as Map?)?['id']) as num?)?.toInt() != fileId) continue;
      _people[e.key] = {...e.value, 'profile_photo': {...photo!, 'small': file}};
      people = true;
    }
    if (people && !changed) notifyListeners();
  }

  // --- chats and messages --------------------------------------------------------------------------------------------

  /// Everything TDLib says: an answer goes to whoever asked (by its "@extra"); an update changes what is held.
  void _received(Map<String, Object?> m) {
    final extra = m['@extra'];
    if (extra is String && _waiting.containsKey(extra)) {
      _waiting.remove(extra)!.complete(m);
      return;
    }
    switch (m['@type']) {
      case 'updateAuthorizationState':
        _authState((m['authorization_state'] as Map).cast<String, Object?>());
      case 'updateUser':
        final u = m['user'] as Map;
        _people[(u['id'] as num).toInt()] = u;
        _setStatus((u['id'] as num).toInt(), u['status'] as Map?);
        final phone = '${u['phone_number'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
        if (phone.length >= 7) _byNumber[phone.length > 10 ? phone.substring(phone.length - 10) : phone] = (u['id'] as num).toInt();
        // Added to or taken out of this account's contacts, in Telegram or here.
        if (u['is_contact'] == true) {
          if (_contactIds.add((u['id'] as num).toInt()) && _state == InboxState.ready) notifyListeners();
        } else if (_contactIds.remove((u['id'] as num).toInt())) {
          notifyListeners();
        }
        // A label of Telegram's, or a contact made, changes how that person's chat is judged (lib/inbox/scams.dart).
        if (_chatsById.isNotEmpty) _rebuild();
        if ((u['type'] as Map?)?['@type'] == 'userTypeBot') _bots.add((u['id'] as num).toInt());
        final name = [u['first_name'], u['last_name']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
        _users[(u['id'] as num).toInt()] = name.isEmpty ? 'Someone' : name;
      case 'updateChatBlockList':
        // Blocked or unblocked, here or in Telegram's own app: Uplink's list follows Telegram's.
        final id = (m['chat_id'] as num).toInt();
        final on = (m['block_list'] as Map?)?['@type'] == 'blockListMain';
        if (on != isBlocked('$id')) {
          keepBlocked('$id', name: '${_chatsById[id]?['title'] ?? ''}', on: on);
          notifyListeners();
        }
      case 'updateNewChat':
        final c = (m['chat'] as Map).cast<String, Object?>();
        final id = (c['id'] as num).toInt();
        _chatsById[id] = c;
        if ((c['block_list'] as Map?)?['@type'] == 'blockListMain' && !isBlocked('$id')) keepBlocked('$id', name: '${c['title'] ?? ''}');
        for (final p in (c['positions'] as List? ?? const [])) {
          _position(id, p as Map);
        }
        _rebuild();
      case 'updateChatTitle':
        _patch(m, {'title': m['title']});
      case 'updateChatPhoto':
        _patch(m, {'photo': m['photo']});
      case 'updateChatActionBar':
        _patch(m, {'action_bar': m['action_bar']});
      case 'updateChatNotificationSettings':
        _patch(m, {'notification_settings': m['notification_settings']});
      case 'updateFile':
        _fileUpdated(m['file'] as Map);
        _messageFile(m['file'] as Map);
      case 'updateChatLastMessage':
        _patch(m, {'last_message': m['last_message']});
        for (final p in (m['positions'] as List? ?? const [])) {
          _position((m['chat_id'] as num).toInt(), p as Map);
        }
        _rebuild();
      case 'updateChatPosition':
        _position((m['chat_id'] as num).toInt(), m['position'] as Map);
        _rebuild();
      case 'updateChatReadInbox':
        _patch(m, {'unread_count': m['unread_count']});
      case 'updateUserStatus':
        _setStatus((m['user_id'] as num).toInt(), m['status'] as Map?);
      case 'updateNewMessage':
        final msg = (m['message'] as Map).cast<String, Object?>();
        _add('${msg['chat_id']}', [_message(msg)]);
      case 'updateMessageSendSucceeded':
        final msg = (m['message'] as Map).cast<String, Object?>();
        final chat = '${msg['chat_id']}';
        final old = '${m['old_message_id']}';
        _messages[chat] = [for (final x in messagesOf(chat)) if (x.id != old) x];
        _add(chat, [_message(msg)]);
      case 'updateMessageSendFailed':
        final msg = (m['message'] as Map).cast<String, Object?>();
        final chat = '${msg['chat_id']}';
        final old = '${m['old_message_id']}';
        _messages[chat] = [for (final x in messagesOf(chat)) x.id == old ? InboxMessage(id: x.id, text: x.text, date: x.date, mine: true, state: 'failed', mentions: x.mentions, senderId: x.senderId) : x];
        _error = _plain(m['error'] as Map? ?? const {});
        notifyListeners();
      case 'updateMessageInteractionInfo':
        // Reactions put on a message, or taken off.
        final chat = '${m['chat_id']}';
        final id = '${m['message_id']}';
        final reactions = telegramReactions(m['interaction_info'] as Map?);
        if (messagesOf(chat).any((x) => x.id == id)) {
          _messages[chat] = [for (final x in messagesOf(chat)) x.id == id ? _withReactions(x, reactions) : x];
          notifyListeners();
        }
      case 'updateMessageContent':
        _edited('${m['chat_id']}', '${m['message_id']}', (raw) => raw..['content'] = m['new_content']);
      case 'updateMessageEdited':
        _edited('${m['chat_id']}', '${m['message_id']}', (raw) => raw..['edit_date'] = m['edit_date']);
      case 'updateDeleteMessages':
        if (m['is_permanent'] == true) {
          final chat = '${m['chat_id']}';
          final gone = {for (final i in (m['message_ids'] as List? ?? const [])) '$i'};
          _messages[chat] = [for (final x in messagesOf(chat)) if (!gone.contains(x.id)) x];
          notifyListeners();
        }
    }
  }

  /// Sets [fields] on the chat an update [m] is about (its `chat_id`), where it is held, and makes the list again.
  void _patch(Map<String, Object?> m, Map<String, Object?> fields) {
    final id = (m['chat_id'] as num).toInt();
    final c = _chatsById[id];
    if (c == null) return;
    _chatsById[id] = {...c, ...fields};
    _rebuild();
  }

  /// Takes a chat's place in the main list or the archive, as TDLib orders them; an order of 0 takes it out of that
  /// list. Other lists (folders) are passed over.
  void _position(int chat, Map p) {
    final list = (p['list'] as Map?)?['@type'];
    final orders = switch (list) { 'chatListMain' => _order, 'chatListArchive' => _archOrder, _ => null };
    if (orders == null) return;
    final order = int.tryParse('${p['order']}') ?? 0;
    if (order == 0) {
      orders.remove(chat);
    } else {
      orders[chat] = order;
    }
    if (list == 'chatListMain') {
      if (p['is_pinned'] == true && order != 0) {
        _pinned.add(chat);
      } else {
        _pinned.remove(chat);
      }
    }
  }

  /// What TDLib said of each user: whether a contact, and whether Telegram marks them a scam or a fake.
  final Map<int, Map> _people = {};

  /// What Telegram itself says of a private chat's account, in words: its scam and fake labels.
  String? _flagOf(int? user) {
    final u = user == null ? null : _people[user];
    if (u == null) return null;
    final v = u['verification_status'] as Map?;
    if (u['is_scam'] == true || v?['is_scam'] == true) return 'Telegram marks this account as a scam';
    if (u['is_fake'] == true || v?['is_fake'] == true) return 'Telegram marks this account as a fake';
    return null;
  }

  /// The users that are bots, which sign-in codes may come from as Telegram's own account's do.
  final Set<int> _bots = {};

  /// Pinned chats in the main list.
  final Set<int> _pinned = {};

  @override
  Future<void> pin(String chatId, bool pinned) async {
    final r = await _ask({'@type': 'toggleChatIsPinned', 'chat_list': {'@type': 'chatListMain'}, 'chat_id': int.parse(chatId), 'is_pinned': pinned});
    if (r['@type'] == 'error') _error = _plain(r);
    notifyListeners();
  }

  /// The chats in Telegram's own archive, by their order there.
  final Map<int, int> _archOrder = {};
  List<InboxChat> _archived = const [];

  @override
  List<InboxChat> get archivedChats {
    _settle();
    return _archived;
  }

  /// Whether [id] is a chat to write in: anything held but a channel.
  bool _writable(int id) {
    final type = (_chatsById[id]?['type'] as Map?);
    if (type == null) return false;
    return !(type['@type'] == 'chatTypeSupergroup' && type['is_channel'] == true);
  }

  /// Into Telegram's archive, or back to the main list, as Telegram's own Archive does.
  @override
  Future<void> archive(String chatId, bool archived) async {
    final r = await _ask({'@type': 'addChatToList', 'chat_id': int.parse(chatId), 'chat_list': {'@type': archived ? 'chatListArchive' : 'chatListMain'}});
    if (r['@type'] == 'error') _error = _plain(r);
    notifyListeners();
  }

  @override
  bool get canBlock => true;

  /// Blocked on Telegram itself, as its own Block user does: they can't message or call this account, on any of its
  /// devices. A one-to-one chat's id is the person's.
  @override
  Future<void> block(String chatId, {required String name, bool on = true}) async {
    final type = _chatsById[int.tryParse(chatId)]?['type'] as Map?;
    final user = type?['@type'] == 'chatTypePrivate' ? (type!['user_id'] as num).toInt() : int.tryParse(chatId);
    if (user == null) throw StateError('Only a person can be blocked');
    final r = await _ask({
      '@type': 'setMessageSenderBlockList',
      'sender_id': {'@type': 'messageSenderUser', 'user_id': user},
      'block_list': on ? {'@type': 'blockListMain'} : null,
    });
    if (r['@type'] == 'error') throw StateError(_plain(r));
    await super.block(chatId, name: name, on: on);
  }

  /// Telegram's own list, as its Settings › Privacy › Blocked users shows it: Uplink's list is made the same.
  @override
  Future<void> refreshBlocked() async {
    if (_state != InboxState.ready) return;
    final r = await _ask({'@type': 'getBlockedMessageSenders', 'block_list': {'@type': 'blockListMain'}, 'offset': 0, 'limit': 100});
    if (r['@type'] == 'error') return;
    final there = <String, String>{};
    for (final s in (r['senders'] as List? ?? const [])) {
      final user = (s as Map)['user_id'];
      if (user is num) there['${user.toInt()}'] = _users[user.toInt()] ?? '${_chatsById[user.toInt()]?['title'] ?? ''}';
    }
    // Only a full list says who is no longer blocked: past a hundred, the ones beyond are left as Uplink has them.
    final whole = ((r['total_count'] as num?) ?? 0) <= there.length;
    for (final id in localList('blocked')) {
      if (whole && !there.containsKey(id)) keepBlocked(id, on: false);
    }
    there.forEach((id, name) => keepBlocked(id, name: name));
    notifyListeners();
  }

  /// Deleted for this account, as Telegram's Delete chat does: a group is left first, then its history goes.
  @override
  Future<void> deleteChat(String chatId) async {
    final id = int.parse(chatId);
    final type = (_chatsById[id]?['type'] as Map?)?['@type'];
    if (type == 'chatTypeBasicGroup' || type == 'chatTypeSupergroup') await _ask({'@type': 'leaveChat', 'chat_id': id});
    final r = await _ask({'@type': 'deleteChatHistory', 'chat_id': id, 'remove_from_chat_list': true, 'revoke': false});
    if (r['@type'] == 'error') {
      _error = _plain(r);
    } else {
      _order.remove(id);
      _archOrder.remove(id);
      _messages.remove(chatId);
      _rebuild();
    }
    notifyListeners();
  }

  /// The messages Telegram says can be deleted for everyone.
  final Set<String> _forAll = {};

  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => _forAll.contains('$chatId/${message.id}');

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    final r = await _ask({'@type': 'deleteMessages', 'chat_id': int.parse(chatId), 'message_ids': [int.parse(messageId)], 'revoke': forEveryone});
    if (r['@type'] == 'error') {
      _error = _plain(r);
    } else {
      _messages[chatId] = [for (final x in messagesOf(chatId)) if (x.id != messageId) x];
    }
    notifyListeners();
  }

  /// The lists are stale: made again when next asked for ([_settle]), and the listeners told. TDLib says thousands of
  /// things as it starts and signs in, each of which used to make and sort every chat here; now each only says so,
  /// and the lists are made once for whoever next reads them (docs/performance-audit.md, finding 2).
  void _rebuild() {
    _stale = true;
    notifyListeners();
  }

  bool _stale = false;

  /// Makes the list and the archive again where they are stale: called by whatever reads them.
  void _settle() {
    if (!_stale) return;
    _stale = false;
    final ids = _order.keys.where(_writable).toList();
    _chats = [for (final id in ids) _chat(_chatsById[id]!)]..sort((a, b) => b.date.compareTo(a.date));
    _archived = [for (final id in _archOrder.keys.where((id) => _writable(id) && !_order.containsKey(id))) _chat(_chatsById[id]!)]..sort((a, b) => b.date.compareTo(a.date));
  }

  /// A chat as TDLib holds it, as the list shows it.
  InboxChat _chat(Map<String, Object?> c) {
    final last = c['last_message'] as Map?;
    final type = (c['type'] as Map?)?['@type'];
    return InboxChat(
      network: id,
      id: '${c['id']}',
      title: (c['title'] as String?)?.trim().isNotEmpty == true ? c['title'] as String : 'Telegram',
      date: last == null ? DateTime.fromMillisecondsSinceEpoch(0) : DateTime.fromMillisecondsSinceEpoch(((last['date'] as num?) ?? 0).toInt() * 1000),
      snippet: last == null ? '' : (_event(last) ?? _text(last)),
      unread: (c['unread_count'] as num?)?.toInt() ?? 0,
      group: type == 'chatTypeBasicGroup' || type == 'chatTypeSupergroup',
      lastFromMe: last?['is_outgoing'] == true,
      avatar: _photo(c),
      pinned: _pinned.contains(c['id']),
      // Someone not a contact who wrote first: Telegram offers to report them (its action bar); or not a contact at all.
      stranger: type == 'chatTypePrivate' &&
          (const {'chatActionBarReportSpam', 'chatActionBarReportAddBlock'}.contains((c['action_bar'] as Map?)?['@type']) ||
              _people[((c['type'] as Map)['user_id'] as num?)?.toInt()]?['is_contact'] == false),
      cold: type == 'chatTypePrivate' && const {'chatActionBarReportSpam', 'chatActionBarReportAddBlock'}.contains((c['action_bar'] as Map?)?['@type']),
      flag: type == 'chatTypePrivate' ? _flagOf(((c['type'] as Map)['user_id'] as num?)?.toInt()) : null,
      // Muted in Telegram for now: no notification from Uplink either. A chat on Telegram's default for its kind is not
      // taken as muted (the default is rarely muted, and is not kept per chat).
      muted: _muted(c['notification_settings'] as Map?),
      // Telegram's own account (777000, which sends its sign-in codes) and bots.
      service: type == 'chatTypePrivate' && (((c['type'] as Map)['user_id'] as num?)?.toInt() == 777000 || _bots.contains(((c['type'] as Map)['user_id'] as num?)?.toInt())),
    );
  }

  /// Whether a chat's own notification settings mute it (a chat left on the account's default counts as not muted).
  static bool _muted(Map? settings) => settings != null && settings['use_default_mute_for'] != true && ((settings['mute_for'] as num?) ?? 0) > 0;

  /// A message as TDLib gives it, as the screens show it. Notes on the way whether it can be deleted for everyone.
  InboxMessage _message(Map<String, Object?> m) {
    if (m['can_be_deleted_for_all_users'] == true) _forAll.add('${m['chat_id']}/${m['id']}');
    final sender = m['sender_id'] as Map?;
    final user = (sender?['user_id'] as num?)?.toInt();
    // Posted as a chat, not a person (an admin as the group itself, a channel in its group): by that chat's name.
    final chat = user == null ? _chatsById[(sender?['chat_id'] as num?)?.toInt()] : null;
    final sending = (m['sending_state'] as Map?)?['@type'];
    final media = _media(m['content'] as Map? ?? const {});
    // The message it answers, where it is one: the words Telegram quoted, else that message's own where it is held.
    final replyTo = m['reply_to'] as Map?;
    final reply = replyTo?['@type'] == 'messageReplyToMessage' ? replyTo : null;
    final quoted = reply == null ? null : messagesOf('${m['chat_id']}').where((x) => x.id == '${reply['message_id']}').firstOrNull;
    for (final x in media) {
      _fileUsers.putIfAbsent(x.fileId, () => {}).add('${m['chat_id']}');
      if (x.thumbId != null) _fileUsers.putIfAbsent(x.thumbId!, () => {}).add('${m['chat_id']}');
    }
    final event = _event(m);
    final key = '${m['chat_id']}/${m['id']}';
    _raw[key] = m;
    final versions = _versions[key] ?? const <String>[];
    // A picture's or a file's words are its caption alone: the picture itself is drawn.
    final text = event ?? (media.isEmpty ? _text(m) : ((((m['content'] as Map?)?['caption'] as Map?)?['text'] as String?) ?? '').trim());
    return InboxMessage(
      id: '${m['id']}',
      event: event != null,
      edited: event == null && (((m['edit_date'] as num?) ?? 0) > 0 || versions.isNotEmpty),
      versions: versions,
      text: text,
      mentions: event == null ? telegramMentions(m, shown: text) : const [],
      senderId: user == null ? '' : '$user',
      media: media,
      date: DateTime.fromMillisecondsSinceEpoch(((m['date'] as num?) ?? 0).toInt() * 1000),
      mine: m['is_outgoing'] == true,
      sender: user == null ? '${chat?['title'] ?? ''}' : (_users[user] ?? ''),
      state: sending == 'messageSendingStatePending' ? 'sending' : (sending == 'messageSendingStateFailed' ? 'failed' : 'sent'),
      reactions: telegramReactions(m['interaction_info'] as Map?),
      replyTo: reply == null ? null : '${reply['message_id']}',
      replyText: reply == null ? null : (((reply['quote'] as Map?)?['text'] as Map?)?['text'] as String? ?? quoted?.text),
      replySender: quoted == null ? null : (quoted.mine ? 'You' : (quoted.sender.isEmpty ? null : quoted.sender)),
    );
  }

  /// [x] with its reactions now [reactions].
  static InboxMessage _withReactions(InboxMessage x, List<InboxReaction> reactions) => InboxMessage(
        id: x.id,
        text: x.text,
        date: x.date,
        mine: x.mine,
        sender: x.sender,
        state: x.state,
        media: x.media,
        reactions: reactions,
        replyTo: x.replyTo,
        replyText: x.replyText,
        replySender: x.replySender,
        event: x.event,
        edited: x.edited,
        versions: x.versions,
        mentions: x.mentions,
        senderId: x.senderId,
      );

  // --- edits (Matt, 2026-11-17: "Add support for edited messages on telegram and signal and the ability to see the
  // original message") ----------------------------------------------------------------------------------------------
  // Telegram says a message was edited (its edit_date) and gives its new words, never the old: what it said before is
  // kept here as each edit comes, the first first, in a file of its own beside TDLib's, so the original is still there
  // after a restart. A message edited before this device saw it is marked edited, with no earlier words to show.

  /// Each message as Telegram last gave it, by "chat/id": what an edit's new content is put into.
  final Map<String, Map<String, Object?>> _raw = {};

  Map<String, List<String>>? _versionsHeld;

  /// Where edited messages' earlier words are kept; null with no folder given, when they last only as long as the app
  /// runs.
  File? get _versionsFile => folder == null ? null : File('$folder/ghost-edits.json');

  /// The earlier words of edited messages, read from the file on first use.
  Map<String, List<String>> get _versions {
    if (_versionsHeld != null) return _versionsHeld!;
    try {
      final f = _versionsFile;
      if (f != null && f.existsSync()) {
        return _versionsHeld = (jsonDecode(f.readAsStringSync()) as Map).map((k, v) => MapEntry('$k', [for (final x in v as List) '$x']));
      }
    } catch (_) {}
    return _versionsHeld = {};
  }

  void _keepVersions() {
    try {
      final f = _versionsFile;
      if (f == null) return;
      // The newest thousand edited messages: enough to see what was said, never a file that only grows.
      final all = _versions;
      if (all.length > 1000) all.remove(all.keys.first);
      // Written elsewhere, a run of edits as one write (lib/inbox/kept_writer.dart): up to a thousand edits were
      // written whole, here, for each message edited.
      (_versionsWriter ??= KeptWriter(file: () => _versionsFile!, snapshot: () => _versions)).save();
    } catch (_) {}
  }

  KeptWriter? _versionsWriter;

  /// A message edited: its words before kept, and it drawn again as it now is (its reactions as they stand here).
  void _edited(String chat, String id, Map<String, Object?> Function(Map<String, Object?> raw) change) {
    final key = '$chat/$id';
    final raw = _raw[key];
    final held = messagesOf(chat).where((x) => x.id == id).firstOrNull;
    if (raw == null || held == null) return;
    final next = change(Map<String, Object?>.of(raw));
    final now = _message(next);
    if (now.text != held.text && !held.event) {
      _versions[key] = [...?_versions[key], held.text];
      _keepVersions();
    }
    final redone = _withReactions(_message(next), held.reactions);
    _messages[chat] = [for (final x in messagesOf(chat)) x.id == id ? redone : x];
    notifyListeners();
  }

  /// Each person's status as Telegram last said it (userStatusOnline and the rest).
  final Map<int, Map> _statuses = {};

  /// Takes [user]'s presence as TDLib says it, and tells the avatars where it changed.
  void _setStatus(int user, Map? status) {
    if (status == null) return;
    final was = _statuses[user];
    _statuses[user] = status;
    if (was == null || was['@type'] != status['@type'] || was['was_online'] != status['was_online']) presenceChanges.changed();
  }

  /// A private chat's id is its person's own (TDLib): either names them.
  @override
  InboxPresence? presenceOf(String id) {
    final user = int.tryParse(id);
    if (user == null || user <= 0 || _bots.contains(user)) return null;
    return telegramPresence(_statuses[user]);
  }

  /// People by their phone number's last ten digits, for an avatar of texts to find their Telegram presence at once.
  final Map<String, int> _byNumber = {};

  @override
  InboxPresence? presenceOfNumber(String digits) {
    final user = _byNumber[digits.length > 10 ? digits.substring(digits.length - 10) : digits];
    return user == null ? null : presenceOf('$user');
  }

  // --- profiles, for the card a tapped @mention opens (Matt, 2026-11-19: "when using telegram and other outside apps we
  // should proxy through any profile information their APIs make available") ----------------------------------------
  // Asked of TDLib as few times as can be: the user as updateUser last gave them (else getUser), their bio from
  // getUserFullInfo, their small picture; each answer kept five minutes, so a card opened again asks nothing.

  final Map<String, (DateTime, InboxProfile?)> _profiles = {};

  @override
  Future<InboxProfile?> profileOf({String user = '', String username = ''}) async {
    if (_state != InboxState.ready) return null;
    final name = username.trim().replaceFirst(RegExp(r'^@'), '');
    final key = user.isNotEmpty ? 'u:$user' : 'n:${name.toLowerCase()}';
    if (user.isEmpty && name.isEmpty) return null;
    final kept = _profiles[key];
    if (kept != null && DateTime.now().difference(kept.$1) < const Duration(minutes: 5)) return kept.$2;
    InboxProfile? found;
    final id = int.tryParse(user);
    if (id != null) {
      found = await _profileOfUser(id);
    } else if (name.isNotEmpty) {
      // A username: the public chat it names, and the person behind it where it is one; a channel or a group
      // (an @mention may name one) as Telegram shows it, its title and picture.
      final chat = await _ask({'@type': 'searchPublicChat', 'username': name});
      if (chat['@type'] == 'chat') {
        final type = chat['type'] as Map?;
        if (type?['@type'] == 'chatTypePrivate') {
          found = await _profileOfUser((type!['user_id'] as num).toInt());
        } else {
          found = InboxProfile(network: this.id, id: '${chat['id']}', name: '${chat['title'] ?? ''}', username: name, avatar: _photo(chat));
        }
      }
    }
    _profiles[key] = (DateTime.now(), found);
    if (found != null && found.username.isNotEmpty) _profiles['n:${found.username.toLowerCase()}'] = (DateTime.now(), found);
    if (found != null && int.tryParse(found.id) != null && int.parse(found.id) > 0) _profiles['u:${found.id}'] = (DateTime.now(), found);
    return found;
  }

  @override
  Future<InboxProfile?> ownProfile() async {
    if (_state != InboxState.ready) return null;
    _meId ??= ((await _ask({'@type': 'getMe'}))['id'] as num?)?.toInt();
    final me = _meId;
    return me == null ? null : _profileOfUser(me);
  }

  /// What Telegram says of the user [id], for a profile card; null where it knows no such user.
  Future<InboxProfile?> _profileOfUser(int id) async {
    var u = _people[id];
    if (u == null) {
      final got = await _ask({'@type': 'getUser', 'user_id': id});
      if (got['@type'] != 'user') return null;
      u = _people[id] = got;
    }
    final full = await _ask({'@type': 'getUserFullInfo', 'user_id': id});
    final bot = (u['type'] as Map?)?['@type'] == 'userTypeBot';
    // A person's bio; a bot's is its short description.
    var bio = full['@type'] == 'userFullInfo' ? '${((full['bio'] as Map?)?['text']) ?? ''}'.trim() : '';
    if (bio.isEmpty && full['@type'] == 'userFullInfo') bio = '${(full['bot_info'] as Map?)?['short_description'] ?? ''}'.trim();
    final usernames = (u['usernames'] as Map?)?['active_usernames'] as List?;
    final phone = '${u['phone_number'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
    return InboxProfile(
      network: this.id,
      id: '$id',
      name: [u['first_name'], u['last_name']].whereType<String>().where((x) => x.trim().isNotEmpty).join(' ').trim(),
      username: usernames != null && usernames.isNotEmpty ? '${usernames.first}' : '',
      bio: bio,
      status: await _emojiStatus(u['emoji_status'] as Map?),
      avatar: await _profilePhoto(u),
      number: phone.isEmpty ? '' : '+$phone',
      bot: bot,
      seen: bot ? '' : (telegramPresence((_statuses[id] ?? u['status']) as Map?)?.words() ?? ''),
    );
  }

  /// A user's small picture on this device: brought down now where it isn't yet (a small file), else none.
  Future<String?> _profilePhoto(Map u) async {
    final there = _userPhoto(u);
    if (there != null) return there;
    final file = ((((u['profile_photo'] as Map?)?['small'] as Map?)?['id']) as num?)?.toInt();
    if (file == null) return null;
    final r = await _ask({'@type': 'downloadFile', 'file_id': file, 'priority': 8, 'offset': 0, 'limit': 0, 'synchronous': true}, wait: const Duration(seconds: 15));
    if (r['@type'] != 'file') return null;
    _fileUpdated(r);
    return _localOf(r);
  }

  /// The emoji a user's emoji status is drawn from, where Telegram says: one more request, kept with the card.
  Future<String> _emojiStatus(Map? status) async {
    if (status == null) return '';
    // TDLib before 1.8.40 kept the id on the status itself; after, under its type.
    final type = status['type'] as Map?;
    final custom = (type?['custom_emoji_id'] ?? status['custom_emoji_id'])?.toString();
    if (custom == null || custom.isEmpty) return '';
    final r = await _ask({'@type': 'getCustomEmojiStickers', 'custom_emoji_ids': [int.tryParse(custom) ?? custom]});
    final stickers = r['stickers'] as List?;
    return stickers == null || stickers.isEmpty ? '' : '${(stickers.first as Map)['emoji'] ?? ''}';
  }

  @override
  bool get canReact => true;

  /// The reactions every Telegram chat takes as it ships (a chat may allow fewer): Telegram has no 😂, so 🤣.
  @override
  List<String> get reactionChoices => const ['❤️', '👍', '👎', '🤣', '😱', '😢', '🙏', '🔥', '🎉'];

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (_state != InboxState.ready) throw StateError('Telegram isn\'t connected');
    final r = await _ask({
      '@type': remove ? 'removeMessageReaction' : 'addMessageReaction',
      'chat_id': int.parse(chatId),
      'message_id': int.parse(messageId),
      'reaction_type': {'@type': 'reactionTypeEmoji', 'emoji': emoji},
      if (!remove) 'is_big': false,
      if (!remove) 'update_recent_reactions': true,
    });
    if (r['@type'] == 'error') throw StateError(r['message'] == 'REACTION_INVALID' ? 'This chat doesn\'t take $emoji as a reaction' : _plain(r));
  }

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final r = await _ask({
      '@type': 'sendMessage',
      'chat_id': int.parse(chatId),
      'reply_to': {'@type': 'inputMessageReplyToMessage', 'message_id': int.parse(messageId)},
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    });
    if (r['@type'] == 'message') {
      _add(chatId, [_message(r)]);
    } else {
      _error = _plain(r);
      notifyListeners();
    }
  }

  // --- attachments (Matt, 2026-11-15: "Is it possible to send and receive attachments through telegram too?") --------

  /// The chats each file is in, so a file brought down reaches the messages holding it.
  final Map<int, Set<String>> _fileUsers = {};
  final Map<int, String> _files = {};
  final Set<int> _filesAsked = {};

  static int? _fileId(Map? f) => (f?['id'] as num?)?.toInt();

  /// TDLib's file as far as this device has it: its path once it is whole here.
  String? _localOf(Map? f) {
    final local = f?['local'] as Map?;
    final path = local?['path'] as String?;
    return local?['is_downloading_completed'] == true && path != null && path.isNotEmpty ? path : null;
  }

  /// A message's pictures, videos, sounds and files.
  List<InboxMedia> _media(Map c) {
    InboxMedia one(String kind, Map? file, {String? name, Map? dims, int duration = 0, Map? thumb}) {
      final id = _fileId(file)!;
      final path = _localOf(file) ?? _files[id];
      if (path != null) _files[id] = path;
      final thumbFile = thumb?['file'] as Map?;
      final thumbId = _fileId(thumbFile);
      return InboxMedia(
        kind: kind, fileId: id, path: path, name: name, size: ((file?['size'] ?? file?['expected_size']) as num?)?.toInt() ?? 0,
        width: (dims?['width'] as num?)?.toInt() ?? 0, height: (dims?['height'] as num?)?.toInt() ?? 0, duration: duration,
        thumbId: thumbId, thumbPath: thumbId == null ? null : (_localOf(thumbFile) ?? _files[thumbId]),
      );
    }

    switch (c['@type']) {
      case 'messagePhoto':
        final sizes = ((c['photo'] as Map?)?['sizes'] as List? ?? const []).cast<Map>();
        if (sizes.isEmpty) return const [];
        // The largest no wider than 1280: sharp on a phone without bringing the original down.
        final fit = sizes.where((x) => ((x['width'] as num?) ?? 0) <= 1280).toList();
        final size = (fit.isEmpty ? sizes : fit).last;
        return [one('photo', size['photo'] as Map?, dims: size)];
      case 'messageVideo':
        final v = c['video'] as Map;
        return [one('video', v['video'] as Map?, name: v['file_name'] as String?, dims: v, duration: (v['duration'] as num?)?.toInt() ?? 0, thumb: v['thumbnail'] as Map?)];
      case 'messageAnimation':
        final v = c['animation'] as Map;
        return [one('video', v['animation'] as Map?, name: v['file_name'] as String?, dims: v, duration: (v['duration'] as num?)?.toInt() ?? 0, thumb: v['thumbnail'] as Map?)];
      case 'messageVideoNote':
        final v = c['video_note'] as Map;
        return [one('video', v['video'] as Map?, dims: {'width': v['length'], 'height': v['length']}, duration: (v['duration'] as num?)?.toInt() ?? 0, thumb: v['thumbnail'] as Map?)];
      case 'messageSticker':
        final st = c['sticker'] as Map;
        // A still sticker is drawn on its own, with no bubble; an animated one is not drawn here yet.
        if ((st['format'] as Map?)?['@type'] != 'stickerFormatWebp') return const [];
        return [one('sticker', st['sticker'] as Map?, dims: st)];
      case 'messageDocument':
        final d = c['document'] as Map;
        return [one('file', d['document'] as Map?, name: d['file_name'] as String?, thumb: d['thumbnail'] as Map?)];
      case 'messageAudio':
        final a = c['audio'] as Map;
        return [one('audio', a['audio'] as Map?, name: (a['title'] as String?)?.trim().isNotEmpty == true ? a['title'] as String : a['file_name'] as String?, duration: (a['duration'] as num?)?.toInt() ?? 0)];
      case 'messageVoiceNote':
        final a = c['voice_note'] as Map;
        return [one('audio', a['voice'] as Map?, name: 'Voice message', duration: (a['duration'] as num?)?.toInt() ?? 0)];
    }
    return const [];
  }

  /// A file whole on this device: the messages holding it take its path, and whoever waits for it is answered.
  void _messageFile(Map file) {
    final id = _fileId(file);
    final path = _localOf(file);
    if (id == null || path == null) return;
    _files[id] = path;
    final chats = _fileUsers[id];
    if (chats == null) return;
    for (final chat in chats) {
      final held = _messages[chat];
      if (held == null) continue;
      _messages[chat] = [
        for (final m in held)
          m.media.any((x) => x.fileId == id || x.thumbId == id)
              ? InboxMessage(
                  id: m.id,
                  text: m.text,
                  date: m.date,
                  mine: m.mine,
                  sender: m.sender,
                  state: m.state,
                  media: [for (final x in m.media) x.withPath(id, path)],
                  reactions: m.reactions,
                  replyTo: m.replyTo,
                  replyText: m.replyText,
                  replySender: m.replySender,
                  event: m.event,
                  edited: m.edited,
                  versions: m.versions,
                  mentions: m.mentions,
                  senderId: m.senderId,
                )
              : m,
      ];
    }
    notifyListeners();
  }

  @override
  bool get canSendFiles => true;

  /// A message's file asked for, to come down by itself (a picture as it is drawn). Asked again if it has not come
  /// [_askAgain] later (Matt, 2026-11-20: "some photos and videos are not coming through"): it was asked once a run, so
  /// one that failed (the network gone a moment) never came until the app was opened again.
  @override
  void wantFile(int fileId) {
    if (_files.containsKey(fileId)) return;
    final now = DateTime.now();
    final asked = _filesAskedAt[fileId];
    if (asked != null && now.difference(asked) < _askAgain) return;
    _filesAskedAt[fileId] = now;
    _filesAsked.add(fileId);
    _td?.send({'@type': 'downloadFile', 'file_id': fileId, 'priority': 16, 'offset': 0, 'limit': 0, 'synchronous': false});
  }

  final Map<int, DateTime> _filesAskedAt = {};
  static const _askAgain = Duration(seconds: 20);

  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null) return known;
    // Waited for whole: a video may take a while.
    final r = await _ask({'@type': 'downloadFile', 'file_id': fileId, 'priority': 32, 'offset': 0, 'limit': 0, 'synchronous': true}, wait: const Duration(minutes: 5));
    if (r['@type'] != 'file') {
      _error = _plain(r);
      notifyListeners();
      return null;
    }
    _messageFile(r);
    return _localOf(r);
  }

  /// What a file is sent as, by its name: a picture, a video, or a file as it is.
  static String kindOf(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif', 'bmp'}.contains(ext)) return ext == 'gif' ? 'animation' : 'photo';
    if (const {'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'}.contains(ext)) return 'video';
    return 'file';
  }

  @override
  Future<void> sendFiles(String chatId, List<String> paths, {String caption = '', bool voice = false, bool sticker = false}) async {
    if (_state != InboxState.ready) return;
    for (final (i, path) in paths.indexed) {
      final words = i == paths.length - 1 && caption.trim().isNotEmpty ? {'caption': {'@type': 'formattedText', 'text': caption.trim()}} : const <String, Object?>{};
      final file = {'@type': 'inputFileLocal', 'path': path};
      // A sticker of Uplink's goes as a Telegram sticker (WEBP is what Telegram takes for one), so it arrives as one
      // there and comes back as one here; one in another format goes as the picture it is.
      final content = sticker && path.toLowerCase().endsWith('.webp')
          ? {'@type': 'inputMessageSticker', 'sticker': file, 'width': 512, 'height': 512}
          : voice
          // Uplink records AAC in .m4a; Telegram's voice messages are Opus, so it goes as a sound named for what it is.
          ? {'@type': 'inputMessageAudio', 'audio': file, 'title': 'Voice message', ...words}
          : switch (kindOf(path)) {
              'photo' => {'@type': 'inputMessagePhoto', 'photo': file, ...words},
              'animation' => {'@type': 'inputMessageAnimation', 'animation': file, ...words},
              'video' => {'@type': 'inputMessageVideo', 'video': file, 'supports_streaming': true, ...words},
              _ => {'@type': 'inputMessageDocument', 'document': file, ...words},
            };
      final r = await _ask({'@type': 'sendMessage', 'chat_id': int.parse(chatId), 'input_message_content': content}, wait: const Duration(minutes: 2));
      if (r['@type'] == 'message') {
        _add(chatId, [_message(r)]);
      } else {
        _error = _plain(r);
        notifyListeners();
        return;
      }
    }
  }

  /// A message's words, or what it is where it has none to show (a picture, a voice message…).
  static String _text(Map m) {
    final c = m['content'] as Map? ?? const {};
    String caption(String what) {
      final t = ((c['caption'] as Map?)?['text'] as String?)?.trim();
      return t == null || t.isEmpty ? what : '$what: $t';
    }

    return switch (c['@type']) {
      'messageText' => ((c['text'] as Map?)?['text'] as String?) ?? '',
      'messagePhoto' => caption('Photo'),
      'messageVideo' => caption('Video'),
      'messageAnimation' => caption('GIF'),
      'messageDocument' => caption('File'),
      'messageAudio' => caption('Audio'),
      'messageVoiceNote' => caption('Voice message'),
      'messageVideoNote' => 'Video message',
      'messageSticker' => '${(c['sticker'] as Map?)?['emoji'] ?? ''} Sticker'.trim(),
      'messageLocation' || 'messageVenue' => 'Location',
      'messageContact' => 'Contact',
      'messagePoll' => 'Poll',
      'messageCall' => 'Call',
      'messageDice' => '${c['emoji'] ?? '🎲'}',
      'messageGame' => 'Game: ${(c['game'] as Map?)?['title'] ?? ''}'.trim(),
      'messageInvoice' => 'Invoice: ${c['title'] ?? (c['product_info'] as Map?)?['title'] ?? ''}'.trim(),
      'messageStory' => 'Story',
      'messageGiveaway' || 'messageGiveawayWinners' || 'messageGiveawayCompleted' || 'messageGiveawayCreated' => 'Giveaway',
      'messageExpiredPhoto' => 'Photo (no longer available)',
      'messageExpiredVideo' => 'Video (no longer available)',
      'messageExpiredVideoNote' || 'messageExpiredVoiceNote' => 'Message (no longer available)',
      'messagePaidMedia' => caption('Paid photo or video'),
      'messageChecklist' => 'Checklist',
      // Something newer than this app knows (Matt, 2026-11-17: "A bunch of telegram messages are just showing as
      // \"Message\""): said so, rather than a word that reads like what was written.
      _ => 'A kind of message Uplink can\'t show yet: open Telegram to see it',
    };
  }

  /// What happened, where [m] is something that happened in the chat rather than something said: a join, a leave, a new
  /// name or picture, a pin, a video chat (Telegram's service messages). Null for anything said.
  String? _event(Map m) {
    final c = m['content'] as Map? ?? const {};
    final senderId = ((m['sender_id'] as Map?)?['user_id'] as num?)?.toInt();
    String who(int? id) => id == null ? 'Someone' : (id == senderId && m['is_outgoing'] == true ? 'You' : (_users[id] ?? 'Someone'));
    final by = m['is_outgoing'] == true ? 'You' : who(senderId);
    String names(Object? ids) => [for (final i in (ids as List? ?? const [])) if (i is num) who(i.toInt())].join(', ');
    return switch (c['@type']) {
      'messageChatAddMembers' => () {
          final ids = [for (final i in (c['member_user_ids'] as List? ?? const [])) if (i is num) i.toInt()];
          return ids.length == 1 && ids.first == senderId ? '$by joined the group' : '$by added ${names(ids)}';
        }(),
      'messageChatJoinByLink' => '$by joined with an invite link',
      'messageChatJoinByRequest' => '$by joined the group',
      'messageChatDeleteMember' => (c['user_id'] as num?)?.toInt() == senderId ? '$by left the group' : '$by removed ${who((c['user_id'] as num?)?.toInt())}',
      'messageBasicGroupChatCreate' || 'messageSupergroupChatCreate' => '$by made the group "${c['title'] ?? ''}"',
      'messageChatChangeTitle' => '$by renamed the group "${c['title'] ?? ''}"',
      'messageChatChangePhoto' => '$by changed the group\'s picture',
      'messageChatDeletePhoto' => '$by took away the group\'s picture',
      'messagePinMessage' => '$by pinned a message',
      'messageChatUpgradeTo' || 'messageChatUpgradeFrom' => 'The group became a supergroup',
      'messageScreenshotTaken' => '$by took a screenshot',
      'messageContactRegistered' => '$by joined Telegram',
      'messageChatSetMessageAutoDeleteTime' => ((c['message_auto_delete_time'] as num?) ?? 0) > 0 ? '$by turned on disappearing messages' : '$by turned off disappearing messages',
      'messageVideoChatStarted' => '$by started a video chat',
      'messageVideoChatEnded' => 'The video chat ended',
      'messageVideoChatScheduled' => '$by scheduled a video chat',
      'messageInviteVideoChatParticipants' => '$by invited ${names(c['user_ids'])} to the video chat',
      'messageForumTopicCreated' => '$by made the topic "${c['name'] ?? ''}"',
      'messageForumTopicEdited' || 'messageForumTopicIsClosedToggled' || 'messageForumTopicIsHiddenToggled' => '$by changed a topic',
      'messageChatSetTheme' || 'messageChatSetBackground' => '$by changed the chat\'s look',
      'messageChatBoost' => '$by boosted the group',
      'messageGameScore' => '$by scored ${c['score'] ?? ''}'.trim(),
      'messageGift' || 'messageGiftedPremium' || 'messagePremiumGiftCode' || 'messageGiftedStars' => '$by sent a gift',
      'messageCustomServiceAction' => '${c['text'] ?? ''}',
      'messageProximityAlertTriggered' => 'Someone came near',
      'messageChatShared' || 'messageUsersShared' => '$by shared a contact',
      'messageBotWriteAccessAllowed' => 'You allowed the bot to write to you',
      'messageWebAppDataSent' || 'messageWebAppDataReceived' => 'Data sent from a web app',
      _ => null,
    };
  }

  /// Puts [got] among [chat]'s messages, each replacing the one held under its id, in order of time.
  void _add(String chat, List<InboxMessage> got) {
    final held = {for (final m in messagesOf(chat)) m.id: m};
    for (final m in got) {
      held[m.id] = m;
    }
    _messages[chat] = held.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    notifyListeners();
  }

  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready) return;
    final held = messagesOf(chatId);
    if (older && _exhausted.contains(chatId)) return;
    var from = older && held.isNotEmpty ? int.tryParse(held.first.id) ?? 0 : 0;
    // TDLib may answer with fewer than asked (often one, the first time): asked again from the oldest got, a few
    // times, so a chat opens with a screenful.
    var got = 0;
    for (var round = 0; round < 4 && got < 30; round++) {
      final r = await _ask({'@type': 'getChatHistory', 'chat_id': int.parse(chatId), 'from_message_id': from, 'offset': 0, 'limit': 50, 'only_local': false});
      if (r['@type'] != 'messages') break;
      final list = [for (final m in (r['messages'] as List? ?? const [])) (m as Map).cast<String, Object?>()];
      if (list.isEmpty) {
        _exhausted.add(chatId);
        break;
      }
      _add(chatId, [for (final m in list) _message(m)]);
      got += list.length;
      from = (list.last['id'] as num).toInt();
    }
  }

  /// Whether [chatId] may have messages before the oldest held.
  bool hasOlder(String chatId) => !_exhausted.contains(chatId);

  @override
  Future<void> send(String chatId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final r = await _ask({
      '@type': 'sendMessage',
      'chat_id': int.parse(chatId),
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    });
    if (r['@type'] == 'message') {
      _add(chatId, [_message(r)]);
    } else {
      _error = _plain(r);
      notifyListeners();
    }
  }

  /// A Telegram group in full, for its drawer: getChat, this account's own standing in it, and the group's full info
  /// and members (a basic group's all, a supergroup's 200 most recent). A channel is not a group.
  @override
  Future<GroupDetails?> groupDetails(String chatId) async {
    if (_state != InboxState.ready) return null;
    final id = int.tryParse(chatId);
    if (id == null) return null;
    final chat = await _ask({'@type': 'getChat', 'chat_id': id});
    if (chat['@type'] == 'error') throw StateError(_plain(chat));
    final type = chat['type'] as Map? ?? const {};
    final basic = type['@type'] == 'chatTypeBasicGroup';
    final superGroup = type['@type'] == 'chatTypeSupergroup' && type['is_channel'] != true;
    if (!basic && !superGroup) return null;
    _meId ??= ((await _ask({'@type': 'getMe'}))['id'] as num?)?.toInt();
    final mine = _meId == null ? const <String, Object?>{} : await _ask({'@type': 'getChatMember', 'chat_id': id, 'member_id': {'@type': 'messageSenderUser', 'user_id': _meId}});
    final Map full;
    final List members;
    if (basic) {
      full = await _ask({'@type': 'getBasicGroupFullInfo', 'basic_group_id': type['basic_group_id']});
      members = full['members'] as List? ?? const [];
    } else {
      full = await _ask({'@type': 'getSupergroupFullInfo', 'supergroup_id': type['supergroup_id']});
      final got = await _ask({'@type': 'getSupergroupMembers', 'supergroup_id': type['supergroup_id'], 'filter': {'@type': 'supergroupMembersFilterRecent'}, 'offset': 0, 'limit': 200});
      members = got['members'] as List? ?? const [];
    }
    final people = <Map<String, Object?>>[];
    for (final raw in members) {
      final m = raw as Map;
      final user = ((m['member_id'] as Map?)?['user_id'] as num?)?.toInt();
      final status = '${(m['status'] as Map?)?['@type']}';
      if (user == null || status == 'chatMemberStatusLeft' || status == 'chatMemberStatusBanned') continue;
      var u = _people[user];
      if (u == null) {
        final got = await _ask({'@type': 'getUser', 'user_id': user});
        if (got['@type'] == 'user') u = _people[user] = got;
      }
      people.add({
        'id': '$user',
        'name': u == null ? (_users[user] ?? 'Someone') : [u['first_name'], u['last_name']].whereType<String>().where((x) => x.trim().isNotEmpty).join(' ').trim(),
        'number': u?['phone_number'],
        'status': status,
        'me': user == _meId,
      });
    }
    return telegramGroupDetails(
      chat: chat,
      mine: (mine['status'] as Map?) ?? const {},
      description: '${full['description'] ?? ''}',
      inviteLink: ((full['invite_link'] as Map?)?['invite_link']) as String?,
      people: people,
      photo: chats.where((c) => c.id == chatId).firstOrNull?.avatar,
    );
  }

  /// Changes a Telegram group on Telegram, a request to TDLib for each part, stopping at the first Telegram refuses.
  @override
  Future<GroupDetails?> changeGroup(String chatId, GroupChange change) async {
    if (_state != InboxState.ready) throw StateError('Telegram isn\'t connected');
    final id = int.parse(chatId);
    Future<void> ask(Map<String, Object?> request) async {
      final got = await _ask(request, wait: const Duration(minutes: 2));
      if (got['@type'] == 'error') throw StateError(_plain(got));
    }

    Map<String, Object?> who(String user) => {'@type': 'messageSenderUser', 'user_id': int.parse(user)};
    if (change.leave) {
      await ask({'@type': 'leaveChat', 'chat_id': id});
      return null;
    }
    if (change.title != null) await ask({'@type': 'setChatTitle', 'chat_id': id, 'title': change.title!.trim()});
    if (change.description != null) await ask({'@type': 'setChatDescription', 'chat_id': id, 'description': change.description!.trim()});
    if (change.photo != null) {
      await ask({
        '@type': 'setChatPhoto',
        'chat_id': id,
        'photo': change.photo!.isEmpty ? null : {'@type': 'inputChatPhotoStatic', 'photo': {'@type': 'inputFileLocal', 'path': change.photo}},
      });
    }
    if (change.timer != null) await ask({'@type': 'setChatMessageAutoDeleteTime', 'chat_id': id, 'message_auto_delete_time': change.timer});
    for (final u in change.add) {
      await ask({'@type': 'addChatMember', 'chat_id': id, 'user_id': int.parse(u), 'forward_limit': 100});
    }
    for (final u in change.remove) {
      await ask({'@type': 'setChatMemberStatus', 'chat_id': id, 'member_id': who(u), 'status': {'@type': 'chatMemberStatusLeft'}});
    }
    for (final u in change.admin) {
      await ask({'@type': 'setChatMemberStatus', 'chat_id': id, 'member_id': who(u), 'status': {'@type': 'chatMemberStatusAdministrator', 'custom_title': '', 'can_be_edited': true, 'rights': telegramAdminRights}});
    }
    for (final u in change.unadmin) {
      await ask({'@type': 'setChatMemberStatus', 'chat_id': id, 'member_id': who(u), 'status': {'@type': 'chatMemberStatusMember'}});
    }
    if (change.announcementsOnly != null || change.editInfoAdminsOnly != null || change.addPeopleAdminsOnly != null) {
      final chat = await _ask({'@type': 'getChat', 'chat_id': id});
      final permissions = telegramPermissions(
        (chat['permissions'] as Map?)?.cast<String, Object?>() ?? const {},
        announcementsOnly: change.announcementsOnly,
        editInfoAdminsOnly: change.editInfoAdminsOnly,
        addPeopleAdminsOnly: change.addPeopleAdminsOnly,
      );
      await ask({'@type': 'setChatPermissions', 'chat_id': id, 'permissions': permissions});
    }
    return groupDetails(chatId);
  }

  @override
  Future<void> markRead(String chatId) async {
    if (_state != InboxState.ready) return;
    final id = int.parse(chatId);
    final ids = [for (final m in messagesOf(chatId)) if (!m.mine) int.tryParse(m.id)].whereType<int>().toList();
    // A chat never opened has no messages here: its newest message seen reads the whole chat, as Telegram counts it
    // (Mark all as read in the list).
    final last = ((_chatsById[id]?['last_message'] as Map?)?['id'] as num?)?.toInt();
    if (ids.isEmpty && last != null) ids.add(last);
    if (ids.isEmpty) return;
    _td?.send({'@type': 'viewMessages', 'chat_id': id, 'message_ids': ids.length > 100 ? ids.sublist(ids.length - 100) : ids, 'force_read': true});
    // Unread no longer, here at once.
    final c = _chatsById[id];
    if (c != null && (c['unread_count'] as num? ?? 0) > 0) {
      _chatsById[id] = {...c, 'unread_count': 0};
      _rebuild();
    }
  }

  @override
  set watching(String? chatId) {
    final was = _watching;
    _watching = chatId;
    if (_state != InboxState.ready) return;
    // An open chat is told to TDLib, so its updates come and reading it counts as read.
    if (was != null && was != chatId) _td?.send({'@type': 'closeChat', 'chat_id': int.parse(was)});
    if (chatId != null && chatId != was) _td?.send({'@type': 'openChat', 'chat_id': int.parse(chatId)});
  }

  /// Asks TDLib and waits for its answer. Never throws: a failure, TDLib not running or no answer within [wait] comes
  /// back as an `error` object, as TDLib's own errors do.
  Future<Map<String, Object?>> _ask(Map<String, Object?> request, {Duration wait = const Duration(seconds: 30)}) {
    final td = _td;
    if (td == null) return Future.value(const {'@type': 'error', 'message': 'Telegram isn\'t running'});
    final key = 'q${++_asked}';
    final done = Completer<Map<String, Object?>>();
    _waiting[key] = done;
    td.send({...request, '@extra': key});
    return done.future.timeout(wait, onTimeout: () {
      _waiting.remove(key);
      return const {'@type': 'error', 'message': 'Telegram took too long to answer'};
    });
  }

  /// An error from TDLib, in words for the page.
  static String _plain(Map e) {
    final said = '${e['message'] ?? ''}';
    return switch (said) {
      'PHONE_NUMBER_INVALID' => 'That phone number isn\'t one Telegram knows. Include the country code, like +1.',
      'PHONE_CODE_INVALID' => 'That code isn\'t right.',
      'PHONE_CODE_EXPIRED' => 'That code has run out. Ask for a new one.',
      'PASSWORD_HASH_INVALID' => 'That password isn\'t right.',
      'PHONE_NUMBER_BANNED' => 'Telegram has banned this number.',
      'API_ID_INVALID' || 'API_ID_PUBLISHED_FLOOD' => 'This build\'s Telegram app id was refused.',
      'CHAT_WRITE_FORBIDDEN' || 'USER_IS_BLOCKED' => 'You can\'t write in this chat.',
      _ when said.startsWith('Too Many Requests') || said.startsWith('FLOOD_WAIT') => 'Telegram asks to wait before trying again.',
      _ => said.isEmpty ? 'Telegram said no.' : said,
    };
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
    _versionsWriter?.flush();
    _sub?.cancel();
    _td?.close();
    super.dispose();
  }
}

/// [Telegram._plain], for a test of its words.
@visibleForTesting
String telegramPlain(Map e) => Telegram._plain(e);

/// What a member made admin from Uplink may do: as Telegram's apps give a new admin, short of adding admins.
const telegramAdminRights = <String, Object?>{
  '@type': 'chatAdministratorRights',
  'can_manage_chat': true,
  'can_change_info': true,
  'can_delete_messages': true,
  'can_invite_users': true,
  'can_restrict_members': true,
  'can_pin_messages': true,
  'can_manage_video_chats': true,
  'can_promote_members': false,
};

/// A group's permissions (TDLib's chatPermissions) with the drawer's rules changed: only admins write (every way of
/// sending turned off for members), only admins change its details, only admins add people.
Map<String, Object?> telegramPermissions(Map<String, Object?> now, {bool? announcementsOnly, bool? editInfoAdminsOnly, bool? addPeopleAdminsOnly}) {
  final p = <String, Object?>{...now, '@type': 'chatPermissions'};
  if (announcementsOnly != null) {
    for (final k in [...p.keys]) {
      if (k.startsWith('can_send_')) p[k] = !announcementsOnly;
    }
    p['can_send_basic_messages'] = !announcementsOnly;
  }
  if (editInfoAdminsOnly != null) p['can_change_info'] = !editInfoAdminsOnly;
  if (addPeopleAdminsOnly != null) p['can_invite_users'] = !addPeopleAdminsOnly;
  return p;
}

/// A Telegram group in the drawer's words: from getChat ([chat]), this account's chatMemberStatus in it ([mine]), its
/// full info and its members (each `id`, `name`, `number`, `status`, `me`).
GroupDetails telegramGroupDetails({required Map chat, required Map mine, String description = '', String? inviteLink, List<Map<String, Object?>> people = const [], String? photo}) {
  final perms = (chat['permissions'] as Map?) ?? const {};
  final status = '${mine['@type']}';
  final owner = status == 'chatMemberStatusCreator';
  final rights = (mine['rights'] as Map?) ?? const {};
  final admin = owner || status == 'chatMemberStatusAdministrator';
  bool right(String k) => owner || (admin && rights[k] == true);
  return GroupDetails(
    title: '${chat['title'] ?? ''}'.trim().isEmpty ? 'Telegram group' : '${chat['title']}'.trim(),
    description: description,
    photo: photo,
    timer: (chat['message_auto_delete_time'] as num?)?.toInt() ?? 0,
    people: [
      for (final p in people)
        GroupPerson(
          id: '${p['id']}',
          name: '${p['name'] ?? ''}'.trim().isEmpty ? 'Someone' : '${p['name']}'.trim(),
          number: '${p['number'] ?? ''}'.isEmpty ? null : '+${p['number']}'.replaceFirst('++', '+'),
          admin: p['status'] == 'chatMemberStatusAdministrator' || p['status'] == 'chatMemberStatusCreator',
          owner: p['status'] == 'chatMemberStatusCreator',
          me: p['me'] == true,
        ),
    ],
    admin: admin,
    editInfoAdminsOnly: perms['can_change_info'] != true,
    addPeopleAdminsOnly: perms['can_invite_users'] != true,
    announcementsOnly: perms['can_send_basic_messages'] == false,
    inviteLink: inviteLink,
    supports: GroupFeature.values.toSet(),
    canEditInfo: right('can_change_info') || perms['can_change_info'] == true,
    canAddPeople: right('can_invite_users') || perms['can_invite_users'] == true,
    canRemovePeople: right('can_restrict_members'),
    canSetAdmins: right('can_promote_members'),
    canChangeRules: right('can_restrict_members'),
  );
}

/// A message's reactions as TDLib gives them (messageInteractionInfo.reactions), as kinds: the emoji ones, how many each,
/// and whether this account gave it. Paid stars and custom emoji are left out: Uplink has no way to draw them.
List<InboxReaction> telegramReactions(Map? interaction) {
  final list = ((interaction?['reactions'] as Map?)?['reactions'] as List?) ?? const [];
  return [
    for (final r in list)
      if (((r as Map)['type'] as Map?)?['@type'] == 'reactionTypeEmoji')
        InboxReaction(emoji: '${(r['type'] as Map)['emoji']}', count: (r['total_count'] as num?)?.toInt() ?? 1, mine: r['is_chosen'] == true),
  ];
}

/// A person's status as TDLib gives it, as presence: online until it says otherwise, offline with when, or the rough
/// words of someone who keeps the time to themselves. Null for none (an empty status, a bot).
InboxPresence? telegramPresence(Map? status, {DateTime? now}) {
  switch (status?['@type']) {
    case 'userStatusOnline':
      final until = (status!['expires'] as num?)?.toInt();
      final online = until == null || DateTime.fromMillisecondsSinceEpoch(until * 1000).isAfter(now ?? DateTime.now());
      return InboxPresence(network: 'Telegram', online: online, lastSeen: online ? null : DateTime.fromMillisecondsSinceEpoch(until * 1000));
    case 'userStatusOffline':
      final at = (status!['was_online'] as num?)?.toInt();
      return InboxPresence(network: 'Telegram', lastSeen: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at * 1000));
    case 'userStatusRecently':
      return const InboxPresence(network: 'Telegram', rough: 'recently');
    case 'userStatusLastWeek':
      return const InboxPresence(network: 'Telegram', rough: 'within a week');
    case 'userStatusLastMonth':
      return const InboxPresence(network: 'Telegram', rough: 'within a month');
  }
  return null;
}

/// The @mentions in a TDLib message's words ([m], as TDLib gives it), as offsets into [shown], the words the app shows
/// for it (the message's own words where null). TDLib marks each with an entity: textEntityTypeMention for "@username"
/// typed out, textEntityTypeMentionName for a person named without one (its user_id). Its offsets are UTF-16 units, as
/// Dart's are; where the app shows the words trimmed, or after a word of its own ("Audio: …"), they are moved to match,
/// and a mention that would fall outside what is shown is left out.
List<InboxMention> telegramMentions(Map m, {String? shown}) {
  final c = m['content'] as Map? ?? const {};
  final formatted = (c['@type'] == 'messageText' ? c['text'] : c['caption']) as Map?;
  final raw = formatted?['text'] as String?;
  final entities = formatted?['entities'] as List?;
  if (raw == null || raw.isEmpty || entities == null || entities.isEmpty) return const [];
  final words = shown ?? raw;
  // Where the raw words begin in what is shown: the same; trimmed; or at the end, after a word of the app's own.
  int base;
  if (words == raw) {
    base = 0;
  } else {
    final trimmed = raw.trim();
    final lead = raw.length - raw.trimLeft().length;
    if (trimmed.isEmpty || !words.endsWith(trimmed)) return const [];
    base = words.length - trimmed.length - lead;
  }
  final out = <InboxMention>[];
  for (final e in entities) {
    if (e is! Map) continue;
    final type = e['type'] as Map?;
    final offset = (e['offset'] as num?)?.toInt();
    final length = (e['length'] as num?)?.toInt();
    if (type == null || offset == null || length == null || length <= 0 || offset + length > raw.length) continue;
    final start = base + offset;
    if (start < 0 || start + length > words.length) continue;
    switch (type['@type']) {
      case 'textEntityTypeMention':
        final said = raw.substring(offset, offset + length);
        out.add(InboxMention(start: start, length: length, username: said.startsWith('@') ? said.substring(1) : said));
      case 'textEntityTypeMentionName':
        final user = (type['user_id'] as num?)?.toInt();
        if (user != null) out.add(InboxMention(start: start, length: length, user: '$user'));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
