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
import 'signal.dart' show signalReactions;

/// What the WhatsApp helper is to the app: lines out, lines in. A process in the app; a stand-in in a test.
abstract class WhatsAppLink {
  Stream<Map<String, Object?>> get heard;
  void say(Map<String, Object?> line);
  Future<void> close();
}

/// What the person is told before linking WhatsApp, and in WhatsApp's settings (Matt, 2026-11-17: "enable whatsapp
/// but warn the user that it's unsupported by whatsapp").
const whatsAppWarning =
    'WhatsApp doesn\'t support or allow other apps. Uplink links as another of your devices, the way WhatsApp Web does, through the open-source whatsmeow library. WhatsApp may suspend or ban accounts it finds using unofficial apps. Use it at your own risk.';

/// WhatsApp, linked to the person's account as another device, as WhatsApp Web is (Matt, 2026-11-17: "enable whatsapp
/// but warn the user that it's unsupported by whatsapp"): the helper `whatsapp-sidecar` (sidecar/whatsapp, on
/// whatsmeow, MPL-2.0) runs as a child process and speaks sidecar/whatsapp/PROTOCOL.md, as Signal's does.
///
/// Signing in is WhatsApp's own linking: a QR code that WhatsApp on the person's phone scans (Settings › Linked devices
/// › Link a device), or an eight-letter code typed there instead. Unlike Signal, WhatsApp gives a new linked device its
/// recent history, which arrives as `history` events and is kept here ([_file]) with what comes after. Chats and people
/// are named by JID; messages by WhatsApp's own id (a string).
class WhatsApp extends InboxNetwork {
  WhatsApp({this.soon = false, this.link, this.folder});

  @override
  final bool soon;

  /// The helper, in a test. Null: the process, once [start] finds it.
  final Future<WhatsAppLink?> Function()? link;

  /// Where the helper's store and the chats kept here are. Null: this app's own folder.
  final String? folder;

  @override
  String get id => 'whatsapp';
  @override
  String get name => 'WhatsApp';

  WhatsAppLink? _link;
  StreamSubscription<Map<String, Object?>>? _sub;
  AppState? _app;
  InboxState _state = InboxState.unavailable;
  String? _error, _account, _qr, _pairCode;

  /// Requests to the helper are numbered; each waits here, by its number, for the helper's answer ([_ask], [_heard]).
  int _asked = 0;
  final Map<int, Completer<Object?>> _waiting = {};

  /// The chats kept here, and each one's messages, oldest first.
  final Map<String, Map<String, Object?>> _chats = {};
  final Map<String, List<Map<String, Object?>>> _messages = {};

  /// Who is who: names and numbers by JID, groups' titles, pictures.
  final Map<String, String> _names = {};
  final Map<String, String> _numbers = {};
  final Map<String, String?> _avatars = {};
  final Set<String> _groups = {};

  /// The people in WhatsApp's synced address book, by JID, with their numbers.
  final Map<String, String?> _contacts = {};

  /// Attachments by the number the screens know them by, and their files once brought down.
  final Map<int, Map<String, Object?>> _pointers = {};
  final Map<int, String> _files = {};

  /// This account's own JID.
  String? _jid;

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut || _state == InboxState.signingIn ? InboxStep.code : InboxStep.none;
  @override
  String? get error => _error;
  @override
  String? get account => _account;

  /// The text to draw as a QR code, while linking.
  String? get qr => _qr;

  /// The eight-letter code to type on the phone instead, once asked for ([pairWithPhone]).
  String? get pairCode => _pairCode;

  String get _dir => folder ?? (PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/whatsapp' : '${DeskStore.defaultDir().path}/whatsapp');
  File get _file => File('$_dir/chats.json');

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (soon) return;
    final link = await (this.link ?? _process)();
    if (link == null) {
      _state = InboxState.unavailable;
      _error = 'The WhatsApp helper isn\'t in this build.';
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

  /// The helper: beside the app on a computer (Contents/Helpers on a Mac), the phone's native libraries on Android.
  Future<WhatsAppLink?> _process() async {
    String? binary;
    if (PlatformInfo.isAndroid) {
      try {
        binary = await const MethodChannel('ghost_messaging/sms').invokeMethod<String>('helperPath', {'name': 'whatsappsidecar'});
      } catch (_) {}
    } else if (PlatformInfo.isMacOS || PlatformInfo.isWindows) {
      final named = PlatformInfo.environment['GHOST_WHATSAPPSIDECAR'];
      final exe = File(PlatformInfo.resolvedExecutable).parent.path;
      for (final c in [
        ?named,
        if (PlatformInfo.isWindows) '$exe\\whatsapp-sidecar.exe' else '$exe/../Helpers/whatsapp-sidecar',
        '${Directory.current.path}/build/whatsapp-sidecar/${PlatformInfo.isWindows ? 'windows/whatsapp-sidecar.exe' : 'mac/whatsapp-sidecar'}',
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

  // --- linking ------------------------------------------------------------------------------------------------------

  /// Asks the helper for a QR code to link this device with ([qr]). Only after the person has agreed to the warning
  /// ([whatsAppWarning]; lib/ui/inbox_signin_whatsapp.dart).
  Future<void> begin() async {
    if (_link == null) return;
    _error = null;
    _qr = null;
    _pairCode = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      await _ask('link', {'name': 'Uplink'});
    } catch (e) {
      _error = '$e';
      _state = InboxState.signedOut;
      notifyListeners();
    }
  }

  /// WhatsApp's "Link with phone number instead": an eight-letter code for [phone] ([pairCode]), typed on the phone.
  Future<String?> pairWithPhone(String phone) async {
    if (_link == null) return null;
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) {
      _error = 'Type your WhatsApp number with its country code.';
      notifyListeners();
      return null;
    }
    _error = null;
    _state = InboxState.signingIn;
    notifyListeners();
    try {
      final r = (await _ask('pair_phone', {'phone': digits}) as Map?) ?? const {};
      _pairCode = r['code'] as String?;
    } catch (e) {
      _error = '$e';
    }
    notifyListeners();
    return _pairCode;
  }

  /// The helper says this device is linked, and to whom: ready. The account is shown by its number, else its name.
  void _signedIn(Map s) {
    final number = (s['number'] as String?)?.trim() ?? '';
    final name = (s['name'] as String?)?.trim() ?? '';
    _account = number.isNotEmpty ? number : (name.isNotEmpty ? name : null);
    _jid = s['jid'] as String?;
    _qr = null;
    _pairCode = null;
    _state = InboxState.ready;
    _error = null;
    notifyListeners();
    unawaited(_who());
  }

  @override
  Future<void> signOut() async {
    try {
      await _ask('unlink');
    } catch (_) {}
    _chats.clear();
    _messages.clear();
    _ids.clear();
    _contacts.clear();
    _account = null;
    _state = InboxState.signedOut;
    _save();
    notifyListeners();
  }

  DateTime? _whoAt;

  /// Names and groups, from WhatsApp's synced contacts and the groups the account is in.
  Future<void> _who() async {
    _whoAt = DateTime.now();
    try {
      _takeContacts((await _ask('contacts')) as List? ?? const []);
      for (final g in (await _ask('groups')) as List? ?? const []) {
        _takeGroup(g as Map);
      }
      notifyListeners();
      _save();
    } catch (_) {}
  }

  /// Takes what the helper says of a group: that it is one, its title and its picture.
  void _takeGroup(Map m) {
    final gid = m['id'] as String?;
    if (gid == null) return;
    _groups.add(gid);
    final title = (m['title'] as String?)?.trim();
    if (title != null && title.isNotEmpty) _names[gid] = title;
    if (m['avatar'] is String) _avatars[gid] = m['avatar'] as String;
  }

  /// Takes the account's contacts as the helper lists them: each one's name, and their number where there is one.
  void _takeContacts(List list) {
    for (final c in list) {
      final m = c as Map;
      final jid = m['jid'] as String?;
      if (jid == null) continue;
      _takeName(m);
      final number = (m['number'] as String?)?.trim();
      _contacts[jid] = number == null || number.isEmpty ? null : number;
    }
  }

  /// Someone's name, as the helper found it. An empty name never stands in for one.
  void _takeName(Map m) {
    final jid = m['jid'] as String?;
    if (jid == null) return;
    final name = (m['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) _names[jid] = name;
    if (m['avatar'] is String) _avatars[jid] = m['avatar'] as String;
    final number = (m['number'] as String?)?.trim();
    if (number != null && number.isNotEmpty) _numbers[jid] = number;
  }

  @override
  List<InboxContact> get contacts => [
        for (final e in _contacts.entries)
          if (e.key != _jid) InboxContact(network: id, id: e.key, name: _names[e.key] ?? e.value ?? 'Someone', number: e.value, avatar: _avatars[e.key]),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// A chat with someone on WhatsApp is named by their JID: it is in the list from the first message sent.
  @override
  Future<String?> chatWith(InboxContact contact) async => _state == InboxState.ready ? contact.id : null;

  /// A WhatsApp group as its drawer shows it (sidecar/whatsapp group_info). Read only: changes are made in WhatsApp.
  @override
  Future<GroupDetails?> groupDetails(String chatId) async {
    if (_state != InboxState.ready || !_groups.contains(chatId)) return null;
    final m = await _ask('group_info', {'to': chatId}) as Map?;
    if (m == null) return null;
    _takeGroup(m);
    return whatsAppGroupDetails(m, names: _names);
  }

  // --- what the helper says ---------------------------------------------------------------------------------------

  /// One line from the helper: an answer to a numbered request (`id` with `ok`), or an event (`ev`) of its own.
  void _heard(Map<String, Object?> m) {
    final id = m['id'];
    if (id is num && m.containsKey('ok')) {
      final w = _waiting.remove(id.toInt());
      if (w == null) return;
      m['ok'] == true ? w.complete(m['result']) : w.completeError(StateError('${m['error'] ?? 'WhatsApp did not answer'}'));
      return;
    }
    switch (m['ev']) {
      case 'qr':
        _qr = m['url'] as String?;
        _state = InboxState.signingIn;
        notifyListeners();
      case 'pair_code':
        _pairCode = m['code'] as String?;
        notifyListeners();
      case 'linked':
        _signedIn(m);
      case 'link_failed':
        _qr = null;
        _pairCode = null;
        _state = InboxState.signedOut;
        _error = (m['error'] as String?) ?? 'Linking did not finish. Try again.';
        notifyListeners();
      case 'banned':
        _error = (m['error'] as String?) ?? 'WhatsApp temporarily banned this account.';
        notifyListeners();
      case 'unlinked':
        _account = null;
        _state = InboxState.signedOut;
        _error = 'WhatsApp removed this device. Link it again to carry on.';
        notifyListeners();
      case 'contacts':
        _takeContacts((m['list'] as List?) ?? const []);
        notifyListeners();
      case 'name':
        _takeName(m);
        _save();
        notifyListeners();
      case 'group':
        _takeGroup(m);
        _save();
        notifyListeners();
      case 'connected':
        final now = DateTime.now();
        if (_whoAt == null || now.difference(_whoAt!) > const Duration(minutes: 1)) unawaited(_who());
      case 'history':
        _history(m);
      case 'message':
        if (_take(m)) {
          final chat = '${m['chat']}';
          if (m['mine'] != true) _chats[chat]!['unread'] = ((_chats[chat]!['unread'] as int?) ?? 0) + 1;
          _save();
          notifyListeners();
        }
      case 'edited':
        final msg = _find('${m['chat']}', '${m['target_id']}');
        if (msg != null) {
          msg['text'] = m['text'] ?? '';
          _save();
          notifyListeners();
        }
      case 'reaction':
        _reaction(m);
      case 'receipt':
        final kind = m['kind'] == 'read' ? 'read' : 'delivered';
        final ids = {for (final i in (m['ids'] as List? ?? const [])) '$i'};
        for (final x in _messages['${m['chat']}'] ?? const <Map<String, Object?>>[]) {
          if (x['mine'] == true && ids.contains(x['id']) && x['state'] != 'read') x['state'] = kind;
        }
        _save();
        notifyListeners();
      case 'deleted':
        _messages['${m['chat']}']?.removeWhere((x) => x['id'] == '${m['target_id']}');
        _ids.remove('${m['chat']}');
        _save();
        notifyListeners();
    }
  }

  /// One chat of WhatsApp's history sync: its name, its unread count, and its messages, merged with what is kept.
  void _history(Map<String, Object?> m) {
    final chat = '${m['chat']}';
    final group = m['group'] == true;
    if (group) _groups.add(chat);
    final name = (m['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) _names.putIfAbsent(chat, () => name);
    final fresh = !_chats.containsKey(chat);
    for (final x in (m['messages'] as List? ?? const [])) {
      _take((x as Map).cast<String, Object?>());
    }
    final c = _chats.putIfAbsent(chat, () => {'unread': 0});
    if (fresh) c['unread'] = (m['unread'] as num?)?.toInt() ?? 0;
    final last = (m['last'] as num?)?.toInt() ?? 0;
    if (last > ((c['last'] as int?) ?? 0)) c['last'] = last;
    if (c['last'] == null) c['last'] = 0;
    _save();
    notifyListeners();
  }

  /// Keeps a message (a live one or one from history) in its chat; false if it was here already.
  bool _take(Map<String, Object?> m) {
    final chat = '${m['chat']}';
    final group = m['group'] == true;
    if (group) _groups.add(chat);
    final from = '${m['from'] ?? ''}';
    final name = (m['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty && m['mine'] != true) {
      if (group) {
        _names.putIfAbsent(from, () => name);
      } else {
        _names.putIfAbsent(chat, () => name);
      }
    }
    final list = _messages.putIfAbsent(chat, () => []);
    final mid = '${m['id'] ?? ''}';
    final ids = _idsOf(chat, list);
    if (mid.isNotEmpty && ids.contains(mid)) return false;
    final ts = (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final inOrder = list.isEmpty || ts >= (list.last['ts'] as int);
    ids.add(mid.isEmpty ? 'in-$ts' : mid);
    list.add({
      'id': mid.isEmpty ? 'in-$ts' : mid,
      'ts': ts,
      'from': from,
      'mine': m['mine'] == true,
      'text': m['text'] ?? '',
      'media': m['media'] ?? const [],
      'state': m['mine'] == true ? 'sent' : 'received',
      if (m['quote'] is Map) 'quote': m['quote'],
      if (m['reactions'] is Map) 'reactions': m['reactions'],
    });
    // Sorted only where it came out of order (history arrives oldest first, live messages newest last): a history
    // sync of thousands sorted the whole chat for each one (docs/performance-audit.md, finding 4).
    if (!inOrder) list.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    final c = _chats.putIfAbsent(chat, () => {'unread': 0});
    if (ts > ((c['last'] as int?) ?? 0)) c['last'] = ts;
    return true;
  }

  /// The ids of [chat]'s messages, for knowing one that is here already without looking through them all. Made from
  /// the list when it is first wanted, and again whenever the two no longer agree (a message deleted, one's id changed
  /// as it was sent).
  final Map<String, Set<String>> _ids = {};
  Set<String> _idsOf(String chat, List<Map<String, Object?>> list) {
    final had = _ids[chat];
    if (had != null && had.length == list.length) return had;
    return _ids[chat] = {for (final x in list) '${x['id']}'};
  }

  Map<String, Object?>? _find(String chatId, String messageId) => (_messages[chatId] ?? const []).where((x) => x['id'] == messageId).firstOrNull;

  /// A reaction put on a message or taken off: one a person, kept on the message as who gave which.
  void _reaction(Map<String, Object?> m) {
    final msg = _find('${m['chat']}', '${m['target_id']}');
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

  @override
  bool get canReact => true;

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (_state != InboxState.ready) throw StateError('WhatsApp isn\'t connected');
    final msg = _find(chatId, messageId);
    if (msg == null) throw StateError('That message isn\'t one WhatsApp can react to');
    final author = msg['mine'] == true ? '' : '${msg['from']}';
    await _ask('react', {'to': chatId, 'author': author, 'target': messageId, 'emoji': emoji, 'remove': remove});
    _reaction({'chat': chatId, 'target_id': messageId, 'from': _jid ?? '', 'emoji': emoji, 'remove': remove});
  }

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) async {
    final quoted = _find(chatId, messageId);
    final quote = quoted == null ? null : {'id': messageId, 'author': quoted['mine'] == true ? (_jid ?? '') : '${quoted['from']}', 'text': '${quoted['text'] ?? ''}'};
    await _send(chatId, text, quote: quote);
  }

  @override
  Future<void> send(String chatId, String text) => _send(chatId, text);

  /// Sends [text], quoting [quote] where it is a reply: kept at once as "sending" under an id of its own (`local-`
  /// and the time), which WhatsApp's id replaces once the helper answers.
  Future<void> _send(String chatId, String text, {Map<String, Object?>? quote}) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = <String, Object?>{'id': 'local-$now', 'ts': now, 'from': _jid ?? '', 'mine': true, 'text': text, 'media': const [], 'state': 'sending', 'quote': ?quote};
    _messages.putIfAbsent(chatId, () => []).add(local);
    _chats.putIfAbsent(chatId, () => {'unread': 0})['last'] = now;
    notifyListeners();
    try {
      final r = (await _ask('send', {'to': chatId, 'text': text, 'quote': ?quote}) as Map?) ?? const {};
      local['id'] = r['id'] ?? local['id'];
      _ids.remove(chatId);
      local['ts'] = (r['ts'] as num?)?.toInt() ?? local['ts'];
      local['state'] = 'sent';
      _error = null;
    } catch (e) {
      local['state'] = 'failed';
      _error = '$e';
    }
    _save();
    notifyListeners();
  }

  // --- the chats and their messages, as the screens have them -----------------------------------------------------

  /// What a chat is called: the group's title or the person's name; else their number; else plainly what it is.
  String _titleOf(String chat, bool group) {
    final name = _names[chat]?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (group) return 'WhatsApp group';
    return _numbers[chat] ?? _contacts[chat] ?? _numberOf(chat) ?? 'WhatsApp contact';
  }

  /// "+15550100" from "15550100@s.whatsapp.net".
  static String? _numberOf(String jid) {
    final at = jid.indexOf('@');
    if (at <= 0 || !jid.endsWith('@s.whatsapp.net')) return null;
    return '+${jid.substring(0, at)}';
  }

  @override
  List<InboxChat> get chats {
    final out = <InboxChat>[];
    for (final e in _chats.entries) {
      final msgs = _messages[e.key] ?? const <Map<String, Object?>>[];
      final last = msgs.isEmpty ? null : msgs.last;
      final group = _groups.contains(e.key);
      out.add(InboxChat(
        network: id,
        id: e.key,
        title: _titleOf(e.key, group),
        date: DateTime.fromMillisecondsSinceEpoch((e.value['last'] as int?) ?? 0),
        snippet: last == null ? '' : _snippet(last),
        unread: (e.value['unread'] as int?) ?? 0,
        group: group,
        avatar: _avatars[e.key],
        lastFromMe: last?['mine'] == true,
      ));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// A message in a line, for the list: its words, else what kind of file came.
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
            sender: m['mine'] == true ? '' : (_names['${m['from']}'] ?? _numberOf('${m['from']}') ?? ''),
            senderId: m['mine'] == true ? (_jid ?? '') : '${m['from'] ?? ''}',
            state: switch (m['state']) { 'sending' => 'sending', 'failed' => 'failed', _ => 'sent' },
            media: [for (final a in (m['media'] as List? ?? const [])) _media(a as Map)],
            reactions: signalReactions(m['reactions'] as Map?, me: _jid),
            replyTo: (m['quote'] as Map?)?['id']?.toString(),
            replyText: (m['quote'] as Map?)?['text'] as String?,
            replySender: _quoteName((m['quote'] as Map?)?['author'] as String?),
          ),
      ];

  @override
  String? faceOf(String user) => _avatars[user];

  /// Who a quoted message was by, to show over the quote: "You", their name, else their number.
  String? _quoteName(String? jid) {
    if (jid == null || jid.isEmpty) return null;
    if (jid == _jid) return 'You';
    return _names[jid] ?? _numbers[jid] ?? _contacts[jid] ?? _numberOf(jid);
  }

  /// An attachment as the screens show it. The number it goes by is its pointer's hash, kept to 30 bits so it is
  /// never negative; what the helper said of it is kept under that number, to bring it down by.
  InboxMedia _media(Map a) {
    final key = jsonEncode(a['pointer']).hashCode & 0x3fffffff;
    _pointers[key] = a.cast<String, Object?>();
    final mime = '${a['mime'] ?? ''}';
    return InboxMedia(
      // A WhatsApp sticker (its pointer is one), or one of Uplink's sent from here: drawn on its own, with no bubble.
      kind: InboxMedia.kindOf(mime, sticker: a['sticker'] == true || (a['pointer'] as Map?)?['kind'] == 'sticker'),
      fileId: key,
      path: _files[key],
      name: a['name'] as String?,
      size: (a['size'] as num?)?.toInt() ?? 0,
      width: (a['width'] as num?)?.toInt() ?? 0,
      height: (a['height'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> load(String chatId, {bool older = false}) async {}

  @override
  set watching(String? chatId) {}

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
          : voice
          ? 'audio/ogg; codecs=opus'
          : const {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic', 'mp4': 'video/mp4', 'mov': 'video/quicktime', 'm4a': 'audio/mp4', 'ogg': 'audio/ogg', 'pdf': 'application/pdf'}[ext] ??
              'application/octet-stream';
      final text = i == paths.length - 1 ? caption : '';
      try {
        final name = path.split(PlatformInfo.pathSeparator).last;
        final r = (await _ask('send_media', {'to': chatId, 'path': path, 'mime': mime, 'name': name, 'text': text}) as Map?) ?? const {};
        final ts = (r['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        // What was sent is kept for its bubble: a copy in WhatsApp's own folder, and WhatsApp's pointer to fetch it again.
        final kept = await _keepSent(path, ts, i, name);
        final pointer = r['pointer'] is Map ? r['pointer'] : {'local': kept};
        _messages.putIfAbsent(chatId, () => []).add({
          'id': r['id'] ?? 'local-$ts-$i',
          'ts': ts,
          'from': _jid ?? '',
          'mine': true,
          'text': text,
          'media': [{'local': kept, 'mime': mime, 'name': name, 'pointer': pointer, if (sticker) 'sticker': true}],
          'state': 'sent',
        });
        _files[jsonEncode(pointer).hashCode & 0x3fffffff] = kept;
        _chats.putIfAbsent(chatId, () => {'unread': 0})['last'] = ts;
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

  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null) return known;
    final a = _pointers[fileId];
    if (a == null) return null;
    final local = a['local'] as String?;
    if (local != null && File(local).existsSync()) return _files[fileId] = local;
    final pointer = a['pointer'];
    if (pointer is! Map || pointer['kind'] == null) return null;
    final ext = switch ('${a['mime'] ?? ''}'.split(';').first) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/webp' => '.webp',
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
      _error = '$e';
      return null;
    }
  }

  @override
  Future<void> markRead(String chatId) async {
    final c = _chats[chatId];
    if (c == null || (c['unread'] as int? ?? 0) == 0) return;
    c['unread'] = 0;
    _save();
    notifyListeners();
    final unread = [for (final m in _messages[chatId] ?? const <Map<String, Object?>>[]) if (m['mine'] != true) m].reversed.take(20).toList();
    final byAuthor = <String, List<String>>{};
    for (final m in unread) {
      byAuthor.putIfAbsent('${m['from']}', () => []).add('${m['id']}');
    }
    for (final e in byAuthor.entries) {
      try {
        await _ask('read', {'to': chatId, 'author': e.key, 'ids': e.value});
      } catch (_) {}
    }
  }

  /// Your own message can be deleted for everyone; anyone else's only here.
  @override
  bool canDeleteForEveryone(String chatId, InboxMessage message) => message.mine;

  @override
  Future<void> deleteMessage(String chatId, String messageId, {bool forEveryone = false}) async {
    if (forEveryone) {
      try {
        await _ask('delete', {'to': chatId, 'target': messageId});
      } catch (e) {
        _error = '$e';
      }
    }
    _messages[chatId]?.removeWhere((m) => m['id'] == messageId);
    _ids.remove(chatId);
    _save();
    notifyListeners();
  }

  @override
  bool get canBlock => true;

  /// Blocked on WhatsApp itself through the helper, then in Uplink's list. A one-to-one chat's id is the person's JID.
  @override
  Future<void> block(String chatId, {required String name, bool on = true}) async {
    if (_groups.contains(chatId)) throw StateError('Only a person can be blocked');
    await _ask('block', {'jid': chatId, 'on': on});
    await super.block(chatId, name: name, on: on);
  }

  /// WhatsApp's block list: Uplink's list is made the same.
  @override
  Future<void> refreshBlocked() async {
    if (state != InboxState.ready) return;
    final List list;
    try {
      list = (await _ask('blocked')) as List? ?? const [];
    } catch (_) {
      return;
    }
    final there = {for (final p in list) '${(p as Map)['jid']}': '${p['name'] ?? ''}'.trim().isEmpty ? '${p['number'] ?? ''}' : '${p['name']}'};
    for (final id in localList('blocked')) {
      if (!there.containsKey(id)) keepBlocked(id, on: false);
    }
    there.forEach((id, name) => keepBlocked(id, name: name));
    notifyListeners();
  }

  /// Gone from here only: the chat stays in WhatsApp on the phone.
  @override
  Future<void> deleteChat(String chatId) async {
    _chats.remove(chatId);
    _messages.remove(chatId);
    _ids.remove(chatId);
    _save();
    notifyListeners();
  }

  // --- keeping ------------------------------------------------------------------------------------------------------

  /// Reads the file back, to show what was seen before the helper has said anything.
  void _read() {
    try {
      if (!_file.existsSync()) return;
      final all = jsonDecode(_file.readAsStringSync()) as Map;
      (all['chats'] as Map? ?? const {}).forEach((k, v) => _chats['$k'] = (v as Map).cast<String, Object?>());
      (all['messages'] as Map? ?? const {}).forEach((k, v) => _messages['$k'] = [for (final m in v as List) (m as Map).cast<String, Object?>()]);
      (all['names'] as Map? ?? const {}).forEach((k, v) {
        if (v is String && v.trim().isNotEmpty) _names['$k'] = v;
      });
      (all['numbers'] as Map? ?? const {}).forEach((k, v) => _numbers['$k'] = '$v');
      _groups.addAll((all['groups'] as List? ?? const []).map((g) => '$g'));
    } catch (_) {}
  }

  /// What is kept, as it stands: handed to [_writer], which makes the file elsewhere (lib/inbox/kept_writer.dart).
  Map<String, Object?> _keptNow() => {'chats': _chats, 'messages': _messages, 'names': _names, 'numbers': _numbers, 'groups': _groups.toList()};

  late final KeptWriter _writer = KeptWriter(file: () => _file, snapshot: _keptNow);
  void _save() => _writer.save();

  /// Writes what is kept now (a test's end, the app going).
  @visibleForTesting
  void flush() => _writer.flush();

  /// Asks the helper to do [op] and waits for its answer; fails with the helper's reason, or where it never answers.
  Future<Object?> _ask(String op, [Map<String, Object?> args = const {}]) {
    final link = _link;
    if (link == null) return Future.error(StateError('WhatsApp isn\'t running'));
    final id = ++_asked;
    final done = Completer<Object?>();
    _waiting[id] = done;
    link.say({'id': id, 'op': op, ...args});
    // Longer than the helper gives each (sidecar/whatsapp's do: a minute, three for files), so its own reason arrives.
    final wait = switch (op) { 'download' || 'send_media' => 190, 'send' || 'react' || 'delete' || 'read' || 'groups' || 'group_info' || 'pair_phone' => 75, _ => 30 };
    return done.future.timeout(Duration(seconds: wait), onTimeout: () {
      _waiting.remove(id);
      throw StateError('WhatsApp took too long to answer');
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

  /// The app's preferences, for later use (a chat's own settings).
  AppState? get app => _app;
}

/// The helper as a process: a line of JSON each way on its stdin and stdout, and its log on stderr.
class _ProcessLink implements WhatsAppLink {
  _ProcessLink(this.p) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = jsonDecode(line);
        if (m is Map) _in.add(m.cast<String, Object?>());
      } catch (_) {}
    });
    // The helper's log (also whatsapp.log beside its store): its own lines and whatsmeow's warnings go to the Developer
    // log. The helper's own lines name an op and a request number, never a message's words.
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final kept = whatsAppLogLine(line);
      if (kept != null) Sms.instance.devLog('whatsapp', kept);
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

/// One line of the WhatsApp helper's log, shortened, where it is worth keeping in the Developer log: the helper's own
/// lines about requests, and anything warned of; null for the rest.
@visibleForTesting
String? whatsAppLogLine(String line) {
  Map? m;
  try {
    final d = jsonDecode(line);
    if (d is Map) m = d;
  } catch (_) {}
  if (m == null) return line.trim().isEmpty ? null : (line.length > 300 ? line.substring(0, 300) : line);
  final level = '${m['level'] ?? ''}';
  final message = '${m['message'] ?? ''}';
  const ours = {'asked', 'answered', 'temporarily banned', 'another copy of this device connected', 'message not decrypted'};
  if (level != 'warn' && level != 'error' && level != 'fatal' && !ours.contains(message)) return null;
  const fields = ['op', 'req', 'took', 'error', 'component', 'ban'];
  final out = [level, message, for (final k in fields) if (m[k] != null) '$k=${m[k]}'].join(' ');
  return out.length > 300 ? out.substring(0, 300) : out;
}

/// A WhatsApp group as the helper's group_info gives it (sidecar/whatsapp groupInfo), in the drawer's words. Read
/// only here: WhatsApp's own app changes it.
GroupDetails whatsAppGroupDetails(Map m, {Map<String, String> names = const {}}) {
  GroupPerson person(Object? raw) {
    final p = raw as Map;
    final jid = '${p['jid']}';
    final number = (p['number'] as String?)?.trim();
    final name = (p['name'] as String?)?.trim();
    return GroupPerson(
      id: jid,
      name: name != null && name.isNotEmpty ? name : (names[jid] ?? (number != null && number.isNotEmpty ? number : 'Someone on WhatsApp')),
      number: number == null || number.isEmpty ? null : number,
      admin: p['admin'] == true,
      owner: p['owner'] == true,
      me: p['me'] == true,
    );
  }

  return GroupDetails(
    title: '${m['title'] ?? ''}'.trim().isEmpty ? 'WhatsApp group' : '${m['title']}'.trim(),
    description: '${m['description'] ?? ''}',
    photo: m['avatar'] as String?,
    timer: (m['timer'] as num?)?.toInt() ?? 0,
    people: [for (final p in (m['people'] as List? ?? const [])) person(p)],
    admin: m['admin'] == true,
    editInfoAdminsOnly: m['edit_info'] == 'admins',
    addPeopleAdminsOnly: m['add_members'] == 'admins',
    announcementsOnly: m['announcements_only'] == true,
    supports: const {},
  );
}
