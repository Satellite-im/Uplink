import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../me/lookup_budget.dart';
import 'crypto.dart';
import 'ledger.dart' show LedgerTimer;
import 'packet.dart';

/// A friend added by username, as the name watch knows them: the username they go by, and the account name and key
/// the relay answered with when they were added, which is who they are from then on (lib/friends/buddies.dart).
@immutable
class WatchedName {
  const WatchedName(this.username, this.id, this.key);
  final String username;
  final String id;
  final String key;
}

/// What a [NameChange] says.
enum NameKind {
  /// A friend's username now names another account on this relay ([NameWatch.changeFor]).
  friend,

  /// This person's own username now names another account here, and this key holds no username on this relay: given up
  /// or changed on another device, a new key, or another relay.
  none,

  /// The same, and this key holds a different username on this relay now: changed on another device.
  changed,

  /// The same, and the other key is one this device held the name under before (from before a new key).
  old,

  /// The relay says this key holds the name, and answers others with another key: the relay contradicts itself.
  contradicts,

  /// A friend's app saw the relay give this person's username to another account ([NameWatch.toldMe]).
  told,
}

/// The relay gave a username to an account other than the one held for it: which username, the account name of the key
/// it gave (the first 16 bytes of the key's SHA-256, in hex), when that was seen (ms), what kind of thing it is, and,
/// for a friend's word about this person's own username, which friend's app saw it.
@immutable
class NameChange {
  const NameChange({required this.username, required this.other, required this.at, this.kind = NameKind.friend, this.by});
  final String username;
  final String other;
  final int at;
  final NameKind kind;
  final String? by;

  List<Object?> toJson() => [username, other, at, kind.name, by];

  static NameChange? fromJson(Object? j) {
    if (j is! List || j.length < 3 || j[0] is! String || j[1] is! String || j[2] is! int) return null;
    final kind = j.length > 3 && j[3] is String ? NameKind.values.asNameMap()[j[3]] : null;
    return NameChange(username: j[0] as String, other: j[1] as String, at: j[2] as int, kind: kind ?? NameKind.friend, by: j.length > 4 && j[4] is String ? j[4] as String : null);
  }
}

/// What the watch knows of one relay (it keeps each relay apart: another relay is another directory).
class _Relay {
  /// When each friend's username was last asked and answered, and when each was first seen here.
  final Map<String, int> checked = {}, seen = {};

  /// The friends whose username this relay has named their own key for, and when: only for them does another account
  /// mean anything here. A relay of one's own, or a name never confirmed here, is another directory, where someone else
  /// holding the name is nothing to say. One confirmed as they were asked to be friends is kept until they say yes (for
  /// [NameWatch.confirmedFor] at most).
  final Map<String, int> confirmed = {};
  final Map<String, NameChange> changes = {};

  /// When each friend was last told that their username names another account here.
  final Map<String, int> told = {};

  /// The username each friend goes by now where they said a new one and this relay named their key for it: the one
  /// asked about from then on (their old one may be anyone's now).
  final Map<String, String> renamed = {};

  /// This person's own username, where it names another account here.
  NameChange? own;

  /// When any friend's username was last asked and answered here (ms; 0 never).
  int get latest => checked.values.fold(0, (a, b) => b > a ? b : a);

  Map<String, Object?> toJson() => {
        'c': checked,
        's': seen,
        'b': confirmed,
        'x': {for (final e in changes.entries) e.key: e.value.toJson()},
        't': told,
        'n': renamed,
        'o': own?.toJson(),
      };

  /// What was kept of a relay, with no time later than [now]; empty where [j] isn't one.
  static _Relay fromJson(Object? j, int now) {
    final r = _Relay();
    if (j is! Map) return r;
    void times(Object? m, Map<String, int> into) {
      if (m is! Map) return;
      for (final e in m.entries) {
        // A clock set back since: what is kept is held to now, so nothing waits for the clock to catch up (S7).
        if (e.key is String && e.value is int) into[e.key as String] = (e.value as int) > now ? now : e.value as int;
      }
    }

    times(j['c'], r.checked);
    times(j['s'], r.seen);
    times(j['t'], r.told);
    final b = j['b'];
    if (b is Map) times(b, r.confirmed);
    final x = j['x'];
    if (x is Map) {
      for (final e in x.entries) {
        final c = NameChange.fromJson(e.value);
        if (e.key is String && c != null) r.changes[e.key as String] = c;
      }
    }
    final n = j['n'];
    if (n is Map) {
      for (final e in n.entries) {
        if (e.key is String && e.value is String) r.renamed[e.key as String] = e.value as String;
      }
    }
    r.own = NameChange.fromJson(j['o']);
    return r;
  }
}

/// The name watch (docs/OPEN_NETWORK.md, section 3): what checks the relay's "@name is this key", and needs no direct
/// route. A friend added by username was found by asking the relay who has that username; their app asks the same again
/// once a day ([every]), each friend at a time of its own through the day, and asks of its own username each time it
/// signs in to the relay ([signedIn]). An account of several devices asks once a day all the same: each device asks
/// about every friend, each on a day of its own (`share`).
///
/// **Each relay is its own directory**, and kept apart (the relay in use: `relay`). For a friend, another account under
/// their username means something only on a relay that has named their own key under it before (the lookup that added
/// them, [confirmed], or a daily one): there it is shown on that friend ([changeFor]: "@maya now belongs to another
/// account on the relay. If Maya changed or gave up her username, that's why."), cleared when the relay says nobody has
/// it or names their key again, and the friend is told, sealed, in an envelope of kind [kind], at most once a day while
/// it lasts:
///
///     {"u": the username, "i": the account name the relay gave it to, "at": when (ms)}
///
/// Where a friend says, sealed, that they go by another username now ([saidName]), the new one is looked up, and taken
/// (`rename`) only where the relay names their key for it.
///
/// **Its own username** is asked only on a relay where this device has held it (the relay says this key holds it there,
/// `held`, or it was [claimed] there), and what comes back is said calmly ([NameKind]): given up or changed on another
/// device, a new key (the old key still holds it), or another relay. Only where the relay says this key holds the name
/// and answers others with another account does it contradict itself. Each is said once ([notices], [notice]): a
/// sign-in after does not say it again, and a friend's word about it is said once a week at most.
///
/// **Lookups.** The relay answers an account 120 lookups an hour, counted for all its devices together (they sign in as
/// one; relay/lib/handles.dart): the watch's lookups and the friend requests' checks are held to one budget for the
/// whole account, shared out among the account's devices it knows of (`lookups`: LookupBudget, of which the requests
/// leave the watch a third), the watch's a minute apart, and none for an hour after the relay says too many. What is
/// shared out is the time, not the friends: with n devices, each asks about every friend every n days, on
/// its own day of the n, so the account still asks about each friend once a day and every device sees what the relay
/// says of every friend (the review, N2). What a device shows of a friend it asks again a day on, whatever its day, so
/// it is never left standing once nobody holds the name (N3).
///
/// Nothing here changes who a friend is: a friend stays the key that was added, whatever the relay says after.
class NameWatch extends ChangeNotifier {
  NameWatch({
    required this.me,
    required this.username,
    required this.friends,
    required this.whois,
    required this.tell,
    required this.read,
    required this.write,
    String Function()? relay,
    Future<String?> Function()? held,
    void Function(String id, String username)? rename,
    ({int index, int of}) Function()? share,
    LookupBudget? lookups,
    DateTime Function()? now,
    LedgerTimer? timer,
  })  : _relayOf = relay,
        _holds = held,
        _rename = rename,
        _share = share,
        _lookups = lookups ?? LookupBudget(share: share, now: now),
        _now = now ?? DateTime.now,
        _timer = timer ?? Timer.new;

  /// The app's own, once started (lib/people.dart): the screens read it, and signing out wipes it.
  static NameWatch? instance;

  /// The envelope a friend is told with.
  static const kind = 'name';

  /// How often the account asks about each friend's username, and how far apart this device's lookups are at least.
  static const every = Duration(days: 1);
  static const gap = Duration(minutes: 1);

  /// Its own username is asked at each sign-in, but not more often than this.
  static const ownEvery = Duration(minutes: 10);

  /// A friend is told again while the relay goes on giving their username to another account, at most this often; a
  /// friend's word is taken at most this often from them; and a new username a friend says is looked up at most this
  /// often for them.
  static const tellEvery = Duration(days: 1);
  static const heardEvery = Duration(hours: 1);
  static const renameEvery = Duration(hours: 1);

  /// How long a friend's word about this person's username is kept, and the most kept; and how long something said once
  /// is not said again (a friend's word, a week; the rest, a month).
  static const toldFor = Duration(days: 7);
  static const mostTold = 8;
  static const saidFor = Duration(days: 30);

  /// When the relay could not be asked, how long before it is tried again.
  static const retryAfter = Duration(minutes: 10);

  /// The most relays, and the most of this device's own usernames, it keeps anything of; and how long a name confirmed
  /// for someone not yet a friend (asked to be one) is kept.
  static const mostRelays = 4, mostHeld = 16;
  static const confirmedFor = Duration(days: 30);

  /// Where what it found is kept, with the app's choices.
  static const keptName = 'name_watch';
  static const keptNames = [keptName];

  /// This account's name; its username on the relay, where it has one.
  final String? Function() me;
  final String? Function() username;

  /// Friends added by username, as kept.
  final List<WatchedName> Function() friends;

  /// Asks the relay who has a username (Me.whois): their account name and key, or null for nobody. Throws where it
  /// can't be asked now.
  final Future<({String id, String key})?> Function(String username) whois;

  /// Sends an envelope to a friend, sealed: by the relay, and by a direct link where one is open.
  final Future<void> Function(String id, Envelope envelope) tell;

  /// Where it keeps what it found: the app's choices.
  final String Function(String name) read;
  final void Function(String name, String value) write;

  /// The relay in use (its address); which username this key holds on it (Me.heldName: the name's hash, null for
  /// none); what takes a friend's new username once confirmed (Buddies.rename); this device's place among the account's
  /// devices it knows of; and the account's budget of lookups made of the app's own accord, which this device's friend
  /// requests' checks share (the app's: LookupBudget.instance).
  final String Function()? _relayOf;
  final Future<String?> Function()? _holds;
  final void Function(String id, String username)? _rename;
  final ({int index, int of}) Function()? _share;
  final LookupBudget _lookups;
  final DateTime Function() _now;
  final LedgerTimer _timer;

  final Map<String, _Relay> _relays = {};
  final List<NameChange> _toldMe = [];
  final Map<String, int> _said = {};

  /// The usernames this device has held, each with the key it held it under and on which relay ([NameKind.old]).
  final List<({String username, String id, String relay, int at})> _heldUnder = [];
  final Map<String, int> _heard = {}, _renameAsked = {};
  final Map<String, String> _renames = {};
  String? _keptFor;
  int _ownAsked = 0, _lastAsked = 0, _retry = 0;
  Timer? _next;
  bool _started = false, _asking = false, _gone = false, _ownDue = false;

  /// What to show the person at once: something about their own username, said once.
  final ValueNotifier<NameChange?> notice = ValueNotifier(null);

  /// The app's own watch's [notice]s as they come, for the frame to show (lib/ui/shell.dart), whichever watch is the
  /// app's by then.
  static Stream<NameChange> get notices => _notices.stream;
  static final _notices = StreamController<NameChange>.broadcast();

  /// Says [change] at once, unless the same was said within [within].
  void _say(NameChange change, {Duration within = saidFor}) {
    final key = '${change.username}|${change.other}|${change.kind == NameKind.told ? 't' : 'o'}';
    final now = nowMs;
    _said.removeWhere((_, at) => now - at >= saidFor.inMilliseconds || at > now);
    final had = _said[key];
    if (had != null && now - had < within.inMilliseconds) return;
    _said[key] = now;
    while (_said.length > 64) {
      _said.remove(_said.keys.first);
    }
    notice.value = change;
    if (identical(this, instance)) _notices.add(change);
  }

  int get nowMs => _now().millisecondsSinceEpoch;

  /// The address of the relay in use; empty where there is none to say.
  String get _relayNow {
    try {
      return _relayOf?.call() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// What is known of the relay in use, begun where nothing is.
  _Relay get _here => _relays[_relayNow] ??= _Relay();

  /// What the relay in use said of [friendId]'s username where it named another account; null where it has not, or
  /// names nobody or their key again.
  NameChange? changeFor(String friendId) => _here.changes[friendId];

  /// Every friend whose username the relay in use gives to another account, with what it said.
  List<({String friend, NameChange change})> get changes => List.unmodifiable([for (final e in _here.changes.entries) (friend: e.key, change: e.value)]);

  /// What the relay in use said of this person's own username, where it names another account.
  NameChange? get own {
    final o = _here.own, name = username();
    return o == null || name == null || _tidy(name) != o.username ? null : o;
  }

  /// Friends' apps that saw the relay give this person's username to another account, newest last.
  List<NameChange> get toldMe {
    final now = nowMs, name = username();
    return List.unmodifiable(_toldMe.where((t) => now - t.at < toldFor.inMilliseconds && name != null && _tidy(name) == t.username));
  }

  /// When a friend's username was last asked and answered on the relay in use (ms; 0 never), and how many were asked in
  /// the day before now.
  int get lastAsked => _here.latest;
  int get askedInDay {
    final now = nowMs;
    return _here.checked.values.where((t) => now - t < every.inMilliseconds).length;
  }

  /// How many friends added by username are watched, by this device and the account's others together.
  int get watching => _friends().length;

  /// The friends watched, as the app says them now; none where it can't say.
  List<WatchedName> _friends() {
    try {
      return friends();
    } catch (_) {
      return const [];
    }
  }

  /// This device's place among the account's devices it knows of: its day of every [of], and its share of the lookups.
  ({int index, int of}) get _shareNow {
    try {
      final s = _share?.call();
      if (s == null || s.of < 1 || s.index < 0 || s.index >= s.of) return (index: 0, of: 1);
      return s;
    } catch (_) {
      return (index: 0, of: 1);
    }
  }

  /// Reads what was kept and sets the timer for the first lookup due.
  void start() {
    if (_started || _gone) return;
    _started = true;
    _load();
    _plan();
  }

  /// Asks nothing more until started again; what is kept stays.
  void stop() {
    _started = false;
    _next?.cancel();
    _next = null;
  }

  /// The friends changed: what was shown of anyone no longer a friend goes at once, and the watch plans again.
  void friendsChanged() {
    if (_gone) return;
    final ids = {for (final f in _friends()) f.id};
    if (_relays.values.any((r) => r.changes.keys.any((id) => !ids.contains(id)))) {
      _save();
      notifyListeners();
    }
    if (_started) _plan();
  }

  // --- asking -----------------------------------------------------------------------------------------------------------

  /// When [f]'s username is next due on the relay in use: at this device's next turn for them ([_turnAfter]: every n
  /// days for n devices) and never within a day of when it last asked; where it shows something of them, a day after it
  /// last asked, whatever its turn (N3). Never asked, at its first turn after they were first seen there (kept, so a
  /// phone that runs for less than a day still comes to each in turn: S2).
  int _dueAt(WatchedName f) {
    final r = _here, now = nowMs;
    final last = r.checked[f.id];
    if (last != null) {
      final l = last > now ? now : last, again = l + every.inMilliseconds;
      if (r.changes.containsKey(f.id)) return again;
      final turn = _turnAfter(f, l);
      return turn > again ? turn : again;
    }
    var seen = r.seen[f.id];
    if (seen == null || seen > now) {
      seen = r.seen[f.id] = now;
      _dirty = true;
    }
    return _turnAfter(f, seen);
  }

  /// This device's first turn for [f] after [t]. The account asks about each friend once a day, at a time of the day of
  /// its own, and the days go round its n devices in turn, starting with a device of the friend's own ([_spread]: the
  /// same on every device of the account): each device asks about a friend every n days, and about a different n-th of
  /// the friends each day, so none asks more in a day than its share of the lookups allows (N2). Counted from 1970, so
  /// every device reckons the days alike.
  int _turnAfter(WatchedName f, int t) {
    final s = _shareNow, day = every.inMilliseconds, at = _spread(f.id);
    final period = day * s.of, phase = at.time + (at.day + s.index) % s.of * day;
    return t - (t - phase) % period + period;
  }

  /// What was first seen just now is kept with the next save.
  bool _dirty = false;

  /// [id]'s time of the day, and its day among the account's devices.
  ({int time, int day}) _spread(String id) {
    final h = NetCrypto.sha256(utf8.encode('ghost name watch ${me() ?? ''} $id'));
    int at(int i) => (h[i] << 24 | h[i + 1] << 16 | h[i + 2] << 8 | h[i + 3]) & 0x7fffffff;
    return (time: at(0) % every.inMilliseconds, day: at(4));
  }

  /// Whether one more lookup may be made now: within this device's share of the account's lookups ([_lookups]), none
  /// while the relay has said too many, [gap] apart, and none while the relay couldn't be asked a while ago.
  bool _mayAsk() {
    final now = nowMs;
    if (_lastAsked > now) _lastAsked = now;
    if (_retry > now + retryAfter.inMilliseconds) _retry = now;
    return _lookups.may(watch: true) && now - _lastAsked >= gap.inMilliseconds && now >= _retry;
  }

  /// When the next lookup may be made, by [_mayAsk].
  int _nextSlot() {
    final now = nowMs;
    if (_lastAsked > now) _lastAsked = now;
    var at = _lastAsked + gap.inMilliseconds;
    final free = _lookups.nextFree(watch: true);
    if (free > at) at = free;
    if (_retry > at) at = _retry;
    return at;
  }

  /// Sets the timer for the next lookup due, no sooner than one may be made.
  void _plan() {
    _next?.cancel();
    _next = null;
    if (!_started || _gone || _asking) return;
    final list = _friends();
    if (list.isEmpty && _renames.isEmpty && !_ownDue) return;
    var due = _renames.isNotEmpty || _ownDue ? nowMs : list.map(_dueAt).reduce((a, b) => a < b ? a : b);
    if (_dirty) _save();
    final slot = _nextSlot();
    if (slot > due) due = slot;
    final wait = due - nowMs;
    _next = _timer(Duration(milliseconds: wait < 0 ? 0 : wait), () {
      _next = null;
      unawaited(_askDue());
    });
  }

  /// Makes the one lookup that is due, where one may be made now, and plans the next.
  Future<void> _askDue() async {
    if (!_started || _gone || _asking) return;
    if (!_mayAsk()) return _plan();
    // Its own username, where a sign-in asked for it, comes first; then a new username a friend said.
    if (_ownDue) {
      _ownDue = false;
      await _ownCheck();
      return _plan();
    }
    if (_renames.isNotEmpty) {
      final id = _renames.keys.first, name = _renames.remove(id)!;
      await _askRename(id, name);
      return _plan();
    }
    final now = nowMs;
    final due = [for (final f in _friends()) if (_dueAt(f) <= now) f]..sort((a, b) => _dueAt(a).compareTo(_dueAt(b)));
    if (due.isEmpty) return _plan();
    await _askFriend(due.first);
    _plan();
  }

  /// Notes a lookup made now.
  void _count() {
    _lookups.took();
    _lastAsked = nowMs;
  }

  /// What became of a lookup that threw: the relay said too many (nothing of the app's own accord for an hour, the
  /// friend requests' checks included: [_lookups]), or couldn't be asked (ten minutes).
  void _failed(Object e) {
    if (LookupBudget.isRefusal(e)) {
      _lookups.refused();
    } else {
      _retry = nowMs + retryAfter.inMilliseconds;
    }
  }

  /// After a lookup: kept. Its own username, where a sign-in came while it was under way, is asked next ([_askDue]: S6).
  void _after() {
    _asking = false;
    _save();
  }

  /// The username [f] goes by on the relay in use, as far as the watch knows: a new one they said and this relay
  /// confirmed, else the one they were added under.
  String _nameFor(WatchedName f) {
    final r = _here, n = r.renamed[f.id];
    if (n != null && n == _tidy(f.username)) r.renamed.remove(f.id);
    return r.renamed[f.id] ?? _tidy(f.username);
  }

  /// Asks the relay who has [f]'s username, and weighs the answer against the key held for them.
  Future<void> _askFriend(WatchedName f) async {
    _asking = true;
    _count();
    final r = _here;
    final name = _nameFor(f);
    try {
      final got = await whois(name);
      _retry = 0;
      r.checked[f.id] = nowMs;
      if (got == null || _sameKey(got, f.id)) {
        // Nobody has it now (given up, perhaps for another), or their key again: nothing to say of them; and where it is
        // theirs, this relay has named their key under it.
        if (got != null) r.confirmed[f.id] = nowMs;
        if (r.changes.remove(f.id) != null) {
          r.told.remove(f.id);
          notifyListeners();
        }
        return;
      }
      // Another account: something to say only where this relay named their key under this username before.
      if (!r.confirmed.containsKey(f.id)) return;
      final had = r.changes[f.id];
      final change = had != null && had.other == got.id && had.username == name ? had : NameChange(username: name, other: got.id, at: nowMs);
      r.changes[f.id] = change;
      if (!identical(had, change)) notifyListeners();
      if (nowMs - (r.told[f.id] ?? 0) >= tellEvery.inMilliseconds) {
        r.told[f.id] = nowMs;
        try {
          await tell(f.id, Envelope(kind: kind, body: {'u': name, 'i': got.id, 'at': change.at}));
        } catch (_) {}
      }
    } catch (e) {
      // Not asked after all: tried again a while on, or at the next sign-in.
      _failed(e);
    } finally {
      _after();
    }
  }

  /// Whether [got] names [id]'s key: the relay's account name is [id], and the key it gave makes that name.
  static bool _sameKey(({String id, String key}) got, String id) {
    if (got.id != id) return false;
    try {
      return NetCrypto.idOf(base64Decode(got.key)) == id;
    } catch (_) {
      return false;
    }
  }

  /// [id] was found under [username] just now by a lookup that named their key (an add, Buddies.add): the relay in use
  /// has confirmed it, and this device asks about them again no sooner than a day on, at its turn.
  void confirmed(String id, String username) {
    if (_gone) return;
    final r = _here;
    r.confirmed[id] = nowMs;
    r.checked[id] = nowMs;
    r.changes.remove(id);
    _save();
    if (_started) _plan();
  }

  /// A friend said, sealed, that they go by [username] now: looked up (at most every [renameEvery] for them), and where
  /// the relay names their key for it, asked about from then on in place of the old one, which may be anyone's now
  /// (`rename` is told too). Until then nothing changes.
  void saidName(String id, String username) {
    if (!_started || _gone) return;
    final f = _friends().where((f) => f.id == id).firstOrNull;
    final name = _tidy(username);
    if (f == null || name.isEmpty || name == _nameFor(f)) return;
    final now = nowMs;
    if (now - (_renameAsked[id] ?? -renameEvery.inMilliseconds) < renameEvery.inMilliseconds) return;
    _renameAsked[id] = now;
    _renames[id] = name;
    while (_renames.length > 16) {
      _renames.remove(_renames.keys.first);
    }
    _plan();
  }

  /// Asks the relay who [name] is, the username the friend [id] said they go by now: taken as theirs only where the
  /// relay names their own key for it.
  Future<void> _askRename(String id, String name) async {
    _asking = true;
    _count();
    try {
      final got = await whois(name);
      _retry = 0;
      if (got == null || !_sameKey(got, id)) return;
      final r = _here;
      r.renamed[id] = name;
      r.confirmed[id] = nowMs;
      r.checked[id] = nowMs;
      r.told.remove(id);
      if (r.changes.remove(id) != null) notifyListeners();
      try {
        _rename?.call(id, name);
      } catch (_) {}
    } catch (e) {
      _failed(e);
    } finally {
      _after();
    }
  }

  /// The relay was signed in to again: its own username is asked (at most every [ownEvery]; once a friend's lookup that
  /// is under way has ended, where one is: S6), and the friends' lookups that waited for it go on.
  Future<void> signedIn() async {
    if (!_started || _gone) return;
    // Waiting a few minutes on a relay that couldn't be reached: it can now.
    if (_retry > nowMs && _retry - nowMs <= retryAfter.inMilliseconds) _retry = 0;
    // Asked now where a lookup may be made now, else as soon as one may: never skipped for a friend's lookup under way.
    _ownDue = true;
    if (!_asking && _mayAsk()) return _askDue();
    _plan();
  }

  /// This person's username changed, or was given up: what was said of the one before goes.
  void usernameChanged() {
    if (_gone) return;
    final name = username();
    var changed = false;
    for (final r in _relays.values) {
      final o = r.own;
      if (o != null && (name == null || _tidy(name) != o.username)) {
        r.own = null;
        changed = true;
      }
    }
    if (changed) {
      _save();
      notifyListeners();
    }
  }

  /// This person claimed [name] on the relay in use, under this key: kept, so the relay naming this key, or an old key
  /// of this device's, for it is known for what it is.
  void claimed(String name) {
    final mine = me();
    if (_gone || mine == null) return;
    _remember(_tidy(name), mine, _relayNow);
    usernameChanged();
  }

  /// Keeps that this device held [name] under the key [id] on [relay], the newest [mostHeld] of them.
  void _remember(String name, String id, String relay) {
    if (_heldUnder.any((h) => h.username == name && h.id == id && h.relay == relay)) return;
    _heldUnder.add((username: name, id: id, relay: relay, at: nowMs));
    while (_heldUnder.length > mostHeld) {
      _heldUnder.removeAt(0);
    }
    _save();
  }

  /// Asks the relay in use who this person's own username names, [ownEvery] at most, and keeps what it says where it
  /// names another account.
  Future<void> _ownCheck() async {
    final name = username(), mine = me(), relay = _relayNow;
    final r = _here;
    if (name == null || name.isEmpty || mine == null) {
      // Given up: nothing is said of it.
      if (r.own != null) {
        r.own = null;
        _save();
        notifyListeners();
      }
      return;
    }
    final tidy = _tidy(name);
    if (r.own != null && r.own!.username != tidy) r.own = null;
    if (nowMs - _ownAsked < ownEvery.inMilliseconds) return;
    if (!_mayAsk()) {
      _ownDue = true;
      return;
    }
    _ownAsked = nowMs;
    _asking = true;
    try {
      // Which name this key holds here, where the relay can say: a name given up or changed on another device, a new key
      // and another relay all answer otherwise, and none of them is the relay lying.
      String? holds;
      var holdsKnown = false;
      final asked = _holds;
      if (asked != null) {
        try {
          holds = await asked();
          holdsKnown = true;
        } catch (_) {}
      }
      final ours = holdsKnown && holds == _nameKey(tidy);
      final wasHere = ours || _heldUnder.any((h) => h.username == tidy && h.relay == relay);
      // A relay where this device never held the name is another directory: nothing to ask of it, nothing to say.
      if (!wasHere) {
        if (r.own != null) {
          r.own = null;
          notifyListeners();
        }
        return;
      }
      _count();
      final got = await whois(tidy);
      _retry = 0;
      if (got == null || _sameKey(got, mine)) {
        if (got != null) _remember(tidy, mine, relay);
        if (r.own != null) {
          r.own = null;
          notifyListeners();
        }
        return;
      }
      final kind = _heldUnder.any((h) => h.username == tidy && h.relay == relay && h.id == got.id)
          ? NameKind.old
          : ours
              ? NameKind.contradicts
              : holdsKnown && holds != null
                  ? NameKind.changed
                  : NameKind.none;
      final had = r.own;
      final change = had != null && had.other == got.id && had.kind == kind ? had : NameChange(username: tidy, other: got.id, at: nowMs, kind: kind);
      r.own = change;
      _say(change);
      if (!identical(had, change)) notifyListeners();
    } catch (e) {
      _failed(e);
    } finally {
      _asking = false;
      _save();
    }
  }

  /// The relay's hash of a username (relay/lib/handles.dart nameKey; Me.nameKeyOf).
  static String _nameKey(String name) => NetCrypto.hex(NetCrypto.sha256(utf8.encode('ghost-name v1|${_tidy(name)}')));

  // --- what friends say -----------------------------------------------------------------------------------------------

  /// A sealed envelope from [from]: where it is a friend by username's word that the relay gave this person's username
  /// to another account, kept and shown, and said at once where it is new this week.
  void heard(String from, Envelope e, {bool sealed = true}) {
    if (e.kind != kind || !sealed || _gone) return;
    final name = username(), mine = me();
    if (name == null || name.isEmpty || mine == null) return;
    if (!_friends().any((f) => f.id == from)) return;
    final u = e.body['u'], i = e.body['i'];
    if (u is! String || _tidy(u) != _tidy(name) || i is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(i) || i == mine) return;
    final now = nowMs;
    if (now - (_heard[from] ?? -heardEvery.inMilliseconds) < heardEvery.inMilliseconds) return;
    _heard[from] = now;
    final change = NameChange(username: _tidy(name), other: i, at: now, kind: NameKind.told, by: from);
    _toldMe
      ..removeWhere((t) => t.by == from || now - t.at >= toldFor.inMilliseconds)
      ..add(change);
    while (_toldMe.length > mostTold) {
      _toldMe.removeAt(0);
    }
    // The same word from another friend, or another device of theirs, is not said again within the week.
    _say(change, within: toldFor);
    _save();
    notifyListeners();
  }

  /// A username as it is compared: trimmed, in small letters, with no @ before it.
  static String _tidy(String name) {
    var n = name.trim().toLowerCase();
    while (n.startsWith('@')) {
      n = n.substring(1);
    }
    return n;
  }

  // --- keeping ----------------------------------------------------------------------------------------------------------

  /// Reads what was kept ([keptName]); no time in it is taken as later than now.
  void _load() {
    Map? j;
    try {
      final d = jsonDecode(read(keptName));
      if (d is Map) j = d;
    } catch (_) {}
    final mine = me();
    _keptFor = mine;
    if (j == null) return;
    final now = nowMs;
    // Which keys this device held its usernames under: this device's whatever identity it has now (a new key is another
    // identity, and the old key still holding the name is what [NameKind.old] says).
    for (final h in (j['h'] is List ? j['h'] as List : const [])) {
      if (h is List && h.length >= 4 && h[0] is String && h[1] is String && h[2] is String && h[3] is int) {
        _heldUnder.add((username: h[0] as String, id: h[1] as String, relay: h[2] as String, at: (h[3] as int) > now ? now : h[3] as int));
      }
    }
    // The rest, kept for another identity (an account signed in to since, without signing out): none of it is this
    // one's (S9).
    if (mine != null && j['me'] != null && j['me'] != mine) return;
    final relays = j['r'];
    if (relays is Map) {
      for (final e in relays.entries) {
        if (e.key is String) _relays[e.key as String] = _Relay.fromJson(e.value, now);
      }
    }
    for (final m in (j['m'] is List ? j['m'] as List : const [])) {
      final c = NameChange.fromJson(m);
      if (c != null && c.by != null) _toldMe.add(c);
    }
    final said = j['s'];
    if (said is Map) {
      for (final e in said.entries) {
        if (e.key is String && e.value is int) _said[e.key as String] = (e.value as int) > now ? now : e.value as int;
      }
    }
  }

  /// Keeps what is known, of friends as they are now only, and nothing of an identity this device had before.
  void _save() {
    if (_gone) return;
    _dirty = false;
    final mine = me();
    // Another identity now: what was kept of the one before goes (S9), but which keys this device held its names under.
    if (_keptFor != null && mine != null && mine != _keptFor) {
      _relays.clear();
      _toldMe.clear();
      _said.clear();
    }
    _keptFor = mine ?? _keptFor;
    // Only of friends now: nothing is kept of anyone else, but a name confirmed for someone asked to be one, a while.
    final ids = {for (final f in _friends()) f.id};
    final at = nowMs;
    for (final r in _relays.values) {
      r.confirmed.removeWhere((id, t) => !ids.contains(id) && at - t >= confirmedFor.inMilliseconds);
      bool keep(String id) => ids.contains(id) || r.confirmed.containsKey(id);
      for (final m in [r.checked, r.seen, r.told]) {
        m.removeWhere((id, _) => !keep(id));
      }
      r.changes.removeWhere((id, _) => !ids.contains(id));
      r.renamed.removeWhere((id, _) => !keep(id));
    }
    // The relays used most lately.
    final inUse = _relayNow;
    while (_relays.length > mostRelays) {
      final quiet = _relays.entries.where((e) => e.key != inUse).toList()..sort((a, b) => a.value.latest.compareTo(b.value.latest));
      if (quiet.isEmpty) break;
      _relays.remove(quiet.first.key);
    }
    final now = nowMs;
    _toldMe.removeWhere((t) => now - t.at >= toldFor.inMilliseconds);
    try {
      write(keptName, jsonEncode({
        'me': _keptFor,
        'r': {for (final e in _relays.entries) e.key: e.value.toJson()},
        'm': [for (final t in _toldMe) t.toJson()],
        's': _said,
        'h': [for (final h in _heldUnder) [h.username, h.id, h.relay, h.at]],
      }));
    } catch (_) {}
  }

  /// Signing out: nothing it found is kept.
  void wipe() {
    _gone = true;
    stop();
    _relays.clear();
    _heard.clear();
    _toldMe.clear();
    _said.clear();
    _heldUnder.clear();
    _renames.clear();
    notice.value = null;
    try {
      write(keptName, '');
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _gone = true;
    notice.dispose();
    super.dispose();
  }
}
