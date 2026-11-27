/// The relay's directory lookups (Me.whois) this account makes of its own accord, the name watch's
/// (lib/net/name_watch.dart) and the friend requests' checks (lib/friends/buddies.dart), held to one budget (the second
/// review, 2026-11-23). The relay answers an account 120 lookups an hour, counted for all its devices together: they
/// sign in as one identity (relay/lib/handles.dart). What the app looks up of its own accord takes no more than
/// [mostAnHour] of them for the whole account, shared out among the account's devices it knows of ([share]), and the rest
/// are left to the person: their adds and Accepts, which always ask, and the add-friend drawer's lookups as a name is
/// typed. The requests' checks leave a third of a device's share to the name watch, so strangers' requests can't stop
/// it; and once the relay says too many, nothing is looked up of the app's own accord for [refusedFor].
class LookupBudget {
  LookupBudget({this.share, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The app's own, shared by its name watch and its friend requests' checks (lib/people.dart says its [share]).
  static final instance = LookupBudget();

  /// The lookups an hour the app makes of its own accord for the whole account, a quarter of what the relay answers.
  static const mostAnHour = 30;

  /// How long nothing is looked up of the app's own accord after the relay says too many: by then it answers again.
  static const refusedFor = Duration(hours: 1);
  static const _hour = 3600000;

  /// This device's place among the account's devices it knows of (the name watch's own: `index` of `of`).
  ({int index, int of}) Function()? share;
  final DateTime Function() _now;

  /// When each lookup of the last hour was made, and when the relay last said too many (ms; 0 where it has not).
  final List<int> _made = [];
  int _refusedAt = 0;

  int get _ms => _now().millisecondsSinceEpoch;

  /// How many devices of the account the budget is shared among; one where [share] does not say.
  int get _devices {
    try {
      final s = share?.call();
      return s == null || s.of < 1 ? 1 : s.of;
    } catch (_) {
      return 1;
    }
  }

  /// The lookups an hour this device makes of its own accord: its share of [mostAnHour], two at least.
  int get perDevice {
    final n = mostAnHour ~/ _devices;
    return n < 2 ? 2 : n;
  }

  /// How many of them the friend requests' checks may take: all but a third, which is the name watch's, and the watch
  /// always keeps one, even at the floor of two (review, 2026-11-23).
  int get forRequests => perDevice - (perDevice ~/ 3 < 1 ? 1 : perDevice ~/ 3);

  /// Drops the lookups of over an hour ago, and holds nothing to a time later than [now] (a clock set back).
  void _tidy(int now) {
    _made.removeWhere((t) => now - t >= _hour || t > now);
    if (_refusedAt > now) _refusedAt = now;
  }

  /// When the next lookup of the app's own accord may be made, for the name watch ([watch]) or a request's check (ms):
  /// within this device's share of the hour, and not while the relay has said too many.
  int nextFree({bool watch = false}) {
    final now = _ms;
    _tidy(now);
    final most = watch ? perDevice : forRequests;
    var at = now;
    if (_made.length >= most) at = _made[_made.length - most] + _hour;
    final shut = refusedUntil;
    if (shut != null && shut > at) at = shut;
    return at;
  }

  /// Whether one may be made now ([nextFree]).
  bool may({bool watch = false}) => nextFree(watch: watch) <= _ms;

  /// One was made now.
  void took() => _made.add(_ms);

  /// One is made now where it may be ([may]), and counted: whether it may.
  bool take({bool watch = false}) {
    if (!may(watch: watch)) return false;
    took();
    return true;
  }

  /// The relay said too many: nothing of the app's own accord for [refusedFor].
  void refused() => _refusedAt = _ms;

  /// Until when nothing is looked up of the app's own accord, the relay having said too many (ms); null where it hasn't
  /// lately.
  int? get refusedUntil {
    final now = _ms;
    _tidy(now);
    final until = _refusedAt + refusedFor.inMilliseconds;
    return _refusedAt > 0 && until > now ? until : null;
  }

  /// By when, at the latest, the relay answers a lookup again after saying too many (ms): an hour after the first lookup
  /// it was still counting that this device made, where it knows of one, else an hour after it said so. The relay
  /// counts an hour back, so one of the lookups it counted is an hour old by then. Null where it hasn't said so lately.
  int? get freesBy {
    final until = refusedUntil;
    if (until == null) return null;
    final counted = _made.where((t) => t > _refusedAt - _hour && t <= _refusedAt);
    final first = counted.isEmpty ? null : counted.reduce((a, b) => a < b ? a : b);
    return first == null || first + _hour > until ? until : first + _hour;
  }

  /// Whether [e] is the relay saying too many lookups (relay/lib/handles.dart: "Too many lookups. Try again in a
  /// while.").
  static bool isRefusal(Object e) => '$e'.contains('Too many lookups');

  /// Signing out: nothing is kept of the account's lookups.
  void clear() {
    _made.clear();
    _refusedAt = 0;
  }
}
