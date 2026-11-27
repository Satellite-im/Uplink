import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';

/// One person's signed word that a friend's account is who they say (GMFB-33: "friends can mark you as verified, shown
/// as 'verified by 3 friends'"), or that they no longer say so ([on] false: taken back). The newest of one person's
/// words about one account stands ([t]); an older one, sent again by anyone, changes nothing.
///
/// Signed by the voucher's account key (P-256, as everything the account signs) over [signedBytes]:
/// `ghost-vouch v1`, a newline, then the voucher's name, the account's name, the account's key (base64), `yes` or `no`,
/// and the time in milliseconds, each on a line of its own. The account's key is in it, so a vouch for one key says
/// nothing of another key that later takes the same username.
///
/// A vouch is good for a year ([lasts]) from the time it was signed (Matt, 2026-11-23: "vouches expire after a year").
/// The time is in what is signed and the year is fixed here, so nobody can make one last longer; Vouch for again
/// renews it. An expired one is counted by nobody, carried to nobody, and dropped from what is kept. A taken-back word
/// is kept as long as the vouch it took back could have lasted, and dropped after.
@immutable
class Vouch {
  const Vouch({required this.by, required this.forId, required this.on, required this.t, required this.sig});

  /// Who said it (their account name) and of whom.
  final String by;
  final String forId;

  /// Said, or taken back.
  final bool on;

  /// When, in milliseconds since 1970, by the voucher's clock (always later than their word before it: [Vouches.make]).
  final int t;
  final Uint8List sig;

  static const words = 'ghost-vouch v1\n';

  /// How long a vouch is good for, from [t].
  static const lasts = Duration(days: 365);

  /// How far ahead of this device's clock a time may be and still be believed (another device's clock running fast).
  static const ahead = Duration(days: 1);

  /// When it stops being good, in milliseconds since 1970.
  int get until => t + lasts.inMilliseconds;

  /// Whether it has run out by [now].
  bool expiredAt(int now) => now >= until;

  /// Whether it is good at [now]: not run out, and not signed further ahead than a clock can be wrong by.
  bool goodAt(int now) => !expiredAt(now) && t <= now + ahead.inMilliseconds;

  static Uint8List signedBytes({required String by, required String forId, required String forKey, required bool on, required int t}) => Uint8List.fromList(utf8.encode('$words$by\n$forId\n$forKey\n${on ? 'yes' : 'no'}\n$t'));

  /// Whether this is the holder of [byKey]'s word about the holder of [forKey] (both base64, as friends' keys are kept):
  /// each key makes its name, and the signature is [byKey]'s.
  bool checks({required String byKey, required String forKey}) {
    try {
      final bk = base64Decode(byKey), fk = base64Decode(forKey);
      if (NetCrypto.idOf(bk) != by || NetCrypto.idOf(fk) != forId) return false;
      return NetCrypto.verifyOnce(bk, signedBytes(by: by, forId: forId, forKey: forKey, on: on, t: t), sig);
    } catch (_) {
      return false;
    }
  }

  static final _name = RegExp(r'^[0-9a-f]{32}$');

  /// As it is sent to the account vouched for (`vouch` envelopes) and kept: everything.
  Map<String, Object> toJson() => {'b': by, 'f': forId, 't': t, 's': base64Encode(sig), if (!on) 'x': 1};

  /// As a profile carries it to friends: without the account's name, which is the profile's own.
  Map<String, Object> carried() => {'b': by, 't': t, 's': base64Encode(sig), if (!on) 'x': 1};

  /// One read back from [j]; [forId] where the form carried leaves it out. Null where it isn't the shape of one (its
  /// signature is checked where it is counted: [checks]).
  static Vouch? fromJson(Object? j, {String? forId}) {
    if (j is! Map) return null;
    final b = j['b'], f = forId ?? j['f'], t = j['t'], s = j['s'];
    if (b is! String || f is! String || t is! int || s is! String || !_name.hasMatch(b) || !_name.hasMatch(f) || s.length > 100 || t <= 0) return null;
    try {
      final sig = base64Decode(s);
      if (sig.length != 64) return null;
      return Vouch(by: b, forId: f, on: j['x'] != 1, t: t, sig: sig);
    } catch (_) {
      return null;
    }
  }
}

/// The vouches this account gave, those it was given, and those its friends carry with their profiles
/// (lib/friends/buddies.dart sends and hears them; docs/friends.md says how they travel).
///
/// - **Given** ([given]): this account's newest word about each friend, so a profile can say "You vouch for them" and
///   a vouch taken back is always newer than the one it takes back.
/// - **Held** ([held]): friends' words about this account, sent by them, each checked against the key held for that
///   friend and for this account before it is kept. The newest of each friend's stands, taken-back ones too, so an old
///   vouch sent again never undoes its withdrawal. At most [most] said and [most] taken back are kept.
/// - **Carried** ([carried]): what each friend's profile said they hold, newest per voucher, kept as it came; counted
///   ([vouchersOf]) only for vouchers who are this account's own friends, checked against the key this account holds
///   for them. A friend's profile is read for at most `2 × most` of them.
/// - **Hidden** ([hidden]): the person chose not to carry the vouches they hold to their friends.
///
/// Nothing here is ever given to the relay or to anyone who isn't a friend; there is no count of anyone's anywhere but
/// on the screens of their friends, each counting only their own friends.
class Vouches extends ChangeNotifier {
  Vouches({required String Function(String key) read, required void Function(String key, String value) write, int Function()? now})
      : _read = read,
        _write = write,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Kept in memory only: for a port with nowhere to keep things (a test).
  factory Vouches.inMemory({int Function()? now}) {
    final m = <String, String>{};
    return Vouches(read: (k) => m[k] ?? '', write: (k, v) => m[k] = v, now: now);
  }

  final String Function(String key) _read;
  final void Function(String key, String value) _write;
  final int Function() _now;

  /// The most said vouches kept or carried, and as many taken back.
  static const most = 64;

  final Map<String, Vouch> given = {};
  final Map<String, Vouch> held = {};
  final Map<String, Map<String, Vouch>> carried = {};
  bool hidden = false;
  String? _for;

  /// This account's own key (base64), to check its own words as a friend's profile carries them back.
  String? _myKey;

  /// For a withdrawal held ([held], by voucher): until when it is carried to friends, which is when the vouch it took
  /// back would have run out. One that took back nothing this account carried is never carried: no friend could be
  /// counting what it takes back.
  final Map<String, int> _carryUntil = {};

  /// Friends this account stopped being friends with whose vouch it held, and when: carried to friends (`vd`) for a
  /// year, so they stop counting that vouch even though they merge what each device of this account says.
  final Map<String, int> dropped = {};

  /// Which friends were carried each held vouch (by voucher), and so which are told of its dropping ([droppedFor]):
  /// nobody else learns that someone once vouched for this account (found in review, 2026-11-23).
  final Map<String, Set<String>> sentTo = {};
  final Map<String, Set<String>> droppedTo = {};

  /// The SHA-256 (hex) of what friends were last told this account holds, kept so a carrying the app was closed before
  /// making is made at its next start (lib/friends/buddies.dart).
  String? lastCarried;

  /// What friends' profiles said they dropped (by friend, then voucher: when): a vouch by that voucher older than
  /// that is no longer counted for them.
  final Map<String, Map<String, int>> floors = {};

  static String _key(String me) => 'vouches:$me';

  /// Reads what is kept for the account [me] (another account on this device keeps its own).
  void load(String me, {String? key}) {
    if (key != null) _myKey = key;
    if (_for == me) return;
    _for = me;
    given.clear();
    held.clear();
    carried.clear();
    _carryUntil.clear();
    dropped.clear();
    floors.clear();
    sentTo.clear();
    droppedTo.clear();
    lastCarried = null;
    hidden = false;
    try {
      final j = jsonDecode(_read(_key(me)));
      if (j is Map) {
        for (final v in (j['given'] as List? ?? const [])) {
          final x = Vouch.fromJson(v);
          if (x != null) given[x.forId] = x;
        }
        for (final v in (j['held'] as List? ?? const [])) {
          final x = Vouch.fromJson(v, forId: me);
          if (x != null) held[x.by] = x;
        }
        final c = j['carried'];
        if (c is Map) {
          for (final e in c.entries) {
            if (e.key is! String || e.value is! List) continue;
            final m = <String, Vouch>{};
            for (final v in e.value as List) {
              final x = Vouch.fromJson(v, forId: e.key as String);
              if (x != null) m[x.by] = x;
            }
            carried[e.key as String] = m;
          }
        }
        hidden = j['hide'] == true;
        final dr = j['dr'];
        if (dr is Map) {
          for (final e in dr.entries) {
            if (e.key is String && e.value is int) dropped[e.key as String] = e.value as int;
          }
        }
        for (final (into, from) in [(sentTo, j['st']), (droppedTo, j['dt'])]) {
          if (from is! Map) continue;
          for (final e in from.entries) {
            if (e.key is String && e.value is List) into[e.key as String] = {...(e.value as List).whereType<String>()};
          }
        }
        if (j['lc'] is String) lastCarried = j['lc'] as String;
        final fl = j['fl'];
        if (fl is Map) {
          for (final e in fl.entries) {
            if (e.key is! String || e.value is! Map) continue;
            floors[e.key as String] = {for (final x in (e.value as Map).entries) if (x.key is String && x.value is int) x.key as String: x.value as int};
          }
        }
        final cu = j['cu'];
        if (cu is Map) {
          for (final e in cu.entries) {
            if (e.key is String && e.value is int && held[e.key]?.on == false) _carryUntil[e.key as String] = e.value as int;
          }
        }
      }
    } catch (_) {}
    if (_prune()) _save();
    notifyListeners();
  }

  /// Drops every word that has run out; true where any was dropped.
  bool _prune() {
    final now = _now();
    var dropped = false;
    void from(Map<String, Vouch> m) {
      final before = m.length;
      m.removeWhere((_, v) => v.expiredAt(now));
      if (m.length != before) dropped = true;
    }

    from(given);
    from(held);
    for (final m in carried.values) {
      from(m);
    }
    carried.removeWhere((_, m) => m.isEmpty);
    _carryUntil.removeWhere((by, until) => until <= now || held[by]?.on != false);
    final year = Vouch.lasts.inMilliseconds;
    final before = this.dropped.length + floors.length;
    this.dropped.removeWhere((_, at) => at + year <= now);
    droppedTo.removeWhere((by, _) => !this.dropped.containsKey(by));
    sentTo.removeWhere((by, _) => held[by]?.on != true);
    for (final f in floors.values) {
      f.removeWhere((_, at) => at + year <= now);
    }
    floors.removeWhere((_, f) => f.isEmpty);
    if (this.dropped.length + floors.length != before) dropped = true;
    return dropped;
  }

  void _save() {
    _prune();
    final me = _for;
    if (me != null) {
      _write(_key(me), jsonEncode({
        'given': [for (final v in given.values) v.toJson()],
        'held': [for (final v in held.values) v.carried()],
        'carried': {for (final e in carried.entries) e.key: [for (final v in e.value.values) v.carried()]},
        if (hidden) 'hide': true,
        if (_carryUntil.isNotEmpty) 'cu': _carryUntil,
        if (dropped.isNotEmpty) 'dr': dropped,
        if (sentTo.isNotEmpty) 'st': {for (final e in sentTo.entries) e.key: [...e.value]},
        if (droppedTo.isNotEmpty) 'dt': {for (final e in droppedTo.entries) e.key: [...e.value]},
        'lc': ?lastCarried,
        if (floors.isNotEmpty) 'fl': floors,
      }));
    }
    notifyListeners();
  }

  /// Keeps [v] in [into] (by voucher) where it is newer than the one there; true where it was.
  static bool _newer(Map<String, Vouch> into, Vouch v) {
    final had = into[v.by];
    if (had != null && had.t >= v.t) return false;
    into[v.by] = v;
    return true;
  }

  /// [all] cut to [most] said and [most] taken back, the newest of each.
  static void _cap(Map<String, Vouch> all) {
    for (final on in [true, false]) {
      final some = all.values.where((v) => v.on == on).toList()..sort((a, b) => b.t.compareTo(a.t));
      for (final v in some.skip(most)) {
        all.remove(v.by);
      }
    }
  }

  /// This account's word about [forId] (key [forKey]): [on] or taken back, signed with [sign], kept, and returned to be
  /// sent. Always later than the word it replaces, whatever the clock says.
  Future<Vouch> make({required String me, required String forId, required String forKey, required bool on, required Future<Uint8List> Function(List<int> message) sign}) async {
    load(me);
    // Later than this account's newest word about them, whichever device said it: another device's comes back in their
    // profile (found in review, 2026-11-23: a withdrawal made on a device whose clock was behind lost to the vouch).
    final back = _ownCarried(forId, forKey);
    final before = [given[forId]?.t ?? 0, back?.t ?? 0].reduce((a, b) => a > b ? a : b);
    final t = _now() > before ? _now() : before + 1;
    final sig = await sign(Vouch.signedBytes(by: me, forId: forId, forKey: forKey, on: on, t: t));
    final v = Vouch(by: me, forId: forId, on: on, t: t, sig: sig);
    given[forId] = v;
    _save();
    return v;
  }

  /// A friend ([from], whose key this account holds as [fromKey]) sent their word about this account ([me], key
  /// [meKey]): kept where it is theirs, about this key, and newer than their word before. True where it changed what is
  /// held.
  bool heard(Object? body, {required String from, required String fromKey, required String me, required String meKey}) {
    load(me);
    if (_prune()) _save();
    final v = Vouch.fromJson(body);
    if (v == null || v.by != from || v.forId != me || !v.goodAt(_now()) || !v.checks(byKey: fromKey, forKey: meKey)) return false;
    final had = held[v.by];
    if (v.t < (dropped[v.by] ?? 0)) return false;
    if (!_newer(held, v)) return false;
    dropped.remove(v.by);
    if (v.on) {
      _carryUntil.remove(v.by);
    } else if (had != null && had.on && had.goodAt(_now())) {
      _carryUntil[v.by] = had.until;
    }
    _cap(held);
    _save();
    return true;
  }

  /// What a friend's profile said they hold ([list], the carried form), merged with what was held before, newest per
  /// voucher, so two devices of theirs saying a little apart don't make the count flip (found in review, 2026-11-23).
  /// Where they hid their vouches ([hidden]) the said ones go. A voucher [keyOf] names a key for (a friend of this
  /// account's, or this account itself) is checked as it comes, once, on the newest the list has of them, so a long
  /// list costs no more checks than it has vouchers; the rest are kept unchecked (counted only if that voucher becomes a
  /// friend and then checks), and an unchecked withdrawal isn't kept at all.
  void tookCarried(String friend, Object? list, {bool hidden = false, Object? dropped, String? Function(String id)? keyOf, String? friendKey}) {
    if (list is! List || _for == null) return;
    if (_prune()) _save();
    final now = _now();
    var floorsChanged = false;
    if (dropped is Map) {
      final f = floors.putIfAbsent(friend, () => {});
      for (final e in dropped.entries.take(2 * most)) {
        final at = e.value;
        if (e.key is! String || at is! int || at > now + Vouch.ahead.inMilliseconds || at + Vouch.lasts.inMilliseconds <= now) continue;
        if (at > (f[e.key] ?? 0)) {
          f[e.key as String] = at;
          floorsChanged = true;
        }
      }
      if (f.isEmpty) floors.remove(friend);
    }
    final floor = floors[friend] ?? const <String, int>{};
    final newest = <String, Vouch>{};
    for (final j in list.take(2 * most)) {
      final v = Vouch.fromJson(j, forId: friend);
      if (v == null || v.by == friend || !v.goodAt(now) || v.t < (floor[v.by] ?? 0)) continue;
      _newer(newest, v);
    }
    final had = carried[friend] ?? const <String, Vouch>{};
    final into = {...had};
    for (final v in newest.values) {
      final before = into[v.by];
      if (before != null && before.t >= v.t) continue;
      final k = keyOf?.call(v.by);
      final checked = k != null && friendKey != null && v.checks(byKey: k, forKey: friendKey);
      if (k != null && !checked) continue;
      if (!v.on && !checked) {
        // A withdrawal newer than what is held of them, which can't be checked yet: what it takes back goes, so a vouch
        // taken back is never counted once its voucher becomes a friend (found in review, 2026-11-23).
        if (before != null) into.remove(v.by);
        continue;
      }
      into[v.by] = v;
    }
    if (hidden) into.removeWhere((_, v) => v.on);
    into.removeWhere((by, v) => v.on && v.t < (floor[by] ?? 0));
    _cap(into);
    String said(Map<String, Vouch> m) => jsonEncode([for (final v in m.values) v.carried()]);
    if (said(into) == said(had)) {
      if (floorsChanged) _save();
      return;
    }
    carried[friend] = into;
    _save();
  }

  /// [friend] was just told what this account holds: they now have each vouch carried, and are told if it is dropped.
  void carriedTo(String friend) {
    final now = _now();
    for (final v in held.values) {
      if (v.on && v.goodAt(now)) sentTo.putIfAbsent(v.by, () => {}).add(friend);
    }
  }

  /// The vouchers this account dropped whom [friend] was carried a vouch from, and when: what `vd` tells them.
  Map<String, int> droppedFor(String friend) => {
        for (final e in dropped.entries)
          if (droppedTo[e.key]?.contains(friend) ?? false) e.key: e.value,
      };

  /// Keeps [hash] as what friends were last told.
  void markCarried(String hash) {
    lastCarried = hash;
    _save();
  }

  /// This account's own newest word about [forId] as their profile carried it back, where it is this account's by its
  /// key; null otherwise.
  Vouch? _ownCarried(String forId, String forKey) {
    final me = _for, key = _myKey;
    final v = me == null ? null : carried[forId]?[me];
    if (v == null || key == null || !v.checks(byKey: key, forKey: forKey)) return null;
    return v;
  }

  /// What this account's profile carries to its friends: the newest said and taken back of those it holds, or nothing
  /// where the person hid them.
  List<Map<String, Object>> carry() {
    if (hidden) return const [];
    final now = _now();
    final all = held.values.where((v) => v.goodAt(now) && (v.on || (_carryUntil[v.by] ?? 0) > now)).toList()..sort((a, b) => b.t.compareTo(a.t));
    return [for (final v in all) v.carried()];
  }

  void setHidden(bool hide) {
    if (hidden == hide) return;
    hidden = hide;
    _save();
  }

  /// [id] is no longer a friend (removed, blocked, or they ended it): their vouch for this account goes, this account's
  /// for them, and what their profile carried.
  void forget(String id) {
    _carryUntil.remove(id);
    if (held[id]?.on ?? false) {
      dropped[id] = _now();
      droppedTo[id] = sentTo[id] ?? {};
    }
    sentTo.remove(id);
    final a = held.remove(id), b = given.remove(id), c = carried.remove(id);
    floors.remove(id);
    if (a != null || b != null || c != null) _save();
  }

  /// Of [friends] (id and key, base64, each one of this account's own friends), those whose newest word about the
  /// account [forId] (key [forKey]) is said and checks out against the key held for them. For this account itself
  /// ([forId] its own) what is held; for anyone else what their profile carried.
  List<T> vouchersOf<T>(String forId, String forKey, Iterable<T> friends, {required String Function(T) id, required String Function(T) key}) {
    final words = forId == _for ? held : (carried[forId] ?? const <String, Vouch>{});
    if (words.isEmpty) return const [];
    final now = _now();
    return [
      for (final f in friends)
        if (words[id(f)] case final v? when id(f) != forId && v.on && v.goodAt(now) && v.t >= (floors[forId]?[id(f)] ?? 0) && v.checks(byKey: key(f), forKey: forKey)) f,
    ];
  }

  /// The most of this account's own words one telling of its other devices carries ([own]) or takes ([tookOwn]).
  static const ownMost = 2 * most;

  /// This account's own words about its friends, said and taken back, the newest first: what its other devices are
  /// told (GMFB-33: a vouch made on the phone was not known to the Mac, which then offered Vouch for again and never
  /// Take back). Each is signed, so a device takes one only where it checks.
  List<Map<String, Object>> own() {
    final now = _now();
    final all = given.values.where((v) => v.goodAt(now)).toList()..sort((a, b) => b.t.compareTo(a.t));
    return [for (final v in all.take(ownMost)) v.toJson()];
  }

  /// What another device of this account ([me], key [myKey]) said it has given ([list], as [own] makes it): each word
  /// kept where it is this account's by its signature, about a friend [keyOf] names a key for, good now, and newer
  /// than the word held here about them. A taking back is a word too, so it travels the same way. True where anything
  /// changed.
  bool tookOwn(Object? list, {required String me, required String myKey, required String? Function(String id) keyOf}) {
    if (list is! List) return false;
    load(me);
    final now = _now();
    var changed = false;
    for (final j in list.take(ownMost)) {
      final v = Vouch.fromJson(j);
      if (v == null || v.by != me || v.forId == me || !v.goodAt(now)) continue;
      final had = given[v.forId];
      if (had != null && had.t >= v.t) continue;
      final key = keyOf(v.forId);
      if (key == null || !v.checks(byKey: myKey, forKey: key)) continue;
      given[v.forId] = v;
      changed = true;
    }
    if (changed) _save();
    return changed;
  }

  /// This account's newest word about [forId] (key [forKey]), from this device or as their profile carried back
  /// another device's ([myKey] checks it is this account's), where it is a vouch good now; null otherwise.
  Vouch? givenFor(String forId, {String? forKey, String? myKey}) {
    if (myKey != null) _myKey = myKey;
    var v = given[forId];
    final back = forKey == null ? null : _ownCarried(forId, forKey);
    if (back != null && (v == null || back.t > v.t)) v = back;
    return v != null && v.on && v.goodAt(_now()) ? v : null;
  }
}
