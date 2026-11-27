import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'carrier.dart';
import 'home_record.dart';
import 'hub_carrier.dart';
import 'hub_link.dart';
import 'relay_ask.dart';
import 'relay_choice.dart';

/// Someone found by their username on a relay ([Homes.whois]).
class FoundOnRelay {
  const FoundOnRelay({required this.id, required this.key, this.home, this.here = false, this.talks = true});

  /// Their name (NetCrypto.idOf their key) and their public key in base64.
  final String id;
  final String key;

  /// Their home record, checked: it is theirs, by their own signature. Null where the relay asked holds none, and
  /// they then can't be reached from another relay.
  final HomeRecord? home;

  /// The relay asked turned out to be this app's own: they are someone here.
  final bool here;

  /// Whether their relay passes messages to other relays at all, as it says itself (asked directly; true where this
  /// app's own relay asked it over a link, which it could only do were it so).
  final bool talks;
}

/// Why a home record could not be made, given or looked up, in words to show.
class HomeError implements Exception {
  HomeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// This account's home record and what the relay is told of where people live (docs/OPEN_NETWORK.md, section 4;
/// Matt, 2026-11-22: "I'd like the relays to be able to talk to each other").
///
/// - **This account's own record** ([mine]): says it lives on the relay this app uses, as that relay names itself in
///   its hub's hello (the address the app dialled where it names none). Made the first time the relay is reached,
///   anew with the next count whenever that address changes (the app moved to another relay), and again before it
///   runs out (a record is good for thirty days: [refreshAfter]). Its count is never below the seconds since 1970,
///   so a device restored, or a second device, makes one newer than any made before. The record and the count are
///   kept with the app's choices (`net_home`, `net_home_n`), so it is ready at every sign-in.
/// - **The count is this account's own**: a relay's word that a newer one exists is checked against the record itself
///   (asked back with `home?`, and held to this account's key) before it moves anything.
/// - **At every sign-in** the relay is given this account's record first, then the record of each friend who lives on
///   another relay ([give]: only friends, and those this account asked), before anything else can be sent.
/// - **Names on another relay** ([whois]): asked of this app's own relay where it talks to others; of the other relay
///   itself where this one doesn't, or couldn't reach it, under a key made for that one question (relay_ask.dart).
///   Never while a name is being typed: only when the person asks to add them.
///
/// It tells its listeners when [mine] changes, so friends can be told (lib/friends/buddies.dart).
class Homes extends ChangeNotifier {
  Homes({required this.signer, required String Function(String key) read, required void Function(String key, String value) write, DateTime Function()? now, HubDial? dial, this.busyAgain = const Duration(seconds: 3), this.answerWithin = const Duration(seconds: 12), this.refreshAfter = const Duration(days: 10)})
      : _read = read,
        _write = write,
        _now = now ?? DateTime.now,
        _dial = dial {
    mine = HomeRecord.check(_json(read('net_home')), forId: signer.id, now: _now());
  }

  /// The account, with a way to sign its record; and where the record and its count are kept (`net_home`,
  /// `net_home_n`, with the app's choices).
  final NetSigner signer;
  final String Function(String key) _read;
  final void Function(String key, String value) _write;
  final DateTime Function() _now;

  /// How another relay is dialled when it is asked itself; the platform's WebSocket where null.
  final HubDial? _dial;

  /// How long before a record the relay was too busy to check is given again, and how long the app's own relay has to
  /// answer a name asked of another.
  final Duration busyAgain;
  final Duration answerWithin;

  /// How old this account's record may be before a new one is made in its place (a third of the thirty days it is
  /// good for).
  final Duration refreshAfter;

  /// This account's own record; null until one is made.
  HomeRecord? mine;

  /// Why the last record could not be made or given, in words to show; null where nothing went wrong.
  String? problem;

  /// A newer record of this account's own than [mine], seen at a relay and checked, that names another relay: another
  /// device of the account moved it there. Null where there is none.
  HomeRecord? movedElsewhere;

  HubCarrier? _hub;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final Map<String, Map<String, Object?>> _friends = {};
  final Map<String, int> _busy = {};
  final List<Timer> _timers = [];
  Future<void>? _making;
  Completer<Map<String, dynamic>>? _ownAnswer;

  /// Told as a move is made, before the relay being left is left (lib/friends/buddies.dart): the friends on it are
  /// told where this account lives now while they can still be reached through it. Waited for, five seconds at most.
  Future<void> Function()? beforeLeaving;

  /// Where a move is going ([moveTo]), and since when: until this app signs in there (a minute at most), a record is
  /// not made for the relay being left, which would take the move back.
  String? _movingTo;
  DateTime? _movingAt;
  bool _disposed = false;

  /// [text] read as JSON; null where it is empty or is none.
  static Object? _json(String text) {
    try {
      return text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// The highest count this account is known to have used: the next record it makes is newer still.
  int get count {
    final kept = int.tryParse(_read('net_home_n')) ?? 0;
    final own = mine?.n ?? 0;
    return kept > own ? kept : own;
  }

  /// The count the next record is made with: one more than any known, and never below the seconds since 1970, so a
  /// device that knows none (restored, or another of the account's) still makes the newest.
  int get _next => min(HomeRecord.maxCount, max(count + 1, _now().millisecondsSinceEpoch ~/ 1000));

  /// Follows [hub]: gives it the records at each sign-in, and makes this account's own where it has none for it.
  void attach(HubCarrier hub) {
    if (identical(hub, _hub)) return;
    detach();
    _hub = hub;
    hub.onSignIn = _first;
    hub.onKeptHere = _keptHere;
    hub.onNoHome = _noHome;
    _sub = hub.homes.listen(_heard);
    hub.state.addListener(_state);
    _state();
  }

  /// Lets go of the relay's route: nothing more is heard from it or said through it.
  void detach() {
    final hub = _hub;
    if (hub == null) return;
    if (identical(hub.onSignIn, _first)) hub.onSignIn = null;
    if (identical(hub.onKeptHere, _keptHere)) hub.onKeptHere = null;
    if (identical(hub.onNoHome, _noHome)) hub.onNoHome = null;
    hub.state.removeListener(_state);
    _sub?.cancel();
    _sub = null;
    _hub = null;
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }

  /// Whether there is a relay's route and it is up.
  bool get _up => _hub != null && _hub!.state.value == CarrierState.up;

  /// Whether the relay this app uses passes packets to other relays, as it said in its hello.
  bool get relayTalks => _hub?.relay?.fed ?? false;

  /// The address this account's record names: the relay this app uses, as it names itself (its own hub's address, or
  /// for one hosted from an app its name and the public relay it stays linked to), else the address the app dialled.
  String? get here {
    final hub = _hub;
    return hub == null ? null : addressOf(hub.relay, hub.url);
  }

  /// The address a home record names for the relay dialled at [dialled], given what that relay said of itself
  /// ([relay]; null from one from before): its own hub's address where it claims one, its name and the public relay
  /// it stays linked to where it has no address of its own, else the address dialled. Null where none of them is one.
  static String? addressOf(HubRelay? relay, String dialled) {
    final own = relay?.url == null ? null : canonicalHub(relay!.url!);
    if (own != null) return own;
    final via = relay?.via == null ? null : canonicalHub(relay!.via!);
    if (relay != null && via != null) return hostedAddress(relay.id, via);
    return canonicalHub(dialled);
  }

  /// Whether [rec] names the relay this app uses: its address as it names itself, the address the app dialled, or
  /// (for a relay hosted from an app) its name.
  bool livesHere(HomeRecord rec) => namesHere(rec.h);

  /// Whether this app uses Uplink's own relay, which is reached by more than one name and says none of its
  /// own: any of those names is this relay (found in the review, 2026-11-23: a friend whose record named
  /// ghost-sms.com was "on another relay" to one who dialled gogho.st).
  bool get _ownRelayByAlias {
    final hub = _hub;
    return hub != null && hub.relay?.url == null && isOwnRelay(hub.url);
  }

  /// Whether one of [addresses] (a home record's) is the relay this app uses.
  bool namesHere(Iterable<String> addresses) {
    final hub = _hub;
    if (hub == null) return false;
    final mine = here, dialled = canonicalHub(hub.url), id = hub.relay?.id, alias = _ownRelayByAlias;
    return addresses.any((x) => x == mine || canonicalHub(x) == mine || (dialled != null && canonicalHub(x) == dialled) || (id != null && (x == 'ghost-relay://$id' || x.startsWith('ghost-relay://$id?'))) || (alias && canonicalHub(x) != null && isOwnRelay(x)));
  }

  /// Whether the relay at [host] (as written after a username's `@`) is the one this app uses.
  bool isHere(String host) {
    final hub = _hub;
    final url = hubOfHost(host);
    return hub != null && url != null && (url == here || url == canonicalHub(hub.url) || (_ownRelayByAlias && isOwnRelay(url)));
  }

  /// What is said first at each sign-in: this account's record where it names this relay, then each friend's who
  /// lives on another.
  List<Map<String, Object?>> _first() => [
        if (mine != null && livesHere(mine!)) {'dir': 'home', 'rec': mine!.toJson()},
        for (final rec in _friends.values)
          if (_elsewhere(rec)) {'dir': 'home', 'rec': rec},
      ];

  /// Whether the record [json] names a relay other than the one in use.
  bool _elsewhere(Map<String, Object?> json) {
    final h = json['h'];
    return h is List && _hub != null && !namesHere(h.whereType<String>());
  }

  /// The relay's route came up or went: come up, this account's record is seen to.
  void _state() {
    if (_up) unawaited(ensure());
  }

  /// Makes this account's record where there is none that names the relay in use, or the one there is is old enough to
  /// be made again ([refreshAfter]), with the next count, keeps it, gives it to the relay and tells the listeners.
  /// Nothing where the record held is the one for this relay and new enough. One at a time: a move asked for while a
  /// record is being made waits for it.
  Future<void> ensure() => _queue(_ensure);

  /// Runs [job] after the one before it; one that throws does not stop the next.
  Future<void> _queue(Future<void> Function() job) {
    final before = _making ?? Future<void>.value();
    final made = _making = before.then((_) => job()).catchError((Object _) {});
    return made.whenComplete(() {
      if (identical(_making, made)) _making = null;
    });
  }

  Future<void> _ensure() async {
    final address = here;
    if (address == null || _disposed) return;
    final moving = _movingTo;
    if (moving != null) {
      if (address == moving || _now().difference(_movingAt!) > const Duration(minutes: 1)) {
        _movingTo = null;
      } else {
        return;
      }
    }
    final had = mine;
    if (had != null && had.h.length == 1 && had.h.single == address && _now().millisecondsSinceEpoch - had.t < refreshAfter.inMilliseconds) return;
    await _make(address);
  }

  /// Signs a record naming [address] with the next count, keeps it as [mine] and gives it to the relay where that is
  /// up. Null, with [problem] saying why, where it could not be signed.
  Future<HomeRecord?> _make(String address) async {
    final HomeRecord rec;
    try {
      rec = await HomeRecord.make(signer, addresses: [address], count: _next, now: _now());
    } catch (e) {
      // Said, not swallowed: without a record nobody on another relay can reach this account.
      problem = 'Where this account lives could not be signed: $e';
      notifyListeners();
      return null;
    }
    if (_disposed) return null;
    mine = rec;
    problem = null;
    movedElsewhere = null;
    _write('net_home', jsonEncode(rec.toJson()));
    _write('net_home_n', '${rec.n}');
    if (_up) _hub!.sayHandles({'dir': 'home', 'rec': rec.toJson()});
    notifyListeners();
    return rec;
  }

  /// The account is about to move to the relay at [address] (what a record names for it: [addressOf]): a record with
  /// the next count is made for it and given to the relay being left, while it is still connected, and its answer
  /// waited for (a few seconds at most), so that relay knows where the account lives now before it is left. The new
  /// relay is given it as the app signs in there.
  Future<void> moveTo(String address, {Duration answer = const Duration(seconds: 4)}) => _queue(() async {
        final to = address.startsWith('ghost-relay://') ? address : canonicalHub(address);
        if (to == null || (mine != null && mine!.h.length == 1 && mine!.h.single == to)) return;
        _movingTo = to;
        _movingAt = _now();
        final heard = _ownAnswer = Completer<Map<String, dynamic>>();
        final rec = await _make(to);
        if (rec == null || !_up) return;
        try {
          var said = await heard.future.timeout(answer);
          // Too busy to check it just now: given again once, a moment on.
          if (said['ok'] != true && said['err'] == 'busy') {
            final again = _ownAnswer = Completer<Map<String, dynamic>>();
            await Future<void>.delayed(busyAgain);
            if (_up) _hub!.sayHandles({'dir': 'home', 'rec': rec.toJson()});
            said = await again.future.timeout(answer);
          }
        } catch (_) {}
        try {
          await beforeLeaving?.call().timeout(const Duration(seconds: 5));
        } catch (_) {}
      });

  /// A friend's record ([rec], already checked): given to the relay now where they live on another, and again at
  /// every sign-in, so the relay can route to them. Lib/friends/buddies.dart gives only friends' and those this
  /// account asked, never a stranger's who only asked.
  void give(Map<String, Object?> rec) {
    final a = rec['a'];
    if (a is! String) return;
    _friends[a] = rec;
    if (_up && _elsewhere(rec)) _hub!.sayHandles({'dir': 'home', 'rec': rec});
  }

  /// [id] is no longer a friend (or never was one): their record is no longer given.
  void forget(String id) => _friends.remove(id);

  /// When each friend's record, and this account's own, was last given again ([_keptHere], [_noHome]).
  final Map<String, DateTime> _saidAgain = {};
  DateTime? _gaveOwnAgain;

  /// The relay only kept a packet here for [id], who lives on another relay: it no longer holds their record (it
  /// keeps only so many of other relays' people, and forgets them when it starts again). Said again, at most once a
  /// minute for one friend, so what is sent next is passed on; what friends write is sent again until it is answered
  /// (lib/friends/friends.dart), so nothing written is lost by it.
  void _keptHere(String id) {
    final rec = _friends[id];
    if (rec == null || !_up || !relayTalks || !_elsewhere(rec)) return;
    final now = _now(), last = _saidAgain[id];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) return;
    _saidAgain[id] = now;
    _saidAgain.removeWhere((k, _) => !_friends.containsKey(k));
    _hub!.sayHandles({'dir': 'home', 'rec': rec});
  }

  /// The relay holds no record of this account's naming it, so it passed nothing on (`nak` `home`): this account's own
  /// is given again (once a minute at most), and what was written is sent again by friends' own resending.
  void _noHome() {
    final own = mine;
    if (own == null || !_up) return;
    final now = _now();
    if (_gaveOwnAgain != null && now.difference(_gaveOwnAgain!) < const Duration(minutes: 1)) return;
    _gaveOwnAgain = now;
    // Where it names another relay (a move under way), nothing: the relay being left is told by the move itself.
    if (livesHere(own)) _hub!.sayHandles({'dir': 'home', 'rec': own.toJson()});
  }

  /// What the relay says of records: its answer to one given it (`home`), or to this account's own asked back
  /// (`home?`).
  void _heard(Map<String, dynamic> m) {
    if (m['dir'] == 'home?') return _heardOwn(m);
    if (m['dir'] != 'home') return;
    final a = m['a'], n = m['n'];
    if (a == signer.id) {
      final waiting = _ownAnswer;
      if (waiting != null && !waiting.isCompleted) waiting.complete(m);
    }
    if (m['ok'] == true) {
      if (a is String) _busy.remove(a);
      // A relay says it holds a newer record of this account's than this device's: its word is not taken for the
      // count, the record is asked back and held to this account's key first.
      if (a == signer.id && n is int && n > count && _up) _hub!.sayHandles({'dir': 'home?', 'a': signer.id});
      return;
    }
    // This account's own has run out (a device asleep past it): another is made.
    if (m['err'] == 'old' && a == signer.id) {
      unawaited(_queue(() async {
        final address = here;
        if (address != null) await _make(address);
      }));
      return;
    }
    // Too busy to check it just now: given again in a while, a few times; counted afresh once it is taken.
    if (m['err'] == 'busy' && a is String) {
      final tries = (_busy[a] ?? 0) + 1;
      if (tries > 5) {
        _busy.remove(a);
        return;
      }
      _busy[a] = tries;
      late final Timer t;
      t = Timer(busyAgain * tries, () {
        _timers.remove(t);
        final rec = a == signer.id ? mine?.toJson() : _friends[a];
        if (rec != null && _up) _hub!.sayHandles({'dir': 'home', 'rec': rec});
      });
      _timers.add(t);
    }
  }

  /// This account's own record as a relay holds it ([_heard] asked): taken where it is this account's by its key and
  /// newer than this device's. Its count is this device's from then on; where it names another relay, another device
  /// of the account moved there, and the person is told ([movedElsewhere]).
  void _heardOwn(Map<String, dynamic> m) {
    if (m['a'] != signer.id) return;
    final rec = HomeRecord.check(m['rec'], forId: signer.id, forKey: base64Encode(signer.publicKey), now: _now());
    if (rec == null) return;
    final had = mine;
    if (had != null && !rec.newerThan(had)) return;
    if (rec.n > count) _write('net_home_n', '${rec.n}');
    if (livesHere(rec)) {
      mine = rec;
      _write('net_home', jsonEncode(rec.toJson()));
    } else {
      movedElsewhere = rec;
    }
    notifyListeners();
  }

  /// Who has the username [name] on the relay at [host] (`relay.example`, as written after the `@`): asked when the
  /// person asks to add them, never while they type. Of this app's own relay where it talks to other relays; where it
  /// says it won't or can't talk to that one, that is the answer (this app doesn't go around it); where it doesn't talk
  /// to others at all, or couldn't reach that one, of that relay itself, under a key made for the one question. Only a
  /// host a relay would dial: a name with a dot, port 443, not an address on this network; and with [dial] false (a
  /// request checked as it comes), never that relay itself. Null where nobody has the name there; a [HomeError] where
  /// nobody could be asked.
  Future<FoundOnRelay?> whois(String name, String host, {bool dial = true}) async {
    final url = hubOfHost(host);
    if (url == null) throw HomeError('"$host" isn\'t a relay\'s address.');
    if (!dialableRelayHost(host)) throw HomeError('"$host" isn\'t a relay this app can ask: a relay\'s address is a name on the internet, on the usual port.');
    final hub = _hub;
    if (hub != null && _up && relayTalks) {
      final got = await _askOwn(hub, name, host);
      if (got != null) {
        if (got['dir'] == 'err') throw HomeError('${got['err'] ?? 'That did not work.'}');
        final id = got['id'], key = got['key'];
        if (id is String && key is String) return FoundOnRelay(id: id, key: key, home: HomeRecord.check(got['home'], forId: id, forKey: key, now: _now()), here: got['here'] == true);
        // Nobody has that name there; or this relay won't talk to that one, or that one won't talk to this, which is
        // the answer: what passes between the two relays is all that ever would.
        switch (got['why']) {
          case null:
            return null;
          case 'off':
            throw HomeError('Your relay doesn\'t pass messages to $host.');
          case 'refused':
            throw HomeError('$host doesn\'t take messages from your relay.');
        }
      }
    }
    // Not dialled of this app's own accord (a stranger's request checked as it comes: the host is theirs to name).
    if (!dial) throw HomeError('$host can\'t be asked through your relay just now.');
    final FoundThere? found;
    try {
      found = await whoisAt(url, name, dial: _dial);
    } on RelayAskError catch (e) {
      throw HomeError(e.message);
    }
    if (found == null) return null;
    return FoundOnRelay(id: found.id, key: found.key, home: HomeRecord.check(found.home, forId: found.id, forKey: found.key, now: _now()), talks: found.talks);
  }

  /// Asks this app's own relay who has [name] on the relay at [host]; its answer, or null where none came in time.
  /// Only an answer for that name at that host is taken, and only an error about such a question.
  Future<Map<String, dynamic>?> _askOwn(HubCarrier hub, String name, String host) async {
    final answer = Completer<Map<String, dynamic>?>();
    final sub = hub.handles.listen((m) {
      if (answer.isCompleted) return;
      if ((m['dir'] == 'whois' && m['name'] == name && m['at'] == host) || (m['dir'] == 'err' && m['about'] == 'whois' && m['at'] == host)) answer.complete(m);
    });
    try {
      if (!hub.sayHandles({'dir': 'whois', 'name': name, 'at': host})) return null;
      return await answer.future.timeout(answerWithin, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }
}
