import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../app_state.dart';
import '../desktop/store.dart';
import '../sms.dart';
import 'cookie_paste.dart';
import 'inbox.dart';
import 'signal.dart' show signalReactions;

/// What an account helper is to the app: lines out, lines in. A process in the app; a stand-in in a test.
abstract class HelperLink {
  /// What the helper says: answers (with the `id` of what was asked) and events (`ev`), one JSON object each.
  Stream<Map<String, Object?>> get heard;
  void say(Map<String, Object?> line);
  Future<void> close();
}

/// One of the services reached by an account helper (sidecar/ACCOUNT_HELPERS.md): what it is called, which helper
/// runs it, and how the person signs in (the cookies of a browser signed in to it).
@immutable
class HelperService {
  const HelperService({
    required this.id,
    required this.name,
    required this.helper,
    required this.library,
    required this.signInUrl,
    required this.cookieSite,
    required this.needed,
    this.optional = const [],
    required this.copyFrom,
    this.also = '',
    this.passcode = false,
    this.people = false,
  });

  /// Its helper lists the service's people (`people`) and opens a chat with one where there is none (`open`;
  /// sidecar/ACCOUNT_HELPERS.md): Slack's, a workspace's members (GMFB-61). Elsewhere the people to start a chat with
  /// are those there is a chat with already.
  final bool people;

  /// Its sign-in asks for a passcode beside the cookies: X's, which opens the keys of its encrypted chats (X Chat;
  /// sidecar/twitter/README.md). Never kept: the helper keeps the keys it opens.
  final bool passcode;

  /// The network's id in the app ("messenger"), and its name as people know it.
  final String id;
  final String name;

  /// The helper's name: `<helper>-sidecar` beside the app on a computer, `lib<helper>sidecar.so` on the phone.
  final String helper;

  /// The open-source library the helper is built on, for the warning.
  final String library;

  /// Where the person signs in, in a private window, and the site whose cookies are copied.
  final String signInUrl;
  final String cookieSite;

  /// The cookies the helper cannot do without, and those it takes too where they are there.
  final List<String> needed;
  final List<String> optional;

  /// Which request to copy in the browser's developer tools, in words.
  final String copyFrom;

  /// Something more this service's sign-in does that the person should know first, added to the warning.
  final String also;

  /// What the person is told before signing in, and in its Settings. None of these services allows other apps.
  String get warning =>
      '$name doesn\'t support or allow other apps. Uplink signs in as you, with the session of a browser signed in to your account, through the open-source $library library, and behaves as the website does. $name may ask you to confirm it\'s you, sign that session out, or restrict accounts it finds using unofficial apps.${also.isEmpty ? '' : ' $also'}';
}

/// Facebook Messenger, Instagram and LinkedIn (Matt, 2026-11-20: "Let's do the feasible ones but skip X and google
/// voice").
const messengerService = HelperService(
  id: 'messenger',
  name: 'Messenger',
  helper: 'messenger',
  library: 'mautrix-meta',
  signInUrl: 'https://www.messenger.com/',
  cookieSite: 'messenger.com or facebook.com',
  needed: ['xs', 'c_user', 'datr'],
  optional: ['sb', 'fr', 'wd', 'presence', 'oo', 'dpr'],
  copyFrom: 'any request to www.messenger.com (or www.facebook.com)',
  // sidecar/messenger: encrypted chats need a device of their own on the account (README, "End-to-end encrypted chats").
  also: 'To read end-to-end encrypted chats Uplink is added to your account as another device, which Messenger lists among your devices; encrypted messages from before you sign in stay in Messenger.',
);
const instagramService = HelperService(
  id: 'instagram',
  name: 'Instagram',
  helper: 'instagram',
  library: 'mautrix-meta',
  signInUrl: 'https://www.instagram.com/direct/inbox/',
  cookieSite: 'instagram.com',
  needed: ['sessionid', 'csrftoken', 'ds_user_id'],
  optional: ['mid', 'ig_did', 'rur', 'shbid', 'shbts', 'datr', 'dpr'],
  copyFrom: 'any request to www.instagram.com',
);
const linkedInService = HelperService(
  id: 'linkedin',
  name: 'LinkedIn',
  helper: 'linkedin',
  library: 'mautrix-linkedin',
  signInUrl: 'https://www.linkedin.com/messaging/',
  cookieSite: 'linkedin.com',
  needed: ['li_at', 'JSESSIONID'],
  // The helper takes every cookie of the site it is given: LinkedIn checks more than the two that sign it in.
  optional: [],
  copyFrom: 'any request to www.linkedin.com/voyager',
);

/// Discord, X and Slack (Matt, 2026-11-21: "Implement the discord one Twitter and slack"): helpers on mautrix-discord's
/// discordgo, mautrix-twitter's twittermeow and mautrix-slack's Slack client (sidecar/discord, sidecar/twitter,
/// sidecar/slack). Discord's and Slack's sign-in is a token, not only cookies: it rides in the cookies as `token`, read
/// from a pasted request by [tokenIn] (Discord's authorization header, Slack's xoxc- token) or synced by the extension.
const discordService = HelperService(
  id: 'discord',
  name: 'Discord',
  helper: 'discord',
  library: 'mautrix-discord (discordgo)',
  signInUrl: 'https://discord.com/channels/@me',
  cookieSite: 'discord.com',
  needed: ['token'],
  copyFrom: 'any request to discord.com/api (the one with an authorization header)',
  also: 'Discord\'s terms forbid automating a user account, and Discord can disable an account it finds doing so.',
);
const xService = HelperService(
  id: 'twitter',
  name: 'X',
  helper: 'twitter',
  library: 'mautrix-twitter',
  signInUrl: 'https://x.com/messages',
  cookieSite: 'x.com',
  needed: ['auth_token', 'ct0'],
  // The helper takes every cookie of the site it is given.
  optional: [],
  copyFrom: 'any request to x.com/i/api',
  passcode: true,
  also: 'X\'s messages are end-to-end encrypted (X Chat): Uplink asks for your 4-digit X Chat passcode once, to open their keys. X locks X Chat after a few wrong passcodes.',
);
const slackService = HelperService(
  id: 'slack',
  name: 'Slack',
  helper: 'slack',
  library: 'mautrix-slack',
  signInUrl: 'https://app.slack.com/client',
  cookieSite: 'slack.com',
  needed: ['d', 'token'],
  optional: [],
  copyFrom: 'any request to your workspace\'s slack.com/api (one with a token in it)',
  also: 'One workspace is signed in at a time, and its admins may sign the session out.',
  people: true,
);

/// A network reached by an account helper: Messenger, Instagram or LinkedIn. The helper (sidecar/messenger,
/// sidecar/instagram, sidecar/linkedin) runs as a child process and speaks sidecar/ACCOUNT_HELPERS.md; this class is
/// the same for all three, told apart by [service].
///
/// Signing in is the cookies of a browser signed in to the account, pasted as a copied request ([signIn]), after the
/// warning ([HelperService.warning]) is agreed to. The service lists the chats (`chat` events) and sends what is said
/// from then on; older messages of a chat are asked for as it is opened and scrolled ([load]). What has come is kept
/// here ([_file]), the newest [_mostKept] of a chat, so the list is there before the helper has connected.
class AccountHelper extends InboxNetwork {
  AccountHelper(this.service, {this.soon = false, this.link, this.folder});

  final HelperService service;

  @override
  final bool soon;

  /// The helper, in a test. Null: the process, once [start] finds it.
  final Future<HelperLink?> Function()? link;

  /// Where the helper's session and the chats kept here are. Null: this app's own folder.
  final String? folder;

  @override
  String get id => service.id;
  @override
  String get name => service.name;

  static const _mostKept = 400;

  // The running helper and what it is asked: each request goes out under the next number ([_asked]) and its answer
  // completes the one waiting under it.
  HelperLink? _link;
  StreamSubscription<Map<String, Object?>>? _sub;
  AppState? _app;
  InboxState _state = InboxState.unavailable;
  String? _error, _account, _me;
  bool _busy = false;
  int _asked = 0;
  final Map<int, Completer<Object?>> _waiting = {};

  /// The chats, as the service describes each, and each one's messages kept here, oldest first.
  final Map<String, Map<String, Object?>> _chats = {};
  final Map<String, List<Map<String, Object?>>> _messages = {};

  /// Names and pictures by the service's id for a person.
  final Map<String, String> _names = {};
  final Map<String, String> _avatars = {};

  /// The service's people the helper has listed ([findPeople]), by their id: name and handle. For this run only.
  final Map<String, ({String name, String handle})> _listed = {};

  /// Chats whose older messages have all come, and those being asked for now.
  final Set<String> _exhausted = {};
  final Set<String> _loading = {};

  /// Attachments by the number the screens know them by, and their files once brought down.
  final Map<int, Map<String, Object?>> _pointers = {};
  final Map<int, String> _files = {};

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut || _state == InboxState.signingIn ? InboxStep.credentials : InboxStep.none;
  @override
  String? get error => _error;
  @override
  String? get account => _account;

  /// The cookies are with the service, being checked.
  bool get signingIn => _busy;

  /// A service's own folder on this device: under the app's files on the phone, the desktop store's on a computer.
  static String _dirOf(HelperService s) => PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/${s.id}' : '${DeskStore.defaultDir().path}/${s.id}';

  /// Deletes what a service no longer offered kept on this device: its helper's session and the chats kept here.
  static Future<void> forget(HelperService s, {String? folder}) async {
    try {
      final dir = Directory(folder ?? _dirOf(s));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  String get _dir => folder ?? (PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/${service.id}' : '${DeskStore.defaultDir().path}/${service.id}');
  File get _file => File('$_dir/chats.json');

  /// A start under way: asked again meanwhile (a synced sign-in switching the plugin on while the app's own start is
  /// still finding the helper), it waits for that one rather than start a second helper on the same folder.
  Future<void>? _starting;

  @override
  Future<void> start(AppState app) {
    final going = _starting;
    if (going != null) return going;
    return _starting = _start(app).whenComplete(() => _starting = null);
  }

  Future<void> _start(AppState app) async {
    _app = app;
    if (soon) return;
    final link = await (this.link ?? _process)();
    if (link == null) {
      _state = InboxState.unavailable;
      _error = 'The ${service.name} helper isn\'t in this build.';
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
      if (s['linked'] == true) _signedIn(s);
    } catch (_) {}
  }

  /// The helper: beside the app on a computer (Contents/Helpers on a Mac, the program's folder on Windows and Linux),
  /// the phone's native libraries on Android.
  Future<HelperLink?> _process() async {
    String? binary;
    final h = service.helper;
    if (PlatformInfo.isAndroid) {
      try {
        binary = await const MethodChannel('ghost_messaging/sms').invokeMethod<String>('helperPath', {'name': '${h}sidecar'});
      } catch (_) {}
    } else if (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux) {
      final named = PlatformInfo.environment['GHOST_${h.toUpperCase()}SIDECAR'];
      final exe = File(PlatformInfo.resolvedExecutable).parent.path;
      final os = PlatformInfo.isWindows ? 'windows' : (PlatformInfo.isLinux ? 'linux' : 'mac');
      final file = PlatformInfo.isWindows ? '$h-sidecar.exe' : '$h-sidecar';
      for (final c in [
        ?named,
        if (PlatformInfo.isWindows) '$exe\\$file' else if (PlatformInfo.isLinux) '$exe/$file' else '$exe/../Helpers/$file',
        '${Directory.current.path}/build/$h-sidecar/$os/$file',
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
      return _ProcessLink(await Process.start(binary, ['--dir', _dir]), service.id);
    } catch (_) {
      return null;
    }
  }

  /// The sign-in this device holds now, as the cookies (and Discord's and Slack's token) a synced entry carries: read
  /// back from the helper's own session.json, so a sign-in made before sign-ins were shared, or whose sharing failed,
  /// still reaches the account's other devices (CurlSync.pull; Matt, 2026-11-27: "if a connection is setup on one
  /// device but not another on the same account it gets sent over"). Null where it is not signed in, or what the helper
  /// keeps lacks a cookie the service needs.
  Future<Map<String, String>?> heldSignIn() async {
    if (_state != InboxState.ready) return null;
    try {
      final f = File('$_dir/session.json');
      if (!await f.exists()) return null;
      final m = (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
      // Only the cookies the service takes, as a pasted sign-in shares ([cookiesOf]): a helper may keep more of the site's.
      final named = service.optional.isEmpty ? null : {...service.needed, ...service.optional};
      final out = <String, String>{
        for (final e in ((m['cookies'] as Map?) ?? const {}).entries)
          if ('${e.value}'.isNotEmpty && (named == null || named.contains('${e.key}'))) '${e.key}': '${e.value}',
      };
      final token = m['token'];
      if (token is String && token.isNotEmpty) out['token'] = token;
      if (out.isEmpty || cookiesMissing(out, service.needed).isNotEmpty) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  // --- signing in ---------------------------------------------------------------------------------------------------

  /// The cookies in what was pasted that this service's helper takes: the needed and the optional ones, or every
  /// cookie where the service names no optional ones (LinkedIn's helper is given the whole site's).
  Map<String, String> cookiesOf(String pasted) {
    final cookies = cookiesIn(pasted, names: service.optional.isEmpty ? const {} : {...service.needed, ...service.optional});
    // Discord's and Slack's token is not a cookie: it is in the request itself (or in the synced entry, already there).
    if (service.needed.contains('token') && !cookies.containsKey('token')) {
      final token = tokenIn(pasted);
      if (token != null) cookies['token'] = token;
    }
    return cookies;
  }

  /// Told of a sign-in made on this device by what was pasted (not one that came synced), so every device on the Uplink
  /// account is signed in too (CurlSync.share; Matt, 2026-11-21: "if i login to discord or something the curl should
  /// automatically be applied to all devices using the same ghost messaging account"). Null in a test.
  static void Function(String serviceId, Map<String, String> cookies)? onShare;

  /// Signs in with the cookies in [pasted] (a copied request, a Cookie header, or the pairs; and [passcode], where the
  /// service asks for one): only after the person has agreed to the warning (lib/ui/inbox_signin_helper.dart). False,
  /// with [error] saying why, where it did not. [share] false: a sign-in that came synced from another device, not
  /// told on to [onShare] again.
  Future<bool> signIn(String pasted, {String? passcode, bool share = true}) async {
    if (_link == null) return false;
    final cookies = cookiesOf(pasted);
    final missing = cookiesMissing(cookies, service.needed);
    final code = passcode?.trim() ?? '';
    if (service.passcode && !RegExp(r'^[0-9]{4}$').hasMatch(code)) {
      _error = 'Enter your 4-digit ${service.name} Chat passcode, the one ${service.name} asks for on its messages page.';
      notifyListeners();
      return false;
    }
    if (missing.isNotEmpty) {
      _error = cookies.isEmpty
          ? 'No ${service.name} cookies in that. Copy ${service.copyFrom} as cURL, and paste all of it.'
          : 'That is missing ${missing.join(', ')}. Make sure you\'re signed in, then copy ${service.copyFrom} again.';
      notifyListeners();
      return false;
    }
    _error = null;
    _busy = true;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final s = (await _ask('sign_in', {'cookies': cookies, if (service.passcode) 'passcode': code}) as Map?) ?? const {};
      _busy = false;
      if (_state != InboxState.ready) _signedIn(s);
      if (share) onShare?.call(service.id, cookies);
      return true;
    } catch (e) {
      _busy = false;
      _error = _words(e);
      _state = InboxState.signedOut;
      notifyListeners();
      return false;
    }
  }

  /// An error as the person is shown it: the helper's own words where it gave them.
  static String _words(Object e) => e is StateError ? e.message : '$e';

  /// The helper is signed in (its `status` answer, a `sign_in` answer or a `linked` event): takes whose account it is
  /// and asks for the chats.
  void _signedIn(Map s) {
    final handle = (s['handle'] as String?)?.trim() ?? '';
    final name = (s['name'] as String?)?.trim() ?? '';
    _account = handle.isNotEmpty ? '@$handle' : (name.isNotEmpty ? name : null);
    _me = (s['me'] as String?)?.trim();
    _state = InboxState.ready;
    _error = null;
    notifyListeners();
    unawaited(_listChats());
  }

  /// The service's own list of chats, asked for as the helper connects.
  Future<void> _listChats() async {
    try {
      for (final c in (await _ask('chats')) as List? ?? const []) {
        _takeChat((c as Map).cast<String, Object?>());
      }
      _save();
      notifyListeners();
    } catch (_) {}
  }

  @override
  Future<void> signOut() async {
    try {
      await _ask('unlink');
    } catch (_) {}
    _forget();
    _state = _link == null ? InboxState.unavailable : InboxState.signedOut;
    _error = null;
    _save();
    notifyListeners();
  }

  /// Drops everything held of the account in memory, on signing out.
  void _forget() {
    _chats.clear();
    _messages.clear();
    _names.clear();
    _avatars.clear();
    _exhausted.clear();
    _listed.clear();
    _account = null;
    _me = null;
  }

  // --- what the helper says ---------------------------------------------------------------------------------------

  /// One line from the helper: the answer to something asked (it has `ok` and the request's `id`), or an event.
  void _heard(Map<String, Object?> m) {
    final id = m['id'];
    if (id is num && m.containsKey('ok')) {
      final w = _waiting.remove(id.toInt());
      if (w == null) return;
      m['ok'] == true ? w.complete(m['result']) : w.completeError(StateError('${m['error'] ?? '${service.name} did not answer'}'));
      return;
    }
    switch (m['ev']) {
      case 'linked':
        _signedIn(m);
      case 'unlinked':
        // The service ended the session: what is kept stays to be read, and signing in again carries on.
        _account = null;
        _state = InboxState.signedOut;
        final why = (m['error'] as String?)?.trim() ?? '';
        _error = why.isNotEmpty ? why : '${service.name} signed this session out. Sign in again to carry on.';
        notifyListeners();
      case 'connected':
        if (_state == InboxState.ready) unawaited(_listChats());
      case 'chat':
        _takeChat(m);
        _save();
        notifyListeners();
      case 'name':
        _takeName(m);
        _save();
        notifyListeners();
      case 'message':
        if (_take(m)) {
          final chat = '${m['chat']}';
          final c = _chats[chat]!;
          final ts = (m['ts'] as num?)?.toInt();
          if (m['mine'] == true) {
            // Nothing to count.
          } else if (chat == _watching) {
            // On screen: not counted, and the service is still to be told it was read ([markRead]; GMFB-62).
            _arrivedOpen.add(chat);
          } else if (ts == null || ts > ((c['read_at'] as int?) ?? 0)) {
            // One from before what was read here, said again by the service, is not unread again (GMFB-62).
            c['unread'] = ((c['unread'] as int?) ?? 0) + 1;
          }
          _save();
          notifyListeners();
        }
      case 'edited':
        final msg = _find('${m['chat']}', '${m['target']}');
        if (msg != null) {
          msg['text'] = m['text'] ?? '';
          msg['edited'] = true;
          _save();
          notifyListeners();
        }
      case 'reaction':
        _reaction(m);
      case 'receipt':
        final chat = '${m['chat']}';
        // This account's own, read in the service's own app: the chat is read here too.
        if (_me != null && '${m['from'] ?? ''}' == _me) {
          final c = _chats[chat];
          if (c != null && (c['unread'] as int? ?? 0) != 0) {
            c['unread'] = 0;
            _readTo(chat, c);
            _save();
            notifyListeners();
          }
          break;
        }
        // Read up to a message (by its id, or where the service gives only a time, `ts`): every one of this account's
        // own up to it, in time.
        final list = _messages[chat] ?? const <Map<String, Object?>>[];
        final upTo = (_find(chat, '${m['id'] ?? ''}')?['ts'] as int?) ?? (m['ts'] as num?)?.toInt();
        final kind = m['kind'] == 'read' ? 'read' : 'delivered';
        for (final x in list) {
          if (x['mine'] != true || x['state'] == 'read' || x['state'] == 'sending' || x['state'] == 'failed') continue;
          if (upTo == null ? x['id'] == '${m['id']}' : (x['ts'] as int) <= upTo) x['state'] = kind;
        }
        _save();
        notifyListeners();
      case 'deleted':
        _messages['${m['chat']}']?.removeWhere((x) => x['id'] == '${m['target']}');
        _save();
        notifyListeners();
    }
  }

  /// A chat as the service describes it: its title, who is in it, its picture, what is unread.
  void _takeChat(Map<String, Object?> m) {
    final chat = (m['id'] as String?) ?? '';
    if (chat.isEmpty) return;
    final c = _chats.putIfAbsent(chat, () => {'unread': 0, 'last': 0});
    final title = (m['title'] as String?)?.trim() ?? '';
    if (title.isNotEmpty) c['title'] = title;
    if (m.containsKey('group')) c['group'] = m['group'] == true;
    if (m['avatar'] is String && (m['avatar'] as String).isNotEmpty) c['avatar'] = m['avatar'];
    final last = (m['last'] as num?)?.toInt() ?? 0;
    // The newest activity the service itself has named, apart from `last`, which a message sent from here moves by
    // this device's clock.
    if (last > ((c['listed_at'] as int?) ?? 0)) c['listed_at'] = last;
    if (m['unread'] is num && chat != _watching) {
      var unread = (m['unread'] as num).toInt();
      // Read here, and the service says something waits though nothing in the chat is newer than what was read: it
      // stays read, and the service is told again, once (GMFB-62, Matt, Android 0.12.26: "Every time i tab back into
      // the app Facebook messenger messages are getting marked as unread". Back in front the helper connects again
      // and the service's list is taken; its count stood over what was read here, and Messenger's is partly a guess,
      // sidecar/messenger's unreadOf).
      final readAt = (c['read_at'] as int?) ?? 0;
      if (unread > 0 && last > 0 && last <= readAt) {
        unread = 0;
        if (_retold[chat] != readAt) {
          _retold[chat] = readAt;
          unawaited(_tellRead(chat));
        }
      }
      c['unread'] = unread;
    }
    if (last > ((c['last'] as int?) ?? 0)) c['last'] = last;
    final snippet = (m['snippet'] as String?)?.trim() ?? '';
    if (snippet.isNotEmpty) {
      c['snippet'] = snippet;
      c['snippet_mine'] = m['snippet_mine'] == true;
      c['snippet_at'] = last;
    }
    final members = <Map<String, Object?>>[];
    for (final p in (m['members'] as List? ?? const [])) {
      if (p is! Map) continue;
      final who = '${p['id'] ?? ''}';
      if (who.isEmpty) continue;
      final name = (p['name'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) _names[who] = name;
      members.add({'id': who});
    }
    if (members.isNotEmpty) c['members'] = members;
  }

  /// Someone's name, as the helper found it. An empty name never stands in for one.
  void _takeName(Map m) {
    final who = '${m['id'] ?? ''}';
    if (who.isEmpty) return;
    final name = (m['name'] as String?)?.trim() ?? '';
    final handle = (m['handle'] as String?)?.trim() ?? '';
    if (name.isNotEmpty) {
      _names[who] = name;
    } else if (handle.isNotEmpty) {
      _names.putIfAbsent(who, () => '@$handle');
    }
    if (m['avatar'] is String && (m['avatar'] as String).isNotEmpty) _avatars[who] = m['avatar'] as String;
  }

  /// Keeps a message in its chat; false if it was here already.
  bool _take(Map<String, Object?> m) {
    final chat = '${m['chat'] ?? ''}';
    if (chat.isEmpty) return false;
    final from = '${m['from'] ?? ''}';
    final name = (m['name'] as String?)?.trim() ?? '';
    if (name.isNotEmpty && m['mine'] != true && from.isNotEmpty) _names.putIfAbsent(from, () => name);
    final list = _messages.putIfAbsent(chat, () => []);
    final mid = '${m['id'] ?? ''}';
    final ts = (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    if (mid.isNotEmpty) {
      final had = list.where((x) => x['id'] == mid).firstOrNull;
      if (had != null) return false;
      // This account's own, sent from here a moment ago and now said back by the service: the one bubble, confirmed.
      if (m['mine'] == true) {
        final pending = list.where((x) => x['state'] == 'sending' && x['text'] == (m['text'] ?? '')).firstOrNull;
        if (pending != null) {
          pending['id'] = mid;
          pending['ts'] = ts;
          pending['state'] = 'sent';
          return true;
        }
      }
    }
    list.add({
      'id': mid.isEmpty ? 'in-$ts' : mid,
      'ts': ts,
      'from': from,
      'mine': m['mine'] == true,
      'text': m['text'] ?? '',
      'media': m['media'] ?? const [],
      'state': m['mine'] == true ? 'sent' : 'received',
      if (m['quote'] is Map) 'quote': m['quote'],
      // The reactions it already has: who → which, or a list of `{"from", "emoji"}` as a helper's history gives them.
      if (m['reactions'] is Map) 'reactions': m['reactions'],
      if (m['reactions'] is List)
        'reactions': {for (final r in m['reactions'] as List) if (r is Map && '${r['emoji'] ?? ''}'.isNotEmpty) '${r['from'] ?? ''}': '${r['emoji']}'},
    });
    list.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    final c = _chats.putIfAbsent(chat, () => {'unread': 0, 'last': 0});
    if (m.containsKey('group')) c.putIfAbsent('group', () => m['group'] == true);
    if (ts > ((c['last'] as int?) ?? 0)) c['last'] = ts;
    return true;
  }

  Map<String, Object?>? _find(String chatId, String messageId) => (_messages[chatId] ?? const []).where((x) => x['id'] == messageId).firstOrNull;

  /// Sets or takes away one person's reaction to a message kept here: each person has one at most.
  void _reaction(Map<String, Object?> m) {
    final msg = _find('${m['chat']}', '${m['target']}');
    if (msg == null) return;
    final from = '${m['from'] ?? ''}';
    final reactions = Map<String, Object?>.from(msg['reactions'] as Map? ?? const {});
    if (m['remove'] == true || '${m['emoji'] ?? ''}'.isEmpty) {
      reactions.remove(from);
    } else {
      reactions[from] = '${m['emoji']}';
    }
    msg['reactions'] = reactions;
    _save();
    notifyListeners();
  }

  // --- people to start a chat with (GMFB-61) ----------------------------------------------------------------------

  /// The chat between this account and one other person, by that person's id: the chats that are not groups and
  /// name one member. Not those deleted or blocked here, nor those held back (the Human check plugin).
  Map<String, String> get _direct {
    final gone = {...localList('deleted'), ...localList('blocked'), ...heldIds};
    final out = <String, String>{};
    for (final e in _chats.entries) {
      if (e.value['group'] == true || gone.contains(e.key)) continue;
      final members = (e.value['members'] as List? ?? const []);
      if (members.length != 1 || members.first is! Map) continue;
      final who = '${(members.first as Map)['id'] ?? ''}';
      if (who.isNotEmpty && who != _me) out.putIfAbsent(who, () => e.key);
    }
    return out;
  }

  /// Everyone there is a chat with, and whoever the helper has listed besides (Slack's members, once looked for).
  /// Not [contacts]: none of these services has contacts as a phone does, and who is a contact is what says who is a
  /// stranger (lib/inbox/human_check.dart), which someone is not for having written.
  List<InboxContact> get _people {
    if (_state != InboxState.ready) return const [];
    final out = <InboxContact>[];
    final direct = _direct;
    for (final who in direct.keys) {
      final name = (_names[who] ?? '').isNotEmpty ? _names[who]! : _titleOf(direct[who]!, _chats[direct[who]!]!);
      final handle = _listed[who]?.handle ?? '';
      out.add(InboxContact(network: id, id: who, name: name, avatar: _avatars[who] ?? _chats[direct[who]!]!['avatar'] as String?, handle: handle.isEmpty ? null : '@$handle'));
    }
    for (final e in _listed.entries) {
      if (direct.containsKey(e.key) || e.key == _me) continue;
      out.add(InboxContact(network: id, id: e.key, name: e.value.name, avatar: _avatars[e.key], handle: e.value.handle.isEmpty ? null : '@${e.value.handle}'));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Those of [_people] that [query] finds, after the service itself is asked where its helper can ([HelperService.people]):
  /// what it finds is kept in [_listed] for the run. A helper that cannot say (an older one, the service away) leaves
  /// what is known here.
  @override
  Future<List<InboxContact>> findPeople(String query) async {
    final q = query.trim();
    if (q.isEmpty || _state != InboxState.ready) return const [];
    if (service.people) {
      try {
        for (final p in (await _ask('people', {'query': q})) as List? ?? const []) {
          if (p is! Map) continue;
          final who = '${p['id'] ?? ''}';
          final name = (p['name'] as String?)?.trim() ?? '';
          if (who.isEmpty || name.isEmpty) continue;
          _listed[who] = (name: name, handle: (p['handle'] as String?)?.trim() ?? '');
          _names.putIfAbsent(who, () => name);
        }
      } catch (_) {}
    }
    return [for (final c in _people) if (contactAnswers(c, q)) c];
  }

  /// The chat with [contact]: the one there is, else one the helper opens on the service where it can (`open`: nothing
  /// is sent, and nobody is told). Null where neither.
  @override
  Future<String?> chatWith(InboxContact contact) async {
    if (_state != InboxState.ready) return null;
    final had = _direct[contact.id];
    if (had != null) return had;
    if (!service.people) return null;
    final r = await _ask('open', {'who': contact.id});
    final chat = r is Map ? '${r['id'] ?? ''}' : '';
    if (chat.isEmpty) return null;
    // Named by who it is with until the service lists it (a chat's own title comes with its first `chat` event).
    if (contact.name.isNotEmpty) _names.putIfAbsent(chat, () => contact.name);
    return chat;
  }

  // --- sending ------------------------------------------------------------------------------------------------------

  @override
  bool get canReact => true;

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (_state != InboxState.ready) throw StateError('${service.name} isn\'t connected');
    await _ask('react', {'to': chatId, 'target': messageId, 'emoji': emoji, 'remove': remove});
    _reaction({'chat': chatId, 'target': messageId, 'from': _me ?? '', 'emoji': emoji, 'remove': remove});
  }

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) {
    final quoted = _find(chatId, messageId);
    // What is quoted, with who wrote it and when: some services (LinkedIn) need those to make the reply.
    return _send(chatId, text, quote: quoted == null ? null : {'id': messageId, 'text': '${quoted['text'] ?? ''}', 'author': quoted['mine'] == true ? (_me ?? '') : '${quoted['from'] ?? ''}', 'ts': quoted['ts']});
  }

  @override
  Future<void> send(String chatId, String text) => _send(chatId, text);

  /// Sends text: its bubble is shown at once as "sending", then takes the service's id and time, or is marked failed.
  Future<void> _send(String chatId, String text, {Map<String, Object?>? quote}) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = <String, Object?>{'id': 'local-$now', 'ts': now, 'from': _me ?? '', 'mine': true, 'text': text, 'media': const [], 'state': 'sending', 'quote': ?quote};
    _messages.putIfAbsent(chatId, () => []).add(local);
    final c = _chats.putIfAbsent(chatId, () => {'unread': 0, 'last': 0});
    c['last'] = now;
    notifyListeners();
    try {
      final r = (await _ask('send', {'to': chatId, 'text': text, 'quote': ?quote}) as Map?) ?? const {};
      // Said back by the service already (its `message` event came first): that took this bubble's place.
      if (local['state'] == 'sending') {
        final sent = '${r['id'] ?? ''}';
        // The same message twice, once from here and once said back: the one from here goes.
        if (sent.isNotEmpty && _messages[chatId]!.any((x) => !identical(x, local) && x['id'] == sent)) {
          _messages[chatId]!.remove(local);
        } else {
          if (sent.isNotEmpty) local['id'] = sent;
          local['ts'] = (r['ts'] as num?)?.toInt() ?? local['ts'];
          local['state'] = 'sent';
        }
      }
      _error = null;
    } catch (e) {
      local['state'] = 'failed';
      _error = _words(e);
    }
    _save();
    notifyListeners();
  }

  @override
  bool get canSendFiles => true;

  @override
  Future<void> sendFiles(String chatId, List<String> paths, {String caption = '', bool voice = false, bool sticker = false}) async {
    if (_state != InboxState.ready) return;
    for (final (i, path) in paths.indexed) {
      final ext = path.split('.').last.toLowerCase();
      final mime = const {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic', 'mp4': 'video/mp4', 'mov': 'video/quicktime', 'm4a': 'audio/mp4', 'mp3': 'audio/mpeg', 'ogg': 'audio/ogg', 'pdf': 'application/pdf'}[ext] ??
          'application/octet-stream';
      final text = i == paths.length - 1 ? caption : '';
      try {
        final name = path.split(PlatformInfo.pathSeparator).last;
        final r = (await _ask('send_media', {'to': chatId, 'path': path, 'mime': mime, 'name': name, 'text': text}) as Map?) ?? const {};
        final ts = (r['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        final mid = '${r['id'] ?? 'local-$ts-$i'}';
        if (_find(chatId, mid) == null) {
          // What was sent is kept for its bubble: a copy in this network's own folder.
          final kept = await _keepSent(path, ts, i, name);
          final pointer = {'local': kept};
          _messages.putIfAbsent(chatId, () => []).add({
            'id': mid,
            'ts': ts,
            'from': _me ?? '',
            'mine': true,
            'text': text,
            'media': [{'local': kept, 'mime': mime, 'name': name, 'pointer': pointer, if (sticker) 'sticker': true}],
            'state': 'sent',
          });
          _files[jsonEncode(pointer).hashCode & 0x3fffffff] = kept;
        }
        _chats.putIfAbsent(chatId, () => {'unread': 0, 'last': 0})['last'] = ts;
        _error = null;
      } catch (e) {
        // The helper's own words: "Instagram files can't be sent from here yet".
        _error = _words(e);
        notifyListeners();
        rethrow;
      }
    }
    _save();
    notifyListeners();
  }

  /// Copies a file that was sent into this network's folder; the path of the copy, or [path] itself if it could not be.
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

  // --- the chats and their messages, as the screens have them -----------------------------------------------------

  /// What a chat is called: the service's title for it; else the other person's name; else plainly what it is. Never
  /// an id.
  String _titleOf(String chat, Map<String, Object?> c) {
    final title = (c['title'] as String?)?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final others = [
      for (final p in (c['members'] as List? ?? const []))
        if (p is Map && (_names['${p['id']}']?.isNotEmpty ?? false)) _names['${p['id']}']!,
    ];
    if (others.isNotEmpty) return others.join(', ');
    final direct = _names[chat];
    if (direct != null && direct.isNotEmpty) return direct;
    return c['group'] == true ? '${service.name} group' : '${service.name} chat';
  }

  @override
  List<InboxChat> get chats {
    final out = <InboxChat>[];
    for (final e in _chats.entries) {
      final c = e.value;
      final msgs = _messages[e.key] ?? const <Map<String, Object?>>[];
      final last = msgs.isEmpty ? null : msgs.last;
      // The newest words: the last message kept, unless the service's own line for the chat is newer.
      final lastAt = (last?['ts'] as int?) ?? 0;
      final fromService = ((c['snippet_at'] as int?) ?? 0) > lastAt && '${c['snippet'] ?? ''}'.isNotEmpty;
      final members = (c['members'] as List? ?? const []);
      final one = members.length == 1 && members.first is Map ? '${(members.first as Map)['id']}' : null;
      out.add(InboxChat(
        network: id,
        id: e.key,
        title: _titleOf(e.key, c),
        date: DateTime.fromMillisecondsSinceEpoch((c['last'] as int?) ?? 0),
        snippet: fromService ? '${c['snippet']}' : (last == null ? '${c['snippet'] ?? ''}' : _snippet(last)),
        unread: (c['unread'] as int?) ?? 0,
        group: c['group'] == true,
        avatar: (c['avatar'] as String?) ?? (one == null ? null : _avatars[one]),
        lastFromMe: fromService || last == null ? c['snippet_mine'] == true : last['mine'] == true,
      ));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  @override
  String? faceOf(String user) => _avatars[user];

  /// A message as one line of the chat list: its words, or what kind of thing its first attachment is.
  static String _snippet(Map<String, Object?> m) {
    final text = '${m['text'] ?? ''}'.trim();
    if (text.isNotEmpty) return text;
    final media = (m['media'] as List?) ?? const [];
    if (media.isEmpty) return '';
    final mime = '${(media.first as Map)['mime'] ?? ''}';
    return mime.startsWith('image/') ? 'Photo' : mime.startsWith('video/') ? 'Video' : mime.startsWith('audio/') ? 'Voice message' : 'File';
  }

  @override
  List<InboxMessage> messagesOf(String chatId) => [
        for (final m in _messages[chatId] ?? const <Map<String, Object?>>[])
          InboxMessage(
            id: '${m['id']}',
            text: '${m['text'] ?? ''}',
            date: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
            mine: m['mine'] == true,
            sender: m['mine'] == true ? '' : (_names['${m['from']}'] ?? ''),
            senderId: '${m['from'] ?? ''}',
            state: switch (m['state']) { 'sending' => 'sending', 'failed' => 'failed', _ => 'sent' },
            media: [for (final a in (m['media'] as List? ?? const [])) _media(a as Map)],
            reactions: signalReactions(m['reactions'] as Map?, me: _me),
            replyTo: (m['quote'] as Map?)?['id']?.toString(),
            replyText: _quoted(chatId, m['quote'])?.text,
            replySender: _quoted(chatId, m['quote'])?.sender,
            edited: m['edited'] == true,
          ),
      ];

  /// What a reply shows of the message it answers ([quote], a message's `quote`): its words and who wrote it
  /// (GMFB-44, "They simply say "a message" and you can't tell what message was actually being replied to": a reply
  /// to a picture had no words to show, and no reply named anyone). Read from the message itself where it is kept
  /// here, as it reads now; else from what the helper sent along (`text`, `from` or `author`, `name`, and `mime` for
  /// one with no words), which is all there is for one older than what is loaded.
  ({String? text, String? sender})? _quoted(String chatId, Object? quote) {
    if (quote is! Map) return null;
    final held = _find(chatId, '${quote['id'] ?? ''}');
    var text = '${quote['text'] ?? ''}'.trim();
    if (text.isEmpty && held != null) text = _snippet(held);
    final mime = '${quote['mime'] ?? ''}';
    if (text.isEmpty && mime.isNotEmpty) {
      text = _snippet({'media': [{'mime': mime}]});
    }
    final who = '${held?['from'] ?? quote['from'] ?? quote['author'] ?? ''}';
    final mine = held != null ? held['mine'] == true : who.isNotEmpty && who == _me;
    final name = (_names[who] ?? '').isNotEmpty ? _names[who]! : '${quote['name'] ?? ''}'.trim();
    return (text: text.isEmpty ? null : text, sender: mine ? 'You' : (name.isEmpty ? null : name));
  }

  /// An attachment as the screens have it. Its number is made from the helper's pointer to it, and the attachment is
  /// remembered under that number for [fileOf] to bring down.
  InboxMedia _media(Map a) {
    final key = jsonEncode(a['pointer']).hashCode & 0x3fffffff;
    _pointers[key] = a.cast<String, Object?>();
    final mime = '${a['mime'] ?? ''}';
    return InboxMedia(
      kind: InboxMedia.kindOf(mime, sticker: a['sticker'] == true),
      fileId: key,
      path: _files[key],
      name: a['name'] as String?,
      size: (a['size'] as num?)?.toInt() ?? 0,
      width: (a['width'] as num?)?.toInt() ?? 0,
      height: (a['height'] as num?)?.toInt() ?? 0,
    );
  }

  /// Whether [chatId] may have messages before the oldest kept here.
  bool hasOlder(String chatId) => !_exhausted.contains(chatId);

  /// Brings [chatId]'s recent messages from the service where few are kept, and with [older] the ones before the
  /// oldest kept.
  @override
  Future<void> load(String chatId, {bool older = false}) async {
    if (_state != InboxState.ready || _loading.contains(chatId)) return;
    final held = _messages[chatId] ?? const <Map<String, Object?>>[];
    if (!older && held.length >= 20) return;
    if (older && _exhausted.contains(chatId)) return;
    // Older than the oldest the service itself named (one sent from here and not yet said back has no id of its).
    final oldest = held.where((m) => !'${m['id']}'.startsWith('local-') && !'${m['id']}'.startsWith('in-')).firstOrNull;
    _loading.add(chatId);
    try {
      // The oldest kept, by its id and by its time: a helper pages by whichever its service does.
      final r = (await _ask('history', {'chat': chatId, if (older && oldest != null) ...{'before': '${oldest['id']}', 'before_ts': oldest['ts']}}) as Map?) ?? const {};
      var took = 0;
      for (final x in (r['messages'] as List? ?? const [])) {
        if (_take({...(x as Map).cast<String, Object?>(), 'chat': chatId})) took++;
      }
      if (r['more'] != true || (older && took == 0)) _exhausted.add(chatId);
      if (took > 0) {
        _save();
        notifyListeners();
      }
    } catch (e) {
      _error = _words(e);
      notifyListeners();
    } finally {
      _loading.remove(chatId);
    }
  }

  /// The chat open on screen: what arrives in it is not counted unread.
  String? _watching;

  @override
  set watching(String? chatId) => _watching = chatId;

  @override
  void wantFile(int fileId) => unawaited(fileOf(fileId));

  /// Files being brought down now, by id: asked for again while one is coming (a picture asks each time it is drawn,
  /// lib/ui/inbox_ui.dart), the one download is waited for. Without it two downloads of one file ran at once into one
  /// path, the helper's `.part` file shared between them: the first renamed it into place and the second's rename found
  /// nothing ("rename …/discord/files/330240540.png.part …: no such file or directory"), as Signal's did before
  /// (lib/inbox/signal.dart).
  final Map<int, Future<String?>> _fetching = {};

  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null) return known;
    // A block, not an arrow: remove's value is this very future, which whenComplete would wait for, forever.
    return _fetching[fileId] ??= _fetch(fileId).whenComplete(() {
      _fetching.remove(fileId);
    });
  }

  /// Brings the file [fileId] down through the helper; its path on this device, or null where it can't be had.
  Future<String?> _fetch(int fileId) async {
    final a = _pointers[fileId];
    if (a == null) return null;
    final local = a['local'] as String?;
    if (local != null && File(local).existsSync()) return _files[fileId] = local;
    final pointer = a['pointer'];
    if (pointer is! Map || pointer.containsKey('local')) return null;
    final ext = switch ('${a['mime'] ?? ''}'.split(';').first) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/gif' => '.gif',
      'video/mp4' => '.mp4',
      'audio/ogg' => '.ogg',
      'audio/mp4' => '.m4a',
      'application/pdf' => '.pdf',
      _ => '${a['name'] ?? ''}'.contains('.') ? '.${'${a['name']}'.split('.').last}' : '',
    };
    final path = '$_dir/files/$fileId$ext';
    if (File(path).existsSync()) return _files[fileId] = path;
    try {
      await Directory('$_dir/files').create(recursive: true);
      await _ask('download', {'pointer': pointer, 'path': path});
      _files[fileId] = path;
      notifyListeners();
      return path;
    } catch (e) {
      _error = _words(e);
      return null;
    }
  }

  @override
  Future<void> markRead(String chatId) async {
    final c = _chats[chatId];
    if (c == null) return;
    // What came while the chat was on screen was never counted, so nothing said it was still to be read on the
    // service: it stayed unread there, and came back unread here with the service's next list (GMFB-62).
    final cameOpen = _arrivedOpen.remove(chatId);
    if ((c['unread'] as int? ?? 0) == 0 && !cameOpen) return;
    c['unread'] = 0;
    _readTo(chatId, c);
    _save();
    notifyListeners();
    await _tellRead(chatId);
  }

  /// Chats a message came in while they were on screen, not yet said to the service as read.
  final Set<String> _arrivedOpen = {};

  /// What each chat was read up to when the service was last told again from [_takeChat]: once for each reading.
  final Map<String, int> _retold = {};

  /// Notes how far [chatId] is read here (`read_at`, kept with the chat): the time of its newest activity known, in
  /// the service's own time. The service's count is not taken over it until something newer comes ([_takeChat]).
  /// Only times the service gave: its own for the chat, and those of messages it named. This device's clock (a
  /// message still being sent) may run ahead of the service's, and what came in between would never be unread.
  void _readTo(String chatId, Map<String, Object?> c) {
    var at = (c['read_at'] as int?) ?? 0;
    final listed = (c['listed_at'] as int?) ?? 0;
    if (listed > at) at = listed;
    for (final m in (_messages[chatId] ?? const <Map<String, Object?>>[]).reversed) {
      final id = '${m['id']}';
      if (id.startsWith('local-') || id.startsWith('in-')) continue;
      final ts = (m['ts'] as int?) ?? 0;
      if (ts > at) at = ts;
      break;
    }
    c['read_at'] = at;
  }

  /// Tells the service [chatId] is read, up to the newest message of someone else's kept here.
  Future<void> _tellRead(String chatId) async {
    final newest = (_messages[chatId] ?? const <Map<String, Object?>>[]).where((m) => m['mine'] != true).lastOrNull;
    try {
      await _ask('read', {'to': chatId, 'upto': ?newest?['id']});
    } catch (_) {}
  }

  /// Your own message can be unsent for everyone; anyone else's is hidden only here.
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine;

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    if (forEveryone) {
      try {
        await _ask('delete', {'to': chatId, 'target': messageId});
      } catch (e) {
        _error = _words(e);
        notifyListeners();
        return;
      }
    }
    _messages[chatId]?.removeWhere((m) => m['id'] == messageId);
    _save();
    notifyListeners();
  }

  /// Gone from here only: the chat stays on the service.
  @override
  Future<void> deleteChat(String chatId) async {
    await super.deleteChat(chatId);
    _messages.remove(chatId);
    _save();
  }

  // --- keeping ------------------------------------------------------------------------------------------------------

  /// Reads what was kept ([_file]) as the helper starts, so the chats are there before it has connected.
  void _read() {
    try {
      if (!_file.existsSync()) return;
      final all = jsonDecode(_file.readAsStringSync()) as Map;
      (all['chats'] as Map? ?? const {}).forEach((k, v) => _chats['$k'] = (v as Map).cast<String, Object?>());
      (all['messages'] as Map? ?? const {}).forEach((k, v) => _messages['$k'] = [for (final m in v as List) (m as Map).cast<String, Object?>()]);
      (all['names'] as Map? ?? const {}).forEach((k, v) {
        if (v is String && v.trim().isNotEmpty) _names['$k'] = v;
      });
      (all['avatars'] as Map? ?? const {}).forEach((k, v) => _avatars['$k'] = '$v');
    } catch (_) {}
  }

  /// What is kept: every chat, and the newest [_mostKept] messages of each (older ones are the service's to give
  /// again), so the file does not grow for ever (docs/performance-audit.md, finding 4).
  String _kept() => jsonEncode({
        'chats': _chats,
        'messages': {for (final e in _messages.entries) e.key: e.value.length > _mostKept ? e.value.sublist(e.value.length - _mostKept) : e.value},
        'names': _names,
        'avatars': _avatars,
      });

  Timer? _saving;
  DateTime? _savingSince;
  Future<void> _writing = Future.value();

  /// How long after the last change the file is written, and the longest a first change waits while more keep coming
  /// (a test sets them shorter).
  @visibleForTesting
  static Duration saveAfter = const Duration(seconds: 2);
  @visibleForTesting
  static Duration saveWithin = const Duration(seconds: 10);

  /// Written two seconds after the last change, off the frame: the file is written without waiting on it. And no
  /// later than ten seconds after the first, as KeptWriter does: in a busy account something changes more often than
  /// every two seconds, and a chat read was never written, so the app opened again with it unread.
  void _save() {
    final now = DateTime.now();
    _savingSince ??= now;
    final left = saveWithin - now.difference(_savingSince!);
    _saving?.cancel();
    _saving = Timer(left < saveAfter ? (left.isNegative ? Duration.zero : left) : saveAfter, () {
      _savingSince = null;
      final text = _kept();
      _writing = _writing.then((_) async {
        try {
          await _file.parent.create(recursive: true);
          final tmp = File('${_file.path}.tmp');
          await tmp.writeAsString(text);
          await tmp.rename(_file.path);
        } catch (_) {}
      });
    });
  }

  /// Writes what is kept now (a test's end, the app going).
  @visibleForTesting
  void flush() {
    if (_saving?.isActive ?? false) {
      _saving!.cancel();
      _saving = null;
      _savingSince = null;
      try {
        _file.parent.createSync(recursive: true);
        _file.writeAsStringSync(_kept());
      } catch (_) {}
    }
  }

  /// Asks the helper for [op] and waits for its answer: the result, or a [StateError] with the helper's reason (or
  /// that it took too long).
  Future<Object?> _ask(String op, [Map<String, Object?> args = const {}]) {
    final link = _link;
    if (link == null) return Future.error(StateError('${service.name} isn\'t running'));
    final id = ++_asked;
    final done = Completer<Object?>();
    _waiting[id] = done;
    // The request's own id last: nothing in [args] may take its place (a `read` once named its message `id`).
    link.say({...args, 'id': id, 'op': op});
    // Longer than a helper gives each, so its own reason arrives.
    final wait = switch (op) { 'download' || 'send_media' => 190, 'status' || 'who' => 30, _ => 90 };
    return done.future.timeout(Duration(seconds: wait), onTimeout: () {
      _waiting.remove(id);
      throw StateError('${service.name} took too long to answer');
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
    _sub?.cancel();
    unawaited(_link?.close());
    super.dispose();
  }

  /// The app's preferences, for later use.
  AppState? get app => _app;
}

/// The helper as a child process: a line of JSON to its stdin for each thing said, a line from its stdout for each
/// thing heard, and its stderr as its log.
class _ProcessLink implements HelperLink {
  _ProcessLink(this.p, String network) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = jsonDecode(line);
        if (m is Map) _in.add(m.cast<String, Object?>());
      } catch (_) {}
    });
    // The helper's log (also beside its session): warnings and its own lines about requests go to the Developer log.
    // A helper's own lines name an op and a request number, never a message's words.
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final kept = helperLogLine(line);
      if (kept != null) Sms.instance.devLog(network, kept);
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

/// One line of an account helper's log, shortened, where it is worth keeping in the Developer log: its own lines about
/// requests, and anything warned of; null for the rest.
@visibleForTesting
String? helperLogLine(String line) {
  Map? m;
  try {
    final d = jsonDecode(line);
    if (d is Map) m = d;
  } catch (_) {}
  if (m == null) return line.trim().isEmpty ? null : (line.length > 300 ? line.substring(0, 300) : line);
  final level = '${m['level'] ?? ''}';
  final message = '${m['message'] ?? ''}';
  const ours = {'asked', 'answered'};
  if (level != 'warn' && level != 'error' && level != 'fatal' && !ours.contains(message)) return null;
  const fields = ['op', 'req', 'took', 'error', 'component'];
  final out = [level, message, for (final k in fields) if (m[k] != null) '$k=${m[k]}'].join(' ');
  return out.length > 300 ? out.substring(0, 300) : out;
}
