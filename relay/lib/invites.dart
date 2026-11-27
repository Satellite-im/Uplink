import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'sha256.dart';

/// Invites waiting for someone who is not on Uplink yet (Matt, 2026-11-17: "when adding people to the space we
/// should have a suggested list of our contacts to add if they're not on ghost yet it should send them a text saying
/// they've been invited to join a space in ghost with a link that eventually follows through after they setup their
/// account").
///
/// The text itself goes from the inviter's own phone, with the space's or circle's link in it. This keeps a copy of
/// that invite for the day the person sets the app up, so it is waiting for them even if the text is lost or the link
/// is never tapped:
///
/// - **Kept by a hash of the invitee's number**, the same hash a verified number is linked by (handles.dart's
///   `keyOf('phone', number)`), never the number. That hash has to be the verification's, so the right install can be
///   handed its invites; it also means this server, or anyone who reads the file, can tell which numbers have invites
///   waiting, by hashing every number there is (there are only about ten billion).
/// - **Sealed by the inviter's app** with a key made from the number by a slow, salted derivation, one salt for each
///   invite (lib/invites/invite_seal.dart in the app). Guessing the number from the hash is quick; opening every blob
///   in the file costs a slow derivation for each guess at each blob, which puts reading the whole file out of reach.
/// - **Taken only by the install that verified that number** by a texted code (handles.dart): [phoneKeyOf] says which
///   number each install has verified. Nobody else can list or drop them, so a number cannot be tried to see what is
///   waiting for it.
/// - **Left only by someone**: an install that verified a number or linked an account ([whoOf]), counted by that and
///   not by its key, since a new key costs nothing.
/// - **Limited**: [maxBlob] for each, [maxForNumber] for one number (more are refused, never put in place of what
///   waits) and [maxFromOne] of them from any one someone, [maxAll] and [maxBytes] in all; one someone may leave
///   [anHour] an hour and [aDay] a day; and each is gone after [life].
///
/// What it says: `{"dir": "invite", "list": [{"h", "b", "t"?}]}` leaves invites (answered `{"dir": "invite", "left": n}`),
/// `{"dir": "invites", "h"}` lists those for the number this install verified (`{"dir": "invites", "h", "list": [{"i",
/// "b", "at"}]}`), and `{"dir": "invites-drop", "h", "ids"}` drops those taken (`{"dir": "invites-drop", "left": n}`).
/// A refusal is `{"dir": "err", "about", "err"}`, as handles.dart's are. An app from before this (0.9.2) never says
/// any of it, and nothing it does say is answered differently.
class Invites {
  Invites({this.dataDir, this.phoneKeyOf, this.whoOf, DateTime Function()? now, Random? random, this.verbose = false})
      : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  /// Where `invites.json` is kept; null keeps nothing across restarts.
  final Directory? dataDir;

  /// The hash of the number [id] verified by a texted code, or null where it has verified none (handles.dart).
  final String? Function(String id)? phoneKeyOf;

  /// Who [id] is beyond its key (handles.dart's `whoOf`: a verified number or a linked account), or null where it is
  /// nobody yet; only someone may leave invites, and what they leave is counted by this.
  final String? Function(String id)? whoOf;
  final bool verbose;
  final DateTime Function() _now;
  final Random _random;

  /// What this answers: everything else that starts `{"dir": …}` is handles.dart's.
  static const dirs = {'invite', 'invites', 'invites-drop'};

  /// How long an invite waits.
  static const life = Duration(days: 30);

  /// A sealed invite, as base64: a link, a name, who sent it and their signature fit in well under this.
  static const maxBlob = 2048;

  /// How many wait for one number, and how many of those from any one someone. A full number refuses more rather
  /// than dropping what waits, so nobody can push a real invite out with junk; a second cap on each sender means one
  /// sender cannot fill the number either.
  static const maxForNumber = 20;
  static const maxFromOne = 3;

  /// How many can be left at once, and in all, and how many bytes in all: what the box holds in memory and writes out
  /// every ten minutes without stalling the hub.
  static const maxAtOnce = 25;
  static const maxAll = 20000;
  static const maxBytes = 24 << 20;

  /// How many one someone may leave in an hour and in a day: each is a text the inviter sent, and nobody invites a
  /// hundred people a day by hand.
  static const anHour = 40;
  static const aDay = 120;

  // A number's hash or an invite's tag (SHA-256 in hex), and a sealed invite's characters (base64, either alphabet).
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static final _base64 = RegExp(r'^[A-Za-z0-9+/=_-]+$');

  /// number hash -> its invites, oldest first: {i: id, b: sealed, t: tag, w: sender, at: ms}. `w` is a hash of who
  /// left it together with the number, so it says nothing across numbers and never who the sender is.
  final Map<String, List<Map<String, Object>>> _waiting = {};

  /// When each someone left invites, in memory only: what [anHour] and [aDay] count.
  final Map<String, List<DateTime>> _leftBy = {};

  int _bytes = 0;

  /// How many invites wait, for every number together.
  int get waiting => _waiting.values.fold(0, (n, l) => n + l.length);

  /// The bytes of sealed invites held.
  int get bytes => _bytes;

  void _say(String what) {
    // Never a hash, never an id whole.
    if (verbose) stdout.writeln('${_now().toIso8601String()} invites $what');
  }

  /// What an invite keeps of who left it (`w`): a hash of the sender with the number [h], for [maxFromOne] to count by.
  static String _sender(String who, String h) => hexOf(sha256(utf8.encode('ghost-invite-from v1|$who|$h'))).substring(0, 32);

  // --- what is kept ---------------------------------------------------------------------------------------------------

  File? get _file => dataDir == null ? null : File('${dataDir!.path}/invites.json');

  /// Reads invites.json as the hub starts, keeping only entries of the right shape, and drops those past [life].
  void load() {
    final file = _file;
    try {
      if (file != null && file.existsSync()) {
        final all = jsonDecode(file.readAsStringSync()) as Map;
        (all['waiting'] as Map? ?? const {}).forEach((h, list) {
          if (h is! String || !_hash.hasMatch(h) || list is! List) return;
          _waiting[h] = [
            for (final e in list)
              if (e is Map && e['i'] is String && e['b'] is String && e['at'] is int)
                {'i': e['i'] as String, 'b': e['b'] as String, 'at': e['at'] as int, if (e['t'] is String) 't': e['t'] as String, if (e['w'] is String) 'w': e['w'] as String},
          ];
        });
      }
    } catch (_) {
      // A file that cannot be read is started again from nothing rather than stopping the relay.
    }
    _bytes = _waiting.values.fold(0, (n, l) => l.fold(n, (m, e) => m + (e['b'] as String).length));
    _sweepNow();
  }

  /// Written at once, on this isolate: as the relay stops, when nothing else is waiting on it.
  void save() {
    final file = _file;
    if (file == null) return;
    // Any write still under way is older than this one, and must not land after it.
    _written++;
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'waiting': _waiting}));
      tmp.renameSync(file.path);
    } catch (_) {}
  }

  // The write under way, which the next waits for; and the number of the newest write asked for, by which an older
  // one still under way knows to stop.
  Future<void>? _saving;
  int _written = 0;

  /// Written without holding up the hub: the words are made on another isolate and written asynchronously, so a
  /// full store never stalls everyone's websockets (0.9.2's calls among them) while it is written out.
  Future<void> _saveSoon() {
    final file = _file;
    if (file == null) return Future.value();
    final before = _saving;
    final copy = {for (final e in _waiting.entries) e.key: [for (final i in e.value) Map<String, Object>.of(i)]};
    final mine = ++_written;
    return _saving = () async {
      if (before != null) await before;
      try {
        final words = await Isolate.run(() => jsonEncode({'waiting': copy}));
        if (mine != _written) return;
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.async.tmp');
        await tmp.writeAsString(words, flush: true);
        if (mine != _written) return;
        await tmp.rename(file.path);
      } catch (_) {}
    }();
  }

  bool _dirty = false;

  /// Saved by the hub's sweep (every ten minutes) and as it stops; an invite left meanwhile is lost to a crash, and
  /// the text the inviter sent still has the link.
  void _changed() => _dirty = true;

  /// Forgets invites past [life], and the counts past a day; saves where anything changed, and is done once saved.
  Future<void> sweep() => _sweepNow() ? _saveSoon() : (_saving ?? Future.value());

  /// The forgetting itself; whether there is anything to save (from this, or from a change since the last save).
  bool _sweepNow() {
    final now = _now();
    final cutoff = now.subtract(life).millisecondsSinceEpoch;
    _waiting.removeWhere((_, list) {
      final before = list.length;
      list.removeWhere((e) {
        final old = (e['at'] as int) < cutoff;
        if (old) _bytes -= (e['b'] as String).length;
        return old;
      });
      if (list.length != before) _dirty = true;
      return list.isEmpty;
    });
    _leftBy.removeWhere((_, list) {
      list.removeWhere((t) => now.difference(t) > const Duration(days: 1));
      return list.isEmpty;
    });
    if (!_dirty) return false;
    _dirty = false;
    return true;
  }

  // --- what an install says -----------------------------------------------------------------------------------------

  /// Something [id] said that starts `{"dir": …}` with one of [dirs]; [tell] answers it.
  void said(String id, Map said, void Function(Map<String, Object?>) tell) {
    final dir = said['dir'];
    void err(String why) => tell({'dir': 'err', 'about': dir, 'err': why});
    switch (dir) {
      case 'invite':
        // Leaves sealed invites for numbers, each by the number's hash.
        final list = said['list'];
        if (list is! List || list.isEmpty || list.length > maxAtOnce) return err('Send between one and $maxAtOnce invites at a time.');
        // Someone, not a key: a key made a moment ago would otherwise start every count again.
        final who = whoOf?.call(id);
        if (who == null) return err('Verify your number in Settings first.');
        final now = _now();
        final mine = _leftBy[who] ??= [];
        mine.removeWhere((t) => now.difference(t) > const Duration(days: 1));
        final lastHour = mine.where((t) => now.difference(t) <= const Duration(hours: 1)).length;
        if (lastHour + list.length > anHour || mine.length + list.length > aDay) return err('You have sent a lot of invites already. Try again later.');
        // All or none: each is looked at before any is kept.
        final good = <({String h, String b, String? t})>[];
        for (final e in list) {
          if (e is! Map) return err('That is not an invite.');
          final h = e['h'], b = e['b'], t = e['t'];
          if (h is! String || !_hash.hasMatch(h)) return err('That is not an invite.');
          if (b is! String || b.isEmpty || b.length > maxBlob || !_base64.hasMatch(b)) return err('That invite is too big.');
          if (t != null && (t is! String || !_hash.hasMatch(t))) return err('That is not an invite.');
          good.add((h: h, b: b, t: t as String?));
        }
        if (waiting + good.length > maxAll || _bytes + good.fold<int>(0, (n, g) => n + g.b.length) > maxBytes) {
          _say('full');
          return err('No more invites can be kept right now. The text you sent still has the link.');
        }
        // Each counts against the sender's hour and day, kept or refused, so a full number cannot be tried over and over.
        mine.addAll([for (final _ in good) now]);
        var kept = 0;
        for (final g in good) {
          final waitingFor = _waiting[g.h] ??= [];
          final from = _sender(who, g.h);
          // The same invite again (the inviter's own tag for this space or circle and this number): the newer stands.
          if (g.t != null) {
            waitingFor.removeWhere((e) {
              final same = e['t'] == g.t;
              if (same) _bytes -= (e['b'] as String).length;
              return same;
            });
          }
          // A full number, or this sender's share of it spent: refused, and what waits stays as it was.
          if (waitingFor.length >= maxForNumber || waitingFor.where((e) => e['w'] == from).length >= maxFromOne) {
            if (waitingFor.isEmpty) _waiting.remove(g.h);
            continue;
          }
          waitingFor.add({'i': hexOf([for (var i = 0; i < 8; i++) _random.nextInt(256)]), 'b': g.b, 'w': from, 'at': now.millisecondsSinceEpoch, if (g.t != null) 't': g.t!});
          _bytes += g.b.length;
          kept++;
        }
        _changed();
        _say('${id.substring(0, min(6, id.length))} left $kept of ${good.length}');
        tell({'dir': 'invite', 'left': kept});
      // 'invites' lists what waits for the number this install verified; 'invites-drop' removes those it has taken.
      case 'invites':
      case 'invites-drop':
        final h = said['h'];
        if (h is! String || !_hash.hasMatch(h)) return err('That is not a number\'s invites.');
        // Only the install that proved the number by a texted code: see the class's words.
        if (phoneKeyOf?.call(id) != h) return err('Verify this number first.');
        if (dir == 'invites') {
          final cutoff = _now().subtract(life).millisecondsSinceEpoch;
          return tell({
            'dir': 'invites',
            'h': h,
            'list': [for (final e in _waiting[h] ?? const <Map<String, Object>>[]) if ((e['at'] as int) >= cutoff) {'i': e['i'], 'b': e['b'], 'at': e['at']}],
          });
        }
        final ids = said['ids'];
        if (ids is! List) return err('Say which invites to drop.');
        final drop = {for (final i in ids) if (i is String) i};
        final list = _waiting[h];
        if (list != null) {
          list.removeWhere((e) {
            final gone = drop.contains(e['i']);
            if (gone) _bytes -= (e['b'] as String).length;
            return gone;
          });
          if (list.isEmpty) _waiting.remove(h);
          _changed();
        }
        tell({'dir': 'invites-drop', 'left': _waiting[h]?.length ?? 0});
    }
  }
}
