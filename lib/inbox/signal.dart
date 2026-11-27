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

/// What the Signal helper is to the app: lines out, lines in. A process in the app; a stand-in in a test.
abstract class SignalLink {
  Stream<Map<String, Object?>> get heard;
  void say(Map<String, Object?> line);
  Future<void> close();
}

/// Signal, linked to the person's account as another device, as Signal Desktop is (Matt, 2026-11-15: "Lets wire it
/// up for signal through the mautrix"): the helper `signal-sidecar` (sidecar/signal, on mautrix-signal's signalmeow and
/// Signal's libsignal, GNU AGPL) runs as a child process and speaks sidecar/signal/PROTOCOL.md.
///
/// Signing in is Signal's own linking: the helper gives a `sgnl://linkdevice` address, drawn as a QR code that Signal
/// on the person's phone scans (Settings › Linked devices › Link new device). Signal keeps no history for a new linked
/// device, so this keeps what arrives from then on, in its own file ([_file]). Signal has no API for other apps; this
/// is the way Signal Desktop and mautrix-signal go, and may need mending when Signal changes. Offered as Coming soon
/// until it has been proven.
class Signal extends InboxNetwork {
  @override
  bool get official => true;

  Signal({this.soon = false, this.link, this.folder});

  @override
  final bool soon;

  /// The helper, in a test. Null: the process, once [start] finds it.
  final Future<SignalLink?> Function()? link;

  /// Where the helper's store and the chats kept here are. Null: this app's own folder.
  final String? folder;

  @override
  String get id => 'signal';
  @override
  String get name => 'Signal';

  SignalLink? _link;
  StreamSubscription<Map<String, Object?>>? _sub;
  AppState? _app;
  InboxState _state = InboxState.unavailable;
  String? _error, _account, _qr;

  /// Requests to the helper are numbered; each waits here, by its number, for the helper's answer ([_ask], [_heard]).
  int _asked = 0;
  final Map<int, Completer<Object?>> _waiting = {};

  /// The chats kept here, and each one's messages, oldest first.
  final Map<String, Map<String, Object?>> _chats = {};
  final Map<String, List<Map<String, Object?>>> _messages = {};

  /// Who is who: names by ACI, and groups' titles.
  final Map<String, String> _names = {};
  final Map<String, String?> _avatars = {};
  final Set<String> _groups = {};

  /// Attachments by the number the screens know them by, and their files once brought down.
  final Map<int, Map<String, Object?>> _pointers = {};
  final Map<int, String> _files = {};

  @override
  InboxState get state => _state;
  @override
  InboxStep get step => _state == InboxState.signedOut || _state == InboxState.signingIn ? InboxStep.code : InboxStep.none;
  @override
  String? get error => _error;
  @override
  String? get account => _account;

  /// The `sgnl://linkdevice` address to draw as a QR code, while linking.
  String? get qr => _qr;

  String get _dir => folder ?? (PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/signal' : '${DeskStore.defaultDir().path}/signal');
  File get _file => File('$_dir/chats.json');

  @override
  Future<void> start(AppState app) async {
    _app = app;
    if (soon) return;
    final link = await (this.link ?? _process)();
    if (link == null) {
      _state = InboxState.unavailable;
      _error = 'The Signal helper isn\'t in this build.';
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
  Future<SignalLink?> _process() async {
    String? binary;
    if (PlatformInfo.isAndroid) {
      try {
        binary = await const MethodChannel('ghost_messaging/sms').invokeMethod<String>('helperPath', {'name': 'signalsidecar'});
      } catch (_) {}
    } else if (PlatformInfo.isMacOS || PlatformInfo.isWindows) {
      final named = PlatformInfo.environment['GHOST_SIGNALSIDECAR'];
      final exe = File(PlatformInfo.resolvedExecutable).parent.path;
      for (final c in [
        ?named,
        if (PlatformInfo.isWindows) '$exe\\signal-sidecar.exe' else '$exe/../Helpers/signal-sidecar',
        '${Directory.current.path}/build/signal-sidecar/${PlatformInfo.isWindows ? 'windows/signal-sidecar.exe' : 'mac/signal-sidecar'}',
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
      // On the phone libsignal needs Android's shared C++ library, which goes beside the helper
      // (tool/build-signalsidecar.sh): the helper is started with its folder on the library path.
      final env = PlatformInfo.isAndroid ? {'LD_LIBRARY_PATH': File(binary).parent.path} : null;
      return _ProcessLink(await Process.start(binary, ['--dir', _dir], environment: env));
    } catch (_) {
      return null;
    }
  }

  // --- linking ------------------------------------------------------------------------------------------------------

  /// Asks the helper for a QR code to link this device with ([qr]).
  Future<void> begin() async {
    if (_link == null) return;
    _error = null;
    _qr = null;
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

  /// The helper says this device is linked, and to whom: ready. The account is shown by its number, else its name.
  void _signedIn(Map s) {
    _account = (s['number'] as String?)?.ifEmpty((s['name'] as String?) ?? '') ?? s['name'] as String?;
    _aci = s['aci'] as String?;
    _qr = null;
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
    _contacts.clear();
    _account = null;
    _state = InboxState.signedOut;
    _save();
    notifyListeners();
  }

  /// When names and groups were last asked for.
  DateTime? _whoAt;

  /// Takes what the helper says of a group: that it is one, its title ("Signal group" until it has one) and picture.
  void _takeGroup(Map m) {
    final gid = m['id'] as String?;
    if (gid == null) return;
    _groups.add(gid);
    final title = (m['title'] as String?)?.trim();
    if (title != null && title.isNotEmpty) {
      _names[gid] = title;
    } else {
      _names.putIfAbsent(gid, () => 'Signal group');
    }
    if (m['avatar'] is String) _avatars[gid] = m['avatar'] as String;
  }

  /// Names and groups, from Signal's contact sync and profiles.
  Future<void> _who() async {
    _whoAt = DateTime.now();
    try {
      _takeContacts((await _ask('contacts')) as List? ?? const []);
      for (final g in (await _ask('groups')) as List? ?? const []) {
        _takeGroup(g as Map);
      }
      notifyListeners();
    } catch (_) {}
    await _nameChats();
  }

  /// Takes the account's contacts as the helper lists them: each one's name, and their number where Signal shares it.
  void _takeContacts(List list) {
    for (final c in list) {
      final m = c as Map;
      final aci = m['aci'] as String?;
      if (aci == null) continue;
      _takeName(m);
      final number = (m['number'] as String?)?.trim();
      _contacts[aci] = number == null || number.isEmpty ? null : number;
    }
  }

  /// Someone's name, as the helper found it (contact sync, or their Signal profile: sidecar/signal `who`). An empty
  /// name is no name: it never stands in for one (Matt, 2026-11-16: "signal messages are not being properly tied to a
  /// username or group name", when a chat showed its ACI).
  void _takeName(Map m) {
    final aci = m['aci'] as String?;
    if (aci == null) return;
    final name = (m['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) _names[aci] = name;
    if (m['avatar'] is String) _avatars[aci] = m['avatar'] as String;
    final number = (m['number'] as String?)?.trim();
    if (number != null && number.isNotEmpty) _numbers[aci] = number;
  }

  /// Numbers by ACI, where Signal gives one: what a chat is called when nothing names the person.
  final Map<String, String> _numbers = {};

  /// The chats of two asked about this run (`who`), so each is asked once.
  final Set<String> _askedWho = {};

  /// Asks the helper who each person written with is, where nothing here names them yet.
  Future<void> _nameChats() async {
    for (final chat in _chats.keys.toList()) {
      if (_groups.contains(chat) || (_names[chat]?.isNotEmpty ?? false) || !_askedWho.add(chat)) continue;
      try {
        final got = await _ask('who', {'aci': chat});
        if (got is Map) {
          _takeName(got);
          notifyListeners();
          _save();
        }
      } catch (_) {}
    }
  }

  // --- contacts (Matt, 2026-11-16: "Show telegram and signal contacts when linked") ---------------------------------

  /// This account's own ACI: Signal's contact sync names the person themself too.
  String? _aci;

  /// The people in Signal's contact sync, by ACI, with their numbers where Signal gives one.
  final Map<String, String?> _contacts = {};

  @override
  List<InboxContact> get contacts => [
        for (final e in _contacts.entries)
          if (e.key != _aci) InboxContact(network: id, id: e.key, name: _names[e.key] ?? e.value ?? 'Someone', number: e.value, avatar: _avatars[e.key]),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// A Signal group in full (sidecar/signal group_info), for its drawer.
  @override
  Future<GroupDetails?> groupDetails(String chatId) async {
    if (_state != InboxState.ready || !_groups.contains(chatId)) return null;
    final m = await _ask('group_info', {'to': chatId}) as Map?;
    if (m == null) return null;
    _takeGroup(m);
    return signalGroupDetails(m, names: _names);
  }

  /// Changes a Signal group on Signal (sidecar/signal group_update): everyone in it sees the change.
  @override
  Future<GroupDetails?> changeGroup(String chatId, GroupChange change) async {
    if (_state != InboxState.ready) throw StateError('Signal isn\'t connected');
    if (change.isEmpty) return groupDetails(chatId);
    final m = await _ask('group_update', {
      'to': chatId,
      'change': {
        if (change.title != null) 'title': change.title,
        if (change.description != null) 'description': change.description,
        if (change.photo != null) 'avatar': change.photo,
        if (change.timer != null) 'timer': change.timer,
        if (change.add.isNotEmpty) 'add': change.add,
        if (change.remove.isNotEmpty) 'remove': change.remove,
        if (change.admin.isNotEmpty) 'admin': change.admin,
        if (change.unadmin.isNotEmpty) 'unadmin': change.unadmin,
        if (change.announcementsOnly != null) 'announcements_only': change.announcementsOnly,
        if (change.editInfoAdminsOnly != null) 'edit_info': change.editInfoAdminsOnly! ? 'admins' : 'members',
        if (change.addPeopleAdminsOnly != null) 'add_members': change.addPeopleAdminsOnly! ? 'admins' : 'members',
        if (change.leave) 'leave': true,
      },
    }) as Map?;
    if (change.leave || m == null || m['left'] == true) {
      _chats.remove(chatId);
      _messages.remove(chatId);
      _save();
      notifyListeners();
      return null;
    }
    _takeGroup(m);
    notifyListeners();
    return signalGroupDetails(m, names: _names);
  }

  /// A chat with someone on Signal is named by their ACI: it is in the list from the first message sent.
  @override
  Future<String?> chatWith(InboxContact contact) async => _state == InboxState.ready ? contact.id : null;

  // --- what the helper says ---------------------------------------------------------------------------------------

  /// One line from the helper: an answer to a numbered request (`id` with `ok`), or an event (`ev`) of its own.
  void _heard(Map<String, Object?> m) {
    final id = m['id'];
    if (id is num && m.containsKey('ok')) {
      final w = _waiting.remove(id.toInt());
      if (w == null) return;
      m['ok'] == true ? w.complete(m['result']) : w.completeError(StateError('${m['error'] ?? 'Signal did not answer'}'));
      return;
    }
    switch (m['ev']) {
      case 'qr':
        _qr = m['url'] as String?;
        _state = InboxState.signingIn;
        notifyListeners();
      case 'linked':
        _signedIn(m);
      case 'link_failed':
        _qr = null;
        _state = InboxState.signedOut;
        _error = (m['error'] as String?) ?? 'Linking did not finish. Try again.';
        notifyListeners();
      case 'unlinked':
        _account = null;
        _state = InboxState.signedOut;
        _error = 'Signal removed this device. Link it again to carry on.';
        notifyListeners();
      case 'contacts':
        _takeContacts((m['list'] as List?) ?? const []);
        notifyListeners();
      case 'name':
        // Someone who wrote with nothing naming them, once the helper fetched their Signal profile.
        _takeName(m);
        _save();
        notifyListeners();
      case 'group':
        // A group first heard from: its name, as the groups op gives it (sidecar/signal announceGroup).
        _takeGroup(m);
        notifyListeners();
      case 'connected':
        // Back on Signal: names and groups asked for again, at most once a minute.
        final now = DateTime.now();
        if (_whoAt == null || now.difference(_whoAt!) > const Duration(minutes: 1)) unawaited(_who());
      case 'message':
        _message(m);
      case 'reaction':
        _reaction(m);
      case 'receipt':
        final kind = m['kind'] == 'read' ? 'read' : 'delivered';
        final times = {for (final t in (m['ts'] as List? ?? const [])) '$t'};
        // A receipt names who read, not the group: the message is found by its time in any chat (sidecar/signal).
        for (final list in _messages.values) {
          for (final x in list) {
            if (x['mine'] == true && times.contains('${x['ts']}') && x['state'] != 'read') x['state'] = kind;
          }
        }
        _save();
        notifyListeners();
      case 'deleted':
        final chat = '${m['chat']}';
        _messages[chat]?.removeWhere((x) => '${x['ts']}' == '${m['target_ts']}');
        _save();
        notifyListeners();
      case 'edited':
        // Its words changed by whoever wrote it: what it said before kept, the first first, so the original can be shown.
        final held = _messages['${m['chat']}']?.where((x) => '${x['ts']}' == '${m['target_ts']}').firstOrNull;
        if (held == null) return;
        final now = '${m['text'] ?? ''}';
        final was = '${held['text'] ?? ''}';
        if (now == was && jsonEncode(m['mentions'] ?? const []) == jsonEncode(held['mentions'] ?? const [])) return;
        // What it said before is kept as it was shown, its @mentions named: the earlier words' places are not kept.
        held['versions'] = [...((held['versions'] as List?) ?? const []).map((v) => '$v'), signalMentions(was, held['mentions'] as List?, nameOf: _mentionName).text];
        held['text'] = now;
        if (m['mentions'] is List) {
          held['mentions'] = m['mentions'];
        } else {
          held.remove('mentions');
        }
        held['edited'] = true;
        _nameMentioned(m['mentions'] as List?);
        _save();
        notifyListeners();
    }
  }

  /// A message the helper heard: kept in its chat, once. Signal gives a message no id; it is known by its time and
  /// its sender.
  void _message(Map<String, Object?> m) {
    final chat = '${m['chat']}';
    final group = m['group'] == true;
    if (group) _groups.add(chat);
    final from = '${m['from'] ?? ''}';
    final name = (m['name'] as String?)?.trim();
    if (!group && name != null && name.isNotEmpty && m['mine'] != true) _names[chat] = name;
    if (group && name != null && name.isNotEmpty) _names[from] = name;
    final list = _messages.putIfAbsent(chat, () => []);
    final ts = (m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    // Here already? The list is in order of time, so one of the same time is at its end: looked for from there back,
    // not through the whole chat (docs/performance-audit.md, finding 4).
    for (var i = list.length - 1; i >= 0 && (list[i]['ts'] as int) >= ts; i--) {
      if (list[i]['ts'] == ts && list[i]['from'] == from) return;
    }
    final inOrder = list.isEmpty || ts >= (list.last['ts'] as int);
    list.add({
      'ts': ts,
      'from': from,
      'mine': m['mine'] == true,
      'text': m['text'] ?? '',
      'media': m['media'] ?? const [],
      'state': m['mine'] == true ? 'sent' : 'received',
      if (m['quote'] is Map) 'quote': m['quote'],
      if (m['mentions'] is List && (m['mentions'] as List).isNotEmpty) 'mentions': m['mentions'],
    });
    _nameMentioned(m['mentions'] as List?);
    if (!inOrder) list.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    final fresh = !_chats.containsKey(chat);
    final c = _chats.putIfAbsent(chat, () => {'unread': 0});
    if (fresh && !group && (_names[chat]?.isEmpty ?? true)) unawaited(_nameChats());
    c['last'] = ts;
    if (m['mine'] != true) c['unread'] = ((c['unread'] as int?) ?? 0) + 1;
    _save();
    notifyListeners();
  }

  /// A reaction someone put on a message, or took off (sidecar/signal's reaction event): one reaction a person, as
  /// Signal has it, kept on the message as who gave which.
  void _reaction(Map<String, Object?> m) {
    final list = _messages['${m['chat']}'];
    final target = (m['target_ts'] as num?)?.toInt();
    if (list == null || target == null) return;
    final msg = list.where((x) => x['ts'] == target).firstOrNull;
    if (msg == null) return;
    final from = '${m['from'] ?? ''}';
    final reactions = Map<String, Object?>.from(msg['reactions'] as Map? ?? const {});
    if (m['remove'] == true) {
      if (reactions[from] == m['emoji']) reactions.remove(from);
    } else {
      reactions[from] = '${m['emoji']}';
    }
    msg['reactions'] = reactions;
    _save();
    notifyListeners();
  }

  /// Who wrote the message [ts] of [chatId], as Signal names them: their ACI, or this account's own for yours.
  String? _authorOf(String chatId, int ts) {
    final msg = (_messages[chatId] ?? const []).where((x) => x['ts'] == ts).firstOrNull;
    if (msg == null) return null;
    return msg['mine'] == true ? _aci : '${msg['from']}';
  }

  @override
  bool get canReact => true;

  @override
  Future<void> react(String chatId, String messageId, String emoji, {bool remove = false}) async {
    if (_state != InboxState.ready) throw StateError('Signal isn\'t connected');
    final ts = int.parse(messageId);
    final author = _authorOf(chatId, ts);
    if (author == null || author.isEmpty) throw StateError('That message isn\'t one Signal can react to');
    await _ask('react', {'to': chatId, 'author': author, 'ts': ts, 'emoji': emoji, 'remove': remove});
    _reaction({'chat': chatId, 'target_ts': ts, 'from': _aci ?? '', 'emoji': emoji, 'remove': remove});
  }

  @override
  bool get canReply => true;

  @override
  Future<void> reply(String chatId, String messageId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final ts = int.parse(messageId);
    final author = _authorOf(chatId, ts) ?? '';
    final quoted = (_messages[chatId] ?? const []).where((x) => x['ts'] == ts).firstOrNull;
    final quote = {'ts': ts, 'author': author, 'text': '${quoted?['text'] ?? ''}'};
    final local = <String, Object?>{'ts': DateTime.now().millisecondsSinceEpoch, 'from': '', 'mine': true, 'text': text, 'media': const [], 'state': 'sending', 'quote': quote};
    _messages.putIfAbsent(chatId, () => []).add(local);
    _chats.putIfAbsent(chatId, () => {'unread': 0})['last'] = local['ts'];
    notifyListeners();
    try {
      final r = (await _ask('send', {'to': chatId, 'text': text, 'quote': {'ts': ts, 'author': author}}) as Map?) ?? const {};
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

  /// What a chat is called: the group's title or the person's name; else their number; else plainly what it is. Never
  /// the ACI or the group's id.
  String _titleOf(String chat, bool group) {
    final name = _names[chat]?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (group) return 'Signal group';
    return _numbers[chat] ?? _contacts[chat] ?? 'Signal contact';
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

  /// A message in a line, for the list: its words (mentions written out), else what kind of file came.
  String _snippet(Map<String, Object?> m) {
    final text = signalMentions('${m['text'] ?? ''}', m['mentions'] as List?, nameOf: _mentionName).text.trim();
    if (text.isNotEmpty) return text;
    final media = (m['media'] as List?) ?? const [];
    if (media.isEmpty) return '';
    final mime = '${(media.first as Map)['mime'] ?? ''}';
    return mime.startsWith('image/') ? 'Photo' : mime.startsWith('video/') ? 'Video' : mime.startsWith('audio/') ? 'Voice message' : 'File';
  }

  @override
  List<InboxMessage> messagesOf(String chatId) => [
        for (final m in _messages[chatId] ?? const <Map<String, Object?>>[]) _shown(m),
      ];

  /// A kept message as the screens show it. Its id is its time in milliseconds, which is what Signal knows it by.
  InboxMessage _shown(Map<String, Object?> m) {
    final words = signalMentions('${m['text'] ?? ''}', m['mentions'] as List?, nameOf: _mentionName);
    return InboxMessage(
      id: '${m['ts']}',
      text: words.text,
      mentions: words.mentions,
      senderId: m['mine'] == true ? (_aci ?? '') : '${m['from'] ?? ''}',
      date: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
      mine: m['mine'] == true,
      sender: m['mine'] == true ? '' : (_names['${m['from']}'] ?? ''),
      state: switch (m['state']) { 'sending' => 'sending', 'failed' => 'failed', _ => 'sent' },
      media: [for (final a in (m['media'] as List? ?? const [])) _media(a as Map)],
      reactions: signalReactions(m['reactions'] as Map?, me: _aci),
      replyTo: (m['quote'] as Map?)?['ts']?.toString(),
      replyText: (m['quote'] as Map?)?['text'] as String?,
      replySender: _quoteName((m['quote'] as Map?)?['author'] as String?),
      edited: m['edited'] == true,
      versions: [for (final v in (m['versions'] as List? ?? const [])) '$v'],
    );
  }

  // --- @mentions and profiles (Matt, 2026-11-19: "when clicking on a @mention anywhere including signal and telegram
  // chats show this profile popup with actions available for the user in context of where it's placed") ------------

  /// A mentioned person's name as this device knows it: "You" for this account, else their name, else their number.
  String? _mentionName(String aci) {
    if (aci.isNotEmpty && aci == _aci) return _names[aci] ?? 'You';
    final name = _names[aci]?.trim();
    if (name != null && name.isNotEmpty) return name;
    return _numbers[aci] ?? _contacts[aci];
  }

  /// Asks the helper who each person [mentions] names is, where nothing here names them yet (once a run each).
  void _nameMentioned(List? mentions) {
    if (mentions == null || _state != InboxState.ready) return;
    for (final x in mentions) {
      final aci = x is Map ? '${x['aci'] ?? ''}' : '';
      if (aci.isEmpty || aci == _aci || _mentionName(aci) != null || !_askedWho.add(aci)) continue;
      unawaited(_ask('who', {'aci': aci}).then((got) {
        if (got is Map) {
          _takeName(got);
          _save();
          notifyListeners();
        }
      }, onError: (_) {}));
    }
  }

  @override
  String? faceOf(String user) => _avatars[user];

  @override
  bool get hasProfiles => true;

  /// Profiles asked for, each kept five minutes, so a card opened again asks the helper nothing.
  final Map<String, (DateTime, InboxProfile?)> _profiles = {};

  /// Someone's Signal profile, by their ACI (sidecar/signal `who` with profile: their name, number, picture and the
  /// "About" line they wrote). Signal has no way to look anyone up by a username from here, and keeps no presence.
  @override
  Future<InboxProfile?> profileOf({String user = '', String username = ''}) async {
    if (user.isEmpty || _state != InboxState.ready) return null;
    final kept = _profiles[user];
    if (kept != null && DateTime.now().difference(kept.$1) < const Duration(minutes: 5)) return kept.$2;
    Map? got;
    try {
      got = await _ask('who', {'aci': user, 'profile': true}) as Map?;
    } catch (_) {}
    if (got != null) {
      _takeName(got);
      _save();
    }
    final name = _names[user]?.trim() ?? '';
    final number = '${got?['number'] ?? ''}'.trim().isNotEmpty ? '${got!['number']}'.trim() : (_numbers[user] ?? _contacts[user] ?? '');
    final about = '${got?['about'] ?? ''}'.trim();
    final emoji = '${got?['aboutEmoji'] ?? ''}'.trim();
    final InboxProfile? found = got == null && name.isEmpty && number.isEmpty
        ? null
        : InboxProfile(network: id, id: user, name: name == number ? '' : name, bio: about, status: emoji, avatar: (got?['avatar'] as String?) ?? _avatars[user], number: number);
    _profiles[user] = (DateTime.now(), found);
    return found;
  }

  /// This account's own profile, as Signal keeps it for another of its devices: its name, picture and About line.
  @override
  Future<InboxProfile?> ownProfile() async {
    final me = _aci;
    if (me == null || me.isEmpty) return null;
    _profiles.remove(me);
    return profileOf(user: me);
  }

  /// Who a quoted message was by, to show over the quote: "You", their name, else their number.
  String? _quoteName(String? aci) {
    if (aci == null || aci.isEmpty) return null;
    if (aci == _aci) return 'You';
    return _names[aci] ?? _numbers[aci] ?? _contacts[aci];
  }

  /// An attachment as the screens show it. The number it goes by is its pointer's hash, kept to 30 bits so it is
  /// never negative; what the helper said of it is kept under that number, to bring it down by.
  InboxMedia _media(Map a) {
    final key = jsonEncode(a['pointer']).hashCode & 0x3fffffff;
    _pointers[key] = a.cast<String, Object?>();
    final mime = '${a['mime'] ?? ''}';
    return InboxMedia(
      // A Signal sticker (the helper marks it), or one of Uplink's sent from here: drawn on its own, with no bubble.
      kind: InboxMedia.kindOf(mime, sticker: a['sticker'] == true),
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
  Future<void> send(String chatId, String text) async {
    text = text.trim();
    if (text.isEmpty || _state != InboxState.ready) return;
    final local = <String, Object?>{'ts': DateTime.now().millisecondsSinceEpoch, 'from': '', 'mine': true, 'text': text, 'media': const [], 'state': 'sending'};
    _messages.putIfAbsent(chatId, () => []).add(local);
    _chats.putIfAbsent(chatId, () => {'unread': 0})['last'] = local['ts'];
    notifyListeners();
    try {
      final r = (await _ask('send', {'to': chatId, 'text': text}) as Map?) ?? const {};
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
      try {
        final name = path.split(PlatformInfo.pathSeparator).last;
        final r = (await _ask('send_media', {'to': chatId, 'path': path, 'mime': mime, 'name': name, 'text': i == paths.length - 1 ? caption : ''}) as Map?) ?? const {};
        final ts = (r['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        // What was sent is kept for its bubble: a copy in Signal's own folder (the picked file is a copy Android may clear),
        // and Signal's pointer to it, with its key, to fetch it again should the copy go (Matt, 2026-11-16: a picture
        // sent showed "Bad state: the attachment has no key", the pointer kept having been only the picked file's path).
        final kept = await _keepSent(path, ts, i, name);
        final pointer = r['pointer'] is Map ? r['pointer'] : {'local': kept};
        _messages.putIfAbsent(chatId, () => []).add({'ts': ts, 'from': '', 'mine': true, 'text': i == paths.length - 1 ? caption : '', 'media': [{'local': kept, 'mime': mime, 'name': name, 'pointer': pointer, if (sticker) 'sticker': true}], 'state': 'sent'});
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

  /// A copy of a file sent, in Signal's own folder, kept as long as its message is; the file itself where it can't be copied.
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
  /// the one download is waited for.
  final Map<int, Future<String?>> _fetching = {};

  /// A file's path once it is here (Matt, 2026-11-20: "some photos and videos are not coming through"). Each picture
  /// asked for its file every time it was drawn, so several downloads of one file ran at once into one path, and a file
  /// half written already counted as here: the picture stayed broken. Now one download a file, into a file of its own
  /// that takes the file's name only once whole; and one smaller than Signal says it is (left by that) is fetched again.
  @override
  Future<String?> fileOf(int fileId) async {
    final known = _files[fileId];
    if (known != null) return known;
    // A block, not an arrow: remove's value is this very future, which whenComplete would wait for, forever.
    return _fetching[fileId] ??= _fetch(fileId).whenComplete(() {
      _fetching.remove(fileId);
    });
  }

  /// Brings the attachment [fileId] down through the helper; its path on this device, or null where it can't be had.
  Future<String?> _fetch(int fileId) async {
    final a = _pointers[fileId];
    if (a == null) return null;
    // One of this account's own, kept on this device as it was sent.
    final local = a['local'] as String?;
    if (local != null && File(local).existsSync()) return _files[fileId] = local;
    // Sent before Signal's pointer was kept with it (0.7.45 and earlier): only the file it was sent from, now gone. Nothing
    // to fetch it with, and nothing to say: the bubble shows it can't be had.
    final pointer = a['pointer'];
    if (pointer is! Map || pointer['key'] == null) return null;
    final ext = '${a['name'] ?? ''}'.contains('.') ? '.${'${a['name']}'.split('.').last}' : '';
    final path = '$_dir/files/$fileId$ext';
    final size = (a['size'] as num?)?.toInt() ?? 0;
    final have = File(path);
    if (have.existsSync()) {
      if (size <= 0 || have.lengthSync() >= size) return _files[fileId] = path;
      try {
        have.deleteSync();
      } catch (_) {}
    }
    final coming = '$path.part';
    try {
      await Directory('$_dir/files').create(recursive: true);
      await _ask('download', {'pointer': a['pointer'], 'path': coming});
      await File(coming).rename(path);
      _files[fileId] = path;
      notifyListeners();
      return path;
    } catch (e) {
      _error = '$e';
      try {
        File(coming).deleteSync();
      } catch (_) {}
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
    final byAuthor = <String, List<int>>{};
    for (final m in unread) {
      byAuthor.putIfAbsent('${m['from']}', () => []).add(m['ts'] as int);
    }
    for (final e in byAuthor.entries) {
      try {
        await _ask('read', {'to': chatId, 'author': e.key, 'ts': e.value});
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
        await _ask('delete', {'to': chatId, 'ts': int.parse(messageId)});
      } catch (e) {
        _error = '$e';
      }
    }
    _messages[chatId]?.removeWhere((m) => '${m['ts']}' == messageId);
    _save();
    notifyListeners();
  }

  @override
  bool get canBlock => true;

  /// Blocked on Signal itself through the helper (sidecar/signal: the same word Signal Desktop sends the phone), then
  /// in Uplink's list. A one-to-one chat's id is the person's ACI.
  @override
  Future<void> block(String chatId, {required String name, bool on = true}) async {
    if (_groups.contains(chatId)) throw StateError('Only a person can be blocked');
    await _ask('block', {'aci': chatId, 'on': on});
    await super.block(chatId, name: name, on: on);
  }

  /// Signal's list as this device knows it (blocked here, or on the phone): Uplink's list is made the same.
  @override
  Future<void> refreshBlocked() async {
    if (state != InboxState.ready) return;
    final List list;
    try {
      list = (await _ask('blocked')) as List? ?? const [];
    } catch (_) {
      return;
    }
    final there = {for (final p in list) '${(p as Map)['aci']}': '${p['name'] ?? ''}'.trim().isEmpty ? '${p['number'] ?? ''}' : '${p['name']}'};
    for (final id in localList('blocked')) {
      if (!there.containsKey(id)) keepBlocked(id, on: false);
    }
    there.forEach((id, name) => keepBlocked(id, name: name));
    notifyListeners();
  }

  /// Gone from here: Signal keeps no conversations on its servers to delete.
  @override
  Future<void> deleteChat(String chatId) async {
    _chats.remove(chatId);
    _messages.remove(chatId);
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
        // Kept by builds that took an empty name for one: dropped, so the chat is asked about again.
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
    if (link == null) return Future.error(StateError('Signal isn\'t running'));
    final id = ++_asked;
    final done = Completer<Object?>();
    _waiting[id] = done;
    link.say({'id': id, 'op': op, ...args});
    // Longer than the helper gives each (sidecar/signal's do: a minute, three for files), so its own reason arrives.
    final wait = switch (op) { 'download' || 'send_media' || 'group_update' => 190, 'send' || 'react' || 'delete' || 'read' || 'groups' || 'group_info' => 75, _ => 30 };
    return done.future.timeout(Duration(seconds: wait), onTimeout: () {
      _waiting.remove(id);
      throw StateError('Signal took too long to answer');
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

/// The helper's log, as the Developer log keeps it (_ProcessLink).
abstract final class SignalLog {
  /// One line of the helper's log, shortened, where it is worth keeping: the helper's own lines about requests and
  /// sends, and anything signalmeow warns of; null for the rest.
  static String? keep(String line) => _ProcessLink.keep(line);
}

/// The helper as a process: a line of JSON each way on its stdin and stdout, and its log on stderr.
class _ProcessLink implements SignalLink {
  _ProcessLink(this.p) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      try {
        final m = jsonDecode(line);
        if (m is Map) _in.add(m.cast<String, Object?>());
      } catch (_) {}
    });
    // The helper's log (sidecar/signal: also signal.log beside its store): what matters goes to the Developer log, so
    // a send that stalls says where (Matt, 2026-11-16: "Sending signal messages get stuck on sending"). signalmeow logs
    // no message's words at this level, and the helper's own lines name an op, a chat and a time, never the text.
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(logLine);
  }

  /// One line of the helper's log, for the Developer log where it is worth keeping.
  @visibleForTesting
  static String? keep(String line) {
    Map? m;
    try {
      final d = jsonDecode(line);
      if (d is Map) m = d;
    } catch (_) {}
    if (m == null) return line.trim().isEmpty ? null : (line.length > 300 ? line.substring(0, 300) : line);
    final level = '${m['level'] ?? ''}';
    final message = '${m['message'] ?? ''}';
    const ours = {'asked', 'answered', 'send', 'sent', 'send to group', 'sent to group', 'group not described', 'send: not connected to Signal; trying anyway'};
    // A send's own steps (trace: true, sidecar/signal send): kept whatever their level, with their time, so the
    // Developer log shows which step a slow send waited on.
    final traced = m['trace'] == true;
    if (!traced && level != 'warn' && level != 'error' && level != 'fatal' && !ours.contains(message)) return null;
    const fields = ['op', 'req', 'took', 'sent_to', 'failed', 'error', 'action', 'component', 'authed_ws', 'unauthed_ws', 'response_status', 'retry_count'];
    final parts = [if (traced && m['time'] != null) '${m['time']}', level, message, for (final k in fields) if (m[k] != null) '$k=${m[k]}'];
    final out = parts.join(' ');
    return out.length > 300 ? out.substring(0, 300) : out;
  }

  /// Puts [line] of the helper's log in the Developer log, where [keep] keeps it.
  static void logLine(String line) {
    final kept = keep(line);
    if (kept != null) Sms.instance.devLog('signal', kept);
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

/// [other] in place of an empty string.
extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A Signal group as the helper's group_info gives it (sidecar/signal groupInfo), in the drawer's words. A member with
/// no name in their profile is named as the app names them elsewhere ([names], by ACI), else by their number.
GroupDetails signalGroupDetails(Map m, {Map<String, String> names = const {}}) {
  GroupPerson person(Object? raw) {
    final p = raw as Map;
    final aci = '${p['aci']}';
    final number = (p['number'] as String?)?.trim();
    final name = (p['name'] as String?)?.trim();
    return GroupPerson(
      id: aci,
      name: name != null && name.isNotEmpty ? name : (names[aci] ?? (number != null && number.isNotEmpty ? number : 'Someone on Signal')),
      number: number == null || number.isEmpty ? null : number,
      admin: p['admin'] == true,
      me: p['me'] == true,
    );
  }

  final admin = m['admin'] == true;
  final editInfoAdminsOnly = m['edit_info'] == 'admins';
  final addPeopleAdminsOnly = m['add_members'] == 'admins';
  return GroupDetails(
    title: '${m['title'] ?? ''}'.trim().isEmpty ? 'Signal group' : '${m['title']}'.trim(),
    description: '${m['description'] ?? ''}',
    photo: m['avatar'] as String?,
    timer: (m['timer'] as num?)?.toInt() ?? 0,
    people: [for (final p in (m['people'] as List? ?? const [])) person(p)],
    pending: [for (final p in (m['pending'] as List? ?? const [])) person(p)],
    requesting: [for (final p in (m['requesting'] as List? ?? const [])) person(p)],
    admin: admin,
    editInfoAdminsOnly: editInfoAdminsOnly,
    addPeopleAdminsOnly: addPeopleAdminsOnly,
    announcementsOnly: m['announcements_only'] == true,
    inviteLink: m['invite_link'] as String?,
    supports: GroupFeature.values.toSet(),
    canEditInfo: admin || !editInfoAdminsOnly,
    canAddPeople: admin || !addPeopleAdminsOnly,
    // Signal lets only admins remove people, make admins and change the rules.
    canRemovePeople: admin,
    canSetAdmins: admin,
    canChangeRules: admin,
  );
}

/// A message's reactions as Signal keeps them, one a person (who → emoji), as kinds: each emoji, how many, and whether
/// [me] (this account's ACI, or '' for one put on here before Signal said who) is among them. In the order first given.
List<InboxReaction> signalReactions(Map? byWho, {String? me}) {
  if (byWho == null || byWho.isEmpty) return const [];
  final order = <String>[];
  final count = <String, int>{};
  final mine = <String>{};
  byWho.forEach((who, emoji) {
    final e = '$emoji';
    if (!count.containsKey(e)) order.add(e);
    count[e] = (count[e] ?? 0) + 1;
    if (who == '' || who == me) mine.add(e);
  });
  return [for (final e in order) InboxReaction(emoji: e, count: count[e]!, mine: mine.contains(e))];
}

/// A Signal message's words as the app shows them, and its @mentions (Matt, 2026-11-19: "when clicking on a @mention
/// anywhere including signal and telegram chats show this profile popup"). Signal sends each mention as the character
/// U+FFFC with a range saying whose it is ([mentions]: `{"start", "length", "aci"}` from sidecar/signal, UTF-16 units of
/// [text]); each is put back as "@Name" ([nameOf], by ACI; "@Someone" where it knows none), and every later place moved
/// by what that adds. A range that is not over U+FFFC (a newer Signal, or words already named) is kept as it stands,
/// still a mention. Words from a helper that sends no mentions come back as they are.
({String text, List<InboxMention> mentions}) signalMentions(String text, List? mentions, {String? Function(String aci)? nameOf}) {
  if (mentions == null || mentions.isEmpty) return (text: text, mentions: const []);
  final ranges = <({int start, int length, String aci})>[];
  for (final x in mentions) {
    if (x is! Map) continue;
    final start = (x['start'] as num?)?.toInt();
    final length = (x['length'] as num?)?.toInt();
    final aci = '${x['aci'] ?? ''}';
    if (start == null || length == null || start < 0 || length <= 0 || start + length > text.length || aci.isEmpty) continue;
    ranges.add((start: start, length: length, aci: aci));
  }
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final out = StringBuffer();
  final found = <InboxMention>[];
  var at = 0;
  for (final r in ranges) {
    if (r.start < at) continue; // overlapping another: the first is kept
    out.write(text.substring(at, r.start));
    final over = text.substring(r.start, r.start + r.length);
    final placeholder = over.runes.every((c) => c == 0xFFFC);
    final name = nameOf?.call(r.aci)?.trim();
    final words = placeholder ? '@${name == null || name.isEmpty ? 'Someone' : name}' : over;
    found.add(InboxMention(start: out.length, length: words.length, user: r.aci));
    out.write(words);
    at = r.start + r.length;
  }
  out.write(text.substring(at));
  return (text: out.toString(), mentions: found);
}
