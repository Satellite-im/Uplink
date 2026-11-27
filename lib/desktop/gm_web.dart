import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

/// Google Messages on this computer, the way messages.google.com reaches it (Matt, 2026-11-15: "I'd like to see if
/// there is a way we can proxy messages from google messages to ghost so we can support RCS and other features";
/// then "Both, notifications first" and "Yes, mautrix sidecar").
///
/// Paired once by a QR code scanned in Google Messages on the phone, the computer has the person's Google Messages
/// conversations whole: RCS and texts, history, pictures and reactions. It is done by the sidecar (sidecar/gmessages,
/// a separate program under the AGPL, built on mautrix-gmessages' libgm), which this starts and talks to over its
/// standard input and output, one JSON object a line. Nothing of it is linked into Uplink.
///
/// Its conversations are folded into what the desktop shows (lib/desktop/remote.dart): each under a thread number
/// of its own below [threadBase], and a conversation the phone also has (the same people) is shown once, from here.
class GmWeb extends ChangeNotifier {
  GmWeb._();
  static final instance = GmWeb._();

  /// Where its conversations' thread numbers start, downwards: far from the phone's and from the bridge's.
  static const threadBase = -2000000000;

  /// The sidecar while it runs, and what has been asked of it and not answered yet, by the id each ask went under.
  Process? _process;
  final _waiting = <int, Completer<Object?>>{};
  var _next = 1;

  /// Where the sidecar keeps its session, and where the sidecar itself is; null where this copy has none.
  Directory? _dir;
  String? _binary;

  /// The start after a stop, and how many stops there have been since it last said it was ready.
  Timer? _restart;
  var _restarts = 0;

  /// The sidecar is on this computer (built with the app); without it there is nothing to pair.
  bool get available => _binary != null;

  /// Paired with the phone's Google Messages, and connected to it now, as the sidecar last said.
  bool paired = false;
  bool connected = false;

  /// Another web session has Google Messages for now (the phone's own connection, android GmWeb.kt, which takes it
  /// back whenever it is taken): this computer then shows what the phone has, through the phone.
  bool inactive = false;

  /// The phone's number as Google Messages says it, once connected.
  String phone = '';

  /// While pairing: the QR code to show, a fresh one every half minute; null otherwise.
  String? qr;

  /// While pairing by Google account: the emoji to tap in Google Messages on the phone.
  String? emoji;

  /// Why pairing or the session ended, where it did.
  String? problem;

  /// Google Messages' conversations as last read, by its own id.
  final conversations = <String, Map<String, dynamic>>{};


  /// The thread number each of its conversations is shown under, and back ([threadOf], [convOf]).
  final _thread = <String, int>{};
  final _conv = <int, String>{};

  /// A message's or a picture's number for the screens (which number them), and back.
  final _messageId = <int, String>{};
  final _part = <int, ({String media, String key, String mime})>{};

  /// Told the thread that changed (-1 for the list): the desktop's own Sms.changes is fed from it.
  final changed = StreamController<int>.broadcast();

  /// Finds the sidecar: `GHOST_GMSIDECAR`, then beside the app (Contents/Helpers on a Mac, the app's folder on
  /// Windows), then a build in the working folder (a developer's run).
  static String? find(Map<String, String> env) {
    final named = env['GHOST_GMSIDECAR'];
    if (named != null && named.isNotEmpty && File(named).existsSync()) return named;
    final exe = File(PlatformInfo.resolvedExecutable).parent.path;
    final candidates = PlatformInfo.isWindows
        ? ['$exe\\gmsidecar.exe', '${Directory.current.path}\\build\\gmsidecar\\windows\\gmsidecar.exe']
        : ['$exe/../Helpers/gmsidecar', '${Directory.current.path}/build/gmsidecar/mac/gmsidecar'];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Starts the sidecar with its session kept in [dir]; nothing where it is not on this computer.
  Future<void> start(Directory dir, {Map<String, String>? env}) async {
    _binary = find(env ?? PlatformInfo.environment);
    _dir = Directory('${dir.path}${PlatformInfo.pathSeparator}gmessages');
    if (_binary == null) return;
    await _spawn();
  }

  /// Runs the sidecar and listens to what it writes, a line at a time. Where it cannot be run, [problem] says so.
  Future<void> _spawn() async {
    final binary = _binary, dir = _dir;
    if (binary == null || dir == null) return;
    try {
      final p = await Process.start(binary, ['--dir', dir.path]);
      _process = p;
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_heard);
      p.stderr.transform(utf8.decoder).listen((_) {});
      unawaited(p.exitCode.then((code) => _ended(p, code)));
    } catch (e) {
      problem = 'The Google Messages helper could not start ($e)';
      notifyListeners();
    }
  }

  /// The sidecar stopped: whatever was waiting on it fails, and it is started again after a wait.
  void _ended(Process p, int code) {
    if (_process != p) return;
    _process = null;
    connected = false;
    for (final w in _waiting.values) {
      if (!w.isCompleted) w.completeError(StateError('The Google Messages helper stopped'));
    }
    _waiting.clear();
    notifyListeners();
    // Started again, more slowly each time it stops: a minute apart at most.
    _restart?.cancel();
    final wait = Duration(seconds: (1 << _restarts.clamp(0, 6)).clamp(1, 60));
    _restarts++;
    _restart = Timer(wait, _spawn);
  }

  /// Stops the sidecar for good: its input is closed, and it is killed where it has not gone in three seconds.
  Future<void> stop() async {
    _restart?.cancel();
    final p = _process;
    _process = null;
    if (p != null) {
      await p.stdin.close();
      await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
        p.kill();
        return -1;
      });
    }
  }

  /// Stands in for the sidecar in a test: asked what it would be asked.
  @visibleForTesting
  Future<Map<String, dynamic>> Function(String op, Map<String, Object?> args)? standIn;

  /// As if this copy carried the helper, for a picture of the Settings page.
  @visibleForTesting
  set carried(bool yes) => _binary = yes ? 'gmsidecar' : null;

  /// What a test's own folder is for pictures brought down.
  @visibleForTesting
  set folder(Directory dir) => _dir = dir;

  /// Asks the sidecar [op]; its answer, or the error it gave.
  Future<Map<String, dynamic>> ask(String op, [Map<String, Object?> args = const {}]) async {
    final stand = standIn;
    if (stand != null) return stand(op, args);
    final p = _process;
    if (p == null) throw StateError(available ? 'The Google Messages helper is not running' : 'This copy has no Google Messages helper');
    final id = _next++;
    final done = _waiting[id] = Completer<Object?>();
    p.stdin.writeln(jsonEncode({'id': id, 'op': op, ...args}));
    final answer = await done.future.timeout(const Duration(seconds: 70), onTimeout: () {
      _waiting.remove(id);
      throw TimeoutException('Google Messages did not answer');
    });
    return (answer as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// One line from the sidecar: with an `id`, the answer to an ask; with an `ev`, something that happened.
  void _heard(String line) {
    final Object? said;
    try {
      said = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (said is! Map) return;
    final id = said['id'];
    if (id is num) {
      final w = _waiting.remove(id.toInt());
      if (w == null) return;
      if (said['error'] != null) {
        w.completeError(GmWebError('${said['error']}'));
      } else {
        w.complete(said['ok']);
      }
      return;
    }
    switch (said['ev']) {
      case 'ready':
        _restarts = 0;
        unawaited(refresh());
      case 'connected':
        connected = true;
        problem = null;
        unawaited(refresh());
      case 'qr':
        qr = '${said['url']}';
        notifyListeners();
      case 'emoji':
        emoji = '${said['emoji']}';
        notifyListeners();
      case 'paired':
        qr = null;
        emoji = null;
        paired = true;
        problem = null;
        notifyListeners();
        // How it stands at once, and again until it says connected (libgm sends no ready signal of its own now).
        unawaited(refresh());
        unawaited(() async {
          for (var i = 0; i < 8 && paired && !connected; i++) {
            await Future<void>.delayed(const Duration(seconds: 15));
            await refresh();
          }
        }());
      case 'pair_failed':
        qr = null;
        emoji = null;
        problem = '${said['why']}';
        notifyListeners();
      case 'unpaired':
        paired = false;
        connected = false;
        conversations.clear();
        problem = '${said['why']}';
        notifyListeners();
        changed.add(-1);
      case 'inactive':
        inactive = true;
        notifyListeners();
        changed.add(-1);
      case 'active':
        inactive = false;
        notifyListeners();
        unawaited(refresh());
      case 'phone':
        problem = said['responding'] == true ? null : 'Your phone isn\'t answering Google Messages';
        notifyListeners();
      case 'conversation':
        final c = (said['data'] as Map).cast<String, dynamic>();
        conversations['${c['id']}'] = c;
        changed.add(-1);
      case 'message':
        final m = (said['data'] as Map).cast<String, dynamic>();
        final t = threadOf('${m['conv']}');
        changed.add(t);
        changed.add(-1);
    }
  }

  /// How it stands, and its conversations, read again.
  Future<void> refresh() async {
    try {
      final s = await ask('status');
      paired = s['paired'] == true;
      connected = s['connected'] == true;
      phone = '${s['phone'] ?? ''}';
      notifyListeners();
      if (!paired) return;
      final list = await ask('conversations', {'count': 200});
      conversations
        ..clear()
        ..addEntries([for (final c in (list['items'] as List? ?? const [])) MapEntry('${(c as Map)['id']}', c.cast<String, dynamic>())]);
      changed.add(-1);
      notifyListeners();
    } catch (_) {}
  }

  /// Starts pairing by QR code: the code comes as [qr], then "paired" or why not.
  Future<void> pair() async {
    problem = null;
    notifyListeners();
    await ask('pair');
  }

  /// Pairs by Google account, from a signed-in browser's cookies (lib/gm/google_signin.dart): an "emoji" to tap on
  /// the phone follows, then "paired". The words of why not, or null once asked.
  Future<String?> pairGoogle(Map<String, String> cookies) async {
    problem = null;
    emoji = null;
    notifyListeners();
    try {
      await ask('pair_google', {'cookies': cookies});
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> unpair() async {
    await ask('unpair');
    paired = false;
    conversations.clear();
    notifyListeners();
    changed.add(-1);
  }

  // --- folded into the desktop's conversations (remote.dart) -------------------------------------------------------

  static int _hash(String s) {
    // FNV-1a, 30 bits: the same number on every run, for the same id.
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h & 0x3fffffff;
  }

  /// The thread number a conversation of Google Messages' is shown under: [threadBase] less a number made from
  /// its id, so it is the same on every run.
  int threadOf(String conv) => _thread.putIfAbsent(conv, () {
        final t = threadBase - _hash(conv);
        _conv[t] = conv;
        return t;
      });

  /// Whether a thread number is one of these, and not the phone's.
  bool owns(int thread) => _conv.containsKey(thread) || thread <= threadBase;

  String? convOf(int thread) => _conv[thread];

  /// An address as two writings of it are compared: a number's last ten digits, anything else in lower case.
  static String _digits(String address) {
    final d = address.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length >= 7 ? (d.length > 10 ? d.substring(d.length - 10) : d) : address.trim().toLowerCase();
  }

  /// Who a conversation is with, not counting the person: the key a phone's conversation is matched to it by.
  static String peopleKey(Iterable<String> addresses) => (addresses.map(_digits).toSet().toList()..sort()).join(',');

  /// Who a conversation is with, not counting you: you are not always marked as you, so also the one the conversation
  /// sends from (Matt, 2026-11-15: a person's chat shown twice, once as a group of them and him).
  List<Map<String, dynamic>> _others(Map<String, dynamic> c) {
    final outgoing = '${c['outgoing'] ?? ''}';
    final seen = <String>{};
    return [
      for (final p in (c['people'] as List? ?? const []))
        if ((p as Map)['me'] != true && (outgoing.isEmpty || '${p['id']}' != outgoing) && seen.add(_digits('${p['number'] ?? ''}'))) p.cast<String, dynamic>(),
    ];
  }

  /// [peopleKey] for one of Google Messages' conversations.
  String keyOf(Map<String, dynamic> c) => peopleKey(_others(c).map((p) => '${p['number'] ?? ''}'));

  /// A conversation of Google Messages' as the desktop's list draws one (Sms Conversation.from).
  Map<String, dynamic> row(Map<String, dynamic> c) {
    final others = _others(c);
    return {
      'id': threadOf('${c['id']}'),
      'date': (c['time'] as num?)?.toInt() ?? 0,
      'count': 1,
      'people': [
        for (final p in others) {'address': '${p['number'] ?? ''}', 'name': (p['name'] as String?)?.isNotEmpty == true ? p['name'] : null},
      ],
      'snippet': '${c['snippet'] ?? ''}',
      'unread': c['unread'] == true,
      'archived': c['archived'] == true,
      'pinned': c['pinned'] == true,
      'muted': false,
      'name': c['group'] == true && '${c['name'] ?? ''}'.isNotEmpty ? c['name'] : null,
      'draft': null,
      'blocked': false,
      'group': null,
      'encrypted': false,
      'error': false,
      'heard': null,
      'gm': true,
      'rcs': c['rcs'] == true,
    };
  }

  /// The desktop's list with Google Messages' folded in: a conversation of the phone's with the same people as one
  /// of Google Messages' is left out, since Google Messages has all of it; the rest are kept; newest first.
  List<dynamic> fold(List<dynamic> phone, {bool archived = false}) {
    if (!paired || conversations.isEmpty) return phone;
    final mine = [for (final c in conversations.values) if (!archived || c['archived'] == true) c];
    final keys = {for (final c in mine) keyOf(c)};
    final kept = [
      for (final p in phone)
        if (!keys.contains(peopleKey([for (final x in ((p as Map)['people'] as List? ?? const [])) '${(x as Map)['address'] ?? ''}'])) || p['group'] != null) p,
    ];
    final all = [...kept, for (final c in mine) row(c)];
    all.sort((a, b) => (b['date'] as num).compareTo(a['date'] as num));
    return all;
  }

  /// A conversation's messages as the desktop's conversation draws them (Sms Message.from), newest first.
  Future<List<Map<String, dynamic>>> messages(int thread, {int limit = 50}) async {
    final conv = _conv[thread];
    if (conv == null) return const [];
    final r = await ask('messages', {'conv': conv, 'count': limit.clamp(1, 200)});
    final c = conversations[conv];
    final people = {for (final p in (c?['people'] as List? ?? const [])) '${(p as Map)['id']}': p};
    final out = <Map<String, dynamic>>[];
    for (final raw in (r['items'] as List? ?? const [])) {
      final m = (raw as Map).cast<String, dynamic>();
      // Google Messages' own lines about the conversation ("Texting with Jade (SMS/MMS)", its tombstones) and messages
      // with nothing in them are not texts (Matt, 2026-11-17, a thread full of them), as on the phone (GmWeb.kt).
      if ('${m['status'] ?? ''}'.contains('tombstone')) continue;
      // A picture message still coming down is told of with a stand-in ("Attachment", "SMS message from Jade") and
      // again once it is had (Matt, 2026-11-18): left out until then, as on the phone (GmBridge.downloading).
      if (downloading('${m['status'] ?? ''}')) continue;
      final words = notDownloaded('${m['status'] ?? ''}') ?? '${m['text'] ?? ''}';
      if (words.trim().isEmpty && (m['media'] as List? ?? const []).isEmpty) continue;
      final id = _hash('m:${m['id']}');
      _messageId[id] = '${m['id']}';
      final from = people['${m['from']}'];
      final status = '${m['status'] ?? ''}';
      final reactions = [for (final x in (m['reactions'] as List? ?? const [])) '${(x as Map)['emoji']}'].where((e) => e.isNotEmpty).toList();
      out.add({
        'id': id,
        'kind': 'gm',
        'address': '${from?['number'] ?? ''}',
        // Its reactions apart from its words, drawn once with the rest (lib/reactions.dart).
        'body': words,
        'reactions': reactions,
        'date': (m['time'] as num?)?.toInt() ?? 0,
        'outgoing': m['me'] == true,
        'state': _state(status, m['me'] == true),
        'read': true,
        'via': 'gm',
        'parts': [
          for (final p in (m['media'] as List? ?? const []))
            () {
              final media = (p as Map).cast<String, dynamic>();
              final pid = _hash('p:${media['id']}');
              _part[pid] = (media: '${media['id']}', key: '${media['key']}', mime: '${media['mime']}');
              return {'id': pid, 'type': '${media['mime']}', 'name': media['name']};
            }(),
        ],
      });
    }
    out.sort((a, b) => (b['date'] as int).compareTo(a['date'] as int));
    return out;
  }

  /// Whether Google Messages' status says a message is still being brought down (a picture message).
  static bool downloading(String status) {
    final s = status.toLowerCase();
    return s.startsWith('incoming_') && (s.contains('downloading') || s.contains('retrying_auto_download') || s.contains('retrying_manual_download') || s.contains('awaiting_auto_download'));
  }

  /// What to say of a picture message that will not come down by itself; null for any other status.
  static String? notDownloaded(String status) => switch (status.toLowerCase()) {
        'incoming_yet_to_manual_download' => 'Picture message not downloaded: open it in Google Messages to download it',
        'incoming_download_failed' || 'incoming_download_canceled' => 'Picture message could not be downloaded',
        'incoming_download_failed_too_large' => 'Picture message too large to download',
        'incoming_download_failed_sim_has_no_data' => 'Picture message not downloaded: no mobile data',
        'incoming_expired_or_not_available' => 'Picture message expired before it was downloaded',
        _ => null,
      };

  /// Google Messages' status for a message as one of the states the screens know ([Message.state]). The order
  /// matters: a failure is asked first, since its status may name sending too.
  static String _state(String status, bool mine) {
    if (!mine) return 'received';
    if (status.contains('fail') || status.contains('error') || status.contains('canceled')) return 'failed';
    if (status.contains('sending') || status.contains('yet_to_send') || status.contains('resending')) return 'sending';
    if (status.contains('delivered') || status.contains('display') || status.contains('read')) return 'delivered';
    return 'sent';
  }

  /// Whether a picture's number is one given out here, for a picture of Google Messages'.
  bool ownsPart(int id) => _part.containsKey(id);

  /// A picture's bytes, brought down once and kept beside the session.
  Future<Uint8List?> part(int id) async {
    final p = _part[id];
    final dir = _dir;
    if (p == null || dir == null) return null;
    final cache = Directory('${dir.path}${PlatformInfo.pathSeparator}media')..createSync(recursive: true);
    final file = File('${cache.path}${PlatformInfo.pathSeparator}${_hash(p.media)}');
    if (!file.existsSync()) {
      try {
        await ask('media', {'media': p.media, 'key': p.key, 'path': file.path});
      } catch (_) {
        return null;
      }
    }
    return file.readAsBytes();
  }

  /// The conversation [addresses] are with, among Google Messages'; null where there is none.
  String? convFor(List<String> addresses) {
    final key = peopleKey(addresses);
    for (final c in conversations.values) {
      if (keyOf(c) == key) return '${c['id']}';
    }
    return null;
  }

  /// Sends words into one of Google Messages' conversations; answers the thread it is shown under.
  Future<int> send(String conv, String body) async {
    await ask('send', {'conv': conv, 'text': body});
    final t = threadOf(conv);
    changed.add(t);
    return t;
  }

  /// Marks [thread] read in Google Messages, as far as its newest message.
  Future<void> markRead(int thread) async {
    final conv = _conv[thread];
    if (conv == null) return;
    try {
      final newest = await ask('messages', {'conv': conv, 'count': 1});
      final items = newest['items'] as List? ?? const [];
      if (items.isEmpty) return;
      await ask('read', {'conv': conv, 'msg': '${(items.first as Map)['id']}'});
      conversations[conv]?['unread'] = false;
      changed.add(-1);
    } catch (_) {}
  }
}

/// The sidecar answered an ask with an error: its words.
class GmWebError implements Exception {
  const GmWebError(this.message);
  final String message;

  @override
  String toString() => message;
}
