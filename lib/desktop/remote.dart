import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import '../files/file_platform.dart';
import '../plugins/shown_store.dart';
import '../sounds.dart';
import '../sms.dart';
import 'cache.dart';
import 'desk_voice.dart';
import 'gm_web.dart';
import 'link/crypto.dart';
import 'link/link.dart';
import 'link/session.dart';
import 'platform.dart';
import 'store.dart';
import 'updates.dart';

/// The phone's screens, on the Mac: every call they make of Android (lib/sms.dart) is answered here, by the phone
/// over the link where it is the phone's to answer, and by the Mac itself where it is the Mac's own (its theme, its
/// choices). What only the phone may do (delete, block, change encryption, send a picture) is refused in words.
///
/// **What was read is kept** (Matt, 2026-11-14: "cache messages on the desktop app so that we don't need to fetch
/// them all from the phone every time, just fetching updates in the background"): the conversations and each
/// conversation's messages, in memory and sealed on this computer's disk (cache.dart). The screens are answered from
/// what is kept, at once, the phone there or not. What is new is fetched behind them: the whole of a conversation
/// once each time the app runs (so what was deleted or changed far back is put right), and after that only its
/// newest few ([window]) each time the phone says it changed, joined to what is kept ([merged]). The screens are
/// told when what is kept has changed, and read it again. The phone is waited for only where nothing is kept, where
/// more is asked for than is kept (reading back), or after something done from here (a picture sent, a message
/// deleted), which must show what the phone made of it.
///
/// While the phone cannot be reached what is typed waits here, drawn as "Waiting for your phone", and goes when the
/// phone is back. Each text has a name the phone remembers, so one sent twice (its answer lost with the connection)
/// is sent once.
class LinkCalls implements SmsCalls, CapableCalls {
  LinkCalls(this.link, this.store);

  final PhoneLink link;
  final DeskStore store;

  Map<String, String> _prefs = {};

  /// What the phone does for a computer beyond the first few (android DeskCalls.CAPS): asked each time it is reached,
  /// since it may have been updated since. A phone from before there were any does none of them, and the screens
  /// offer none ([Sms.can]).
  @override
  Set<String> get caps => _caps;
  Set<String> _caps = const {};

  /// Asks the phone what it does. With no connection what is known stands; a phone that does not know the question
  /// does none. Where the answer has changed, the screens are told to draw again.
  Future<void> _askCaps() async {
    Set<String> next;
    try {
      next = {for (final c in ((await link.request('caps')) as List? ?? const [])) '$c'};
    } on LinkDown {
      return;
    } catch (_) {
      next = const {};
    }
    if (next.length != _caps.length || !next.containsAll(_caps)) {
      _caps = next;
      // Bubbles drawn before the phone said it can translate were answered "unavailable": asked again now.
      ShownStore.instance.askAll();
      Sms.instance.changes.add(-1);
    }
  }

  /// The app's own updates, once the app has handed them over ([attachUpdates]); none in a test that has none.
  MacUpdates? _updates;
  DateTime _looked = DateTime.fromMillisecondsSinceEpoch(0);

  /// Hands over the app's own updates: where they stand is told to the phone's screens (`Sms.instance.updates`), in
  /// the words the phone's own updater uses, each time it moves.
  void attachUpdates(MacUpdates updates) {
    _updates = updates;
    updates.addListener(() => Sms.instance.updates.add(UpdateState.from(updateState())));
  }

  /// Where the app's own update stands, as the phone's updater says it (android/.../Updater.kt): `ready` is the new
  /// version in place beside this one, and installing it is a restart.
  Map<String, Object?> updateState() {
    final u = _updates;
    final here = u?.installed;
    if (u == null || here == null) return {'phase': 'disabled', 'current': link.app};
    return {
      'phase': switch (u.phase) {
        MacUpdatePhase.idle => 'idle',
        MacUpdatePhase.checking => 'checking',
        MacUpdatePhase.downloading => 'downloading',
        MacUpdatePhase.ready => 'ready',
        MacUpdatePhase.restarting => 'installing',
        // There is a newer one this copy cannot put in place itself.
        MacUpdatePhase.manual => 'available',
        MacUpdatePhase.failed => 'failed',
      },
      'current': here.version,
      'available': u.release?.version,
      'progress': u.phase == MacUpdatePhase.downloading ? u.progress : null,
      'error': u.problem,
      'auto': true,
      'canInstall': u.phase != MacUpdatePhase.manual,
      'source': u.feed.host,
    };
  }

  /// The list of conversations and each conversation's messages as held in memory, in the phone's own maps: what
  /// the screens are answered from. Null, or missing, until read from the disk or the phone.
  List<dynamic>? _conversations;
  final Map<int, List<dynamic>> _messages = {};

  // --- what is kept, and how current it is ----------------------------------------------------------------------------

  /// What is kept on this computer's disk, sealed with a key made from the pairing's (cache.dart).
  late final DeskCache cache = DeskCache(Directory('${store.dir.path}/cache'), () {
    final phone = link.phone;
    return phone == null ? null : DeskCrypto.derive(phone.key, 'cache');
  });

  /// How many of a conversation's newest messages are asked for when the phone says it changed.
  static const window = 40;

  /// How many messages a conversation asks for as it opens (lib/ui/thread.dart): what is fetched ahead for the
  /// conversations at the top of the list.
  static const opening = 120;

  /// How many conversations at the top of the list have their messages fetched ahead, so they open at once.
  static const ahead = 8;

  /// How many times each conversation has been said to have changed, and the count it was last read at: it is
  /// current while the two agree. [_allChanged] counts the times everything may have ("the phone is back").
  final Map<int, int> _changed = {};
  final Map<int, int> _readAt = {};
  int _allChanged = 0;

  /// The conversations read whole since the app opened, how many messages each was asked for, and those whose next
  /// reading waits for the phone (something was done to them from here).
  final Set<int> _whole = {};
  final Map<int, int> _got = {};
  final Set<int> _hold = {};

  /// The conversations the phone has nothing older of than what is kept: asked for more, it gave fewer.
  final Set<int> _ended = {};
  final Map<int, Future<void>> _reading = {};

  /// The list is as the phone last gave it since it last said anything changed; the disk has been asked for it.
  bool _listCurrent = false;
  bool _listRead = false;

  /// Every conversation is among those kept (read whole from the phone, now or when the disk's were written), not
  /// just the first lot of them.
  bool _listWhole = false;
  Future<void>? _listReading;
  Timer? _listSaving;
  bool _fetchingAhead = false;

  /// One number for both counts (the second times a large prime, so neither hides the other): a conversation is
  /// current while it was last read at this number. [_stale] says one changed.
  int _count(int thread) => (_changed[thread] ?? 0) + _allChanged * 1000003;
  bool _current(int thread) => _readAt[thread] == _count(thread);
  void _stale(int thread) => _changed[thread] = (_changed[thread] ?? 0) + 1;

  /// Whether two answers of the phone's say the same, compared as the JSON they came as.
  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  /// A conversation's newest messages ([recent], as the phone just gave them, newest first) joined to the ones kept
  /// ([had]): the newest are the phone's, and what is kept older than them stays. One that is kept among the newest
  /// and is no longer the phone's was deleted, and goes. Null where none of [recent] is among [had] though [recent]
  /// is a full [window]: more is new than was asked for, and the conversation is to be read whole.
  static List<dynamic>? merged(List<dynamic> had, List<dynamic> recent, {int window = LinkCalls.window}) {
    if (recent.isEmpty) return const [];
    String key(dynamic m) => '${(m as Map)['kind']}:${m['id']}';
    int date(dynamic m) => (((m as Map)['date'] as num?) ?? 0).toInt();
    final keys = {for (final m in recent) key(m)};
    if (recent.length >= window && had.isNotEmpty && !had.any((m) => keys.contains(key(m)))) return null;
    final oldest = recent.map(date).reduce(math.min);
    return [...recent, for (final m in had) if (!keys.contains(key(m)) && date(m) <= oldest) m];
  }

  /// Reads a conversation's messages from the phone and keeps them: whole the first time since the app opened (or
  /// where [limit] asks for more than is kept), its newest [window] after that. One reading at a time for a
  /// conversation. The screens are told when what is kept changed, unless [quiet] (the caller tells them). The
  /// phone away, what is kept stands.
  Future<void> _read(int thread, {int? limit, bool quiet = false}) {
    final next = (_reading[thread] ?? Future<void>.value()).catchError((_) {}).then((_) => _readNow(thread, limit: limit, quiet: quiet));
    _reading[thread] = next;
    return next.whenComplete(() {
      if (identical(_reading[thread], next)) _reading.remove(thread);
    });
  }

  /// The reading itself, behind [_read]'s queue. A conversation read whole before, and long enough, is asked only
  /// for its newest [window], joined to what is kept ([merged]); otherwise for as many as are wanted.
  Future<void> _readNow(int thread, {int? limit, required bool quiet}) async {
    final count = _count(thread);
    final had = _messages[thread];
    final want = math.max(limit ?? 0, _got[thread] ?? opening);
    // Read already since it last changed, with as many as are wanted.
    if (had != null && _readAt[thread] == count && want <= (_got[thread] ?? 0)) return;
    List<dynamic> next;
    try {
      List<dynamic>? joined;
      if (had != null && _whole.contains(thread) && want <= (_got[thread] ?? 0) && had.length > window) {
        joined = merged(had, (await link.request('messages', {'thread': thread, 'limit': window})) as List);
      }
      next = joined ?? (await link.request('messages', {'thread': thread, 'limit': want})) as List;
      if (joined == null) {
        _whole.add(thread);
        // Fewer than were asked for: that is all of it.
        next.length < want ? _ended.add(thread) : _ended.remove(thread);
      }
    } on LinkDown {
      return;
    } on PhoneError {
      return;
    }
    if (next.length > want) next = next.sublist(0, want);
    _got[thread] = want;
    _readAt[thread] = count;
    _hold.remove(thread);
    if (had == null || !_same(had, next)) {
      _messages[thread] = next;
      unawaited(cache.saveMessages(thread, next, want, ended: _ended.contains(thread)));
      if (!quiet) Sms.instance.changes.add(thread);
    }
  }

  /// What is kept of a conversation on the disk, brought into memory where it is not there yet.
  Future<void> _recall(int thread) async {
    if (_messages.containsKey(thread)) return;
    final kept = await cache.messages(thread);
    if (kept != null && !_messages.containsKey(thread)) {
      _messages[thread] = kept.items;
      _got[thread] = kept.limit;
      if (kept.ended) _ended.add(thread);
    }
  }

  /// The list as the disk has it, once, where the phone has not been asked yet.
  Future<void> _recallList() async {
    if (_listRead) return;
    _listRead = true;
    final kept = await cache.conversations();
    if (kept != null && _conversations == null) {
      _conversations = kept;
      _listWhole = true;
    }
  }

  /// Writes the list to the disk a moment from now, once for a run of changes.
  void _saveListSoon() {
    // Only a whole list is kept on the disk: the first lot of one would be taken for all of it next time.
    if (!_listWhole) return;
    _listSaving?.cancel();
    _listSaving = Timer(const Duration(milliseconds: 300), () {
      final list = _conversations;
      if (list != null) unawaited(cache.saveConversations(list));
    });
  }

  /// Reads every conversation from the phone, a lot at a time, in place of the list kept. One that is gone from the
  /// phone is gone from here, with its messages. Throws [LinkDown] where the phone is away.
  Future<void> _readList({bool quiet = false}) => _listReading ??= _readListNow(quiet: quiet).whenComplete(() => _listReading = null);

  Future<void> _readListNow({required bool quiet}) async {
    // Noted before asking: a change the phone says of while the lots are read leaves the list not current.
    final count = _allChanged;
    final all = <dynamic>[];
    int? at = 0;
    while (at != null) {
      final page = (await link.request('conversationsPage', {'limit': lot, 'offset': at, 'pinned': at == 0})) as Map;
      all.addAll(page['items'] as List);
      at = (page['next'] as num?)?.toInt();
    }
    // Once each (a pinned one comes with the first lot and again in its place), newest first: of two copies, the one
    // with the newer message. A phone's later lot used to carry a conversation as Android has it (its last SMS,
    // however old) over the first lot's copy with the newer RCS message (Matt, 2026-11-26: "they don't always show the
    // last message"); a phone that has not been updated still does.
    final byId = <Object?, dynamic>{};
    for (final c in all) {
      final had = byId[(c as Map)['id']];
      if (had == null || (((had as Map)['date'] as num?) ?? 0) <= ((c['date'] as num?) ?? 0)) byId[c['id']] = c;
    }
    final next = byId.values.toList()..sort((x, y) => (((y as Map)['date'] as num?) ?? 0).compareTo(((x as Map)['date'] as num?) ?? 0));
    final had = _conversations;
    for (final c in had ?? const []) {
      final id = ((c as Map)['id'] as num?)?.toInt();
      if (id != null && !byId.containsKey(c['id'])) _dropThread(id);
    }
    _conversations = next;
    _listWhole = true;
    _listCurrent = count == _allChanged;
    if (had == null || !_same(had, next)) {
      _saveListSoon();
      if (!quiet) Sms.instance.changes.add(-1);
    }
    unawaited(_fetchAhead());
  }

  /// The newest each conversation had when its message sound last played here, and when this ran up.
  final Map<int, int> _soundedUpTo = {};
  final int _since = DateTime.now().millisecondsSinceEpoch;

  /// The message sound (lib/sounds.dart), for a conversation the phone says changed and now has an unread message
  /// newer than any heard: a text came in. Not for one muted, nor for what was there before the app opened.
  void _heard(int thread, Map c) {
    final date = (c['date'] as num?)?.toInt() ?? 0;
    if (c['unread'] != true || c['muted'] == true || c['archived'] == true) return;
    if (date <= (_soundedUpTo[thread] ?? _since)) return;
    _soundedUpTo[thread] = date;
    Sounds.instance.play(UiSound.messageIn);
  }

  /// Reads one conversation's line in the list from the phone again, and plays the message sound where a text came
  /// in; a conversation the phone no longer has is dropped from the list here.
  Future<void> _readOne(int thread) async {
    try {
      final c = await link.request('conversation', {'thread': thread});
      if (c is Map) {
        _heard(thread, c);
        _remember([c]);
      } else if (_conversations != null) {
        _conversations = [for (final x in _conversations!) if (((x as Map)['id'] as num?)?.toInt() != thread) x];
        _dropThread(thread);
      }
      _saveListSoon();
    } on LinkDown {
      return;
    } on PhoneError {
      return;
    }
  }

  /// Forgets a conversation's messages, in memory and on the disk. Its line in the list is the caller's to take out.
  void _dropThread(int thread) {
    _messages.remove(thread);
    _got.remove(thread);
    _whole.remove(thread);
    _ended.remove(thread);
    unawaited(cache.forget(thread));
  }

  /// The conversations at the top of the list have their messages read behind the screens, one after another, so
  /// each opens at once: the ones kept get what is new, the ones never opened get what a conversation opens with.
  Future<void> _fetchAhead() async {
    if (_fetchingAhead) return;
    _fetchingAhead = true;
    try {
      for (final c in (_conversations ?? const []).take(ahead).toList()) {
        if (!link.online) return;
        final thread = ((c as Map)['id'] as num?)?.toInt();
        if (thread == null) continue;
        await _recall(thread);
        if (!_current(thread)) await _read(thread);
      }
    } finally {
      _fetchingAhead = false;
    }
  }

  /// The phone says a conversation changed (or, with -1, that something did): what is new is read behind the
  /// screens, and then they are told, and read what is kept.
  Future<void> _changedOnPhone(int thread) async {
    if (thread < 0) {
      _allChanged++;
      _listCurrent = false;
      try {
        await _readList(quiet: true);
      } on LinkDown {
        // Away again already: what is kept stands.
      } catch (_) {}
    } else {
      _stale(thread);
      await _recall(thread);
      await Future.wait([
        _readOne(thread),
        if (_messages.containsKey(thread)) _read(thread, quiet: true),
      ]);
    }
    Sms.instance.changes.add(thread);
  }

  /// Everything kept on this computer is thrown away, in memory and on the disk: the person asked. The screens read
  /// from the phone again.
  Future<void> clearKept() async {
    _forgetKept();
    await cache.clear();
    Sms.instance.changes.add(-1);
  }

  /// Empties what is held in memory. The disk counts as read, so nothing old is brought back from it.
  void _forgetKept() {
    _conversations = null;
    _messages.clear();
    _changed.clear();
    _readAt.clear();
    _whole.clear();
    _got.clear();
    _hold.clear();
    _ended.clear();
    _listCurrent = false;
    _listWhole = false;
    _listRead = true;
    _listSaving?.cancel();
  }

  /// What is half written in each conversation, held here for as long as the app runs.
  final Map<int, String> _drafts = {};

  /// The texts typed while the phone was away, oldest first. Each has an id below zero ([_localId] counts down),
  /// which no message of the phone's has. [_flushing]: they are being sent now.
  final List<_Waiting> _waiting = [];
  int _localId = -1;
  bool _flushing = false;
  StreamSubscription<dynamic>? _events;
  StreamSubscription<void>? _connected;

  /// How many texts are waiting for the phone.
  int get waiting => _waiting.where((w) => !w.failed).length;

  /// Reads this computer's choices and starts listening to the link: the phone's "changed", and each time the
  /// phone is reached again. Called once, before anything is drawn.
  Future<void> init() async {
    _prefs = await store.prefs();
    // On a computer Enter sends, as every desktop messenger has it; the choice can still be changed.
    _prefs.putIfAbsent('enter_sends', () => 'on');
    _events = link.events.stream.listen((e) {
      if (e.name == 'changed') unawaited(_changedOnPhone((e.args['thread'] as num?)?.toInt() ?? -1));
    });
    if (link.online) unawaited(_askCaps());
    // The phone coming and going (lib/sounds.dart): disconnected as it goes, connected as it comes back. Not as the
    // app first finds it.
    _wasOnline = _everOnline = link.online;
    link.addListener(_linkChanged);
    _connected = link.connected.stream.listen((_) async {
      await _askCaps();
      await _flush();
      // Whatever changed while the phone was away is read again: nothing kept is taken for current. The screens
      // read what is kept, and what is new comes in behind them.
      _allChanged++;
      _listCurrent = false;
      Sms.instance.changes.add(-1);
    });
  }

  bool _wasOnline = false, _everOnline = false;

  /// Plays the disconnected sound as the phone goes, and the connected sound as it comes back.
  void _linkChanged() {
    final now = link.online;
    if (now == _wasOnline) return;
    _wasOnline = now;
    if (now) {
      if (_everOnline) Sounds.instance.play(UiSound.connected);
      _everOnline = true;
    } else {
      Sounds.instance.play(UiSound.disconnected);
    }
  }

  void dispose() {
    link.removeListener(_linkChanged);
    _events?.cancel();
    _connected?.cancel();
    _listSaving?.cancel();
  }

  /// The pairing is gone: nothing of the old phone's is kept.
  void forget() {
    _forgetKept();
    unawaited(cache.clear());
    _drafts.clear();
    _waiting.clear();
    _videos.clear();
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => (await _call(method, (arguments as Map?)?.cast<String, dynamic>() ?? const {})) as T?;

  /// Google Messages on this computer (lib/desktop/gm_web.dart), where it is paired: its conversations are folded
  /// into the list, and what is asked of one of them is answered by it, not the phone.
  Future<dynamic> _call(String method, Map<String, dynamic> a) async {
    final gm = GmWeb.instance;
    // Not paired, or another session (the phone's) has Google Messages for now: the phone's list has it all.
    if (!gm.paired || gm.inactive) return _phoneCall(method, a);
    final thread = (a['thread'] as num?)?.toInt();
    final ours = thread != null && gm.owns(thread);
    switch (method) {
      case 'conversations':
        return gm.fold(await _orNone(() async => (await _phoneCall(method, a)) as List));
      case 'conversationsPage':
        if (((a['offset'] as num?)?.toInt() ?? 0) > 0) return {'items': const [], 'next': null};
        final page = await _orNone(() async => (((await _phoneCall(method, {...a, 'limit': 0})) as Map)['items'] as List));
        return {'items': gm.fold(page, archived: a['archived'] == true), 'next': null};
      case 'conversation' when ours:
        final c = gm.conversations[gm.convOf(thread)];
        return c == null ? null : gm.row(c);
      case 'messages' when ours:
        return gm.messages(thread, limit: (a['limit'] as num?)?.toInt() ?? 50);
      case 'people' when ours:
        final c = gm.conversations[gm.convOf(thread)];
        return c == null ? const [] : gm.row(c)['people'];
      case 'markRead' when ours:
        await gm.markRead(thread);
        return null;
      case 'part' when gm.ownsPart((a['id'] as num).toInt()):
        return gm.part((a['id'] as num).toInt());
      case 'send':
        final addresses = [for (final x in (a['addresses'] as List? ?? const [])) '$x'];
        final conv = gm.convFor(addresses);
        if (conv != null) {
          if ((a['attachments'] as List?)?.isNotEmpty ?? false) {
            throw const PhoneError('Pictures to Google Messages conversations can\'t be sent from the computer yet. Send them from your phone.');
          }
          return gm.send(conv, '${a['body'] ?? ''}');
        }
      case 'threadFlag' || 'threadName' || 'archive' || 'draft' || 'setDraft' || 'deleteThread' when ours:
        return null;
    }
    return _phoneCall(method, a);
  }

  /// The phone's answer, or nothing where it is away: Google Messages' conversations are shown either way.
  Future<List<dynamic>> _orNone(Future<List<dynamic>> Function() ask) async {
    try {
      return await ask();
    } on LinkDown {
      return const [];
    }
  }

  Future<dynamic> _phoneCall(String method, Map<String, dynamic> a) async {
    switch (method) {
      // --- the phone's -------------------------------------------------------------------------------------------------
      case 'conversations':
        // Every conversation. Kept whole: answered at once, and read again behind the screens where it may have
        // changed. Not kept yet: read from the phone a lot at a time (a phone with thousands has more than a frame
        // carries) and waited for; away with only some of them read, those.
        await _recallList();
        if (!_listWhole) {
          try {
            await _readList(quiet: true);
          } on LinkDown {
            if (_conversations == null) rethrow;
          }
        } else if (!_listCurrent && link.online) {
          unawaited(_readList().catchError((_) {}));
        }
        return List<dynamic>.of(_conversations ?? const []);
      case 'conversationsPage':
        await _recallList();
        if (!_listWhole) {
          // The first time, with nothing whole kept: the phone is asked for the lot the list asks for, so the list
          // has something to show at once, and all of it is read behind that for the next time.
          try {
            final page = (await link.request('conversationsPage', a)) as Map;
            _remember(page['items'] as List);
            unawaited(_readList(quiet: true).catchError((_) {}));
            return page;
          } on LinkDown {
            if (_conversations == null) rethrow;
          }
        } else if (!_listCurrent && link.online) {
          // Kept whole: read again behind the screens where it may have changed; they are told if it differs.
          unawaited(_readList().catchError((_) {}));
        }
        // What is kept, all of it as one lot: there is nothing to wait for.
        if (((a['offset'] as num?)?.toInt() ?? 0) > 0) return {'items': const [], 'next': null};
        final archived = a['archived'] == true;
        return {'items': [for (final c in _conversations ?? const []) if (!archived || (c as Map)['archived'] == true) c], 'next': null};
      case 'conversation':
        final thread = (a['thread'] as num).toInt();
        await _recallList();
        // Its line in the list is kept current by what the phone says changed (_readOne).
        final kept = _cached(thread);
        if (kept != null) return kept;
        try {
          final c = await link.request('conversation', a);
          if (c is Map) {
            _remember([c]);
            _saveListSoon();
          }
          return c;
        } on LinkDown {
          return null;
        }
      case 'archivedCount':
        await _recallList();
        if (_conversations != null) return _conversations!.where((c) => (c as Map)['archived'] == true).length;
        try {
          return await link.request('archivedCount');
        } on LinkDown {
          return 0;
        }
      case 'messages':
        final thread = (a['thread'] as num).toInt();
        final limit = (a['limit'] as num?)?.toInt() ?? 300;
        await _recall(thread);
        final had = _messages[thread];
        if (had == null || (limit > (_got[thread] ?? 0) && !_ended.contains(thread)) || _hold.contains(thread)) {
          // Nothing kept, more asked for than is kept (reading back), or something was done to it from here: the
          // phone is waited for. Away, what is kept stands.
          await _read(thread, limit: limit, quiet: true);
        } else if (!_current(thread) && link.online) {
          // Kept: shown at once. What is new is read behind it, and the screens are told if it differs.
          unawaited(_read(thread));
        }
        // Newest first: what waits for the phone is the newest of all.
        return [for (final w in _waiting.reversed) if (w.thread == thread) w.message, ...?_messages[thread]];
      case 'people':
        await _recallList();
        final people = _cached((a['thread'] as num).toInt())?['people'];
        if (people != null) return people;
        try {
          return await link.request('people', a);
        } on LinkDown {
          return const [];
        }
      case 'send':
        return ((a['attachments'] as List?)?.isNotEmpty ?? false) ? _sendPictures(a) : _send(a);

      // --- what the message field has (Matt, 2026-11-14: "Add an emoji picker, file upload, voice memo and sticker
      // selector to the desktop app as well"): the Mac chooses, records and holds; the phone sends. What is sent is
      // handed over in pieces first ([_handOver]).
      case 'pickImages':
        return MacPlatform.pickPictures();
      // A Telegram chat's + and a file it was sent (lib/ui/inbox_ui.dart): chosen and opened on the computer itself,
      // which runs its own Telegram.
      // Any file, not only pictures: the Mac's Open panel for every kind (lib/files/file_platform.dart), which a Files
      // space chooses with too.
      case 'pickFiles':
        return FilePlatform.pickPaths(most: 10);
      case 'openFile':
        final path = '${a['path']}';
        await Process.run(PlatformInfo.isWindows ? 'explorer' : 'open', [path]);
        return null;
      case 'emoji':
        await MacPlatform.emoji();
        return null;
      case 'sendSticker':
        final sticker = a['picture'] as Uint8List;
        final sent = (await link.request('sendSticker', {'key': _name(), 'addresses': a['addresses'], 'name': a['name'], 'upload': await _handOver(sticker)})) as Map;
        return _went(sent);
      case 'voiceStart':
        // For a text, how long one may run is the phone's carrier's to say, and the recorder stops itself there; for a
        // file (a network's chat, a space, a friend: GMFB-32) no carrier holds it and the phone isn't asked.
        final limit = a['file'] == true ? null : (await link.request('voiceLimit')) as Map;
        return DeskVoice.start(carrier: limit);
      case 'voiceLevel':
        return DeskVoice.level();
      case 'voiceCancel':
        await DeskVoice.cancel();
        return null;
      // Kept as a file here, for a network's chat or a space to send (GMFB-32), as the phone's own voiceFinish does.
      case 'voiceFinish':
        return DeskVoice.finish();
      case 'voiceSend':
        final sound = await DeskVoice.stopBytes();
        final sent = (await link.request('sendVoice', {'key': _name(), 'addresses': a['addresses'], 'name': 'voice.m4a', 'upload': await _handOver(sound)})) as Map;
        return {'thread': _went(sent), 'millis': 0};
      case 'voicePlay':
        final part = (a['part'] as num).toInt();
        final sound = await _video(part);
        if (sound == null) throw const LinkDown('Your phone isn\'t reachable, and the voice message is on it. Try again when it is back.');
        final why = await MacPlatform.voicePlay(part, sound);
        if (why != null) throw PhoneError('Couldn\'t play it: $why.');
        return null;
      case 'voicePause':
        await MacPlatform.voicePause();
        return null;
      case 'voiceStop':
        await MacPlatform.voiceHalt();
        return null;
      case 'voiceLength':
        final sound = await _video((a['part'] as num).toInt());
        return sound == null ? 0 : await MacPlatform.voiceLength(sound);

      // --- what the phone's screens do to what is kept, done through the phone (android DeskCalls) ----------------
      case 'deleteMessage' || 'editMessage' || 'setBlocked' || 'e2eOff' || 'e2eVerify' || 'e2ePlainSeen':
        await link.request(method, a);
        _reread();
        return null;
      case 'deleteThread':
        await link.request('deleteThreads', {'threads': [a['thread']]});
        _reread();
        return null;
      case 'deleteThreads' || 'resendMms' || 'e2eOffer':
        final done = await link.request(method, a);
        _reread();
        return done;
      case 'e2eList' || 'blockedNumbers':
        if (!_caps.contains(method)) return const [];
        try {
          return await link.request(method, a);
        } on LinkDown {
          return const [];
        }
      case 'mmsStatus':
        if (!_caps.contains(method)) return const <String, dynamic>{};
        try {
          return await link.request(method, a);
        } on LinkDown {
          return const <String, dynamic>{};
        }
      case 'markRead':
        final thread = (a['thread'] as num).toInt();
        try {
          await link.request('markRead', {'thread': thread});
        } on LinkDown {
          return null;
        }
        final c = _cached(thread);
        if (c != null && c['unread'] == true) {
          c['unread'] = false;
          // On the disk too: the phone says nothing back of what a computer did, so nothing else writes it, and the
          // app opened again with the conversation unread.
          _saveListSoon();
          Sms.instance.changes.add(-1);
        }
        return null;
      case 'threadFor':
      case 'searchContacts':
        return link.request(method, a);
      case 'contact':
        try {
          return await link.request('contact', a);
        } on LinkDown {
          return {'address': a['address']};
        }
      case 'photo':
        // A picture chosen on this Mac for a message not yet sent (its path, where the phone's is an address of
        // Android's): drawn from where it is.
        if ('${a['uri']}'.startsWith('/')) {
          try {
            final file = File('${a['uri']}');
            return await file.length() > mostBytes ? null : await file.readAsBytes();
          } catch (_) {
            return null;
          }
        }
        try {
          final data = await link.request('photo', a);
          return data is String ? base64.decode(data) : null;
        } catch (_) {
          return null;
        }
      case 'part':
        return _part((a['id'] as num).toInt());
      // A video (lib/ui/video.dart): its bytes are the phone's, brought over as a picture's are; the Mac makes the
      // picture of where it starts (macos/Runner/DeskVideo.swift), and the app's own player plays it from a file
      // (lib/ui/video_screen.dart; Matt, 2026-11-18: "add support for playing mkv video files and mp4's within the app
      // in a player themed by glacier UI").
      case 'videoPreview':
        final id = (a['part'] as num).toInt();
        final bytes = await _video(id);
        if (bytes == null) return null;
        final preview = await MacPlatform.videoPreview(id, bytes, '${a['ending'] ?? 'mp4'}');
        // How large its file is: the Mac holds it, having fetched it.
        return preview is Map ? {...preview, 'bytes': bytes.length} : preview;
      case 'videoFile':
        final id = (a['part'] as num).toInt();
        final bytes = await _video(id);
        if (bytes == null) return null;
        return videoCopy(id, bytes, '${a['ending'] ?? 'mp4'}');
      case 'threadFlag':
      case 'threadName':
      case 'archive':
        await link.request(method, a);
        return null;
      case 'draft':
        final thread = (a['thread'] as num).toInt();
        try {
          return await link.request('draft', a);
        } on LinkDown {
          return _drafts[thread];
        }
      case 'setDraft':
        final thread = (a['thread'] as num).toInt();
        _drafts[thread] = '${a['text'] ?? ''}';
        try {
          await link.request('setDraft', a);
        } catch (_) {}
        return null;
      case 'e2e':
        try {
          return await link.request('e2e', a);
        } catch (_) {
          return {'address': a['address'], 'state': 'none'};
        }

      // --- the Mac's own -----------------------------------------------------------------------------------------------
      case 'openLink':
        // A link pressed in a message opens in this computer's own browser (Matt, 2026-11-14: "I can't click to
        // open links in the desktop app"): only a web address, handed over alone (MacPlatform.openLink).
        return MacPlatform.openLink('${a['url'] ?? ''}');
      case 'prefs':
        return Map<String, String>.of(_prefs);
      case 'setPref':
        _prefs['${a['key']}'] = '${a['value']}';
        await store.savePrefs(_prefs);
        return null;
      case 'status':
        return {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      // The app's own updates (updates.dart), told to the phone's screens in the phone's words, so the banner and
      // the Settings a phone has are the ones a computer has (Matt, 2026-11-14: "bring the same update banner we
      // have on mobile to the desktop app").
      case 'update':
        return updateState();
      case 'updateCheck':
        final u = _updates;
        if (u == null) return null;
        if (a['install'] == true && u.phase == MacUpdatePhase.ready) {
          await u.restart();
        } else {
          _looked = DateTime.now();
          unawaited(u.check());
        }
        return null;
      case 'updateInstall':
        await _updates?.restart();
        return null;
      case 'updatePage' || 'updateBackground':
        // As a page opens: a look, no oftener than every five minutes (the phone's Updater.pageCheck).
        final u = _updates;
        if (u != null && DateTime.now().difference(_looked) >= const Duration(minutes: 5)) {
          _looked = DateTime.now();
          unawaited(u.check());
        }
        return null;
      case 'arriving':
        return <String, dynamic>{};
      case 'perfOn' || 'keyboardHere' || 'ghostPeers' || 'deskUnrestricted':
        return false;
      case 'deskList':
        return const [];
      case 'deskState':
        return {'phase': 'none'};
      case 'ownNumber':
        // The phone's own (android DeskCalls), where it answers it; a phone before that has none to give.
        if (!_caps.contains('ownNumber')) return null;
        try {
          return await link.request('ownNumber');
        } on LinkDown {
          return null;
        }
      case 'telegram':
        // The phone's Telegram approves this computer's sign-in (lib/inbox/telegram.dart answerComputer).
        if (!_caps.contains('telegram')) throw const PhoneError('Update Uplink on your phone to sign in to Telegram through it.');
        return link.request('telegram', a, const Duration(seconds: 40));
      case 'signins':
        // The networks' sign-ins the phone holds (lib/inbox/curl_sync.dart forComputer): none from a phone too old to say.
        if (!_caps.contains('signins')) return const <String, Object?>{'entries': <String, Object?>{}};
        return link.request('signins', a, const Duration(seconds: 20));
      case 'rcs':
        // How RCS stands on the phone (lib/gm/rcs_share.dart, GMFB-11).
        if (!_caps.contains('rcs')) throw const PhoneError('Update Uplink on your phone to see its RCS here.');
        return link.request('rcs', a, const Duration(seconds: 15));
      case 'voice':
        // The phone's voice channels, kept in step with this computer's (lib/voice/channels.dart).
        if (!_caps.contains('voice')) throw const PhoneError('Update Uplink on your phone to see its spaces here.');
        return link.request('voice', a, const Duration(seconds: 15));
      case 'translate' || 'translateLanguages' || 'translateModel':
        // Translation is the phone's (android Translate.kt): this computer's texts are translated there, as asked. A
        // phone from before it, or one out of reach, leaves the words as they came, and says nothing more.
        final none = switch (method) { 'translate' => <String, Object?>{'state': 'unavailable'}, 'translateLanguages' => const <Object?>[], _ => false };
        if (!_caps.contains('translate')) return none;
        final op = switch (method) { 'translateLanguages' => 'languages', 'translateModel' => 'model', _ => 'text' };
        try {
          return await link.request('translate', {'what': {...a, 'op': op}}, const Duration(seconds: 20));
        } on LinkDown {
          return method == 'translate' ? const {'state': 'offline'} : none;
        } catch (_) {
          return method == 'translate' ? const {'state': 'failed'} : none;
        }
      case 'handover':
        // The phone's identity and friends, for this computer's own network (lib/friends/handover.dart).
        if (!_caps.contains('handover')) throw const PhoneError('Update Uplink on your phone to have friends on this computer.');
        return link.request('handover', a, const Duration(seconds: 40));
      case 'buddies':
        // Friends by username, the phone's (lib/friends/buddies.dart forComputer): added, answered and listed through it.
        if (!_caps.contains('buddies')) throw const PhoneError('Update Uplink on your phone to add friends from here.');
        return link.request('buddies', a, const Duration(seconds: 40));
      case 'me':
        // Settings › Me's number, verified through the phone (Me.followPhone); a code takes the phone a while.
        if (!_caps.contains('me')) throw const PhoneError('Update Uplink on your phone to verify your number from here.');
        return link.request('me', a, const Duration(seconds: 45));
      case 'setOpenThread' || 'openRequest' || 'systemPalette' || 'e2eMine' || 'setAutoUpdate':
        return null;
      default:
        throw const PhoneError('That is done on the phone.');
    }
  }

  /// The most conversations asked of the phone at once (the phone hands over no more: android DeskCalls.LOT).
  static const lot = 250;

  /// Keeps [items] among the conversations read last, each in place of the one held under its id, newest first.
  void _remember(List<dynamic> items) {
    final byId = <Object?, dynamic>{for (final c in _conversations ?? const []) (c as Map)['id']: c, for (final c in items) (c as Map)['id']: c};
    _conversations = byId.values.toList()..sort((x, y) => (((y as Map)['date'] as num?) ?? 0).compareTo(((x as Map)['date'] as num?) ?? 0));
  }

  /// A conversation's line in the list as it is held, or null where it is not among those read.
  Map<String, dynamic>? _cached(int thread) {
    for (final c in _conversations ?? const []) {
      if (((c as Map)['id'] as num?)?.toInt() == thread) return c.cast<String, dynamic>();
    }
    return null;
  }

  /// The last few videos brought over, so the one a picture was just made of is not fetched again to be played.
  final _videos = <int, Uint8List>{};

  /// A video's bytes, from the last four held or fetched from the phone; null where they cannot be had.
  Future<Uint8List?> _video(int id) async {
    final had = _videos.remove(id);
    final bytes = had ?? await _part(id);
    if (bytes == null || bytes.isEmpty) return null;
    _videos[id] = bytes;
    while (_videos.length > 4) {
      _videos.remove(_videos.keys.first);
    }
    return bytes;
  }

  /// The phone's video [bytes] as a file for the player, in the folder the Mac's DeskVideo.swift sweeps as the app
  /// opens and quits (`ghost-messaging-video/<this run's pid>`), in the account's own temporary folder (the Mac's
  /// per-user TMPDIR, Windows' %TEMP%), which no other account can read. The player removes it
  /// once its screen has gone (VideoScreen.dropFile), so nothing of a conversation stays on the computer's disk.
  static Future<String?> videoCopy(int id, Uint8List bytes, String ending, {Directory? under}) async {
    try {
      final folder = Directory('${(under ?? Directory.systemTemp).path}/ghost-messaging-video/$pid');
      await folder.create(recursive: true);
      final safe = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ending.toLowerCase()) ? ending.toLowerCase() : 'mp4';
      final file = File('${folder.path}/$id-${DateTime.now().microsecondsSinceEpoch}.$safe');
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// A picture's or video's bytes from the phone, a piece at a time, each a frame's worth at most (Matt, 2026-11-20: "some photos and videos are not
  /// coming through"): two at once at most ([_partsAtOnce]), the rest waiting their turn, since every piece asked of a
  /// phone that answers on two threads waited behind all the others and a conversation of pictures ran past the 20
  /// seconds a request is given; and a piece the link drops or is slow with is asked again twice before the picture is
  /// given up.
  Future<Uint8List?> _part(int id) async {
    while (_partsGoing >= _partsAtOnce) {
      final turn = Completer<void>();
      _partsWaiting.add(turn);
      await turn.future;
    }
    _partsGoing++;
    try {
      final whole = BytesBuilder(copy: false);
      var total = -1;
      while (total < 0 || whole.length < total) {
        Object? piece;
        for (var tries = 0;; tries++) {
          try {
            piece = await link.request('part', {'id': id, 'offset': whole.length}, const Duration(seconds: 40));
            break;
          } on LinkDown {
            return null;
          } catch (_) {
            if (tries >= 2) return null;
          }
        }
        if (piece is! Map) return null;
        total = (piece['total'] as num).toInt();
        final data = base64.decode(piece['data'] as String);
        if (data.isEmpty) break;
        whole.add(data);
      }
      return whole.takeBytes();
    } catch (_) {
      return null;
    } finally {
      _partsGoing--;
      if (_partsWaiting.isNotEmpty) _partsWaiting.removeAt(0).complete();
    }
  }

  /// How many pictures are fetched from the phone at once; the rest wait their turn, first come first.
  static const _partsAtOnce = 2;
  int _partsGoing = 0;
  final List<Completer<void>> _partsWaiting = [];

  /// An address in the form two writings of it share: a number's last ten digits (all of them, from seven to ten),
  /// anything else trimmed and in lower case.
  static String _digits(String address) {
    final d = address.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length >= 7 ? (d.length > 10 ? d.substring(d.length - 10) : d) : address.trim().toLowerCase();
  }

  /// The conversation with exactly these people, among those read last; -1 when it is not known.
  int _threadOf(List<String> addresses) {
    final want = addresses.map(_digits).toSet();
    for (final c in _conversations ?? const []) {
      final people = {for (final p in ((c as Map)['people'] as List? ?? const [])) _digits('${(p as Map)['address']}')};
      if (people.length == want.length && people.containsAll(want)) return (c['id'] as num).toInt();
    }
    return -1;
  }

  /// A name for something sent, so the phone sends it once however many times it is asked.
  String _name() => DeskCrypto.hex(DeskCrypto.randomBytes(12));

  /// Hands [bytes] over to the phone a piece at a time under a name of their own, which the call that sends them
  /// gives: a frame carries less than a megabyte, and a picture is more.
  Future<String> _handOver(Uint8List bytes) async {
    if (bytes.isEmpty) throw const PhoneError('There is nothing in that to send');
    if (bytes.length > mostBytes) throw PhoneError('That is too large to send (${mostBytes ~/ (1024 * 1024)} MB at most)');
    final id = DeskCrypto.hex(DeskCrypto.randomBytes(8));
    for (var at = 0; at < bytes.length; at += piece) {
      final end = math.min(bytes.length, at + piece);
      await link.request('put', {'upload': id, 'offset': at, 'total': bytes.length, 'data': base64.encode(Uint8List.sublistView(bytes, at, end))});
    }
    return id;
  }

  /// As much as one frame carries, and the most the phone takes (android DeskCalls.PIECE, MOST_BYTES).
  static const piece = 384 * 1024;
  static const mostBytes = 12 * 1024 * 1024;

  /// Where what was sent went: read again, since it is in the conversation now.
  int _went(Map sent) {
    final thread = (sent['thread'] as num).toInt();
    // Its next reading waits for the phone: what was sent is to be seen as the phone has it.
    _stale(thread);
    _hold.add(thread);
    Sms.instance.changes.add(thread);
    return thread;
  }

  /// Something the phone keeps was changed from here: what was read is read again.
  void _reread() {
    // Nothing kept is taken for current, and each conversation's next reading waits for the phone, so what was
    // deleted or changed from here is not shown again from what is kept.
    _allChanged++;
    _listCurrent = false;
    _hold.addAll(_messages.keys);
    Sms.instance.changes.add(-1);
  }

  /// What a picture's file is, by its name's ending; null for what is not one the phone can make ready.
  static String? pictureType(String name) {
    final dot = name.lastIndexOf('.');
    return switch (dot < 0 ? '' : name.substring(dot + 1).toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      'bmp' => 'image/bmp',
      _ => null,
    };
  }

  /// Pictures chosen on the Mac ([a]'s `attachments` are their paths), handed to the phone and sent as it sends its
  /// own: made to fit the carrier there, with the words beside them.
  Future<int> _sendPictures(Map<String, dynamic> a) async {
    final files = <Map<String, String>>[];
    for (final path in (a['attachments'] as List)) {
      final name = '$path'.split('/').last;
      final type = pictureType(name);
      if (type == null) throw PhoneError('$name isn\'t a picture. Only pictures can be sent from here for now.');
      final Uint8List bytes;
      try {
        bytes = await File('$path').readAsBytes();
      } catch (_) {
        throw PhoneError('$name couldn\'t be read.');
      }
      files.add({'upload': await _handOver(bytes), 'name': name, 'type': type});
    }
    final sent = (await link.request('sendPictures', {'key': _name(), 'addresses': a['addresses'], 'body': '${a['body'] ?? ''}', 'files': files})) as Map;
    return _went(sent);
  }

  /// Sends a text through the phone; answers the conversation it went into. With the phone away it is kept among
  /// those waiting, where the conversation is one already known.
  Future<int> _send(Map<String, dynamic> a) async {
    final addresses = [for (final x in (a['addresses'] as List? ?? const [])) '$x'];
    final body = '${a['body'] ?? ''}';
    final key = _name();
    try {
      final r = (await link.request('send', {'key': key, 'addresses': addresses, 'body': body})) as Map;
      return (r['thread'] as num).toInt();
    } on LinkDown {
      // The phone could not be reached (or went before it answered): the text waits here, under the same name, so
      // the phone sends it once however many times it is asked.
      final thread = _threadOf(addresses);
      if (thread < 0) throw const LinkDown('Your phone isn\'t reachable, and this would start a new conversation. Try again when it is back.');
      _waiting.add(_Waiting(key: key, thread: thread, addresses: addresses, body: body, id: _localId--));
      Sms.instance.changes.add(thread);
      return thread;
    }
  }

  /// The phone is back: what waited goes, oldest first.
  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final w in List.of(_waiting)) {
        if (w.failed) continue;
        try {
          await link.request('send', {'key': w.key, 'addresses': w.addresses, 'body': w.body});
          _waiting.remove(w);
        } on LinkDown {
          return;
        } on PhoneError {
          w.failed = true;
        }
        Sms.instance.changes.add(w.thread);
      }
    } finally {
      _flushing = false;
    }
  }
}

/// A text typed while the phone could not be reached.
class _Waiting {
  _Waiting({required this.key, required this.thread, required this.addresses, required this.body, required this.id}) : date = DateTime.now();
  /// The name the phone remembers it by, so it is sent once however often it is asked.
  final String key;
  final int thread;
  final List<String> addresses;
  final String body;

  /// Below zero: its id among the conversation's messages until the phone has it.
  final int id;
  final DateTime date;

  /// The phone was reached and would not send it.
  bool failed = false;

  /// As the conversation draws it, among the phone's own messages.
  Map<String, dynamic> get message => {'id': id, 'kind': 'waiting', 'address': '', 'body': body, 'date': date.millisecondsSinceEpoch, 'outgoing': true, 'state': failed ? 'failed' : 'waiting', 'parts': const []};
}
